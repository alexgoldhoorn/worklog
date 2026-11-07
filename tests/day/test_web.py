"""/api/day inside the worklog app: model, prep notes, owner and task writes (Task 7)."""
from datetime import datetime
from pathlib import Path

import pytest

from balance import db as bdb
from tests.day.conftest import NOW, write_state
from tests.helpers import cal


@pytest.fixture
def dayclient(client, app, tmp_path):
    write_state(Path(app.state.settings.balance_state_dir))
    plan = tmp_path / "plan.csv"
    plan.write_text("date,session,type,distance_km,surface,elevation_m\n2026-11-05,Easy Run,easy,8,road,\n")
    app.state.settings.plan_path = str(plan)
    app.state.clock = lambda: NOW
    return client


def test_get_day_matches_status_timer(dayclient):
    assert dayclient.post("/api/start", json={"type": "dev"}).status_code == 200
    status = dayclient.get("/api/status").json()
    day = dayclient.get("/api/day").json()
    assert day["date"] == "2026-11-05" and day["work"]["status"]["state"] == "working"
    assert day["work"]["status"]["elapsed_min"] == status["elapsed_min"]
    assert day["work"]["today_h"] == round(status["today"]["work_h_live"], 2)
    assert day["training"]["session"] == "Easy Run"
    assert dayclient.get("/api/day?date=2026-11-06").json()["date"] == "2026-11-06"
    assert dayclient.get("/api/day?date=bad").status_code == 400


def test_prep_note_roundtrip_and_start_by(dayclient):
    r = dayclient.post("/api/day/prep", json={"date": "2026-11-05", "start": "08:30", "title": "Early sync",
                                              "minutes": 30, "text": "read the overnight report"})
    assert r.status_code == 200 and r.json()["prep"]["minutes"] == 30
    ft = dayclient.get("/api/day").json()["first_things"]
    meeting = next(x for x in ft if x["kind"] == "meeting")
    assert meeting["prep"]["start_by"] == "08:00"
    assert dayclient.post("/api/day/prep", json={"date": "2026-11-05", "start": "08:30", "title": "x", "minutes": 999, "text": ""}).status_code == 400


def test_owner_write_enqueues(dayclient, app):
    r = dayclient.post("/api/day/owner", json={"date": "2026-11-05", "start": "08:45", "title": "School drop-off", "owner": "Robin"})
    assert r.status_code == 200 and r.json()["queued"]["kind"] == "annotate"
    conn = bdb.connect(app.state.settings.balance_db_path)
    assert bdb.queue_pending(conn)[0]["payload"] == {"date": "2026-11-05", "start": "08:45", "title": "School drop-off", "owner": "Robin"}
    conn.close()
    assert Path(app.state.settings.balance_db_path).with_name("sync_now").exists()   # beside the store, not in the ro state dir


def test_bad_owner_400(dayclient):
    assert dayclient.post("/api/day/owner", json={"date": "2026-11-05", "start": "08:45", "title": "School drop-off", "owner": "Bob"}).status_code == 400


def test_complete_enqueues_and_marks_done(dayclient):
    r = dayclient.post("/api/day/task/t2/complete")
    assert r.status_code == 200 and r.json()["queued"]["payload"] == {"task_id": "t2"}
    top3 = dayclient.get("/api/day").json()["work"]["top3"]
    assert next(t for t in top3 if t["id"] == "t2")["done"] is True
    assert next(t for t in top3 if t["id"] == "t2")["pending"] is True


def test_refresh_touches_flag(dayclient, app):
    r = dayclient.post("/api/day/refresh")
    assert r.status_code == 200 and r.json()["ok"] is True and r.json()["sync"]["google"] == "ok"
    assert Path(app.state.settings.balance_db_path).with_name("sync_now").exists()


def test_day_api_needs_login_when_configured(tmp_path):
    from fastapi.testclient import TestClient
    from worklog.auth import hash_password
    from worklog.config import Settings
    from worklog.web.app import create_app
    (tmp_path / "state").mkdir()
    a = create_app(Settings(db_path=str(tmp_path / "w.db"), balance_db_path=str(tmp_path / "b.db"),
                            balance_state_dir=str(tmp_path / "state"),
                            auth_user="sam", auth_password_hash=hash_password("pw", iterations=1000)))
    a.state.clock = lambda: datetime(2026, 11, 5, 9, 0)
    c = TestClient(a)
    assert c.get("/api/day").status_code == 401
    assert c.get("/api/day", auth=("sam", "pw")).status_code == 200
    assert c.get("/api/balance/week").status_code == 401


