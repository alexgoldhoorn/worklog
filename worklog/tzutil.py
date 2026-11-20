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


def fold_of(naive: datetime, tz: ZoneInfo | None) -> int | None:
    """The fold to store for a time the timer writes: 0 or 1 inside a repeated hour, else None."""
    if tz is None or not is_repeated(naive.replace(second=0, microsecond=0), tz):
        return None
    return naive.fold


def reading(date: str, hhmm: str, fold: int | None) -> datetime:
    """A stored date and time as a naive reading carrying its fold (NULL = first pass)."""
    return datetime.fromisoformat(f"{date} {hhmm}").replace(fold=1 if fold else 0)


def back_minutes(start: datetime, end: datetime, tz: ZoneInfo) -> int:
    """Minutes the wall clock stepped back between two readings (0 if it did not): the amount to
    add to their wall-clock difference to get the true duration."""
    back = tz.utcoffset(start) - tz.utcoffset(end)
    return int(back.total_seconds() // 60) if back > timedelta(0) else 0


def elapsed_seconds(start: datetime, now: datetime, tz: ZoneInfo | None) -> float:
    """True seconds between two readings (each carries its own fold)."""
    if tz is None:
        return (now - start).total_seconds()
    return (instant(now, tz) - instant(start, tz)).total_seconds()
