"""Currency, clients, break types, idempotent timer actions and daylight-saving handling."""
from datetime import datetime
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

from worklog import db, timer
from worklog.config import Settings
from worklog.web.app import create_app

EUR = "€"
AMS = ZoneInfo("Europe/Amsterdam")


def _at(client, *args, **kw):
    client.app.state.clock = lambda: datetime(*args, **kw)


# ---- currency ---------------------------------------------------------------------------

def test_currency_defaults_to_euro_and_can_be_changed(client):
    assert client.get("/api/settings").json()["currency"] == EUR
    assert client.get("/api/status").json()["currency"] == EUR
    assert client.put("/api/settings", json={"currency": "  USD "}).json()["currency"] == "USD"
    assert client.get("/api/status").json()["currency"] == "USD"
    assert client.put("/api/settings", json={"currency": "$"}).json()["currency"] == "$"


def test_bad_currency_is_refused_and_nothing_else_is_saved(client):
    for bad in ("", "   ", "ABCDE", 5, None):
        r = client.put("/api/settings", json={"currency": bad, "rate": 50})
        assert r.status_code == 400, bad
        assert "currency" in r.json()["error"]
    s = client.get("/api/settings").json()
    assert s["currency"] == EUR and s["rate"] is None


# ---- clients ----------------------------------------------------------------------------

def test_clients_list_add_and_duplicates(client):
    assert client.get("/api/clients").json() == [{"name": "ACME", "billable": True}]
    assert client.post("/api/clients", json={"name": "Globex", "billable": False}).json() == {
        "name": "Globex", "billable": False}
    assert client.post("/api/clients", json={"name": "bravo"}).json()["billable"] is True
    assert [c["name"] for c in client.get("/api/clients").json()] == ["ACME", "bravo", "Globex"]
    for bad in ({"name": ""}, {"name": "  "}, {"name": "globex"}, {"name": "acme"}, {}, {"name": 3}):
        assert client.post("/api/clients", json=bad).status_code == 400, bad


def test_rename_client_follows_blocks_and_default_client_but_billable_does_not_rewrite(client):
    client.put("/api/settings", json={"default_client": "ACME"})
    client.post("/api/start", json={})
    client.post("/api/stop", json={})
    client.post("/api/blocks", json={"date": "2026-10-19", "start": "09:00", "end": "10:00",
                                     "type": "dev", "client": "ACME"})
    r = client.put("/api/clients/ACME", json={"name": "Acme Corp"})
    assert r.json() == {"name": "Acme Corp", "billable": True}
    assert client.get("/api/settings").json()["default_client"] == "Acme Corp"
    blocks = client.get("/api/day/2026-10-19").json()["blocks"]
    assert [b["client"] for b in blocks] == ["Acme Corp"]
    assert client.put("/api/clients/Acme Corp", json={"billable": False}).json()["billable"] is False
    assert client.get("/api/day/2026-10-19").json()["blocks"][0]["billable"] is True   # untouched
    assert client.get("/api/clients").json() == [{"name": "Acme Corp", "billable": False}]


def test_client_update_errors(client):
    client.post("/api/clients", json={"name": "Globex"})
    assert client.put("/api/clients/Nope", json={"billable": True}).status_code == 404
    assert client.put("/api/clients/Globex", json={"name": "acme"}).status_code == 400
    assert client.put("/api/clients/Globex", json={"name": ""}).status_code == 400
    assert client.put("/api/clients/Globex", json={"billable": None}).status_code == 400
    assert client.put("/api/clients/Globex", json={"name": "GLOBEX"}).json()["name"] == "GLOBEX"   # own case change


