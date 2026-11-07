"""Excel/CSV import and export of the time log (the layout of the old Excel sheet)."""
import csv
import io
import re
from dataclasses import dataclass, field
from datetime import date as _date, datetime, time as _time, timedelta

import openpyxl

from . import db, expect, model, reports

EXPORT_COLUMNS = ["date", "start", "end", "project", "type", "Client", "Billable", "work_type",
                  "duration", "duration_h", "amount", "week day", "is workday", "week", "year-week"]
SUMMARY_COLUMNS = ["year-week", "worked_h", "expected_h", "extra_h", "extra_40h", "days_worked",
                   "days_equiv", "billable_h", "amount"]

_HEADERS = {"date", "start", "end", "project", "type", "client", "billable"}
_WORKDAY_FIELDS = {"year": "year", "week": "week", "workdays": "workdays", "workhours": "workhours",
                   "sick hours": "sick_hours", "comment": "comment"}


@dataclass
class ParsedFile:
    blocks: list[db.Block] = field(default_factory=list)
    break_types: list[str] = field(default_factory=list)
    clients: list[tuple[str, str]] = field(default_factory=list)
    workdays: list[dict] = field(default_factory=list)
    skipped: int = 0
    errors: list[str] = field(default_factory=list)


# ---- cell normalisation ----------------------------------------------------

def _blank(v) -> bool:
    return v is None or (isinstance(v, str) and not v.strip())


def _parse_date(v) -> str:
    if isinstance(v, datetime):
        return v.date().isoformat()
    if isinstance(v, _date):
        return v.isoformat()
    s = str(v).strip()
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", s):
        return _date.fromisoformat(s).isoformat()
    m = re.fullmatch(r"(\d{1,2})/(\d{1,2})/(\d{4})", s)
    if m:
        return _date(int(m[3]), int(m[2]), int(m[1])).isoformat()
    raise ValueError(f"bad date {v!r}")


def _parse_time(v) -> str:
    if isinstance(v, datetime):
        return v.strftime("%H:%M")
    if isinstance(v, _time):
        return v.strftime("%H:%M")
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        total = round(float(v) * 1440)
        if not 0 <= total < 1440:
            raise ValueError(f"bad time {v!r}")
        return f"{total // 60:02d}:{total % 60:02d}"
    m = re.fullmatch(r"(\d{1,2}):(\d{2})(?::\d{2})?", str(v).strip())
    if not m or int(m[1]) > 23 or int(m[2]) > 59:
        raise ValueError(f"bad time {v!r}")
    return f"{int(m[1]):02d}:{m[2]}"


def _parse_billable(v) -> bool | None:
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return bool(v)
    s = str(v).strip().upper() if v is not None else ""
    return {"TRUE": True, "1": True, "FALSE": False, "0": False}.get(s)


def _text(v) -> str | None:
    return None if _blank(v) else str(v).strip()


def _number(v) -> float | None:
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, float)):
        return float(v)
    try:
        return float(str(v).strip().replace(",", "."))
    except ValueError:
        return None


# ---- parsing ---------------------------------------------------------------

def _read_bytes(path_or_file) -> bytes:
    if hasattr(path_or_file, "read"):
        data = path_or_file.read()
        return data.encode() if isinstance(data, str) else data
    with open(path_or_file, "rb") as f:
        return f.read()


def _log_rows(header: list, rows: list[list], parsed: ParsedFile) -> None:
    idx = {}
    for i, h in enumerate(header):
        name = str(h).strip().lower() if h is not None else ""
        if name in _HEADERS and name not in idx:
            idx[name] = i

    def cell(row, name):
        i = idx.get(name)
        return row[i] if i is not None and i < len(row) else None

    for n, row in enumerate(rows, start=2):
        if all(_blank(c) for c in row):
            continue
        if _blank(cell(row, "date")):
            parsed.errors.append(f"row {n}: no date")
            continue
        try:
            day = _parse_date(cell(row, "date"))
            if _blank(cell(row, "start")):
                parsed.skipped += 1
                continue
            start = _parse_time(cell(row, "start"))
            end = None if _blank(cell(row, "end")) else _parse_time(cell(row, "end"))
        except ValueError as e:
            parsed.errors.append(f"row {n}: {e}")
            continue
        client = _text(cell(row, "client"))
        type_ = (_text(cell(row, "type")) or "").lower()
        if not type_:
            type_ = "div" if client else "other"
            parsed.errors.append(f"row {n}: no type, defaulted")
        parsed.blocks.append(db.Block(None, day, start, end, _text(cell(row, "project")), type_,
                                      client, _parse_billable(cell(row, "billable"))))


