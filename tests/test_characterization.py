"""Characterization: the JSON of /api/status, /api/summary and /api/day on a fixed fixture is
pinned to a golden file, so refactors of the web layer provably change nothing.
Regenerate deliberately with WORKLOG_UPDATE_GOLDEN=1."""
import json
import os
from datetime import datetime
from pathlib import Path

from fastapi.testclient import TestClient

from balance import db as bdb
from tests.helpers import cal
from worklog.config import Settings
from worklog.web.app import create_app

GOLDEN = Path(__file__).parent / "golden" / "characterization.json"


def _build(tmp_path):
    (tmp_path / "state").mkdir()
    bconn = bdb.connect(str(tmp_path / "balance.db"))
    bdb.set_setting(bconn, "hard_stop", "17:30")
    bconn.close()
    hol = tmp_path / "hol.json"
    hol.write_text(json.dumps({"2026": {"holidays": [
        {"date": "2026-10-12", "name": "National day", "scope": "country"},
        {"date": "2026-10-16", "name": "Town day", "scope": "town"}]}}))
    calendar = cal(tmp_path, [("2026-10-20", "10:15", "10:30", "weekly sync", "confirmed"),
                              ("2026-10-20", "15:00", "16:00", "review", "confirmed")])
    app = create_app(Settings(db_path=str(tmp_path / "t.db"), calendar_db_path=calendar,
                              holidays_path=str(hol), balance_db_path=str(tmp_path / "balance.db"),
                              balance_state_dir=str(tmp_path / "state")))
    c = TestClient(app)
    for d, s, e, t, p in [("2026-09-28", "09:00", "17:00", "dev", "alpha"), ("2026-10-05", "08:30", "12:30", "dev", "beta"),
                          ("2026-10-12", "09:00", "10:00", "dev", "alpha"), ("2026-10-14", "09:00", "11:00", "meet", "standup"),
                          ("2026-10-14", "11:00", "11:30", "eat", None), ("2026-10-14", "11:30", "18:00", "dev", "alpha"),
                          ("2026-10-19", "09:00", "13:00", "dev", "beta"), ("2026-10-19", "12:00", "14:00", "meet", "overlap")]:
        r = c.post("/api/blocks", json={"date": d, "start": s, "end": e, "type": t, "project": p})
        assert r.status_code == 200, r.text
    c.put("/api/days/2026-10-23", json={"expected_h": 4, "sick_h": 1, "reason": "half"})
    app.state.clock = lambda: datetime(2026, 10, 20, 9, 0)
    c.post("/api/start", json={"type": "dev", "project": "alpha"})
    return app, c


def _snapshot(tmp_path):
    app, c = _build(tmp_path)
    out = {}
    for label, hour in (("morning", (9, 30)), ("past_stop", (18, 10))):
        app.state.clock = lambda h=hour: datetime(2026, 10, 20, *h)
        out[f"status_{label}"] = c.get("/api/status").json()
        out[f"brief_{label}"] = c.get("/api/status", params={"brief": "true"}).json()
    app.state.clock = lambda: datetime(2026, 10, 20, 9, 30)
    for g in ("week", "month", "quarter", "year"):
        out[f"summary_{g}"] = c.get("/api/summary", params={"group": g}).json()
    out["summary_range"] = c.get("/api/summary", params={"group": "week", "start": "2026-10-12", "end": "2026-10-18"}).json()
    for d in ("2026-10-14", "2026-10-19", "2026-10-20", "2026-10-12"):
        out[f"day_{d}"] = c.get(f"/api/day/{d}").json()
    return out


def test_api_output_is_unchanged(tmp_path):
    got = json.loads(json.dumps(_snapshot(tmp_path), sort_keys=True))
    if os.environ.get("WORKLOG_UPDATE_GOLDEN"):
        GOLDEN.write_text(json.dumps(got, indent=1, sort_keys=True) + "\n")
    assert got == json.loads(GOLDEN.read_text())