def test_delete_client_is_refused_while_used(client):
    client.post("/api/clients", json={"name": "Globex"})
    assert client.delete("/api/clients/ACME").status_code == 409          # default_client
    client.post("/api/blocks", json={"date": "2026-10-19", "start": "09:00", "end": "10:00",
                                     "type": "dev", "client": "Globex"})
    r = client.delete("/api/clients/Globex")
    assert r.status_code == 409 and "error" in r.json()
    client.post("/api/clients", json={"name": "Unused"})
    assert client.delete("/api/clients/Unused").json() == {"ok": True}
    assert client.delete("/api/clients/Unused").status_code == 404


# ---- break types ------------------------------------------------------------------------

def test_break_types_list_add_delete(client):
    names = client.get("/api/break-types").json()
    assert names[0] == "eat" and "pomo" in names
    assert names == client.get("/api/status").json()["chips"]["break_types"]
    assert "nap" in client.post("/api/break-types", json={"name": " Nap "}).json()
    assert client.post("/api/pause", json={"type": "nap"}).json()["block"]["work_type"] == "other"
    for bad in ({"name": ""}, {"name": "EAT"}, {"name": "nap"}, {}, {"name": 4}):
        assert client.post("/api/break-types", json=bad).status_code == 400, bad
    assert client.delete("/api/break-types/nap").status_code == 409        # a block uses it
    assert client.delete("/api/break-types/eat").status_code == 409        # default_break_type
    assert client.delete("/api/break-types/nope").status_code == 404
    assert "shop" not in client.delete("/api/break-types/shop").json()
    assert "shop" not in client.get("/api/break-types").json()


def test_break_type_cannot_reuse_a_work_type_name(client):
    client.post("/api/start", json={"type": "Consulting"})
    r = client.post("/api/break-types", json={"name": "consulting"})
    assert r.status_code == 400 and "work type" in r.json()["error"]


# ---- idempotent timer actions -----------------------------------------------------------

def test_request_id_replay_does_nothing_and_answers_with_status(client):
    r1 = client.post("/api/start", json={"project": "a", "request_id": "r-1"}).json()
    assert r1["state"] == "working"
    client.post("/api/stop", json={"request_id": "r-2"})
    again = client.post("/api/start", json={"project": "a", "request_id": "r-1"}).json()
    assert again["state"] == "stopped"                      # the replayed start did nothing
    brief = client.post("/api/start?brief=1", json={"request_id": "r-1"}).json()
    assert brief["state"] == "stopped" and "week" not in brief and "now" in brief
    assert len(client.get("/api/day/2026-10-20").json()["blocks"]) == 0   # zero-minute block deleted, never restarted


def test_request_id_validation_and_only_successes_are_remembered(client):
    for bad in ("", "x" * 65, 5, ["a"]):
        assert client.post("/api/start", json={"request_id": bad}).status_code == 400, bad
    # a refused action (409) leaves no memory: the same id works once the state is right
    assert client.post("/api/stop", json={"request_id": "r-9", "expect_state": "working"}).status_code == 409
    client.post("/api/start", json={})
    assert client.post("/api/stop", json={"request_id": "r-9", "expect_state": "working"}).json()["state"] == "stopped"
    assert client.post("/api/start", json={"request_id": "r-10", "type": "eat"}).status_code == 400
    assert client.post("/api/start", json={"request_id": "r-10"}).json()["state"] == "working"


def test_request_id_combines_with_at_and_survives_restart(tmp_path):
    def make():
        app = create_app(Settings(db_path=str(tmp_path / "t.db")))
        app.state.clock = lambda: datetime(2026, 10, 20, 9, 30)
        return TestClient(app)

    c = make()
    c.post("/api/start", json={"at": "2026-10-20T09:00", "request_id": "q-1"})
    c.post("/api/stop", json={"at": "2026-10-20T09:20", "request_id": "q-2"})
    c2 = make()                                             # a new process, the same store
    assert c2.post("/api/stop", json={"at": "2026-10-20T09:25", "request_id": "q-2"}).json()["state"] == "stopped"
    blocks = c2.get("/api/day/2026-10-20").json()["blocks"]
    assert [(b["start"], b["end"]) for b in blocks] == [("09:00", "09:20")]
    assert c2.post("/api/start", json={"request_id": "q-1"}).json()["state"] == "stopped"


