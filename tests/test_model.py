from worklog import db, model


def test_work_type_uses_break_list():
    assert model.work_type("eat", {"eat"}) == "other"
    assert model.work_type("Dev", {"eat"}) == "work"


def test_minutes_wall_clock_including_dst_night():
    assert model.minutes("09:10", "10:00") == 50
    assert model.minutes("02:30", "03:30") == 60      # 2026-10-25 fall-back night: still 60
    assert model.minutes("10:00", "09:40") == -20
    assert model.minutes("10:00", None) is None
    assert model.hours(72) == 1.2 and model.hours(None) == 0.0
    assert model.hhmm(72) == "01:12" and model.hhmm(-20) == "-00:20"


def test_calendar_keys():
    assert model.excel_weekday("2026-10-18") == 1       # Sunday
    assert model.excel_weekday("2026-10-20") == 3
    assert model.is_workday("2026-10-20") and not model.is_workday("2026-10-18")
    assert model.week_key("2026-03-01") == "2026-09"    # Sunday closes ISO week 9
    assert model.week_key("2026-10-20") == "2026-43"   # 2026-10-12..18 is week 42
    assert model.week_key("2027-01-01") == "2026-53"    # ISO, not Excel WEEKNUM
    assert model.month_key("2026-10-20") == "2026-10"
    assert model.quarter_key("2026-10-20") == "2026-Q4"
    assert model.year_key("2026-10-20") == "2026"
    assert model.week_bounds("2026-42") == ("2026-10-12", "2026-10-18")


def test_flags_mark_overlap_and_reversed():
    a = db.Block(1, "2026-03-03", "09:00", "10:30", None, "dev", "ACME", True)
    b = db.Block(2, "2026-03-03", "10:00", "11:12", "trainings", "study", "ACME", True)
    c = db.Block(3, "2026-03-03", "12:00", "11:00", None, "dev", "ACME", True)
    f = model.flags([a, b, c])
    assert f[1] == {"start_gt_end": False, "overlap": False}
    assert f[2]["overlap"] and not f[2]["start_gt_end"]
    assert f[3]["start_gt_end"] and not f[3]["overlap"]


def test_with_derived():
    b = db.Block(1, "2026-10-20", "09:00", "10:12", None, "Eat", "X", True)
    d = model.with_derived(b, {"eat"})
    assert d["work_type"] == "other" and d["minutes"] == 72
    assert d["duration_h"] == 1.2 and d["duration"] == "01:12"
    assert d["week_day"] == 3 and d["is_workday"] is True
    assert d["week"] == "2026-43" and d["year_week"] == "2026-43"
    assert d["source"] == "timer" and d["auto_closed"] is False
    o = model.with_derived(db.Block(2, "2026-10-20", "09:00", None, None, "dev", None, None), set())
    assert o["minutes"] is None and o["duration_h"] is None and o["duration"] is None


def test_overlap_flag_uses_latest_end_and_pairs():
    from worklog.db import Block
    bs = [Block(1, "2026-10-20", "13:40", "16:50", None, "dev", None, None, "timer"),
          Block(2, "2026-10-20", "16:04", "17:19", None, "dev", None, None, "timer"),
          Block(3, "2026-10-20", "16:50", "17:05", None, "eat", None, None, "manual"),
          Block(4, "2026-10-20", "17:19", None, None, "dev", None, None, "timer")]
    f = model.flags(bs)
    assert [f[i]["overlap"] for i in (1, 2, 3, 4)] == [False, True, True, False]
    assert [(a.id, b.id) for a, b in model.overlaps(bs)] == [(1, 2), (2, 3)]
