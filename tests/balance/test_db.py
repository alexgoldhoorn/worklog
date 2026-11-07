"""Classification store for Family events (plan 3, Task 3)."""
from balance import db


def test_event_class_roundtrip_and_overwrite():
    conn = db.connect(":memory:")
    db.set_event_class(conn, "2026-11-03", "10:00", "Haircut", "partner")
    db.set_event_class(conn, "2026-11-03", "10:00", "Haircut", "family")
    assert db.get_event_classes(conn, "2026-11-03") == {("10:00", "Haircut"): "family"}
    assert db.get_event_classes(conn, "2026-11-04") == {}


def test_family_rules_are_case_insensitive_substrings_in_order():
    conn = db.connect(":memory:")
    a = db.add_family_rule(conn, "haircut", "partner")
    db.add_family_rule(conn, "Swimming", "child")
    rules = db.family_rules(conn)
    assert [(r["pattern"], r["cls"]) for r in rules] == [("haircut", "partner"), ("Swimming", "child")]
    assert a["id"] == rules[0]["id"]
    assert db.add_family_rule(conn, "haircut", "family")["cls"] == "family"      # same pattern: updated, not duplicated
    assert [(r["pattern"], r["cls"]) for r in db.family_rules(conn)] == [("haircut", "family"), ("Swimming", "child")]
