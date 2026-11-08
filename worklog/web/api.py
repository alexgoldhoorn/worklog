"""JSON API routes."""
import dataclasses
import math
import re
import threading
from datetime import date as _date, datetime

from fastapi import APIRouter, Body, Depends, File, Form, Query, Request, UploadFile
from fastapi.responses import Response

from .. import calendar as wcal, db, expect, model, reports, status, timer, xlsx_io
from ..db import Block, DayExpectation
from ..validate import ApiError, date_arg

router = APIRouter()
_LOCK = threading.Lock()  # one timer mutation at a time (phone tap vs Telegram call)

_XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"


# ApiError lives in worklog.validate (shared by the day and balance APIs); re-exported here.


# ---- dependencies / helpers -------------------------------------------------

def get_conn(request: Request):
    conn = db.connect(request.app.state.settings.db_path, check_same_thread=False)
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
        self.holidays, warn = expect.load_holidays(self.settings.holidays_path)
        self.notices: list[str] = [warn] if warn else []
        if self.holidays and not any(d.startswith(str(self.now.year)) for d in self.holidays):
            self.notices.append(f"holidays cache has no entries for {self.now.year}")

    def auto_close(self):
        """Close forgotten blocks before reading. Routes call this first so every client sees
        the same corrected data, whichever endpoint it hits first in the morning."""
        timer.auto_close(self.conn, self.now)
        return self


def ctx(request: Request, conn=Depends(get_conn)) -> Ctx:
    return Ctx(request, conn)


_date_arg = date_arg


_LOOSE_TIME = re.compile(r"(\d{1,2})[:.hH]?(\d{2})")


def _time_arg(v, name) -> str:
    """Accept HH:MM, and also 9:50 / 9.50 / 950 / 0950, normalised to HH:MM."""
    if isinstance(v, str):
        m = _LOOSE_TIME.fullmatch(v.strip())
        if m and int(m.group(1)) < 24 and int(m.group(2)) < 60:
            return f"{int(m.group(1)):02d}:{m.group(2)}"
    raise ApiError(f"invalid {name}: {v!r} (expected HH:MM)")


def _client_default(conn, client):
    if client is None:
        return None
    row = db.clients(conn).get(client)
    return None if row is None else bool(row["billable"])


def _derived(c: Ctx, b: Block) -> dict:
    return model.with_derived(b, db.break_types(c.conn))


def _opt_str(body: dict, key: str):
    v = body.get(key)
    if v is not None and not isinstance(v, str):
        raise ApiError(f"{key} must be a string or null")
    return v


def _opt_bool(body: dict, key: str):
    v = body.get(key)
    if v is not None and not isinstance(v, bool):
        raise ApiError(f"{key} must be a boolean or null")
    return v


def _body(body) -> dict:
    return body if isinstance(body, dict) else {}


# ---- status -----------------------------------------------------------------


def _status(c: Ctx) -> dict:
    return status.build(c.conn, c.now, c.holidays, c.notices, c.settings)


def _status_payload(c: Ctx, brief: bool) -> dict:
    if brief:
        return status.brief(c.conn, c.now, c.holidays, c.notices, c.settings)
    return _status(c)


@router.get("/healthz")
def healthz():
    return {"ok": True}


@router.get("/api/status")
def get_status(c: Ctx = Depends(ctx), brief: bool = Query(False)):
    return _status_payload(c, brief)


@router.post("/api/start")
def post_start(body: dict | None = Body(None), c: Ctx = Depends(ctx), brief: bool = Query(False)):
    b = _body(body)
    t = (b.get("type") or "").strip() if isinstance(b.get("type"), str) else b.get("type")
    if t and t in db.break_types(c.conn):
        raise ApiError(f"'{t}' is a break type; use pause")
    with _LOCK:
        timer.start(c.conn, c.now, b.get("type"), b.get("project"), b.get("client"))
    return _status_payload(c, brief)


@router.post("/api/pause")
def post_pause(body: dict | None = Body(None), c: Ctx = Depends(ctx), brief: bool = Query(False)):
    t = _body(body).get("type")
    t = t.strip() if isinstance(t, str) else t
    if t:
        bt = db.break_types(c.conn)
        if t not in bt:
            valid = ", ".join(sorted(bt, key=lambda n: (n != "eat", n)))
            raise ApiError(f"unknown break type '{t}'; valid: {valid}")
    with _LOCK:
        timer.pause(c.conn, c.now, t)
    return _status_payload(c, brief)


@router.post("/api/stop")
def post_stop(body: dict | None = Body(None), c: Ctx = Depends(ctx), brief: bool = Query(False)):
    with _LOCK:
        timer.stop(c.conn, c.now)
    return _status_payload(c, brief)


# ---- day --------------------------------------------------------------------

