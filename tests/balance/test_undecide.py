"""A decided protected block can go back to proposed; the sync job undoes what the decision did."""
from balance import db
from balance.sync import push_blocks


def _add(app, state="proposed"):
    conn = db.connect(app.state.settings.balance_db_path)
    bid = db.add_block(conn, "2026-11-03", "07:30", "08:30", "run", "Easy Run", state=state)
    conn.close()
    return bid


def test_rejected_and_approved_go_back_to_proposed(client, app):
    a, b = _add(app), _add(app)
    assert client.post(f"/api/balance/blocks/{a}/reject").json()["state"] == "rejected"
    r = client.post(f"/api/balance/blocks/{a}/propose").json()
    assert r["state"] == "proposed" and r["decided_at"] is None
    assert client.post(f"/api/balance/blocks/{b}/approve").json()["state"] == "approved"
    assert client.post(f"/api/balance/blocks/{b}/proposed").json()["state"] == "proposed"
    assert client.post("/api/balance/blocks/999/propose").status_code == 404
    week = client.get("/api/balance/week").json()["blocks"]
    assert {x["id"]: x["state"] for x in week} == {a: "proposed", b: "proposed"}


def test_proposed_again_removes_the_calendar_event_a_sync_wrote():
    conn = db.connect(":memory:")
    bid = db.add_block(conn, "2026-11-09", "07:30", "08:30", "run", "Easy Run", state="approved")
    calls = []

    def api(method, path, params=None, body=None):
        calls.append(method)
        return {"id": "ev1"} if method == "POST" else {}

    run = lambda: push_blocks(conn, "Agent", api=api, resolver=lambda n: ("cal", False))
    assert run()["created"] == 1
    db.decide(conn, bid, "proposed")
    assert [p["id"] for p in db.pending_sync(conn)] == [bid]
    assert run()["deleted"] == 1 and calls == ["POST", "DELETE"]
    assert db.get_block(conn, bid)["gcal_event_id"] == ""
    assert db.pending_sync(conn) == []          # proposed and not in Google: nothing left to do


def test_approved_then_proposed_before_a_sync_leaves_nothing_to_sync():
    conn = db.connect(":memory:")
    bid = db.add_block(conn, "2026-11-09", "07:30", "08:30", "run", "Easy Run")
    db.decide(conn, bid, "approved")
    assert len(db.pending_sync(conn)) == 1
    db.decide(conn, bid, "proposed")
    assert db.pending_sync(conn) == []


def test_rejected_block_with_event_then_proposed_still_drops_the_event():
    conn = db.connect(":memory:")
    bid = db.add_block(conn, "2026-11-09", "07:30", "08:30", "run", "Easy Run", state="approved")
    db.update_block(conn, bid, gcal_event_id="ev1", gcal_calendar="cal")
    db.decide(conn, bid, "rejected")
    db.decide(conn, bid, "proposed")
    assert [p["id"] for p in db.pending_sync(conn)] == [bid]
    db.decide(conn, bid, "approved")             # approving again keeps the event: nothing to do
    assert db.pending_sync(conn) == []