def test_refresh_reports_failure_when_flag_dir_unwritable(dayclient, app, tmp_path):
    ro = tmp_path / "ro"
    ro.mkdir()
    ro.chmod(0o500)
    app.state.settings.balance_db_path = str(ro / "b.db")               # flag dir = the db's dir
    try:
        r = dayclient.post("/api/day/refresh")
        assert r.status_code == 200 and r.json()["ok"] is False
    finally:
        ro.chmod(0o700)


def test_owner_write_stores_you_for_sam(dayclient, app):
    dayclient.post("/api/day/owner", json={"date": "2026-11-05", "start": "08:45", "title": "School drop-off", "owner": "Sam"})
    conn = bdb.connect(app.state.settings.balance_db_path)
    assert bdb.queue_pending(conn)[-1]["payload"]["owner"] == "you"
    conn.close()


def test_calendar_pdf_upload_lands_in_the_inbox(dayclient, app, tmp_path):
    inbox = tmp_path / "inbox"
    inbox.mkdir()
    app.state.settings.calendar_inbox = str(inbox)
    r = dayclient.post("/api/day/calendar-pdf", files={"file": ("2026-11 Calendar - Sam (Outlook).pdf", b"%PDF-1.4 fake", "application/pdf")})
    assert r.status_code == 200 and r.json()["saved"].endswith(".pdf")
    assert (inbox / r.json()["saved"]).read_bytes() == b"%PDF-1.4 fake"
    assert dayclient.post("/api/day/calendar-pdf", files={"file": ("notes.txt", b"hello", "text/plain")}).status_code == 400
    assert dayclient.post("/api/day/calendar-pdf", files={"file": ("x.pdf", b"not a pdf", "application/pdf")}).status_code == 400
    app.state.settings.calendar_inbox = None
    assert dayclient.post("/api/day/calendar-pdf", files={"file": ("x.pdf", b"%PDF-1.4", "application/pdf")}).status_code == 503


# ---- plan 2: slots, move, find ----------------------------------------------------

@pytest.fixture
def weekclient(client, app, tmp_path):
    from tests.day.fixtures import week as W
    W.write_state(Path(app.state.settings.balance_state_dir))
    plan = tmp_path / "plan.csv"
    plan.write_text(W.PLAN)
    app.state.settings.plan_path = str(plan)
    app.state.clock = lambda: W.NOW
    conn = bdb.connect(app.state.settings.balance_db_path)
    bdb.add_block(conn, "2026-11-03", "07:30", "08:30", "run", "Easy Run", state="approved", source="propose")
    for day in W.DAYS[:5]:
        bdb.add_block(conn, day, "18:00", "18:30", "stop", "Hard stop", state="approved", source="gate")
    conn.close()
    return client


def test_slots_endpoint_ranks_and_flags_unknown_days(weekclient):
    r = weekclient.post("/api/day/slots", json={"item": {"title": "Call", "minutes": 30, "kind": "personal"},
                                                "from": "2026-11-06", "to": "2026-11-07"})
    assert r.status_code == 200
    body = r.json()
    assert body["slots"][0]["best"] is True and body["slots"][0]["date"] == "2026-11-06"
    assert body["days"]["2026-11-07"]["unknown"] is True and body["days"]["2026-11-06"]["unknown"] is False
    assert weekclient.post("/api/day/slots", json={"item": {"title": "x", "minutes": 30}, "from": "2026-11-01", "to": "2026-12-31"}).status_code == 400