@router.get("/api/day/{date}")
def get_day(date: str, c: Ctx = Depends(ctx)):
    date = _date_arg(date)
    c.auto_close()
    bt = db.break_types(c.conn)
    blocks = db.blocks_on(c.conn, date)
    fl = model.flags(blocks)
    items = [{**model.with_derived(b, bt), "flags": fl[b.id]} for b in blocks]
    props, warn = wcal.proposals(c.settings.calendar_db_path, date, blocks)  # the open block counts too
    dismissed = db.dismissed_on(c.conn, date)
    props = [p for p in props if (p["start"], p["title"] or "") not in dismissed]
    return {"date": date, "blocks": items, "totals": reports.day_totals(c.conn, date, bt),
            "proposals": props, "overlaps": status.overlap_notices(blocks),
            "notices": c.notices + ([warn] if warn else [])}


# ---- blocks -----------------------------------------------------------------

@router.post("/api/blocks")
def create_block(body: dict = Body(...), c: Ctx = Depends(ctx)):
    c.auto_close()
    date = _date_arg(body.get("date"))
    start = _time_arg(body.get("start"), "start")
    end = body.get("end")
    if end is not None:
        end = _time_arg(end, "end")
    type_ = (_opt_str(body, "type") or "").strip() if "type" in body else db.setting(c.conn, "default_type")
    if not type_:
        raise ApiError("type is required")
    project = _opt_str(body, "project") or None
    if "client" in body:
        client = _opt_str(body, "client") or None
    else:
        client = db.setting(c.conn, "default_client") or None
    billable = _opt_bool(body, "billable") if "billable" in body else _client_default(c.conn, client)
    if type_ in db.break_types(c.conn):
        client, billable = None, None  # a break is never billed to anyone
    b = Block(None, date, start, end, project, type_, client, billable, "manual")
    b.id = db.insert_block(c.conn, b)
    return _derived(c, db.get_block(c.conn, b.id))


@router.put("/api/blocks/{block_id}")
def update_block(block_id: int, body: dict = Body(...), c: Ctx = Depends(ctx)):
    c.auto_close()
    cur = db.get_block(c.conn, block_id)
    if cur is None:
        raise ApiError("not found", 404)
    if body.get("require_open") and cur.end is not None:
        raise ApiError("block is not running any more", 409)  # a chip aimed at the running block hit a closed one
    fields = {}
    if "date" in body:
        fields["date"] = _date_arg(body["date"])
    if "start" in body:
        fields["start"] = _time_arg(body["start"], "start")
    if body.get("end") is not None:
        fields["end"] = _time_arg(body["end"], "end")
    elif "end" in body:
        fields["end"] = None
    if "type" in body:
        t = (_opt_str(body, "type") or "").strip()
        if not t:
            raise ApiError("type is required")
        fields["type"] = t
    if "project" in body:
        fields["project"] = _opt_str(body, "project") or None
    if "client" in body:
        fields["client"] = _opt_str(body, "client") or None
        if "billable" not in body:
            fields["billable"] = _client_default(c.conn, fields["client"])
    if "billable" in body:
        fields["billable"] = _opt_bool(body, "billable")
    if "type" in body:
        cur = db.get_block(c.conn, block_id)
        bt = db.break_types(c.conn)
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
    if db.get_block(c.conn, block_id) is None:
        raise ApiError("not found", 404)
    db.delete_block(c.conn, block_id)
    return {"ok": True}


@router.post("/api/calendar/add")
def calendar_add(body: dict = Body(...), c: Ctx = Depends(ctx)):
    c.auto_close()
    date = _date_arg(body.get("date"))
    start = _time_arg(body.get("start"), "start")
    end = _time_arg(body.get("end"), "end")
    title = body.get("title") or None
    today, hhmm = c.today.isoformat(), c.now.strftime("%H:%M")
    if date > today or (date == today and start > hhmm):
        raise ApiError("meeting has not started yet")
    in_progress = date == today and start <= hhmm < end
    client = db.setting(c.conn, "default_client")
    with _LOCK:
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
        b = Block(None, date, start, None if in_progress else end, title, "meet", client,
                  _client_default(c.conn, client), "calendar")
        b.id = db.insert_block(c.conn, b)
        if interrupted and not in_progress:
            # The timer was never stopped: resume what was running, from the meeting's end.
            db.insert_block(c.conn, Block(None, date, end, None, ob.project, ob.type, ob.client,
                                          ob.billable, "timer"))
    return _derived(c, db.get_block(c.conn, b.id))


def _dismiss_args(body: dict) -> tuple[str, str, str | None]:
    return _date_arg(body.get("date")), _time_arg(body.get("start"), "start"), _opt_str(body, "title") or None


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


@router.get("/api/summary")
def summary(group: str = "week", start: str | None = None, end: str | None = None,
            c: Ctx = Depends(ctx)):
    if group not in ("week", "month", "quarter", "year"):
        raise ApiError(f"invalid group: {group!r}")
    c.auto_close()
    end = _date_arg(end, "end") if end else c.today.isoformat()
    if start:
        start = _date_arg(start, "start")
    else:
        start = expect.first_logged_day(c.conn) or c.today.isoformat()
    span = (_date.fromisoformat(end) - _date.fromisoformat(start)).days
    if span > MAX_SUMMARY_DAYS:
        raise ApiError(f"range too long: {span} days (the summary covers at most {MAX_SUMMARY_DAYS} days)")
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
            "alt_week_h": float(db.setting(conn, "alt_week_h"))}


