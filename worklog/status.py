"""The /api/status payloads: the full timer status (today, week, month, chips, notices) and the
compact one for small clients. Pure assembly over a connection and a clock reading; the web
layer only supplies them."""
import os
from datetime import date as _date, datetime, timedelta

from . import calendar as wcal, db, model, reports, timer
from .db import Block
from .validate import is_hhmm


def _fmt_day(d: str) -> str:
    x = _date.fromisoformat(d)
    return f"{x:%a} {x.day} {x:%b}"  # not %-d: that is not portable to Windows


def overlap_notices(blocks: list[Block]) -> list[str]:
    return [x["text"] for x in overlap_details(blocks)]


def overlap_details(blocks: list[Block]) -> list[dict]:
    """Overlaps as {date, text}: the ISO date lets a client place the notice without parsing text."""
    by_date: dict[str, list[Block]] = {}
    for b in blocks:
        by_date.setdefault(b.date, []).append(b)
    out = []
    for d in sorted(by_date):
        for a, b in model.overlaps(by_date[d]):
            out.append({"date": d, "text": f"Overlap {_fmt_day(d)}: {a.start}–{a.end or 'now'} {a.type} and "
                                           f"{b.start}–{b.end or 'now'} {b.type} · both count in full"})
    return out


def live_min(st: dict, now: datetime, since: _date) -> int:
    """Minutes of the running work block on or after `since` (midnight): a block that crossed
    midnight only counts its part inside the period."""
    blk = st.get("block")
    if st["state"] != "working" or not blk:
        return 0
    started = datetime.fromisoformat(f"{blk['date']} {blk['start']}")
    lo = max(started, datetime.combine(since, datetime.min.time()))
    return max(0, int((now.replace(second=0, microsecond=0) - lo).total_seconds() // 60))


def hard_stop(settings) -> str | None:
    """The balance store's hard stop ("HH:MM"), or None when there is no store."""
    path = settings.balance_db_path
    if not path or not os.path.exists(path):
        return None
    try:
        from balance import db as bdb  # lazy: day.web imports the web layer
        conn = bdb.connect(path, check_same_thread=False, readonly=True)
        try:
            v = bdb.get_settings(conn).get("hard_stop")
        finally:
            conn.close()
        return v if v and is_hhmm(v) else None
    except Exception:
        return None


def brief(conn, now: datetime, holidays, notices, settings) -> dict:
    """Compact status for small clients (the Garmin widget): no week/month/net series."""
    today = now.date().isoformat()
    st = timer.status(conn, now)
    bt = db.break_types(conn)
    blk = st["block"]
    running = live_min(st, now, now.date())
    work = [b for b in db.blocks_on(conn, today) if model.work_type(b.type, bt) == "work"]
    last = max(work, key=lambda b: b.start, default=None)
    return {"state": st["state"], "date": st["date"], "since": st["since"], "elapsed_s": st["elapsed_s"],
            "type": blk["type"] if blk else None, "project": blk["project"] if blk else None,
            "today_work_h": round(reports.day_totals(conn, today, bt)["work_h"] + running / 60, 2),
            "resume": {"type": last.type, "project": last.project} if last else None}


_EMPTY_WEEK = {"worked_h": 0.0, "other_h": 0.0, "expected_h": 0.0, "extra_h": 0.0,
               "expected_alt_h": 0.0, "extra_alt_h": 0.0, "days_worked": 0, "days_equiv": 0.0,
               "billable_h": 0.0, "by_client": {}, "sick_h": 0.0}
_EMPTY_MONTH = {"worked_h": 0.0, "expected_h": 0.0, "extra_h": 0.0, "days_worked": 0, "billable_h": 0.0}


def _week(conn, now, today, holidays, running) -> dict:
    t = now.date()
    wk = model.week_key(today)
    wstart, wend = model.week_bounds(wk)
    rows = reports.grouped(conn, "week", wstart, min(wend, today), holidays, t)
    week = next((r for r in rows if r["key"] == wk), None) or {"key": wk, **_EMPTY_WEEK}
    week["worked_h_live"] = week["worked_h"] + running / 60
    week["extra_h_live"] = week["worked_h_live"] - week["expected_h"]
    # per-day series for the whole ISO week (future days carry expected hours only)
    week["days"] = [
        {"date": d["date"], "weekday": d["weekday"], "worked_h": d["worked_h"], "expected_h": d["expected_h"]}
        for d in reports.day_rows(conn, wstart, wend, holidays)]
    return week


def _month(conn, now, today, holidays, running) -> dict:
    mk = model.month_key(today)
    mrows = reports.grouped(conn, "month", f"{mk}-01", today, holidays, now.date())
    mrow = next((r for r in mrows if r["key"] == mk), None) or {"key": mk, **_EMPTY_MONTH}
    month = {k: mrow[k] for k in ("key", "worked_h", "expected_h", "extra_h", "days_worked", "billable_h")}
    month["worked_h_live"] = month["worked_h"] + running / 60
    return month


def chips(conn, today: _date, break_types) -> dict:
    """Most used work types / projects in the last 60 days, plus the break types by recent use."""
    since = (today - timedelta(days=60)).isoformat()
    types: dict[str, int] = {}
    projects: dict[str, int] = {}
    breaks: dict[str, int] = {}
    for b in db.blocks_between(conn, since, today.isoformat()):
        if model.work_type(b.type, break_types) != "work":
            breaks[b.type] = breaks.get(b.type, 0) + 1
            continue
        types[b.type] = types.get(b.type, 0) + 1
        # a calendar meeting's project is its title, not a project to pick again
        if b.source != "calendar" and b.project and b.project.strip():
            projects[b.project] = projects.get(b.project, 0) + 1

    def top(d):
        return [k for k, _ in sorted(d.items(), key=lambda kv: (-kv[1], kv[0]))[:8]]

    return {"types": top(types), "projects": top(projects),
            # eat first, then the break types by recent use, then the rest alphabetically
            "break_types": sorted(break_types, key=lambda n: (n != "eat", -breaks.get(n, 0), n))}


def build(conn, now: datetime, holidays, notices, settings) -> dict:
    """The full status. `notices` are the request-level notices (holiday cache); calendar
    availability is appended here."""
    t = now.date()
    today = t.isoformat()
    out = timer.status(conn, now)
    out["now"] = now.replace(microsecond=0).isoformat()
    out["tz"] = settings.tz
    out["hard_stop"] = hard_stop(settings)
    out["past_stop_min"] = None
    blk = out.get("block")
    if out["hard_stop"] and out["state"] == "working" and blk and blk.get("date") == today:
        hh, mm = out["hard_stop"].split(":")
        out["past_stop_min"] = max(0, now.hour * 60 + now.minute - (int(hh) * 60 + int(mm)))
    bt = db.break_types(conn)
    out["today"] = reports.day_totals(conn, today, bt)
    running = max(0, out["elapsed_min"] if out["state"] == "working" and out["elapsed_min"] else 0)
    out["running_min"] = running
    out["today"]["work_h_live"] = out["today"]["work_h"] + live_min(out, now, t) / 60
    wstart, _ = model.week_bounds(model.week_key(today))
    out["week"] = _week(conn, now, today, holidays, live_min(out, now, _date.fromisoformat(wstart)))
    out["month"] = _month(conn, now, today, holidays,
                          live_min(out, now, _date.fromisoformat(f"{model.month_key(today)}-01")))
    out["week_basis_h"] = float(db.setting(conn, "base_week_h"))
    out["today"]["expected_h"] = next((d["expected_h"] for d in out["week"]["days"] if d["date"] == today), 0.0)
    out["needs_review"] = [
        {"date": b.date, "start": b.start, "end": b.end, "type": b.type}
        for b in db.auto_closed_between(conn, (t - timedelta(days=30)).isoformat(), today)]
    out["net"] = reports.net_balance(conn, holidays, t)
    _, cal_warn = wcal.proposals(settings.calendar_db_path, today, [])
    det = overlap_details(db.blocks_between(conn, (t - timedelta(days=14)).isoformat(), today))
    out["overlaps"] = [x["text"] for x in det]
    out["overlap_details"] = det
    out["notices"] = notices + ([cal_warn] if cal_warn else [])
    out["chips"] = chips(conn, t, bt)
    return out
