from datetime import date

from balance import db
from balance.propose import next_monday, plan_blocks, propose, week_days

MON = date(2026, 11, 9)
DAYS = week_days(MON, date(2026, 11, 15))
PLAN = [
    {"date": date(2026, 11, 9), "session": "Easy Run (7.5km)", "type": "easy", "distance_km": 7.5},
    {"date": date(2026, 11, 10), "session": "Rest", "type": "rest", "distance_km": None},
    {"date": date(2026, 11, 11), "session": "Intervals", "type": "intervals", "distance_km": 9},
    {"date": date(2026, 11, 14), "session": "Long Run (16km)", "type": "long", "distance_km": 16},
]
SETTINGS = {"hard_stop": "18:00", "run_slot": "07:30", "run_alt_slots": "13:00,18:00"}


def test_runs_and_hard_stops():
    out = plan_blocks(DAYS, PLAN, [], SETTINGS, [])
    runs = [b for b in out if b["kind"] == "run"]
    stops = [b for b in out if b["kind"] == "stop"]
    assert [b["date"] for b in runs] == ["2026-11-09", "2026-11-11", "2026-11-14"]
    assert runs[0]["start"] == "07:30" and runs[0]["end"] == "08:30"
    assert runs[2]["end"] == "09:30"  # long = 120 min
    assert len(stops) == 5 and stops[0]["start"] == "18:00"


def test_clash_moves_to_next_slot_and_notes_when_none_fits():
    busy = [{"date": "2026-11-09", "start": "07:00", "end": "09:00", "title": "standup"}]
    out = plan_blocks(DAYS[:1], PLAN, busy, SETTINGS, [])
    run = next(b for b in out if b["kind"] == "run")
    assert run["start"] == "13:00" and run["note"] == ""
    busy_all = busy + [{"date": "2026-11-09", "start": "12:00", "end": "19:30", "title": "x"}]
    run = next(b for b in plan_blocks(DAYS[:1], PLAN, busy_all, SETTINGS, []) if b["kind"] == "run")
    assert run["start"] == "07:30" and "clashes" in run["note"]


def test_never_a_second_block_of_the_same_kind():
    existing = [{"date": "2026-11-09", "kind": "run"}, {"date": "2026-11-09", "kind": "stop"}]
    out = plan_blocks(DAYS[:1], PLAN, [], SETTINGS, existing)
    assert out == []


def test_propose_writes_and_is_idempotent():
    conn = db.connect(":memory:")
    created = propose(conn, DAYS, PLAN, [], "sunday")
    assert len(created) == 8 and all(b["state"] == "proposed" for b in created)
    assert propose(conn, DAYS, PLAN, [], "sunday") == []
    db.decide(conn, created[0]["id"], "rejected")
    again = propose(conn, DAYS, PLAN, [], "red")
    assert len(again) == 1 and again[0]["date"] == created[0]["date"]


def test_next_monday():
    assert next_monday(date(2026, 11, 2)) == date(2026, 11, 9)   # a Monday → next week
    assert next_monday(date(2026, 11, 8)) == date(2026, 11, 9)   # Sunday → tomorrow


def test_hand_kept_hard_stop_is_not_duplicated():
    personal = [{"date": "2026-11-09", "title": "🛑 Hard stop — end work", "start": "18:00", "end": "18:15"}]
    out = plan_blocks(DAYS[:2], PLAN, [], SETTINGS, [], personal)
    stops = [b["date"] for b in out if b["kind"] == "stop"]
    assert stops == ["2026-11-10"]
