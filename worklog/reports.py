"""Reports: day totals, grouped weeks/months/quarters/years, statistics, invoice days."""
import calendar
import statistics
from datetime import date as _date, timedelta

from . import db, expect, model

_KEYS = {"week": model.week_key, "month": model.month_key,
         "quarter": model.quarter_key, "year": model.year_key}


def rate_per_h(conn) -> float | None:
    """Hourly rate from settings; a per-day rate is spread over the default expected hours."""
    raw = db.setting(conn, "rate").strip()
    if not raw:
        return None
    rate = float(raw)
    if db.setting(conn, "rate_unit") == "day":
        rate /= float(db.setting(conn, "default_expected_h"))
    return rate


def amount(billable_h: float, rate: float | None) -> float | None:
    return None if rate is None else round(billable_h * rate, 2)


def day_totals(conn, date: str, break_types) -> dict:
    return _totals(db.blocks_on(conn, date), break_types)


def _totals(blocks, break_types) -> dict:
    t = {"work_h": 0.0, "other_h": 0.0, "billable_h": 0.0, "by_client": {}, "by_type": {}, "by_project": {}}
    for b in blocks:
        h = model.hours(model.minutes(b.start, b.end))
        if b.end is None:
            continue
        if model.work_type(b.type, break_types) == "other":
            t["other_h"] += h
            continue
        t["work_h"] += h
        if b.billable:
            t["billable_h"] += h
        if b.client:
            t["by_client"][b.client] = t["by_client"].get(b.client, 0.0) + h
        t["by_type"][b.type] = t["by_type"].get(b.type, 0.0) + h
        proj = (b.project or "").strip()
        t["by_project"][proj] = t["by_project"].get(proj, 0.0) + h
    return t


def grouped(conn, group: str, start: str, end: str, holidays, today: _date) -> list[dict]:
    keyf = _KEYS[group]
    btypes = db.break_types(conn)
    default_h = float(db.setting(conn, "default_expected_h"))
    base, alt = float(db.setting(conn, "base_week_h")), float(db.setting(conn, "alt_week_h"))
    first_day = expect.first_logged_day(conn)
    rate = rate_per_h(conn)

    # Expectation runs through Sunday of the current week when the range reaches today.
    sunday = today + timedelta(days=6 - today.weekday())
    exp_end = sunday.isoformat() if end >= today.isoformat() else end

    blocks_by: dict[str, list[db.Block]] = {}
    for b in db.blocks_between(conn, start, end):
        blocks_by.setdefault(keyf(b.date), []).append(b)
    exp_by: dict[str, list[db.DayExpectation]] = {}
    if start <= exp_end:
        for e in expect.expected_between(conn, start, exp_end, holidays, first_day).values():
            exp_by.setdefault(keyf(e.date), []).append(e)

    limit = keyf(today.isoformat())
    keys = set(blocks_by)
    keys |= {k for k, es in exp_by.items() if any(e.expected_h for e in es)}
    rows = []
    for k in sorted(k for k in keys if k <= limit):
        t = _totals(blocks_by.get(k, []), btypes)
        exp_h = sum(e.expected_h for e in exp_by.get(k, []))
        exp_alt = alt * exp_h / base
        days = {b.date for b in blocks_by.get(k, [])
                if b.end is not None and model.work_type(b.type, btypes) == "work"}
        rows.append({
            "key": k, "worked_h": t["work_h"], "other_h": t["other_h"],
            "expected_h": exp_h, "extra_h": t["work_h"] - exp_h,
            "expected_alt_h": exp_alt, "extra_alt_h": t["work_h"] - exp_alt,
            "days_worked": len(days), "days_equiv": t["work_h"] / default_h,
            "billable_h": t["billable_h"], "by_client": t["by_client"],
            "sick_h": sum(e.sick_h for e in exp_by.get(k, [])),
            "amount": amount(t["billable_h"], rate), "by_type": t["by_type"],
            "by_project": t["by_project"],
        })
    return rows


def _stats(rows: list[dict]) -> dict:
    extra = [r["extra_h"] for r in rows]
    alt = [r["extra_alt_h"] for r in rows]
    out = {"net_h": float(sum(extra)), "last4_h": float(sum(extra[-4:])),
           "net_alt_h": float(sum(alt)), "last4_alt_h": float(sum(alt[-4:])),
           "min_h": None, "max_h": None, "median_h": None,
           "q1_h": None, "q3_h": None, "median_alt_h": None}
    if extra:
        out.update(min_h=min(extra), max_h=max(extra), median_h=statistics.median(extra),
                   median_alt_h=statistics.median(alt))
    if len(extra) >= 2:
        q = statistics.quantiles(extra, n=4, method="inclusive")
        out.update(q1_h=q[0], q3_h=q[2])
    return out


def weekly_stats(rows: list[dict], current_key: str) -> dict:
    rows = sorted(rows, key=lambda r: r["key"])
    return {"with_current": _stats(rows),
            "without_current": _stats([r for r in rows if r["key"] != current_key])}


