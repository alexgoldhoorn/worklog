import json
from datetime import datetime

import pytest
from fastapi import FastAPI
from fastapi.responses import JSONResponse
from fastapi.testclient import TestClient

from balance import db
from worklog.config import Settings
from balance.web.api import ApiError, router


@pytest.fixture
def state_dir(tmp_path):
    d = tmp_path / "state"
    d.mkdir()
    (d / "gate.json").write_text(json.dumps({"date": "2026-11-02", "colour": "amber", "signals": [
        {"name": "hours", "text": "41 h of work in the last 7 days"}], "gaps": [], "protect": "one afternoon off",
        "speak": True, "pre_event": None, "numbers": {"hours_7d": 41}}))
    (d / "goals.json").write_text(json.dumps({"project": "Acme", "open": 12, "milestones": [
        {"content": "Preprod release", "due": "2026-11-12", "priority": 4}], "top3": [], "due_today_or_overdue": 0}))
    (d / "personal.json").write_text(json.dumps({"events": [
        {"date": "2026-11-03", "start": "16:30", "end": "17:30", "all_day": False, "title": "Kim dentist", "calendar": "Family"}]}))
    return d


def make_app(settings: Settings) -> FastAPI:
    """A throwaway app around the balance routers (the real one is worklog's factory)."""
    app = FastAPI(title="balance-test")
    app.state.settings = settings
    db.connect(settings.balance_db_path).close()

    @app.exception_handler(ApiError)
    async def _api_error(_request, exc: ApiError):
        return JSONResponse({"error": exc.message}, status_code=exc.status)

    app.include_router(router)
    return app


@pytest.fixture
def app(tmp_path, state_dir):
    a = make_app(Settings(db_path=str(tmp_path / "w.db"), balance_db_path=str(tmp_path / "t.db"), balance_state_dir=str(state_dir)))
    a.state.clock = lambda: datetime(2026, 11, 2, 9, 0)
    return a


@pytest.fixture
def client(app):
    return TestClient(app)
