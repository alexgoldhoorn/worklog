from balance import db
import pytest
from balance.sync import GoogleUnavailable, push_blocks


def test_push_creates_then_deletes_only_its_own_events():
    conn = db.connect(":memory:")
    a = db.add_block(conn, "2026-11-09", "07:30", "08:30", "run", "Easy Run", state="approved")
    r = db.add_block(conn, "2026-11-10", "18:00", "18:30", "stop", "Hard stop", state="approved")
    calls = []

    def api(method, path, params=None, body=None):
        calls.append((method, path, body))
        return {"id": f"ev{len(calls)}"} if method == "POST" else {}

    st = push_blocks(conn, "Agent", api=api, resolver=lambda n: ("agent@cal", False))
    assert st["created"] == 2 and not st["fallback_primary"]
    assert db.get_block(conn, a)["gcal_event_id"] == "ev1"
    assert calls[0][2]["summary"] == "Easy Run"
    # nothing pending now
    assert push_blocks(conn, "Agent", api=api, resolver=lambda n: ("agent@cal", False))["created"] == 0
    db.decide(conn, r, "rejected")
    st = push_blocks(conn, "Agent", api=api, resolver=lambda n: ("agent@cal", False))
    assert st["deleted"] == 1 and calls[-1][0] == "DELETE" and "ev2" in calls[-1][1]
    assert db.get_block(conn, r)["gcal_event_id"] == ""


def test_fallback_to_primary_prefixes_the_title():
    conn = db.connect(":memory:")
    db.add_block(conn, "2026-11-09", "07:30", "08:30", "run", "Easy Run", state="approved")
    seen = {}
    st = push_blocks(conn, "Agent", api=lambda m, p, params=None, body=None: seen.update(body or {}) or {"id": "x"},
                     resolver=lambda n: ("primary", True))
    assert st["fallback_primary"] and seen["summary"].startswith("🛡 ")


def test_google_unavailable_leaves_blocks_pending():
    conn = db.connect(":memory:")
    db.add_block(conn, "2026-11-09", "07:30", "08:30", "run", "Easy Run", state="approved")

    def resolver(n):
        raise GoogleUnavailable("login expired")
    try:
        push_blocks(conn, "Agent", api=None, resolver=resolver)
        assert False, "should raise"
    except GoogleUnavailable:
        pass
    assert len(db.pending_sync(conn)) == 1


def test_resolver_network_error_is_reported_not_raised():
    conn = db.connect(":memory:")
    db.add_block(conn, "2026-11-09", "07:30", "08:30", "run", "Easy Run", state="approved")

    def resolver(n):
        raise RuntimeError("Calendar API HTTP 503")
    st = push_blocks(conn, "Agent", api=None, resolver=resolver)
    assert st["created"] == 0 and "503" in st["errors"][0]
    assert len(db.pending_sync(conn)) == 1


def test_light_run_drains_the_queue_without_snapshots(tmp_path):
    """Every 2 minutes the host sync only drains the queue; the snapshots are taken on a full run."""
    from balance import sync as s
    conn = db.connect(":memory:")
    db.enqueue(conn, "noop", {}, "x")
    st = s.run(conn, str(tmp_path), env={}, light=True, handlers={"noop": lambda p, e: None})
    assert st["queue"] == {"done": 1, "failed": 0, "errors": []}
    assert not (tmp_path / "goals.json").exists() and not (tmp_path / "mirror.json").exists()
    assert (tmp_path / "sync.json").exists() and st["light"] is True


def test_personal_snapshot_rows_carry_uid_and_calendar():
    from datetime import date, datetime
    from zoneinfo import ZoneInfo
    from balance import sync as s
    tz = ZoneInfo("Europe/Amsterdam")

    def fake_fetch(urls, ws, we):
        return [{"calendar": "Family", "title": "Patinatge", "uid": "abc@google.com", "all_day": False,
                 "start": datetime(2026, 11, 6, 17, 0, tzinfo=tz), "end": datetime(2026, 11, 6, 18, 0, tzinfo=tz)}], []

    snap = s.personal_snapshot("Family|https://x", date(2026, 11, 1), date(2026, 11, 30), fetch=fake_fetch)
    assert snap["events"] == [{"date": "2026-11-06", "start": "17:00", "end": "18:00", "all_day": False,
                               "title": "Patinatge", "calendar": "Family", "uid": "abc@google.com"}]


