"""JSON API routes."""
import dataclasses
import io
import logging
import math
import re
import threading
from datetime import date as _date, datetime, timedelta
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Body, Depends, File, Form, Query, Request, UploadFile
from fastapi.responses import JSONResponse, Response

from .. import calendar as wcal, db, expect, model, reports, status, timer, tzutil, xlsx_io
from ..db import Block, DayExpectation
from ..validate import ApiError, date_arg, loose_time

router = APIRouter()
log = logging.getLogger(__name__)
# One block mutation at a time (phone tap vs Telegram call). Reentrant: a locked route may call a
# helper that locks again. Every check that depends on the running block is made inside it.
_LOCK = threading.RLock()

_XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"


# ApiError lives in worklog.validate (shared by the day and balance APIs); re-exported here.


# ---- dependencies / helpers -------------------------------------------------

def _zone(name: str) -> ZoneInfo | None:
    try:
        return ZoneInfo(name)
    except Exception:  # noqa: BLE001 - an unknown zone falls back to plain wall-clock maths
        return None


def get_conn(request: Request):
    conn = db.connect(request.app.state.settings.db_path, check_same_thread=False,
                      tz=_zone(request.app.state.settings.tz))
    try:
        yield conn
    finally:
        conn.close()


class Ctx:
    """Per-request context: connection, clock reading, holidays and notices."""

    def __init__(self, request: Request, conn):
        self.settings = request.app.state.settings
        self.conn = conn
        self.now: datetime = request.app.state.clock()
        self.today: _date = self.now.date()
        self.tz: ZoneInfo | None = _zone(self.settings.tz)
        self.holidays, warn = expect.load_holidays(self.settings.holidays_path)
        self.notices: list[str] = [warn] if warn else []
        if self.holidays and not any(d.startswith(str(self.now.year)) for d in self.holidays):
            self.notices.append(f"holidays cache has no entries for {self.now.year}")

    def auto_close(self):
        """Close forgotten blocks before reading. Routes call this first so every client sees
        the same corrected data, whichever endpoint it hits first in the morning."""
        timer.auto_close(self.conn, self.now)
        _auto_add_meetings(self)
        return self


def ctx(request: Request, conn=Depends(get_conn)) -> Ctx:
    return Ctx(request, conn)




def _client_default(conn, client):
    if client is None:
        return None
    row = db.clients(conn).get(client)
    return None if row is None else bool(row["billable"])


def _derived(c: Ctx, b: Block) -> dict:
    return model.with_derived(b, db.break_types(c.conn), c.tz)


def _opt_str(body: dict, key: str):
    v = body.get(key)
    if v is not None and not isinstance(v, str):
        raise ApiError(f"{key} must be a string or null")
    return v


def _refuse_second_open(conn, exclude_id: int | None = None) -> None:
    row = conn.execute("SELECT id FROM blocks WHERE end IS NULL AND id IS NOT ? LIMIT 1",
                       (exclude_id,)).fetchone()
    if row:
        raise ApiError("another block is already running; stop it first", 409)


def _opt_bool(body: dict, key: str):
    v = body.get(key)
    if v is not None and not isinstance(v, bool):
        raise ApiError(f"{key} must be a boolean or null")
    return v


def _body(body) -> dict:
    return body if isinstance(body, dict) else {}


def _canon_break(bt: set[str], t: str) -> str | None:
    """The stored name of break type `t` (matched case-insensitively), or None if it is not one."""
    want = t.strip().lower()
    return next((n for n in bt if n.lower() == want), None)


_STATES = ("working", "break", "stopped")


def _expect_state(body: dict) -> str | None:
    v = body.get("expect_state")
    if v is None:
        return None
    if not isinstance(v, str) or v not in _STATES:
        raise ApiError(f"expect_state must be one of {', '.join(_STATES)}")
    return v


def _state_now(c: "Ctx") -> str:
    ob = db.open_block(c.conn)
    if ob is None:
        return "stopped"
    return "working" if model.work_type(ob.type, db.break_types(c.conn)) == "work" else "break"


def _check_span(start: str, end: str, limit: int, what: str) -> None:
    span = (_date.fromisoformat(end) - _date.fromisoformat(start)).days
    if span > limit:
        raise ApiError(f"range too long: {span} days ({what} covers at most {limit} days)")


_AT_MAX_AGE = timedelta(hours=24)


