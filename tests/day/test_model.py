"""The day model: one JSON-ready picture of the day from every source (Task 6)."""
from dataclasses import replace
from datetime import date

from balance import db as bdb
from day import model
from tests.day.conftest import write_state


def _titles(day, layer=None):
    return [e["title"] for e in day["timeline"] if layer is None or e["layer"] == layer]


def test_timeline_merges_every_layer(ctx):
    day = model.build_day(ctx)
    assert day["date"] == "2026-11-05" and day["now"] == "09:00"
    assert _titles(day, "work") == ["Early sync", "Astrid v1 stand-up", "Model review", "Vendor demo"]
    assert _titles(day, "protected") == ["Easy Run", "Hard stop"]
    assert _titles(day, "duty") == ["School drop-off", "School pick-up"]
    assert "Dinner" in _titles(day, "personal") and "Haircut" in _titles(day, "personal")
    work = [e for e in day["timeline"] if e["layer"] == "work"]
    assert work[2]["source"] == "dashboard" and work[3]["cancelled"] is True
    assert [e["start"] for e in day["timeline"]] == sorted(e["start"] for e in day["timeline"])


def test_unknown_coverage_flags_day(ctx, state_dir):
    assert model.build_day(ctx)["mirror"] == {"unknown": False, "last_import_end": "2026-11-14", "stale_days": 8}
    write_state(state_dir, coverage_end="2026-11-04")
    assert model.build_day(ctx)["mirror"]["unknown"] is True


def test_pending_complete_marks_task_done(ctx):
    top3 = model.build_day(ctx)["work"]["top3"]
    assert [(t["id"], t["done"]) for t in top3] == [("t1", True), ("t2", False), ("t3", False)]
    assert model.build_day(ctx)["counts"] == {"done": 1, "todo": 2, "meetings_left": 2, "unclassified": 1}   # 11:00 and the cancelled 13:00 does not count


def test_first_things_order_and_fit(ctx):
    ft = model.build_day(ctx)["first_things"]
    assert ft[0]["kind"] == "duty" and ft[0]["title"] == "School drop-off" and ft[0]["owner"] == "Sam"
    assert ft[0]["fits"] is False and "Early sync" in ft[0]["fit_line"]     # 08:30–09:00 meeting overlaps 08:30–08:55
    assert ft[1]["kind"] == "meeting" and ft[1]["title"] == "Early sync" and ft[1]["prep"] is None
    assert ft[2]["kind"] == "urgent" and [t["id"] for t in ft[2]["tasks"]] == ["t1", "t3"]   # P4 due + doubt label
    pick = [x for x in ft if x.get("title") == "School pick-up"]
    assert pick == []                                                        # pick-up is not a first thing


def test_prep_note_gives_start_by(ctx):
    bdb.set_prep_note(ctx.balance_conn, "2026-11-05", "08:30", "Early sync", 30, "read the overnight report")
    ft = model.build_day(ctx)["first_things"]
    assert ft[1]["prep"] == {"minutes": 30, "text": "read the overnight report", "start_by": "08:00"}


def test_capacity_hidden_on_green(ctx, state_dir):
    assert model.build_day(ctx)["capacity"]["show"] is True
    write_state(state_dir, colour="green")
    cap = model.build_day(ctx)["capacity"]
    assert cap["colour"] == "green" and cap["show"] is False


def test_family_classification_patterns(ctx):
    cls = {e["title"]: e.get("classification") for e in model.build_day(ctx)["timeline"] if e["layer"] == "personal"}
    assert cls == {"Dinner": "mine", "Kim swimming": "child", "Haircut": "unclassified", "Doctor": "partner"}


def test_training_and_work_numbers(ctx):
    day = model.build_day(ctx)
    assert day["training"] == {"session": "Easy Run", "type": "easy", "distance_km": 8.0, "time": "07:30", "end": "08:30",
                               "time_source": "block", "block_state": "approved", "easy_week": True}
    w = day["work"]
    assert w["band"] == [30.0, 35.0] and w["week_h"] == 12.67 and w["status"]["state"] == "working"
    # 09:00 → 18:00 is 9 h, minus the meetings still ahead today (09:30–10:00, 11:00–12:00) = 7.5 h
    assert w["left_before_stop_h"] == 7.5
    assert [m["days_left"] for m in w["milestones"]] == [9, 23]


def test_rest_day_has_no_training(ctx):
    day = model.build_day(replace(ctx, date=date(2026, 11, 6)))
    assert day["training"] is None


def test_google_mirror_of_a_block_is_hidden_by_uid_not_by_calendar(ctx, state_dir):
    """The approved block is mirrored to Google and comes back through the feeds with uid <event id>@google.com."""
    import json
    bdb.update_block(ctx.balance_conn, 1, gcal_event_id="ev123", gcal_calendar="Agent")
    p = state_dir / "personal.json"
    d = json.loads(p.read_text())
    d["events"].append({"date": "2026-11-05", "start": "07:30", "end": "08:30", "all_day": False, "title": "🛡 Easy Run", "calendar": "Personal", "uid": "x@google.com"})
    d["events"].append({"date": "2026-11-05", "start": "07:30", "end": "08:30", "all_day": False, "title": "Easy Run", "calendar": "Agent", "uid": "ev123@google.com"})
    d["events"].append({"date": "2026-11-05", "start": "20:00", "end": "21:00", "all_day": False, "title": "Agent note", "calendar": "Agent", "uid": "other@google.com"})
    p.write_text(json.dumps(d))
    day = model.build_day(ctx)
    personal = [e["title"] for e in day["timeline"] if e["layer"] == "personal"]
    assert "🛡 Easy Run" not in personal and "Easy Run" not in personal
    assert "Agent note" in personal                                   # an unrelated Agent-calendar event is shown
    assert _titles(day, "protected") == ["Easy Run", "Hard stop"]


