"""The Day model: one JSON-ready dict for /api/day and the Day page, built from the
snapshots, the blocks store, the care duties, the plan and the worklog timer."""
from dataclasses import replace
from datetime import datetime, timedelta

from balance import sessions

from . import duties as _duties, rules as _rules, sources

PENDING_LAYERS = {"gcal_create": "personal", "gcal_update": "personal", "mirror_add": "work", "session_time": "protected"}

GREEN = "green"


def _hm(s: str) -> int:
    h, m = s.split(":")
    return int(h) * 60 + int(m)


def _fmt(minutes: int) -> str:
    minutes = max(0, min(24 * 60 - 1, minutes))
    return f"{minutes // 60:02d}:{minutes % 60:02d}"


def _overlap(a_start, a_end, b_start, b_end) -> bool:
    return _hm(a_start) < _hm(b_end) and _hm(b_start) < _hm(a_end)


def lane_of(calendar: str, household: dict) -> str:
    """personal | family | child: which lane a calendar's events belong to."""
    cals = household["calendars"]
    if calendar == cals["family"]:
        return "family"
    if calendar == cals["child"]:
        return "child"
    return "personal"


def classify_family(title: str, calendar: str, annotations: dict, patterns: dict, household: dict | None = None,
                    stored: str | None = None, rules_db: list[dict] | None = None, date: str | None = None,
                    start: str | None = None) -> str:
    """mine | family | partner | child | unclassified, for one personal event (partner = the
    partner's own, child = the child's; the values are the spec's names, the people come from the
    household). Precedence: overlay context annotation for this occurrence → the stored
    per-occurrence class → an "always for this title" rule → rules.json patterns → unclassified."""
    cals = (household or _rules.household({}))["calendars"]
    if calendar != cals["family"]:
        return "mine"
    if stored in ("mine", "family", "partner", "child"):          # the newest tap on the page wins
        return stored
    for a in annotations.get("one_off", []):
        if a.get("title") == title and a.get("tier") == "context" and (date is None or a.get("date") == date) \
                and (start is None or not a.get("start") or a.get("start") == start):
            return "partner"
    low = title.lower()
    for r in rules_db or []:
        if r.get("pattern", "").lower() in low and r.get("cls") in ("mine", "family", "partner", "child"):
            return r["cls"]
    for cls in ("partner", "child", "family"):
        if any(p.lower() in low for p in patterns.get(cls, [])):
            return cls
    return "unclassified"