def _at(c: Ctx, body: dict) -> datetime:
    """The moment a timer action happened: `at` ("YYYY-MM-DDTHH:MM", server local time) when a
    client replays an action it queued while offline, else now. Never in the future, never older
    than a day, and never before the running block's start. Call it with _LOCK held: it reads the
    running block. Instants are compared in the configured zone, so an `at` in the repeated hour
    after the clocks go back means the later pass (the earlier one if the later is still ahead),
    and one in the skipped hour after they go forward means the valid time after the gap."""
    raw = body.get("at")
    if raw is None:
        return c.now
    if not isinstance(raw, str):
        raise ApiError("at must be a string like 2026-10-20T09:30")
    try:
        at = datetime.fromisoformat(raw).replace(second=0, microsecond=0, tzinfo=None)
    except ValueError:
        raise ApiError("at must look like 2026-10-20T09:30") from None
    at = tzutil.parse_at(at, c.tz, c.now)
    at_i, now_i = tzutil.instant(at, c.tz), tzutil.instant(c.now, c.tz)
    if at_i > now_i.replace(second=59, microsecond=0):
        raise ApiError("at is in the future")
    if now_i - at_i > _AT_MAX_AGE:
        raise ApiError("at is more than a day ago")
    ob = db.open_block(c.conn)
    if ob and tzutil.instant(tzutil.reading(ob.date, ob.start, ob.start_fold), c.tz) > at_i:
        raise ApiError("at is before the running block started")
    return c.now if at_i >= now_i else at


# ---- status -----------------------------------------------------------------


def _status(c: Ctx) -> dict:
    return status.build(c.conn, c.now, c.holidays, c.notices, c.settings)


def _status_payload(c: Ctx, brief: bool) -> dict:
    if brief:
        return status.brief(c.conn, c.now, c.holidays, c.notices, c.settings)
    return _status(c)


@router.get("/api/chips")
def get_chips(c: Ctx = Depends(ctx)):
    return status.chips(c.conn, c.today, db.break_types(c.conn))


@router.get("/healthz")
def healthz():
    return {"ok": True}


@router.get("/api/status")
def get_status(c: Ctx = Depends(ctx), brief: bool = Query(False)):
    return _status_payload(c, brief)


def _extend_auto_closed(c: Ctx, at: datetime) -> None:
    """An action replayed with `at` after the server had already auto-closed the block it ended:
    when nothing runs and the newest block is an auto-closed one that began before `at` on
    `at`'s date (or the evening before, for `at` in the late-night hours), that block really ran
    until `at`. Its end moves to `at` and the review flag goes; across midnight it is split like
    a late-night stop. Call with _LOCK held."""
    conn = c.conn
    if db.open_block(conn):
        return
    row = conn.execute("SELECT * FROM blocks ORDER BY date DESC, start DESC, id DESC LIMIT 1").fetchone()
    nb = db._block(row) if row else None
    if nb is None or not nb.auto_closed or nb.end is None:
        return
    if tzutil.instant(tzutil.reading(nb.date, nb.start, nb.start_fold), c.tz) >= tzutil.instant(at, c.tz):
        return
    day, hhmm = at.date().isoformat(), at.strftime("%H:%M")
    if nb.date == day:
        db.update_block(conn, nb.id, end=hhmm, end_fold=tzutil.fold_of(at, c.tz))
    elif nb.date == (at.date() - timedelta(days=1)).isoformat() and at.time() < timer.LATE_NIGHT_END:
        db.update_block(conn, nb.id, end="23:59")
        if hhmm != "00:00":
            db.insert_block(conn, Block(None, day, "00:00", hhmm, nb.project, nb.type, nb.client,
                                        nb.billable, nb.source))


def _request_id(body: dict) -> str | None:
    v = body.get("request_id")
    if v is None:
        return None
    if not isinstance(v, str) or not 1 <= len(v) <= 64:
        raise ApiError("request_id must be a string of 1 to 64 characters")
    return v


def _timer_action(c: Ctx, b: dict, brief: bool, act):
    """Run a Start/Pause/Stop under the lock. `expect_state` (not with `at`) turns a stale tap
    into a 409; `at` (an offline replay) first repairs a block auto-closed in the meantime.
    A `request_id` the server already acted on does nothing and answers with the current status;
    only an action that succeeded is remembered."""
    expected = _expect_state(b)
    rid = _request_id(b)
    with _LOCK:
        if rid is not None and db.request_seen(c.conn, rid):
            return _status_payload(c, brief)
        at = _at(c, b)
        if b.get("at") is None:
            if expected is not None:
                timer.auto_close(c.conn, c.now)
                cur = _state_now(c)
                if cur != expected:
                    return JSONResponse({"error": "state changed", "state": cur}, status_code=409)
        else:
            _extend_auto_closed(c, at)
        act(at)
        if rid is not None:
            db.remember_request(c.conn, rid)
    return _status_payload(c, brief)


@router.post("/api/start")
def post_start(body: dict | None = Body(None), c: Ctx = Depends(ctx), brief: bool = Query(False)):
    b = _body(body)
    for k in ("type", "project", "client"):
        _opt_str(b, k)
    t = (b.get("type") or "").strip() if isinstance(b.get("type"), str) else b.get("type")
    if t and _canon_break(db.break_types(c.conn), t):
        raise ApiError(f"'{t}' is a break type; use pause")
    return _timer_action(c, b, brief, lambda at: timer.start(
        c.conn, at, b.get("type"), b.get("project"), b.get("client"), c.tz))


