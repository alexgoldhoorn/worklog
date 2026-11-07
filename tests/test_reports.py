from datetime import date

from worklog import db, reports


def _add(conn, date, start, end, type_="dev", client="ACME", billable=True):
    db.insert_block(conn, db.Block(None, date, start, end, None, type_, client, billable))


def test_day_totals_split_work_and_other(conn):
    _add(conn, "2026-10-20", "09:00", "11:00"); _add(conn, "2026-10-20", "11:00", "11:30", "eat", None, None)
    _add(conn, "2026-10-20", "11:30", None)            # open
    t = reports.day_totals(conn, "2026-10-20", db.break_types(conn))
    assert (t["work_h"], t["other_h"], t["billable_h"], t["by_client"]) == (2.0, 0.5, 2.0, {"ACME": 2.0})


def test_grouped_week_counts_full_current_week(conn):
    _add(conn, "2026-10-19", "09:00", "17:00"); _add(conn, "2026-10-20", "09:00", "13:00")
    rows = reports.grouped(conn, "week", "2026-10-12", "2026-10-25", {"2026-10-12": "h"}, date(2026, 10, 20))
    assert [r["key"] for r in rows] == ["2026-43"]  # first logged day is 2026-10-19 → week 42 has nothing, week 43 is current
    r = rows[0]
    assert (r["worked_h"], r["expected_h"], r["extra_h"]) == (12.0, 35.0, -23.0)
    assert r["expected_alt_h"] == 40.0 and r["extra_alt_h"] == -28.0
    assert r["days_worked"] == 2 and round(r["days_equiv"], 3) == round(12 / 7, 3)


def test_grouped_excludes_future_keys_and_includes_expected_only_weeks(conn):
    _add(conn, "2026-10-05", "09:00", "16:00")
    rows = reports.grouped(conn, "week", "2026-10-05", "2026-11-30", {}, date(2026, 10, 20))
    assert [r["key"] for r in rows] == ["2026-41", "2026-42", "2026-43"]
    assert rows[1]["worked_h"] == 0 and rows[1]["expected_h"] == 35


def test_month_and_quarter_keys(conn):
    _add(conn, "2026-09-30", "09:00", "10:00"); _add(conn, "2026-10-01", "09:00", "10:00")
    assert [r["key"] for r in reports.grouped(conn, "month", "2026-09-01", "2026-10-31", {}, date(2026, 10, 20))] == ["2026-09", "2026-10"]
    assert [r["key"] for r in reports.grouped(conn, "quarter", "2026-01-01", "2026-12-31", {}, date(2026, 10, 20))] == ["2026-Q3", "2026-Q4"]


def test_weekly_stats_match_excel_conventions():
    rows = [{"key": k, "extra_h": e, "extra_alt_h": e - 5} for k, e in
            [("2026-38", 8.7), ("2026-39", 6.0), ("2026-40", 2.5), ("2026-41", 7.0), ("2026-42", 4.9)]]
    s = reports.weekly_stats(rows, "2026-42")
    assert round(s["with_current"]["net_h"], 1) == 29.1 and round(s["without_current"]["net_h"], 1) == 24.2
    assert round(s["with_current"]["last4_h"], 1) == 20.4 and round(s["without_current"]["last4_h"], 1) == 24.2
    assert s["with_current"]["min_h"] == 2.5 and s["with_current"]["max_h"] == 8.7
    assert s["with_current"]["median_h"] == 6.0 and s["without_current"]["q1_h"] == 5.125


def test_weekly_stats_small_inputs():
    s = reports.weekly_stats([{"key": "2026-42", "extra_h": 1.0, "extra_alt_h": 0.0}], "2026-42")
    assert s["without_current"]["net_h"] == 0.0 and s["without_current"]["median_h"] is None
    assert s["with_current"]["net_h"] == 1.0 and s["with_current"]["q1_h"] is None


def test_net_balance(conn):
    _add(conn, "2026-10-19", "09:00", "17:00")
    b = reports.net_balance(conn, {}, date(2026, 10, 20))
    assert b == {"with_current_h": -27.0, "without_current_h": 0.0}


def test_invoice_days_lists_worked_and_off(conn):
    _add(conn, "2026-10-13", "09:00", "17:00")
    db.set_expectation(conn, db.DayExpectation("2026-10-14", 0, 0, "vacation", "manual"))
    days = reports.invoice_days(conn, "2026-10", {"2026-10-12": "Festa Nacional"}, date(2026, 10, 20))
    by = {d["date"]: d for d in days}
    assert by["2026-10-12"]["reason"] == "Festa Nacional" and by["2026-10-12"]["source"] == "before-first"
    assert by["2026-10-13"]["worked"] and by["2026-10-13"]["worked_h"] == 8.0
    assert by["2026-10-14"] == {**by["2026-10-14"], "worked": False, "expected_h": 0, "reason": "vacation"}
    assert days[-1]["date"] == "2026-10-20"
    assert by["2026-10-13"]["weekday"] == "Tue"
