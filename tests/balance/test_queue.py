"""Write queue in balance.db, drained on the host by balance_sync (Task 3)."""
import sqlite3

import pytest

from balance import db as bdb, sync
from balance.queue_handlers import HANDLERS, annotate_handler


@pytest.fixture
def conn():
    c = bdb.connect(":memory:")
    yield c
    c.close()


def test_enqueue_and_drain_marks_done(conn):
    q = bdb.enqueue(conn, "todoist_complete", {"task_id": "abc"}, "Done: Sign-off checklist")
    assert q["status"] == "pending" and q["payload"] == {"task_id": "abc"} and q["line"] == "Done: Sign-off checklist"
    calls = []
    st = sync.drain(conn, {}, {"todoist_complete": lambda p, env: calls.append(p)})
    assert calls == [{"task_id": "abc"}] and st["done"] == 1 and st["failed"] == 0
    row = bdb.queue_recent(conn)[0]
    assert row["status"] == "done" and row["applied_at"]
    assert bdb.queue_pending(conn) == []


def test_failed_handler_stays_visible_with_error_and_never_retries_silently(conn):
    bdb.enqueue(conn, "gcal_create", {"calendar": "Family"}, "Dentist")

    def boom(p, env):
        raise RuntimeError("login expired")

    st = sync.drain(conn, {}, {"gcal_create": boom})
    row = bdb.queue_recent(conn)[0]
    assert st["failed"] == 1 and row["status"] == "failed" and "login expired" in row["error"]
    assert sync.drain(conn, {}, {"gcal_create": boom}) == {"done": 0, "failed": 0, "errors": []}
    bdb.queue_retry(conn, row["id"])
    assert bdb.queue_pending(conn)[0]["id"] == row["id"] and bdb.queue_pending(conn)[0]["error"] == ""


def test_one_failure_does_not_stop_the_others(conn):
    bdb.enqueue(conn, "a", {}, "first")
    bdb.enqueue(conn, "b", {}, "second")
    done = []
    st = sync.drain(conn, {}, {"a": lambda p, e: (_ for _ in ()).throw(ValueError("x")), "b": lambda p, e: done.append(1)})
    assert st == {"done": 1, "failed": 1, "errors": ["first: x"]} and done == [1]


def test_unknown_kind_fails_not_crashes(conn):
    bdb.enqueue(conn, "teleport", {}, "beam me up")
    st = sync.drain(conn, {}, {})
    assert st["failed"] == 1 and bdb.queue_recent(conn)[0]["error"] == "no handler: teleport"


def test_queue_mark_and_dismiss(conn):
    q = bdb.enqueue(conn, "a", {}, "x")
    assert bdb.queue_mark(conn, q["id"], "dismissed")["status"] == "dismissed"
    assert bdb.queue_pending(conn) == []


def test_enqueue_touches_sync_now_flag(conn, tmp_path):
    bdb.enqueue(conn, "a", {}, "x", flag_dir=str(tmp_path))
    assert (tmp_path / "sync_now").exists()


def test_annotate_handler_upserts_one_off(tmp_path):
    path = str(tmp_path / "ann.db")
    env = {"ANNOTATIONS_DB": path}
    annotate_handler({"date": "2026-11-05", "start": "08:45", "title": "School drop-off", "owner": "Sam"}, env)
    annotate_handler({"date": "2026-11-05", "start": "08:45", "title": "School drop-off", "note": "bring the form"}, env)
    c = sqlite3.connect(path)
    rows = c.execute("SELECT owner, tier, note FROM one_off").fetchall()
    assert rows == [("Sam", None, "bring the form")]


def test_handlers_registered():
    assert set(HANDLERS) >= {"todoist_complete", "todoist_add", "gcal_create", "annotate"}


def test_session_time_handler_writes_the_sidecar(tmp_path):
    from balance import sessions
    HANDLERS["session_time"]({"date": "2026-11-05", "session": "Easy Run", "start": "13:00", "end": "14:00"},
                             {"BALANCE_STATE_DIR": str(tmp_path)})
    assert sessions.time_for(sessions.read(str(tmp_path)), "2026-11-05", "Easy Run")["start"] == "13:00"


