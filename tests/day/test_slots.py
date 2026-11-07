"""The slot engine (plan 2, Task 3): where a run, meeting or activity fits, with reasons."""
import pytest

from day import model, slots
from day.slots import Item
from tests.day.fixtures.week import DAYS, make_ctx


@pytest.fixture
def ctx(tmp_path):
    return make_ctx(tmp_path)


def _days(ctx, dates=DAYS):
    return model.build_days(ctx, dates)


def _find(ctx, item, dates=DAYS):
    return slots.find(item, _days(ctx, dates), ctx.balance_settings, ctx.rules, ctx.date.isoformat())


def _at(found, date, start):
    return next(s for s in found if s.date == date and s.start == start)


RUN_TUE = Item(title="Easy Run", minutes=60, kind="run",
               ref={"kind": "run", "date": "2026-11-03", "start": "07:30", "end": "08:30", "session": "Easy Run", "block_id": 1})


def test_pending_queued_write_counts_as_busy(ctx):
    found = _find(ctx, Item(title="Gym", minutes=60, kind="gym"), ["2026-11-04"])
    s = _at(found, "2026-11-04", "13:00")
    assert s.verdict == "clash" and any("Dentist" in r for r in s.reasons)


def test_overlap_with_travel_is_a_clash(ctx):
    found = _find(ctx, Item(title="Dentist", minutes=45, kind="personal", travel_before=30), ["2026-11-02"])
    s = _at(found, "2026-11-02", "12:15")          # 11:45 with travel overlaps Model review 11:00–12:00
    assert s.verdict == "clash" and any("Model review" in r for r in s.reasons)
    assert _at(found, "2026-11-02", "12:30").verdict != "clash"


def test_unknown_day_is_unknown_and_ranks_below_known_days(ctx):
    found = _find(ctx, Item(title="Call", minutes=30, kind="personal"), ["2026-11-06", "2026-11-07"])
    sat = [s for s in found if s.date == "2026-11-07"]
    assert sat and all(s.verdict == "unknown" and "work calendar unknown" in s.reasons[0] for s in sat)
    assert found[0].date == "2026-11-06" and found[0].best is True
    assert all(s.date == "2026-11-06" for s in found if s.verdict == "fits")


def test_school_pickup_sam_owns_makes_the_margin_tight(ctx):
    # Thursday: pick-up at 16:15 is Sam's; leaving 16:00 → a slot ending 15:50 is within the 15-min margin
    found = _find(ctx, Item(title="Gym", minutes=50, kind="gym"), ["2026-11-05"])
    s = _at(found, "2026-11-05", "15:00")
    assert s.verdict == "tight" and any("pick-up" in r.lower() for r in s.reasons)
    assert _at(found, "2026-11-05", "16:00").verdict == "clash"          # inside the duty window itself
    # Tuesday: Robin's pick-up is context, so the same slot fits
    tue = _find(ctx, Item(title="Gym", minutes=50, kind="gym"), ["2026-11-03"])
    assert _at(tue, "2026-11-03", "15:00").verdict == "fits"


def test_run_into_work_hours_fits_only_when_the_share_is_covered(ctx):
    found = _find(ctx, RUN_TUE, ["2026-11-03"])
    noon = _at(found, "2026-11-03", "12:00")
    assert noon.verdict == "fits"                                            # Tue: 1 h run leaves > the day's share
    low = make_ctx(ctx_tmp := __import__("pathlib").Path(ctx.state_dir).parent)
    low.worklog_status["week"]["worked_h_live"] = 0.0
    low.balance_settings = dict(low.balance_settings, week_hours_min="60", week_hours_max="65")
    tight = slots.find(RUN_TUE, model.build_days(low, ["2026-11-03"]), low.balance_settings, low.rules, "2026-11-02")
    s = _at(tight, "2026-11-03", "12:00")
    assert s.verdict == "tight" and any("h left" in r or "share" in r for r in s.reasons)


def test_red_gate_makes_evening_sessions_tight(ctx):
    found = _find(ctx, RUN_TUE, ["2026-11-03"])
    s = _at(found, "2026-11-03", "18:30")
    assert s.verdict == "tight" and any("evening" in r for r in s.reasons)
    green = make_ctx(__import__("pathlib").Path(ctx.state_dir).parent, colour="green")
    ok = slots.find(RUN_TUE, model.build_days(green, ["2026-11-03"]), green.balance_settings, green.rules, "2026-11-02")
    assert _at(ok, "2026-11-03", "18:30").verdict == "fits"


def test_pre_event_week_makes_long_sessions_after_the_stop_tight(tmp_path):
    c = make_ctx(tmp_path, colour="green", pre_event={"title": "Race", "days": 5})
    long = Item(title="Long Run", minutes=120, kind="run", ref={"kind": "run", "date": "2026-11-07", "start": "08:00", "end": "10:00", "session": "Long Run"})
    found = slots.find(long, model.build_days(c, ["2026-11-04"]), c.balance_settings, c.rules, "2026-11-02")
    s = _at(found, "2026-11-04", "18:30")
    assert s.verdict == "tight" and any("Race" in r for r in s.reasons)