@router.post("/api/pause")
def post_pause(body: dict | None = Body(None), c: Ctx = Depends(ctx), brief: bool = Query(False)):
    b = _body(body)
    t = b.get("type")
    if t is not None and not isinstance(t, str):
        raise ApiError("type must be a string or null")
    t = t.strip() if t else t
    if t:
        bt = db.break_types(c.conn)
        canon = _canon_break(bt, t)
        if canon is None:
            first = db.setting(c.conn, "default_break_type")
            valid = ", ".join(sorted(bt, key=lambda n: (n != first, n)))
            raise ApiError(f"unknown break type '{t}'; valid: {valid}")
        t = canon
    return _timer_action(c, b, brief, lambda at: timer.pause(c.conn, at, t, c.tz))


@router.post("/api/stop")
def post_stop(body: dict | None = Body(None), c: Ctx = Depends(ctx), brief: bool = Query(False)):
    return _timer_action(c, _body(body), brief, lambda at: timer.stop(c.conn, at, c.tz))


# ---- day --------------------------------------------------------------------

@router.get("/api/day/{date}")
def get_day(date: str, c: Ctx = Depends(ctx)):
    date = date_arg(date)
    c.auto_close()
    bt = db.break_types(c.conn)
    blocks = db.blocks_on(c.conn, date)
    fl = model.flags(blocks, c.tz)
    items = [{**model.with_derived(b, bt, c.tz), "flags": fl[b.id]} for b in blocks]
    meetings, warn = wcal.meetings(c.settings.calendar_db_path, date, blocks, c.settings.balance_db_path)  # the open block counts too
    dismissed = db.dismissed_on(c.conn, date)
    for m in meetings:
        m["dismissed"] = not m["logged"] and (m["start"], m["title"] or "") in dismissed
    props = [{"start": m["start"], "end": m["end"], "title": m["title"]}
             for m in meetings if not m["logged"] and not m["dismissed"]]
    return {"date": date, "blocks": items, "totals": reports.day_totals(c.conn, date, bt),
            "proposals": props, "meetings": meetings, "overlaps": status.overlap_notices(blocks),
            "overlap_details": status.overlap_details(blocks),
            "notices": c.notices + ([warn] if warn else [])}


# ---- blocks -----------------------------------------------------------------

@router.post("/api/blocks")
def create_block(body: dict = Body(...), c: Ctx = Depends(ctx)):
    c.auto_close()
    date = date_arg(body.get("date"))
    start = loose_time(body.get("start"), "start")
    end = body.get("end")
    if end is not None:
        end = loose_time(end, "end")
    type_ = (_opt_str(body, "type") or "").strip() if "type" in body else db.setting(c.conn, "default_type")
    if not type_:
        raise ApiError("type is required")
    project = _opt_str(body, "project") or None
    if "client" in body:
        client = _opt_str(body, "client") or None
    else:
        client = db.setting(c.conn, "default_client") or None
    billable = _opt_bool(body, "billable") if "billable" in body else _client_default(c.conn, client)
    bt = db.break_types(c.conn)
    type_ = _canon_break(bt, type_) or type_
    if type_ in bt:
        client, billable = None, None  # a break is never billed to anyone
    if end is not None and end <= start:
        raise ApiError("end must be after start")
    cut = _opt_bool(body, "cut") if "cut" in body else False
    with _LOCK:
        if end is None:
            _refuse_second_open(c.conn)
        elif cut:
            _make_room(c, date, start, end)
        b = Block(None, date, start, end, project, type_, client, billable, "manual")
        b.id = db.insert_block(c.conn, b)
    return _derived(c, db.get_block(c.conn, b.id))


@router.put("/api/blocks/{block_id}")
def update_block(block_id: int, body: dict = Body(...), c: Ctx = Depends(ctx)):
    c.auto_close()
    with _LOCK:
        cur = db.get_block(c.conn, block_id)
        if cur is None:
            raise ApiError("not found", 404)
        if body.get("require_open") and cur.end is not None:
            raise ApiError("block is not running any more", 409)  # a chip aimed at the running block hit a closed one
        fields = {}
        if "end" in body and body["end"] is None and cur.end is not None:
            _refuse_second_open(c.conn, block_id)
        if "date" in body:
            fields["date"] = date_arg(body["date"])
        if "start" in body:
            fields["start"] = loose_time(body["start"], "start")
            if fields["start"] == cur.start:
                fields["start_fold"] = cur.start_fold   # an unchanged time keeps its pass
        if body.get("end") is not None:
            fields["end"] = loose_time(body["end"], "end")
            if fields["end"] == cur.end:
                fields["end_fold"] = cur.end_fold
        elif "end" in body:
            fields["end"] = None
        if "start" in fields or "end" in fields:
            start = fields.get("start", cur.start)
            end = fields["end"] if "end" in fields else cur.end
            if end is not None and end <= start:
                raise ApiError("end must be after start")
        bt = db.break_types(c.conn)
        if "type" in body:
            t = (_opt_str(body, "type") or "").strip()
            if not t:
                raise ApiError("type is required")
            fields["type"] = _canon_break(bt, t) or t
        if "project" in body:
            fields["project"] = _opt_str(body, "project") or None
        if "client" in body:
            fields["client"] = _opt_str(body, "client") or None
            if "billable" not in body:
                fields["billable"] = _client_default(c.conn, fields["client"])
        if "billable" in body:
            fields["billable"] = _opt_bool(body, "billable")
        if "type" in body:
            if fields["type"] in bt:
                fields["client"], fields["billable"] = None, None  # became a break
            elif cur.type in bt and "client" not in body:
                fields["client"] = db.setting(c.conn, "default_client") or None  # break became work
                fields["billable"] = _client_default(c.conn, fields["client"])
        if fields:
            db.update_block(c.conn, block_id, **fields)
        return _derived(c, db.get_block(c.conn, block_id))