def test_gcal_update_patches_the_event_found_by_uid_and_never_inserts(monkeypatch):
    from balance import queue_handlers as qh, sync
    calls = []

    def api(method, path, params=None, body=None):
        calls.append((method, path, params, body))
        if method == "GET":
            return {"items": [{"id": "ev9"}]} if params.get("iCalUID") == "known@google.com" else {"items": []}
        return {}

    monkeypatch.setattr(sync, "_gapi", api)
    monkeypatch.setattr(sync, "resolve_calendar", lambda name: ("fam@cal", False))
    qh.gcal_update({"calendar": "Family", "uid": "known@google.com", "date": "2026-11-06", "start": "15:00", "end": "15:45"}, {})
    assert calls[-1][0] == "PATCH" and calls[-1][1].endswith("/events/ev9")
    assert calls[-1][3]["start"]["dateTime"] == "2026-11-06T15:00:00"
    with pytest.raises(LookupError):
        qh.gcal_update({"calendar": "Family", "uid": "gone@google.com", "date": "2026-11-06", "start": "15:00", "end": "15:45"}, {})
    assert not any(c[0] == "POST" for c in calls)


def test_mirror_add_upserts_and_refuses_an_email(tmp_path):
    from balance import queue_handlers as qh
    from tests.balance.test_snapshots import MIRROR_SCHEMA
    path = str(tmp_path / "work_calendar.db")
    c = sqlite3.connect(path); c.executescript(MIRROR_SCHEMA); c.commit(); c.close()
    env = {"WORK_CALENDAR_DB": path}
    qh.mirror_add({"date": "2026-11-06", "start": "14:00", "end": "14:45", "title": "Go/no-go prep"}, env)
    qh.mirror_add({"date": "2026-11-06", "start": "14:00", "end": "15:00", "title": "Go/no-go prep"}, env)   # same key: update
    c = sqlite3.connect(path)
    rows = c.execute("SELECT date,start,end,title,source FROM events").fetchall()
    assert rows == [("2026-11-06", "14:00", "15:00", "Go/no-go prep", "dashboard")]
    with pytest.raises(ValueError):
        qh.mirror_add({"date": "2026-11-06", "start": "16:00", "end": "16:30", "title": "call bob@corp.com"}, env)


def test_handlers_registered_for_plan_2():
    assert {"session_time", "gcal_update", "mirror_add"} <= set(HANDLERS)


def test_gcal_update_moves_one_instance_of_a_recurring_event(monkeypatch):
    """C1: the ICS feed expands series, every occurrence carries the master UID; a move must
    touch that occurrence's instance, never the master."""
    from balance import queue_handlers as qh, sync
    calls = []

    def api(method, path, params=None, body=None):
        calls.append((method, path, params, body))
        if method == "GET" and path.endswith("/events"):
            return {"items": [{"id": "master1", "recurrence": ["RRULE:FREQ=WEEKLY"], "status": "confirmed"}]}
        if method == "GET" and path.endswith("/events/master1/instances"):
            return {"items": [{"id": "master1_20261104T160000Z", "start": {"dateTime": "2026-11-04T17:00:00+01:00"}, "status": "confirmed"}]}
        return {}

    monkeypatch.setattr(sync, "_gapi", api)
    monkeypatch.setattr(sync, "resolve_calendar", lambda name: ("fam@cal", False))
    qh.gcal_update({"calendar": "Family", "uid": "swim@google.com", "orig_date": "2026-11-04", "orig_start": "17:00",
                    "date": "2026-11-04", "start": "18:00", "end": "19:00"}, {})
    patched = [c for c in calls if c[0] == "PATCH"]
    assert len(patched) == 1 and patched[0][1].endswith("/events/master1_20261104T160000Z")
    inst = [c for c in calls if c[1].endswith("/instances")][0]
    assert inst[2]["timeMin"].startswith("2026-11-04") and inst[2]["timeMax"].startswith("2026-11-05")


def test_gcal_update_refuses_a_recurring_master_without_the_original_occurrence(monkeypatch):
    from balance import queue_handlers as qh, sync
    monkeypatch.setattr(sync, "_gapi", lambda m, p, params=None, body=None: {"items": [{"id": "m", "recurrence": ["RRULE:FREQ=WEEKLY"]}]})
    monkeypatch.setattr(sync, "resolve_calendar", lambda name: ("fam@cal", False))
    with pytest.raises(ValueError):
        qh.gcal_update({"calendar": "Family", "uid": "x@google.com", "date": "2026-11-04", "start": "18:00", "end": "19:00"}, {})


def _mirror_db(tmp_path):
    from tests.balance.test_snapshots import MIRROR_SCHEMA
    path = str(tmp_path / "work_calendar.db")
    c = sqlite3.connect(path); c.executescript(MIRROR_SCHEMA)
    c.execute("INSERT INTO events(date,start,end,title,source,status) VALUES ('2026-11-06','14:00','14:45','Go/no-go prep','outlook.pdf','confirmed')")
    c.commit(); c.close()
    return path


