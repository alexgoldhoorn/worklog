"""Outlook paste grammar (plan 3, Task 4): three shapes, 12-hour times, email refusal, no guessing."""
from day import outlook


def test_short_line_shape():
    rows = outlook.parse_lines("Fri 6 Nov 14:00-14:45 Go/no-go prep with release manager", year=2026)
    assert rows == [{"date": "2026-11-06", "start": "14:00", "end": "14:45", "title": "Go/no-go prep with release manager",
                     "ok": True, "raw": "Fri 6 Nov 14:00-14:45 Go/no-go prep with release manager", "error": None}]


def test_numeric_date_shape_and_en_dash():
    rows = outlook.parse_lines("06/11/2026 14:00 - 14:45 Sprint review\n7/11/2026 09:00–09:30 Stand-up", year=2026)
    assert [(r["date"], r["start"], r["end"], r["title"]) for r in rows] == [
        ("2026-11-06", "14:00", "14:45", "Sprint review"), ("2026-11-07", "09:00", "09:30", "Stand-up")]


def test_outlook_two_line_copy_with_12_hour_times():
    text = "Go/no-go prep\nWhen: Thursday, November 6, 2026 2:00 PM-2:45 PM\n\nEval walkthrough\nWhen: Friday, November 7, 2026 10:30 AM-11:30 AM"
    rows = outlook.parse_lines(text, year=2026)
    assert [(r["date"], r["start"], r["end"], r["title"], r["ok"]) for r in rows] == [
        ("2026-11-06", "14:00", "14:45", "Go/no-go prep", True), ("2026-11-07", "10:30", "11:30", "Eval walkthrough", True)]


def test_email_anywhere_is_refused_and_garbage_is_not_guessed():
    rows = outlook.parse_lines("Fri 6 Nov 14:00-14:45 Call bob@corp.com\nlunch with the team\n", year=2026)
    assert rows[0]["ok"] is False and "email" in rows[0]["error"]
    assert rows[1]["ok"] is False and rows[1]["raw"] == "lunch with the team" and rows[1]["date"] is None
    assert outlook.parse_lines("   \n", year=2026) == []


def test_weekday_mismatch_is_refused_not_guessed():
    rows = outlook.parse_lines("Fri 6 Nov 14:00-14:45 Prep", year=2026)       # 6 Nov 2026 is a Friday
    assert rows[0]["ok"] is True
    rows = outlook.parse_lines("Thu 6 Nov 14:00-14:45 Prep", year=2026)
    assert rows[0]["ok"] is False and "weekday" in rows[0]["error"]


def test_short_shape_rolls_to_next_year_when_far_in_the_past():
    from datetime import date
    rows = outlook.parse_lines("Mon 5 Jan 09:00-10:00 Kickoff", year=2026, today=date(2026, 12, 15))
    assert rows[0]["date"] == "2027-01-05"
    rows = outlook.parse_lines("Mon 5 Jan 09:00-10:00 Kickoff", year=2026, today=date(2026, 2, 1))
    assert rows[0]["date"] == "2026-01-05"                                    # a few weeks back: this year