@router.get("/api/settings")
def get_settings(c: Ctx = Depends(ctx)):
    return _settings(c.conn)


@router.put("/api/settings")
def put_settings(body: dict = Body(...), c: Ctx = Depends(ctx)):
    if "rate" in body:
        v = body["rate"]
        if v is not None and (isinstance(v, bool) or not isinstance(v, (int, float)) or v < 0):
            raise ApiError("rate must be a non-negative number or null")
        db.set_setting(c.conn, "rate", "" if v is None else str(float(v)))
    if "rate_unit" in body:
        if body["rate_unit"] not in RATE_UNITS:
            raise ApiError(f"rate_unit must be one of {', '.join(RATE_UNITS)}")
        db.set_setting(c.conn, "rate_unit", body["rate_unit"])
    if "week_basis_h" in body:
        v = body["week_basis_h"]
        if isinstance(v, bool) or not isinstance(v, (int, float)) or not 1 <= v <= 80:
            raise ApiError("week_basis_h must be a number between 1 and 80")
        # A full week is `v` hours: the default workday becomes v/5 (per-day overrides stay as
        # set) and the alternative column shows the other common basis.
        db.set_setting(c.conn, "base_week_h", str(float(v)))
        db.set_setting(c.conn, "default_expected_h", str(float(v) / 5))
        db.set_setting(c.conn, "alt_week_h", "35.0" if abs(float(v) - 40) < 1e-9 else "40.0")
    return _settings(c.conn)


@router.get("/api/heatmap")
def heatmap(start: str | None = None, end: str | None = None, c: Ctx = Depends(ctx)):
    c.auto_close()
    start, end = _export_range(c, start, end)
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
    start, end = _date_arg(start, "start"), _date_arg(end, "end")
    exps = expect.expected_between(c.conn, start, end, c.holidays, expect.first_logged_day(c.conn))
    return [dataclasses.asdict(e) for e in exps.values()]


@router.put("/api/days/{date}")
def put_day(date: str, body: dict = Body(...), c: Ctx = Depends(ctx)):
    date = _date_arg(date)
    try:
        expected = float(body["expected_h"])
        sick = float(body.get("sick_h") or 0)
    except (KeyError, TypeError, ValueError):
        raise ApiError("expected_h (number) is required; sick_h must be a number")
    if not (math.isfinite(expected) and math.isfinite(sick)):
        raise ApiError("expected_h and sick_h must be finite numbers")
    e = DayExpectation(date, expected, sick, str(body.get("reason") or ""), "manual")
    db.set_expectation(c.conn, e)
    return dataclasses.asdict(db.get_expectation(c.conn, date))


@router.delete("/api/days/{date}")
def delete_day(date: str, c: Ctx = Depends(ctx)):
    db.delete_expectation(c.conn, _date_arg(date))
    return {"ok": True}


# ---- export -----------------------------------------------------------------

def _export_range(c: Ctx, start, end) -> tuple[str, str]:
    end = _date_arg(end, "end") if end else c.today.isoformat()
    start = _date_arg(start, "start") if start else (
        expect.first_logged_day(c.conn) or c.today.isoformat())
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

@router.post("/api/import")
def import_file(file: UploadFile = File(...), mode: str = Form("merge"),
                dry_run: str = Form("0"), workdays: str = Form("0"), c: Ctx = Depends(ctx)):
    if mode not in ("merge", "replace"):
        raise ApiError(f"invalid mode: {mode!r}")
    name = file.filename or ""
    if not name.lower().endswith((".xlsx", ".csv")):
        raise ApiError(f"unsupported file type: {name!r} (use .xlsx or .csv)")
    try:
        parsed = xlsx_io.parse_rows(file.file, name)
    except Exception as e:
        raise ApiError(f"could not read file: {e}")
    if dry_run == "1":
        would_update = would_delete = 0
        if mode == "merge":
            would_update = sum(
                1 for b in parsed.blocks if c.conn.execute(
                    "SELECT 1 FROM blocks WHERE date = ? AND start = ? LIMIT 1",
                    (b.date, b.start)).fetchone())
        elif parsed.blocks:
            lo, hi = min(b.date for b in parsed.blocks), max(b.date for b in parsed.blocks)
            would_delete = c.conn.execute(
                "SELECT COUNT(*) FROM blocks WHERE date BETWEEN ? AND ?", (lo, hi)).fetchone()[0]
        return {"would_insert": len(parsed.blocks) - would_update, "would_update": would_update,
                "would_delete": would_delete, "skipped": parsed.skipped,
                "errors": list(parsed.errors)}
    res = xlsx_io.import_blocks(c.conn, parsed, mode)
    if workdays == "1":
        res["workdays_rows"] = xlsx_io.import_workdays(c.conn, parsed, c.holidays)
    return res