def _timeline(ctx, src) -> list[dict]:
    out = []
    hh = _rules.household(ctx.rules)
    for e in src["mirror"].get("events", []):
        if e.get("date") != ctx.date.isoformat():
            continue
        out.append({"start": e["start"], "end": e.get("end") or e["start"], "title": e["title"], "layer": "work",
                    "source": e.get("source") or "pdf", "cancelled": e.get("status") == "cancelled",
                    "note": e.get("note") or ""})
    mirrored_ids = {b["gcal_event_id"] for b in src["blocks"] if b.get("gcal_event_id")}
    for e in src["personal"]:
        if e.get("all_day") or not e.get("start"):
            continue
        # the Google mirror of a block comes back through the calendar feeds: show the block only
        uid = str(e.get("uid") or "")
        if uid.split("@")[0] in mirrored_ids or str(e.get("title", "")).startswith("🛡"):
            continue
        creator = (e.get("creator") or "").strip().lower()
        out.append({"start": e["start"], "end": e.get("end") or e["start"], "title": e["title"], "layer": "personal",
                    "source": e.get("calendar", ""), "uid": e.get("uid", ""),
                    "creator_name": ((hh.get("people") or {}).get(creator) or creator.split("@")[0]) if creator else None,
                    "lane": lane_of(e.get("calendar", ""), hh),
                    "classification": classify_family(e["title"], e.get("calendar", ""), src["annotations"],
                                                      ctx.rules.get("family_patterns", {}), hh,
                                                      stored=src.get("event_class", {}).get((e["start"], e["title"])),
                                                      rules_db=src.get("family_rules"), date=e.get("date"), start=e["start"])})
    for b in src["blocks"]:
        out.append({"start": b["start"], "end": b["end"], "title": b["title"], "layer": "protected",
                    "source": b.get("source", ""), "state": b["state"], "kind": b["kind"], "id": b["id"]})
    snap_at = {"personal": (src.get("personal_fetched") or "").replace("T", " "),
               "work": (src["mirror"].get("taken") or "").replace("T", " "), "protected": ""}
    today = ctx.date.isoformat()
    live = lambda q, layer: q["status"] == "pending" or (q["status"] == "done" and (q.get("applied_at") or "") > snap_at.get(layer, ""))
    for q in src["queue"]:
        p = q.get("payload") or {}
        if q["kind"] == "mirror_bulk_add" and live(q, "work"):
            for ev in p.get("events", []):
                if ev.get("date") == today and ev.get("start") and not any(
                        e["layer"] == "work" and e["start"] == ev["start"] and e["title"] == ev.get("title") for e in out):
                    out.append({"start": ev["start"], "end": ev.get("end") or ev["start"], "title": ev.get("title") or "(no title)",
                                "layer": "work", "source": "dashboard", "cancelled": False, "note": "", "pending": True})
            continue
        if q["kind"] == "mirror_annotate" and live(q, "work") and p.get("date") == today:
            for e in out:
                if e["layer"] == "work" and e["start"] == p.get("start") and e["title"] == p.get("title"):
                    if p.get("status"):
                        e["cancelled"] = p["status"] == "cancelled"
                    if p.get("note") is not None:
                        e["note"] = p["note"]
                    e["pending"] = True
            continue
        layer = PENDING_LAYERS.get(q["kind"])
        if not layer or p.get("date") != today or not p.get("start"):
            continue
        # a drained row stays "pending" on the timeline until the snapshot it lands in was taken after it
        if q["status"] == "done" and not ((q.get("applied_at") or "") > snap_at.get(layer, "")):
            continue
        if q["status"] not in ("pending", "done"):
            continue
        if q["kind"] == "session_time":
            continue                                           # shown through the sidecar below
        if q["kind"] == "mirror_annotate":
            continue                                           # applied to the matching row below
        out.append({"start": p["start"], "end": p.get("end") or p["start"], "title": p.get("title") or p.get("session") or q["line"],
                    "layer": layer, "source": p.get("calendar", "queue"), "pending": True,
                    "lane": lane_of(p.get("calendar", ""), hh) if layer == "personal" else None,
                    "classification": "mine" if layer == "personal" else None, "kind": "run" if q["kind"] == "session_time" else None})
    row = next((r for r in src["plan"] if r["date"] == ctx.date), None)
    moved = sessions.time_for(src.get("session_times") or {}, ctx.date.isoformat(), row["session"]) if row else None
    if moved and not any(b["kind"] == "run" and b["start"] == moved["start"] for b in src["blocks"]):
        out.append({"start": moved["start"], "end": moved.get("end") or moved["start"], "title": row["session"], "layer": "protected",
                    "source": "sidecar", "state": "moved", "kind": "run", "id": None})
    for d in _duties.for_day(ctx.date, ctx.rules, ctx.holidays, src["annotations"], src.get("school_days")):
        out.append({"start": d["start"], "end": d["end"], "title": d["title"], "layer": "duty", "source": "rules",
                    "owner": d["owner"], "owner_source": d["owner_source"], "at": d["at"], "school_status": d["school_status"]})
    return sorted(out, key=lambda e: (_hm(e["start"]), _hm(e["end"])))


def _busy_work(timeline) -> list[dict]:
    return [e for e in timeline if e["layer"] == "work" and not e.get("cancelled")]


def _unknown(ctx, src) -> bool:
    """True when the mirror cannot vouch for this date: outside every real import range."""
    cov = src["mirror"].get("coverage", {})
    d = ctx.date.isoformat()
    ranges = cov.get("ranges")
    if ranges:
        return not any(a <= d <= b for a, b in ranges)
    last_end = cov.get("last_import_end")
    return last_end is None or d > last_end


