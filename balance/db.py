"""SQLite store for agent blocks and settings. Host jobs and the container share it."""
import re
import json
import os
import sqlite3
from datetime import datetime, timedelta

from .config import DEFAULT_SETTINGS

KINDS = ("run", "stop", "family", "other")
STATES = ("proposed", "approved", "rejected")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS blocks(
    id INTEGER PRIMARY KEY,
    date TEXT NOT NULL,            -- YYYY-MM-DD
    start TEXT NOT NULL,           -- HH:MM
    end TEXT NOT NULL,             -- HH:MM
    kind TEXT NOT NULL,            -- run | stop | family | other
    title TEXT NOT NULL,
    note TEXT NOT NULL DEFAULT '',
    state TEXT NOT NULL DEFAULT 'proposed',
    source TEXT NOT NULL DEFAULT 'propose',   -- propose | gate | manual
    gcal_event_id TEXT NOT NULL DEFAULT '',
    gcal_calendar TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    decided_at TEXT,
    synced_at TEXT
);
CREATE INDEX IF NOT EXISTS idx_blocks_date ON blocks(date);
CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS queue(
    id INTEGER PRIMARY KEY,
    created_at TEXT NOT NULL,
    kind TEXT NOT NULL,            -- handler name (balance/queue_handlers.py)
    payload TEXT NOT NULL,         -- JSON
    line TEXT NOT NULL,            -- human line shown in the UI
    status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','done','failed','dismissed')),
    error TEXT NOT NULL DEFAULT '',
    applied_at TEXT
);
CREATE TABLE IF NOT EXISTS prep_notes(
    date TEXT NOT NULL, start TEXT NOT NULL, title TEXT NOT NULL,
    minutes INTEGER NOT NULL DEFAULT 0, text TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL,
    PRIMARY KEY (date, start, title)
);
CREATE TABLE IF NOT EXISTS event_class(
    date TEXT NOT NULL, start TEXT NOT NULL, title TEXT NOT NULL,
    cls TEXT NOT NULL, updated_at TEXT NOT NULL,
    PRIMARY KEY (date, start, title)
);
CREATE TABLE IF NOT EXISTS family_rules(
    id INTEGER PRIMARY KEY,
    pattern TEXT NOT NULL UNIQUE COLLATE NOCASE,
    cls TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS proposals(
    id INTEGER PRIMARY KEY,
    week_start TEXT NOT NULL,      -- Monday
    reason TEXT NOT NULL,          -- sunday | red | manual
    created_at TEXT NOT NULL
);
"""


def connect(path: str, check_same_thread: bool = True, readonly: bool = False) -> sqlite3.Connection:
    """readonly=True opens an existing store without touching it (dry runs); a missing
    store then yields an in-memory one with default settings."""
    if readonly:
        if path == ":memory:" or not os.path.exists(path):
            return connect(":memory:", check_same_thread)
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, check_same_thread=check_same_thread)
        conn.row_factory = sqlite3.Row
        return conn
    if path != ":memory:":
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    conn = sqlite3.connect(path, check_same_thread=check_same_thread)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    conn.executescript(_SCHEMA)
    conn.executemany("INSERT OR IGNORE INTO settings(key, value) VALUES (?, ?)",
                     DEFAULT_SETTINGS.items())
    conn.commit()
    return conn


def _now() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


# ---- settings ---------------------------------------------------------------

def get_settings(conn) -> dict:
    return {r["key"]: r["value"] for r in conn.execute("SELECT key, value FROM settings")}


_TIME_SETTINGS = ("hard_stop", "run_slot")
_NUMBER_SETTINGS = ("week_hours_min", "week_hours_max")
_HHMM = re.compile(r"([01]\d|2[0-3]):[0-5]\d")


def normalise_setting(key: str, value) -> str:
    """The string to store for `value`, or ValueError. Readers call float()/HH:MM parsing on
    these, so a bad value stored here would break the Day page and the gate job."""
    if key not in DEFAULT_SETTINGS:
        raise ValueError(f"unknown setting {key}")
    if isinstance(value, bool) or not isinstance(value, (str, int, float)):
        raise ValueError(f"{key} must be a string or number")
    text = str(value).strip()
    if key in _TIME_SETTINGS:
        if not _HHMM.fullmatch(text):
            raise ValueError(f"{key} must be HH:MM")
    elif key == "run_alt_slots":
        if text and not all(_HHMM.fullmatch(p.strip()) for p in text.split(",")):
            raise ValueError(f"{key} must be a comma-separated list of HH:MM")
        text = ",".join(p.strip() for p in text.split(",")) if text else ""
    elif key in _NUMBER_SETTINGS:
        try:
            n = float(text)
        except ValueError:
            raise ValueError(f"{key} must be a number")
        if not 0 <= n <= 168:
            raise ValueError(f"{key} must be between 0 and 168")
    elif len(text) > 100:
        raise ValueError(f"{key} is too long (max 100)")
    return text


def set_setting(conn, key: str, value) -> None:
    value = normalise_setting(key, value)
    conn.execute("INSERT OR REPLACE INTO settings(key, value) VALUES (?, ?)", (key, value))
    conn.commit()


# ---- blocks -----------------------------------------------------------------

def add_block(conn, date: str, start: str, end: str, kind: str, title: str,
              note: str = "", source: str = "propose", state: str = "proposed") -> int:
    if kind not in KINDS:
        raise ValueError(f"unknown kind {kind}")
    if state not in STATES:
        raise ValueError(f"unknown state {state}")
    cur = conn.execute(
        "INSERT INTO blocks(date, start, end, kind, title, note, state, source, created_at)"
        " VALUES (?,?,?,?,?,?,?,?,?)",
        (date, start, end, kind, title, note, state, source, _now()))
    conn.commit()
    return cur.lastrowid


def blocks_between(conn, start: str, end: str, states: tuple = STATES) -> list[dict]:
    q = ",".join("?" * len(states))
    rows = conn.execute(
        f"SELECT * FROM blocks WHERE date >= ? AND date <= ? AND state IN ({q})"
        " ORDER BY date, start", (start, end, *states))
    return [dict(r) for r in rows]


def has_block(conn, date: str, kind: str) -> bool:
    r = conn.execute("SELECT 1 FROM blocks WHERE date = ? AND kind = ? AND state != 'rejected'"
                     " LIMIT 1", (date, kind)).fetchone()
    return r is not None


def get_block(conn, block_id: int) -> dict | None:
    r = conn.execute("SELECT * FROM blocks WHERE id = ?", (block_id,)).fetchone()
    return dict(r) if r else None


def decide(conn, block_id: int, state: str) -> dict:
    """Approve or reject a block. The sync job then creates or deletes its calendar event."""
    if state not in ("approved", "rejected"):
        raise ValueError("state must be approved or rejected")
    if get_block(conn, block_id) is None:
        raise KeyError(block_id)
    conn.execute("UPDATE blocks SET state = ?, decided_at = ? WHERE id = ?",
                 (state, _now(), block_id))
    conn.commit()
    return get_block(conn, block_id)


def update_block(conn, block_id: int, **fields) -> dict:
    allowed = {"date", "start", "end", "title", "note", "gcal_event_id", "gcal_calendar", "synced_at"}
    bad = set(fields) - allowed
    if bad:
        raise ValueError(f"cannot update {sorted(bad)}")
    if not fields:
        return get_block(conn, block_id)
    sets = ", ".join(f"{k} = ?" for k in fields)
    conn.execute(f"UPDATE blocks SET {sets} WHERE id = ?", (*fields.values(), block_id))
    conn.commit()
    return get_block(conn, block_id)


def move_block(conn, block_id: int, date: str, start: str, end: str) -> dict:
    """Move = reject the old row (the sync deletes its Google event) + a new approved row
    (the sync creates one). Keeps kind, title and source; the note says where it came from."""
    old = get_block(conn, block_id)
    if old is None:
        raise KeyError(block_id)
    if old["state"] not in ("approved", "proposed"):
        raise ValueError(f"block {block_id} is {old['state']}, not live: nothing to move")
    try:
        conn.execute("UPDATE blocks SET state='rejected', decided_at=? WHERE id=? AND state IN ('approved','proposed')",
                     (_now(), block_id))
        cur = conn.execute(
            "INSERT INTO blocks(date, start, end, kind, title, note, state, source, created_at, decided_at)"
            " VALUES (?,?,?,?,?,?,?,?,?,?)",
            (date, start, end, old["kind"], old["title"], f"moved from {old['date']} {old['start']}", "approved",
             old["source"], _now(), _now()))
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    return get_block(conn, cur.lastrowid)


def pending_sync(conn) -> list[dict]:
    """Approved blocks not yet in Google, plus rejected ones still there."""
    rows = conn.execute(
        "SELECT * FROM blocks WHERE (state = 'approved' AND gcal_event_id = '')"
        " OR (state = 'rejected' AND gcal_event_id != '') ORDER BY date, start")
    return [dict(r) for r in rows]


def record_proposal(conn, week_start: str, reason: str) -> None:
    conn.execute("INSERT INTO proposals(week_start, reason, created_at) VALUES (?,?,?)",
                 (week_start, reason, _now()))
    conn.commit()


def last_proposal(conn, week_start: str) -> dict | None:
    r = conn.execute("SELECT * FROM proposals WHERE week_start = ? ORDER BY id DESC LIMIT 1",
                     (week_start,)).fetchone()
    return dict(r) if r else None


# ---- write queue ------------------------------------------------------------

def touch_sync_now(flag_dir: str) -> bool:
    try:
        with open(os.path.join(flag_dir, "sync_now"), "w") as f:
            f.write(_now())
        return True
    except OSError:
        return False

# The container holds no credentials: every Todoist / Google / overlay write is
# queued here and applied by the sync job (balance.jobs.sync) on the host (sync.drain).

def _qrow(r) -> dict:
    d = dict(r)
    d["payload"] = json.loads(d["payload"] or "{}")
    return d


def enqueue(conn, kind: str, payload: dict, line: str, flag_dir: str | None = None) -> dict:
    """Queue a write; touches <flag_dir>/sync_now so the host sync takes a full run soon
    (best effort; flag_dir is the store's own directory, writable from the container)."""
    cur = conn.execute("INSERT INTO queue(created_at, kind, payload, line) VALUES (?,?,?,?)",
                       (_now(), kind, json.dumps(payload), line))
    conn.commit()
    if flag_dir:
        touch_sync_now(flag_dir)
    return _qrow(conn.execute("SELECT * FROM queue WHERE id=?", (cur.lastrowid,)).fetchone())


def queue_pending(conn) -> list[dict]:
    return [_qrow(r) for r in conn.execute("SELECT * FROM queue WHERE status='pending' ORDER BY id")]


def queue_recent(conn, days: int = 7) -> list[dict]:
    since = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")
    return [_qrow(r) for r in conn.execute("SELECT * FROM queue WHERE created_at >= ? ORDER BY id DESC", (since,))]


def queue_mark(conn, qid: int, status: str, error: str = "") -> dict:
    applied = _now() if status in ("done", "failed") else None
    conn.execute("UPDATE queue SET status=?, error=?, applied_at=COALESCE(?, applied_at) WHERE id=?",
                 (status, error[:500], applied, qid))
    conn.commit()
    return _qrow(conn.execute("SELECT * FROM queue WHERE id=?", (qid,)).fetchone())


def queue_retry(conn, qid: int) -> dict:
    conn.execute("UPDATE queue SET status='pending', error='', applied_at=NULL WHERE id=? AND status='failed'", (qid,))
    conn.commit()
    return _qrow(conn.execute("SELECT * FROM queue WHERE id=?", (qid,)).fetchone())


# ---- prep notes (Day page) ---------------------------------------------------

def set_prep_note(conn, date: str, start: str, title: str, minutes: int, text: str) -> dict:
    conn.execute("INSERT INTO prep_notes(date,start,title,minutes,text,updated_at) VALUES (?,?,?,?,?,?)"
                 " ON CONFLICT(date,start,title) DO UPDATE SET minutes=excluded.minutes, text=excluded.text,"
                 " updated_at=excluded.updated_at", (date, start, title, int(minutes), text, _now()))
    conn.commit()
    return {"date": date, "start": start, "title": title, "minutes": int(minutes), "text": text}


def get_prep_notes(conn, date: str) -> list[dict]:
    return [dict(r) for r in conn.execute(
        "SELECT date, start, title, minutes, text FROM prep_notes WHERE date=? ORDER BY start", (date,))]


# ---- Family-event classification (Day page "whose?") -------------------------

CLASSES = ("mine", "family", "partner", "child")


def set_event_class(conn, date: str, start: str, title: str, cls: str) -> dict:
    conn.execute("INSERT INTO event_class(date,start,title,cls,updated_at) VALUES (?,?,?,?,?)"
                 " ON CONFLICT(date,start,title) DO UPDATE SET cls=excluded.cls, updated_at=excluded.updated_at",
                 (date, start, title, cls, _now()))
    conn.commit()
    return {"date": date, "start": start, "title": title, "cls": cls}


def get_event_classes(conn, date: str) -> dict:
    return {(r["start"], r["title"]): r["cls"] for r in conn.execute(
        "SELECT start, title, cls FROM event_class WHERE date=?", (date,))}


def add_family_rule(conn, pattern: str, cls: str) -> dict:
    """'Always for this title': a case-insensitive substring rule; the same pattern is updated."""
    conn.execute("INSERT INTO family_rules(pattern, cls, created_at) VALUES (?,?,?)"
                 " ON CONFLICT(pattern) DO UPDATE SET cls=excluded.cls", (pattern.strip(), cls, _now()))
    conn.commit()
    r = conn.execute("SELECT id, pattern, cls FROM family_rules WHERE pattern=? COLLATE NOCASE", (pattern.strip(),)).fetchone()
    return dict(r)


def delete_family_rule(conn, rule_id: int) -> bool:
    cur = conn.execute("DELETE FROM family_rules WHERE id=?", (rule_id,))
    conn.commit()
    return cur.rowcount > 0


def family_rules(conn) -> list[dict]:
    return [dict(r) for r in conn.execute("SELECT id, pattern, cls FROM family_rules ORDER BY id")]