def test_only_the_newest_500_request_ids_are_kept(conn):
    for i in range(505):
        db.remember_request(conn, f"id-{i}")
    assert not db.request_seen(conn, "id-0") and not db.request_seen(conn, "id-4")
    assert db.request_seen(conn, "id-5") and db.request_seen(conn, "id-504")
    assert conn.execute("SELECT COUNT(*) FROM timer_requests").fetchone()[0] == 500


# ---- daylight saving --------------------------------------------------------------------

@pytest.fixture
def dst(tmp_path):
    app = create_app(Settings(db_path=str(tmp_path / "t.db"), tz="Europe/Amsterdam"))
    return TestClient(app)


def test_elapsed_across_the_october_change_is_true_elapsed(dst):
    # 2026-10-25: 03:00 CEST becomes 02:00 CET. 01:30 CEST to 02:30 CET (second pass) is 2 h.
    _at(dst, 2026, 10, 25, 1, 30)
    dst.post("/api/start", json={})
    _at(dst, 2026, 10, 25, 2, 30, fold=1)
    st = dst.get("/api/status").json()
    assert st["elapsed_min"] == 120 and st["elapsed_s"] == 7200
    _at(dst, 2026, 10, 25, 2, 30, fold=0)                 # the first pass through 02:30 is 1 h in
    st = dst.get("/api/status").json()
    assert st["elapsed_min"] == 60


def test_elapsed_across_the_march_change_is_true_elapsed(dst):
    # 2026-03-29: 02:00 CET becomes 03:00 CEST. 01:30 CET to 03:30 CEST is 1 h, not 2.
    _at(dst, 2026, 3, 29, 1, 30)
    dst.post("/api/start", json={})
    _at(dst, 2026, 3, 29, 3, 30)
    st = dst.get("/api/status").json()
    assert st["elapsed_min"] == 60 and st["elapsed_s"] == 3600


def _blocks(c):
    return c.get("/api/day/2026-10-25").json()["blocks"]


def test_a_block_from_the_first_to_the_second_pass_is_a_true_hour(dst):
    _at(dst, 2026, 10, 25, 2, 30)                           # first pass through 02:30
    dst.post("/api/start", json={"project": "night"})
    _at(dst, 2026, 10, 25, 2, 30, fold=1)                   # the clock went back: 02:30 again
    dst.post("/api/stop", json={})
    (b,) = _blocks(dst)
    assert (b["start"], b["end"], b["auto_closed"], b["minutes"]) == ("02:30", "02:30", False, 60)
    assert dst.get("/api/status").json()["needs_review"] == []


def test_a_block_ending_earlier_on_the_wall_clock_in_the_second_pass(dst):
    _at(dst, 2026, 10, 25, 2, 30)
    dst.post("/api/start", json={})
    _at(dst, 2026, 10, 25, 2, 10, fold=1)                   # 02:30 first pass to 02:10 second pass
    dst.post("/api/pause", json={})
    closed = [x for x in _blocks(dst) if x["end"]][0]
    assert (closed["start"], closed["end"], closed["auto_closed"]) == ("02:30", "02:10", False)
    assert closed["minutes"] == 40 and closed["duration"] == "00:40"
    assert closed["flags"]["start_gt_end"] is False
    assert dst.get("/api/day/2026-10-25").json()["totals"]["work_h"] == pytest.approx(40 / 60)


