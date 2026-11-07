"""Paths and tunables. Host scripts and the container read the same names."""
import json
import os
from dataclasses import dataclass, field

# Everything host-side lives under one root unless a variable points elsewhere.
STATE_ROOT = os.path.expanduser(os.environ.get("WORKLOG_STATE_ROOT", "~/.local/state/worklog"))
STATE_DIR = os.path.expanduser(os.environ.get("BALANCE_STATE_DIR", os.path.join(STATE_ROOT, "balance")))
DB_PATH = os.path.expanduser(os.environ.get("BALANCE_DB", os.path.join(STATE_ROOT, "balance.db")))
# Optional directory with host integrations (credentials loader, Google OAuth, ICS fetcher,
# Telegram sender, school calendar). Unset: those features are off. See docs/host-integration.md.
HOST_LIB = os.path.expanduser(os.environ.get("WORKLOG_HOST_LIB", "")) or None
TZ = os.environ.get("TZ") or "UTC"

DEFAULT_RULES = {
    "week_hours_max": 35.0,       # top of the 30-35 h band
    "evening_grace_min": 60,      # a work block ending > hard stop + grace counts as an evening
    "evenings_in_7d": 3,
    "rhr_over_baseline": 3.0,     # bpm
    "hrv_ratio": 0.90,            # 7d mean / baseline
    "sleep_min_h": 6.5,
    "sleep_score_min": 65.0,
    "stress_over_baseline": 8.0,
    "runs_missed": 2,
    "runs_planned_min": 3,
    "felt_heavy_in_7d": 3,
    "baseline_days": 90,
    "baseline_gap_days": 14,
    "pre_event_days": 7,
    "amber_every_days": 7,
    "nudge_after_min": 30,        # minutes past the hard stop before the first nudge
    "nudge_snooze_min": 30,
}

DEFAULT_SETTINGS = {
    "hard_stop": "18:00",
    "run_slot": "07:30",
    "run_alt_slots": "13:00,18:00",
    "week_hours_min": "30",
    "week_hours_max": "35",
    "gcal_calendar": "Agent",
    "todoist_project": "",
    "milestone_label": "milestone",
}


def rules_path() -> str:
    return os.path.join(STATE_DIR, "config.json")


def load_rules(path: str | None = None) -> dict:
    """DEFAULT_RULES overridden by <BALANCE_STATE_DIR>/config.json (missing = defaults)."""
    out = dict(DEFAULT_RULES)
    try:
        with open(path or rules_path()) as f:
            data = json.load(f)
        if isinstance(data, dict):
            out.update({k: v for k, v in data.items() if k in DEFAULT_RULES})
    except (OSError, ValueError):
        pass
    return out