def test_move_block_leaves_one_approved_and_the_sync_deletes_then_creates():
    conn = db.connect(":memory:")
    a = db.add_block(conn, "2026-11-05", "07:30", "08:30", "run", "Easy Run", state="approved", source="propose")
    db.update_block(conn, a, gcal_event_id="old1", gcal_calendar="agent@cal", synced_at="2026-11-04 10:00:00")
    new = db.move_block(conn, a, "2026-11-05", "13:00", "14:00")
    rows = db.blocks_between(conn, "2026-11-05", "2026-11-05")
    assert [(r["state"], r["start"]) for r in rows] == [("rejected", "07:30"), ("approved", "13:00")]
    assert new["kind"] == "run" and new["title"] == "Easy Run" and new["source"] == "propose" and "moved from 2026-11-05 07:30" in new["note"]
    calls = []

    def api(method, path, params=None, body=None):
        calls.append((method, path))
        return {"id": "new1"} if method == "POST" else {}

    st = push_blocks(conn, "Agent", api=api, resolver=lambda n: ("agent@cal", False))
    assert st["deleted"] == 1 and st["created"] == 1
    assert [c[0] for c in calls] == ["DELETE", "POST"] or [c[0] for c in calls] == ["POST", "DELETE"]
    assert db.get_block(conn, new["id"])["gcal_event_id"] == "new1" and db.get_block(conn, a)["gcal_event_id"] == ""


def test_move_block_refuses_a_block_that_is_not_approved_or_proposed():
    """I7: a double tap or a stale tab must not create a second approved block."""
    conn = db.connect(":memory:")
    a = db.add_block(conn, "2026-11-05", "07:30", "08:30", "run", "Easy Run", state="approved")
    db.move_block(conn, a, "2026-11-05", "13:00", "14:00")
    with pytest.raises(ValueError):
        db.move_block(conn, a, "2026-11-05", "15:00", "16:00")
    assert [b["state"] for b in db.blocks_between(conn, "2026-11-05", "2026-11-05")].count("approved") == 1


def _fake_gapi(calendars, events):
    def api(method, path, params=None, body=None):
        if path.endswith("/users/me/calendarList"):
            return {"items": [{"id": cid, "summary": name} for name, cid in calendars.items()]}
        import urllib.parse
        for name, cid in calendars.items():
            if urllib.parse.unquote(path).endswith(f"/calendars/{cid}/events"):
                return {"items": events.get(name, [])}
        return {"items": []}
    return api


def test_personal_snapshot_api_rows_carry_identity_and_people():
    from datetime import date
    from balance import sync as s
    api = _fake_gapi({"Personal": "p@cal", "Family": "f@cal"}, {"Family": [
        {"id": "ev1", "iCalUID": "ev1@google.com", "summary": "Patinatge", "status": "confirmed", "updated": "2026-11-01T10:00:00Z",
         "creator": {"email": "partner@example.com"}, "organizer": {"email": "partner@example.com"},
         "start": {"dateTime": "2026-11-06T17:00:00+01:00"}, "end": {"dateTime": "2026-11-06T18:00:00+01:00"}, "recurringEventId": "m1"},
        {"id": "ev2", "iCalUID": "ev2@google.com", "summary": "Pont", "status": "confirmed", "start": {"date": "2026-11-07"}, "end": {"date": "2026-11-08"}},
        {"id": "ev3", "iCalUID": "ev3@google.com", "summary": "Gone", "status": "cancelled", "start": {"dateTime": "2026-11-06T19:00:00+01:00"}, "end": {"dateTime": "2026-11-06T20:00:00+01:00"}}]})
    snap = s.personal_snapshot_api(["Personal", "Family", "Kim"], date(2026, 11, 1), date(2026, 11, 30), api=api)
    assert snap["source"] == "api" and snap["missing"] == ["Kim"]
    rows = snap["events"]
    assert [r["title"] for r in rows] == ["Patinatge", "Pont"]                      # cancelled dropped
    ev = rows[0]
    assert ev == {"date": "2026-11-06", "start": "17:00", "end": "18:00", "all_day": False, "title": "Patinatge", "calendar": "Family",
                  "uid": "ev1@google.com", "event_id": "ev1", "creator": "partner@example.com", "organizer": "partner@example.com",
                  "updated": "2026-11-01T10:00:00Z", "recurring": True}
    assert rows[1]["all_day"] is True and rows[1]["date"] == "2026-11-07" and rows[1]["recurring"] is False


