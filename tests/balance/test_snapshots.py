"""JSON snapshots of the work mirror and the annotation overlay for the container (Task 4)."""
import sqlite3
from datetime import date

from balance import inputs, snapshots

MIRROR_SCHEMA = """
CREATE TABLE events (
    id INTEGER PRIMARY KEY, date TEXT NOT NULL, start TEXT NOT NULL, end TEXT, title TEXT NOT NULL,
    organizer TEXT DEFAULT '', status TEXT DEFAULT 'confirmed', note TEXT DEFAULT '', source TEXT DEFAULT '',
    updated_at TEXT, UNIQUE(date, start, title));
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE imports (start TEXT NOT NULL, end TEXT NOT NULL, source TEXT DEFAULT '', imported_at TEXT);
"""
ANN_SCHEMA = """
CREATE TABLE one_off (id INTEGER PRIMARY KEY, date TEXT NOT NULL, start TEXT NOT NULL, title TEXT NOT NULL,
    owner TEXT, tier TEXT, note TEXT, updated_at TEXT, UNIQUE(date, start, title));
CREATE TABLE recurring (id INTEGER PRIMARY KEY, pattern TEXT NOT NULL UNIQUE, tier TEXT, note TEXT, updated_at TEXT);
"""


def _mirror(tmp_path):
    p = str(tmp_path / "work_calendar.db")
    c = sqlite3.connect(p)
    c.executescript(MIRROR_SCHEMA)
    c.executemany("INSERT INTO events(date,start,end,title,organizer,status,note,source,updated_at) VALUES (?,?,?,?,?,?,?,?,?)", [
        ("2026-11-03", "09:30", "10:00", "Astrid v1 stand-up", "", "confirmed", "", "outlook-2026-10-28.pdf", "2026-10-28 10:00:00"),
        ("2026-11-03", "11:00", "12:00", "Model review", "", "confirmed", "", "dashboard", "2026-11-02 18:00:00"),
        ("2026-11-04", "13:00", "13:30", "Vendor demo", "", "cancelled", "moved", "outlook-2026-10-28.pdf", "2026-10-28 10:00:00"),
        ("2026-12-01", "09:00", "10:00", "Far away", "", "confirmed", "", "outlook-2026-10-28.pdf", None),
    ])
    c.executemany("INSERT INTO imports(start,end,source,imported_at) VALUES (?,?,?,?)", [
        ("2026-10-01", "2026-10-31", "outlook-2026-09-30.pdf", "2026-09-30 09:00:00"),
        ("2026-10-27", "2026-11-14", "outlook-2026-10-28.pdf", "2026-10-28 10:00:00"),
        ("2026-11-05", "2026-11-05", "dashboard", "2026-11-02 18:00:00"),
    ])
    c.commit()
    c.close()
    return p


def test_mirror_snapshot_shape_and_window(tmp_path):
    snap = snapshots.mirror_snapshot(_mirror(tmp_path), date(2026, 11, 1), date(2026, 11, 30))
    titles = [e["title"] for e in snap["events"]]
    assert titles == ["Astrid v1 stand-up", "Model review", "Vendor demo"]      # window applied, cancelled kept
    ev = snap["events"][0]
    assert set(ev) == {"id", "date", "start", "end", "title", "organizer", "status", "note", "source", "updated_at"}
    assert snap["events"][2]["status"] == "cancelled"
    assert snap["taken"]


def test_mirror_coverage_ignores_hand_added_ranges(tmp_path):
    snap = snapshots.mirror_snapshot(_mirror(tmp_path), date(2026, 11, 1), date(2026, 11, 30))
    cov = dict(snap["coverage"]); cov.pop("ranges")
    assert cov == {"last_import_end": "2026-11-14", "last_import_at": "2026-10-28 10:00:00",
                   "last_import_source": "outlook-2026-10-28.pdf"}


def test_missing_mirror_is_an_empty_snapshot_with_warning(tmp_path):
    snap = snapshots.mirror_snapshot(str(tmp_path / "nope.db"), date(2026, 11, 1), date(2026, 11, 2))
    assert snap["events"] == [] and snap["coverage"]["last_import_end"] is None and "missing" in snap["warning"]


def test_annotations_snapshot(tmp_path):
    p = str(tmp_path / "ann.db")
    c = sqlite3.connect(p)
    c.executescript(ANN_SCHEMA)
    c.execute("INSERT INTO one_off(date,start,title,owner,tier,note,updated_at) VALUES ('2026-11-05','08:45','School drop-off','Sam',NULL,NULL,'x')")
    c.execute("INSERT INTO recurring(pattern,tier,note,updated_at) VALUES ('Escola','context',NULL,'x')")
    c.commit()
    c.close()
    snap = snapshots.annotations_snapshot(p)
    assert snap["one_off"] == [{"date": "2026-11-05", "start": "08:45", "title": "School drop-off", "owner": "Sam", "tier": None, "note": None}]
    assert snap["recurring"] == [{"pattern": "Escola", "tier": "context", "note": None}]
    assert snapshots.annotations_snapshot(str(tmp_path / "nope.db"))["one_off"] == []


def test_inputs_read_snapshots(tmp_path):
    (tmp_path / "mirror.json").write_text('{"events": [], "coverage": {"last_import_end": null}}')
    assert inputs.read_mirror(str(tmp_path))["coverage"]["last_import_end"] is None
    assert inputs.read_annotations(str(tmp_path)) == {"one_off": [], "recurring": []}


def test_mirror_coverage_exports_import_ranges(tmp_path):
    snap = snapshots.mirror_snapshot(_mirror(tmp_path), date(2026, 11, 1), date(2026, 11, 30))
    assert snap["coverage"]["ranges"] == [["2026-10-01", "2026-10-31"], ["2026-10-27", "2026-11-14"]]


def test_school_days_snapshot_uses_the_school_calendar_function():
    from datetime import date
    def status(d, rules):
        return ("off", "Festa") if d == date(2026, 11, 6) else ("school", "") if d.weekday() < 5 else ("school", "")
    snap = snapshots.school_days_snapshot(date(2026, 11, 5), date(2026, 11, 7), status_fn=status, rules={})
    assert snap["from"] == "2026-11-05" and snap["to"] == "2026-11-07" and snap["taken"]
    assert snap["days"]["2026-11-06"] == {"status": "off", "name": "Festa"}
    assert snap["days"]["2026-11-05"]["status"] == "school"
    broken = snapshots.school_days_snapshot(date(2026, 11, 5), date(2026, 11, 5), status_fn=None, rules=None)
    assert broken["days"] == {} and "warning" in broken
