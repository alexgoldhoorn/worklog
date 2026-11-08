"""Host-side sync: Todoist goals and personal-calendar snapshots for the page, and
the Google Calendar mirror of approved blocks.

The container never holds credentials: it reads the JSON this writes. Google is a
mirror of the store, never the other way round; when the OAuth login has expired
(Testing-mode consent, ~7 days) the push waits and sync.json says so.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta

from . import db as bdb, inputs, queue_handlers, snapshots
from .config import HOST_LIB, TZ

GCAL_API = "https://www.googleapis.com/calendar/v3"
PREFIX = "🛡 "   # used on the primary calendar only, until an Agent calendar exists


def _write_json(path: str, data) -> None:
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=1, default=str)
    os.replace(tmp, path)


class HostLibMissing(RuntimeError):
    pass


def _host_import(module: str, subdir: str = ""):
    """Import `module` from the optional host library (WORKLOG_HOST_LIB)."""
    if not HOST_LIB:
        raise HostLibMissing(f"WORKLOG_HOST_LIB is not set (needed for {module})")
    path = os.path.join(HOST_LIB, subdir) if subdir else HOST_LIB
    if path not in sys.path:
        sys.path.insert(0, path)
    import importlib
    return importlib.import_module(module)


def _env() -> dict:
    """Credentials: the host library's `common.load_env()` when there is one, else os.environ."""
    try:
        return _host_import("common").load_env()
    except (HostLibMissing, ImportError):
        return dict(os.environ)


# ---- Todoist goals ------------------------------------------------------------

def _todoist(path: str, key: str, params: dict | None = None) -> list:
    """GET with v1 pagination (results + next_cursor)."""
    out, cursor = [], None
    while True:
        q = dict(params or {})
        if cursor:
            q["cursor"] = cursor
        url = f"https://api.todoist.com/api/v1{path}" + ("?" + urllib.parse.urlencode(q) if q else "")
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {key}"})
        with urllib.request.urlopen(req, timeout=20) as r:
            data = json.loads(r.read() or b"{}")
        if isinstance(data, list):
            return data
        out.extend(data.get("results", []))
        cursor = data.get("next_cursor")
        if not cursor:
            return out


def goals_snapshot(project: str, milestone_label: str, today: date, key: str) -> dict:
    tasks = _todoist("/tasks/filter", key, {"query": f"##{project}"})
    ms, top, open_count = [], [], 0
    for t in tasks:
        open_count += 1
        due = (t.get("due") or {}).get("date")
        labels = [str(x).lower() for x in t.get("labels") or []]
        row = {"id": t.get("id"), "content": t.get("content", ""), "due": due,
               "priority": int(t.get("priority") or 1), "labels": labels,
               "project_id": t.get("project_id")}
        if milestone_label.lower() in labels and due:
            ms.append(row)
        if due and due[:10] <= today.isoformat():
            top.append(row)
    ms.sort(key=lambda r: r["due"])
    top.sort(key=lambda r: (-r["priority"], r["due"] or "9999"))
    return {"fetched": datetime.now().isoformat(timespec="seconds"), "project": project,
            "open": open_count, "milestones": ms, "top3": top[:3], "due_today_or_overdue": len(top)}


# ---- personal calendar ---------------------------------------------------------

def personal_snapshot(ics_urls: str, lo: date, hi: date, fetch=None) -> dict:
    """Rows carry `uid` (the ICS UID; Google's is `<event id>@google.com`) so an event can be
    edited in place later and a mirrored block can be matched to its feed copy."""
    from zoneinfo import ZoneInfo
    if fetch is None:
        fetch = _host_import("personal.calendar_ics").fetch_ics_events
    tz = ZoneInfo(TZ)
    ws = datetime.combine(lo, datetime.min.time(), tz)
    we = datetime.combine(hi + timedelta(days=1), datetime.min.time(), tz)
    events, warnings = fetch(ics_urls, ws, we)
    rows = []
    for e in events:
        s, en = e.get("start"), e.get("end")
        if s is None:
            continue
        if e.get("all_day"):
            rows.append({"date": s.isoformat()[:10], "start": "", "end": "", "all_day": True,
                         "title": e["title"], "calendar": e.get("calendar", ""), "uid": e.get("uid", "")})
        else:
            rows.append({"date": s.strftime("%Y-%m-%d"), "start": s.strftime("%H:%M"),
                         "end": en.strftime("%H:%M") if en else "", "all_day": False,
                         "title": e["title"], "calendar": e.get("calendar", ""), "uid": e.get("uid", "")})
    rows.sort(key=lambda r: (r["date"], r["start"]))
    return {"fetched": datetime.now().isoformat(timespec="seconds"), "from": lo.isoformat(),
            "to": hi.isoformat(), "events": rows, "warnings": warnings}


