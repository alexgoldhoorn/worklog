from datetime import datetime, time

import pytest
from fastapi.testclient import TestClient

from tests.helpers import book, cal
from worklog.config import Settings
from worklog.web.app import create_app


def test_health(client):
    assert client.get("/healthz").json() == {"ok": True}


def test_start_pause_stop_roundtrip(client, app):
    app.state.clock = lambda: datetime(2026, 10, 20, 9, 0)
    s = client.post("/api/start", json={"project": "weekly AI", "type": "meet"}).json()
    assert s["state"] == "working" and s["block"]["project"] == "weekly AI"
    app.state.clock = lambda: datetime(2026, 10, 20, 13, 4)
    assert client.post("/api/pause", json={}).json()["state"] == "break"
    app.state.clock = lambda: datetime(2026, 10, 20, 13, 40)
    assert client.post("/api/stop", json={}).json()["state"] == "stopped"
    day = client.get("/api/day/2026-10-20").json()
    assert [(b["start"], b["end"], b["type"]) for b in day["blocks"]] == [("09:00", "13:04", "meet"), ("13:04", "13:40", "eat")]
    assert day["totals"]["work_h"] == pytest.approx(4.0667, abs=0.001)


def test_double_tap_start_leaves_one_block(client, app):
    client.post("/api/start", json={})
    client.post("/api/start", json={})
    assert len(client.get("/api/day/2026-10-20").json()["blocks"]) == 1


def test_empty_or_absent_body_allowed(client):
    assert client.post("/api/start").status_code == 200
    assert client.post("/api/pause", json={}).status_code == 200
    assert client.post("/api/stop").status_code == 200


def test_edit_client_resets_billable_and_flags_are_informational(client, app):
    b = client.post("/api/blocks", json={"date": "2026-10-20", "start": "09:00", "end": "10:00", "type": "dev", "client": "ACME"}).json()
    assert b["billable"] is True
    e = client.put(f"/api/blocks/{b['id']}", json={"client": None}).json()
    assert e["billable"] is None
    client.put(f"/api/blocks/{b['id']}", json={"end": "08:30"})
    day = client.get("/api/day/2026-10-20").json()
    assert day["blocks"][0]["flags"]["start_gt_end"] is True
    assert client.delete(f"/api/blocks/{b['id']}").status_code == 200


def test_block_errors(client):
    r = client.post("/api/blocks", json={"date": "2026-10-20", "start": "9:60", "type": "dev"})
    assert r.status_code == 400 and "error" in r.json()
    assert client.post("/api/blocks", json={"date": "2026-10-20", "start": "24:00", "type": "dev"}).status_code == 400
    r = client.post("/api/blocks", json={"date": "20-10-2026", "start": "09:00", "type": "dev"})
    assert r.status_code == 400
    assert client.put("/api/blocks/999", json={"end": "10:00"}).json() == {"error": "not found"}
    assert client.put("/api/blocks/999", json={"end": "10:00"}).status_code == 404
    assert client.delete("/api/blocks/999").status_code == 404
    assert client.get("/api/day/nope").status_code == 400


def test_status_carries_notices_when_sources_missing(client):
    s = client.get("/api/status").json()
    assert any(n.startswith("calendar unavailable") for n in s["notices"])
    assert s["chips"]["break_types"][0] == "eat"
    assert s["week"]["key"] == "2026-43" and s["net"]["with_current_h"] == 0.0


def test_status_chips(client):
    for d, t, p in [("2026-10-19", "dev", "alpha"), ("2026-10-20", "dev", "alpha"), ("2026-10-20", "meet", "beta")]:
        client.post("/api/blocks", json={"date": d, "start": "09:00", "end": "10:00", "type": t, "project": p})
    client.post("/api/blocks", json={"date": "2026-10-20", "start": "11:00", "end": "11:30", "type": "eat", "project": "lunch"})
    ch = client.get("/api/status").json()["chips"]
    assert ch["types"] == ["dev", "meet"] and ch["projects"] == ["alpha", "beta"]


def test_status_chips_skip_meeting_titles(client, app):
    client.post("/api/blocks", json={"date": "2026-10-20", "start": "08:00", "end": "08:30", "type": "dev", "project": "alpha"})
    app.state.clock = lambda: datetime(2026, 10, 20, 11, 0)
    client.post("/api/calendar/add", json=MEET)
    ch = client.get("/api/status").json()["chips"]
    assert ch["projects"] == ["alpha"] and "meet" in ch["types"]


def test_status_week_series_and_today_expected(client):
    client.post("/api/blocks", json={"date": "2026-10-19", "start": "09:00", "end": "11:00"})
    s = client.get("/api/status").json()
    days = s["week"]["days"]
    assert [d["date"] for d in days] == [f"2026-10-{n}" for n in range(19, 26)]
    assert days[0]["worked_h"] == 2.0 and days[0]["expected_h"] == 7.0 and days[5]["expected_h"] == 0.0
    assert s["today"]["expected_h"] == 7.0 and days[1]["weekday"] == "Tue"