@router.delete("/api/blocks/{block_id}")
def delete_block(block_id: int, c: Ctx = Depends(ctx)):
    c.auto_close()
    with _LOCK:
        if db.get_block(c.conn, block_id) is None:
            raise ApiError("not found", 404)
        db.delete_block(c.conn, block_id)
    return {"ok": True}


def _make_room(c: Ctx, date: str, start: str, end: str) -> None:
    """Make room for a block the user adds with `cut`: a block of that day it reaches into is
    trimmed, one it lies inside is split in two (the forgotten break). A block it covers whole is
    left as it is and shows as an overlap: a mistyped time never deletes anything. The running
    block gives way only when the new block is already over; what runs on is a new running block
    with the same type, project and client. Call it with _LOCK held."""
    over = date < c.today.isoformat() or (date == c.today.isoformat() and end <= c.now.strftime("%H:%M"))
    for b in db.blocks_on(c.conn, date):
        if b.end is None:
            if not over or b.start >= end:
                continue
            if b.start < start:
                db.update_block(c.conn, b.id, end=start)
                db.insert_block(c.conn, Block(None, date, end, None, b.project, b.type, b.client,
                                              b.billable, b.source))
            else:
                db.update_block(c.conn, b.id, start=end)
            continue
        if not b.start < b.end or not (b.start < end and b.end > start):
            continue
        head, tail = b.start < start, b.end > end
        if head and tail:
            db.insert_block(c.conn, Block(None, date, end, b.end, b.project, b.type, b.client,
                                          b.billable, b.source, b.auto_closed))
        if head:
            db.update_block(c.conn, b.id, end=start)
        elif tail:
            db.update_block(c.conn, b.id, start=end)


@router.post("/api/blocks/{block_id}/merge-next")
def merge_next(block_id: int, c: Ctx = Depends(ctx)):
    """Join a block with the one that starts where it ends: it takes that block's end (running
    included) and the other is deleted. Type, project, client and billable stay this block's."""
    c.auto_close()
    with _LOCK:
        cur = db.get_block(c.conn, block_id)
        if cur is None:
            raise ApiError("not found", 404)
        nxt = None if cur.end is None else next(
            (b for b in db.blocks_on(c.conn, cur.date) if b.id != cur.id and b.start == cur.end), None)
        if nxt is None:
            raise ApiError("no block starts where this one ends", 409)
        db.delete_block(c.conn, nxt.id)
        db.update_block(c.conn, cur.id, end=nxt.end, end_fold=nxt.end_fold, auto_closed=nxt.auto_closed)
        return _derived(c, db.get_block(c.conn, cur.id))


def _cut_out_of_closed_blocks(conn, date, start, end):
    """Make room for a meeting: the closed work and break blocks of the day lose the part it
    covers (trimmed, split in two, or removed). Meeting blocks are left as they are."""
    for b in db.blocks_on(conn, date):
        if b.end is None or wcal.is_meeting(b) or not b.start < b.end or not (b.start < end and b.end > start):
            continue
        head, tail = b.start < start, b.end > end
        if head and tail:
            db.insert_block(conn, Block(None, date, end, b.end, b.project, b.type, b.client, b.billable,
                                        b.source, b.auto_closed))
        if head:
            db.update_block(conn, b.id, end=start, auto_closed=b.auto_closed and not tail)
        elif tail:
            db.update_block(conn, b.id, start=end)
        else:
            db.delete_block(conn, b.id)


@router.post("/api/calendar/add")
def calendar_add(body: dict = Body(...), c: Ctx = Depends(ctx)):
    c.auto_close()
    date = date_arg(body.get("date"))
    start = loose_time(body.get("start"), "start")
    end = loose_time(body.get("end"), "end")
    title = _opt_str(body, "title") or None
    today, hhmm = c.today.isoformat(), c.now.strftime("%H:%M")
    if date > today or (date == today and start > hhmm):
        raise ApiError("meeting has not started yet")
    with _LOCK:   # the duplicate check and the write are one step
        same = [b for b in db.blocks_on(c.conn, date)
                if b.source == "calendar" and (b.start, b.project) == (start, title) and b.end in (end, None)]
        if same:
            return _derived(c, same[0])   # added a moment ago (auto-add, or a second tap): not twice
        return _derived(c, _add_meeting(c, date, start, end, title))


