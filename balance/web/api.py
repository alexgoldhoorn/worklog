"""JSON API. Reads the store, the snapshots the host jobs write, and two read-only
input files (work calendar, plan.csv); writes only to the store."""
import os
from datetime import date as _date, timedelta

from fastapi import APIRouter, Body, Request

from worklog.validate import date_arg, is_hhmm as _is_hhmm, optional_date as _date_arg
from .. import db, inputs, propose as prop
from fastapi.responses import PlainTextResponse
from worklog.web.api import ApiError  # noqa: F401  (one shared class; re-exported)

router = APIRouter(prefix="/api/balance")

def _conn(request: Request):
    path = request.app.state.settings.balance_db_path
    if not path:
        raise ApiError("balance store not configured", 503)
    return db.connect(path, check_same_thread=False)


def _state(request: Request) -> str:
    path = request.app.state.settings.balance_state_dir
    if not path:
        raise ApiError("balance state directory not configured", 503)
    return path


def _monday(d: _date) -> _date:
    return d - timedelta(days=d.weekday())


@router.get("/week")
def week(request: Request, start: str | None = None):
    today = request.app.state.clock().date()
    mon = _monday(_date_arg(start, today))
    sun = mon + timedelta(days=6)
    st = _state(request)
    conn = _conn(request)
    try:
        settings = db.get_settings(conn)
        blocks = db.blocks_between(conn, mon.isoformat(), sun.isoformat())
    finally:
        conn.close()
    personal = inputs.read_json(os.path.join(st, "personal.json"), {})
    pevents = [e for e in personal.get("events", []) if mon.isoformat() <= e["date"] <= sun.isoformat()]
    work = inputs.read_work_calendar(mon, sun, path=request.app.state.settings.calendar_db_path or inputs.WORK_CALENDAR_DB)
    gate = inputs.read_json(os.path.join(st, "gate.json"), {})
    return {
        "today": today.isoformat(), "start": mon.isoformat(), "end": sun.isoformat(),
        "days": [(mon + timedelta(days=i)).isoformat() for i in range(7)],
        "work": work, "personal": pevents, "blocks": blocks, "settings": settings,
        "gate": gate, "sync": inputs.read_json(os.path.join(st, "sync.json"), {}),
        "goals": inputs.read_json(os.path.join(st, "goals.json"), {}),
        "history": _history(st, 28),
    }


def _history(state_dir: str, days: int) -> list[dict]:
    out = []
    try:
        with open(os.path.join(state_dir, "gate_history.jsonl")) as f:
            lines = f.readlines()[-days:]
        import json
        for line in lines:
            try:
                r = json.loads(line)
                out.append({"date": r.get("date"), "colour": r.get("colour"),
                            "signals": [s.get("name") for s in r.get("signals", [])]})
            except ValueError:
                continue
    except OSError:
        pass
    return out


@router.post("/blocks/{block_id}/approve")
def approve(request: Request, block_id: int):
    return _decide(request, block_id, "approved")


@router.post("/blocks/{block_id}/reject")
def reject(request: Request, block_id: int):
    return _decide(request, block_id, "rejected")


def _decide(request, block_id, state):
    conn = _conn(request)
    try:
        try:
            return db.decide(conn, block_id, state)
        except KeyError:
            raise ApiError("no such block", 404)
    finally:
        conn.close()


@router.post("/blocks")
def add_block(request: Request, body: dict = Body(...)):
    for k in ("date", "start", "end", "kind", "title"):
        if not body.get(k):
            raise ApiError(f"{k} is required")
    if not _is_hhmm(body["start"]) or not _is_hhmm(body["end"]) or body["end"] <= body["start"]:
        raise ApiError("start/end must be HH:MM with end after start")
    day = date_arg(body["date"])
    if not isinstance(body["title"], str) or not isinstance(body["kind"], str):
        raise ApiError("kind and title must be text")
    conn = _conn(request)
    try:
        try:
            bid = db.add_block(conn, day, body["start"], body["end"], body["kind"],
                               body["title"][:120], note=str(body.get("note", ""))[:300],
                               source="manual", state="approved")
        except ValueError as e:
            raise ApiError(str(e))
        return db.get_block(conn, bid)
    finally:
        conn.close()


@router.post("/propose")
def propose_week(request: Request, body: dict = Body(default={})):
    today = request.app.state.clock().date()
    start = _date_arg(body.get("start"), today + timedelta(days=1))
    end = _date_arg(body.get("end"), _monday(start) + timedelta(days=6))
    if end < start or (end - start).days > 14:
        raise ApiError("range must be 1-15 days")
    plan = inputs.read_plan()
    days = prop.week_days(start, end)
    busy = inputs.read_work_calendar(start, end, path=request.app.state.settings.calendar_db_path or inputs.WORK_CALENDAR_DB)
    conn = _conn(request)
    try:
        created = prop.propose(conn, days, plan, busy, "manual", personal=inputs.personal_events(_state(request)))
    finally:
        conn.close()
    return {"created": created, "plan_days": len([r for r in plan if start <= r["date"] <= end])}


@router.get("/outlook", response_class=PlainTextResponse)
def outlook(request: Request, start: str | None = None):
    today = request.app.state.clock().date()
    mon = _monday(_date_arg(start, today))
    sun = mon + timedelta(days=6)
    conn = _conn(request)
    try:
        blocks = db.blocks_between(conn, mon.isoformat(), sun.isoformat(), states=("approved",))
    finally:
        conn.close()
    return outlook_text(blocks)


def outlook_text(blocks: list[dict]) -> str:
    if not blocks:
        return "No approved blocks this week."
    lines = ["Please block these in Outlook as Focus time (show as Busy, no reminder):", ""]
    for b in blocks:
        d = _date.fromisoformat(b["date"])
        lines.append(f"{d.strftime('%a %d/%m')} {b['start']}–{b['end']}  {b['title']}")
    return "\n".join(lines)


@router.get("/settings")
def get_settings(request: Request):
    conn = _conn(request)
    try:
        return db.get_settings(conn)
    finally:
        conn.close()


@router.put("/settings")
def put_settings(request: Request, body: dict = Body(...)):
    clean = {}
    for k, v in body.items():
        try:
            clean[k] = db.normalise_setting(k, v)
        except ValueError as e:
            raise ApiError(str(e))
    conn = _conn(request)
    try:
        for k, v in clean.items():
            db.set_setting(conn, k, v)
        return db.get_settings(conn)
    finally:
        conn.close()


# ---- write queue -------------------------------------------------------------

@router.get("/queue")
def queue_list(request: Request):
    conn = _conn(request)
    try:
        return {"pending": db.queue_pending(conn), "recent": db.queue_recent(conn)}
    finally:
        conn.close()


def _queue_set(request: Request, qid: int, status: str) -> dict:
    conn = _conn(request)
    try:
        if not conn.execute("SELECT 1 FROM queue WHERE id=?", (qid,)).fetchone():
            raise ApiError("no such queue item", 404)
        return db.queue_retry(conn, qid) if status == "pending" else db.queue_mark(conn, qid, status)
    finally:
        conn.close()


@router.post("/queue/{qid}/retry")
def queue_retry(request: Request, qid: int):
    return _queue_set(request, qid, "pending")


@router.post("/queue/{qid}/dismiss")
def queue_dismiss(request: Request, qid: int):
    return _queue_set(request, qid, "dismissed")
