import json

from worklog import db, expect


def _cache(tmp_path, body):
    p = tmp_path / "h.json"; p.write_text(body); return str(p)


def test_load_holidays_reads_pa_cache(tmp_path):
    h, warn = expect.load_holidays(_cache(tmp_path, json.dumps({"2026": {"holidays": [
        {"date": "2026-10-12", "scope": "region", "name": "Festa Nacional"},
        {"date": "2026-09-16", "scope": "town", "name": "Town festival"},
        {"date": "2026-09-24", "scope": "city", "name": "City festival"}]}})))
    assert h == {"2026-10-12": "Festa Nacional", "2026-09-24": "City festival"} and warn is None


def test_load_holidays_tolerates_missing_or_broken_file(tmp_path):
    assert expect.load_holidays(str(tmp_path / "none.json"))[0] == {}
    h, warn = expect.load_holidays(_cache(tmp_path, "{not json"))
    assert h == {} and "unavailable" in warn
    assert expect.load_holidays(None) == ({}, None)


def test_expected_for_default_holiday_and_override(conn):
    hol = {"2026-10-12": "Festa Nacional"}
    assert expect.expected_for(conn, "2026-10-20", hol).expected_h == 7
    assert expect.expected_for(conn, "2026-10-18", hol).expected_h == 0
    e = expect.expected_for(conn, "2026-10-12", hol)
    assert (e.expected_h, e.reason, e.source) == (0, "Festa Nacional", "holiday")
    db.set_expectation(conn, db.DayExpectation("2026-10-12", 7, 0, "client worked", "manual"))
    assert expect.expected_for(conn, "2026-10-12", hol).expected_h == 7


def test_week_expected_counts_full_week_and_respects_first_day(conn):
    db.insert_block(conn, db.Block(None, "2026-10-14", "09:00", "10:00", None, "dev", "ACME", True))
    first = expect.first_logged_day(conn)
    assert first == "2026-10-14"
    assert expect.week_expected(conn, "2026-42", {"2026-10-12": "x"}, first) == 21   # Wed–Fri only
    assert expect.week_expected(conn, "2026-43", {}, first) == 35                     # future week, full
    between = expect.expected_between(conn, "2026-10-12", "2026-10-13", {}, first)
    assert all(e.source == "before-first" and e.expected_h == 0 for e in between.values())


def test_before_first_keeps_reason(conn):
    hol = {"2026-10-12": "Festa Nacional"}
    r = expect.expected_between(conn, "2026-10-12", "2026-10-13", hol, "2026-10-14")
    assert r["2026-10-12"].reason == "Festa Nacional" and r["2026-10-12"].source == "before-first"