def test_training_time_prefers_the_session_sidecar_over_the_block(ctx, state_dir):
    from balance import sessions
    assert model.build_day(ctx)["training"]["time_source"] == "block"            # approved run block 07:30
    sessions.write(str(state_dir), sessions.key("2026-11-05", "Easy Run"), "13:00", "14:00")
    t = model.build_day(ctx)["training"]
    assert (t["time"], t["end"], t["time_source"]) == ("13:00", "14:00", "moved")


def test_done_writes_stay_busy_until_the_snapshot_catches_up(ctx, state_dir):
    """I6: a gcal_create drained 2 minutes ago is still not in personal.json; it must stay on the timeline."""
    import json
    q = bdb.enqueue(ctx.balance_conn, "gcal_create", {"calendar": "Personal", "date": "2026-11-05", "start": "13:00", "end": "14:00", "title": "Dentist"}, "Dentist")
    bdb.queue_mark(ctx.balance_conn, q["id"], "done")                       # applied now
    g = json.loads((state_dir / "personal.json").read_text()); g["fetched"] = "2000-01-01T00:00:00"
    (state_dir / "personal.json").write_text(json.dumps(g))
    assert any(e["title"] == "Dentist" and e.get("pending") for e in model.build_day(ctx)["timeline"])
    g["fetched"] = "2099-01-01T00:00:00"
    (state_dir / "personal.json").write_text(json.dumps(g))
    assert not any(e["title"] == "Dentist" for e in model.build_day(ctx)["timeline"])


def test_moved_session_without_a_block_is_on_the_timeline(ctx, state_dir):
    from balance import sessions
    for b in bdb.blocks_between(ctx.balance_conn, "2026-11-05", "2026-11-05"):
        if b["kind"] == "run":
            bdb.decide(ctx.balance_conn, b["id"], "rejected")
    sessions.write(str(state_dir), sessions.key("2026-11-05", "Easy Run"), "13:00", "14:00")
    ev = [e for e in model.build_day(ctx)["timeline"] if e["layer"] == "protected" and e.get("kind") == "run"]
    assert [(e["start"], e["end"], e["state"]) for e in ev] == [("13:00", "14:00", "moved")]


def test_personal_events_carry_a_lane_from_the_household(ctx):
    lanes = {e["title"]: e["lane"] for e in model.build_day(ctx)["timeline"] if e["layer"] == "personal"}
    assert lanes == {"Dinner": "personal", "Kim swimming": "family", "Haircut": "family", "Doctor": "family"}   # lane = calendar; the child classification moves it on the page
    assert model.build_day(ctx)["household"]["child"] == "Kim"


def test_school_off_day_has_no_duties_and_unknown_is_flagged(ctx, state_dir):
    import json
    (state_dir / "school_days.json").write_text(json.dumps({"from": "2026-11-01", "to": "2026-11-30", "taken": "x",
                                                            "days": {"2026-11-05": {"status": "off", "name": "Festa"}}}))
    assert [e for e in model.build_day(ctx)["timeline"] if e["layer"] == "duty"] == []
    (state_dir / "school_days.json").write_text(json.dumps({"days": {}}))
    day = model.build_day(ctx)
    assert [e for e in day["timeline"] if e["layer"] == "duty"][0]["school_status"] == "unknown"
    assert "school calendar unknown" in day["first_things"][0]["fit_line"]


def test_creator_name_from_the_household_people_map(ctx, state_dir):
    import json
    d = json.loads((state_dir / "personal.json").read_text())
    d["events"][1]["creator"] = "partner@example.com"                        # Kim swimming
    d["events"][2]["creator"] = "someone@corp.com"                           # Haircut
    (state_dir / "personal.json").write_text(json.dumps(d))
    ctx.rules["household"]["people"] = {"partner@example.com": "Robin"}
    by = {e["title"]: e.get("creator_name") for e in model.build_day(ctx)["timeline"] if e["layer"] == "personal"}
    assert by["Kim swimming"] == "Robin" and by["Haircut"] == "someone" and by["Dinner"] is None


def test_classification_precedence_overlay_then_store_then_rules_then_patterns(ctx):
    conn = ctx.balance_conn
    # Doctor has an overlay context annotation (partner) but a newer tap on the page says family: the tap wins
    bdb.set_event_class(conn, "2026-11-05", "15:00", "Doctor", "family")
    # Haircut: a per-occurrence class beats a per-title rule
    bdb.add_family_rule(conn, "haircut", "family")
    bdb.set_event_class(conn, "2026-11-05", "10:00", "Haircut", "partner")
    cls = {e["title"]: e["classification"] for e in model.build_day(ctx)["timeline"] if e["layer"] == "personal"}
    assert cls["Doctor"] == "family" and cls["Haircut"] == "partner" and cls["Kim swimming"] == "child"
    day = model.build_day(ctx)
    assert day["counts"]["unclassified"] == 0
    conn.execute("DELETE FROM event_class"); conn.execute("DELETE FROM family_rules"); conn.commit()
    assert model.build_day(ctx)["counts"]["unclassified"] == 1                   # Haircut again


def test_family_view_matches_the_day_page(ctx):
    day = model.build_day(ctx)
    view = model.family_view(ctx, [ctx.date.isoformat()])
    assert view["household"]["partner"]
    for e in day["timeline"]:
        if e["layer"] != "personal":
            continue
        got = view[(ctx.date.isoformat(), e["start"], e["title"])]
        assert got == {"classification": e["classification"], "creator_name": e["creator_name"], "lane": e["lane"]}
