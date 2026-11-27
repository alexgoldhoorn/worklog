"""Meeting proposals from the (read-only) work calendar database."""
import json
import os
import sqlite3

MEET_TYPE = "meet"   # the type a meeting added from the calendar gets


def is_meeting(block):
    """A block that stands for a meeting: added from the calendar, or typed as one by hand."""
    return block.source == "calendar" or block.type == MEET_TYPE


def _covers(block, m_start, m_end, resumed_at=()):
    """Only a meeting block covers a meeting: work or a break logged over it leaves it open to be
    added (the add cuts it out of them). A closed meeting block covers what it overlaps. A running
    one covers only the meeting it began during; one resumed at the end of an added meeting
    (`resumed_at`) is not the meeting that starts at that same minute."""
    if not is_meeting(block):
        return False
    if block.end is None:
        if block.start == m_start and block.start in resumed_at and block.source != "calendar":
            return False
        return m_start <= block.start < m_end
    return m_start < block.end and m_end > block.start


def _unavailable(reason):
    return [], f"calendar unavailable: {reason}"


def availability_warning(cal_db_path):
    """The warning proposals() would return for this path, without reading any events."""
    if not cal_db_path:
        return _unavailable("not configured")[1]
    if not os.path.isfile(cal_db_path):
        return _unavailable(f"{cal_db_path} not found")[1]
    try:
        conn = sqlite3.connect(f"file:{cal_db_path}?mode=ro", uri=True)
        try:
            conn.execute("SELECT start, end, title, status FROM events WHERE 0").fetchall()
        finally:
            conn.close()
    except (sqlite3.Error, OSError) as e:
        return _unavailable(str(e))[1]
    return None


def proposals(cal_db_path, date, blocks, queue_db_path=None):
    """(proposals, warning) for one day: the meetings() no meeting block covers yet."""
    found, warn = meetings(cal_db_path, date, blocks, queue_db_path)
    return [{"start": m["start"], "end": m["end"], "title": m["title"]} for m in found if not m["logged"]], warn


def _queued(queue_db_path, date):
    """(adds, annotations) for one day from the balance store's write queue that the host has not
    applied to the work calendar yet: the Day page's "work" adds and pasted rows (mirror_add,
    mirror_bulk_add) and its cancel/un-cancel (mirror_annotate). Read-only, best effort."""
    if not queue_db_path or not os.path.isfile(queue_db_path):
        return [], []
    try:
        conn = sqlite3.connect(f"file:{queue_db_path}?mode=ro", uri=True)
        try:
            rows = conn.execute("SELECT kind, payload FROM queue WHERE status = 'pending' AND kind IN"
                                " ('mirror_add', 'mirror_bulk_add', 'mirror_annotate') ORDER BY id").fetchall()
        finally:
            conn.close()
    except (sqlite3.Error, OSError):
        return [], []
    adds, notes = [], []
    for kind, payload in rows:
        try:
            p = json.loads(payload)
        except ValueError:
            continue
        if kind == "mirror_annotate":
            if p.get("date") == date:
                notes.append(p)
            continue
        for ev in (p.get("events") or []) if kind == "mirror_bulk_add" else [p]:
            if ev.get("date") == date and ev.get("start") and (ev.get("title") or "").strip():
                adds.append((ev["start"], ev.get("end"), ev["title"].strip(), ev.get("status")))
    return adds, notes


def meetings(cal_db_path, date, blocks, queue_db_path=None):
    """(meetings, warning) for one day: every calendar meeting that is not cancelled, with
    `logged` telling whether a meeting block covers it already. With `queue_db_path` (the balance
    store) the writes still queued for the work calendar count already; such a meeting carries
    `pending: True` until the host has applied it.
    The database is opened read-only. Any problem returns ([], reason) so the timer page
    shows a notice and keeps working."""
    if not cal_db_path:
        return _unavailable("not configured")
    if not os.path.isfile(cal_db_path):
        return _unavailable(f"{cal_db_path} not found")
    try:
        conn = sqlite3.connect(f"file:{cal_db_path}?mode=ro", uri=True)
        try:
            rows = conn.execute(
                "SELECT start, end, title, status FROM events WHERE date = ?", (date,)
            ).fetchall()
        finally:
            conn.close()
    except (sqlite3.Error, OSError) as e:
        return _unavailable(str(e))
    events = {(s, t): [s, e, t, st, False] for s, e, t, st in rows}
    adds, notes = _queued(queue_db_path, date)
    for s, e, t, st in adds:
        if (s, t) in events:   # the host upserts on (date, start, title)
            events[(s, t)][1:4] = [e, t, st or events[(s, t)][3]]   # a known row keeps its status
        else:
            events[(s, t)] = [s, e, t, st or "confirmed", True]
    for n in notes:
        ev = events.get((n.get("start"), (n.get("title") or "").strip()))
        if ev and n.get("status") in ("confirmed", "cancelled"):
            ev[3] = n["status"]
    out = []
    resumed_at = {b.end for b in blocks if b.source == "calendar" and b.end}
    for start, end, title, status, pending in events.values():
        if not end or not start or (status or "").lower() == "cancelled":
            continue
        m = {"start": start, "end": end, "title": title,
             "logged": any(_covers(b, start, end, resumed_at) for b in blocks)}
        if pending:
            m["pending"] = True
        out.append(m)
    out.sort(key=lambda p: p["start"])
    return out, None
