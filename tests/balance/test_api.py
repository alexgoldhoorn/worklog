from balance import db


def test_week_merges_layers(client):
    r = client.get("/api/balance/week").json()
    assert r["start"] == "2026-11-02" and r["days"][-1] == "2026-11-08"
    assert r["gate"]["colour"] == "amber"
    assert r["personal"][0]["title"] == "Kim dentist"
    assert r["goals"]["milestones"][0]["content"] == "Preprod release"
    assert r["settings"]["hard_stop"] == "18:00"


def test_approve_reject_and_outlook(client, app):
    conn = db.connect(app.state.settings.balance_db_path)
    a = db.add_block(conn, "2026-11-03", "07:30", "08:30", "run", "Easy Run")
    b = db.add_block(conn, "2026-11-03", "18:00", "18:30", "stop", "Hard stop")
    conn.close()
    assert client.post(f"/api/balance/blocks/{a}/approve").json()["state"] == "approved"
    assert client.post(f"/api/balance/blocks/{b}/reject").json()["state"] == "rejected"
    assert client.post("/api/balance/blocks/999/approve").status_code == 404
    text = client.get("/api/balance/outlook").text
    assert "Tue 03/11 07:30–08:30  Easy Run" in text and "Hard stop" not in text


def test_manual_block_validation(client):
    assert client.post("/api/balance/blocks", json={"date": "2026-11-04", "start": "19:00", "end": "18:00",
                                            "kind": "family", "title": "Dinner"}).status_code == 400
    r = client.post("/api/balance/blocks", json={"date": "2026-11-04", "start": "19:00", "end": "20:30",
                                         "kind": "family", "title": "Dinner"})
    assert r.status_code == 200 and r.json()["state"] == "approved" and r.json()["source"] == "manual"


def test_settings_roundtrip(client):
    assert client.put("/api/balance/settings", json={"hard_stop": "25:00"}).status_code == 400
    assert client.put("/api/balance/settings", json={"nope": "x"}).status_code == 400
    r = client.put("/api/balance/settings", json={"hard_stop": "17:30", "run_slot": "07:00"}).json()
    assert r["hard_stop"] == "17:30" and r["run_slot"] == "07:00"


def test_queue_api_lists_retries_and_dismisses(client, app):
    conn = db.connect(app.state.settings.balance_db_path)
    a = db.enqueue(conn, "todoist_complete", {"task_id": "t1"}, "Done: QA checklist")
    b = db.enqueue(conn, "gcal_create", {"calendar": "Family"}, "Dentist")
    db.queue_mark(conn, b["id"], "failed", "login expired")
    conn.close()
    q = client.get("/api/balance/queue").json()
    assert [r["id"] for r in q["pending"]] == [a["id"]]
    assert q["recent"][0]["id"] == b["id"] and q["recent"][0]["error"] == "login expired"
    assert client.post(f"/api/balance/queue/{b['id']}/retry").json()["status"] == "pending"
    assert client.post(f"/api/balance/queue/{a['id']}/dismiss").json()["status"] == "dismissed"
    assert client.post("/api/balance/queue/999/retry").status_code == 404


# ---- review fixes: input validation ------------------------------------------

import pytest
from datetime import datetime
from fastapi.testclient import TestClient
from worklog.config import Settings


@pytest.mark.parametrize("key,value", [
    ("week_hours_max", "abc"), ("week_hours_min", "-1"), ("week_hours_max", "nan"), ("week_hours_max", "999"),
    ("run_alt_slots", "13:00,25:99"), ("run_slot", 730), ("hard_stop", None), ("gcal_calendar", ["x"]),
    ("todoist_project", "x" * 101), ("milestone_label", True),
])
def test_bad_setting_values_are_rejected_and_not_stored(client, key, value):
    before = client.get("/api/balance/settings").json()
    assert client.put("/api/balance/settings", json={key: value}).status_code == 400
    assert client.get("/api/balance/settings").json() == before


def test_settings_put_is_all_or_nothing_and_accepts_numbers(client):
    r = client.put("/api/balance/settings", json={"week_hours_min": 28, "week_hours_max": "x"})
    assert r.status_code == 400 and client.get("/api/balance/settings").json()["week_hours_min"] != "28"
    ok = client.put("/api/balance/settings", json={"week_hours_min": 28, "week_hours_max": "36.5",
                                                   "run_alt_slots": "12:30, 18:00", "todoist_project": ""})
    assert ok.status_code == 200 and ok.json()["week_hours_min"] == "28" and ok.json()["run_alt_slots"] == "12:30,18:00"


def test_no_balance_store_is_503_not_500(tmp_path):
    from fastapi import FastAPI
    from fastapi.responses import JSONResponse
    from balance.web.api import ApiError, router
    app = FastAPI()
    app.state.settings = Settings(db_path=str(tmp_path / "w.db"))
    app.state.clock = lambda: datetime(2026, 11, 2, 9, 0)

    @app.exception_handler(ApiError)
    async def _e(_r, exc):
        return JSONResponse({"error": exc.message}, status_code=exc.status)
    app.include_router(router)
    c = TestClient(app)
    for path in ("/api/balance/week", "/api/balance/settings", "/api/balance/queue", "/api/balance/outlook"):
        assert c.get(path).status_code == 503, path


@pytest.mark.parametrize("patch", [{"start": 900}, {"end": 1000}, {"start": None}, {"title": 5}, {"kind": []}, {"date": 20261109}])
def test_add_block_with_wrong_types_is_400(client, patch):
    body = {"date": "2026-11-03", "start": "09:00", "end": "10:00", "kind": "other", "title": "x", **patch}
    assert client.post("/api/balance/blocks", json=body).status_code == 400


@pytest.mark.parametrize("raw", ["20261109", "2026-W45-1", "2026-11-9"])
def test_non_canonical_dates_are_rejected(client, raw):
    body = {"date": raw, "start": "09:00", "end": "10:00", "kind": "other", "title": "x"}
    assert client.post("/api/balance/blocks", json=body).status_code == 400
    assert client.get("/api/balance/week", params={"start": raw}).status_code == 400
