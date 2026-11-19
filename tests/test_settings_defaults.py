"""The defaults behind Start and Pause, the auto-close time and auto-adding meetings, through /api/settings."""
from datetime import datetime

from fastapi.testclient import TestClient

from tests.helpers import cal
from worklog.config import Settings
from worklog.web.app import create_app

DAY = "2026-10-20"


def test_settings_list_the_defaults(client):
    st = client.get("/api/settings").json()
    assert (st["default_type"], st["default_client"], st["default_break_type"], st["auto_close_time"]) == (
        "dev", "ACME", "eat", "18:00")
    assert st["calendar_auto_add"] is False
    assert "eat" in st["break_types"] and "dev" not in st["break_types"]


def test_default_type_and_break_type_drive_start_and_pause(client):
    st = client.put("/api/settings", json={"default_type": " prep ", "default_break_type": "rest"}).json()
    assert (st["default_type"], st["default_break_type"]) == ("prep", "rest")
    assert client.post("/api/start", json={}).json()["block"]["type"] == "prep"
    assert client.post("/api/pause", json={}).json()["block"]["type"] == "rest"
    for bad in ({"default_type": ""}, {"default_type": "eat"}, {"default_type": 5}, {"default_type": "x" * 41},
                {"default_break_type": "dev"}, {"default_break_type": None}):
        assert client.put("/api/settings", json=bad).status_code == 400, bad
    assert client.get("/api/settings").json()["default_type"] == "prep"


def test_default_client_can_be_changed_or_cleared(client):
    assert client.put("/api/settings", json={"default_client": "Globex"}).json()["default_client"] == "Globex"
    assert client.post("/api/start", json={}).json()["block"]["client"] == "Globex"
    assert client.put("/api/settings", json={"default_client": None}).json()["default_client"] is None
    assert client.put("/api/settings", json={"default_client": "  "}).json()["default_client"] is None
    assert client.put("/api/settings", json={"default_client": 3}).status_code == 400


def test_auto_close_time(client):
    assert client.put("/api/settings", json={"auto_close_time": "1930"}).json()["auto_close_time"] == "19:30"
    assert client.put("/api/settings", json={"auto_close_time": "25:00"}).status_code == 400
    assert client.put("/api/settings", json={"auto_close_time": None}).status_code == 400


def _cal_client(tmp_path, events, now=(9, 0)):
    c_ = cal(tmp_path, [(DAY, s, e, t, "confirmed") for s, e, t in events])
    app = create_app(Settings(db_path=str(tmp_path / "t.db"), calendar_db_path=c_, holidays_path=None))
    app.state.clock = lambda: datetime(2026, 10, 20, *now)
    return TestClient(app)


def _at(c, h, m):
    c.app.state.clock = lambda: datetime(2026, 10, 20, h, m)


def _spans(c):
    return [(b["start"], b["end"], b["type"], b["source"]) for b in c.get(f"/api/day/{DAY}").json()["blocks"]]


def test_meetings_are_not_added_on_their_own_by_default(tmp_path):
    c = _cal_client(tmp_path, [("10:00", "10:30", "review")])
    c.post("/api/start", json={"type": "dev"})
    _at(c, 11, 0)
    c.get("/api/status")
    assert _spans(c) == [("09:00", None, "dev", "timer")]


def test_auto_add_cuts_a_finished_meeting_into_the_logged_time(tmp_path):
    c = _cal_client(tmp_path, [("10:00", "10:30", "review"), ("11:00", "11:30", "running"), ("15:00", "15:30", "later"),
                               ("07:00", "07:30", "before work")])
    assert c.put("/api/settings", json={"calendar_auto_add": True}).json()["calendar_auto_add"] is True
    c.post("/api/start", json={"type": "dev"})
    _at(c, 11, 10)   # "review" is over, "running" is not, "later" has not begun, "before work" was not logged time
    c.get("/api/status")
    assert _spans(c) == [("09:00", "10:00", "dev", "timer"), ("10:00", "10:30", "meet", "calendar"),
                         ("10:30", None, "dev", "timer")]
    day = c.get(f"/api/day/{DAY}").json()
    assert [p["title"] for p in day["proposals"]] == ["before work", "running", "later"]
    assert c.get("/api/status").json()["state"] == "working"


def test_auto_added_meeting_that_was_deleted_stays_away(tmp_path):
    c = _cal_client(tmp_path, [("10:00", "10:30", "review")])
    c.put("/api/settings", json={"calendar_auto_add": True})
    c.post("/api/blocks", json={"date": DAY, "start": "09:00", "end": "11:00", "type": "dev"})
    _at(c, 12, 0)
    blocks = c.get(f"/api/day/{DAY}").json()["blocks"]
    meet = next(b for b in blocks if b["type"] == "meet")
    c.delete(f"/api/blocks/{meet['id']}")
    day = c.get(f"/api/day/{DAY}").json()
    assert [b["type"] for b in day["blocks"]] == ["dev", "dev"]
    assert day["meetings"][0]["dismissed"] is True and day["proposals"] == []


def test_auto_add_leaves_a_dismissed_meeting_alone(tmp_path):
    c = _cal_client(tmp_path, [("10:00", "10:30", "review")])
    c.put("/api/settings", json={"calendar_auto_add": True})
    c.post("/api/calendar/dismiss", json={"date": DAY, "start": "10:00", "title": "review"})
    c.post("/api/blocks", json={"date": DAY, "start": "09:00", "end": "11:00", "type": "dev"})
    _at(c, 12, 0)
    assert [b["type"] for b in c.get(f"/api/day/{DAY}").json()["blocks"]] == ["dev"]


def test_adding_by_hand_what_was_just_added_does_not_double_it(tmp_path):
    c = _cal_client(tmp_path, [("10:00", "10:30", "review")])
    c.put("/api/settings", json={"calendar_auto_add": True})
    c.post("/api/blocks", json={"date": DAY, "start": "09:00", "end": "11:00", "type": "dev"})
    _at(c, 12, 0)
    r = c.post("/api/calendar/add", json={"date": DAY, "start": "10:00", "end": "10:30", "title": "review"})
    assert r.status_code == 200 and r.json()["type"] == "meet"
    assert [b["type"] for b in c.get(f"/api/day/{DAY}").json()["blocks"]] == ["dev", "meet", "dev"]
