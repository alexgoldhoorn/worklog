"""Care duties: the school run synthesised from rules, overridden per date by the overlay (Task 5)."""
from datetime import date

from day import duties, rules

RULES = rules.load(rules.EXAMPLE_PATH)


def _one(d, holidays=None, overlay=None, name="School drop-off"):
    return [x for x in duties.for_day(d, RULES, holidays or {}, overlay or {"one_off": []}) if x["title"] == name]


def test_weekday_default_and_thursday_override():
    tue = _one(date(2026, 11, 3))[0]
    thu = _one(date(2026, 11, 5))[0]
    assert (tue["owner"], tue["owner_source"]) == ("Robin", "rule")
    assert (thu["owner"], thu["owner_source"]) == ("Sam", "weekday")


def test_overlay_owner_wins():
    overlay = {"one_off": [{"date": "2026-11-05", "start": "08:45", "title": "School drop-off", "owner": "Robin", "tier": None, "note": None}]}
    thu = _one(date(2026, 11, 5), overlay=overlay)[0]
    assert (thu["owner"], thu["owner_source"]) == ("Robin", "overlay")


def test_no_duty_on_holiday_or_weekend():
    assert _one(date(2026, 11, 3), holidays={"2026-11-03": "Festa"}) == []
    assert _one(date(2026, 11, 7)) == []                       # Saturday
    assert len(duties.for_day(date(2026, 11, 3), RULES, {}, {"one_off": []})) == 2


def test_window_and_travel():
    d = _one(date(2026, 11, 3))[0]
    assert (d["start"], d["at"], d["end"]) == ("08:30", "08:45", "08:55")
    assert d["tier"] == "context" and d["kind"] == "duty" and d["date"] == "2026-11-03"
    p = _one(date(2026, 11, 3), name="School pick-up")[0]
    assert (p["start"], p["at"], p["end"]) == ("16:00", "16:15", "16:25")


def test_rules_file_has_the_spec_values():
    assert RULES["me"] == "Sam"
    names = [d["name"] for d in RULES["duties"]]
    assert names == ["School drop-off", "School pick-up"]
    assert RULES["duties"][0]["owner_by_weekday"] == {"3": "Sam"}


def test_school_closure_and_free_day_drop_the_duties():
    school = {"2026-11-03": {"status": "off", "name": "Festa de lliure disposició"}, "2026-11-04": {"status": "school", "name": ""}}
    assert duties.for_day(date(2026, 11, 3), RULES, {}, {"one_off": []}, school=school) == []
    assert len(duties.for_day(date(2026, 11, 4), RULES, {}, {"one_off": []}, school=school)) == 2


def test_unknown_school_calendar_keeps_the_duties_flagged():
    school = {"2026-11-03": {"status": "unknown", "name": "no school calendar on file"}}
    d = duties.for_day(date(2026, 11, 3), RULES, {}, {"one_off": []}, school=school)
    assert len(d) == 2 and all(x["school_status"] == "unknown" for x in d)
    none = duties.for_day(date(2026, 11, 3), RULES, {}, {"one_off": []}, school={})      # date absent from the snapshot
    assert all(x["school_status"] == "unknown" for x in none)
    known = duties.for_day(date(2026, 11, 4), RULES, {}, {"one_off": []}, school={"2026-11-04": {"status": "school", "name": ""}})
    assert all(x["school_status"] == "school" for x in known)
