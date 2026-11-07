"""Meeting proposals from the (read-only) work calendar database."""
import os
import sqlite3

def _covers(block, m_start, m_end):
    """A closed block hides a meeting it overlaps. A running block hides only the meeting it began
    during (it *is* that meeting, or came after it); an upcoming or in-progress meeting under a
    longer work block stays proposed so it can still be added."""
    if block.end is None:
        return m_start <= block.start < m_end
    return m_start < block.end and m_end > block.start


def _unavailable(reason):
    return [], f"calendar unavailable: {reason}"


def proposals(cal_db_path, date, blocks):
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
    for start, end, title, status in rows:
        if not end or not start or (status or "").lower() == "cancelled":
            continue
        if any(_covers(b, start, end) for b in blocks):
            continue
        out.append({"start": start, "end": end, "title": title})
    out.sort(key=lambda p: p["start"])
    return out, None
