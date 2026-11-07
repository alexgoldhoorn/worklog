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