def test_consecutive_hard_sessions_and_rest_days_are_tight(ctx):
    intervals = Item(title="Intervals", minutes=75, kind="run", ref={"kind": "run", "date": "2026-11-05", "start": "07:30", "end": "08:45", "session": "Intervals"})
    found = _find(ctx, intervals, ["2026-11-06"])                           # Fri is a rest day
    s = _at(found, "2026-11-06", "07:00")
    assert s.verdict == "tight" and any("rest day" in r for r in s.reasons)
    found = _find(ctx, intervals, ["2026-11-04"])                           # Wed, before Thu's intervals… Wed is easy: ok
    assert _at(found, "2026-11-04", "07:00").verdict == "fits"
    long = Item(title="Long Run", minutes=120, kind="run", ref={"kind": "run", "date": "2026-11-07", "start": "08:00", "end": "10:00", "session": "Long Run"})
    found = _find(ctx, long, ["2026-11-06"])                                # Fri after Thu intervals: two hard days
    s = _at(found, "2026-11-06", "07:00")
    assert s.verdict == "tight" and any("consecutive" in r for r in s.reasons)


def test_ranking_best_current_first_and_ask_trainer(ctx):
    found = _find(ctx, RUN_TUE, ["2026-11-03"])
    assert found[0].reasons[0].startswith("current") and found[0].start == "07:30"
    rest = found[1:]
    order = {"fits": 0, "tight": 1, "unknown": 2, "clash": 3, "ask_trainer": 4}
    assert [order[s.verdict] for s in rest] == sorted(order[s.verdict] for s in rest)
    assert sum(1 for s in found if s.best) == 1 and next(s for s in found if s.best).verdict in ("fits", "tight")
    ask = [s for s in found if s.verdict == "ask_trainer"]
    assert len(ask) == 1 and ask[0].date == "2026-11-04" and ask[0].start == "07:30"
    fits = next(s for s in rest if s.verdict == "fits")
    assert fits.changes and fits.changes[0]["kind"] == "session_time" and fits.changes[0]["session"] == "Easy Run"


def test_own_occurrence_is_ignored_when_moving(ctx):
    found = _find(ctx, RUN_TUE, ["2026-11-03"])
    assert _at(found, "2026-11-03", "07:30").verdict != "clash"              # its own block is not a clash
    personal = Item(title="Dinner out", minutes=60, kind="personal",
                    ref={"kind": "personal", "date": "2026-11-03", "start": "20:00", "end": "21:00", "uid": "din@google.com", "calendar": "Personal"})
    found = _find(ctx, personal, ["2026-11-03"])
    s = _at(found, "2026-11-03", "20:30")
    assert s.verdict != "clash" and s.changes[0]["kind"] == "gcal_update" and s.changes[0]["uid"] == "din@google.com"


def test_same_ranking_for_page_and_pa(ctx):
    a = _find(ctx, RUN_TUE, ["2026-11-03"])
    b = slots.find(RUN_TUE, model.build_days(ctx, ["2026-11-03"]), ctx.balance_settings, ctx.rules, "2026-11-02")
    assert [(s.date, s.start, s.verdict, s.best) for s in a] == [(s.date, s.start, s.verdict, s.best) for s in b]


def test_prefer_not_school_runs_and_afternoons(ctx):
    found = _find(ctx, Item(title="Call", minutes=30, kind="personal", prefer=["afternoon", "not_school_runs"]), ["2026-11-05"])
    assert all("12:00" <= s.start < "18:00" for s in found)
    assert not any(s.start in ("16:00", "16:15") for s in found)


def test_work_share_is_the_weeks_remaining_floor_over_the_work_days_left(ctx):
    """I3: the share is the same for every remaining day of this week, and never inflates."""
    from day.slots import work_share
    days = _days(ctx, ["2026-11-04", "2026-11-05", "2026-11-06"])
    # Monday 09:00 with 0.97 h done, floor 30: (30 − 0.97) / 5 work days left ≈ 5.8 h for every day this week
    for d in days.values():
        assert abs(work_share(d, ctx.balance_settings, today="2026-11-02", client_holidays={}) - 5.81) < 0.05
    nxt = _days(ctx, ["2026-11-10"])["2026-11-10"]
    assert abs(work_share(nxt, ctx.balance_settings, today="2026-11-02", client_holidays={}) - 6.0) < 0.01   # next week: 30 / 5
    found = _find(ctx, Item(title="Gym", minutes=60, kind="gym"), ["2026-11-06"])
    noon = _at(found, "2026-11-06", "12:00")
    assert noon.verdict == "fits"                                            # Fri has 1.5 h of meetings: 9.5 − 1.5 − 1 h > 5.8


def test_past_slots_are_never_offered_today(ctx):
    found = slots.find(Item(title="Call", minutes=30, kind="personal"), _days(ctx, ["2026-11-02"]),
                       ctx.balance_settings, ctx.rules, "2026-11-02", now="09:10")
    assert all(s.start >= "09:15" for s in found if s.date == "2026-11-02")
    assert found[0].best and found[0].start >= "09:15"


def test_unclassified_family_event_makes_the_slot_tight(ctx):
    found = _find(ctx, Item(title="Call", minutes=30, kind="personal"), ["2026-11-03"])
    s = _at(found, "2026-11-03", "10:00")                                    # Haircut, Family, unclassified
    assert s.verdict == "tight" and any("may not need you" in r for r in s.reasons)


def test_partner_classified_event_is_context_for_the_engine(ctx):
    from balance import db as bdb
    bdb.set_event_class(ctx.balance_conn, "2026-11-03", "10:00", "Haircut", "partner")
    found = _find(ctx, Item(title="Call", minutes=30, kind="personal"), ["2026-11-03"])
    assert _at(found, "2026-11-03", "10:00").verdict == "fits"
