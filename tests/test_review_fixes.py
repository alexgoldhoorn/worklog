"""Regression tests for the reviewed server defects (one section per finding)."""
import asyncio
import base64
import io
import sqlite3
import threading
import time
from datetime import datetime

import openpyxl
import pytest
from fastapi.testclient import TestClient

from worklog import auth, db, timer, xlsx_io
from worklog.config import Settings
from worklog.web.app import create_app

D = "2026-10-20"


def T(s):
    return datetime.fromisoformat(s)


def at(app, s):
    app.state.clock = lambda: datetime.fromisoformat(s)


def blocks(app, date=D):
    c = db.connect(app.state.settings.db_path)
    try:
        return [(b.start, b.end, b.type, b.auto_closed) for b in db.blocks_on(c, date)]
    finally:
        c.close()


def raw(app):
    return db.connect(app.state.settings.db_path)


# ---- 1. a closed block ends after it starts -----------------------------------------

def test_create_rejects_end_not_after_start(client):
    for end in ("09:00", "08:59"):
        r = client.post("/api/blocks", json={"date": D, "start": "09:00", "end": end, "type": "dev"})
        assert r.status_code == 400 and r.json() == {"error": "end must be after start"}


def test_update_compares_merged_values(client):
    b = client.post("/api/blocks", json={"date": D, "start": "09:00", "end": "10:00", "type": "dev"}).json()
    url = f"/api/blocks/{b['id']}"
    assert client.put(url, json={"start": "10:30"}).status_code == 400      # only start moves past the end
    assert client.put(url, json={"end": "08:00"}).status_code == 400        # only end moves before the start
    assert client.put(url, json={"start": "10:30", "end": "11:00"}).status_code == 200
    assert client.put(url, json={"date": "2026-10-19", "project": "x"}).status_code == 200
    assert client.put(url, json={"end": None}).status_code == 200            # reopening is not an inversion


def test_import_still_accepts_and_flags_inverted_rows(conn, tmp_path):
    from tests.helpers import book
    parsed = xlsx_io.parse_rows(book(tmp_path, [[D, "10:00", "09:00", "x", "dev", None, None, None]]), "t.xlsx")
    assert xlsx_io.import_blocks(conn, parsed, "merge")["inserted"] == 1


# ---- 2. one open block, in the store and under the lock --------------------------------

def test_index_refuses_a_second_open_block(conn):
    db.insert_block(conn, db.Block(None, D, "08:00", None, None, "dev", None, None))
    with pytest.raises(sqlite3.IntegrityError):
        db.insert_block(conn, db.Block(None, D, "09:00", None, None, "dev", None, None))


def test_migration_closes_all_but_the_newest_open_block(tmp_path):
    p = str(tmp_path / "old.db")
    c = db.connect(p)
    c.execute("DROP INDEX idx_blocks_one_open")
    c.execute("PRAGMA user_version = 5")
    db.insert_block(c, db.Block(None, "2026-10-19", "17:00", None, None, "dev", None, None))
    db.insert_block(c, db.Block(None, D, "08:00", None, None, "dev", None, None))
    newest = db.insert_block(c, db.Block(None, D, "09:00", None, None, "dev", None, None))
    c.close()
    c = db.connect(p)   # must not crash
    assert c.execute("PRAGMA user_version").fetchone()[0] == 8
    assert [r["id"] for r in c.execute("SELECT id FROM blocks WHERE end IS NULL")] == [newest]
    old = db.blocks_on(c, "2026-10-19")[0]
    assert (old.end, old.auto_closed) == ("17:00", True)
    with pytest.raises(sqlite3.IntegrityError):
        db.insert_block(c, db.Block(None, D, "10:00", None, None, "dev", None, None))
    c.close()


