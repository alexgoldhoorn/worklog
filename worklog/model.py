"""Pure derivations over blocks: work type, durations, flags, calendar keys."""
from datetime import date as _date, timedelta

from .db import Block


def work_type(type_: str, break_types: set[str]) -> str:
    return "other" if type_.strip().lower() in break_types else "work"


def _mins(hhmm_: str) -> int:
    h, m = hhmm_.split(":")
    return int(h) * 60 + int(m)


def minutes(start: str, end: str | None) -> int | None:
    """Minutes between two same-day times; None while running. Negative when end < start
    (a block cannot span midnight: it is closed at the day's end and a new one starts)."""
    if end is None:
        return None
    return _mins(end) - _mins(start)


def hours(m: int | None) -> float:
    return 0.0 if m is None else m / 60


def hhmm(m: int) -> str:
    sign = "-" if m < 0 else ""
    h, mm = divmod(abs(m), 60)
    return f"{sign}{h:02d}:{mm:02d}"


def _d(date: str) -> _date:
    return _date.fromisoformat(date)


def excel_weekday(date: str) -> int:
    """Sunday=1 ... Saturday=7, the numbering of Excel's WEEKDAY(), kept so exports and
    imports line up with spreadsheets this app replaced."""
    return _d(date).isoweekday() % 7 + 1


def is_workday(date: str) -> bool:
    return _d(date).isoweekday() <= 5


def week_key(date: str) -> str:
    y, w, _ = _d(date).isocalendar()
    return f"{y}-{w:02d}"


def month_key(date: str) -> str:
    return date[:7]


def quarter_key(date: str) -> str:
    return f"{date[:4]}-Q{(_d(date).month - 1) // 3 + 1}"


def year_key(date: str) -> str:
    return date[:4]


def week_bounds(key: str) -> tuple[str, str]:
    y, w = key.split("-")
    monday = _date.fromisocalendar(int(y), int(w), 1)
    return monday.isoformat(), (monday + timedelta(days=6)).isoformat()


def flags(blocks: list[Block]) -> dict[int, dict]:
    """Per block id: `start_gt_end` (bad times) and `overlap` (starts before an earlier block
    ended). The comparison uses the latest end seen so far, so a short block inside a long one
    is flagged too."""
    out: dict[int, dict] = {}
    covered: str | None = None  # latest end seen so far, not just the previous block's
    for b in sorted(blocks, key=lambda x: x.start):
        out[b.id] = {
            "start_gt_end": b.end is not None and b.start > b.end,
            "overlap": covered is not None and b.start < covered,
        }
        if b.end is not None and (covered is None or b.end > covered):
            covered = b.end
    return out


def overlaps(blocks: list[Block]) -> list[tuple[Block, Block]]:
    """Pairs (earlier, later) of same-day blocks whose intervals intersect; open blocks run to now."""
    out = []
    done = [b for b in sorted(blocks, key=lambda x: (x.start, x.id))]
    for i, a in enumerate(done):
        a_end = a.end or "24:00"
        for b in done[i + 1:]:
            if b.start < a_end and b.start >= a.start:
                out.append((a, b))
    return out


def with_derived(b: Block, break_types) -> dict:
    m = minutes(b.start, b.end)
    wk = week_key(b.date)
    return {
        "id": b.id, "date": b.date, "start": b.start, "end": b.end,
        "project": b.project, "type": b.type, "client": b.client,
        "billable": b.billable, "source": b.source, "auto_closed": b.auto_closed,
        "work_type": work_type(b.type, break_types),
        "minutes": m,
        "duration_h": None if m is None else round(m / 60, 4),
        "duration": None if m is None else hhmm(m),
        "week_day": excel_weekday(b.date),
        "is_workday": is_workday(b.date),
        "week": wk,
        "year_week": wk,
    }