def _workday_rows(header: list, rows: list[list], parsed: ParsedFile) -> None:
    idx = {}
    for i, h in enumerate(header):
        name = str(h).strip().lower() if h is not None else ""
        if name in _WORKDAY_FIELDS and _WORKDAY_FIELDS[name] not in idx:
            idx[_WORKDAY_FIELDS[name]] = i

    def cell(row, name):
        i = idx.get(name)
        return row[i] if i is not None and i < len(row) else None

    for row in rows:
        year, week = _number(cell(row, "year")), _number(cell(row, "week"))
        if year is None or week is None:
            continue
        parsed.workdays.append({
            "year": int(year), "week": int(week),
            "workdays": _number(cell(row, "workdays")),
            "workhours": _number(cell(row, "workhours")),
            "sick_hours": _number(cell(row, "sick_hours")) or 0.0,
            "comment": _text(cell(row, "comment")) or "",
        })


def _sheet(wb, name: str):
    for ws in wb.worksheets:
        if ws.title.strip().lower() == name:
            return ws
    return None


def _rows(ws) -> tuple[list, list[list]]:
    it = ws.iter_rows(values_only=True)
    header = list(next(it, []))
    return header, [list(r) for r in it]


def _parse_xlsx(data: bytes, parsed: ParsedFile) -> None:
    wb = openpyxl.load_workbook(io.BytesIO(data), data_only=True)
    log = _sheet(wb, "log") or wb.worksheets[0]
    _log_rows(*_rows(log), parsed)
    if (meta := _sheet(wb, "meta")) is not None:
        parsed.break_types = [t.lower() for r in _rows(meta)[1] if (t := _text(r[0] if r else None))]
    if (cl := _sheet(wb, "clients")) is not None:
        for r in _rows(cl)[1]:
            abbrev = _text(r[0] if r else None)
            if abbrev:
                parsed.clients.append((abbrev, _text(r[1] if len(r) > 1 else None) or abbrev))
    if (wd := _sheet(wb, "workday")) is not None:
        _workday_rows(*_rows(wd), parsed)


def _parse_csv(data: bytes, parsed: ParsedFile) -> None:
    text = data.decode("utf-8-sig")
    first = text.splitlines()[0] if text.strip() else ""
    delimiter = ";" if first.count(";") > first.count(",") else ","
    rows = list(csv.reader(io.StringIO(text), delimiter=delimiter))
    if rows:
        _log_rows(rows[0], rows[1:], parsed)


def parse_rows(path_or_file, filename: str) -> ParsedFile:
    ext = filename.lower().rsplit(".", 1)[-1] if "." in filename else ""
    if ext not in ("xlsx", "csv"):
        raise ValueError(f"unsupported file type: {filename!r} (use .xlsx or .csv)")
    data = _read_bytes(path_or_file)
    parsed = ParsedFile()
    (_parse_xlsx if ext == "xlsx" else _parse_csv)(data, parsed)
    return parsed


# ---- import ----------------------------------------------------------------

def import_blocks(conn, parsed: ParsedFile, mode: str) -> dict:
    if mode not in ("merge", "replace"):
        raise ValueError(f"unknown import mode: {mode!r}")
    conn.executemany("INSERT OR IGNORE INTO break_types(name) VALUES (?)", [(t,) for t in parsed.break_types])
    conn.executemany(
        "INSERT INTO clients(abbrev, name) VALUES (?, ?)"
        " ON CONFLICT(abbrev) DO UPDATE SET name = excluded.name", parsed.clients)
    conn.commit()
    inserted = updated = deleted = 0
    if mode == "replace" and parsed.blocks:
        lo, hi = min(b.date for b in parsed.blocks), max(b.date for b in parsed.blocks)
        deleted = conn.execute("DELETE FROM blocks WHERE date BETWEEN ? AND ?", (lo, hi)).rowcount
        conn.commit()
    for b in parsed.blocks:
        b.source = "import"
        existing = None
        if mode == "merge":
            existing = conn.execute("SELECT id FROM blocks WHERE date = ? AND start = ? ORDER BY id LIMIT 1",
                                    (b.date, b.start)).fetchone()
        if existing:
            db.update_block(conn, existing["id"], end=b.end, project=b.project, type=b.type,
                            client=b.client, billable=b.billable, source="import")
            updated += 1
        else:
            db.insert_block(conn, b)
            inserted += 1
    return {"inserted": inserted, "updated": updated, "deleted": deleted,
            "skipped": parsed.skipped, "errors": list(parsed.errors)}


