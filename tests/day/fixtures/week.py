"""A seven-day picture for the slot engine tests: Mon 2026-11-02 .. Sun 2026-11-08.

- mirror coverage to Fri 11-06 (Sat/Sun unknown); work meetings Mon–Fri
- school drop-off/pick-up every weekday (Robin default, Sam on Thu)
- Family event Wed 17:00–18:00 "Kim swimming" (child), Family "Haircut" Tue 10:00 (unclassified)
- approved run block Tue 07:30–08:30, hard stop Mon–Fri 18:00–18:30 (approved)
- gate red; plan: Tue easy, Thu intervals, Sat long, Fri rest, Wed easy, Mon rest, Sun rest
- a pending queued gcal_create Wed 13:00–14:00 "Dentist" (counts as busy)
"""
import copy
import json
from datetime import date, datetime

from balance import db as bdb
from day import rules
from day.sources import Context

MON = date(2026, 11, 2)
DAYS = [date(2026, 11, 2 + i).isoformat() for i in range(7)]
NOW = datetime(2026, 11, 2, 9, 0)      # Monday 09:00

WORK = {
    "2026-11-02": [("09:30", "10:00", "Stand-up"), ("11:00", "12:00", "Model review"), ("14:30", "15:15", "Release readiness")],
    "2026-11-03": [("09:30", "10:00", "Stand-up"), ("13:00", "14:00", "Lunch & learn")],
    "2026-11-04": [("09:00", "10:00", "Governance"), ("15:00", "15:30", "1:1")],
    "2026-11-05": [("09:30", "10:00", "Stand-up"), ("10:30", "11:30", "Eval walkthrough")],
    "2026-11-06": [("09:30", "10:00", "Stand-up"), ("11:00", "12:00", "Sprint review")],
}
PLAN = "date,session,type,distance_km,surface,elevation_m\n" + "\n".join([
    "2026-11-02,Rest,rest,,,", "2026-11-03,Easy Run,easy,8,road,", "2026-11-04,Easy Run,easy,6,road,",
    "2026-11-05,Intervals,intervals,10,road,", "2026-11-06,Rest,rest,,,", "2026-11-07,Long Run,long,18,trail,",
    "2026-11-08,Rest,rest,,,"]) + "\n"

WORKLOG_STATUS = {"state": "working", "since": "08:32", "elapsed_min": 28, "running_min": 28,
                  "today": {"work_h": 0.5, "work_h_live": 0.97, "expected_h": 7.0},
                  "week": {"worked_h": 0.5, "worked_h_live": 0.97, "expected_h": 35.0}}


def write_state(d, *, colour="red", pre_event=None, coverage_end="2026-11-06"):
    d.mkdir(exist_ok=True)
    (d / "gate.json").write_text(json.dumps({
        "date": "2026-11-02", "colour": colour, "signals": [], "gaps": [], "protect": "hard stop 18:00",
        "speak": True, "pre_event": pre_event, "numbers": {}, "line": f"Capacity: {colour}."}))
    (d / "goals.json").write_text(json.dumps({"fetched": "2026-11-02T08:00:00", "project": "Acme", "open": 3,
                                              "milestones": [], "top3": [], "due_today_or_overdue": 0}))
    (d / "personal.json").write_text(json.dumps({"events": [
        {"date": "2026-11-04", "start": "17:00", "end": "18:00", "all_day": False, "title": "Kim swimming", "calendar": "Family", "uid": "swim@google.com"},
        {"date": "2026-11-03", "start": "10:00", "end": "11:00", "all_day": False, "title": "Haircut", "calendar": "Family", "uid": "hair@google.com"},
        {"date": "2026-11-03", "start": "20:00", "end": "21:00", "all_day": False, "title": "Dinner out", "calendar": "Personal", "uid": "din@google.com"},
    ]}))
    events = []
    i = 1
    for day, meetings in WORK.items():
        for s, e, t in meetings:
            events.append({"id": i, "date": day, "start": s, "end": e, "title": t, "organizer": "", "status": "confirmed",
                           "note": "", "source": "outlook-2026-10-28.pdf", "updated_at": ""})
            i += 1
    (d / "mirror.json").write_text(json.dumps({"events": events, "coverage": {
        "last_import_end": coverage_end, "last_import_at": "2026-10-28 10:00:00", "last_import_source": "pdf",
        "ranges": [["2026-10-27", coverage_end]]}}))
    (d / "annotations.json").write_text(json.dumps({"one_off": [], "recurring": [], "taken": "2026-11-02T08:00:00"}))
    (d / "sync.json").write_text(json.dumps({"ran": "2026-11-02T08:50:00", "google": "ok", "errors": []}))


def make_ctx(tmp_path, *, colour="red", pre_event=None, coverage_end="2026-11-06", now=NOW):
    state = tmp_path / "state"
    write_state(state, colour=colour, pre_event=pre_event, coverage_end=coverage_end)
    plan = tmp_path / "plan.csv"
    plan.write_text(PLAN)
    conn = bdb.connect(":memory:")
    bdb.add_block(conn, "2026-11-03", "07:30", "08:30", "run", "Easy Run", state="approved", source="propose")
    for day in DAYS[:5]:
        bdb.add_block(conn, day, "18:00", "18:30", "stop", "Hard stop", state="approved", source="gate")
    bdb.enqueue(conn, "gcal_create", {"calendar": "Personal", "date": "2026-11-04", "start": "13:00", "end": "14:00", "title": "Dentist"}, "Dentist")
    return Context(date=now.date(), now=now, state_dir=str(state), balance_conn=conn, plan_path=str(plan),
                   holidays={}, rules=rules.load(), worklog_status=copy.deepcopy(WORKLOG_STATUS),
                   balance_settings=bdb.get_settings(conn))
