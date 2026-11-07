"""Timer transitions over the blocks table, with lazy auto-close of forgotten blocks."""
from datetime import datetime, time, timedelta

from . import db, model
from .db import Block


def now_parts(now: datetime) -> tuple[str, str]:
    return now.strftime("%Y-%m-%d"), now.strftime("%H:%M")


def _norm(v: str | None) -> str | None:
    v = (v or "").strip()
    return v or None


def auto_close(conn, now: datetime) -> list[Block]:
    """Close every open block dated before today; zero-minute blocks are kept, flagged.

    A block dated yesterday is left open before 06:00 (late-night session in progress).
    """
    limit = db.setting(conn, "auto_close_time")
    cutoff = now.date()
    if now.time() < time(6, 0):
        cutoff -= timedelta(days=1)
    rows = conn.execute(
        "SELECT id, start FROM blocks WHERE end IS NULL AND date < ? ORDER BY date, start, id",
        (cutoff.isoformat(),)).fetchall()
    return [db.update_block(conn, r["id"], end=max(r["start"], limit), auto_closed=True) for r in rows]


def close_open(conn, now: datetime) -> Block | None:
    ob = db.open_block(conn)
    if ob is None:
        return None
    today, hhmm = now_parts(now)
    auto = ob.date < today
    end = "23:59" if auto else hhmm
    if not auto and model.minutes(ob.start, end) == 0:
        db.delete_block(conn, ob.id)
        return None
    return db.update_block(conn, ob.id, end=end, auto_closed=auto)


def start(conn, now: datetime, type_: str | None = None, project: str | None = None,
          client: str | None = None) -> Block:
    today, hhmm = now_parts(now)
    auto_close(conn, now)
    type_ = _norm(type_) or db.setting(conn, "default_type")
    project = _norm(project)
    ob = db.open_block(conn)
    if (ob and ob.date == today
            and model.work_type(ob.type, db.break_types(conn)) == "work"
            and _norm(ob.type) == type_ and _norm(ob.project) == project):
        return ob
    close_open(conn, now)
    client = _norm(client) or db.setting(conn, "default_client")
    row = db.clients(conn).get(client)
    billable = bool(row["billable"]) if row is not None else None
    b = Block(None, today, hhmm, None, project, type_, client, billable, "timer")
    b.id = db.insert_block(conn, b)
    return b


def pause(conn, now: datetime, type_: str | None = None) -> Block:
    today, hhmm = now_parts(now)
    auto_close(conn, now)
    type_ = _norm(type_) or db.setting(conn, "default_break_type")
    ob = db.open_block(conn)
    if (ob and ob.date == today
            and model.work_type(ob.type, db.break_types(conn)) == "other"
            and _norm(ob.type) == type_):
        return ob
    close_open(conn, now)
    b = Block(None, today, hhmm, None, None, type_, None, None, "timer")
    b.id = db.insert_block(conn, b)
    return b


def stop(conn, now: datetime) -> Block | None:
    closed = auto_close(conn, now)
    return close_open(conn, now) or (closed[-1] if closed else None)


def status(conn, now: datetime) -> dict:
    today, hhmm = now_parts(now)
    closed = auto_close(conn, now)
    bt = db.break_types(conn)
    ob = db.open_block(conn)
    elapsed_s = None
    if ob is None:
        state, block, since, elapsed = "stopped", None, None, None
    else:
        d = model.with_derived(ob, bt)
        state = "working" if d["work_type"] == "work" else "break"
        started = datetime.fromisoformat(f"{ob.date} {ob.start}")
        block, since = d, ob.start
        elapsed = int((now.replace(second=0, microsecond=0) - started).total_seconds() // 60)
        elapsed_s = max(0, int((now.replace(microsecond=0) - started).total_seconds()))
    return {"state": state, "block": block, "since": since, "elapsed_min": elapsed, "elapsed_s": elapsed_s,
            "date": today, "auto_closed": [model.with_derived(b, bt) for b in closed]}
