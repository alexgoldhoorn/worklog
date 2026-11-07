"""JSON snapshots of two host-side SQLite stores the container never mounts: the work
calendar mirror (BALANCE_CALENDAR_DB) and the annotation overlay
(BALANCE_ANNOTATIONS_DB). balance_sync writes them into the state dir."""
import os
import sqlite3
from datetime import date, datetime, timedelta

HAND_SOURCES = ("dashboard", "pa", "manual")   # import ranges that are not a PDF/bulk import


def _now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def _ro(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def mirror_snapshot(db_path: str, lo: date, hi: date) -> dict:
    """Events in [lo, hi] (cancelled ones included, with their status) plus the coverage of
    the last real import. A missing file gives an empty snapshot with a warning."""
    out = {"events": [], "coverage": {"last_import_end": None, "last_import_at": None, "last_import_source": "",
                                      "ranges": []}, "taken": _now()}
    if not os.path.exists(db_path):
        out["warning"] = f"{db_path} missing"
        return out
    conn = _ro(db_path)
    try:
        out["events"] = [dict(r) for r in conn.execute(
            "SELECT id, date, start, end, title, organizer, status, note, source, updated_at FROM events"
            " WHERE date BETWEEN ? AND ? ORDER BY date, start", (lo.isoformat(), hi.isoformat()))]
        marks = ",".join("?" * len(HAND_SOURCES))
        r = conn.execute(f"SELECT end, imported_at, source FROM imports WHERE COALESCE(source,'') NOT IN ({marks})"
                         " ORDER BY end DESC, imported_at DESC LIMIT 1", HAND_SOURCES).fetchone()
        if r:
            out["coverage"].update({"last_import_end": r["end"], "last_import_at": r["imported_at"],
                                    "last_import_source": r["source"] or ""})
        out["coverage"]["ranges"] = [[x["start"], x["end"]] for x in conn.execute(
            f"SELECT start, end FROM imports WHERE COALESCE(source,'') NOT IN ({marks}) ORDER BY start, end", HAND_SOURCES)]
    finally:
        conn.close()
    return out


def annotations_snapshot(db_path: str) -> dict:
    out = {"one_off": [], "recurring": [], "taken": _now()}
    if not os.path.exists(db_path):
        out["warning"] = f"{db_path} missing"
        return out
    conn = _ro(db_path)
    try:
        out["one_off"] = [dict(r) for r in conn.execute(
            "SELECT date, start, title, owner, tier, note FROM one_off ORDER BY date, start")]
        out["recurring"] = [dict(r) for r in conn.execute("SELECT pattern, tier, note FROM recurring ORDER BY id")]
    finally:
        conn.close()
    return out


def school_days_snapshot(lo: date, hi: date, status_fn=None, rules: dict | None = None) -> dict:
    """The child's school calendar per date: status school | off (closure or free day, named)
    | unknown. `status_fn(date, rules) -> (status, name)` is personal.holidays.school_status on the
    host; a missing function or a crash yields an empty snapshot with a warning, never an exception."""
    out = {"from": lo.isoformat(), "to": hi.isoformat(), "days": {}, "taken": _now()}
    if status_fn is None or rules is None:
        out["warning"] = "school calendar not available"
        return out
    d = lo
    try:
        while d <= hi:
            status, name = status_fn(d, rules)
            out["days"][d.isoformat()] = {"status": status, "name": name or ""}
            d = d + timedelta(days=1)
    except Exception as e:  # noqa: BLE001
        out["warning"] = f"school calendar: {e}"
        out["days"] = {}
    return out