def _add_meeting(c: Ctx, date: str, start: str, end: str, title: str | None) -> Block:
    """Log a calendar meeting that has started: the blocks at that time make room for it."""
    in_progress = date == c.today.isoformat() and start <= c.now.strftime("%H:%M") < end
    client = db.setting(c.conn, "default_client") or None
    with _LOCK:
        _cut_out_of_closed_blocks(c.conn, date, start, end)
        ob = db.open_block(c.conn)
        # The meeting cuts the running block when it reaches past the block's start; a meeting
        # wholly before the block leaves it alone. Never more than one open block results.
        interrupted = ob is not None and ob.date == date and end > ob.start
        if interrupted:
            cut = max(ob.start, start)   # a meeting that began before the timer eats its start
            if cut == ob.start:
                db.delete_block(c.conn, ob.id)   # nothing of the running block is left
            else:
                db.update_block(c.conn, ob.id, end=cut)
        b = Block(None, date, start, None if in_progress else end, title, wcal.MEET_TYPE, client,
                  _client_default(c.conn, client), "calendar")
        b.id = db.insert_block(c.conn, b)
        if interrupted and not in_progress:
            # The timer was never stopped: resume what was running, from the meeting's end.
            db.insert_block(c.conn, Block(None, date, end, None, ob.project, ob.type, ob.client,
                                          ob.billable, "timer"))
    return db.get_block(c.conn, b.id)


def _auto_add_meetings(c: Ctx) -> None:
    """With the `calendar_auto_add` setting: today's meetings that are over and fall inside logged
    time (a work or break block, or the running one) become meeting blocks, as if Add was pressed.
    Each is also marked dismissed, so deleting such a block is final and it is never added twice."""
    if db.setting(c.conn, "calendar_auto_add") != "1" or not c.settings.calendar_db_path:
        return
    date, hhmm = c.today.isoformat(), c.now.strftime("%H:%M")
    while True:
        with _LOCK:   # look and write in one step, so two requests never add the same meeting
            blocks = db.blocks_on(c.conn, date)
            found, _ = wcal.meetings(c.settings.calendar_db_path, date, blocks, c.settings.balance_db_path)
            dismissed = db.dismissed_on(c.conn, date)
            due = next((m for m in found
                        if not m["logged"] and m["end"] <= hhmm and (m["start"], m["title"] or "") not in dismissed
                        and any(not wcal.is_meeting(b) and b.start < m["end"] and (b.end or hhmm) > m["start"]
                                for b in blocks)), None)
            if due is None:
                return
            db.dismiss_proposal(c.conn, date, due["start"], due["title"])
            _add_meeting(c, date, due["start"], due["end"], due["title"])


def _dismiss_args(body: dict) -> tuple[str, str, str | None]:
    return date_arg(body.get("date")), loose_time(body.get("start"), "start"), _opt_str(body, "title") or None


@router.post("/api/calendar/dismiss")
def calendar_dismiss(body: dict = Body(...), c: Ctx = Depends(ctx)):
    db.dismiss_proposal(c.conn, *_dismiss_args(body))
    return {"ok": True}


@router.delete("/api/calendar/dismiss")
def calendar_undismiss(body: dict = Body(...), c: Ctx = Depends(ctx)):
    db.undismiss_proposal(c.conn, *_dismiss_args(body))
    return {"ok": True}


# ---- reports ----------------------------------------------------------------

MAX_SUMMARY_DAYS = 3660  # /api/summary refuses ranges longer than about ten years (HTTP 400)
MAX_DAYS_SPAN = 3660     # so do /api/days and /api/heatmap
MAX_EXPORT_DAYS = 7320   # and /api/export.* (about twenty years)


@router.get("/api/summary")
def summary(group: str = "week", start: str | None = None, end: str | None = None,
            c: Ctx = Depends(ctx)):
    if group not in ("week", "month", "quarter", "year"):
        raise ApiError(f"invalid group: {group!r}")
    c.auto_close()
    end = date_arg(end, "end") if end else c.today.isoformat()
    if start:
        start = date_arg(start, "start")
    else:
        start = expect.first_logged_day(c.conn) or c.today.isoformat()
    _check_span(start, end, MAX_SUMMARY_DAYS, "the summary")
    rows = reports.grouped(c.conn, group, start, end, c.holidays, c.today)
    stats = (reports.weekly_stats(rows, model.week_key(c.today.isoformat()))
             if group == "week" else None)
    return {"rows": rows, "stats": stats, "rate_h": reports.rate_per_h(c.conn),
            "week_basis_h": float(db.setting(c.conn, "base_week_h")),
            "alt_week_h": float(db.setting(c.conn, "alt_week_h"))}


# ---- settings ---------------------------------------------------------------

RATE_UNITS = ("h", "day")