def test_run_falls_back_to_ics_when_google_is_unavailable(tmp_path, monkeypatch):
    from balance import sync as s
    conn = db.connect(":memory:")
    monkeypatch.setattr(s, "personal_snapshot_api", lambda *a, **k: (_ for _ in ()).throw(s.GoogleUnavailable("login expired")))
    monkeypatch.setattr(s, "personal_snapshot", lambda urls, lo, hi, fetch=None: {"events": [{"date": "2026-11-06", "start": "17:00", "end": "18:00", "all_day": False, "title": "Patinatge", "calendar": "Family", "uid": "x"}], "warnings": []})
    monkeypatch.setattr(s, "_school_calendar", lambda: (None, None))
    st = s.run(conn, str(tmp_path), env={"GOOGLE_CALENDAR_ICS_URLS": "Family|https://x"})
    assert st["personal_source"] == "ics"
    import json
    assert json.load(open(tmp_path / "personal.json"))["events"][0]["title"] == "Patinatge"


def test_run_reports_calendar_labels_missing_in_google(tmp_path, monkeypatch):
    from balance import sync as s
    conn = db.connect(":memory:")
    monkeypatch.setattr(s, "personal_snapshot_api", lambda names, lo, hi, api=None: {"source": "api", "missing": ["Kim"], "events": [], "fetched": "x", "warnings": []})
    monkeypatch.setattr(s, "personal_snapshot", lambda urls, lo, hi, fetch=None: {"events": [], "warnings": []})
    monkeypatch.setattr(s, "_school_calendar", lambda: (None, None))
    st = s.run(conn, str(tmp_path), env={"GOOGLE_CALENDAR_ICS_URLS": "Personal|https://a,Family|https://b,Kim|https://c"})
    assert st["personal_source"] == "mixed" and st["calendar_labels"] == ["Kim"]


def test_run_fills_a_missing_calendar_from_its_ics_feed(tmp_path, monkeypatch):
    from balance import sync as s
    conn = db.connect(":memory:")
    monkeypatch.setattr(s, "personal_snapshot_api", lambda names, lo, hi, api=None: {"source": "api", "missing": ["Kim"], "fetched": "x", "warnings": [],
        "events": [{"date": "2026-11-06", "start": "17:00", "end": "18:00", "all_day": False, "title": "Patinatge", "calendar": "Family", "uid": "a"}]})
    monkeypatch.setattr(s, "personal_snapshot", lambda urls, lo, hi, fetch=None: {"events": [{"date": "2026-11-06", "start": "08:45", "end": "16:15", "all_day": False, "title": "Kim school", "calendar": "Kim", "uid": "b"}], "warnings": [], "fetched": "y"} if "Kim|" in urls else {"events": [], "warnings": []})
    monkeypatch.setattr(s, "_school_calendar", lambda: (None, None))
    st = s.run(conn, str(tmp_path), env={"GOOGLE_CALENDAR_ICS_URLS": "Personal|https://a,Family|https://b,Kim|https://c"})
    import json
    snap = json.load(open(tmp_path / "personal.json"))
    assert st["personal_source"] == "mixed" and st["calendar_labels"] == ["Kim"]
    assert sorted(e["calendar"] for e in snap["events"]) == ["Family", "Kim"]


def test_personal_snapshot_api_converts_utc_times_to_local():
    """Google returns dateTime in the calendar's zone; a UTC calendar gave 07:45 for an 08:45 event."""
    from datetime import date
    from balance import sync as s
    api = _fake_gapi({"Family": "f@cal"}, {"Family": [
        {"id": "ev1", "iCalUID": "ev1@google.com", "summary": "Kim school", "status": "confirmed",
         "start": {"dateTime": "2026-11-05T07:45:00Z"}, "end": {"dateTime": "2026-11-05T15:15:00Z"}},
        {"id": "ev2", "iCalUID": "ev2@google.com", "summary": "Late", "status": "confirmed",          # crosses midnight in local time
         "start": {"dateTime": "2026-11-05T23:30:00Z"}, "end": {"dateTime": "2026-11-06T00:30:00Z"}},
        {"id": "ev3", "iCalUID": "ev3@google.com", "summary": "Summer", "status": "confirmed",        # CEST, UTC+2
         "start": {"dateTime": "2026-07-01T07:00:00Z"}, "end": {"dateTime": "2026-07-01T08:00:00Z"}}]})
    rows = {r["title"]: r for r in s.personal_snapshot_api(["Family"], date(2026, 7, 1), date(2026, 11, 30), api=api)["events"]}
    assert (rows["Kim school"]["date"], rows["Kim school"]["start"], rows["Kim school"]["end"]) == ("2026-11-05", "08:45", "16:15")
    assert (rows["Late"]["date"], rows["Late"]["start"], rows["Late"]["end"]) == ("2026-11-06", "00:30", "01:30")
    assert (rows["Summer"]["start"], rows["Summer"]["end"]) == ("09:00", "10:00")
