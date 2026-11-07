"""Outlook paste grammar for the work-calendar catch-up: three shapes, nothing guessed.

1. `Fri 6 Nov 14:00-14:45 Title`            (weekday optional, day month, 24h times)
2. `06/11/2026 14:00 - 14:45 Title`         (day/month/year, 24h times, '-' or '–')
3. Outlook's two-line copy:
       `Title`
       `When: Thursday, November 6, 2026 2:00 PM-2:45 PM`
A line that matches none comes back `ok: False` with the raw text; an email address anywhere
makes the row `ok: False` ("email address"), because the mirror never stores one."""
import re
from datetime import date

MONTHS = {m: i for i, m in enumerate(["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"], 1)}
_EMAIL = re.compile(r"\S+@\S+\.\S+")
_T24 = r"([01]?\d|2[0-3]):([0-5]\d)"
_DASH = r"\s*[-–—]\s*"
SHORT = re.compile(rf"^(?:([A-Za-z]{{3,9}}),?\s+)?(\d{{1,2}})\s+([A-Za-z]{{3,9}})\.?(?:\s+(\d{{4}}))?\s+{_T24}{_DASH}{_T24}\s+(.+)$")
WEEKDAYS = {w: i for i, w in enumerate(["mon", "tue", "wed", "thu", "fri", "sat", "sun"])}
NUMERIC = re.compile(rf"^(\d{{1,2}})/(\d{{1,2}})/(\d{{4}})\s+{_T24}{_DASH}{_T24}\s+(.+)$")
WHEN = re.compile(r"^When:\s*(?:[A-Za-z]+,\s*)?([A-Za-z]+)\s+(\d{1,2}),\s*(\d{4})\s+(\d{1,2}):(\d{2})\s*([AP]M)\s*[-–—]\s*(\d{1,2}):(\d{2})\s*([AP]M)", re.I)


def _row(raw: str, d: date | None = None, start: str | None = None, end: str | None = None, title: str | None = None,
         error: str | None = None) -> dict:
    ok = error is None and d is not None
    return {"date": d.isoformat() if d else None, "start": start, "end": end, "title": title, "ok": ok, "raw": raw, "error": error}


def _checked(raw, d, start, end, title) -> dict:
    if _EMAIL.search(raw):
        return _row(raw, d, start, end, title, error="email address: never stored in the work calendar")
    if (end or "") <= (start or ""):
        return _row(raw, d, start, end, title, error="end is not after start")
    return _row(raw, d, start, end, title.strip())


def _h24(h: str, m: str, ampm: str) -> str:
    hh = int(h) % 12 + (12 if ampm.upper() == "PM" else 0)
    return f"{hh:02d}:{m}"


def _date_from(day: str, month: str, year: str | None, default_year: int) -> date | None:
    mi = MONTHS.get(month[:3].lower())
    if not mi:
        return None
    try:
        return date(int(year) if year else default_year, mi, int(day))
    except ValueError:
        return None


def _roll(d: date | None, year_given: bool, today: date | None) -> date | None:
    """A short-shape date with no year more than ~2 months behind today is next year's."""
    if d is None or year_given or today is None:
        return d
    if (today - d).days > 60:
        try:
            return d.replace(year=d.year + 1)
        except ValueError:
            return None
    return d


def parse_lines(text: str, year: int, today: date | None = None) -> list[dict]:
    rows: list[dict] = []
    lines = [ln.rstrip() for ln in (text or "").splitlines()]
    i = 0
    while i < len(lines):
        raw = lines[i].strip()
        i += 1
        if not raw:
            continue
        m = SHORT.match(raw)
        if m:
            wd, day_s, month_s, year_s = m.group(1), m.group(2), m.group(3), m.group(4)
            d = _roll(_date_from(day_s, month_s, year_s, year), bool(year_s), today)
            if d is None:
                rows.append(_row(raw, error="unknown month or day"))
            elif wd and WEEKDAYS.get(wd[:3].lower()) is not None and WEEKDAYS[wd[:3].lower()] != d.weekday():
                rows.append(_row(raw, d, error=f"weekday does not match: {d.isoformat()} is a {d.strftime('%A')}"))
            else:
                rows.append(_checked(raw, d, f"{int(m.group(5)):02d}:{m.group(6)}", f"{int(m.group(7)):02d}:{m.group(8)}", m.group(9)))
            continue
        m = NUMERIC.match(raw)
        if m:
            try:
                d = date(int(m.group(3)), int(m.group(2)), int(m.group(1)))
            except ValueError:
                rows.append(_row(raw, error="not a valid date"))
                continue
            rows.append(_checked(raw, d, f"{int(m.group(4)):02d}:{m.group(5)}", f"{int(m.group(6)):02d}:{m.group(7)}", m.group(8)))
            continue
        # Outlook two-line copy: this line is the subject if the next is a "When:" line
        nxt = lines[i].strip() if i < len(lines) else ""
        w = WHEN.match(nxt)
        if w and not raw.lower().startswith("when:"):
            i += 1
            d = _date_from(w.group(2), w.group(1), w.group(3), year)
            if d is None:
                rows.append(_row(raw + "\n" + nxt, error="unknown month"))
                continue
            rows.append(_checked(raw + "\n" + nxt, d, _h24(w.group(4), w.group(5), w.group(6)), _h24(w.group(7), w.group(8), w.group(9)), raw))
            continue
        rows.append(_row(raw, error="could not read this line"))
    return rows
