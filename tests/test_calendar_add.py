"""Adding a calendar meeting over blocks that are already closed, and the day's meeting list."""
from datetime import datetime

from fastapi.testclient import TestClient

from tests.helpers import cal
from worklog.config import Settings
from worklog.web.app import create_app

DAY = "2026-10-20"


def _client(tmp_path, events, now=(12, 0)):
    c_ = cal(tmp_path, [(DAY, s, e, t, "confirmed") for s, e, t in events])
    app = create_app(Settings(db_path=str(tmp_path / "t.db"), calendar_db_path=c_, holidays_path=None))
    app.state.clock = lambda: datetime(2026, 10, 20, *now)
    return TestClient(app)


def _day(c):
    return c.get(f"/api/day/{DAY}").json()


def _spans(c):
    return [(b["start"], b["end"], b["type"]) for b in _day(c)["blocks"]]


def _add(c, start, end, title):
    return c.post("/api/calendar/add", json={"date": DAY, "start": start, "end": end, "title": title})


def test_meeting_under_a_closed_work_block_is_proposed_and_cut_out_of_it(tmp_path):
    c = _client(tmp_path, [("10:00", "10:30", "review")])
    c.post("/api/blocks", json={"date": DAY, "start": "09:00", "end": "11:00", "type": "dev", "project": "widgets"})
    day = _day(c)
    assert day["proposals"] == [{"start": "10:00", "end": "10:30", "title": "review"}]
    assert day["meetings"] == [{"start": "10:00", "end": "10:30", "title": "review", "logged": False, "dismissed": False}]
    assert _add(c, "10:00", "10:30", "review").status_code == 200
    day = _day(c)
    assert [(b["start"], b["end"], b["type"], b["project"]) for b in day["blocks"]] == [
        ("09:00", "10:00", "dev", "widgets"), ("10:00", "10:30", "meet", "review"), ("10:30", "11:00", "dev", "widgets")]
    assert day["proposals"] == [] and day["overlaps"] == []
    assert day["meetings"] == [{"start": "10:00", "end": "10:30", "title": "review", "logged": True, "dismissed": False}]


def test_add_trims_or_removes_the_closed_blocks_it_overlaps(tmp_path):
    c = _client(tmp_path, [("10:00", "11:00", "workshop")])
    for s, e, t in [("09:00", "10:15", "dev"), ("10:15", "10:45", "prep"), ("10:45", "11:30", "dev")]:
        c.post("/api/blocks", json={"date": DAY, "start": s, "end": e, "type": t})
    _add(c, "10:00", "11:00", "workshop")
    assert _spans(c) == [("09:00", "10:00", "dev"), ("10:00", "11:00", "meet"), ("11:00", "11:30", "dev")]


def test_add_leaves_another_meeting_block_alone(tmp_path):
    c = _client(tmp_path, [("10:00", "10:30", "review"), ("10:15", "10:45", "clash")])
    _add(c, "10:00", "10:30", "review")
    assert _day(c)["proposals"] == []   # the overlapping one counts as logged
    _add(c, "10:15", "10:45", "clash")
    assert _spans(c) == [("10:00", "10:30", "meet"), ("10:15", "10:45", "meet")]


def test_earlier_meeting_stays_proposed_after_a_later_one_was_added(tmp_path):
    c = _client(tmp_path, [("10:00", "10:30", "review"), ("11:00", "11:20", "huddle")], now=(9, 0))
    c.post("/api/start", json={"type": "dev"})
    c.app.state.clock = lambda: datetime(2026, 10, 20, 12, 0)
    _add(c, "11:00", "11:20", "huddle")
    assert [p["title"] for p in _day(c)["proposals"]] == ["review"]
    _add(c, "10:00", "10:30", "review")
    assert _spans(c) == [("09:00", "10:00", "dev"), ("10:00", "10:30", "meet"), ("10:30", "11:00", "dev"),
                         ("11:00", "11:20", "meet"), ("11:20", None, "dev")]


def test_dismissed_meeting_stays_listed_as_dismissed(tmp_path):
    c = _client(tmp_path, [("10:00", "10:30", "review")])
    c.post("/api/calendar/dismiss", json={"date": DAY, "start": "10:00", "title": "review"})
    day = _day(c)
    assert day["proposals"] == []
    assert day["meetings"] == [{"start": "10:00", "end": "10:30", "title": "review", "logged": False, "dismissed": True}]


def test_meeting_queued_from_the_day_page_shows_at_once(tmp_path):
    from balance import db as bdb
    c_ = cal(tmp_path, [(DAY, "09:00", "09:30", "standup", "confirmed"), (DAY, "15:00", "15:30", "retro", "confirmed")])
    bpath = str(tmp_path / "b.db")
    conn = bdb.connect(bpath)
    bdb.enqueue(conn, "mirror_add", {"date": DAY, "start": "12:00", "end": "12:30", "title": "lunch talk"}, "Work: lunch talk")
    bdb.enqueue(conn, "mirror_add", {"date": "2026-10-21", "start": "12:00", "end": "12:30", "title": "tomorrow"}, "other day")
    bdb.enqueue(conn, "mirror_annotate", {"date": DAY, "start": "15:00", "title": "retro", "status": "cancelled"}, "cancel")
    conn.close()
    app = create_app(Settings(db_path=str(tmp_path / "t.db"), calendar_db_path=c_, holidays_path=None, balance_db_path=bpath))
    app.state.clock = lambda: datetime(2026, 10, 20, 13, 0)
    c = TestClient(app)
    assert _day(c)["meetings"] == [
        {"start": "09:00", "end": "09:30", "title": "standup", "logged": False, "dismissed": False},
        {"start": "12:00", "end": "12:30", "title": "lunch talk", "logged": False, "dismissed": False, "pending": True}]
    assert _add(c, "12:00", "12:30", "lunch talk").status_code == 200
    assert [m["logged"] for m in _day(c)["meetings"]] == [False, True]
