"""Expected hours per day: stored overrides, holidays, then the default rule."""
import json
import os
from datetime import date as _date, timedelta

from . import db, model


def skip_scopes() -> set[str]:
    """Holiday scopes that do not count as days off for work (WORKLOG_HOLIDAY_SKIP_SCOPES,
    comma-separated; e.g. local town holidays when the client follows the city's calendar)."""
    return {s.strip() for s in os.environ.get("WORKLOG_HOLIDAY_SKIP_SCOPES", "").split(",") if s.strip()}


def load_holidays(path: str | None) -> tuple[dict[str, str], str | None]:
    """({date: name}, warning). A missing or broken file gives no holidays and a warning that
    the pages show as a notice, rather than an error: the timer works without the cache."""
    if path is None:
        return {}, None
    try:
        with open(path) as f:
            data = json.load(f)
        out: dict[str, str] = {}
        skip = skip_scopes()
        for year in data.values():
            for h in year.get("holidays", []):
                if h.get("scope") not in skip:
                    out[h["date"]] = h["name"]
        return out, None
    except (OSError, ValueError, AttributeError, KeyError, TypeError) as e:
        return {}, f"holidays cache unavailable: {e}"


def _default(conn, date: str, holidays: dict[str, str]) -> db.DayExpectation:
    if date in holidays:
        return db.DayExpectation(date, 0, 0, holidays[date], "holiday")
    h = float(db.setting(conn, "default_expected_h")) if model.is_workday(date) else 0
    return db.DayExpectation(date, h, 0, "", "default")


def expected_for(conn, date: str, holidays: dict[str, str]) -> db.DayExpectation:
    """A stored override wins; else 0 h on a holiday; else the default workday on Mon-Fri."""
    return db.get_expectation(conn, date) or _default(conn, date, holidays)


def first_logged_day(conn) -> str | None:
    return conn.execute("SELECT MIN(date) FROM blocks").fetchone()[0]


def expected_between(conn, start: str, end: str, holidays, first_day: str | None) -> dict[str, db.DayExpectation]:
    """One entry per calendar day in the range. Days before `first_day` (the first logged
    block) expect 0 h, so a new install does not start with a huge negative balance."""
    stored = db.expectations_between(conn, start, end)
    out: dict[str, db.DayExpectation] = {}
    d, last = _date.fromisoformat(start), _date.fromisoformat(end)
    while d <= last:
        key = d.isoformat()
        e = stored.get(key) or _default(conn, key, holidays)
        if first_day is not None and key < first_day:
            e = db.DayExpectation(key, 0, e.sick_h, e.reason, "before-first")
        out[key] = e
        d += timedelta(days=1)
    return out


def week_expected(conn, key: str, holidays, first_day) -> float:
    start, end = model.week_bounds(key)
    return sum(e.expected_h for e in expected_between(conn, start, end, holidays, first_day).values())
