"""Day rules: care duties, who 'me' is, Family-calendar title patterns. The package file
holds neutral defaults; DAY_RULES=<path> points at your own (see rules.example.json)."""
import json
import os

DEFAULT_PATH = os.path.join(os.path.dirname(__file__), "rules.json")
EXAMPLE_PATH = os.path.join(os.path.dirname(__file__), "rules.example.json")


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
    p = path or os.environ.get("DAY_RULES") or DEFAULT_PATH
    with open(p) as f:
        rules = json.load(f)
    rules.setdefault("duties", [])
    rules.setdefault("me", (rules.get("household") or {}).get("me", "me"))
    rules.setdefault("family_patterns", {})
    return rules
