"""Household config (plan 3, Task 0): no personal names in code; another household works unchanged."""
import json
from dataclasses import replace

from day import duties, model, rules
from tests.day.fixtures.week import make_ctx


def test_household_defaults_and_file_values(tmp_path):
    h = rules.household(rules.load())
    assert h["me"] == "Sam" and h["partner"] == "Robin" and h["child"] == "Kim"
    assert h["calendars"] == {"personal": "Personal", "family": "Family", "child": "Kim", "agent": "Agent"}
    assert h["timezone"] == "Europe/Amsterdam" and "you" in h["me_aliases"] and h["people"].get("robin@example.com") == "Robin"
    bare = tmp_path / "r.json"; bare.write_text("{}")
    h2 = rules.household(rules.load(str(bare)))
    assert set(h2) == set(h) and h2["me"] == "me" and h2["calendars"]["family"] == "Family"


def test_another_household_renames_every_lane_and_owner(tmp_path):
    other = json.loads(open(rules.EXAMPLE_PATH).read())
    other["household"] = {"me": "Bo", "me_aliases": ["you"], "partner": "Kim", "child": "Ida",
                          "calendars": {"personal": "Me", "family": "Home", "child": "Ida", "agent": "Bot"},
                          "timezone": "Europe/Oslo", "people": {}}
    other["duties"][0]["default_owner"] = "Kim"; other["duties"][0]["owner_by_weekday"] = {"3": "Bo"}
    p = tmp_path / "other.json"; p.write_text(json.dumps(other))
    ctx = make_ctx(tmp_path)
    ctx = replace(ctx, rules=rules.load(str(p)))
    # rename the fixture's calendars to the other household's
    import json as _j
    pj = tmp_path / "state" / "personal.json"; d = _j.loads(pj.read_text())
    for e in d["events"]:
        e["calendar"] = {"Family": "Home", "Personal": "Me", "Kim": "Ida"}.get(e["calendar"], e["calendar"])
    pj.write_text(_j.dumps(d))
    day = model.build_day(replace(ctx, date=ctx.date.replace(day=3)))   # Tue
    lanes = {e["title"]: e["lane"] for e in day["timeline"] if e["layer"] == "personal"}
    assert lanes["Haircut"] == "family" and lanes["Dinner out"] == "personal"
    thu = model.build_day(replace(ctx, date=ctx.date.replace(day=5)))
    duty = [e for e in thu["timeline"] if e["layer"] == "duty"][0]
    assert duty["owner"] == "Bo"
    assert day["household"]["partner"] == "Kim" and day["household"]["me"] == "Bo"
    ov = {"one_off": [{"date": "2026-11-03", "start": "08:45", "title": "School drop-off", "owner": "you", "tier": None, "note": None}]}
    d3 = duties.for_day(ctx.date.replace(day=3), rules.load(str(p)), {}, ov)
    assert d3[0]["owner"] == "Bo"                                              # "you" means me, whoever me is


def test_without_any_rules_file_the_neutral_defaults_apply(monkeypatch, tmp_path):
    monkeypatch.delenv("DAY_RULES")
    monkeypatch.setattr(rules, "DEFAULT_PATH", str(tmp_path / "absent.json"))
    r = rules.load()
    assert r["duties"] == [] and rules.household(r)["me"] == "me" and r["slots"]["step_min"] == 15
    r["duties"].append("x")
    assert rules.load()["duties"] == []          # a fresh copy each time


def test_a_local_rules_file_beside_the_module_is_still_honoured(monkeypatch, tmp_path):
    monkeypatch.delenv("DAY_RULES")
    p = tmp_path / "rules.json"; p.write_text('{"me": "Ann"}')
    monkeypatch.setattr(rules, "DEFAULT_PATH", str(p))
    assert rules.load()["me"] == "Ann"


def test_a_missing_day_rules_path_fails_clearly(monkeypatch, tmp_path):
    import pytest
    monkeypatch.setenv("DAY_RULES", str(tmp_path / "nope.json"))
    with pytest.raises(FileNotFoundError, match="DAY_RULES"):
        rules.load()