def test_status_break_chips_follow_recent_use(client):
    for start, end, t in [("09:00", "09:10", "sport"), ("09:10", "09:20", "sport"), ("09:20", "09:30", "run")]:
        client.post("/api/blocks", json={"date": "2026-10-20", "start": start, "end": end, "type": t})
    bt = client.get("/api/status").json()["chips"]["break_types"]
    assert bt[:3] == ["eat", "sport", "run"] and bt[3:] == sorted(bt[3:])


def test_calendar_add_closes_open_block_first(tmp_path):
    c_ = cal(tmp_path, [("2026-10-20", "10:15", "10:30", "weekly AI", "confirmed")])
    app = create_app(Settings(db_path=str(tmp_path / "t.db"), calendar_db_path=c_, holidays_path=None))
    app.state.clock = lambda: datetime(2026, 10, 20, 9, 0)
    c = TestClient(app)
    c.post("/api/start", json={})
    assert c.get("/api/day/2026-10-20").json()["proposals"] == [{"start": "10:15", "end": "10:30", "title": "weekly AI"}]
    app.state.clock = lambda: datetime(2026, 10, 20, 11, 0)
    r = c.post("/api/calendar/add", json={"date": "2026-10-20", "start": "10:15", "end": "10:30", "title": "weekly AI"})
    assert r.status_code == 200 and r.json()["type"] == "meet" and r.json()["project"] == "weekly AI"
    day = c.get("/api/day/2026-10-20").json()
    assert [(b["start"], b["end"], b["type"], b["source"]) for b in day["blocks"]] == [
        ("09:00", "10:15", "dev", "timer"), ("10:15", "10:30", "meet", "calendar"), ("10:30", None, "dev", "timer")]
    assert day["proposals"] == []


def test_calendar_add_finished_meeting_resumes_the_running_block(client, app):
    client.post("/api/start", json={"type": "dev", "project": "widgets"})
    app.state.clock = lambda: datetime(2026, 10, 20, 11, 0)
    r = client.post("/api/calendar/add", json=MEET)
    assert r.status_code == 200 and r.json()["end"] == MEET["end"]
    blocks = client.get("/api/day/2026-10-20").json()["blocks"]
    assert [(b["start"], b["end"], b["type"], b["project"], b["source"]) for b in blocks] == [
        ("09:00", "10:15", "dev", "widgets", "timer"), ("10:15", "10:30", "meet", MEET["title"], "calendar"),
        ("10:30", None, "dev", "widgets", "timer")]
    s = client.get("/api/status").json()
    assert s["state"] == "working" and s["block"]["start"] == "10:30" and s["block"]["project"] == "widgets"
    assert blocks[2]["client"] == blocks[0]["client"] and blocks[2]["billable"] == blocks[0]["billable"]


def test_days_put_and_delete(client):
    assert client.put("/api/days/2026-10-23", json={"expected_h": 3.5, "reason": "half day"}).json()["source"] == "manual"
    rows = client.get("/api/days", params={"start": "2026-10-22", "end": "2026-10-24"}).json()
    assert [r["expected_h"] for r in rows] == [7, 3.5, 0]
    assert client.delete("/api/days/2026-10-23").status_code == 200
    rows = client.get("/api/days", params={"start": "2026-10-23", "end": "2026-10-23"}).json()
    assert rows[0]["source"] == "default"


def test_import_dry_run_then_replace_and_export(client, tmp_path):
    p = book(tmp_path, [[datetime(2026, 3, 2), time(9, 0), time(10, 0), "a", "dev", "ACME", True, None],
                        [datetime(2026, 3, 2), time(10, 0), time(10, 30), "coffee++", "eat", None, None, None]])
    with open(p, "rb") as fh:
        r = client.post("/api/import", files={"file": ("t.xlsx", fh)}, data={"mode": "replace", "dry_run": "1", "workdays": "0"}).json()
    assert r["would_insert"] == 2 and client.get("/api/day/2026-03-02").json()["blocks"] == []
    with open(p, "rb") as fh:
        r = client.post("/api/import", files={"file": ("t.xlsx", fh)}, data={"mode": "replace", "dry_run": "0", "workdays": "0"}).json()
    assert r["inserted"] == 2
    with open(p, "rb") as fh:
        r = client.post("/api/import", files={"file": ("t.xlsx", fh)}, data={"mode": "merge", "dry_run": "1", "workdays": "0"}).json()
    assert (r["would_insert"], r["would_update"]) == (0, 2)
    with open(p, "rb") as fh:
        r = client.post("/api/import", files={"file": ("t.xlsx", fh)}, data={"mode": "replace", "dry_run": "1", "workdays": "0"}).json()
    assert r["would_delete"] == 2
    e = client.get("/api/export.csv", params={"start": "2026-03-01", "end": "2026-03-31"})
    assert e.headers["content-disposition"] == "attachment; filename=worklog-2026-03-01-2026-03-31.csv"
    assert len(e.text.strip().splitlines()) == 3
    x = client.get("/api/export.xlsx", params={"start": "2026-03-01", "end": "2026-03-31"})
    assert x.headers["content-disposition"].endswith("worklog-2026-03-01-2026-03-31.xlsx")


