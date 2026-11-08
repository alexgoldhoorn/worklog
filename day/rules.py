"""Day rules: care duties, who 'me' is, Family-calendar title patterns. DAY_RULES=<path> points
at your own file (start from rules.example.json). Without it, an optional git-ignored
day/rules.json beside this module is used, and without that the neutral built-in defaults."""
import copy
import json
import os

DEFAULT_PATH = os.path.join(os.path.dirname(__file__), "rules.json")   # optional, git-ignored
EXAMPLE_PATH = os.path.join(os.path.dirname(__file__), "rules.example.json")


NEUTRAL_RULES = {
    "household": {
        "me": "me", "me_aliases": ["you", "me"], "partner": "partner", "child": "child",
        "calendars": {"personal": "Personal", "family": "Family", "child": "Child", "agent": "Agent"},
        "timezone": "UTC", "people": {},
    },
    "duties": [],
    "family_patterns": {"partner": [], "child": [], "family": []},
    "slots": {"step_min": 15, "day_start": "06:30", "day_end": "21:30", "work_start": "08:30",
              "travel_margin_min": 15, "work_share_tolerance_h": 0.5},
}

HOUSEHOLD_DEFAULTS = {
    "me": "me", "me_aliases": ["you", "me"], "partner": "partner", "child": "child",
    "calendars": {"personal": "Personal", "family": "Family", "child": "Child", "agent": "Agent"},
    "timezone": "UTC", "people": {},
}


def household(rules: dict) -> dict:
    """The people, calendars and timezone this dashboard serves. Every key has a default, so
    the engine, model and pages work for another household from rules.json alone."""
    h = dict(HOUSEHOLD_DEFAULTS)
    h["calendars"] = dict(HOUSEHOLD_DEFAULTS["calendars"])
    given = rules.get("household") or {}
    for k, v in given.items():
        if k == "calendars" and isinstance(v, dict):
            h["calendars"].update(v)
        elif v is not None:
            h[k] = v
    if "household" not in rules and rules.get("me"):
        h["me"] = rules["me"]
    h["me_aliases"] = list(h.get("me_aliases") or [])
    return h


def load(path: str | None = None) -> dict:
    p = path or os.environ.get("DAY_RULES")
    if not p and os.path.exists(DEFAULT_PATH):
        p = DEFAULT_PATH
    if p:
        try:
            with open(p) as f:
                rules = json.load(f)
        except FileNotFoundError:
            raise FileNotFoundError(f"household rules file not found: {p} (check DAY_RULES; "
                                    "start from day/rules.example.json)") from None
    else:
        rules = copy.deepcopy(NEUTRAL_RULES)
    rules.setdefault("duties", [])
    rules.setdefault("me", (rules.get("household") or {}).get("me", "me"))
    rules.setdefault("family_patterns", {})
    return rules