def test_mirror_annotate_cancels_and_notes_the_row_or_fails_visibly(tmp_path):
    from balance import queue_handlers as qh
    env = {"WORK_CALENDAR_DB": _mirror_db(tmp_path)}
    qh.mirror_annotate({"date": "2026-11-06", "start": "14:00", "title": "Go/no-go prep", "status": "cancelled", "note": "moved by PM"}, env)
    c = sqlite3.connect(env["WORK_CALENDAR_DB"])
    assert c.execute("SELECT status, note FROM events").fetchone() == ("cancelled", "moved by PM")
    with pytest.raises(LookupError):
        qh.mirror_annotate({"date": "2026-11-06", "start": "09:00", "title": "Nope", "status": "cancelled"}, env)
    with pytest.raises(ValueError):
        qh.mirror_annotate({"date": "2026-11-06", "start": "14:00", "title": "Go/no-go prep", "note": "ask bob@corp.com"}, env)


def test_mirror_bulk_add_is_all_or_nothing_on_an_email(tmp_path):
    from balance import queue_handlers as qh
    env = {"WORK_CALENDAR_DB": _mirror_db(tmp_path)}
    with pytest.raises(ValueError):
        qh.mirror_bulk_add({"events": [{"date": "2026-11-07", "start": "09:00", "end": "09:30", "title": "Stand-up"},
                                       {"date": "2026-11-07", "start": "10:00", "end": "10:30", "title": "call bob@corp.com"}]}, env)
    c = sqlite3.connect(env["WORK_CALENDAR_DB"])
    assert c.execute("SELECT COUNT(*) FROM events").fetchone()[0] == 1                 # nothing added
    qh.mirror_bulk_add({"events": [{"date": "2026-11-07", "start": "09:00", "end": "09:30", "title": "Stand-up"}]}, env)
    assert c.execute("SELECT COUNT(*) FROM events").fetchone()[0] == 2
    assert c.execute("SELECT COUNT(*) FROM imports").fetchone()[0] == 0               # coverage never extended by hand


def test_mirror_add_keeps_the_existing_source_of_a_known_row(tmp_path):
    from balance import queue_handlers as qh
    env = {"WORK_CALENDAR_DB": _mirror_db(tmp_path)}
    qh.mirror_add({"date": "2026-11-06", "start": "14:00", "end": "14:45", "title": "Go/no-go prep"}, env)   # already there from the PDF
    c = sqlite3.connect(env["WORK_CALENDAR_DB"])
    assert c.execute("SELECT source FROM events").fetchone() == ("outlook.pdf",)


def test_overlapping_drains_apply_a_row_once(tmp_path):
    path = str(tmp_path / "b.db")
    a, b = bdb.connect(path), bdb.connect(path)
    bdb.enqueue(a, "mirror_bulk_add", {}, "paste")
    calls = []

    def slow(payload, env):
        calls.append(1)
        sync.drain(b, {}, {"mirror_bulk_add": lambda p, e: calls.append("second")})   # a second run starts meanwhile
    st = sync.drain(a, {}, {"mirror_bulk_add": slow})
    assert calls == [1] and st["done"] == 1
    a.close(); b.close()


def test_dismiss_during_apply_is_not_overwritten(conn):
    q = bdb.enqueue(conn, "todoist_complete", {}, "x")
    sync.drain(conn, {}, {"todoist_complete": lambda p, e: bdb.queue_mark(conn, q["id"], "dismissed")})
    assert bdb.queue_recent(conn)[0]["status"] == "dismissed"


def test_a_stale_claim_from_a_dead_run_is_taken_again(conn):
    q = bdb.enqueue(conn, "todoist_complete", {}, "x")
    assert bdb.queue_claim(conn, q["id"]) is True
    assert bdb.queue_claim(conn, q["id"]) is False
    conn.execute("UPDATE queue SET applied_at='2000-01-01 00:00:00' WHERE id=?", (q["id"],))
    assert bdb.queue_claim(conn, q["id"]) is True


def test_retry_makes_a_failed_row_claimable_again(conn):
    q = bdb.enqueue(conn, "gcal_create", {}, "x")
    sync.drain(conn, {}, {"gcal_create": lambda p, e: 1 / 0})
    bdb.queue_retry(conn, q["id"])
    calls = []
    sync.drain(conn, {}, {"gcal_create": lambda p, e: calls.append(1)})
    assert calls == [1]
