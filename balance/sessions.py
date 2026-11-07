"""Session-time sidecar: when a planned run was moved on the dashboard, its new start/end.
`<state_dir>/session_times.json`, keyed "YYYY-MM-DD|<session>", written on the host by
the sync (queue kind `session_time`), read by the day model and the coach brief. The coach's
plan.csv is never touched: this file only says *when*, never *what*."""
import json
import os
from datetime import datetime

FILE = "session_times.json"


def path(state_dir: str) -> str:
    return os.path.join(state_dir, FILE)


def key(date: str, session: str) -> str:
    return f"{date}|{session}"


def read(state_dir: str) -> dict[str, dict]:
    try:
        with open(path(state_dir)) as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def write(state_dir: str, k: str, start: str, end: str) -> dict:
    """Atomic: write a temp file beside the target and rename it over."""
    times = read(state_dir)
    row = {"start": start, "end": end, "set_at": datetime.now().strftime("%Y-%m-%d %H:%M:%S")}
    times[k] = row
    os.makedirs(state_dir, exist_ok=True)
    tmp = path(state_dir) + ".tmp"
    with open(tmp, "w") as f:
        json.dump(times, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path(state_dir))
    return row


def time_for(times: dict, date: str, session: str) -> dict | None:
    return times.get(key(date, session))
