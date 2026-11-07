"""Host-side readers that turn local data files into gate.Inputs.

Every reader is defensive: a missing or unreadable source becomes a gap, never a
crash, so one broken feed cannot take the verdict down with it.
"""
from __future__ import annotations

import csv
import json
import os
import sqlite3
from datetime import date, datetime, timedelta

from . import db as bdb
from .config import STATE_ROOT
from .gate import Inputs


def _path(var: str, name: str) -> str:
    return os.path.expanduser(os.environ.get(var) or os.path.join(STATE_ROOT, name))


WORKLOG_DB = _path("BALANCE_WORKLOG_DB", "worklog.db")
WELLNESS_PARQUET = _path("BALANCE_WELLNESS", "inputs/wellness.parquet")
PLAN_CSV = _path("BALANCE_PLAN", "inputs/plan.csv")
GARMIN_ACTIVITIES = _path("BALANCE_ACTIVITIES", "inputs/garmin_activities.csv")
COACH_HEALTH = _path("BALANCE_COACH_HEALTH", "inputs/health.json")
WORK_CALENDAR_DB = _path("BALANCE_CALENDAR_DB", "work_calendar.db")
ANNOTATIONS_DB = _path("BALANCE_ANNOTATIONS_DB", "calendar_annotations.db")
HOLIDAYS_CACHE = _path("WORKLOG_HOLIDAYS", "holidays_cache.json")

RUN_TYPES = {"easy", "long", "intervals", "tempo", "race"}
RUN_SPORTS = {"running", "trail_running", "treadmill_running", "track_running"}
TRAVEL_WORDS = ("vacation", "vacances", "travel", "trip", "viaje", "viatge", "holiday", "flight", "vuelo")


def _hm(s: str) -> int:
    h, m = s.split(":")
    return int(h) * 60 + int(m)


# ---- worklog ----------------------------------------------------------------

def read_worklog(today: date, hard_stop: str, grace_min: int, days: int = 28,
                 path: str = WORKLOG_DB, gaps: list | None = None) -> tuple[dict, set]:
    """({date: work hours}, {dates with a work block ending after hard stop + grace})."""
    gaps = gaps if gaps is not None else []
    if not os.path.exists(path):
        gaps.append("worklog database missing")
        return {}, set()
    lo = (today - timedelta(days=days - 1)).isoformat()
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        breaks = {r[0] for r in conn.execute("SELECT name FROM break_types")}
        rows = conn.execute("SELECT date, start, end, type FROM blocks WHERE date >= ? AND date <= ?",
                            (lo, today.isoformat())).fetchall()
        conn.close()
    except sqlite3.Error as e:
        gaps.append(f"worklog unreadable: {e}")
        return {}, set()
    hours: dict[date, float] = {}
    evenings: set[date] = set()
    limit = _hm(hard_stop) + grace_min
    now_hm = datetime.now().strftime("%H:%M")
    for r in rows:
        if r["type"] in breaks:
            continue
        d = date.fromisoformat(r["date"])
        end = r["end"] or (now_hm if r["date"] == today.isoformat() else None)
        if not end:
            continue
        mins = max(0, _hm(end) - _hm(r["start"]))
        hours[d] = hours.get(d, 0.0) + mins / 60
        if _hm(end) > limit:
            evenings.add(d)
    return hours, evenings


# ---- Garmin wellness --------------------------------------------------------

def read_wellness(today: date, days: int = 120, path: str = WELLNESS_PARQUET,
                  gaps: list | None = None) -> list[dict]:
    gaps = gaps if gaps is not None else []
    if not os.path.exists(path):
        gaps.append("wellness.parquet missing")
        return []
    try:
        import pyarrow.parquet as pq  # system python: pyarrow<21 (--user), 2026-11-02
        t = pq.read_table(path, columns=["local_date", "resting_hr", "hrv_last_night_ms", "sleep_s",
                                         "sleep_score", "stress_avg"]).to_pylist()
    except Exception as e:  # noqa: BLE001 - any reader failure is a gap
        gaps.append(f"wellness unreadable: {e}")
        return []
    lo = today - timedelta(days=days - 1)
    out = []
    for r in t:
        d = r.get("local_date")
        if isinstance(d, datetime):
            d = d.date()
        elif isinstance(d, str):
            d = date.fromisoformat(d[:10])
        if d is None or d < lo or d > today:
            continue
        sleep_s = r.get("sleep_s")
        out.append({"date": d, "resting_hr": _num(r.get("resting_hr")),
                    "hrv": _num(r.get("hrv_last_night_ms")),
                    "sleep_h": (sleep_s / 3600) if _num(sleep_s) else None,
                    "sleep_score": _num(r.get("sleep_score")), "stress": _num(r.get("stress_avg"))})
    return sorted(out, key=lambda x: x["date"])


def _num(v):
    try:
        if v is None:
            return None
        f = float(v)
        return None if f != f else f  # NaN
    except (TypeError, ValueError):
        return None


# ---- plan + activities ------------------------------------------------------

def read_plan(path: str = PLAN_CSV, gaps: list | None = None) -> list[dict]:
    """plan.csv rows: {date, session, type, distance_km}."""
    gaps = gaps if gaps is not None else []
    try:
        with open(path, newline="") as f:
            rows = []
            for r in csv.DictReader(f):
                try:
                    rows.append({"date": date.fromisoformat(r["date"]), "session": r.get("session", ""),
                                 "type": (r.get("type") or "").strip().lower(),
                                 "distance_km": _num(r.get("distance_km"))})
                except (KeyError, ValueError):
                    continue
            return rows
    except OSError:
        gaps.append("plan.csv missing")
        return []


