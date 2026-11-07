from datetime import date, timedelta

from balance.config import DEFAULT_RULES
from balance.gate import Inputs, evaluate, telegram_line

T = date(2026, 11, 2)


def wellness(days=120, rhr=41, hrv=60, sleep_h=7.2, score=80, stress=25, **last7):
    rows = []
    for i in range(days):
        d = T - timedelta(days=i)
        r = {"date": d, "resting_hr": rhr, "hrv": hrv, "sleep_h": sleep_h, "sleep_score": score, "stress": stress}
        if i < 7:
            r.update(last7)
        rows.append(r)
    return rows


def hours(per_day, days=21):
    """per_day hours on every weekday of the `days` days ending yesterday."""
    return {T - timedelta(days=i): per_day for i in range(1, days + 1) if (T - timedelta(days=i)).weekday() < 5}


def test_green_when_everything_is_normal():
    v = evaluate(Inputs(T, work_hours=hours(6.5), wellness=wellness()), DEFAULT_RULES)
    assert v.colour == "green" and v.signals == [] and not v.speak
    assert telegram_line(v) == "🟢 Capacity: green."


def test_missing_data_is_a_gap_not_a_signal():
    v = evaluate(Inputs(T), DEFAULT_RULES)
    assert v.colour == "green"
    assert "no worklog hours" in v.gaps and "no Garmin wellness" in v.gaps


def test_work_and_body_together_is_red():
    v = evaluate(Inputs(T, work_hours=hours(8.5), wellness=wellness(rhr=41, resting_hr=45)), DEFAULT_RULES)
    names = {s["name"] for s in v.signals}
    assert "hours" in names and "rhr" in names
    assert v.colour == "red" and v.speak


def test_two_work_signals_alone_is_amber_and_speaks_once_a_week():
    evening = {T - timedelta(days=i) for i in range(4)}
    inp = Inputs(T, work_hours=hours(8.5, days=7), wellness=wellness(), evening_days=evening)
    v = evaluate(inp, DEFAULT_RULES)
    assert v.colour == "amber" and v.speak
    assert v.protect.startswith("a hard stop at 18:00")
    v2 = evaluate(inp, DEFAULT_RULES, last_spoken={"amber": (T - timedelta(days=3)).isoformat()})
    assert not v2.speak
    v3 = evaluate(inp, DEFAULT_RULES, last_spoken={"amber": (T - timedelta(days=8)).isoformat()})
    assert v3.speak


def test_pre_event_window_is_stricter():
    ev = [{"date": T + timedelta(days=5), "title": "Jean Bouin 5K", "kind": "race"}]
    v = evaluate(Inputs(T, work_hours=hours(8.5, days=7), wellness=wellness(), events=ev), DEFAULT_RULES)
    assert v.colour == "amber" and v.pre_event["days"] == 5
    assert "Jean Bouin 5K is in 5 days" in telegram_line(v)
    far = [{"date": T + timedelta(days=20), "title": "x", "kind": "race"}]
    v2 = evaluate(Inputs(T, work_hours=hours(8.5, days=7), wellness=wellness(), events=far), DEFAULT_RULES)
    assert v2.colour == "green" and v2.pre_event is None


def test_runs_signal_skipped_while_ill():
    planned = [T - timedelta(days=i) for i in (1, 3, 5, 8, 10)]
    base = dict(work_hours=hours(6), wellness=wellness(), runs_planned=planned, runs_done=[T - timedelta(days=1)])
    v = evaluate(Inputs(T, **base), DEFAULT_RULES)
    assert any(s["name"] == "runs" for s in v.signals)
    v2 = evaluate(Inputs(T, illness_open=True, **base), DEFAULT_RULES)
    assert not any(s["name"] == "runs" for s in v2.signals) and v2.numbers["illness_open"]


def test_felt_heavy_escalates():
    felt = [{"date": T - timedelta(days=i), "answer": "heavy"} for i in range(3)]
    v = evaluate(Inputs(T, work_hours=hours(8.5, days=7), wellness=wellness(), felt=felt), DEFAULT_RULES)
    assert {s["name"] for s in v.signals} == {"hours", "felt"}
    assert v.colour == "red"


def test_baseline_needs_history():
    v = evaluate(Inputs(T, work_hours=hours(6), wellness=wellness(days=10, resting_hr=50)), DEFAULT_RULES)
    assert v.numbers["rhr_base"] is None and not any(s["name"] == "rhr" for s in v.signals)


def test_work_windows_end_yesterday_and_same_day_rerun_keeps_speaking():
    # 8.5 h on every weekday up to yesterday, nothing today: still a full week
    wh = {T - timedelta(days=i): 8.5 for i in range(1, 8) if (T - timedelta(days=i)).weekday() < 5}
    v = evaluate(Inputs(T, work_hours=wh, wellness=wellness()), DEFAULT_RULES)
    assert v.numbers["hours_7d"] == 42.5
    evening = {T - timedelta(days=i) for i in range(1, 5)}
    inp = Inputs(T, work_hours=wh, wellness=wellness(), evening_days=evening)
    v = evaluate(inp, DEFAULT_RULES, last_spoken={"amber": T.isoformat()})
    assert v.colour == "amber" and v.speak


def test_felt_double_tap_counts_once(tmp_path):
    import json
    from balance.inputs import read_felt
    p = tmp_path / "load.jsonl"
    p.write_text("\n".join(json.dumps({"date": "2026-11-01", "answer": a}) for a in ("heavy", "heavy", "ok")) + "\n")
    assert read_felt(str(tmp_path), T) == [{"date": date(2026, 11, 1), "answer": "ok"}]