def personal_snapshot_api(calendar_names: list[str], lo: date, hi: date, api=None) -> dict:
    """Personal events through the Calendar API: the same rows as the ICS snapshot plus
    `event_id`, `creator`, `organizer`, `updated` and `recurring`. Calendars whose name is not in
    the account's list are reported in `missing` (an ICS label that does not match Google)."""
    from zoneinfo import ZoneInfo
    api = api or _gapi
    tz = ZoneInfo(TZ)
    ws = datetime.combine(lo, datetime.min.time(), tz).isoformat()
    we = datetime.combine(hi + timedelta(days=1), datetime.min.time(), tz).isoformat()

    def _local(dt: str) -> datetime:
        # Google answers in the calendar's own zone (the Family calendar is UTC), so a bare
        # dt[11:16] showed an 08:45 event as 07:45. Convert before cutting date and time.
        return datetime.fromisoformat(dt.replace("Z", "+00:00")).astimezone(tz)

    items = api("GET", "/users/me/calendarList", {"fields": "items(id,summary,primary)"}).get("items", [])
    by_name = {c.get("summary", ""): c["id"] for c in items if c.get("id")}
    rows, missing = [], []
    for name in calendar_names:
        cal_id = by_name.get(name)
        if not cal_id:
            missing.append(name)
            continue
        page = api("GET", f"/calendars/{urllib.parse.quote(cal_id, safe='')}/events",
                   {"singleEvents": "true", "orderBy": "startTime", "maxResults": 2500, "showDeleted": "false",
                    "timeMin": ws, "timeMax": we, "timeZone": TZ,
                    "fields": "items(id,iCalUID,summary,status,updated,creator,organizer,start,end,recurringEventId)"})
        for ev in page.get("items", []):
            if ev.get("status") == "cancelled":
                continue
            st, en = ev.get("start", {}), ev.get("end", {})
            if st.get("date"):
                row = {"date": st["date"], "start": "", "end": "", "all_day": True}
            else:
                sdt, edt = st.get("dateTime", ""), en.get("dateTime", "")
                if not sdt:
                    continue
                ls = _local(sdt)
                row = {"date": ls.strftime("%Y-%m-%d"), "start": ls.strftime("%H:%M"),
                       "end": _local(edt).strftime("%H:%M") if edt else "", "all_day": False}
            row.update({"title": ev.get("summary") or "(no title)", "calendar": name, "uid": ev.get("iCalUID", ""),
                        "event_id": ev.get("id", ""), "creator": (ev.get("creator") or {}).get("email", ""),
                        "organizer": (ev.get("organizer") or {}).get("email", ""), "updated": ev.get("updated", ""),
                        "recurring": bool(ev.get("recurringEventId"))})
            rows.append(row)
    rows.sort(key=lambda r: (r["date"], r["start"]))
    return {"fetched": datetime.now().isoformat(timespec="seconds"), "from": lo.isoformat(), "to": hi.isoformat(),
            "source": "api", "missing": missing, "events": rows, "warnings": []}


def _ics_labels(ics_urls: str) -> list[str]:
    out = []
    for entry in (ics_urls or "").split(","):
        if "|" in entry:
            out.append(entry.split("|", 1)[0].strip())
    return out


# ---- Google mirror --------------------------------------------------------------

class GoogleUnavailable(Exception):
    pass


def _oauth():
    try:
        return _host_import("oauth", "gcal")
    except (HostLibMissing, ImportError) as e:
        raise GoogleUnavailable(str(e)) from None