def _first_things(ctx, src, timeline, tasks, unknown: bool) -> list[dict]:
    me = _rules.household(ctx.rules)["me"]
    out = []
    work = _busy_work(timeline)
    for d in timeline:
        if d["layer"] != "duty" or d["title"] != "School drop-off":
            continue
        if d["owner"] not in (me, None):
            continue
        clash = [w for w in work if _overlap(d["start"], d["end"], w["start"], w["end"])]
        fits = None if (unknown and not clash) else not clash
        line = ("work calendar unknown for this day" if fits is None
                else f"fits: nothing before {work[0]['start']}" if fits and work else "fits" if fits
                else "clashes with " + ", ".join(f"{w['title']} {w['start']}" for w in clash))
        if unknown and clash:
            line += " · rest of the work day unknown"
        if d.get("school_status") == "unknown":
            line += " · school calendar unknown"
        if d["owner"] is None:
            line = "who? " + line
        out.append({"kind": "duty", "title": d["title"], "at": d["at"], "owner": d["owner"],
                    "owner_source": d["owner_source"], "fits": fits, "fit_line": line})
    if work:
        first = work[0]
        prep = next((p for p in src["prep"] if p["start"] == first["start"] and p["title"] == first["title"]), None)
        out.append({"kind": "meeting", "title": first["title"], "start": first["start"], "end": first["end"],
                    "source": first["source"],
                    "prep": None if prep is None else {"minutes": prep["minutes"], "text": prep["text"],
                                                       "start_by": _fmt(_hm(first["start"]) - prep["minutes"])}})
    urgent = [t for t in tasks if t.get("priority") == 4 or "doubt" in (t.get("labels") or [])][:4]
    out.append({"kind": "urgent", "tasks": urgent})
    return out


def _tasks(src) -> list[dict]:
    """A pending close always counts; a done one only until the Todoist snapshot caught up
    (a recurring task keeps its id and comes back open on its next occurrence)."""
    fetched = (src["goals"].get("fetched") or "").replace("T", " ")
    done_ids = {q["payload"].get("task_id") for q in src["queue"]
                if q["kind"] == "todoist_complete"
                and (q["status"] == "pending" or (q["status"] == "done" and (q.get("applied_at") or "") > fetched))}
    pending_ids = {q["payload"].get("task_id") for q in src["queue"]
                   if q["kind"] == "todoist_complete" and q["status"] == "pending"}
    out = []
    for t in src["goals"].get("top3", []):
        out.append({**t, "done": t["id"] in done_ids, "pending": t["id"] in pending_ids})
    return out


def _training(ctx, src) -> dict | None:
    row = next((r for r in src["plan"] if r["date"] == ctx.date), None)
    if row is None or row["type"] in ("", "rest"):
        return None
    run = next((b for b in src["blocks"] if b["kind"] == "run"), None)
    moved = sessions.time_for(src.get("session_times") or {}, ctx.date.isoformat(), row["session"])
    if moved:
        time, end, source = moved["start"], moved.get("end"), "moved"
    elif run:
        time, end, source = run["start"], run["end"], "block"
    else:
        time, end, source = ctx.balance_settings.get("run_slot", "07:30"), None, "slot"
    return {"session": row["session"], "type": row["type"], "distance_km": row["distance_km"],
            "time": time, "end": end, "time_source": source,
            "block_state": run["state"] if run else None,
            "easy_week": src["gate"].get("colour", GREEN) != GREEN}