def _settings(conn) -> dict:
    raw = db.setting(conn, "rate").strip()
    return {"rate": float(raw) if raw else None, "rate_unit": db.setting(conn, "rate_unit"),
            "rate_h": reports.rate_per_h(conn),
            "default_expected_h": float(db.setting(conn, "default_expected_h")),
            "week_basis_h": float(db.setting(conn, "base_week_h")),
            "alt_week_h": float(db.setting(conn, "alt_week_h")),
            "default_type": db.setting(conn, "default_type"),
            "default_client": db.setting(conn, "default_client") or None,
            "default_break_type": db.setting(conn, "default_break_type"),
            "auto_close_time": db.setting(conn, "auto_close_time"),
            "calendar_auto_add": db.setting(conn, "calendar_auto_add") == "1",
            "currency": db.setting(conn, "currency"),
            "break_types": sorted(db.break_types(conn))}


def _type_name(body: dict, key: str) -> str:
    v = body[key]
    if not isinstance(v, str) or not v.strip() or len(v.strip()) > 40:
        raise ApiError(f"{key} must be a name of 1 to 40 characters")
    return v.strip()


@router.get("/api/settings")
def get_settings(c: Ctx = Depends(ctx)):
    return _settings(c.conn)


@router.put("/api/settings")
def put_settings(body: dict = Body(...), c: Ctx = Depends(ctx)):
    # Everything is validated first and stored in one transaction: a 400 saves nothing.
    todo: dict[str, str] = {}
    if "rate" in body:
        v = body["rate"]
        if v is not None and (isinstance(v, bool) or not isinstance(v, (int, float)) or v < 0):
            raise ApiError("rate must be a non-negative number or null")
        todo["rate"] = "" if v is None else str(float(v))
    if "rate_unit" in body:
        if body["rate_unit"] not in RATE_UNITS:
            raise ApiError(f"rate_unit must be one of {', '.join(RATE_UNITS)}")
        todo["rate_unit"] = body["rate_unit"]
    if "week_basis_h" in body:
        v = body["week_basis_h"]
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not 1 <= v <= 80:
            raise ApiError("week_basis_h must be a number between 1 and 80")
        # A full week is `v` hours: the default workday becomes v/5 (per-day overrides stay as
        # set) and the alternative column shows the other common basis.
        todo["base_week_h"] = str(float(v))
        todo["default_expected_h"] = str(float(v) / 5)
        todo["alt_week_h"] = "35.0" if abs(float(v) - 40) < 1e-9 else "40.0"
    # what Start and Pause use when nothing is picked
    bt = db.break_types(c.conn)
    if "default_type" in body:
        todo["default_type"] = _type_name(body, "default_type")
        if _canon_break(bt, todo["default_type"]):
            raise ApiError("default_type must be a work type, not a break type")
    if "default_break_type" in body:
        v = _type_name(body, "default_break_type")
        todo["default_break_type"] = _canon_break(bt, v) or v
        if todo["default_break_type"] not in bt:
            raise ApiError(f"default_break_type must be one of {', '.join(sorted(bt))}")
    if "default_client" in body:
        v = _opt_str(body, "default_client")
        if v is not None and len(v.strip()) > 100:
            raise ApiError("default_client is too long")
        todo["default_client"] = (v or "").strip()
    if "auto_close_time" in body:
        todo["auto_close_time"] = loose_time(body["auto_close_time"], "auto_close_time")
    if "calendar_auto_add" in body:
        if not isinstance(body["calendar_auto_add"], bool):
            raise ApiError("calendar_auto_add must be true or false")
        todo["calendar_auto_add"] = "1" if body["calendar_auto_add"] else ""
    if "currency" in body:
        v = body["currency"]
        if not isinstance(v, str) or not 1 <= len(v.strip()) <= 4:
            raise ApiError("currency must be a symbol or code of 1 to 4 characters")
        todo["currency"] = v.strip()
    if todo:
        db.set_settings(c.conn, todo)
    return _settings(c.conn)


# ---- clients ----------------------------------------------------------------

def _client_row(conn, name: str):
    """The client called `name` (exact, else case-insensitive), or a 404."""
    rows = db.clients(conn)
    if name in rows:
        return rows[name]
    want = name.lower()
    row = next((r for k, r in rows.items() if k.lower() == want), None)
    if row is None:
        raise ApiError("no such client", 404)
    return row


def _client_name(v) -> str:
    if not isinstance(v, str) or not v.strip() or len(v.strip()) > 100:
        raise ApiError("name must be a text of 1 to 100 characters")
    return v.strip()


def _client_json(r) -> dict:
    return {"name": r["abbrev"], "billable": bool(r["billable"])}


def _client_taken(conn, name: str, except_name: str | None = None) -> bool:
    want = name.lower()
    return any(k.lower() == want and k != except_name for k in db.clients(conn))


@router.get("/api/clients")
def list_clients(c: Ctx = Depends(ctx)):
    return [_client_json(r) for _, r in sorted(db.clients(c.conn).items(), key=lambda kv: (kv[0].lower(), kv[0]))]