def test_import_rejects_bad_extension(client):
    r = client.post("/api/import", files={"file": ("t.txt", b"x")}, data={"mode": "merge", "dry_run": "0", "workdays": "0"})
    assert r.status_code == 400 and "error" in r.json()


def test_summary_week_has_stats(client, app):
    client.post("/api/blocks", json={"date": "2026-10-19", "start": "09:00", "end": "17:00", "type": "dev", "client": "ACME"})
    r = client.get("/api/summary", params={"group": "week"}).json()
    assert r["rows"][0]["key"] == "2026-43" and "with_current" in r["stats"]
    assert client.get("/api/summary", params={"group": "month"}).json()["stats"] is None


def test_invoice(client):
    client.post("/api/blocks", json={"date": "2026-10-19", "start": "09:00", "end": "17:00", "type": "dev"})
    rows = client.get("/api/invoice", params={"month": "2026-10"}).json()
    assert [r["date"] for r in rows][0] == "2026-10-01" and any(r["worked"] for r in rows)


def test_concurrent_status_requests(client):
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(8) as ex:
        codes = list(ex.map(lambda _: client.get("/api/status").status_code, range(8)))
    assert codes == [200] * 8


def test_errors_are_json_error_shape(client):
    r = client.get("/api/invoice")
    assert r.status_code == 400 and "error" in r.json()
    r = client.get("/api/nope")
    assert r.status_code == 404 and "error" in r.json()


def test_bad_input_is_400_not_500(client):
    r = client.post("/api/import", files={"file": ("x.xlsx", b"not a workbook")},
                    data={"mode": "merge", "dry_run": "0", "workdays": "0"})
    assert r.status_code == 400 and r.json()["error"].startswith("could not read file")
    r = client.post("/api/blocks", json={"date": "2026-10-20", "start": "09:00", "type": 5})
    assert r.status_code == 400
    b = client.post("/api/blocks", json={"date": "2026-10-20", "start": "09:00", "end": "10:00", "type": "dev"}).json()
    assert client.put(f"/api/blocks/{b['id']}", json={"billable": "false"}).status_code == 400
    assert client.put("/api/days/2026-10-23", json={"expected_h": "nan"}).status_code == 400


def test_create_block_defaults_type_and_client_from_settings(client):
    b = client.post("/api/blocks", json={"date": "2026-10-20", "start": "09:00", "end": "10:00"}).json()
    assert (b["type"], b["client"], b["billable"]) == ("dev", "ACME", True)
    n = client.post("/api/blocks", json={"date": "2026-10-20", "start": "10:00", "end": "11:00", "client": None}).json()
    assert n["client"] is None


MEET = {"date": "2026-10-20", "start": "10:15", "end": "10:30", "title": "weekly AI"}


def test_pause_rejects_unknown_break_type(client):
    client.post("/api/start", json={})
    r = client.post("/api/pause", json={"type": "lunch"})
    assert r.status_code == 400
    err = r.json()["error"]
    assert err.startswith("unknown break type 'lunch'; valid: eat, ") and "shop" in err
    blocks = client.get("/api/day/2026-10-20").json()["blocks"]
    assert [(b["type"], b["end"]) for b in blocks] == [("dev", None)]


def test_start_rejects_break_type(client):
    r = client.post("/api/start", json={"type": "eat"})
    assert r.status_code == 400 and r.json() == {"error": "'eat' is a break type; use pause"}
    assert client.get("/api/day/2026-10-20").json()["blocks"] == []


def test_calendar_add_future_meeting_rejected(client):
    client.post("/api/start", json={})
    r = client.post("/api/calendar/add", json=MEET)
    assert r.status_code == 400 and r.json() == {"error": "meeting has not started yet"}
    assert client.get("/api/status").json()["state"] == "working"
    r = client.post("/api/calendar/add", json={**MEET, "date": "2026-10-21"})
    assert r.status_code == 400
    blocks = client.get("/api/day/2026-10-20").json()["blocks"]
    assert [(b["type"], b["end"]) for b in blocks] == [("dev", None)]


