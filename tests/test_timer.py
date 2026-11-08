from datetime import datetime

import pytest

from worklog import db, reports, timer


def T(s):
    return datetime.fromisoformat(s)


def test_start_opens_work_block_with_defaults(conn):
    b = timer.start(conn, T("2026-10-20 09:10:30"))
    assert (b.date, b.start, b.end, b.type, b.client, b.billable) == ("2026-10-20", "09:10", None, "dev", "ACME", True)


def test_start_twice_same_task_is_noop(conn):
    a = timer.start(conn, T("2026-10-20 09:10"), "dev", "x")
    b = timer.start(conn, T("2026-10-20 09:10"), "dev", "x ")
    assert a.id == b.id and len(db.blocks_on(conn, "2026-10-20")) == 1


def test_start_while_working_switches_task_contiguously(conn):
    timer.start(conn, T("2026-10-20 09:00"), "dev")
    b = timer.start(conn, T("2026-10-20 10:15"), "meet", "weekly AI")
    rows = db.blocks_on(conn, "2026-10-20")
    assert rows[0].end == "10:15" == b.start and rows[0].auto_closed is False


def test_pause_defaults_to_eat_and_resume_is_start(conn):
    timer.start(conn, T("2026-10-20 09:00"))
    p = timer.pause(conn, T("2026-10-20 13:04"))
    assert (p.type, p.client, p.billable) == ("eat", None, None)
    r = timer.start(conn, T("2026-10-20 13:40"))
    assert db.get_block(conn, p.id).end == "13:40" and r.start == "13:40"


def test_pause_while_on_break_changes_type_keeping_switch_time(conn):
    timer.pause(conn, T("2026-10-20 13:00"))
    p2 = timer.pause(conn, T("2026-10-20 13:20"), "out")
    rows = db.blocks_on(conn, "2026-10-20")
    assert [(r.type, r.start, r.end) for r in rows] == [("eat", "13:00", "13:20"), ("out", "13:20", None)]
    assert timer.pause(conn, T("2026-10-20 13:25"), "out").id == p2.id


def test_pause_while_stopped_opens_break(conn):
    p = timer.pause(conn, T("2026-10-20 12:00"))
    assert p.type == "eat" and db.open_block(conn).id == p.id


def test_stop_closes_and_stop_again_is_none(conn):
    timer.start(conn, T("2026-10-20 09:00"))
    assert timer.stop(conn, T("2026-10-20 17:30")).end == "17:30"
    assert timer.stop(conn, T("2026-10-20 17:31")) is None


def test_zero_minute_block_is_dropped_on_close(conn):
    timer.start(conn, T("2026-10-20 09:00"))
    assert timer.stop(conn, T("2026-10-20 09:00:40")) is None
    assert db.blocks_on(conn, "2026-10-20") == []


def test_forgotten_block_auto_closes_at_18_and_is_flagged(conn):
    timer.start(conn, T("2026-10-19 17:00"))
    b = timer.start(conn, T("2026-10-20 09:00"))
    old = db.blocks_on(conn, "2026-10-19")[0]
    assert (old.end, old.auto_closed) == ("18:00", True) and b.date == "2026-10-20"
    db.update_block(conn, old.id, end="17:45")
    assert db.get_block(conn, old.id).auto_closed is False


def test_forgotten_block_started_after_18_closes_at_its_start(conn):
    timer.start(conn, T("2026-10-19 19:10"))
    timer.auto_close(conn, T("2026-10-20 09:00"))
    old = db.blocks_on(conn, "2026-10-19")[0]
    assert (old.end, old.auto_closed) == ("19:10", True)


def test_stop_after_midnight_splits_the_block_at_midnight(conn):
    timer.start(conn, T("2026-10-19 22:00"), "dev", "widgets")
    b = timer.stop(conn, T("2026-10-20 01:00"))
    assert (b.date, b.start, b.end, b.auto_closed) == ("2026-10-20", "00:00", "01:00", False)
    before = db.blocks_on(conn, "2026-10-19")
    assert [(x.start, x.end, x.auto_closed, x.project, x.client) for x in before] == [
        ("22:00", "23:59", False, "widgets", b.client)]
    assert db.open_block(conn) is None
    # per-day totals: 22:00-23:59 yesterday, 00:00-01:00 today
    bt = db.break_types(conn)
    assert reports.day_totals(conn, "2026-10-19", bt)["work_h"] == pytest.approx(119 / 60, abs=1e-3)
    assert reports.day_totals(conn, "2026-10-20", bt)["work_h"] == 1.0


def test_stop_at_midnight_exactly_keeps_no_empty_block(conn):
    timer.start(conn, T("2026-10-19 22:00"))
    timer.stop(conn, T("2026-10-20 00:00"))
    assert db.blocks_on(conn, "2026-10-20") == []
    assert [(x.end, x.auto_closed) for x in db.blocks_on(conn, "2026-10-19")] == [("23:59", False)]


def test_pause_after_midnight_splits_and_starts_the_break_at_now(conn):
    timer.start(conn, T("2026-10-19 22:00"))
    timer.pause(conn, T("2026-10-20 00:40"))
    assert [(x.start, x.end, x.type) for x in db.blocks_on(conn, "2026-10-20")] == [
        ("00:00", "00:40", "dev"), ("00:40", None, "eat")]
    assert db.blocks_on(conn, "2026-10-19")[0].auto_closed is False


def test_block_forgotten_past_the_morning_cutoff_is_still_auto_closed(conn):
    timer.start(conn, T("2026-10-19 22:00"))
    b = timer.stop(conn, T("2026-10-20 06:30"))
    assert (b.date, b.end, b.auto_closed) == ("2026-10-19", "22:00", True)
    assert db.blocks_on(conn, "2026-10-20") == []


def test_status_reports_state(conn):
    assert timer.status(conn, T("2026-10-20 08:00"))["state"] == "stopped"
    timer.start(conn, T("2026-10-20 09:00"))
    s = timer.status(conn, T("2026-10-20 10:30"))
    assert (s["state"], s["since"], s["elapsed_min"]) == ("working", "09:00", 90)
    timer.pause(conn, T("2026-10-20 13:00"))
    assert timer.status(conn, T("2026-10-20 13:05"))["state"] == "break"


def test_stop_next_morning_closes_forgotten_block_at_18(conn):
    timer.start(conn, T("2026-10-19 17:00"))
    b = timer.stop(conn, T("2026-10-20 09:00"))
    assert (b.end, b.auto_closed) == ("18:00", True)
    assert db.get_block(conn, b.id).end == "18:00"


def test_late_session_is_not_auto_closed_before_6(conn):
    timer.start(conn, T("2026-10-19 22:00"))
    s = timer.status(conn, T("2026-10-20 00:30"))
    assert s["state"] == "working" and s["auto_closed"] == []
    assert s["elapsed_min"] == 150
