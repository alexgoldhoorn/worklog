"""The timer's SQLite store: schema, migrations and plain row accessors.

Times are local `HH:MM` strings and dates are `YYYY-MM-DD` strings, with no timezone stored.
The server decides what "now" is (`TZ`), so moving the database between zones does not
rewrite history. A block with `end` NULL is the running one; there is at most one.
"""
import sqlite3
from dataclasses import dataclass
from datetime import datetime

# A block whose type is in this list (table `break_types`) counts as a break, not work.
BREAK_TYPES = "shop eat sport out house other travel fam family child rest sick run gym admin pomo".split()
# Seeded into `settings` on first start; `default_client`/the ACME client are placeholders.
DEFAULT_SETTINGS = {
    "default_type": "dev",
    "default_client": "ACME",
    "default_break_type": "eat",
    "default_expected_h": "7",
    "auto_close_time": "18:00",
    "base_week_h": "35",
    "alt_week_h": "40",
}

_V1 = """
CREATE TABLE blocks(
    id INTEGER PRIMARY KEY,
    date TEXT NOT NULL,
    start TEXT NOT NULL,
    end TEXT,
    project TEXT,
    type TEXT NOT NULL,
    client TEXT,
    billable INTEGER,
    source TEXT NOT NULL DEFAULT 'timer',
    auto_closed INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
CREATE INDEX idx_blocks_date_start ON blocks(date, start);
CREATE TABLE break_types(name TEXT PRIMARY KEY);
CREATE TABLE clients(
    abbrev TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    billable INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE day_expectations(
    date TEXT PRIMARY KEY,
    expected_h REAL NOT NULL,
    sick_h REAL NOT NULL DEFAULT 0,
    reason TEXT NOT NULL DEFAULT '',
    source TEXT NOT NULL DEFAULT 'manual'
);
CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


def _seed_v1(conn: sqlite3.Connection) -> None:
    conn.executemany("INSERT INTO break_types(name) VALUES (?)", [(n,) for n in BREAK_TYPES])
    conn.execute("INSERT INTO clients(abbrev, name, billable) VALUES ('ACME', 'Acme', 1)")
    conn.executemany("INSERT INTO settings(key, value) VALUES (?, ?)", DEFAULT_SETTINGS.items())


def _seed_v2(conn: sqlite3.Connection) -> None:
    conn.executemany("INSERT OR IGNORE INTO settings(key, value) VALUES (?, ?)",
                     [("rate", ""), ("rate_unit", "h")])


_V3 = """
CREATE TABLE proposal_dismissals(
    date TEXT NOT NULL,
    start TEXT NOT NULL,
    title TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL,
    PRIMARY KEY(date, start, title)
);
"""


def _seed_noop(conn: sqlite3.Connection) -> None:
    pass


def _seed_v4(conn: sqlite3.Connection) -> None:
    # Dedicated break type for pomodoro breaks, so they never land under `eat`.
    conn.execute("INSERT OR IGNORE INTO break_types(name) VALUES ('pomo')")


MIGRATIONS = [(1, _V1, _seed_v1), (2, "", _seed_v2), (3, _V3, _seed_noop), (4, "", _seed_v4)]


def migrate(conn: sqlite3.Connection) -> None:
    """Apply MIGRATIONS newer than PRAGMA user_version, one transaction each. Forward only:
    to change the schema, append a new (version, sql, seed) entry; never edit an old one."""
    current = conn.execute("PRAGMA user_version").fetchone()[0]
    for version, sql, seed in MIGRATIONS:
        if version <= current:
            continue
        if sql:
            conn.executescript("BEGIN;" + sql)
        seed(conn)
        conn.execute(f"PRAGMA user_version = {version}")
        conn.commit()


def connect(path: str, check_same_thread: bool = True) -> sqlite3.Connection:
    """Open (and migrate) the store. WAL mode so the web server and host jobs can read while
    the timer writes. The directory of `path` must exist; the file is created."""
    conn = sqlite3.connect(path, check_same_thread=check_same_thread)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    migrate(conn)
    return conn


@dataclass
class Block:
    id: int | None
    date: str
    start: str
    end: str | None
    project: str | None
    type: str
    client: str | None
    billable: bool | None
    source: str = "timer"
    auto_closed: bool = False


@dataclass
class DayExpectation:
    date: str
    expected_h: float
    sick_h: float = 0.0
    reason: str = ""
    source: str = "manual"


def _now() -> str:
    return datetime.now().isoformat(timespec="seconds")


def _to_int(v):
    return None if v is None else int(bool(v))


def _block(row: sqlite3.Row) -> Block:
    return Block(
        id=row["id"], date=row["date"], start=row["start"], end=row["end"],
        project=row["project"], type=row["type"], client=row["client"],
        billable=None if row["billable"] is None else bool(row["billable"]),
        source=row["source"], auto_closed=bool(row["auto_closed"]),
    )


def insert_block(conn: sqlite3.Connection, b: Block) -> int:
    now = _now()
    cur = conn.execute(
        "INSERT INTO blocks(date, start, end, project, type, client, billable, source,"
        " auto_closed, created_at, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        (b.date, b.start, b.end, b.project, b.type, b.client, _to_int(b.billable),
         b.source, int(bool(b.auto_closed)), now, now),
    )
    conn.commit()
    return cur.lastrowid


_BLOCK_FIELDS = {"date", "start", "end", "project", "type", "client", "billable", "source", "auto_closed"}


def update_block(conn: sqlite3.Connection, block_id: int, **fields) -> Block:
    """Change the named fields. Setting `end` clears `auto_closed` unless the caller sets it,
    so a block the user fixed no longer shows up as needing review."""
    unknown = set(fields) - _BLOCK_FIELDS
    if unknown:
        raise ValueError(f"unknown block fields: {sorted(unknown)}")
    if "end" in fields and "auto_closed" not in fields:
        fields["auto_closed"] = 0
    for k in ("billable", "auto_closed"):
        if k in fields:
            fields[k] = _to_int(fields[k])
    fields["updated_at"] = _now()
    sets = ", ".join(f"{k} = ?" for k in fields)
    conn.execute(f"UPDATE blocks SET {sets} WHERE id = ?", (*fields.values(), block_id))
    conn.commit()
    return get_block(conn, block_id)


def delete_block(conn: sqlite3.Connection, block_id: int) -> None:
    conn.execute("DELETE FROM blocks WHERE id = ?", (block_id,))
    conn.commit()


def get_block(conn: sqlite3.Connection, block_id: int) -> Block | None:
    row = conn.execute("SELECT * FROM blocks WHERE id = ?", (block_id,)).fetchone()
    return _block(row) if row else None


def blocks_on(conn: sqlite3.Connection, date: str) -> list[Block]:
    rows = conn.execute("SELECT * FROM blocks WHERE date = ? ORDER BY start, id", (date,))
    return [_block(r) for r in rows]


def blocks_between(conn: sqlite3.Connection, start: str, end: str) -> list[Block]:
    rows = conn.execute(
        "SELECT * FROM blocks WHERE date BETWEEN ? AND ? ORDER BY date, start, id", (start, end))
    return [_block(r) for r in rows]


def auto_closed_between(conn: sqlite3.Connection, start: str, end: str) -> list[Block]:
    rows = conn.execute(
        "SELECT * FROM blocks WHERE auto_closed = 1 AND date BETWEEN ? AND ? ORDER BY date, start, id",
        (start, end)).fetchall()
    return [_block(r) for r in rows]


def open_block(conn: sqlite3.Connection) -> Block | None:
    """The running block (no `end`), newest first if data ever holds more than one."""
    row = conn.execute(
        "SELECT * FROM blocks WHERE end IS NULL ORDER BY date DESC, start DESC, id DESC LIMIT 1"
    ).fetchone()
    return _block(row) if row else None


def break_types(conn: sqlite3.Connection) -> set[str]:
    return {r["name"] for r in conn.execute("SELECT name FROM break_types")}


def clients(conn: sqlite3.Connection) -> dict[str, sqlite3.Row]:
    return {r["abbrev"]: r for r in conn.execute("SELECT * FROM clients")}


def setting(conn: sqlite3.Connection, key: str) -> str:
    """A stored setting; raises if the key was never seeded (all keys are, by migration)."""
    return conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()["value"]


def set_setting(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        "INSERT INTO settings(key, value) VALUES (?, ?)"
        " ON CONFLICT(key) DO UPDATE SET value = excluded.value", (key, value))
    conn.commit()


def _expectation(r: sqlite3.Row) -> DayExpectation:
    return DayExpectation(r["date"], r["expected_h"], r["sick_h"], r["reason"], r["source"])


def get_expectation(conn: sqlite3.Connection, date: str) -> DayExpectation | None:
    r = conn.execute("SELECT * FROM day_expectations WHERE date = ?", (date,)).fetchone()
    return _expectation(r) if r else None


def set_expectation(conn: sqlite3.Connection, e: DayExpectation) -> None:
    conn.execute(
        "INSERT INTO day_expectations(date, expected_h, sick_h, reason, source) VALUES (?,?,?,?,?)"
        " ON CONFLICT(date) DO UPDATE SET expected_h=excluded.expected_h, sick_h=excluded.sick_h,"
        " reason=excluded.reason, source=excluded.source",
        (e.date, e.expected_h, e.sick_h, e.reason, e.source))
    conn.commit()


def delete_expectation(conn: sqlite3.Connection, date: str) -> None:
    conn.execute("DELETE FROM day_expectations WHERE date = ?", (date,))
    conn.commit()


def expectations_between(conn: sqlite3.Connection, start: str, end: str) -> dict[str, DayExpectation]:
    rows = conn.execute(
        "SELECT * FROM day_expectations WHERE date BETWEEN ? AND ? ORDER BY date", (start, end))
    return {r["date"]: _expectation(r) for r in rows}


# ---- calendar proposal dismissals ------------------------------------------------

def dismiss_proposal(conn: sqlite3.Connection, date: str, start: str, title: str | None) -> None:
    conn.execute("INSERT OR IGNORE INTO proposal_dismissals(date, start, title, created_at) VALUES (?, ?, ?, ?)",
                 (date, start, title or "", _now()))
    conn.commit()


def undismiss_proposal(conn: sqlite3.Connection, date: str, start: str, title: str | None) -> None:
    conn.execute("DELETE FROM proposal_dismissals WHERE date = ? AND start = ? AND title = ?", (date, start, title or ""))
    conn.commit()


def dismissed_on(conn: sqlite3.Connection, date: str) -> set[tuple[str, str]]:
    return {(r["start"], r["title"]) for r in conn.execute(
        "SELECT start, title FROM proposal_dismissals WHERE date = ?", (date,))}