_NET_CACHE: dict = {}  # db path -> (stamp, extras, alts) for the closed weeks before the current one
_NET_CACHE_MAX = 8


def _closed_stamp(conn, first: str, last: str, holidays, week_end_excl: str) -> tuple:
    """Cheap fingerprint of everything the closed weeks' rows depend on."""
    blocks = conn.execute(
        "SELECT COUNT(*), COALESCE(SUM(id), 0), COALESCE(MAX(updated_at), ''), COALESCE(MAX(id), 0) "
        "FROM blocks WHERE date BETWEEN ? AND ?", (first, last)).fetchone()
    exps = conn.execute(
        "SELECT date, expected_h, sick_h, reason, source FROM day_expectations WHERE date BETWEEN ? AND ?",
        (first, last)).fetchall()
    sett = conn.execute("SELECT key, value FROM settings ORDER BY key").fetchall()
    bts = conn.execute("SELECT name FROM break_types ORDER BY name").fetchall()
    return (first, last, tuple(blocks), tuple(tuple(r) for r in exps), tuple(tuple(r) for r in sett),
            tuple(r[0] for r in bts), tuple(sorted(holidays.items())))


def _net_rows(conn, holidays, today: _date, first: str, use_cache: bool) -> list[dict]:
    """Weekly rows from `first` through the current week. Closed weeks are cached per database."""
    wstart, _ = model.week_bounds(model.week_key(today.isoformat()))
    cur = grouped(conn, "week", max(first, wstart), today.isoformat(), holidays, today) if first <= today.isoformat() else []
    if first >= wstart:
        return cur
    last = (_date.fromisoformat(wstart) - timedelta(days=1)).isoformat()
    path = conn.execute("PRAGMA database_list").fetchone()[2] or ""
    stamp = _closed_stamp(conn, first, last, holidays, wstart) if use_cache and path else None
    hit = _NET_CACHE.get(path) if stamp is not None else None
    if hit and hit[0] == stamp:
        closed = hit[1]
    else:
        closed = grouped(conn, "week", first, last, holidays, today)
        if stamp is not None:
            if len(_NET_CACHE) >= _NET_CACHE_MAX:
                _NET_CACHE.clear()
            _NET_CACHE[path] = (stamp, closed)
    return closed + cur


def net_balance(conn, holidays, today: _date, use_cache: bool = True) -> dict:
    first = expect.first_logged_day(conn)
    if first is None:
        return {"with_current_h": 0.0, "without_current_h": 0.0}
    rows = _net_rows(conn, holidays, today, first, use_cache)
    s = weekly_stats(rows, model.week_key(today.isoformat()))
    return {"with_current_h": s["with_current"]["net_h"],
            "without_current_h": s["without_current"]["net_h"]}


def invoice_days(conn, month_key: str, holidays, today: _date) -> list[dict]:
    y, m = map(int, month_key.split("-"))
    last = min(_date(y, m, calendar.monthrange(y, m)[1]), today)
    first = _date(y, m, 1)
    if last < first:
        return []
    return day_rows(conn, first.isoformat(), last.isoformat(), holidays)


def day_rows(conn, s: str, e: str, holidays) -> list[dict]:
    """One row per day in [s, e]: worked, expected, reason, source, worked flag."""
    btypes = db.break_types(conn)
    rate = rate_per_h(conn)
    exps = expect.expected_between(conn, s, e, holidays, expect.first_logged_day(conn))
    by_date: dict[str, list[db.Block]] = {}
    for b in db.blocks_between(conn, s, e):
        by_date.setdefault(b.date, []).append(b)
    out = []
    for key, x in exps.items():
        t = _totals(by_date.get(key, []), btypes)
        w = t["work_h"]
        out.append({"date": key, "weekday": _date.fromisoformat(key).strftime("%a"),
                    "worked_h": w, "expected_h": x.expected_h, "reason": x.reason,
                    "source": x.source, "worked": w > 0,
                    "billable_h": t["billable_h"], "amount": amount(t["billable_h"], rate)})
    return out


def heatmap(conn, start: str, end: str) -> dict:
    """Work hours by ISO weekday (0=Mon) and hour of day over [start, end]; open blocks skipped."""
    btypes = db.break_types(conn)
    cells = [[0.0] * 24 for _ in range(7)]
    days = set()
    for b in db.blocks_between(conn, start, end):
        if b.end is None or model.work_type(b.type, btypes) != "work":
            continue
        wd = _date.fromisoformat(b.date).weekday()
        s_min, e_min = model.minutes("00:00", b.start), model.minutes("00:00", b.end)
        if e_min <= s_min:
            continue
        days.add(b.date)
        for h in range(s_min // 60, min(23, (e_min - 1) // 60) + 1):
            lo, hi = max(s_min, h * 60), min(e_min, (h + 1) * 60)
            cells[wd][h] += (hi - lo) / 60
    return {"cells": [[round(v, 3) for v in row] for row in cells], "days": len(days)}
