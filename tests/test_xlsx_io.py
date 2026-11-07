import io
from datetime import date, datetime, time

import openpyxl

from tests.helpers import book
from worklog import db, expect, xlsx_io


def test_parse_normalises_cell_types(tmp_path):
    p = book(tmp_path, [
        [datetime(2026, 3, 2), time(9, 10), time(10, 0), "meeting", "meet", "ACME", True, "x"],
        ["2026-03-02", "10:00", datetime(2026, 3, 2, 10, 30), None, "read", "ACME", "TRUE", None],
        [datetime(2026, 3, 2), 0.4375, 0.5, "coffee++", "eat", None, None, None],      # 10:30 -> 12:00
        [datetime(2026, 10, 20), None, None, None, None, None, None, None],            # placeholder
    ])
    parsed = xlsx_io.parse_rows(p, "t.xlsx")
    assert [(b.start, b.end, b.billable) for b in parsed.blocks] == [("09:10", "10:00", True), ("10:00", "10:30", True), ("10:30", "12:00", None)]
    assert parsed.skipped == 1 and parsed.errors == []


def test_parse_csv_with_bom_and_semicolons(tmp_path):
    p = tmp_path / "t.csv"
    p.write_bytes("﻿date;start;end;project;type;Client;Billable\n2026-03-02;9:10;10:00;;dev;ACME;TRUE\n".encode())
    parsed = xlsx_io.parse_rows(p, "t.csv")
    assert parsed.blocks[0].start == "09:10" and parsed.blocks[0].type == "dev"


def test_parse_missing_type_defaults_and_file_like(tmp_path):
    p = book(tmp_path, [
        [datetime(2026, 3, 2), time(9, 0), time(10, 0), None, None, "ACME", None, None],
        [datetime(2026, 3, 2), time(10, 0), time(11, 0), None, None, None, None, None],
    ])
    parsed = xlsx_io.parse_rows(io.BytesIO(p.read_bytes()), "t.xlsx")
    assert [b.type for b in parsed.blocks] == ["div", "other"]
    assert parsed.errors == ["row 2: no type, defaulted", "row 3: no type, defaulted"]


def test_import_merge_and_replace(conn, tmp_path):
    p = book(tmp_path, [[datetime(2026, 3, 2), time(9, 0), time(10, 0), "a", "dev", "ACME", True, None]], meta=["eat", "nap"], clients=[("ACME", "Acme")])
    r = xlsx_io.import_blocks(conn, xlsx_io.parse_rows(p, "t.xlsx"), "merge")
    assert r["inserted"] == 1 and "nap" in db.break_types(conn)
    db.insert_block(conn, db.Block(None, "2026-03-02", "10:00", "11:00", None, "dev", "ACME", True))
    p2 = book(tmp_path, [[datetime(2026, 3, 2), time(9, 0), time(9, 30), "b", "dev", "ACME", True, None]])
    r = xlsx_io.import_blocks(conn, xlsx_io.parse_rows(p2, "t.xlsx"), "merge")
    assert (r["inserted"], r["updated"]) == (0, 1) and len(db.blocks_on(conn, "2026-03-02")) == 2
    r = xlsx_io.import_blocks(conn, xlsx_io.parse_rows(p2, "t.xlsx"), "replace")
    assert r["deleted"] == 2 and r["inserted"] == 1 and len(db.blocks_on(conn, "2026-03-02")) == 1


def test_import_workdays_matches_weekly_targets(conn, tmp_path):
    db.insert_block(conn, db.Block(None, "2026-03-01", "09:00", "10:00", None, "dev", "ACME", True))
    hol = {"2026-04-03": "Divendres Sant", "2026-04-06": "Dilluns de Pasqua", "2026-05-01": "Festa del Treball", "2026-09-24": "La Mercè"}
    p = book(tmp_path, [], workday=[(2026, 11, 4.5, 31.5, 4, "was sick half day"), (2026, 14, 0, 0, None, "easter holidays"),
                                    (2026, 18, 3.5, 24.5, None, "half day off, and 1 May"), (2026, 20, 5, 35, None, None),
                                    (2026, 34, 5, 17.5, None, "half days"), (2026, 39, 4.5, 31.5, None, "holiday 24/9 (?)")])
    n = xlsx_io.import_workdays(conn, xlsx_io.parse_rows(p, "t.xlsx"), hol)
    first = expect.first_logged_day(conn)
    for key, target in [("2026-11", 31.5), ("2026-14", 0), ("2026-18", 24.5), ("2026-20", 35), ("2026-34", 17.5), ("2026-39", 31.5)]:
        assert expect.week_expected(conn, key, hol, first) == target, key
    assert db.get_expectation(conn, "2026-03-13").sick_h == 4          # Fri of week 11 carries the half day + sick hours
    assert db.get_expectation(conn, "2026-03-13").expected_h == 3.5
    assert db.get_expectation(conn, "2026-05-01") is None              # holiday already 0, nothing stored
    assert db.get_expectation(conn, "2026-04-30").expected_h == 3.5    # Thu of week 18 (Fri is the holiday)
    assert db.get_expectation(conn, "2026-05-15") is None              # week 20: nothing stored
    assert db.get_expectation(conn, "2026-08-19").expected_h == 3.5    # week 34: 5 half days, spread evenly
    assert db.get_expectation(conn, "2026-09-24").expected_h == 3.5    # week 39: client half-worked La Mercè
    assert n == 1 + 4 + 1 + 0 + 5 + 1


def test_export_columns_and_roundtrip(conn, tmp_path):
    db.insert_block(conn, db.Block(None, "2026-03-03", "10:00", "11:12", "trainings", "study", "ACME", True))
    db.insert_block(conn, db.Block(None, "2026-03-03", "11:12", "11:30", "coffee++", "eat", None, None))
    rows = xlsx_io.export_rows(conn, "2026-03-01", "2026-03-31", {})
    assert list(rows[0]) == xlsx_io.EXPORT_COLUMNS
    assert rows[0]["duration"] == "01:12" and rows[0]["duration_h"] == 1.2 and rows[0]["week day"] == 3
    assert rows[0]["year-week"] == "2026-10" and rows[1]["work_type"] == "other" and rows[1]["Billable"] == ""
    xlsx = xlsx_io.export_xlsx(conn, rows, "2026-03-01", "2026-03-31", {}, date(2026, 3, 31))
    wb = openpyxl.load_workbook(io.BytesIO(xlsx))
    assert set(wb.sheetnames) == {"log", "summary", "workday", "meta", "clients"}
    conn2 = db.connect(str(tmp_path / "second.db"))
    out = tmp_path / "e.xlsx"
    out.write_bytes(xlsx)
    xlsx_io.import_blocks(conn2, xlsx_io.parse_rows(out, "e.xlsx"), "merge")
    assert [(b.start, b.end, b.type, b.billable) for b in db.blocks_on(conn2, "2026-03-03")] == [("10:00", "11:12", "study", True), ("11:12", "11:30", "eat", None)]
    csv_text = xlsx_io.export_csv(rows).decode()
    assert csv_text.splitlines()[0] == ",".join(xlsx_io.EXPORT_COLUMNS)
