"""/api/day: the day model plus the writes the Day page makes. Writes that need credentials
(Todoist, the annotation overlay) go to the balance queue; prep notes are stored directly."""
import os
import re
from datetime import date as _date, timedelta

from fastapi import APIRouter, Body, Depends, File, Request, UploadFile

from balance import db as bdb
from worklog import calendar as wcal, db as wdb
from worklog.web.api import ApiError, Ctx, _status, ctx as worklog_ctx

from . import holidays, model, outlook, rules, slots as _slots
from .sources import Context

_EMAIL = re.compile(r"\S+@\S+\.\S+")
TARGETS = ("personal", "family", "work", "training", "todoist")

router = APIRouter(prefix="/api/day")
_HHMM = re.compile(r"^([01]\d|2[0-3]):[0-5]\d$")
def _owners() -> tuple:
    h = rules.household(rules.load())
    return (h["me"], h["partner"])


def _bconn(request: Request):
    path = request.app.state.settings.balance_db_path
    if not path:
        raise ApiError("balance store not configured", 503)
    return bdb.connect(path, check_same_thread=False)


def _state_dir(request: Request) -> str:
    return request.app.state.settings.balance_state_dir or ""


def _flag_dir(request: Request) -> str:
    """Where the sync_now flag goes: beside the store (the state dir is read-only in the container)."""
    return os.path.dirname(request.app.state.settings.balance_db_path or "") or "."


def _date_arg(s: str | None, default: _date) -> _date:
    if not s:
        return default
    try:
        return _date.fromisoformat(s)
    except ValueError:
        raise ApiError("date must be YYYY-MM-DD")


def _event_fields(body: dict) -> tuple[str, str, str]:
    d, start, title = body.get("date", ""), body.get("start", ""), (body.get("title") or "").strip()
    if not d:
        raise ApiError("date required")
    _date_arg(d, None)
    if not _HHMM.match(start or ""):
        raise ApiError("start must be HH:MM")
    if not title or len(title) > 200:
        raise ApiError("title required (max 200)")
    return d, start, title


def _day_ctx(request: Request, c: Ctx, conn, d: _date) -> Context:
    c.auto_close()
    return Context(date=d, now=c.now, state_dir=_state_dir(request), balance_conn=conn,
                   plan_path=c.settings.plan_path, holidays=holidays.school_holidays(c.settings.holidays_path),
                   rules=rules.load(), worklog_status=_status(c), balance_settings=bdb.get_settings(conn),
                   client_holidays=c.holidays)


@router.get("")
def get_day(request: Request, date: str | None = None, c: Ctx = Depends(worklog_ctx)):
    d = _date_arg(date, c.today)
    conn = _bconn(request)
    try:
        out = model.build_day(_day_ctx(request, c, conn, d))
    finally:
        conn.close()
    iso = d.isoformat()
    props, _ = wcal.proposals(c.settings.calendar_db_path, iso, wdb.blocks_on(c.conn, iso))
    dismissed = wdb.dismissed_on(c.conn, iso)
    out["work"]["proposals"] = [p for p in props if (p["start"], p["title"] or "") not in dismissed]
    return out


# ---- plan 2: slots, move, find --------------------------------------------------

def _item(body: dict) -> _slots.Item:
    raw = body.get("item") or {}
    title = (raw.get("title") or "").strip()
    if not title or len(title) > 200:
        raise ApiError("item.title required (max 200)")
    try:
        minutes = int(raw.get("minutes", 60))
    except (TypeError, ValueError):
        raise ApiError("item.minutes must be a number")
    if not 5 <= minutes <= 480:
        raise ApiError("item.minutes must be 5–480")
    kind = raw.get("kind") or "personal"
    if kind not in ("run", "gym", "meeting", "personal", "work"):
        raise ApiError("item.kind must be run, gym, meeting, personal or work")
    prefer = [p for p in (raw.get("prefer") or []) if p in ("morning", "afternoon", "evening", "not_school_runs")]
    return _slots.Item(title=title, minutes=minutes, kind=kind, travel_before=int(raw.get("travel_before") or 0),
                       travel_after=int(raw.get("travel_after") or 0), prefer=prefer, ref=raw.get("ref") or body.get("ref"))


def _range(body: dict, today: _date) -> list[str]:
    lo = _date_arg(body.get("from"), today)
    hi = _date_arg(body.get("to"), lo)
    if hi < lo or (hi - lo).days > 20:
        raise ApiError("from/to must span at most 21 days")
    return [(lo + timedelta(days=i)).isoformat() for i in range((hi - lo).days + 1)]