def test_calendar_add_in_progress_meeting_stays_open(client, app):
    client.post("/api/start", json={})
    app.state.clock = lambda: datetime(2026, 10, 20, 10, 20)
    r = client.post("/api/calendar/add", json=MEET)
    assert r.status_code == 200 and r.json()["end"] is None
    blocks = client.get("/api/day/2026-10-20").json()["blocks"]
    assert [(b["start"], b["end"], b["type"]) for b in blocks] == [("09:00", "10:15", "dev"), ("10:15", None, "meet")]
    s = client.get("/api/status").json()
    assert s["state"] == "working" and s["block"]["type"] == "meet"


def test_live_totals_include_running_work_block(client, app):
    client.post("/api/start", json={})
    app.state.clock = lambda: datetime(2026, 10, 20, 12, 0)
    s = client.get("/api/status").json()
    assert s["running_min"] == 180
    assert s["today"]["work_h"] == 0 and s["today"]["work_h_live"] == pytest.approx(3.0)
    assert s["week"]["worked_h_live"] == pytest.approx(s["week"]["worked_h"] + 3.0)
    assert s["week"]["extra_h_live"] == pytest.approx(s["week"]["worked_h_live"] - s["week"]["expected_h"])


def test_running_break_is_not_live_work(client, app):
    client.post("/api/pause", json={})
    app.state.clock = lambda: datetime(2026, 10, 20, 10, 0)
    s = client.get("/api/status").json()
    assert s["state"] == "break" and s["running_min"] == 0 and s["today"]["work_h_live"] == 0


def test_needs_review_lists_auto_closed_until_fixed(client, app):
    client.post("/api/start", json={})
    app.state.clock = lambda: datetime(2026, 10, 21, 9, 0)
    s = client.get("/api/status").json()
    assert [(r["date"], r["start"], r["type"]) for r in s["needs_review"]] == [("2026-10-20", "09:00", "dev")]
    bid = client.get("/api/day/2026-10-20").json()["blocks"][0]["id"]
    assert client.put(f"/api/blocks/{bid}", json={"end": "17:00"}).status_code == 200
    assert client.get("/api/status").json()["needs_review"] == []


def test_holiday_cache_without_current_year_notice(tmp_path):
    import json
    hp = tmp_path / "h.json"
    hp.write_text(json.dumps({"2025": {"holidays": [{"date": "2025-12-25", "name": "Navidad", "scope": "es"}]}}))
    app = create_app(Settings(db_path=str(tmp_path / "t.db"), calendar_db_path=None, holidays_path=str(hp)))
    app.state.clock = lambda: datetime(2026, 10, 20, 9, 0)
    assert "holidays cache has no entries for 2026" in TestClient(app).get("/api/status").json()["notices"]


def test_break_type_never_carries_client_or_billable(client):
    b = client.post("/api/blocks", json={"date": "2026-10-20", "start": "13:04", "end": "13:40", "type": "eat", "client": "ACME", "billable": True}).json()
    assert (b["client"], b["billable"]) == (None, None)
    w = client.post("/api/blocks", json={"date": "2026-10-20", "start": "14:00", "end": "15:00", "type": "dev"}).json()
    assert (w["client"], w["billable"]) == ("ACME", True)
    e = client.put(f"/api/blocks/{w['id']}", json={"type": "eat"}).json()   # work -> break: dropped
    assert (e["type"], e["client"], e["billable"]) == ("eat", None, None)
    e = client.put(f"/api/blocks/{w['id']}", json={"type": "dev"}).json()   # break -> work: default client back
    assert (e["client"], e["billable"]) == ("ACME", True)


def test_overlap_warning_in_status_and_day(client):
    client.post("/api/blocks", json={"date": "2026-10-20", "start": "13:40", "end": "16:50", "type": "dev"})
    client.post("/api/blocks", json={"date": "2026-10-20", "start": "16:04", "end": "17:19", "type": "dev"})
    client.post("/api/blocks", json={"date": "2026-10-20", "start": "16:50", "end": "17:05", "type": "eat"})
    day = client.get("/api/day/2026-10-20").json()
    assert day["overlaps"] == ["Overlap Tue 20 Oct: 13:40–16:50 dev and 16:04–17:19 dev · both count in full",
                               "Overlap Tue 20 Oct: 16:04–17:19 dev and 16:50–17:05 eat · both count in full"]
    flagged = [b["start"] for b in day["blocks"] if b["flags"]["overlap"]]
    assert flagged == ["16:04", "16:50"]  # 16:50 starts inside 16:04–17:19, even though 13:40–16:50 ended
    assert client.get("/api/status").json()["overlaps"] == day["overlaps"]
    assert day["totals"]["work_h"] == pytest.approx(3.1667 + 1.25, abs=0.01)  # both count in full


