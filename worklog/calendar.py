"""Meeting proposals from the (read-only) work calendar database."""
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


def proposals(cal_db_path, date, blocks):
    """(proposals, warning) for one day: the meetings() no meeting block covers yet."""
    found, warn = meetings(cal_db_path, date, blocks)
    return [{"start": m["start"], "end": m["end"], "title": m["title"]} for m in found if not m["logged"]], warn


def meetings(cal_db_path, date, blocks):
    """(meetings, warning) for one day: every calendar meeting that is not cancelled, with
    `logged` telling whether a meeting block covers it already.
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
    out = []
    resumed_at = {b.end for b in blocks if b.source == "calendar" and b.end}
    for start, end, title, status in rows:
        if not end or not start or (status or "").lower() == "cancelled":
            continue
        out.append({"start": start, "end": end, "title": title,
                    "logged": any(_covers(b, start, end, resumed_at) for b in blocks)})
    out.sort(key=lambda p: p["start"])
    return out, None