def _slot_fields(body: dict) -> tuple[str, str, str]:
    d = body.get("date") or ""
    if not d:
        raise ApiError("date required")
    _date_arg(d, None)
    start, end = body.get("start") or "", body.get("end") or ""
    if not (_HHMM.match(start) and _HHMM.match(end)) or end <= start:
        raise ApiError("start/end must be HH:MM with end after start")
    return d, start, end


@router.post("/slots")
def post_slots(request: Request, body: dict = Body(...), c: Ctx = Depends(worklog_ctx)):
    item = _item(body)
    dates = _range(body, c.today)
    conn = _bconn(request)
    try:
        ctx = _day_ctx(request, c, conn, c.today)
        days = model.build_days(ctx, dates)
        found = _slots.find(item, days, ctx.balance_settings, ctx.rules, c.today.isoformat(),
                            now=c.now.strftime("%H:%M"), client_holidays=c.holidays)
        return {"slots": [s.as_dict() for s in found],
                "days": {d: {"unknown": days[d]["mirror"]["unknown"], "work_day": days[d]["work_day"]} for d in dates}}
    finally:
        conn.close()


def _paste_line(d: str, start: str, end: str, title: str) -> str:
    dt = _date.fromisoformat(d)
    return f"{dt.strftime('%a')} {dt.day} {dt.strftime('%b')} {start}-{end} {title}"


@router.post("/move")
def post_move(request: Request, body: dict = Body(...)):
    ref = body.get("ref") or {}
    d, start, end = _slot_fields(body)
    writes = set(body.get("writes") or [])
    kind = ref.get("kind")
    if kind not in ("run", "block", "personal"):
        raise ApiError("ref.kind must be run, block or personal")
    if kind == "run" and ref.get("date") and ref["date"] != d:
        raise ApiError("a run keeps its date here: a date change is the trainer's call (ask the trainer)")
    conn = _bconn(request)
    flag = _flag_dir(request)
    out = {"queued": [], "blocks": [], "paste": None}
    try:
        if kind == "run":
            session = (ref.get("session") or "").strip() or "Run"
            if "session_time" in writes or not writes:
                out["queued"].append(bdb.enqueue(conn, "session_time", {"date": ref.get("date") or d, "session": session,
                                                                        "start": start, "end": end},
                                                 f"Move {session} to {d} {start}", flag_dir=flag))
            if "block" in writes:
                bid = ref.get("block_id")
                if not bid:
                    run = next((b for b in bdb.blocks_between(conn, d, d, states=("approved", "proposed")) if b["kind"] == "run"), None)
                    bid = run["id"] if run else None
                if bid:
                    try:
                        out["blocks"].append(bdb.move_block(conn, int(bid), d, start, end))
                    except (KeyError, ValueError) as e:
                        raise ApiError(f"block: {e}", 409)
        elif kind == "block":
            if not ref.get("block_id"):
                raise ApiError("ref.block_id required")
            try:
                out["blocks"].append(bdb.move_block(conn, int(ref["block_id"]), d, start, end))
            except KeyError:
                raise ApiError("no such block", 404)
            except ValueError as e:
                raise ApiError(str(e), 409)
        else:
            if not ref.get("uid"):
                raise ApiError("ref.uid required to move a calendar event")
            h = rules.household(rules.load())
            out["queued"].append(bdb.enqueue(conn, "gcal_update", {"calendar": ref.get("calendar") or h["calendars"]["personal"], "uid": ref["uid"],
                                                                   "orig_date": ref.get("date") or d, "orig_start": ref.get("start") or "",
                                                                   "date": d, "start": start, "end": end, "tz": h["timezone"]},
                                             f"Move {ref.get('title') or 'event'} to {d} {start}", flag_dir=flag))
        if "mirror_busy" in writes:
            out["paste"] = _paste_line(d, start, end, "Busy")
        return out
    finally:
        conn.close()


