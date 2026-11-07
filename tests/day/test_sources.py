"""host_context: the day Context built on the host (PA tools), from real paths (plan 2, Task 6)."""
import json
from datetime import date

from balance import db as bdb
from day import sources
from tests.day.fixtures import week as W


def test_host_context_reads_the_real_shaped_inputs(tmp_path):
    state = tmp_path / "state"
    W.write_state(state)
    plan = tmp_path / "plan.csv"; plan.write_text(W.PLAN)
    dbp = tmp_path / "balance.db"
    bdb.connect(str(dbp)).close()
    hol = tmp_path / "holidays_cache.json"
    hol.write_text(json.dumps({"2026": {"holidays": [{"date": "2026-11-06", "name": "x", "scope": "town"},
                                                     {"date": "2026-11-05", "name": "y", "scope": "city"}]}}))
    ctx = sources.host_context(date(2026, 11, 2), state_dir=str(state), db_path=str(dbp), plan_path=str(plan),
                               holidays_cache=str(hol), worklog_status={"week": {"worked_h_live": 12.0}})
    try:
        assert ctx.date == date(2026, 11, 2) and ctx.state_dir == str(state)
        assert ctx.holidays == {"2026-11-06": "x"}                      # school: town yes, city no
        assert ctx.client_holidays == {"2026-11-05": "y"}               # client: city yes, town no
        assert ctx.balance_settings["hard_stop"] == "18:00" and ctx.worklog_status["week"]["worked_h_live"] == 12.0
        assert ctx.rules["me"] == "Sam"
    finally:
        ctx.balance_conn.close()


def test_page_and_host_contexts_rank_alike_over_the_same_paths(tmp_path):
    """Focus 4, for real: the web app's context and host_context built from the same files."""
    from fastapi.testclient import TestClient
    from day import slots as dslots, model as dmodel
    from worklog.config import Settings
    from worklog.web.app import create_app
    state = tmp_path / "state"; W.write_state(state)
    plan = tmp_path / "plan.csv"; plan.write_text(W.PLAN)
    dbp = tmp_path / "balance.db"
    c = bdb.connect(str(dbp)); bdb.add_block(c, "2026-11-03", "07:30", "08:30", "run", "Easy Run", state="approved"); c.close()
    app = create_app(Settings(db_path=str(tmp_path / "w.db"), balance_db_path=str(dbp), balance_state_dir=str(state), plan_path=str(plan)))
    app.state.clock = lambda: W.NOW
    web = TestClient(app).post("/api/day/slots", json={"item": {"title": "Gym", "minutes": 60, "kind": "gym"}, "from": "2026-11-03", "to": "2026-11-04"}).json()["slots"]
    ctx = sources.host_context(date(2026, 11, 2), state_dir=str(state), db_path=str(dbp), plan_path=str(plan),
                               holidays_cache=str(tmp_path / "none.json"), worklog_status={}, now=W.NOW)
    try:
        host = dslots.find(dslots.Item(title="Gym", minutes=60, kind="gym"), dmodel.build_days(ctx, ["2026-11-03", "2026-11-04"]),
                           ctx.balance_settings, ctx.rules, "2026-11-02", now="09:00")
    finally:
        ctx.balance_conn.close()
    assert [(s["date"], s["start"], s["verdict"], s["best"]) for s in web] == [(s.date, s.start, s.verdict, s.best) for s in host]