def _gapi(method: str, path: str, params: dict | None = None, body: dict | None = None) -> dict:
    oauth = _oauth()
    try:
        token = oauth.access_token()
    except Exception as e:  # noqa: BLE001 - AuthError or a network failure
        raise GoogleUnavailable(str(e)) from None
    url = GCAL_API + path + ("?" + urllib.parse.urlencode(params) if params else "")
    req = urllib.request.Request(url, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token,
                                          "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise GoogleUnavailable("Google Calendar login expired") from None
        if e.code in (404, 410) and method == "DELETE":
            return {}
        raise RuntimeError(f"Calendar API HTTP {e.code}: {e.read().decode(errors='replace')[:200]}") from None


def find_event_by_uid(calendar_id: str, uid: str, api=None) -> dict | None:
    """The Google event whose iCalUID is `uid` on that calendar (the ICS feed's UID), or None."""
    api = api or _gapi
    items = api("GET", f"/calendars/{urllib.parse.quote(calendar_id, safe='')}/events",
                {"iCalUID": uid, "maxResults": 2, "showDeleted": "false"}).get("items", [])
    live = [i for i in items if i.get("status") != "cancelled"]
    return live[0] if live else None


def resolve_calendar(name: str) -> tuple[str, bool]:
    """(calendar id, is_fallback). Falls back to primary when `name` does not exist."""
    items = _gapi("GET", "/users/me/calendarList", {"fields": "items(id,summary,accessRole,primary)"}).get("items", [])
    for c in items:
        if c.get("summary", "").strip().lower() == name.strip().lower() and \
           c.get("accessRole") in ("owner", "writer"):
            return c["id"], False
    return "primary", True


def push_blocks(conn, calendar_name: str, api=_gapi, resolver=resolve_calendar) -> dict:
    """Create Google events for approved blocks, delete them for rejected ones."""
    pending = bdb.pending_sync(conn)
    stats = {"created": 0, "deleted": 0, "errors": [], "fallback_primary": False}
    if not pending:
        return stats
    try:
        cal_id, fallback = resolver(calendar_name)
    except GoogleUnavailable:
        raise
    except Exception as e:  # noqa: BLE001 - a 5xx or a network blip: report, keep the blocks pending
        stats["errors"].append(f"calendar lookup: {e}")
        return stats
    stats["fallback_primary"] = fallback
    for b in pending:
        try:
            if b["state"] == "approved":
                title = (PREFIX if fallback else "") + b["title"]
                body = {"summary": title, "description": b["note"] or "Agent block (balance page)",
                        "start": {"dateTime": f"{b['date']}T{b['start']}:00", "timeZone": TZ},
                        "end": {"dateTime": f"{b['date']}T{b['end']}:00", "timeZone": TZ},
                        "reminders": {"useDefault": False, "overrides": [{"method": "popup", "minutes": 10}]}}
                ev = api("POST", f"/calendars/{urllib.parse.quote(cal_id)}/events", {"sendUpdates": "none"}, body)
                bdb.update_block(conn, b["id"], gcal_event_id=ev.get("id", ""), gcal_calendar=cal_id,
                                 synced_at=datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
                stats["created"] += 1
            else:  # rejected after a push: remove only what this sync created
                api("DELETE", f"/calendars/{urllib.parse.quote(b['gcal_calendar'] or cal_id)}/events/"
                    f"{urllib.parse.quote(b['gcal_event_id'])}", {"sendUpdates": "none"})
                bdb.update_block(conn, b["id"], gcal_event_id="", synced_at=datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
                stats["deleted"] += 1
        except GoogleUnavailable:
            raise
        except Exception as e:  # noqa: BLE001 - one bad block must not stop the rest
            stats["errors"].append(f"block {b['id']}: {e}")
    return stats


# ---- entry point ----------------------------------------------------------------

def _school_calendar():
    """(status_fn, rules) from the host library's personal.holidays (`school_status`,
    `load_rules_checked`); (None, None) when unavailable."""
    try:
        ph = _host_import("personal.holidays")
        rules, _warn = ph.load_rules_checked()
        return ph.school_status, rules
    except Exception:  # noqa: BLE001
        return None, None


def drain(conn, env: dict, handlers: dict | None = None) -> dict:
    """Apply every pending queue row through its handler; one failure never stops the others.
    A failed row stays failed (visible, retried only by hand). Rows are claimed before they
    are applied, so overlapping runs never apply one twice."""
    from .queue_handlers import HANDLERS
    handlers = HANDLERS if handlers is None else handlers
    st = {"done": 0, "failed": 0, "errors": []}
    for row in bdb.queue_pending(conn):
        if not bdb.queue_claim(conn, row["id"]):
            continue   # another run has it (or it was dismissed since the listing)
        fn = handlers.get(row["kind"])
        try:
            if fn is None:
                raise LookupError(f"no handler: {row['kind']}")
            fn(row["payload"], env)
            bdb.queue_mark(conn, row["id"], "done", only_if_pending=True)
            st["done"] += 1
        except Exception as e:  # noqa: BLE001 - recorded on the row
            bdb.queue_mark(conn, row["id"], "failed", str(e), only_if_pending=True)
            st["failed"] += 1
            st["errors"].append(f"{row['line']}: {e}")
    return st


def run(conn, state_dir: str, today: date | None = None, env: dict | None = None,
        light: bool = False, handlers: dict | None = None) -> dict:
    """light=True (the 2-minute tick): drain the queue and push pending blocks only;
    the snapshots (Todoist, calendars, mirror, overlay) are taken on a full run."""
    today = today or date.today()
    env = env if env is not None else _env()
    settings = bdb.get_settings(conn)
    status: dict = {"ran": datetime.now().isoformat(timespec="seconds"), "google": "", "errors": [], "light": light}

    status["queue"] = drain(conn, env, handlers)
    status["errors"].extend("queue: " + e for e in status["queue"]["errors"])
    if light:
        if bdb.pending_sync(conn) or status["queue"]["done"]:
            try:
                st = push_blocks(conn, settings.get("gcal_calendar", "Agent"))
                status["google"] = "ok"
                status["pushed"] = {k: st[k] for k in ("created", "deleted", "fallback_primary")}
                status["errors"].extend(st["errors"])
            except Exception as e:  # noqa: BLE001
                status["google"] = f"waiting: {e}"
                status["pending"] = len(bdb.pending_sync(conn))
        prev = inputs.read_json(os.path.join(state_dir, "sync.json"), {})
        if not status["google"]:
            status["google"] = prev.get("google", "")
        status["full_ran"] = prev.get("full_ran") or prev.get("ran")
        _write_json(os.path.join(state_dir, "sync.json"), status)
        return status
    status["full_ran"] = status["ran"]

    try:
        key = env.get("TODOIST_API_KEY") or env.get("TODOIST_API_TOKEN") or ""
        if not key:
            raise RuntimeError("TODOIST_API_KEY not configured")
        _write_json(os.path.join(state_dir, "goals.json"),
                    goals_snapshot(settings["todoist_project"], settings["milestone_label"], today, key))
    except Exception as e:  # noqa: BLE001
        status["errors"].append(f"goals: {e}")

    lo, hi = today - timedelta(days=7), today + timedelta(days=60)
    labels = _ics_labels(env.get("GOOGLE_CALENDAR_ICS_URLS", ""))
    try:
        snap = personal_snapshot_api(labels, lo, hi)
        status["personal_source"] = "api"
        if snap.get("missing"):
            # a label that does not match a Google calendar name: keep its events through the ICS feed
            status["calendar_labels"] = snap["missing"]
            status["errors"].append("calendar labels not found in Google (filled from ICS): " + ", ".join(snap["missing"]))
            entries = [e for e in (env.get("GOOGLE_CALENDAR_ICS_URLS") or "").split(",") if e.split("|", 1)[0].strip() in snap["missing"]]
            if entries:
                ics = personal_snapshot(",".join(entries), lo, hi)
                snap["events"] = sorted(snap["events"] + ics.get("events", []), key=lambda r: (r["date"], r["start"]))
                snap["warnings"] = snap.get("warnings", []) + ics.get("warnings", [])
                snap["source"] = "mixed"
                status["personal_source"] = "mixed"
        _write_json(os.path.join(state_dir, "personal.json"), snap)
    except (GoogleUnavailable, Exception) as e:  # noqa: BLE001 - API read failed: the ICS feeds still work
        status["personal_source"] = "ics"
        status["personal_api_error"] = str(e)
        try:
            snap = personal_snapshot(env.get("GOOGLE_CALENDAR_ICS_URLS", ""), lo, hi)
            snap["source"] = "ics"
            _write_json(os.path.join(state_dir, "personal.json"), snap)
        except Exception as e2:  # noqa: BLE001
            status["errors"].append(f"personal calendar: {e2}")

    try:
        _write_json(os.path.join(state_dir, "mirror.json"),
                    snapshots.mirror_snapshot(env.get("WORK_CALENDAR_DB") or inputs.WORK_CALENDAR_DB,
                                              today - timedelta(days=7), today + timedelta(days=60)))
        _write_json(os.path.join(state_dir, "annotations.json"),
                    snapshots.annotations_snapshot(env.get("ANNOTATIONS_DB") or queue_handlers.ANNOTATIONS_DB))
        _write_json(os.path.join(state_dir, "school_days.json"),
                    snapshots.school_days_snapshot(today - timedelta(days=7), today + timedelta(days=60),
                                                   *_school_calendar()))
    except Exception as e:  # noqa: BLE001
        status["errors"].append(f"snapshots: {e}")

    try:
        _oauth().access_token()  # login check even with nothing to push, so the page can say
        st = push_blocks(conn, settings.get("gcal_calendar", "Agent"))
        status["google"] = "ok"
        status["pushed"] = {k: st[k] for k in ("created", "deleted", "fallback_primary")}
        status["errors"].extend(st["errors"])
    except GoogleUnavailable as e:
        status["google"] = f"waiting: {e}"
        status["pending"] = len(bdb.pending_sync(conn))
    except Exception as e:  # noqa: BLE001 - oauth.AuthError or anything else from the login check
        status["google"] = f"waiting: {e}"
        status["pending"] = len(bdb.pending_sync(conn))

    _write_json(os.path.join(state_dir, "sync.json"), status)
    return status