@router.post("/find")
def post_find(request: Request, body: dict = Body(...)):
    item = _item(body)
    d, start, end = _slot_fields(body)
    target = body.get("target")
    if target not in TARGETS:
        raise ApiError(f"target must be one of {', '.join(TARGETS)}")
    conn = _bconn(request)
    flag = _flag_dir(request)
    out = {"queued": [], "blocks": [], "paste": None}
    try:
        if target in ("personal", "family"):
            h = rules.household(rules.load())
            cal = h["calendars"]["family"] if target == "family" else h["calendars"]["personal"]
            out["queued"].append(bdb.enqueue(conn, "gcal_create", {"calendar": cal, "date": d, "start": start, "end": end,
                                                                   "title": item.title, "description": "from the Day dashboard",
                                                                   "tz": h["timezone"]},
                                             f"{item.title} on {cal} {d} {start}", flag_dir=flag))
        elif target == "work":
            if _EMAIL.search(item.title):
                raise ApiError("email addresses are never stored in the work calendar")
            out["queued"].append(bdb.enqueue(conn, "mirror_add", {"date": d, "start": start, "end": end, "title": item.title},
                                             f"Work: {item.title} {d} {start}", flag_dir=flag))
            out["paste"] = _paste_line(d, start, end, item.title)
        elif target == "training":
            bid = bdb.add_block(conn, d, start, end, "run" if item.kind == "run" else "other", item.title,
                                note="from Find a date", state="approved", source="manual")
            out["blocks"].append(bdb.get_block(conn, bid))
        else:
            td = body.get("todoist") or {}
            if not (td.get("project") and td.get("priority") and td.get("due_string")):
                raise ApiError("todoist needs project, priority and due_string (the task policy)")
            out["queued"].append(bdb.enqueue(conn, "todoist_add", {"content": item.title, "project": td["project"],
                                                                   "priority": int(td["priority"]), "due_string": td["due_string"],
                                                                   "labels": td.get("labels") or []},
                                             f"Todoist: {item.title}", flag_dir=flag))
        return out
    finally:
        conn.close()


@router.post("/prep")
def post_prep(request: Request, body: dict = Body(...)):
    d, start, title = _event_fields(body)
    try:
        minutes = int(body.get("minutes", 0))
    except (TypeError, ValueError):
        raise ApiError("minutes must be a number")
    if not 0 <= minutes <= 480:
        raise ApiError("minutes must be 0–480")
    text = (body.get("text") or "").strip()[:500]
    conn = _bconn(request)
    try:
        return {"prep": bdb.set_prep_note(conn, d, start, title, minutes, text)}
    finally:
        conn.close()


@router.post("/owner")
def post_owner(request: Request, body: dict = Body(...)):
    d, start, title = _event_fields(body)
    owner = body.get("owner")
    owners = _owners()
    h = rules.household(rules.load())
    if owner not in owners and owner not in h["me_aliases"]:
        raise ApiError(f"owner must be one of {', '.join(owners)}")
    stored = "you" if owner == h["me"] or owner in h["me_aliases"] else owner   # the overlay convention (PA): "you" = me
    conn = _bconn(request)
    try:
        row = bdb.enqueue(conn, "annotate", {"date": d, "start": start, "title": title, "owner": stored},
                          f"{title} {d}: {owner}", flag_dir=_flag_dir(request))
        return {"queued": row}
    finally:
        conn.close()


# ---- plan 3: work-calendar catch-up ------------------------------------------------

@router.post("/workcal/parse")
def post_workcal_parse(body: dict = Body(...), c: Ctx = Depends(worklog_ctx)):
    """Read pasted Outlook lines; never writes. Rows come back with ok/error per line."""
    text = str(body.get("text") or "")[:20000]
    return {"rows": outlook.parse_lines(text, year=c.today.year, today=c.today)}


def _mirror_row(ev: dict) -> dict:
    d, start, end = ev.get("date") or "", ev.get("start") or "", ev.get("end") or ""
    if not d:
        raise ApiError("date required")
    _date_arg(d, None)
    if not (_HHMM.match(start) and (not end or _HHMM.match(end))) or (end and end <= start):
        raise ApiError("start/end must be HH:MM with end after start")
    title = (ev.get("title") or "").strip()
    if not title or len(title) > 200:
        raise ApiError("title required (max 200)")
    if _EMAIL.search(title) or _EMAIL.search(str(ev.get("note") or "")):
        raise ApiError("email addresses are never stored in the work calendar")
    return {"date": d, "start": start, "end": end or None, "title": title, "note": (ev.get("note") or "").strip()[:500]}


@router.post("/workcal/add")
def post_workcal_add(request: Request, body: dict = Body(...)):
    rows = body.get("events") or []
    if not rows or len(rows) > 50:
        raise ApiError("1–50 meetings per paste")
    events = [_mirror_row(ev) for ev in rows]
    conn = _bconn(request)
    try:
        line = f"Work calendar: {len(events)} meeting{'s' if len(events) != 1 else ''} pasted ({events[0]['date']}…)"
        return {"queued": bdb.enqueue(conn, "mirror_bulk_add", {"events": events}, line, flag_dir=_flag_dir(request))}
    finally:
        conn.close()