def _work(ctx, src, timeline, tasks, unknown: bool, is_today: bool) -> dict:
    s = ctx.balance_settings
    hard_stop = s.get("hard_stop", "18:00")
    today = ctx.now.date()
    # another date never borrows today's clock: a future day counts from 00:00, a past one is over
    now_m = (ctx.now.hour * 60 + ctx.now.minute) if is_today else (0 if ctx.date > today else _hm(hard_stop))
    ahead = [w for w in _busy_work(timeline) if _hm(w["end"]) > now_m]
    meeting_min = sum(max(0, min(_hm(w["end"]), _hm(hard_stop)) - max(_hm(w["start"]), now_m)) for w in ahead)
    left = max(0, _hm(hard_stop) - now_m - meeting_min) / 60
    ms = []
    for m in src["goals"].get("milestones", []):
        try:
            days_left = (datetime.strptime(m["due"], "%Y-%m-%d").date() - ctx.date).days
        except (KeyError, ValueError, TypeError):
            days_left = None
        ms.append({**m, "days_left": days_left})
    status = ctx.worklog_status if is_today else None
    return {"status": status,
            "week_h": round(float(ctx.worklog_status.get("week", {}).get("worked_h_live", 0.0)), 2),
            "today_h": round(float(ctx.worklog_status.get("today", {}).get("work_h_live", 0.0)), 2) if is_today else None,
            "band": [float(s.get("week_hours_min", 30)), float(s.get("week_hours_max", 35))],
            "hard_stop": hard_stop, "left_before_stop_h": None if unknown else round(left, 2),
            "top3": tasks, "milestones": ms,
            "meetings_left": None if unknown else len([w for w in ahead if _hm(w["start"]) >= now_m])}


def build_day(ctx: sources.Context) -> dict:
    src = sources.load(ctx)
    timeline = _timeline(ctx, src)
    tasks = _tasks(src)
    gate = src["gate"]
    colour = gate.get("colour", "none") if gate else "none"
    cov = src["mirror"].get("coverage", {})
    last_end = cov.get("last_import_end")
    last_at = cov.get("last_import_at")
    stale = None
    if last_at:
        try:
            # age of the export as of now: the Work calendar banner reads the week's Monday payload,
            # and measuring from that day gave "-1 days ago" after a Tuesday import
            stale = max(0, (ctx.now.date() - datetime.strptime(last_at[:10], "%Y-%m-%d").date()).days)
        except ValueError:
            stale = None
    unknown = _unknown(ctx, src)
    is_today = ctx.date == ctx.now.date()
    work = _work(ctx, src, timeline, tasks, unknown, is_today)
    return {
        "date": ctx.date.isoformat(), "now": ctx.now.strftime("%H:%M"), "is_today": is_today,
        "household": {k: _rules.household(ctx.rules)[k] for k in ("me", "partner", "child", "calendars")},
        "capacity": {"colour": colour, "line": gate.get("line", ""), "show": colour not in (GREEN, "none"),
                     "numbers": gate.get("numbers", {}), "protect": gate.get("protect", ""),
                     "pre_event": gate.get("pre_event")},
        "work_day": ctx.date.weekday() < 5 and ctx.date.isoformat() not in (ctx.client_holidays or {}),
        "plan_types": {r["date"].isoformat(): (r.get("type") or "rest") for r in src["plan"]},
        "timeline": timeline,
        "mirror": {"unknown": unknown, "last_import_end": last_end, "stale_days": stale},
        "first_things": _first_things(ctx, src, timeline, tasks, unknown),
        "training": _training(ctx, src),
        "work": work,
        "counts": {"done": sum(1 for t in tasks if t["done"]), "todo": sum(1 for t in tasks if not t["done"]),
                   "meetings_left": work["meetings_left"],
                   "unclassified": sum(1 for e in timeline if e["layer"] == "personal" and e.get("classification") == "unclassified")},
        "sync": src["sync"],
        "queue": [q for q in src["queue"] if q["status"] in ("pending", "failed")],
    }


def build_days(ctx: sources.Context, dates: list[str]) -> dict[str, dict]:
    """One day model per date (the same rules as build_day: another date never borrows today's clock)."""
    out = {}
    for d in dates:
        out[d] = build_day(replace(ctx, date=datetime.strptime(d, "%Y-%m-%d").date()))
    return out