def test_rate_setting_prices_summary_and_invoice(client):
    client.post("/api/blocks", json={"date": "2026-10-19", "start": "09:00", "end": "17:00", "type": "dev"})
    client.post("/api/blocks", json={"date": "2026-10-19", "start": "17:00", "end": "18:00", "type": "dev", "client": None})
    assert client.get("/api/settings").json()["rate"] is None
    assert client.get("/api/summary", params={"group": "week"}).json()["rate_h"] is None
    assert "amount" not in {k for k, v in client.get("/api/summary", params={"group": "week"}).json()["rows"][0].items() if v is not None}
    st = client.put("/api/settings", json={"rate": 80, "rate_unit": "h"}).json()
    assert st == {"rate": 80.0, "rate_unit": "h", "rate_h": 80.0, "default_expected_h": 7.0,
                  "week_basis_h": 35.0, "alt_week_h": 40.0}
    r = client.get("/api/summary", params={"group": "week"}).json()
    assert r["rate_h"] == 80.0 and r["rows"][0]["billable_h"] == 8.0 and r["rows"][0]["amount"] == 640.0
    day = next(d for d in client.get("/api/invoice", params={"month": "2026-10"}).json() if d["date"] == "2026-10-19")
    assert (day["billable_h"], day["amount"]) == (8.0, 640.0)
    st = client.put("/api/settings", json={"rate": 560, "rate_unit": "day"}).json()
    assert st["rate_h"] == 80.0
    assert client.put("/api/settings", json={"rate": -1}).status_code == 400
    assert client.put("/api/settings", json={"rate_unit": "week"}).status_code == 400
    assert client.put("/api/settings", json={"rate": None}).json()["rate_h"] is None


def test_export_amount_column_and_summary_sheet(client):
    import io
    import openpyxl
    client.post("/api/blocks", json={"date": "2026-10-19", "start": "09:00", "end": "11:00", "type": "dev"})
    client.post("/api/blocks", json={"date": "2026-10-19", "start": "11:00", "end": "11:30", "type": "eat"})
    client.put("/api/settings", json={"rate": 80, "rate_unit": "h"})
    csv = client.get("/api/export.csv", params={"start": "2026-10-19", "end": "2026-10-19"}).text.splitlines()
    cols = csv[0].split(",")
    i = cols.index("amount")
    assert csv[1].split(",")[i] == "160.0" and csv[2].split(",")[i] == ""
    wb = openpyxl.load_workbook(io.BytesIO(client.get("/api/export.xlsx", params={"start": "2026-10-19", "end": "2026-10-19"}).content))
    assert "summary" in wb.sheetnames
    rows = list(wb["summary"].iter_rows(values_only=True))
    assert rows[0][0] == "year-week" and rows[0][-1] == "amount" and rows[1][0] == "2026-43" and rows[1][-1] == 160.0
    client.put("/api/settings", json={"rate": None})
    csv = client.get("/api/export.csv", params={"start": "2026-10-19", "end": "2026-10-19"}).text.splitlines()
    assert csv[1].split(",")[i] == ""


def test_heatmap_splits_blocks_by_hour(client):
    client.post("/api/blocks", json={"date": "2026-10-19", "start": "08:30", "end": "10:15", "type": "dev"})   # Mon
    client.post("/api/blocks", json={"date": "2026-10-19", "start": "10:15", "end": "10:45", "type": "eat"})
    client.post("/api/blocks", json={"date": "2026-10-20", "start": "22:00", "end": "23:59", "type": "dev"})   # Tue
    hm = client.get("/api/heatmap", params={"start": "2026-10-19", "end": "2026-10-20"}).json()
    assert hm["days"] == 2
    assert hm["cells"][0][8:11] == [0.5, 1.0, 0.25] and sum(hm["cells"][0]) == 1.75
    assert hm["cells"][1][22:24] == [1.0, pytest.approx(0.983)]
    r = client.get("/api/summary", params={"group": "week"}).json()["rows"][0]
    assert r["by_type"] == {"dev": pytest.approx(3.7333, abs=0.001)}


def test_lenient_time_formats_are_normalised(client):
    r = client.post("/api/blocks", json={"date": "2026-10-20", "start": "9:50", "end": " 10.05 ", "type": "dev"})
    assert r.status_code == 200 and (r.json()["start"], r.json()["end"]) == ("09:50", "10:05")
    bid = r.json()["id"]
    r = client.put(f"/api/blocks/{bid}", json={"start": "930", "end": "1005"})
    assert (r.json()["start"], r.json()["end"]) == ("09:30", "10:05")


def test_status_month_and_summary_by_project(client):
    client.post("/api/blocks", json={"date": "2026-10-20", "start": "09:00", "end": "11:00", "type": "dev", "project": "insights"})
    client.post("/api/blocks", json={"date": "2026-10-20", "start": "11:00", "end": "12:00", "type": "dev"})
    client.post("/api/blocks", json={"date": "2026-10-20", "start": "12:00", "end": "12:30", "type": "eat"})
    s = client.get("/api/status").json()
    assert s["month"]["key"] == "2026-10" and s["month"]["worked_h"] == 3.0
    assert s["month"]["expected_h"] > 0 and s["month"]["days_worked"] == 1
    rows = client.get("/api/summary?group=week&start=2026-10-19&end=2026-10-25").json()["rows"]
    assert rows[0]["by_project"] == {"insights": 2.0, "": 1.0}