def test_concurrent_creates_leave_one_open_block(app, client):
    codes = []

    def post(i):
        codes.append(client.post("/api/blocks", json={"date": D, "start": f"0{i}:00", "type": "dev"}).status_code)

    ts = [threading.Thread(target=post, args=(i,)) for i in range(1, 6)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert sorted(codes) == [200, 409, 409, 409, 409]


def test_reopening_a_block_while_another_runs_is_refused(client):
    closed = client.post("/api/blocks", json={"date": "2026-10-19", "start": "09:00", "end": "10:00"}).json()
    client.post("/api/start", json={})
    assert client.put(f"/api/blocks/{closed['id']}", json={"end": None}).status_code == 409


# ---- 3. import is one transaction -------------------------------------------------------

def _parsed(tmp_path, rows):
    from tests.helpers import book
    return xlsx_io.parse_rows(book(tmp_path, rows), "t.xlsx")


def test_replace_import_rolls_back_on_error(conn, tmp_path, monkeypatch):
    db.insert_block(conn, db.Block(None, D, "07:00", "08:00", "keep", "dev", None, None))
    parsed = _parsed(tmp_path, [[D, "09:00", "10:00", "a", "dev", None, None, None],
                                [D, "11:00", "12:00", "b", "dev", None, None, None]])
    parsed.break_types, parsed.clients = ["newbreak"], [("NEW", "New client")]
    real, calls = db.insert_block, []

    def flaky(conn_, b, **kw):
        calls.append(b)
        if len(calls) == 2:
            raise RuntimeError("disk on fire")
        return real(conn_, b, **kw)

    monkeypatch.setattr(db, "insert_block", flaky)
    with pytest.raises(RuntimeError):
        xlsx_io.import_blocks(conn, parsed, "replace")
    assert [(b.start, b.project) for b in db.blocks_on(conn, D)] == [("07:00", "keep")]
    assert "newbreak" not in db.break_types(conn) and "NEW" not in db.clients(conn)


def test_merge_import_rolls_back_on_error(conn, tmp_path, monkeypatch):
    db.insert_block(conn, db.Block(None, D, "09:00", "09:30", "old", "dev", None, None))
    parsed = _parsed(tmp_path, [[D, "09:00", "10:00", "new", "dev", None, None, None],
                                [D, "11:00", "12:00", "b", "dev", None, None, None]])
    real = db.insert_block
    monkeypatch.setattr(db, "insert_block", lambda *a, **k: (_ for _ in ()).throw(RuntimeError("x")))
    with pytest.raises(RuntimeError):
        xlsx_io.import_blocks(conn, parsed, "merge")
    monkeypatch.setattr(db, "insert_block", real)
    assert [(b.end, b.project) for b in db.blocks_on(conn, D)] == [("09:30", "old")]


def test_imported_open_rows_never_make_a_second_open_block(conn, tmp_path):
    db.insert_block(conn, db.Block(None, D, "08:00", None, None, "dev", None, None))
    parsed = _parsed(tmp_path, [["2026-10-18", "09:00", None, "x", "dev", None, None, None],
                                ["2026-10-17", "09:00", None, "y", "dev", None, None, None]])
    res = xlsx_io.import_blocks(conn, parsed, "merge")
    assert res["inserted"] == 0 and len(res["errors"]) == 2
    assert conn.execute("SELECT COUNT(*) FROM blocks WHERE end IS NULL").fetchone()[0] == 1
    conn.execute("DELETE FROM blocks"); conn.commit()
    res = xlsx_io.import_blocks(conn, parsed, "merge")   # none running: the first one is taken, the second not
    assert res["inserted"] == 1 and len(res["errors"]) == 1


def _upload(client, rows, tmp_path, **form):
    from tests.helpers import book
    p = book(tmp_path, rows)
    return client.post("/api/import", files={"file": ("t.xlsx", p.read_bytes())}, data=form)


def test_replace_dry_run_reports_the_running_block(client, tmp_path):
    client.post("/api/start", json={"type": "dev"})
    rows = [[D, "07:00", "08:00", "a", "dev", None, None, None]]
    r = _upload(client, rows, tmp_path, mode="replace", dry_run="1").json()
    assert r["would_delete"] == 1 and r["would_delete_running"] == {"date": D, "start": "09:00", "type": "dev"}
    assert _upload(client, rows, tmp_path, mode="merge", dry_run="1").json()["would_delete_running"] is None
    done = _upload(client, rows, tmp_path, mode="replace").json()
    assert done["deleted_running"]["start"] == "09:00"
    assert client.get("/api/status").json()["state"] == "stopped"


# ---- 4. late-night split of a block that began before auto_close_time ------------------------

def test_late_night_stop_of_an_afternoon_block_is_flagged(conn):
    timer.start(conn, T("2026-10-19 15:00"))
    timer.stop(conn, T("2026-10-20 05:00"))
    assert [(b.date, b.start, b.end, b.auto_closed) for b in db.blocks_between(conn, "2026-10-19", D)] == [
        ("2026-10-19", "15:00", "23:59", True), (D, "00:00", "05:00", True)]


def test_late_night_stop_of_an_evening_block_stays_silent(conn):
    timer.start(conn, T("2026-10-19 22:00"))
    timer.stop(conn, T("2026-10-20 02:00"))
    assert [(b.start, b.end, b.auto_closed) for b in db.blocks_between(conn, "2026-10-19", D)] == [
        ("22:00", "23:59", False), ("00:00", "02:00", False)]


# ---- 5. offline replay after auto-close --------------------------------------------------------

def test_replayed_stop_after_auto_close_extends_the_block(app, client):
    at(app, "2026-10-19 09:00")
    client.post("/api/start", json={"type": "dev"})
    at(app, D + " 07:30")                      # next morning the server auto-closed it at 18:00
    assert client.get("/api/status").json()["auto_closed"]
    assert blocks(app, "2026-10-19") == [("09:00", "18:00", "dev", True)]
    r = client.post("/api/stop", json={"at": "2026-10-19T21:15"})
    assert r.status_code == 200 and r.json()["state"] == "stopped"
    assert blocks(app, "2026-10-19") == [("09:00", "21:15", "dev", False)]


def test_replayed_pause_extends_then_starts_the_break_at_at(app, client):
    at(app, "2026-10-19 09:00")
    client.post("/api/start", json={"type": "dev"})
    at(app, D + " 07:30")
    client.get("/api/status")
    client.post("/api/pause", json={"at": "2026-10-19T19:00", "type": "Out"})   # case-insensitive too
    # the break replayed for yesterday evening is itself auto-closed by the status answer (it is older than today)
    assert blocks(app, "2026-10-19") == [("09:00", "19:00", "dev", False), ("19:00", "19:00", "out", True)]


def test_replayed_start_extends_and_begins_at_at(app, client):
    at(app, "2026-10-19 09:00")
    client.post("/api/start", json={"type": "dev"})
    at(app, D + " 07:30")
    client.get("/api/status")
    client.post("/api/start", json={"at": "2026-10-19T20:00", "type": "meet"})
    assert blocks(app, "2026-10-19") == [("09:00", "20:00", "dev", False), ("20:00", "20:00", "meet", True)]


def test_replay_across_midnight_splits_like_a_late_night_stop(app, client):
    at(app, "2026-10-19 09:00")
    client.post("/api/start", json={"type": "dev"})
    at(app, D + " 08:00")
    client.get("/api/status")
    client.post("/api/stop", json={"at": D + "T00:30"})
    assert blocks(app, "2026-10-19") == [("09:00", "23:59", "dev", False)]
    assert blocks(app) == [("00:00", "00:30", "dev", False)]


def test_stop_without_at_leaves_an_auto_closed_block_alone(app, client):
    at(app, "2026-10-19 09:00")
    client.post("/api/start", json={"type": "dev"})
    at(app, D + " 07:30")
    client.post("/api/stop", json={})
    assert blocks(app, "2026-10-19") == [("09:00", "18:00", "dev", True)]


# ---- 6. settings are all or nothing --------------------------------------------------------------

def test_settings_put_with_a_bad_field_saves_nothing(client):
    before = client.get("/api/settings").json()
    r = client.put("/api/settings", json={"rate": 55, "week_basis_h": 40, "default_type": "eat"})
    assert r.status_code == 400
    assert client.get("/api/settings").json() == before
    r = client.put("/api/settings", json={"rate": 55, "calendar_auto_add": "yes"})
    assert r.status_code == 400 and client.get("/api/settings").json() == before
    ok = client.put("/api/settings", json={"rate": 55, "week_basis_h": 40, "default_break_type": "OUT"}).json()
    assert ok["rate"] == 55 and ok["week_basis_h"] == 40 and ok["default_break_type"] == "out"


def test_set_settings_rolls_back(conn):
    with pytest.raises(sqlite3.IntegrityError):
        db.set_settings(conn, {"rate": "9", "default_type": None})   # NOT NULL fails on the second
    assert db.setting(conn, "rate") == ""


# ---- 7. unexpected errors are JSON; known triggers are 400 -----------------------------------------

def test_unexpected_exception_answers_500_json(app):
    @app.get("/boom")
    def boom():
        raise RuntimeError("secret detail")

    r = TestClient(app, raise_server_exceptions=False).get("/boom")
    assert r.status_code == 500 and r.json() == {"error": "internal error"}


def test_known_500_triggers_are_400(client):
    item = {"title": "x", "minutes": 30}
    day = {"date": "2026-11-03", "start": "09:00", "end": "10:00", "target": "todoist"}
    assert client.post("/api/day/slots", json={"item": {**item, "travel_before": "abc"}}).status_code == 400
    assert client.post("/api/day/slots", json={"item": {**item, "prefer": 5}}).status_code == 400
    td = {"project": "P", "due_string": "today"}
    for bad in ({**td, "priority": "high"}, {**td, "priority": 9}, "high", ["x"]):
        r = client.post("/api/day/find", json={**day, "item": item, "todoist": bad})
        assert r.status_code == 400 and "error" in r.json(), bad
    assert client.post("/api/calendar/add", json={"date": D, "start": "08:00", "end": "08:30", "title": 5}).status_code == 400
    r = client.get("/api/days", params={"start": "9999-12-01", "end": "9999-12-31"})
    assert r.status_code == 200 and len(r.json()) == 31


# ---- 8. range caps -----------------------------------------------------------------------------

def test_range_caps(client):
    for url in ("/api/days", "/api/heatmap", "/api/export.csv", "/api/export.xlsx"):
        far = "2000-01-01" if url != "/api/export.csv" and url != "/api/export.xlsx" else "1990-01-01"
        r = client.get(url, params={"start": far, "end": "2026-10-20"})
        assert r.status_code == 400 and "range too long" in r.json()["error"], url
    assert client.get("/api/export.csv", params={"start": "2016-01-01", "end": "2026-10-20"}).status_code == 200
    assert client.get("/api/heatmap", params={"start": "2017-01-01", "end": "2026-10-20"}).status_code == 200


# ---- 9. break types ignore case --------------------------------------------------------------------

def test_break_types_match_case_insensitively(client):
    assert client.post("/api/start", json={"type": "EAT"}).status_code == 400
    assert client.post("/api/pause", json={"type": " Eat "}).json()["block"]["type"] == "eat"
    assert client.post("/api/pause", json={"type": "Lunch"}).status_code == 400
    b = client.post("/api/blocks", json={"date": D, "start": "08:00", "end": "08:30", "type": "Sport", "client": "ACME"}).json()
    assert (b["type"], b["client"], b["billable"], b["work_type"]) == ("sport", None, None, "other")
    w = client.post("/api/blocks", json={"date": D, "start": "07:00", "end": "07:30", "type": "dev"}).json()
    e = client.put(f"/api/blocks/{w['id']}", json={"type": "REST"}).json()
    assert (e["type"], e["client"], e["billable"]) == ("rest", None, None)


# ---- 10. calendar add is one step ---------------------------------------------------------------------

def test_concurrent_calendar_adds_make_one_block(app, client):
    at(app, D + " 12:00")
    body = {"date": D, "start": "09:00", "end": "10:00", "title": "Review"}
    ids = []

    def post():
        ids.append(client.post("/api/calendar/add", json=body).json()["id"])

    ts = [threading.Thread(target=post) for _ in range(5)]
    [t.start() for t in ts]
    [t.join() for t in ts]
    assert len(set(ids)) == 1 and len(blocks(app)) == 1


# ---- 11. import upload -----------------------------------------------------------------------------------

def test_import_upload_cap_and_error_text(client):
    big = b"x" * (10 * 1024 * 1024 + 1)
    r = client.post("/api/import", files={"file": ("t.csv", big)})
    assert r.status_code == 413 and "error" in r.json()
    r = client.post("/api/import", files={"file": ("t.xlsx", b"PK this is not a workbook")})
    assert r.status_code == 400 and set(r.json()) == {"error"}
    assert "Traceback" not in r.json()["error"] and "zip" not in r.json()["error"].lower()


# ---- 12. formulas in exports ---------------------------------------------------------------------------------

NASTY = ["=1+1", "+SUM(A1)", "-5", "@x", "'=quoted", "''-2", "'plain", "-", "normal"]


def _seed_nasty(c):
    for i, p in enumerate(NASTY):
        db.insert_block(c, db.Block(None, D, f"{8 + i:02d}:00", f"{8 + i:02d}:30", p, "dev", None, None))


def _roundtrip(conn, tmp_path, make, name):
    _seed_nasty(conn)
    rows = xlsx_io.export_rows(conn, D, D, {})
    data = make(conn, rows)
    fresh = db.connect(str(tmp_path / "fresh.db"))
    parsed = xlsx_io.parse_rows(io.BytesIO(data), name)
    xlsx_io.import_blocks(fresh, parsed, "merge")
    got = [b.project for b in db.blocks_on(fresh, D)]
    fresh.close()
    return got


def test_csv_export_neutralises_formulas_and_roundtrips(conn, tmp_path):
    got = _roundtrip(conn, tmp_path, lambda c, rows: xlsx_io.export_csv(rows), "t.csv")
    assert got == NASTY
    csv_text = xlsx_io.export_csv(xlsx_io.export_rows(conn, D, D, {})).decode()
    assert ",'=1+1," in csv_text and ",=1+1," not in csv_text


def test_xlsx_export_stores_formula_like_text_as_strings(conn, tmp_path):
    got = _roundtrip(conn, tmp_path, lambda c, rows: xlsx_io.export_xlsx(c, rows, D, D, {}, T(D + " 12:00").date()), "t.xlsx")
    assert got == NASTY
    data = xlsx_io.export_xlsx(conn, xlsx_io.export_rows(conn, D, D, {}), D, D, {}, T(D + " 12:00").date())
    ws = openpyxl.load_workbook(io.BytesIO(data))["log"]
    cell = next(c for row in ws.iter_rows() for c in row if c.value == "=1+1")
    assert cell.data_type == "s"


# ---- 13. auth ------------------------------------------------------------------------------------------------------

def _basic(user, pw):
    return "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode()


def _guard():
    return auth.BasicAuth(None, "sam", auth.hash_password("pw", iterations=1000))


def test_failed_header_is_remembered_for_a_minute(monkeypatch):
    calls = []
    real = auth.verify_password
    monkeypatch.setattr(auth, "verify_password", lambda *a: calls.append(1) or real(*a))
    g = _guard()
    bad = _basic("sam", "nope")
    assert not asyncio.run(g._allowed(bad)) and not asyncio.run(g._allowed(bad)) and len(calls) == 1
    g._bad[next(iter(g._bad))] -= 61            # a minute later it is tried again
    asyncio.run(g._allowed(bad))
    assert len(calls) == 2
    assert asyncio.run(g._allowed(_basic("sam", "pw"))) and asyncio.run(g._allowed(_basic("sam", "pw")))
    assert len(calls) == 3                      # the success cache still works


def test_failed_header_memory_is_bounded(monkeypatch):
    monkeypatch.setattr(auth, "FAIL_MEMORY_MAX", 3)
    monkeypatch.setattr(auth, "verify_password", lambda *a: False)
    g = _guard()
    for i in range(10):
        asyncio.run(g._allowed(_basic("sam", f"w{i}")))
    assert len(g._bad) == 3


def test_at_most_two_verifications_at_once(monkeypatch):
    live, peak, lock = 0, 0, threading.Lock()

    def slow(*a):
        nonlocal live, peak
        with lock:
            live += 1
            peak = max(peak, live)
        time.sleep(0.05)
        with lock:
            live -= 1
        return False

    monkeypatch.setattr(auth, "verify_password", slow)
    g = _guard()

    async def run():
        await asyncio.gather(*(g._allowed(_basic("sam", f"w{i}")) for i in range(8)))

    asyncio.run(run())
    assert peak == 2


def test_security_headers_on_every_response(tmp_path):
    app = create_app(Settings(db_path=str(tmp_path / "t.db"), auth_user="sam",
                              auth_password_hash=auth.hash_password("pw", iterations=1000)))
    c = TestClient(app)
    for r in (c.get("/healthz"), c.get("/api/status"), c.get("/api/status", headers={"Authorization": _basic("sam", "pw")})):
        assert r.headers["x-content-type-options"] == "nosniff"
        assert r.headers["x-frame-options"] == "DENY"
        assert r.headers["referrer-policy"] == "same-origin"
        assert "content-security-policy" not in r.headers


# ---- A, B, C: the client contract --------------------------------------------------------------------------------------

def test_full_status_carries_resume(app, client):
    assert client.get("/api/status").json()["resume"] is None
    client.post("/api/start", json={"type": "meet", "project": "weekly"})
    at(app, D + " 10:00")
    client.post("/api/pause", json={})
    full, brief = client.get("/api/status").json(), client.get("/api/status?brief=1").json()
    assert full["resume"] == brief["resume"] == {"type": "meet", "project": "weekly"}


def test_default_break_type_comes_first(client):
    assert client.get("/api/status?brief=1").json()["breaks"][0] == "eat"
    client.put("/api/settings", json={"default_break_type": "sport"})
    full, brief = client.get("/api/status").json(), client.get("/api/status?brief=1").json()
    assert full["chips"]["break_types"][0] == "sport" and brief["breaks"][0] == "sport"
    assert client.get("/api/chips").json()["break_types"][0] == "sport"


def test_expect_state(app, client):
    r = client.post("/api/stop", json={"expect_state": "working"})
    assert r.status_code == 409 and r.json() == {"error": "state changed", "state": "stopped"}
    assert client.post("/api/start", json={"expect_state": "working"}).status_code == 409
    assert client.post("/api/start", json={"expect_state": "stopped"}).json()["state"] == "working"
    r = client.post("/api/pause", json={"expect_state": "stopped"})
    assert r.status_code == 409 and r.json()["state"] == "working"
    assert client.post("/api/pause", json={"expect_state": "working"}).json()["state"] == "break"
    r = client.post("/api/start?brief=1", json={"expect_state": "working"})
    assert r.status_code == 409 and r.json()["state"] == "break"
    assert client.post("/api/stop?brief=1", json={"expect_state": "break"}).json()["state"] == "stopped"
    for bad in ("paused", 3, ["working"]):
        assert client.post("/api/stop", json={"expect_state": bad}).status_code == 400


def test_expect_state_sees_state_after_auto_close(app, client):
    at(app, "2026-10-19 09:00")
    client.post("/api/start", json={})
    at(app, D + " 07:30")
    r = client.post("/api/stop", json={"expect_state": "working"})
    assert r.status_code == 409 and r.json()["state"] == "stopped"


def test_expect_state_is_ignored_with_at(app, client):
    r = client.post("/api/start", json={"expect_state": "working", "at": D + "T08:00"})
    assert r.status_code == 200 and r.json()["state"] == "working"