def test_a_block_started_in_the_second_pass_has_the_true_elapsed_and_duration(dst):
    _at(dst, 2026, 10, 25, 2, 20, fold=1)
    dst.post("/api/start", json={})
    _at(dst, 2026, 10, 25, 2, 50, fold=1)
    assert dst.get("/api/status").json()["elapsed_min"] == 30      # not 90: the start is the later 02:20
    _at(dst, 2026, 10, 25, 3, 20)
    assert dst.get("/api/status").json()["elapsed_min"] == 60
    dst.post("/api/stop", json={})
    (b,) = _blocks(dst)
    assert (b["start"], b["end"], b["minutes"]) == ("02:20", "03:20", 60)
    row = db.connect(dst.app.state.settings.db_path).execute("SELECT start_fold, end_fold FROM blocks").fetchone()
    assert (row["start_fold"], row["end_fold"]) == (1, None)


def test_a_block_that_covers_the_whole_repeated_hour_counts_both_passes(dst):
    _at(dst, 2026, 10, 25, 1, 30)
    dst.post("/api/start", json={})
    _at(dst, 2026, 10, 25, 3, 30)
    dst.post("/api/stop", json={})
    (b,) = _blocks(dst)
    assert (b["start"], b["end"], b["minutes"]) == ("01:30", "03:30", 180)


def test_reports_and_the_day_total_use_the_true_minutes(dst):
    _at(dst, 2026, 10, 25, 2, 30)
    dst.post("/api/start", json={})
    _at(dst, 2026, 10, 25, 2, 10, fold=1)
    dst.post("/api/stop", json={})                           # 40 true minutes
    assert dst.get("/api/day/2026-10-25").json()["totals"]["work_h"] == pytest.approx(40 / 60)
    rows = dst.get("/api/summary?group=week&start=2026-10-19&end=2026-10-25").json()["rows"]
    assert rows[0]["worked_h"] == pytest.approx(40 / 60)


def test_a_typed_block_in_the_repeated_hour_is_the_first_pass(dst):
    r = dst.post("/api/blocks", json={"date": "2026-10-25", "start": "02:10", "end": "02:50"})
    assert r.status_code == 200 and r.json()["minutes"] == 40
    assert dst.post("/api/blocks", json={"date": "2026-10-25", "start": "02:50", "end": "02:10"}).status_code == 400


def test_editing_a_time_drops_its_fold_and_an_unchanged_time_keeps_it(dst):
    _at(dst, 2026, 10, 25, 2, 20, fold=1)
    bid = dst.post("/api/start", json={}).json()["block"]["id"]
    _at(dst, 2026, 10, 25, 3, 20)
    dst.post("/api/stop", json={})
    q = lambda: db.connect(dst.app.state.settings.db_path).execute("SELECT start_fold FROM blocks").fetchone()[0]
    dst.put(f"/api/blocks/{bid}", json={"start": "02:20", "project": "x"})
    assert q() == 1
    dst.put(f"/api/blocks/{bid}", json={"start": "02:25"})
    assert q() is None


def test_start_in_the_second_pass_is_not_flagged_against_a_first_pass_block(dst):
    _at(dst, 2026, 10, 25, 2, 40)
    dst.post("/api/start", json={})
    _at(dst, 2026, 10, 25, 2, 10, fold=1)
    dst.post("/api/pause", json={})
    _at(dst, 2026, 10, 25, 2, 40, fold=1)
    dst.post("/api/stop", json={})
    blocks = _blocks(dst)
    assert [(b["start"], b["end"]) for b in blocks] == [("02:10", "02:40"), ("02:40", "02:10")]
    assert not any(b["flags"]["overlap"] or b["flags"]["start_gt_end"] for b in blocks)


def test_the_migration_adds_the_fold_columns_and_keeps_old_rows_null(tmp_path):
    p = str(tmp_path / "old.db")
    c = db.connect(p)
    db.insert_block(c, db.Block(None, "2026-10-25", "02:10", "02:50", None, "dev", None, None))
    c.execute("ALTER TABLE blocks DROP COLUMN start_fold")
    c.execute("ALTER TABLE blocks DROP COLUMN end_fold")
    c.execute("PRAGMA user_version = 7")
    c.commit(); c.close()
    c = db.connect(p)
    r = c.execute("SELECT start_fold, end_fold FROM blocks").fetchone()
    assert (r[0], r[1]) == (None, None) and c.execute("PRAGMA user_version").fetchone()[0] == 8


