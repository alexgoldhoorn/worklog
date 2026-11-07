"""Handlers for queued writes (balance/db.py `queue`), run on the host by the sync job
(balance.jobs.sync) with the credentials from the host environment. Each handler is `(payload, env) -> None` and raises
on failure; sync.drain records the error on the row."""
import json
import os
import re
import sqlite3
import urllib.parse
import urllib.request
from datetime import datetime

from .config import TZ as DEFAULT_TZ
from .inputs import ANNOTATIONS_DB, WORK_CALENDAR_DB

TODOIST = "https://api.todoist.com/api/v1"

_ANN_SCHEMA = """
CREATE TABLE IF NOT EXISTS one_off (
    id         INTEGER PRIMARY KEY,
    date       TEXT NOT NULL,
    start      TEXT NOT NULL,
    title      TEXT NOT NULL,
    owner      TEXT,
    tier       TEXT,
    note       TEXT,
    updated_at TEXT,
    UNIQUE(date, start, title)
);
"""


def _todoist_key(env: dict) -> str:
    key = env.get("TODOIST_API_KEY") or env.get("TODOIST_API_TOKEN") or ""
    if not key:
        raise RuntimeError("TODOIST_API_KEY not configured")
    return key


def _todoist(method: str, path: str, key: str, body: dict | None = None, params: dict | None = None):
    url = f"{TODOIST}{path}" + ("?" + urllib.parse.urlencode(params) if params else "")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r:
        raw = r.read()
    return json.loads(raw) if raw else {}


def _todoist_pages(path: str, key: str) -> list:
    out, cursor = [], None
    while True:
        data = _todoist("GET", path, key, params={"cursor": cursor} if cursor else None)
        if isinstance(data, list):
            return data
        out.extend(data.get("results", []))
        cursor = data.get("next_cursor")
        if not cursor:
            return out


def todoist_complete(payload: dict, env: dict) -> None:
    _todoist("POST", f"/tasks/{payload['task_id']}/close", _todoist_key(env))


def todoist_add(payload: dict, env: dict) -> None:
    key = _todoist_key(env)
    want = payload["project"]
    projects = {p["name"].lower(): p["id"] for p in _todoist_pages("/projects", key)}
    if want.lower() not in projects:
        raise ValueError(f"unknown Todoist project: {want}")
    body = {"content": payload["content"], "project_id": projects[want.lower()],
            "due_string": payload.get("due_string") or None, "priority": int(payload.get("priority") or 1),
            "labels": payload.get("labels") or []}
    if payload.get("description"):
        body["description"] = payload["description"]
    _todoist("POST", "/tasks", key, body={k: v for k, v in body.items() if v is not None})


def gcal_create(payload: dict, env: dict) -> None:
    from . import sync
    cal_id, _fallback = sync.resolve_calendar(payload["calendar"])
    tz = payload.get("tz") or DEFAULT_TZ
    body = {"summary": payload["title"], "description": payload.get("description", ""),
            "start": {"dateTime": f"{payload['date']}T{payload['start']}:00", "timeZone": tz},
            "end": {"dateTime": f"{payload['date']}T{payload['end']}:00", "timeZone": tz}}
    sync._gapi("POST", f"/calendars/{urllib.parse.quote(cal_id, safe='')}/events", body=body)


def annotate_handler(payload: dict, env: dict) -> None:
    """UPSERT into the one_off overlay (the table holds duty owners and notes set from the Day page;
    a host-side calendar overlay may read the same file)."""
    path = env.get("ANNOTATIONS_DB") or ANNOTATIONS_DB
    conn = sqlite3.connect(path)
    try:
        conn.executescript(_ANN_SCHEMA)
        row = conn.execute("SELECT owner, tier, note FROM one_off WHERE date=? AND start=? AND title=?",
                           (payload["date"], payload["start"], payload["title"])).fetchone()
        owner, tier, note = payload.get("owner"), payload.get("tier"), payload.get("note")
        if row:
            owner = owner if owner is not None else row[0]
            tier = tier if tier is not None else row[1]
            note = note if note is not None else row[2]
        tier = tier or None                                        # "" clears a tier (a corrected "whose?" tap)
        conn.execute(
            "INSERT INTO one_off (date,start,title,owner,tier,note,updated_at) VALUES (?,?,?,?,?,?,?)"
            " ON CONFLICT(date,start,title) DO UPDATE SET owner=excluded.owner, tier=excluded.tier,"
            " note=excluded.note, updated_at=excluded.updated_at",
            (payload["date"], payload["start"], payload["title"], owner, tier, note,
             datetime.now().strftime("%Y-%m-%d %H:%M:%S")))
        conn.commit()
    finally:
        conn.close()


def session_time(payload: dict, env: dict) -> None:
    from . import sessions
    from .config import STATE_DIR
    state_dir = env.get("BALANCE_STATE_DIR") or STATE_DIR
    sessions.write(state_dir, sessions.key(payload["date"], payload["session"]), payload["start"], payload["end"])