def test_move_run_queues_session_time_and_moves_the_block(weekclient, app):
    body = {"ref": {"kind": "run", "date": "2026-11-03", "start": "07:30", "end": "08:30", "session": "Easy Run", "block_id": 1},
            "date": "2026-11-03", "start": "13:00", "end": "14:00", "writes": ["session_time", "block", "mirror_busy"]}
    r = weekclient.post("/api/day/move", json=body)
    assert r.status_code == 200
    out = r.json()
    assert [q["kind"] for q in out["queued"]] == ["session_time"] and out["queued"][0]["payload"]["start"] == "13:00"
    assert out["paste"] == "Tue 3 Nov 13:00-14:00 Busy"
    conn = bdb.connect(app.state.settings.balance_db_path)
    runs = [b for b in bdb.blocks_between(conn, "2026-11-03", "2026-11-03") if b["kind"] == "run"]
    assert sorted((b["state"], b["start"]) for b in runs) == [("approved", "13:00"), ("rejected", "07:30")]
    conn.close()
    day = weekclient.get("/api/day?date=2026-11-03").json()
    assert day["training"]["time"] == "13:00"


def test_move_personal_event_queues_gcal_update(weekclient):
    body = {"ref": {"kind": "personal", "date": "2026-11-03", "start": "20:00", "end": "21:00", "uid": "din@google.com", "calendar": "Personal"},
            "date": "2026-11-03", "start": "20:30", "end": "21:30", "writes": ["gcal"]}
    out = weekclient.post("/api/day/move", json=body).json()
    assert out["queued"][0]["kind"] == "gcal_update" and out["queued"][0]["payload"]["uid"] == "din@google.com"
    assert weekclient.post("/api/day/move", json={**body, "ref": {**body["ref"], "uid": ""}}).status_code == 400


def test_find_puts_it_in_family_work_training_or_todoist(weekclient, app):
    base = {"item": {"title": "Dentist", "minutes": 45, "kind": "personal"}, "date": "2026-11-06", "start": "15:00", "end": "15:45"}
    out = weekclient.post("/api/day/find", json={**base, "target": "family"}).json()
    assert out["queued"][0]["kind"] == "gcal_create" and out["queued"][0]["payload"]["calendar"] == "Family"
    out = weekclient.post("/api/day/find", json={**base, "target": "work", "item": {"title": "Go/no-go prep", "minutes": 45}}).json()
    assert out["queued"][0]["kind"] == "mirror_add"
    assert weekclient.post("/api/day/find", json={**base, "target": "work", "item": {"title": "call bob@corp.com", "minutes": 45}}).status_code == 400
    out = weekclient.post("/api/day/find", json={**base, "target": "training", "item": {"title": "Gym", "minutes": 45, "kind": "gym"}}).json()
    assert out["blocks"][0]["state"] == "approved" and out["blocks"][0]["kind"] == "other"
    assert weekclient.post("/api/day/find", json={**base, "target": "todoist"}).status_code == 400
    out = weekclient.post("/api/day/find", json={**base, "target": "todoist", "todoist": {"project": "Personal", "priority": 2, "due_string": "2026-11-06"}}).json()
    assert out["queued"][0]["kind"] == "todoist_add" and out["queued"][0]["payload"]["project"] == "Personal"
    assert weekclient.post("/api/day/find", json={**base, "target": "mars"}).status_code == 400


def test_move_run_to_another_date_is_refused(weekclient):
    body = {"ref": {"kind": "run", "date": "2026-11-03", "start": "07:30", "end": "08:30", "session": "Easy Run", "block_id": 1},
            "date": "2026-11-04", "start": "13:00", "end": "14:00", "writes": ["session_time", "block"]}
    r = weekclient.post("/api/day/move", json=body)
    assert r.status_code == 400 and "trainer" in r.json()["error"]


def test_move_personal_carries_the_original_occurrence(weekclient):
    body = {"ref": {"kind": "personal", "date": "2026-11-03", "start": "20:00", "end": "21:00", "uid": "din@google.com", "calendar": "Personal"},
            "date": "2026-11-03", "start": "20:30", "end": "21:30", "writes": ["gcal"]}
    out = weekclient.post("/api/day/move", json=body).json()
    assert out["queued"][0]["payload"]["orig_date"] == "2026-11-03" and out["queued"][0]["payload"]["orig_start"] == "20:00"


