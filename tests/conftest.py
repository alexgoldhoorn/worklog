import os

os.environ["WORKLOG_ENV_FILE"] = os.devnull   # never the developer's real host settings

from datetime import datetime

import pytest
from fastapi.testclient import TestClient

from worklog import db
from worklog.config import Settings
from worklog.web.app import create_app


@pytest.fixture(autouse=True)
def example_config(monkeypatch):
    """The suite runs against the example household and a town/city/region holiday split."""
    from day import rules
    monkeypatch.setenv("DAY_RULES", rules.EXAMPLE_PATH)
    monkeypatch.setenv("WORKLOG_HOLIDAY_SKIP_SCOPES", "town")
    monkeypatch.setenv("DAY_SCHOOL_HOLIDAY_SCOPES", "region,town")
    from balance import sync
    monkeypatch.setattr(sync, "TZ", "Europe/Amsterdam")


@pytest.fixture
def conn(tmp_path):
    c = db.connect(str(tmp_path / "t.db"))
    yield c
    c.close()


@pytest.fixture
def app(tmp_path):
    (tmp_path / "state").mkdir(exist_ok=True)
    from balance import db as bdb
    bdb.connect(str(tmp_path / "balance.db")).close()  # the store exists in production
    a = create_app(Settings(db_path=str(tmp_path / "t.db"), calendar_db_path=None, holidays_path=None,
                            balance_db_path=str(tmp_path / "balance.db"), balance_state_dir=str(tmp_path / "state")))
    a.state.clock = lambda: datetime(2026, 10, 20, 9, 0)
    return a


@pytest.fixture
def client(app):
    return TestClient(app)