def gcal_update(payload: dict, env: dict) -> None:
    """Edit an existing Google event in place, found by its iCalUID. Never creates one.
    The ICS feed expands recurring series, so an occurrence carries the master's UID: for a
    recurring master the instance on `orig_date`/`orig_start` is patched, never the series."""
    from . import sync
    cal_id, _fallback = sync.resolve_calendar(payload["calendar"])
    ev = sync.find_event_by_uid(cal_id, payload["uid"])
    if ev is None:
        raise LookupError(f"event no longer exists: {payload['uid']}")
    cal = urllib.parse.quote(cal_id, safe="")
    target_id = ev["id"]
    if ev.get("recurrence") or ev.get("recurringEventId"):
        od, os_ = payload.get("orig_date"), payload.get("orig_start")
        if not od:
            raise ValueError("recurring event: the original occurrence is unknown, move it in Google Calendar")
        from datetime import date as _d, timedelta as _td
        lo, hi = _d.fromisoformat(od), _d.fromisoformat(od) + _td(days=1)
        inst = sync._gapi("GET", f"/calendars/{cal}/events/{urllib.parse.quote(ev['id'], safe='')}/instances",
                          {"timeMin": f"{lo.isoformat()}T00:00:00+01:00", "timeMax": f"{hi.isoformat()}T00:00:00+01:00",
                           "showDeleted": "false"}).get("items", [])
        live = [i for i in inst if i.get("status") != "cancelled"]
        if os_:
            same = [i for i in live if (i.get("start", {}).get("dateTime") or "")[11:16] == os_]
            live = same or live
        if len(live) != 1:
            raise ValueError(f"recurring event: {len(live)} instances on {od}, move it in Google Calendar")
        target_id = live[0]["id"]
    tz = payload.get("tz") or DEFAULT_TZ
    body = {"start": {"dateTime": f"{payload['date']}T{payload['start']}:00", "timeZone": tz},
            "end": {"dateTime": f"{payload['date']}T{payload['end']}:00", "timeZone": tz}}
    sync._gapi("PATCH", f"/calendars/{cal}/events/{urllib.parse.quote(target_id, safe='')}", body=body)


_EMAIL = re.compile(r"\S+@\S+\.\S+")


def mirror_add(payload: dict, env: dict) -> None:
    """One meeting into the work-calendar mirror (an UPSERT into the `events` table described in docs/configuration.md),
    source 'dashboard'. Refuses email addresses, as every mirror write does."""
    title = (payload.get("title") or "").strip()
    note = (payload.get("note") or "").strip()
    if not title:
        raise ValueError("title required")
    if _EMAIL.search(title) or _EMAIL.search(note):
        raise ValueError("email addresses are never stored in the work calendar")
    path = env.get("WORK_CALENDAR_DB") or WORK_CALENDAR_DB
    if not os.path.exists(path):
        raise FileNotFoundError(f"{path} missing")
    now = datetime.now().isoformat(timespec="seconds")
    conn = sqlite3.connect(path)
    try:
        row = conn.execute("SELECT id, status, note FROM events WHERE date=? AND start=? AND title=?",
                           (payload["date"], payload["start"], title)).fetchone()
        if row:
            # a known row keeps its source: pasting a week the PDF already covers must not re-tag it "you"
            conn.execute("UPDATE events SET end=?, status=?, note=?, updated_at=? WHERE id=?",
                         (payload.get("end"), payload.get("status") or row[1] or "confirmed", note or row[2] or "", now, row[0]))
        else:
            conn.execute("INSERT INTO events (date,start,end,title,organizer,status,note,source,updated_at)"
                         " VALUES (?,?,?,?,?,?,?,?,?)",
                         (payload["date"], payload["start"], payload.get("end"), title, "",
                          payload.get("status") or "confirmed", note, "dashboard", now))
        conn.execute("INSERT OR REPLACE INTO meta (key,value) VALUES ('last_import',?)", (now,))
        conn.commit()
    finally:
        conn.close()


def mirror_annotate(payload: dict, env: dict) -> None:
    """Cancel / un-cancel / note one mirror row, found by (date, start, title). Missing row →
    LookupError (visible on the queue); an email address in the note → ValueError."""
    status, note = payload.get("status"), payload.get("note")
    if status not in (None, "confirmed", "cancelled"):
        raise ValueError("status must be confirmed or cancelled")
    if note is not None and _EMAIL.search(note):
        raise ValueError("email addresses are never stored in the work calendar")
    if status is None and note is None:
        raise ValueError("nothing to change")
    path = env.get("WORK_CALENDAR_DB") or WORK_CALENDAR_DB
    if not os.path.exists(path):
        raise FileNotFoundError(f"{path} missing")
    conn = sqlite3.connect(path)
    try:
        row = conn.execute("SELECT id FROM events WHERE date=? AND start=? AND title=?",
                           (payload["date"], payload["start"], (payload.get("title") or "").strip())).fetchone()
        if not row:
            raise LookupError(f"no meeting {payload['date']} {payload['start']} {payload.get('title')!r} in the mirror")
        sets, args = [], []
        if status is not None:
            sets.append("status=?"); args.append(status)
        if note is not None:
            sets.append("note=?"); args.append(note.strip())
        sets.append("updated_at=?"); args.append(datetime.now().isoformat(timespec="seconds"))
        args.append(row[0])
        conn.execute(f"UPDATE events SET {', '.join(sets)} WHERE id=?", args)
        conn.commit()
    finally:
        conn.close()


def mirror_bulk_add(payload: dict, env: dict) -> None:
    """A pasted batch into the mirror: checked first (any email anywhere → nothing written), then
    one UPSERT per row through mirror_add. The imports table is never touched: a pasted week does
    not make the week 'known'."""
    events = payload.get("events") or []
    for ev in events:
        for field in ("title", "note"):
            if _EMAIL.search(str(ev.get(field) or "")):
                raise ValueError("email addresses are never stored in the work calendar")
        if not (ev.get("date") and ev.get("start") and (ev.get("title") or "").strip()):
            raise ValueError("every row needs date, start and title")
    for ev in events:
        mirror_add(ev, env)


HANDLERS = {
    "todoist_complete": todoist_complete,
    "todoist_add": todoist_add,
    "gcal_create": gcal_create,
    "annotate": annotate_handler,
    "session_time": session_time,
    "gcal_update": gcal_update,
    "mirror_add": mirror_add,
    "mirror_annotate": mirror_annotate,
    "mirror_bulk_add": mirror_bulk_add,
}