def test_classify_changes_the_slot_verdict_at_once(weekclient, app):
    item = {"item": {"title": "Call", "minutes": 30, "kind": "personal"}, "from": "2026-11-03", "to": "2026-11-03"}
    before = next(s for s in weekclient.post("/api/day/slots", json=item).json()["slots"] if s["start"] == "10:00")
    assert before["verdict"] == "tight"                                          # Haircut, unclassified
    r = weekclient.post("/api/day/classify", json={"date": "2026-11-03", "start": "10:00", "title": "Haircut", "cls": "partner", "always": True})
    assert r.status_code == 200 and r.json()["cls"] == "partner" and r.json()["rule"]["pattern"] == "Haircut"
    assert r.json()["queued"] and r.json()["queued"]["payload"]["tier"] == "context"   # the digest's convention
    after = next(s for s in weekclient.post("/api/day/slots", json=item).json()["slots"] if s["start"] == "10:00")
    assert after["verdict"] == "fits"
    assert weekclient.post("/api/day/classify", json={"date": "2026-11-03", "start": "10:00", "title": "x", "cls": "alien"}).status_code == 400
    r2 = weekclient.post("/api/day/classify", json={"date": "2026-11-03", "start": "10:00", "title": "Haircut", "cls": "family"})
    assert r2.json()["queued"]["payload"]["tier"] == "" and r2.json()["rule"] is None   # clears the overlay's context


def test_workcal_parse_never_writes_and_add_queues_a_batch(weekclient, app):
    text = "Fri 6 Nov 14:00-14:45 Go/no-go prep\nnonsense line"
    r = weekclient.post("/api/day/workcal/parse", json={"text": text}).json()
    assert r["rows"][0]["ok"] is True and r["rows"][1]["ok"] is False
    conn = bdb.connect(app.state.settings.balance_db_path)
    assert bdb.queue_pending(conn) == []
    conn.close()
    out = weekclient.post("/api/day/workcal/add", json={"events": [r["rows"][0]]}).json()
    assert out["queued"]["kind"] == "mirror_bulk_add" and out["queued"]["payload"]["events"][0]["title"] == "Go/no-go prep"
    assert weekclient.post("/api/day/workcal/add", json={"events": [{"date": "2026-11-06", "start": "14:00", "end": "14:45", "title": "x bob@corp.com"}]}).status_code == 400
    assert weekclient.post("/api/day/workcal/add", json={"events": [{"date": "2026-11-06", "start": "14:00", "end": "14:45", "title": "x"}] * 51}).status_code == 400


def test_workcal_annotate_queues_cancel_and_note(weekclient):
    out = weekclient.post("/api/day/workcal/annotate", json={"date": "2026-11-03", "start": "09:30", "title": "Stand-up", "status": "cancelled"}).json()
    assert out["queued"]["kind"] == "mirror_annotate" and out["queued"]["payload"]["status"] == "cancelled"
    assert weekclient.post("/api/day/workcal/annotate", json={"date": "2026-11-03", "start": "09:30", "title": "Stand-up", "status": "maybe"}).status_code == 400
    assert weekclient.post("/api/day/workcal/annotate", json={"date": "2026-11-03", "start": "09:30", "title": "Stand-up", "note": "mail bob@corp.com"}).status_code == 400


def test_cancelled_meeting_is_listed_struck_and_not_busy(weekclient, app):
    import json
    p = Path(app.state.settings.balance_state_dir, "mirror.json")
    m = json.loads(p.read_text())
    for e in m["events"]:
        if e["date"] == "2026-11-05" and e["title"] == "Eval walkthrough":
            e["status"] = "cancelled"
    p.write_text(json.dumps(m))
    day = weekclient.get("/api/day?date=2026-11-05").json()
    ev = next(e for e in day["timeline"] if e["title"] == "Eval walkthrough")
    assert ev["cancelled"] is True
    item = {"item": {"title": "Call", "minutes": 30, "kind": "personal"}, "from": "2026-11-05", "to": "2026-11-05"}
    s = next(x for x in weekclient.post("/api/day/slots", json=item).json()["slots"] if x["start"] == "10:30")
    assert s["verdict"] != "clash"


