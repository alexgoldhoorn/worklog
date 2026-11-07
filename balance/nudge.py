"""Hard-stop Telegram nudge: pure decision logic plus thin HTTP/Telegram defaults.

Runs from the 2-minute Balance Sync job on the host. It asks the worklog API
whether a work block is still running past the hard stop, sends at most one
message an evening (plus one more after a snooze), and handles the two buttons.
"""
from __future__ import annotations

import base64
import json
import os
import re
import sys
import urllib.request
from datetime import datetime, time, timedelta

from .config import DEFAULT_RULES, load_rules

STATE_FILE = "nudge.json"
DEFAULT_URL = "http://127.0.0.1:8503"
_TAP = re.compile(r"balance:(\d{4}-\d{2}-\d{2}):(stop|snooze)")


def _write_json(path: str, data) -> None:
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def load_state(state_dir: str) -> dict:
    try:
        with open(os.path.join(state_dir, STATE_FILE)) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(state_dir: str, state: dict) -> None:
    _write_json(os.path.join(state_dir, STATE_FILE), state)


def _hm(minutes: float) -> str:
    m = round(minutes)
    return f"{m // 60} h {m % 60:02d}"


def decide(status: dict, state: dict, now: datetime, rules: dict) -> str | None:
    """Return "nudge" or None. First nudge once the running work block is `nudge_after_min` past the
    hard stop; one more after the snooze time, then silence for the evening."""
    if status.get("state") != "working" or status.get("date") != now.date().isoformat():
        return None
    past = status.get("past_stop_min")
    if past is None or past < rules["nudge_after_min"]:
        return None
    sent = state.get("sent", 0)
    if sent == 0:
        return "nudge"
    snooze = state.get("snooze_until")
    if sent == 1 and snooze and now.strftime("%H:%M") >= snooze:
        return "nudge"
    return None


def message(status: dict, now: datetime) -> tuple[str, dict]:
    day = status["date"]
    text = (f"⏱ Still working at {now.strftime('%H:%M')} · {_hm(status['past_stop_min'])} past "
            f"your {status['hard_stop']} stop · today {_hm(status['today']['work_h_live'] * 60)}")
    markup = {"inline_keyboard": [[
        {"text": "Stop now", "callback_data": f"balance:{day}:stop"},
        {"text": "30 more min", "callback_data": f"balance:{day}:snooze"},
    ]]}
    return text, markup


def _request(env: dict, path: str, method: str = "GET") -> dict:
    base = (env.get("WORKLOG_URL") or DEFAULT_URL).rstrip("/")
    req = urllib.request.Request(base + path, method=method,
                                 data=b"{}" if method == "POST" else None)
    if method == "POST":
        req.add_header("Content-Type", "application/json")
    user, pw = env.get("WORKLOG_USER"), env.get("WORKLOG_PASSWORD")
    if user and pw:
        token = base64.b64encode(f"{user}:{pw}".encode()).decode()
        req.add_header("Authorization", f"Basic {token}")
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.loads(r.read() or b"{}")


def _fetch_status(env: dict) -> dict:
    return _request(env, "/api/status")


def _stop(env: dict) -> dict:
    return _request(env, "/api/stop", "POST")


def _send(env: dict, text: str, markup: dict) -> None:
    """Telegram through the host library's `scripts/notify.py` when there is one, else the Bot API."""
    from .config import HOST_LIB
    chat = env.get("TELEGRAM_CHAT_ID") or env["TELEGRAM_HOME_CHANNEL"]
    scripts = os.path.join(HOST_LIB, "scripts") if HOST_LIB else None
    if scripts and os.path.isfile(os.path.join(scripts, "notify.py")):
        if scripts not in sys.path:
            sys.path.insert(0, scripts)
        import notify
        notify.send_telegram(text, env["TELEGRAM_BOT_TOKEN"], chat, reply_markup=markup)
        return
    body = json.dumps({"chat_id": chat, "text": text, "reply_markup": markup}).encode()
    req = urllib.request.Request(f"https://api.telegram.org/bot{env['TELEGRAM_BOT_TOKEN']}/sendMessage",
                                 data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        r.read()


def tick(env: dict, state_dir: str, now: datetime | None = None, fetch=None, sender=None,
         rules: dict | None = None) -> dict:
    """One pass of the job: fetch the timer status, decide, send. Never raises on an
    unreachable server (no nudge is the safe outcome). `fetch` and `sender` are test hooks."""
    now = now or datetime.now()
    rules = rules or load_rules()
    today = now.date().isoformat()
    state = load_state(state_dir)
    if state.get("date") != today:
        state = {"date": today, "sent": 0, "last_sent": None, "snooze_until": None}
    try:
        status = (fetch or _fetch_status)(env)
    except Exception as e:  # noqa: BLE001 - any failure means "do not nudge"
        return {"sent": False, "reason": f"worklog unreachable: {e}"}
    if decide(status, state, now, rules) != "nudge":
        return {"sent": False, "reason": "nothing to nudge"}
    text, markup = message(status, now)
    if sender:
        sender(text, markup)
    else:
        _send(env, text, markup)
    state.update(sent=state.get("sent", 0) + 1, last_sent=now.strftime("%H:%M"), snooze_until=None)
    save_state(state_dir, state)
    return {"sent": True, "reason": "nudged"}


def handle_tap(data: str, env: dict, now: datetime | None = None, state_dir: str | None = None,
               stop=None, rules: dict | None = None, fetch=None) -> str | None:
    """Act on a button callback (`balance:<date>:stop|snooze`) and return the reply text; None
    if `data` is not ours. A tap from an earlier day does nothing, except a late stop before
    06:00 for the previous evening (the session may still be running past midnight)."""
    m = _TAP.fullmatch(data or "")
    if not m:
        return None
    now = now or datetime.now()
    day, action = m.groups()
    yesterday = (now - timedelta(days=1)).date().isoformat()
    late_stop = action == "stop" and day == yesterday and now.time() < time(6, 0)
    if day != now.date().isoformat() and not late_stop:
        return f"That nudge was for {day}; nothing changed."
    if action == "snooze":
        from .config import STATE_DIR
        d = state_dir or STATE_DIR
        mins = (rules or load_rules())["nudge_snooze_min"]
        state = load_state(d)
        if state.get("date") != day:
            state = {"date": day, "sent": 0, "last_sent": None}
        until = now + timedelta(minutes=mins)
        state["snooze_until"] = until.strftime("%H:%M") if until.date() == now.date() else "23:59"
        save_state(d, state)
        if state.get("sent", 0) >= 2:
            return "OK, no more reminders tonight."
        return f"OK, {mins} more minutes. I will ask once more."
    try:
        st = (fetch or _fetch_status)(env)
    except Exception:  # noqa: BLE001 - fall through to stop
        st = {}
    if st.get("state") == "stopped":
        t = st.get("today") or {}
        h = t.get("work_h", t.get("work_h_live", 0))
        return f"Nothing was running · today {_hm(h * 60)}"
    res = (stop or _stop)(env)
    today = res.get("today") or {}
    h = today.get("work_h", today.get("work_h_live", 0))
    return f"Stopped at {now.strftime('%H:%M')} · today {_hm(h * 60)}"
