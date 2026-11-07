import json
from datetime import date, datetime

import pytest

from balance import db as bdb
from day import rules
from day.sources import Context

TODAY = date(2026, 11, 5)          # a Thursday: the school run defaults to Sam
NOW = datetime(2026, 11, 5, 9, 0)


def write_state(d, *, colour="red", coverage_end="2026-11-14"):
    d.mkdir(exist_ok=True)
    (d / "gate.json").write_text(json.dumps({
        "date": TODAY.isoformat(), "colour": colour, "signals": [], "gaps": [], "protect": "hard stop 18:00",
        "speak": True, "pre_event": None, "numbers": {"hours_21d_avg": 36.0},
        "line": "🔴 Capacity: red. three weeks averaging 36 h. Protect: hard stop 18:00."}))
    (d / "goals.json").write_text(json.dumps({
        "project": "Acme", "open": 12,
        "milestones": [{"id": "m1", "content": "Code freeze", "due": "2026-11-14", "priority": 4},
                       {"id": "m2", "content": "Astrid v1 release", "due": "2026-11-28", "priority": 4}],
        "top3": [{"id": "t1", "content": "Sign-off checklist for QA", "due": "2026-11-05", "priority": 4, "labels": []},
                 {"id": "t2", "content": "Fix retrieval regression", "due": "2026-11-05", "priority": 3, "labels": []},
                 {"id": "t3", "content": "Release notes draft", "due": "2026-11-04", "priority": 2, "labels": ["doubt"]}],
        "due_today_or_overdue": 3}))
    (d / "personal.json").write_text(json.dumps({"events": [
        {"date": "2026-11-05", "start": "19:30", "end": "20:30", "all_day": False, "title": "Dinner", "calendar": "Personal"},
        {"date": "2026-11-05", "start": "17:00", "end": "18:00", "all_day": False, "title": "Kim swimming", "calendar": "Family"},
        {"date": "2026-11-05", "start": "10:00", "end": "11:00", "all_day": False, "title": "Haircut", "calendar": "Family"},
        {"date": "2026-11-05", "start": "15:00", "end": "16:00", "all_day": False, "title": "Doctor", "calendar": "Family"},
    ]}))
    (d / "mirror.json").write_text(json.dumps({"events": [
        {"id": 1, "date": "2026-11-05", "start": "08:30", "end": "09:00", "title": "Early sync", "organizer": "", "status": "confirmed", "note": "", "source": "outlook-2026-10-28.pdf", "updated_at": ""},
        {"id": 2, "date": "2026-11-05", "start": "09:30", "end": "10:00", "title": "Astrid v1 stand-up", "organizer": "", "status": "confirmed", "note": "", "source": "outlook-2026-10-28.pdf", "updated_at": ""},
        {"id": 3, "date": "2026-11-05", "start": "11:00", "end": "12:00", "title": "Model review", "organizer": "", "status": "confirmed", "note": "", "source": "dashboard", "updated_at": ""},
        {"id": 4, "date": "2026-11-05", "start": "13:00", "end": "13:30", "title": "Vendor demo", "organizer": "", "status": "cancelled", "note": "", "source": "outlook-2026-10-28.pdf", "updated_at": ""},
    ], "coverage": {"last_import_end": coverage_end, "last_import_at": "2026-10-28 10:00:00", "last_import_source": "outlook-2026-10-28.pdf"}}))
    (d / "annotations.json").write_text(json.dumps({"one_off": [
        {"date": "2026-11-05", "start": "15:00", "title": "Doctor", "owner": None, "tier": "context", "note": None}], "recurring": []}))
    (d / "sync.json").write_text(json.dumps({"ran": "2026-11-05T08:50:00", "google": "ok", "errors": []}))


@pytest.fixture
def state_dir(tmp_path):
    d = tmp_path / "state"
    write_state(d)
    return d


@pytest.fixture
def plan_path(tmp_path):
    p = tmp_path / "plan.csv"
    p.write_text("date,session,type,distance_km,surface,elevation_m\n2026-11-05,Easy Run,easy,8,road,\n2026-11-06,Rest,rest,,,\n")
    return str(p)


@pytest.fixture
def balance_conn(tmp_path):
    c = bdb.connect(":memory:")
    bdb.add_block(c, "2026-11-05", "07:30", "08:30", "run", "Easy Run", state="approved")
    bdb.add_block(c, "2026-11-05", "18:00", "18:30", "stop", "Hard stop", state="proposed")
    bdb.enqueue(c, "todoist_complete", {"task_id": "t1"}, "Done: Sign-off checklist for QA")
    yield c
    c.close()


WORKLOG_STATUS = {"state": "working", "since": "08:32", "elapsed_min": 28, "running_min": 28,
                  "today": {"work_h": 1.7, "work_h_live": 2.17, "expected_h": 7.0},
                  "week": {"worked_h": 12.2, "worked_h_live": 12.67, "expected_h": 28.0}}


@pytest.fixture
def ctx(state_dir, plan_path, balance_conn):
    return Context(date=TODAY, now=NOW, state_dir=str(state_dir), balance_conn=balance_conn, plan_path=plan_path,
                   holidays={}, rules=rules.load(), worklog_status=dict(WORKLOG_STATUS),
                   balance_settings=bdb.get_settings(balance_conn))