@router.post("/workcal/annotate")
def post_workcal_annotate(request: Request, body: dict = Body(...)):
    d, start, title = _event_fields(body)
    status, note = body.get("status"), body.get("note")
    if status not in (None, "confirmed", "cancelled"):
        raise ApiError("status must be confirmed or cancelled")
    if note is not None and _EMAIL.search(str(note)):
        raise ApiError("email addresses are never stored in the work calendar")
    if status is None and note is None:
        raise ApiError("nothing to change")
    conn = _bconn(request)
    try:
        payload = {"date": d, "start": start, "title": title}
        if status is not None:
            payload["status"] = status
        if note is not None:
            payload["note"] = str(note).strip()[:500]
        what = status or "note"
        return {"queued": bdb.enqueue(conn, "mirror_annotate", payload, f"Work calendar: {title} {d} {start} → {what}", flag_dir=_flag_dir(request))}
    finally:
        conn.close()


@router.post("/classify")
def post_classify(request: Request, body: dict = Body(...)):
    """Whose is this Family-calendar event: mine | family | partner | child. Stored per occurrence
    in balance.db (read at once by the model and the engine); `always` adds a per-title rule;
    `partner` also tells the PA's overlay (tier context) through the queue."""
    d, start, title = _event_fields(body)
    cls = body.get("cls")
    if cls not in bdb.CLASSES:
        raise ApiError(f"cls must be one of {', '.join(bdb.CLASSES)}")
    conn = _bconn(request)
    try:
        row = bdb.set_event_class(conn, d, start, title, cls)
        rule = bdb.add_family_rule(conn, title, cls) if body.get("always") else None
        # the PA's overlay follows: context for the partner's own events, cleared for everything else
        tier = "context" if cls == "partner" else ""
        queued = bdb.enqueue(conn, "annotate", {"date": d, "start": start, "title": title, "tier": tier},
                             f"{title} {d}: {'context (partner\'s)' if tier else 'needs me'}", flag_dir=_flag_dir(request))
        return {**row, "rule": rule, "queued": queued}
    finally:
        conn.close()


@router.get("/classify/rules")
def get_classify_rules(request: Request):
    conn = _bconn(request)
    try:
        return {"rules": bdb.family_rules(conn)}
    finally:
        conn.close()


@router.delete("/classify/rules/{rule_id}")
def delete_classify_rule(request: Request, rule_id: int):
    conn = _bconn(request)
    try:
        if not bdb.delete_family_rule(conn, rule_id):
            raise ApiError("no such rule", 404)
        return {"ok": True}
    finally:
        conn.close()


@router.post("/task/{task_id}/complete")
def post_complete(request: Request, task_id: str):
    if not re.match(r"^[A-Za-z0-9_-]{1,64}$", task_id):
        raise ApiError("bad task id")
    conn = _bconn(request)
    try:
        row = bdb.enqueue(conn, "todoist_complete", {"task_id": task_id}, f"Done: task {task_id}",
                          flag_dir=_flag_dir(request))
        return {"queued": row}
    finally:
        conn.close()


@router.post("/calendar-pdf")
async def post_calendar_pdf(request: Request, file: UploadFile = File(...)):
    """Save an Outlook calendar export into the work-calendar inbox; the Work Calendar Inbox
    job (every 15 min) imports it into the mirror. The file is checked, never parsed here."""
    inbox = request.app.state.settings.calendar_inbox
    if not inbox:
        raise ApiError("calendar inbox not configured", 503)
    name = os.path.basename(file.filename or "")
    if not name.lower().endswith(".pdf"):
        raise ApiError("only an Outlook calendar PDF export is accepted")
    data = await file.read(12 * 1024 * 1024 + 1)
    if len(data) > 12 * 1024 * 1024:
        raise ApiError("file too large (12 MB max)")
    if not data.startswith(b"%PDF"):
        raise ApiError("that is not a PDF")
    safe = re.sub(r"[^A-Za-z0-9._ ()-]+", "_", name)[:120] or "calendar.pdf"
    stamp = _date.today().isoformat()
    target = os.path.join(inbox, f"{stamp}_{safe}")
    try:
        with open(target, "wb") as f:
            f.write(data)
    except OSError as e:
        raise ApiError(f"could not save into the inbox: {e}", 503)
    return {"saved": os.path.basename(target), "note": "imported into the work calendar within 15 minutes"}


@router.post("/refresh")
def post_refresh(request: Request):
    from balance import inputs
    ok = bdb.touch_sync_now(_flag_dir(request))
    return {"ok": ok, "sync": inputs.read_json(os.path.join(_state_dir(request), "sync.json"), {}),
            "error": None if ok else "could not write the sync flag; the next full sync runs within 15 minutes"}
