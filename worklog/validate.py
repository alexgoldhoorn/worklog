"""Request-input validation shared by the worklog, day and balance APIs.

Every helper takes whatever JSON/query value arrived (str, int, None...) and either returns
the canonical string to store or raises ApiError (a 400)."""
import re
from datetime import date as _date


class ApiError(Exception):
    """Raised for bad input; the app turns it into `{"error": message}` with this status."""
    def __init__(self, message: str, status: int = 400):
        self.message, self.status = message, status


_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
_HHMM = re.compile(r"([01]\d|2[0-3]):[0-5]\d")
_LOOSE_TIME = re.compile(r"(\d{1,2})[:.hH]?(\d{2})")


def date_arg(v, name: str = "date") -> str:
    """Strictly YYYY-MM-DD (Python 3.11+ would also accept 20261109 or 2026-W45-1)."""
    try:
        if not isinstance(v, str) or not _DATE.fullmatch(v):
            raise ValueError
        return _date.fromisoformat(v).isoformat()
    except ValueError:
        raise ApiError(f"invalid {name}: {v!r} (expected YYYY-MM-DD)")


def optional_date(v, default: _date, name: str = "date") -> _date:
    """An empty value gives `default`; anything else must be a strict YYYY-MM-DD."""
    if v is None or v == "":
        return default
    return _date.fromisoformat(date_arg(v, name))


def is_hhmm(v) -> bool:
    return isinstance(v, str) and _HHMM.fullmatch(v) is not None


def hhmm(v, name: str = "time") -> str:
    """Strictly HH:MM; a non-string (e.g. 900) is a 400, never a TypeError."""
    if not is_hhmm(v):
        raise ApiError(f"invalid {name}: {v!r} (expected HH:MM)")
    return v


def loose_time(v, name: str = "time") -> str:
    """Accept HH:MM, and also 9:50 / 9.50 / 950 / 0950 (what people type in the timer), as HH:MM."""
    if isinstance(v, str):
        m = _LOOSE_TIME.fullmatch(v.strip())
        if m and int(m.group(1)) < 24 and int(m.group(2)) < 60:
            return f"{int(m.group(1)):02d}:{m.group(2)}"
    raise ApiError(f"invalid {name}: {v!r} (expected HH:MM)")


def text(v, name: str = "text") -> str:
    """A missing value is ""; a string is stripped; anything else (a number, a list) is a 400,
    never an AttributeError from .strip()."""
    if v is None:
        return ""
    if not isinstance(v, str):
        raise ApiError(f"{name} must be a string")
    return v.strip()


def obj(v, name: str) -> dict:
    """A missing value is {}; a JSON object is returned as is; anything else is a 400."""
    if v is None:
        return {}
    if not isinstance(v, dict):
        raise ApiError(f"{name} must be an object")
    return v


def str_list(v, name: str) -> list:
    """A missing value is []; a JSON list of strings is returned as is; anything else is a 400."""
    if v is None:
        return []
    if not isinstance(v, list) or not all(isinstance(x, str) for x in v):
        raise ApiError(f"{name} must be a list of strings")
    return v
