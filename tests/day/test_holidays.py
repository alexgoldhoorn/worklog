"""School holidays: the client's calendar is not the school's (review finding 2)."""
import json

from day import holidays


def test_school_holidays_keep_region_and_town_drop_city(tmp_path):
    p = tmp_path / "holidays_cache.json"
    p.write_text(json.dumps({"2026": {"holidays": [
        {"date": "2026-09-11", "name": "Region day", "scope": "region"},
        {"date": "2026-09-16", "name": "Town festival", "scope": "town"},
        {"date": "2026-09-24", "name": "City festival", "scope": "city"}]}}))
    h = holidays.school_holidays(str(p))
    assert set(h) == {"2026-09-11", "2026-09-16"}
    assert holidays.school_holidays(None) == {} and holidays.school_holidays(str(tmp_path / "nope.json")) == {}


def test_without_scope_settings_every_holiday_counts(tmp_path, monkeypatch):
    monkeypatch.delenv("DAY_SCHOOL_HOLIDAY_SCOPES", raising=False)
    monkeypatch.delenv("WORKLOG_HOLIDAY_SKIP_SCOPES", raising=False)
    p = tmp_path / "holidays_cache.json"
    p.write_text(json.dumps({"2026": {"holidays": [
        {"date": "2026-09-11", "name": "a", "scope": "region"}, {"date": "2026-09-24", "name": "b", "scope": "city"}]}}))
    assert set(holidays.school_holidays(str(p))) == set(holidays.client_holidays(str(p))) == {"2026-09-11", "2026-09-24"}