def test_week_basis_setting_scales_defaults_not_overrides(client):
    client.post("/api/blocks", json={"date": "2026-10-19", "start": "09:00", "end": "17:00", "type": "dev"})
    client.put("/api/days/2026-10-20", json={"expected_h": 4, "reason": "half day"})
    before = client.get("/api/summary", params={"group": "week", "start": "2026-10-19", "end": "2026-10-20"}).json()
    assert before["week_basis_h"] == 35.0 and before["alt_week_h"] == 40.0
    assert before["rows"][0]["expected_h"] == 32.0  # Mon–Fri at 7 h, Tue override 4 h; runs through the current week
    st = client.put("/api/settings", json={"week_basis_h": 40}).json()
    assert (st["week_basis_h"], st["default_expected_h"], st["alt_week_h"]) == (40.0, 8.0, 35.0)
    after = client.get("/api/summary", params={"group": "week", "start": "2026-10-19", "end": "2026-10-20"}).json()
    assert after["rows"][0]["expected_h"] == 36.0  # 8 h days, the 4 h override kept
    assert after["rows"][0]["expected_alt_h"] == 36.0 * 35 / 40
    assert client.get("/api/status").json()["today"]["expected_h"] in (0.0, 4.0, 8.0)  # weekend / the override day / a plain 8 h day
    st = client.put("/api/settings", json={"week_basis_h": 37.5}).json()
    assert (st["default_expected_h"], st["alt_week_h"]) == (7.5, 40.0)
    assert client.put("/api/settings", json={"week_basis_h": 0}).status_code == 400
    assert client.put("/api/settings", json={"week_basis_h": "40"}).status_code == 400


def test_status_elapsed_seconds_and_basis(client):
    client.post("/api/start", json={"type": "dev"})
    s = client.get("/api/status").json()
    assert s["state"] == "working" and isinstance(s["elapsed_s"], int) and 0 <= s["elapsed_s"] < 120
    assert s["elapsed_s"] // 60 == s["elapsed_min"] and s["week_basis_h"] == 35.0
    client.post("/api/stop")
    assert client.get("/api/status").json()["elapsed_s"] is None


def test_running_block_hides_the_meeting_it_began_during(tmp_path):
    c_ = cal(tmp_path, [("2026-10-20", "09:15", "09:30", "standup", "confirmed"),
                        ("2026-10-20", "08:00", "08:30", "early", "confirmed")])
    app = create_app(Settings(db_path=str(tmp_path / "t.db"), calendar_db_path=c_, holidays_path=None))
    app.state.clock = lambda: datetime(2026, 10, 20, 10, 0)
    c = TestClient(app)
    bid = c.post("/api/start", json={"type": "meet"}).json()["block"]["id"]
    c.put(f"/api/blocks/{bid}", json={"start": "09:20"})
    day = c.get("/api/day/2026-10-20").json()
    assert [p["title"] for p in day["proposals"]] == ["early"]


def test_in_progress_meeting_under_a_work_block_stays_addable(tmp_path):
    c_ = cal(tmp_path, [("2026-10-20", "10:15", "10:30", "weekly AI", "confirmed")])
    app = create_app(Settings(db_path=str(tmp_path / "t.db"), calendar_db_path=c_, holidays_path=None))
    app.state.clock = lambda: datetime(2026, 10, 20, 9, 0)
    c = TestClient(app)
    c.post("/api/start", json={"type": "dev"})
    app.state.clock = lambda: datetime(2026, 10, 20, 10, 17)
    assert [p["title"] for p in c.get("/api/day/2026-10-20").json()["proposals"]] == ["weekly AI"]
    r = c.post("/api/calendar/add", json={"date": "2026-10-20", "start": "10:15", "end": "10:30", "title": "weekly AI"})
    assert r.status_code == 200 and r.json()["end"] is None
    assert c.get("/api/day/2026-10-20").json()["proposals"] == []  # the open meet block began during it


def test_running_block_keeps_upcoming_proposals(tmp_path):
    c_ = cal(tmp_path, [("2026-10-20", "11:00", "11:30", "later", "confirmed")])
    app = create_app(Settings(db_path=str(tmp_path / "t.db"), calendar_db_path=c_, holidays_path=None))
    app.state.clock = lambda: datetime(2026, 10, 20, 10, 0)
    c = TestClient(app)
    c.post("/api/start", json={"type": "dev"})
    assert [p["title"] for p in c.get("/api/day/2026-10-20").json()["proposals"]] == ["later"]