@router.post("/api/clients")
def add_client(body: dict = Body(...), c: Ctx = Depends(ctx)):
    name = _client_name(body.get("name"))
    billable = _opt_bool(body, "billable")
    with _LOCK:
        if _client_taken(c.conn, name):
            raise ApiError("a client with that name already exists")
        c.conn.execute("INSERT INTO clients(abbrev, name, billable) VALUES (?, ?, ?)",
                       (name, name, 1 if billable is None else int(billable)))
        c.conn.commit()
        return _client_json(db.clients(c.conn)[name])


@router.put("/api/clients/{name}")
def update_client(name: str, body: dict = Body(...), c: Ctx = Depends(ctx)):
    with _LOCK:
        old = _client_row(c.conn, name)["abbrev"]
        new = _client_name(body["name"]) if "name" in body else old
        billable = _opt_bool(body, "billable") if "billable" in body else None
        if "billable" in body and billable is None:
            raise ApiError("billable must be true or false")
        if new != old and _client_taken(c.conn, new, except_name=old):
            raise ApiError("a client with that name already exists")
        db.rename_client(c.conn, old, new, billable)
        return _client_json(db.clients(c.conn)[new])


@router.delete("/api/clients/{name}")
def delete_client(name: str, c: Ctx = Depends(ctx)):
    with _LOCK:
        cur = _client_row(c.conn, name)["abbrev"]
        if c.conn.execute("SELECT 1 FROM blocks WHERE client = ? LIMIT 1", (cur,)).fetchone():
            raise ApiError("client is used by blocks", 409)
        if db.setting(c.conn, "default_client") == cur:
            raise ApiError("client is the default_client", 409)
        c.conn.execute("DELETE FROM clients WHERE abbrev = ?", (cur,))
        c.conn.commit()
    return {"ok": True}


# ---- break types --------------------------------------------------------------

def _break_names(c: Ctx) -> list[str]:
    return status.chips(c.conn, c.today, db.break_types(c.conn))["break_types"]


@router.get("/api/break-types")
def list_break_types(c: Ctx = Depends(ctx)):
    return _break_names(c)


@router.post("/api/break-types")
def add_break_type(body: dict = Body(...), c: Ctx = Depends(ctx)):
    if "name" not in body:
        raise ApiError("name is required")
    # stored lower case: model.work_type compares a block's lower-cased type with these names
    name = _type_name(body, "name").lower()
    with _LOCK:
        if _canon_break(db.break_types(c.conn), name):
            raise ApiError("a break type with that name already exists")
        if c.conn.execute("SELECT 1 FROM blocks WHERE lower(trim(type)) = ? LIMIT 1", (name,)).fetchone():
            raise ApiError("that name is already used as a work type")
        c.conn.execute("INSERT INTO break_types(name) VALUES (?)", (name,))
        c.conn.commit()
    return _break_names(c)


@router.put("/api/break-types/{name}")
def rename_break_type(name: str, body: dict = Body(...), c: Ctx = Depends(ctx)):
    if "name" not in body:
        raise ApiError("name is required")
    new = _type_name(body, "name").lower()   # stored lower case, like POST
    with _LOCK:
        cur = _canon_break(db.break_types(c.conn), name)
        if cur is None:
            raise ApiError("no such break type", 404)
        other = _canon_break(db.break_types(c.conn), new)
        if other is not None and other != cur:
            raise ApiError("a break type with that name already exists")
        if other is None and c.conn.execute(
                "SELECT 1 FROM blocks WHERE lower(trim(type)) = ? LIMIT 1", (new,)).fetchone():
            raise ApiError("that name is already used as a work type")
        if new != cur:
            db.rename_break_type(c.conn, cur, new)
    return _break_names(c)


@router.delete("/api/break-types/{name}")
def delete_break_type(name: str, c: Ctx = Depends(ctx)):
    with _LOCK:
        cur = _canon_break(db.break_types(c.conn), name)
        if cur is None:
            raise ApiError("no such break type", 404)
        if db.setting(c.conn, "default_break_type") == cur:
            raise ApiError("break type is the default_break_type", 409)
        if c.conn.execute("SELECT 1 FROM blocks WHERE lower(trim(type)) = ? LIMIT 1", (cur.lower(),)).fetchone():
            raise ApiError("break type is used by blocks", 409)
        c.conn.execute("DELETE FROM break_types WHERE name = ?", (cur,))
        c.conn.commit()
    return _break_names(c)


@router.get("/api/heatmap")
def heatmap(start: str | None = None, end: str | None = None, c: Ctx = Depends(ctx)):
    c.auto_close()
    start, end = _export_range(c, start, end, MAX_DAYS_SPAN, "the heatmap")
    return {"start": start, "end": end, **reports.heatmap(c.conn, start, end)}


@router.get("/api/invoice")
def invoice(month: str, c: Ctx = Depends(ctx)):
    if not re.fullmatch(r"\d{4}-(0[1-9]|1[0-2])", month):
        raise ApiError(f"invalid month: {month!r} (expected YYYY-MM)")
    c.auto_close()
    return reports.invoice_days(c.conn, month, c.holidays, c.today)


# ---- expected days ----------------------------------------------------------

