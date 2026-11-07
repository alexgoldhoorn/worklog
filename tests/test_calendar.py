from tests.helpers import cal
from worklog import calendar, db


def test_proposals_skip_overlapping_cancelled_and_endless(tmp_path):
    p = cal(tmp_path, [("2026-10-20", "10:15", "10:30", "weekly AI", "confirmed"), ("2026-10-20", "14:00", "15:00", "retro", "cancelled"),
                       ("2026-10-20", "16:00", "16:30", "1:1", "confirmed"), ("2026-10-20", "17:00", None, "allday?", "confirmed")])
    blocks = [db.Block(1, "2026-10-20", "10:00", "10:30", "weekly AI", "meet", "ACME", True)]
    got, warn = calendar.proposals(p, "2026-10-20", blocks)
    assert got == [{"start": "16:00", "end": "16:30", "title": "1:1"}] and warn is None


def test_open_block_hides_only_the_meeting_it_began_during(tmp_path):
    p = cal(tmp_path, [("2026-10-20", "14:00", "14:30", "sync", "confirmed"), ("2026-10-20", "15:05", "15:20", "standup", "confirmed"),
                       ("2026-10-20", "16:00", "16:30", "1:1", "confirmed")])
    got, _ = calendar.proposals(p, "2026-10-20", [db.Block(1, "2026-10-20", "15:10", None, "standup", "meet", "ACME", True)])
    assert [g["title"] for g in got] == ["sync", "1:1"]


def test_missing_db_gives_notice(tmp_path):
    got, warn = calendar.proposals(str(tmp_path / "nope.db"), "2026-10-20", [])
    assert got == [] and warn.startswith("calendar unavailable")
    assert calendar.proposals(None, "2026-10-20", []) == ([], "calendar unavailable: not configured")


def test_not_a_database_gives_notice(tmp_path):
    f = tmp_path / "junk.db"
    f.write_text("this is not sqlite" * 100)
    got, warn = calendar.proposals(str(f), "2026-10-20", [])
    assert got == [] and warn.startswith("calendar unavailable")