def test_dismissed_proposal_is_hidden_until_undismissed(tmp_path):
    c_ = cal(tmp_path, [("2026-10-20", "16:00", "16:30", None, "confirmed")])
    app = create_app(Settings(db_path=str(tmp_path / "t.db"), calendar_db_path=c_, holidays_path=None))
    c = TestClient(app)
    assert len(c.get("/api/day/2026-10-20").json()["proposals"]) == 1
    r = c.post("/api/calendar/dismiss", json={"date": "2026-10-20", "start": "16:00", "title": None})
    assert r.status_code == 200 and r.json() == {"ok": True}
    assert c.get("/api/day/2026-10-20").json()["proposals"] == []
    r = c.request("DELETE", "/api/calendar/dismiss", json={"date": "2026-10-20", "start": "16:00", "title": None})
    assert r.status_code == 200
    assert len(c.get("/api/day/2026-10-20").json()["proposals"]) == 1
    assert c.post("/api/calendar/dismiss", json={"date": "nope", "start": "16:00"}).status_code == 400


def test_update_block_require_open_refuses_a_closed_block(client):
    bid = client.post("/api/blocks", json={"date": "2026-10-20", "start": "08:00", "end": "08:30", "type": "dev"}).json()["id"]
    r = client.put(f"/api/blocks/{bid}", json={"type": "meet", "require_open": True})
    assert r.status_code == 409 and "not running" in r.json()["error"]
    assert client.get("/api/day/2026-10-20").json()["blocks"][0]["type"] == "dev"
    ob = client.post("/api/start", json={"type": "dev"}).json()["block"]
    r = client.put(f"/api/blocks/{ob['id']}", json={"type": "meet", "require_open": True})
    assert r.status_code == 200 and r.json()["type"] == "meet"


def test_pause_accepts_the_pomo_break_type(client):
    client.post("/api/start", json={})
    r = client.post("/api/pause", json={"type": "pomo"})
    assert r.status_code == 200 and r.json()["state"] == "break" and r.json()["block"]["type"] == "pomo"
    assert "pomo" in client.get("/api/status").json()["chips"]["break_types"]


def test_status_carries_hard_stop_and_minutes_past_it(client, app):
    app.state.clock = lambda: datetime(2026, 10, 20, 17, 0)
    s = client.post("/api/start", json={"type": "dev"}).json()
    assert s["hard_stop"] == "18:00" and s["past_stop_min"] == 0
    app.state.clock = lambda: datetime(2026, 10, 20, 19, 20)
    assert client.get("/api/status").json()["past_stop_min"] == 80
    client.post("/api/pause", json={})
    assert client.get("/api/status").json()["past_stop_min"] is None


def test_past_stop_counts_from_the_stop_not_the_start(client, app):
    app.state.clock = lambda: datetime(2026, 10, 20, 21, 3)
    assert client.post("/api/start", json={}).json()["past_stop_min"] == 183


def test_past_stop_is_none_for_yesterdays_open_block(client, app):
    app.state.clock = lambda: datetime(2026, 10, 20, 23, 0)
    client.post("/api/start", json={})
    app.state.clock = lambda: datetime(2026, 10, 21, 0, 30)   # before 06:00: still open, dated yesterday
    s = client.get("/api/status").json()
    assert s["state"] == "working" and s["past_stop_min"] is None


def test_hard_stop_is_null_without_a_balance_store(tmp_path):
    a = create_app(Settings(db_path=str(tmp_path / "t.db")))
    s = TestClient(a).get("/api/status").json()
    assert s["hard_stop"] is None and s["past_stop_min"] is None


def test_sentry_not_imported_without_dsn():
    import subprocess, sys, tempfile, os
    with tempfile.TemporaryDirectory() as d:
        code = ("import sys\nfrom worklog.config import Settings\nfrom worklog.web.app import create_app\n"
                f"create_app(Settings(db_path={os.path.join(d,'w.db')!r}, sentry_dsn=None))\n"
                "assert 'sentry_sdk' not in sys.modules\n")
        r = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_bad_dsn_never_stops_startup(tmp_path):
    from worklog.config import Settings
    from worklog.web.app import create_app
    create_app(Settings(db_path=str(tmp_path / "w.db"), sentry_dsn="not a dsn"))


def test_brief_status_stopped(client):
    assert client.get("/api/status?brief=1").json() == {
        "state": "stopped", "date": "2026-10-20", "since": None, "elapsed_s": None,
        "type": None, "project": None, "today_work_h": 0.0, "resume": None}


def test_brief_actions_and_resume(client, app):
    r = client.post("/api/start?brief=1", json={"project": "acme"}).json()
    assert (r["state"], r["type"], r["project"], r["since"]) == ("working", "dev", "acme", "09:00")
    app.state.clock = lambda: datetime(2026, 10, 20, 10, 30)
    r = client.post("/api/pause?brief=1", json={}).json()
    assert (r["state"], r["type"], r["today_work_h"]) == ("break", "eat", 1.5)
    assert r["resume"] == {"type": "dev", "project": "acme"}
    assert set(r) == {"state", "date", "since", "elapsed_s", "type", "project", "today_work_h", "resume"}
    assert client.post("/api/stop?brief=1", json={}).json()["state"] == "stopped"


