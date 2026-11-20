"""Timer transitions over the blocks table, with lazy auto-close of forgotten blocks."""
from datetime import datetime, time, timedelta

from . import db, model, tzutil
from .db import Block


# Before this hour a block dated yesterday counts as a late-night session still in progress:
# auto_close leaves it open, and an explicit stop/pause/switch splits it at midnight.
LATE_NIGHT_END = time(6, 0)


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
    if now.time() < LATE_NIGHT_END:
        cutoff -= timedelta(days=1)
    rows = conn.execute(
        "SELECT id, start, start_fold FROM blocks WHERE end IS NULL AND date < ? ORDER BY date, start, id",
        (cutoff.isoformat(),)).fetchall()
    out = []
    for r in rows:
        end = max(r["start"], limit)
        # closing at its own start keeps the start's pass; a typed-style limit is the first pass
        fold = r["start_fold"] if end == r["start"] else None
        out.append(db.update_block(conn, r["id"], end=end, end_fold=fold, auto_closed=True))
    return out


def close_open(conn, now: datetime, tz=None) -> Block | None:
    """Close every open block (normally there is one) and return the newest result, if kept.

    Close the open block at the current minute; a block that would last zero minutes is
    deleted instead.

    A late-night block (dated yesterday, acted on before LATE_NIGHT_END, so auto_close left it
    open) is split at midnight: yesterday's part ends 23:59, today's part runs 00:00 to now,
    neither flagged when the block began at or after `auto_close_time`, both flagged when it
    began earlier. Any older block is closed at 23:59 and flagged auto_closed.

    With `tz` (a ZoneInfo), start and end remember which pass through a repeated hour they were
    read in (`start_fold`, `end_fold`), so a block that spans or starts in the second pass has its
    true duration; only a block that lasted zero true minutes is deleted."""
    result = None
    for r in conn.execute("SELECT id FROM blocks WHERE end IS NULL ORDER BY date, start, id").fetchall():
        result = _close_one(conn, now, db.get_block(conn, r["id"]), tz)
    return result


def _close_one(conn, now: datetime, ob: Block, tz=None) -> Block | None:
    today, hhmm = now_parts(now)
    if ob.date < today:
        yesterday = (now.date() - timedelta(days=1)).isoformat()
        if ob.date == yesterday and now.time() < LATE_NIGHT_END:
            # A block that began before the auto-close time was probably forgotten, not worked
            # through the night: both parts are flagged so the user confirms them.
            flag = ob.start < db.setting(conn, "auto_close_time")
            db.update_block(conn, ob.id, end="23:59", auto_closed=flag)
            if model.minutes("00:00", hhmm) == 0:
                return db.get_block(conn, ob.id)
            part = Block(None, today, "00:00", hhmm, ob.project, ob.type, ob.client,
                         ob.billable, ob.source, flag, None, tzutil.fold_of(now, tz))
            part.id = db.insert_block(conn, part)
            return db.get_block(conn, part.id)
        return db.update_block(conn, ob.id, end="23:59", auto_closed=True)
    fold = tzutil.fold_of(now, tz)
    if model.span_minutes(ob.date, ob.start, ob.start_fold, hhmm, fold, tz) == 0:
        db.delete_block(conn, ob.id)
        return None
    return db.update_block(conn, ob.id, end=hhmm, end_fold=fold, auto_closed=False)


def start(conn, now: datetime, type_: str | None = None, project: str | None = None,
          client: str | None = None, tz=None) -> Block:
    """Begin work. Idempotent: if the same work (type and project) is already running today,
    return it. Otherwise close whatever runs and open a new block. Billable comes from the
    client's flag; an unknown client leaves it NULL."""
    today, hhmm = now_parts(now)
    auto_close(conn, now)
    type_ = _norm(type_) or db.setting(conn, "default_type")
    project = _norm(project)
    ob = db.open_block(conn)
    if (ob and ob.date == today
            and model.work_type(ob.type, db.break_types(conn)) == "work"
            and _norm(ob.type) == type_ and _norm(ob.project) == project):
        return ob
    close_open(conn, now, tz)
    client = _norm(client) or db.setting(conn, "default_client")
    row = db.clients(conn).get(client)
    billable = bool(row["billable"]) if row is not None else None
    b = Block(None, today, hhmm, None, project, type_, client, billable, "timer",
              start_fold=tzutil.fold_of(now, tz))
    b.id = db.insert_block(conn, b)
    return b


def pause(conn, now: datetime, type_: str | None = None, tz=None) -> Block:
    """Begin a break of `type_` (default `default_break_type`); idempotent like `start`."""
    today, hhmm = now_parts(now)
    auto_close(conn, now)
    type_ = _norm(type_) or db.setting(conn, "default_break_type")
    ob = db.open_block(conn)
    if (ob and ob.date == today
            and model.work_type(ob.type, db.break_types(conn)) == "other"
            and _norm(ob.type) == type_):
        return ob
    close_open(conn, now, tz)
    b = Block(None, today, hhmm, None, None, type_, None, None, "timer",
              start_fold=tzutil.fold_of(now, tz))
    b.id = db.insert_block(conn, b)
    return b


def stop(conn, now: datetime, tz=None) -> Block | None:
    """Close the open block. Returns the closed block, or the last one auto-closed if that is
    all there was; None when nothing ran (or the block was zero minutes and was deleted)."""
    closed = auto_close(conn, now)
    return close_open(conn, now, tz) or (closed[-1] if closed else None)


def status(conn, now: datetime, tz=None) -> dict:
    """State (`working`, `break`, `stopped`) plus elapsed time. Runs auto_close first, so a
    block forgotten overnight is closed by whoever looks next, and reported in `auto_closed`.
    `elapsed_min` is minute-granular (matches the stored times); `elapsed_s` feeds the ticker. With `tz` both are
    true elapsed time across a daylight-saving change."""
    today, hhmm = now_parts(now)
    closed = auto_close(conn, now)
    bt = db.break_types(conn)
    ob = db.open_block(conn)
    elapsed_s = None
    if ob is None:
        state, block, since, elapsed = "stopped", None, None, None
    else:
        d = model.with_derived(ob, bt, tz)
        state = "working" if d["work_type"] == "work" else "break"
        started = tzutil.reading(ob.date, ob.start, ob.start_fold)
        block, since = d, ob.start
        elapsed = int(tzutil.elapsed_seconds(started, now.replace(second=0, microsecond=0), tz) // 60)
        elapsed_s = max(0, int(tzutil.elapsed_seconds(started, now.replace(microsecond=0), tz)))
    return {"state": state, "block": block, "since": since, "elapsed_min": elapsed, "elapsed_s": elapsed_s,
            "date": today, "auto_closed": [model.with_derived(b, bt, tz) for b in closed]}
