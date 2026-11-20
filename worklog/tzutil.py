"""Daylight-saving helpers. Stored times stay naive local wall-clock strings; these turn a naive
reading (plus its `fold` bit for the repeated hour) into a real instant when time must be measured."""
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

_UTC = timezone.utc


def instant(naive: datetime, tz: ZoneInfo | None) -> datetime:
    """The aware (UTC) instant of a naive local reading. `fold` picks the pass through a repeated hour;
    a wall time that does not exist (the skipped hour) is moved to the valid instant after it."""
    if tz is None:
        return naive
    aware = naive.replace(tzinfo=tz)
    return aware.astimezone(_UTC)


def wall(aware: datetime, tz: ZoneInfo) -> datetime:
    """Back to a naive reading, keeping `fold` so the repeated hour stays distinguishable."""
    return aware.astimezone(tz).replace(tzinfo=None)


def is_repeated(naive: datetime, tz: ZoneInfo) -> bool:
    a = naive.replace(tzinfo=tz, fold=0)
    b = naive.replace(tzinfo=tz, fold=1)
    return a.utcoffset() != b.utcoffset() and a.astimezone(_UTC) < b.astimezone(_UTC)


def parse_at(naive: datetime, tz: ZoneInfo | None, now: datetime) -> datetime:
    """A client's `at` (fold unknown) as a naive reading. In the repeated hour it means the later
    pass, unless that is still ahead of `now`, then the earlier one; in the skipped hour it means
    the valid wall time after the gap."""
    if tz is None:
        return naive
    naive = naive.replace(fold=0)
    if is_repeated(naive, tz):
        later = naive.replace(fold=1)
        if instant(later, tz) <= instant(now, tz).replace(second=59):
            return later
        return naive
    return wall(instant(naive, tz), tz)


def elapsed_seconds(start: datetime, now: datetime, tz: ZoneInfo | None) -> float:
    """True seconds between two readings (start is taken as the first pass of a repeated hour)."""
    if tz is None:
        return (now - start).total_seconds()
    return (instant(now, tz) - instant(start.replace(fold=0), tz)).total_seconds()


def last_minute_before_clock_goes_back(start: datetime, tz: ZoneInfo) -> datetime | None:
    """The latest wall minute reached, moving forward from `start`, before the wall clock steps
    back (or the day ends). None when it never does within a day."""
    t = instant(start.replace(fold=0), tz)
    prev = wall(t, tz)
    for _ in range(24 * 60 + 1):
        t += timedelta(minutes=1)
        cur = wall(t, tz)
        if cur < prev:
            return prev
        if cur.date() != prev.date():
            return None
        prev = cur
    return None