def test_status_without_brief_unchanged(client):
    assert "week" in client.get("/api/status").json()


def _open_count(client):
    return sum(1 for b in client.get("/api/day/2026-10-20").json()["blocks"] if b["end"] is None)


def test_calendar_add_in_progress_meeting_starting_before_the_timer_leaves_one_open_block(client, app):
    app.state.clock = lambda: datetime(2026, 10, 20, 10, 5)
    client.post("/api/start", json={"type": "dev"})
    app.state.clock = lambda: datetime(2026, 10, 20, 10, 20)
    r = client.post("/api/calendar/add", json={"date": "2026-10-20", "start": "10:00", "end": "11:00", "title": "standup"})
    assert r.status_code == 200
    blocks = client.get("/api/day/2026-10-20").json()["blocks"]
    # the running block would be zero minutes long (10:05-10:05), so it is dropped
    assert [(b["start"], b["end"], b["type"]) for b in blocks] == [("10:00", None, "meet")]
    assert _open_count(client) == 1
    app.state.clock = lambda: datetime(2026, 10, 20, 10, 30)
    client.post("/api/stop", json={})
    assert client.get("/api/status").json()["state"] == "stopped"


def test_calendar_add_finished_meeting_starting_before_the_timer_resumes_after_it(client, app):
    app.state.clock = lambda: datetime(2026, 10, 20, 10, 5)
    client.post("/api/start", json={"type": "dev", "project": "widgets"})
    app.state.clock = lambda: datetime(2026, 10, 20, 11, 30)
    r = client.post("/api/calendar/add", json={"date": "2026-10-20", "start": "10:00", "end": "11:00", "title": "standup"})
    assert r.status_code == 200
    blocks = client.get("/api/day/2026-10-20").json()["blocks"]
    assert [(b["start"], b["end"], b["type"]) for b in blocks] == [
        ("10:00", "11:00", "meet"), ("11:00", None, "dev")]
    assert _open_count(client) == 1


def test_calendar_add_meeting_starting_with_the_timer_does_not_double_open(client, app):
    app.state.clock = lambda: datetime(2026, 10, 20, 10, 0)
    client.post("/api/start", json={"type": "dev"})
    app.state.clock = lambda: datetime(2026, 10, 20, 10, 20)
    client.post("/api/calendar/add", json={"date": "2026-10-20", "start": "10:00", "end": "11:00", "title": "standup"})
    assert _open_count(client) == 1


def test_calendar_add_overlap_with_start_before_timer_keeps_the_timer_tail(client, app):
    app.state.clock = lambda: datetime(2026, 10, 20, 10, 30)
    client.post("/api/start", json={"type": "dev"})
    app.state.clock = lambda: datetime(2026, 10, 20, 12, 0)
    client.post("/api/calendar/add", json={"date": "2026-10-20", "start": "10:00", "end": "11:00", "title": "standup"})
    blocks = client.get("/api/day/2026-10-20").json()["blocks"]
    assert [(b["start"], b["end"], b["type"]) for b in blocks] == [("10:00", "11:00", "meet"), ("11:00", None, "dev")]


def test_calendar_add_meeting_wholly_before_the_timer_leaves_it_alone(client, app):
    app.state.clock = lambda: datetime(2026, 10, 20, 10, 5)
    client.post("/api/start", json={"type": "dev"})
    app.state.clock = lambda: datetime(2026, 10, 20, 11, 0)
    client.post("/api/calendar/add", json={"date": "2026-10-20", "start": "08:00", "end": "08:30", "title": "early"})
    blocks = client.get("/api/day/2026-10-20").json()["blocks"]
    assert [(b["start"], b["end"], b["type"]) for b in blocks] == [("08:00", "08:30", "meet"), ("10:05", None, "dev")]


def test_summary_refuses_a_range_beyond_the_cap(client):
    from worklog.web.api import MAX_SUMMARY_DAYS
    r = client.get("/api/summary", params={"start": "2000-01-01", "end": "2026-10-20"})
    assert r.status_code == 400 and "range too long" in r.json()["error"]
    assert (client.get("/api/summary", params={"start": "2016-10-21", "end": "2026-10-20"}).status_code == 200)
    assert MAX_SUMMARY_DAYS == 3660


def test_default_workday_hours_are_read_once_per_range(conn, monkeypatch):
    from worklog import db, expect
    calls = []
    real = db.setting
    monkeypatch.setattr(db, "setting", lambda c, k: (calls.append(k), real(c, k))[1])
    expect.expected_between(conn, "2026-10-01", "2026-12-31", {}, None)
    assert calls.count("default_expected_h") == 1
