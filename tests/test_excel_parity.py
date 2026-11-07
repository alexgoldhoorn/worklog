"""Acceptance: the app's reports reproduce the Excel pivots. Skipped unless WORKLOG_EXCEL is set."""
import os
from datetime import date

import openpyxl
import pytest

from worklog import db, expect, reports, xlsx_io

EXCEL = os.environ.get("WORKLOG_EXCEL")
HOL = os.environ.get("WORKLOG_HOLIDAYS")
pytestmark = pytest.mark.skipif(not EXCEL, reason="WORKLOG_EXCEL not set")


def test_weekly_pivot_and_net_match_excel(tmp_path):
    conn = db.connect(str(tmp_path / "p.db"))
    holidays, _ = expect.load_holidays(HOL)
    parsed = xlsx_io.parse_rows(EXCEL, "log.xlsx")
    r = xlsx_io.import_blocks(conn, parsed, "replace")
    assert r["inserted"] == 1478 and r["skipped"] == 5
    xlsx_io.import_workdays(conn, parsed, holidays)
    today = date(2026, 10, 20)
    rows = {x["key"]: x for x in reports.grouped(conn, "week", "2026-03-01", "2026-10-20", holidays, today)}
    wb = openpyxl.load_workbook(EXCEL, data_only=True)
    pw = wb["Pivot weekly"]
    checked = 0
    bad = []
    for row in pw.iter_rows(min_row=4, max_col=5, values_only=True):
        key, _, worked, expected, extra = row
        if not key or key == "Grand Total":
            continue
        got = rows.get(key)
        if got is None:
            bad.append((key, "missing"))
            continue
        for name, g, w in (("worked", got["worked_h"], worked), ("expected", got["expected_h"], expected),
                           ("extra", got["extra_h"], extra)):
            if abs(g - w) >= 0.01:
                bad.append((key, name, round(g, 2), round(w, 2)))
        checked += 1
    assert not bad, bad
    assert checked >= 30
    # The pivot cache was last refreshed in week 42 while the log already holds week-43 rows,
    # so compare on the weeks the pivot knows, with week 42 as "current".
    pivot_rows = [r for k, r in sorted(rows.items()) if k <= "2026-42"]
    stats = reports.weekly_stats(pivot_rows, "2026-42")
    assert abs(stats["with_current"]["net_h"] - 71.05) < 0.01
    assert abs(stats["without_current"]["net_h"] - 66.18) < 0.01
    assert abs(stats["with_current"]["last4_h"] - 20.48) < 0.01