# ---- rename a break type ----------------------------------------------------------------

def test_rename_a_break_type_everywhere(client):
    client.post("/api/pause", json={"type": "eat"})
    client.post("/api/stop", json={})
    client.app.state.clock = lambda: datetime(2026, 10, 20, 9, 30)
    client.put("/api/settings", json={"default_break_type": "eat"})
    client.post("/api/blocks", json={"date": "2026-10-20", "start": "10:00", "end": "10:30", "type": "eat"})
    r = client.put("/api/break-types/eat", json={"name": "  Lunch "})
    assert r.status_code == 200 and "lunch" in r.json() and "eat" not in r.json()
    assert client.get("/api/break-types").json()[0] == "lunch"      # the default comes first
    assert client.get("/api/settings").json()["default_break_type"] == "lunch"
    assert {b["type"] for b in client.get("/api/day/2026-10-20").json()["blocks"]} == {"lunch"}
    assert client.post("/api/pause", json={"type": "eat"}).status_code == 400


def test_rename_a_break_type_errors(client):
    assert client.put("/api/break-types/nope", json={"name": "x"}).status_code == 404
    assert client.put("/api/break-types/eat", json={"name": " "}).status_code == 400
    assert client.put("/api/break-types/eat", json={}).status_code == 400
    assert client.put("/api/break-types/eat", json={"name": "SHOP"}).status_code == 400   # duplicate
    client.post("/api/blocks", json={"date": "2026-10-20", "start": "10:00", "end": "10:30", "type": "dev"})
    assert client.put("/api/break-types/eat", json={"name": "Dev"}).status_code == 400    # a work type
    assert "eat" in client.get("/api/break-types").json()


def test_a_start_and_stop_in_the_same_minute_is_still_deleted(dst):
    _at(dst, 2026, 10, 25, 2, 30)
    dst.post("/api/start", json={})
    dst.post("/api/stop", json={})
    assert dst.get("/api/day/2026-10-25").json()["blocks"] == []


def test_timer_close_open_without_a_zone_is_unchanged(conn):
    now = datetime(2026, 10, 25, 2, 30)
    timer.start(conn, now)
    assert timer.stop(conn, datetime(2026, 10, 25, 2, 30, fold=1)) is None   # no zone: zero minutes, deleted


def test_at_in_the_repeated_hour_means_the_later_pass(dst):
    _at(dst, 2026, 10, 25, 2, 40)                              # a block starts in the first pass
    dst.post("/api/start", json={})
    _at(dst, 2026, 10, 25, 2, 50, fold=1)
    # 02:30 on the later pass is after the running block started (02:40 on the first): accepted
    r = dst.post("/api/pause", json={"at": "2026-10-25T02:30"})
    assert r.status_code == 200 and r.json()["since"] == "02:30"


def test_at_in_the_repeated_hour_uses_the_first_pass_while_the_later_one_is_ahead(dst):
    _at(dst, 2026, 10, 25, 2, 45)                              # first pass
    r = dst.post("/api/start", json={"at": "2026-10-25T02:30"})
    assert r.status_code == 200 and r.json()["since"] == "02:30"


def test_at_in_the_skipped_hour_is_the_valid_time_after_the_gap(dst):
    _at(dst, 2026, 3, 29, 3, 40)
    r = dst.post("/api/start", json={"at": "2026-03-29T02:30"})   # 02:30 does not exist that day
    assert r.status_code == 200 and r.json()["since"] == "03:30"
    assert r.json()["elapsed_min"] == 10


def test_at_in_the_future_is_still_refused_with_a_zone(dst):
    _at(dst, 2026, 10, 25, 1, 40)
    assert dst.post("/api/start", json={"at": "2026-10-25T02:30"}).status_code == 400