def planned_runs(plan: list[dict], lo: date, hi: date) -> list[date]:
    return sorted({r["date"] for r in plan if r["type"] in RUN_TYPES and lo <= r["date"] <= hi})


def upcoming_races(plan: list[dict], today: date, days: int = 60) -> list[dict]:
    return [{"date": r["date"], "title": r["session"].replace("RACE — ", "").strip() or "race",
             "kind": "race"} for r in plan
            if r["type"] == "race" and 0 <= (r["date"] - today).days <= days]


def read_runs_done(today: date, days: int = 28, path: str = GARMIN_ACTIVITIES,
                   gaps: list | None = None) -> list[date]:
    gaps = gaps if gaps is not None else []
    lo = today - timedelta(days=days - 1)
    out = set()
    try:
        with open(path, newline="") as f:
            for r in csv.DictReader(f):
                if (r.get("sport") or "").strip().lower() not in RUN_SPORTS:
                    continue
                try:
                    d = date.fromisoformat((r.get("start") or "")[:10])
                except ValueError:
                    continue
                if lo <= d <= today:
                    out.add(d)
    except OSError:
        gaps.append("garmin_activities.csv missing")
    return sorted(out)


def illness_open(path: str = COACH_HEALTH) -> bool:
    try:
        with open(path) as f:
            data = json.load(f)
        return any(isinstance(i, dict) and i.get("kind") == "illness" and not i.get("closed_on")
                   for i in data.get("issues", []))
    except (OSError, ValueError, AttributeError, TypeError):
        return False


# ---- work calendar ----------------------------------------------------------

def read_work_calendar(lo: date, hi: date, path: str = WORK_CALENDAR_DB) -> list[dict]:
    """Imported Outlook meetings: {date, start, end, title} (strings)."""
    if not os.path.exists(path):
        return []
    try:
        conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        rows = conn.execute("SELECT date, start, end, title, status FROM events WHERE date >= ? AND date <= ?"
                            " ORDER BY date, start", (lo.isoformat(), hi.isoformat())).fetchall()
        conn.close()
    except sqlite3.Error:
        return []
    return [dict(r) for r in rows if (r["status"] or "confirmed") != "cancelled"]


# ---- snapshots written by the sync job ----------------------------------------

def read_json(path: str, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def read_mirror(state_dir: str) -> dict:
    """Work-calendar mirror snapshot written by the sync job (balance/snapshots.py)."""
    return read_json(os.path.join(state_dir, "mirror.json"),
                     {"events": [], "coverage": {"last_import_end": None, "last_import_at": None, "last_import_source": ""}})


def read_school_days(state_dir: str) -> dict:
    """{date: {status, name}} from school_days.json; {} when absent (duties then flag 'unknown')."""
    return read_json(os.path.join(state_dir, "school_days.json"), {}).get("days", {}) or {}


def read_annotations(state_dir: str) -> dict:
    d = read_json(os.path.join(state_dir, "annotations.json"), {})
    return {"one_off": d.get("one_off", []), "recurring": d.get("recurring", [])}


def personal_events(state_dir: str) -> list[dict]:
    return read_json(os.path.join(state_dir, "personal.json"), {}).get("events", [])


def read_felt(state_dir: str, today: date, days: int = 14) -> list[dict]:
    """One rating per day (the last tap wins), so a double tap cannot count twice."""
    by_day: dict[date, str] = {}
    lo = today - timedelta(days=days)
    try:
        with open(os.path.join(state_dir, "load.jsonl")) as f:
            for line in f:
                try:
                    r = json.loads(line)
                    d = date.fromisoformat(r["date"])
                except (ValueError, KeyError, TypeError):
                    continue
                if lo <= d <= today:
                    by_day[d] = r.get("answer")
    except OSError:
        pass
    return [{"date": d, "answer": a} for d, a in sorted(by_day.items())]


def travel_events(personal: dict, today: date, days: int = 60) -> list[dict]:
    """Vacation/travel markers from the personal-calendar snapshot."""
    out = []
    for e in personal.get("events", []):
        title = str(e.get("title", ""))
        low = title.lower()
        if not any(w in low for w in TRAVEL_WORDS):
            continue
        try:
            d = date.fromisoformat(str(e.get("date"))[:10])
        except ValueError:
            continue
        if 0 <= (d - today).days <= days:
            out.append({"date": d, "title": title, "kind": "travel"})
    return out


# ---- assemble ---------------------------------------------------------------

def gather(today: date, state_dir: str, rules: dict, settings: dict) -> Inputs:
    gaps: list[str] = []
    hard_stop = settings.get("hard_stop", "18:00")
    hours, evenings = read_worklog(today, hard_stop, int(rules["evening_grace_min"]), gaps=gaps)
    wellness = read_wellness(today, days=rules["baseline_days"] + rules["baseline_gap_days"] + 7, gaps=gaps)
    plan = read_plan(gaps=gaps)
    personal = read_json(os.path.join(state_dir, "personal.json"), {})
    events = upcoming_races(plan, today) + travel_events(personal, today)
    # dedupe events on the same day (race wins)
    seen, uniq = set(), []
    for e in sorted(events, key=lambda x: (x["date"], x["kind"] != "race")):
        if e["date"] not in seen:
            seen.add(e["date"])
            uniq.append(e)
    return Inputs(
        today=today, work_hours=hours, evening_days=evenings, wellness=wellness,
        runs_planned=planned_runs(plan, today - timedelta(days=13), today),
        runs_done=read_runs_done(today, gaps=gaps), illness_open=illness_open(),
        felt=read_felt(state_dir, today), events=uniq, hard_stop=hard_stop, gaps=gaps)