@router.get("/api/days")
def get_days(start: str, end: str, c: Ctx = Depends(ctx)):
    start, end = date_arg(start, "start"), date_arg(end, "end")
    _check_span(start, end, MAX_DAYS_SPAN, "expected days")
    exps = expect.expected_between(c.conn, start, end, c.holidays, expect.first_logged_day(c.conn))
    return [dataclasses.asdict(e) for e in exps.values()]


@router.put("/api/days/{date}")
def put_day(date: str, body: dict = Body(...), c: Ctx = Depends(ctx)):
    date = date_arg(date)
    try:
        expected = float(body["expected_h"])
        sick = float(body.get("sick_h") or 0)
    except (KeyError, TypeError, ValueError):
        raise ApiError("expected_h (number) is required; sick_h must be a number")
    if not (math.isfinite(expected) and math.isfinite(sick)):
        raise ApiError("expected_h and sick_h must be finite numbers")
    if expected < 0 or sick < 0:
        raise ApiError("expected_h and sick_h must not be negative")
    e = DayExpectation(date, expected, sick, str(body.get("reason") or ""), "manual")
    db.set_expectation(c.conn, e)
    return dataclasses.asdict(db.get_expectation(c.conn, date))


@router.delete("/api/days/{date}")
def delete_day(date: str, c: Ctx = Depends(ctx)):
    db.delete_expectation(c.conn, date_arg(date))
    return {"ok": True}


# ---- export -----------------------------------------------------------------

def _export_range(c: Ctx, start, end, limit: int = MAX_EXPORT_DAYS, what: str = "an export") -> tuple[str, str]:
    end = date_arg(end, "end") if end else c.today.isoformat()
    start = date_arg(start, "start") if start else (
        expect.first_logged_day(c.conn) or c.today.isoformat())
    _check_span(start, end, limit, what)
    return start, end


@router.get("/api/export.csv")
def export_csv(start: str | None = None, end: str | None = None, c: Ctx = Depends(ctx)):
    start, end = _export_range(c, start, end)
    data = xlsx_io.export_csv(xlsx_io.export_rows(c.conn, start, end, c.holidays))
    return Response(data, media_type="text/csv", headers={
        "Content-Disposition": f"attachment; filename=worklog-{start}-{end}.csv"})


@router.get("/api/export.xlsx")
def export_xlsx(start: str | None = None, end: str | None = None, c: Ctx = Depends(ctx)):
    start, end = _export_range(c, start, end)
    rows = xlsx_io.export_rows(c.conn, start, end, c.holidays)
    data = xlsx_io.export_xlsx(c.conn, rows, start, end, c.holidays, c.today)
    return Response(data, media_type=_XLSX, headers={
        "Content-Disposition": f"attachment; filename=worklog-{start}-{end}.xlsx"})


# ---- import -----------------------------------------------------------------

MAX_UPLOAD_BYTES = 10 * 1024 * 1024


@router.post("/api/import")
def import_file(file: UploadFile = File(...), mode: str = Form("merge"),
                dry_run: str = Form("0"), workdays: str = Form("0"), c: Ctx = Depends(ctx)):
    if mode not in ("merge", "replace"):
        raise ApiError(f"invalid mode: {mode!r}")
    name = file.filename or ""
    if not name.lower().endswith((".xlsx", ".csv")):
        raise ApiError(f"unsupported file type: {name!r} (use .xlsx or .csv)")
    data = file.file.read(MAX_UPLOAD_BYTES + 1)
    if len(data) > MAX_UPLOAD_BYTES:
        raise ApiError(f"file too large ({MAX_UPLOAD_BYTES // (1024 * 1024)} MB max)", 413)
    try:
        parsed = xlsx_io.parse_rows(io.BytesIO(data), name)
    except Exception:
        log.exception("import: could not read %r", name)
        raise ApiError("could not read file: it is not a valid .xlsx or .csv export") from None
    if dry_run == "1":
        would_update = would_delete = 0
        running = None
        if mode == "merge":
            would_update = sum(
                1 for b in parsed.blocks if c.conn.execute(
                    "SELECT 1 FROM blocks WHERE date = ? AND start = ? LIMIT 1",
                    (b.date, b.start)).fetchone())
        elif parsed.blocks:
            lo, hi = min(b.date for b in parsed.blocks), max(b.date for b in parsed.blocks)
            would_delete = c.conn.execute(
                "SELECT COUNT(*) FROM blocks WHERE date BETWEEN ? AND ?", (lo, hi)).fetchone()[0]
            running = xlsx_io.running_block_in_range(c.conn, parsed)
        return {"would_insert": len(parsed.blocks) - would_update, "would_update": would_update,
                "would_delete": would_delete, "would_delete_running": running,
                "skipped": parsed.skipped, "errors": list(parsed.errors)}
    with _LOCK:
        res = xlsx_io.import_blocks(c.conn, parsed, mode)
        if workdays == "1":
            res["workdays_rows"] = xlsx_io.import_workdays(c.conn, parsed, c.holidays)
    return res