def import_workdays(conn, parsed: ParsedFile, holidays: dict[str, str]) -> int:
    stored = 0

    def put(day, hours, sick, reason):
        nonlocal stored
        db.set_expectation(conn, db.DayExpectation(day, hours, sick, reason, "import"))
        stored += 1

    for w in parsed.workdays:
        try:
            monday = _date.fromisocalendar(w["year"], w["week"], 1)
        except ValueError:
            continue
        workdays, workhours = w["workdays"], w["workhours"]
        if workhours is None and workdays is None:
            continue
        target = workhours if workhours is not None else 7 * workdays
        weekdays = [(monday + timedelta(days=i)).isoformat() for i in range(5)]
        days = [d for d in weekdays if d not in holidays]
        deficit = round(7 * len(days) - target, 6)
        sick = w["sick_hours"]
        if deficit == 0:
            continue
        if deficit > 0:
            reason = w["comment"] or "from weekly import"
            if workdays == len(days):
                for i, d in enumerate(days):
                    put(d, target / len(days), sick if i == 0 else 0.0, reason)
            else:
                remaining, first = deficit, True
                for d in reversed(days):
                    if remaining <= 0:
                        break
                    take = min(7.0, remaining)
                    put(d, 7 - take, sick if first else 0.0, reason)
                    remaining = round(remaining - take, 6)
                    first = False
        else:
            remaining = -deficit
            for d in (d for d in weekdays if d in holidays):
                if remaining <= 0:
                    break
                give = min(7.0, remaining)
                put(d, give, 0.0, w["comment"] or "client worked")
                remaining = round(remaining - give, 6)
    return stored


# ---- export ----------------------------------------------------------------

def export_rows(conn, start: str, end: str, holidays) -> list[dict]:
    btypes = db.break_types(conn)
    rate = reports.rate_per_h(conn)
    out = []
    for b in db.blocks_between(conn, start, end):
        d = model.with_derived(b, btypes)
        wk = model.week_key(b.date)
        billed = d["work_type"] == "work" and b.billable and d["duration_h"] is not None
        out.append({
            "date": b.date, "start": b.start, "end": b.end or "",
            "project": b.project or "", "type": b.type, "Client": b.client or "",
            "Billable": "" if b.billable is None else b.billable,
            "work_type": d["work_type"],
            "duration": d["duration"] or "",
            "duration_h": "" if d["duration_h"] is None else d["duration_h"],
            "amount": reports.amount(d["duration_h"], rate) if billed and rate is not None else "",
            "week day": d["week_day"], "is workday": d["is_workday"],
            "week": int(wk.split("-")[1]), "year-week": wk,
        })
    return out


def _csv_value(v):
    return ("TRUE" if v else "FALSE") if isinstance(v, bool) else v


def export_csv(rows: list[dict]) -> bytes:
    buf = io.StringIO()
    w = csv.writer(buf, lineterminator="\n")
    w.writerow(EXPORT_COLUMNS)
    for r in rows:
        w.writerow([_csv_value(r[c]) for c in EXPORT_COLUMNS])
    return buf.getvalue().encode("utf-8")


def export_xlsx(conn, rows: list[dict], start: str, end: str, holidays, today: _date) -> bytes:
    wb = openpyxl.Workbook()
    log = wb.active
    log.title = "log"
    log.append(EXPORT_COLUMNS)
    for r in rows:
        log.append([r[c] for c in EXPORT_COLUMNS])

    wd = wb.create_sheet("workday")
    wd.append(["year", "week", "year-week", "workdays", "workhours", "sick hours", "comment"])
    first_day = expect.first_logged_day(conn)
    for g in reports.grouped(conn, "week", start, end, holidays, today):
        year, week = g["key"].split("-")
        wstart, wend = model.week_bounds(g["key"])
        reasons = []
        for e in expect.expected_between(conn, wstart, wend, holidays, first_day).values():
            if e.reason and e.reason not in reasons:
                reasons.append(e.reason)
        wd.append([int(year), int(week), g["key"], g["expected_h"] / 7, g["expected_h"],
                   g["sick_h"], "; ".join(reasons)])

    sm = wb.create_sheet("summary")
    sm.append(SUMMARY_COLUMNS)
    for g in reports.grouped(conn, "week", start, end, holidays, today):
        sm.append([g["key"], g["worked_h"], g["expected_h"], g["extra_h"], g["extra_alt_h"],
                   g["days_worked"], g["days_equiv"], g["billable_h"],
                   "" if g["amount"] is None else g["amount"]])

    meta = wb.create_sheet("meta")
    meta.append(["break types"])
    for t in sorted(db.break_types(conn)):
        meta.append([t])
    cl = wb.create_sheet("clients")
    cl.append(["Abrev", "Name"])
    for abbrev, row in sorted(db.clients(conn).items()):
        cl.append([abbrev, row["name"]])

    buf = io.BytesIO()
    wb.save(buf)
    return buf.getvalue()