def test_a_whose_tap_can_be_corrected_even_after_partner(weekclient, app):
    item = {"item": {"title": "Call", "minutes": 30, "kind": "personal"}, "from": "2026-11-03", "to": "2026-11-03"}
    weekclient.post("/api/day/classify", json={"date": "2026-11-03", "start": "10:00", "title": "Haircut", "cls": "partner"})
    assert next(s for s in weekclient.post("/api/day/slots", json=item).json()["slots"] if s["start"] == "10:00")["verdict"] == "fits"
    # the overlay now says context for that occurrence (simulate the sync having applied it)
    import json
    p = Path(app.state.settings.balance_state_dir, "annotations.json")
    a = json.loads(p.read_text()); a["one_off"].append({"date": "2026-11-03", "start": "10:00", "title": "Haircut", "owner": None, "tier": "context", "note": None})
    p.write_text(json.dumps(a))
    r = weekclient.post("/api/day/classify", json={"date": "2026-11-03", "start": "10:00", "title": "Haircut", "cls": "mine"})
    assert r.json()["queued"]["payload"]["tier"] == ""                         # clears the overlay's context
    assert next(s for s in weekclient.post("/api/day/slots", json=item).json()["slots"] if s["start"] == "10:00")["verdict"] == "clash"
    ev = next(e for e in weekclient.get("/api/day?date=2026-11-03").json()["timeline"] if e["title"] == "Haircut")
    assert ev["classification"] == "mine"


def test_family_rules_can_be_listed_and_deleted(weekclient):
    weekclient.post("/api/day/classify", json={"date": "2026-11-03", "start": "10:00", "title": "Haircut", "cls": "partner", "always": True})
    rules = weekclient.get("/api/day/classify/rules").json()["rules"]
    assert rules and rules[0]["pattern"] == "Haircut"
    assert weekclient.delete(f"/api/day/classify/rules/{rules[0]['id']}").status_code == 200
    assert weekclient.get("/api/day/classify/rules").json()["rules"] == []
    assert weekclient.delete("/api/day/classify/rules/999").status_code == 404


def test_pasted_and_cancelled_meetings_show_at_once(weekclient):
    weekclient.post("/api/day/workcal/add", json={"events": [{"date": "2026-11-03", "start": "15:00", "end": "15:30", "title": "Pasted sync"}]})
    weekclient.post("/api/day/workcal/annotate", json={"date": "2026-11-03", "start": "09:30", "title": "Stand-up", "status": "cancelled"})
    day = weekclient.get("/api/day?date=2026-11-03").json()
    pasted = next(e for e in day["timeline"] if e["title"] == "Pasted sync")
    assert pasted["layer"] == "work" and pasted["pending"] is True
    standup = next(e for e in day["timeline"] if e["title"] == "Stand-up")
    assert standup["cancelled"] is True and standup.get("pending") is True
    item = {"item": {"title": "Call", "minutes": 30, "kind": "personal"}, "from": "2026-11-03", "to": "2026-11-03"}
    found = weekclient.post("/api/day/slots", json=item).json()["slots"]
    assert next(s for s in found if s["start"] == "15:00")["verdict"] == "clash"
    assert next(s for s in found if s["start"] == "09:30")["verdict"] != "clash"


def test_day_lists_meeting_proposals_until_logged(dayclient, app, tmp_path):
    app.state.settings.calendar_db_path = cal(tmp_path, [("2026-11-05", "08:30", "09:00", "Early sync", "confirmed"),
                                                        ("2026-11-05", "10:00", "10:30", "Standup", "confirmed")])
    props = dayclient.get("/api/day").json()["work"]["proposals"]
    assert [p["title"] for p in props] == ["Early sync", "Standup"]
    r = dayclient.post("/api/calendar/add", json={"date": "2026-11-05", "start": "08:30", "end": "09:00", "title": "Early sync"})
    assert r.status_code == 200
    props = dayclient.get("/api/day").json()["work"]["proposals"]
    assert [p["title"] for p in props] == ["Standup"]
    dayclient.post("/api/calendar/dismiss", json={"date": "2026-11-05", "start": "10:00", "title": "Standup"})
    assert dayclient.get("/api/day").json()["work"]["proposals"] == []


def test_day_proposals_empty_without_calendar(dayclient):
    assert dayclient.get("/api/day").json()["work"]["proposals"] == []
