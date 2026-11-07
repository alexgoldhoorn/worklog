"""Holidays from the holidays cache, two views of it.

The cache is `{"<year>": {"holidays": [{"date", "name", "scope"}, ...]}}`. Work days off
(worklog.expect, `client_holidays`) leave out WORKLOG_HOLIDAY_SKIP_SCOPES; the school
calendar keeps only DAY_SCHOOL_HOLIDAY_SCOPES (unset: every scope)."""
import json
import os


def _scopes(var: str) -> set[str]:
    return {s.strip() for s in os.environ.get(var, "").split(",") if s.strip()}


def _read(path: str | None, keep) -> dict[str, str]:
    if not path:
        return {}
    try:
        with open(path) as f:
            data = json.load(f)
        out: dict[str, str] = {}
        for year in data.values():
            for h in year.get("holidays", []):
                if keep(h.get("scope")):
                    out[h["date"]] = h["name"]
        return out
    except (OSError, ValueError, AttributeError, KeyError, TypeError):
        return {}


def school_holidays(path: str | None) -> dict[str, str]:
    scopes = _scopes("DAY_SCHOOL_HOLIDAY_SCOPES")
    return _read(path, lambda s: not scopes or s in scopes)


def client_holidays(path: str | None) -> dict[str, str]:
    """The client's calendar, as worklog.expect reads it. Kept here so host code never imports
    the `worklog` package, whose name can collide with another package named `worklog`."""
    skip = _scopes("WORKLOG_HOLIDAY_SKIP_SCOPES")
    return _read(path, lambda s: s not in skip)
