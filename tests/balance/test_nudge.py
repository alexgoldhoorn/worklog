from datetime import datetime
from balance import nudge
from balance.config import DEFAULT_RULES

def status(**kw):
    base = {"state": "working", "date": "2026-11-04", "since": "09:20", "hard_stop": "18:00",
            "past_stop_min": 212, "today": {"work_h_live": 8.17}}
    base.update(kw); return base

NOW = datetime(2026, 11, 4, 21, 32)

def test_first_nudge_after_the_grace():
    assert nudge.decide(status(), {}, NOW, DEFAULT_RULES) == "nudge"
    assert nudge.decide(status(past_stop_min=20), {}, NOW, DEFAULT_RULES) is None
    assert nudge.decide(status(state="break"), {}, NOW, DEFAULT_RULES) is None
    assert nudge.decide(status(past_stop_min=None), {}, NOW, DEFAULT_RULES) is None

def test_one_message_an_evening_unless_snoozed():
    sent = {"date": "2026-11-04", "sent": 1, "last_sent": "21:00", "snooze_until": None}
    assert nudge.decide(status(), sent, NOW, DEFAULT_RULES) is None
    snoozed = {**sent, "snooze_until": "21:30"}
    assert nudge.decide(status(), snoozed, NOW, DEFAULT_RULES) == "nudge"
    assert nudge.decide(status(), {**sent, "snooze_until": "21:40"}, NOW, DEFAULT_RULES) is None
    assert nudge.decide(status(), {**snoozed, "sent": 2}, NOW, DEFAULT_RULES) is None

def test_message_text_and_buttons():
    text, markup = nudge.message(status(), NOW)
    assert text == "⏱ Still working at 21:32 · 3 h 32 past your 18:00 stop · today 8 h 10"
    row = markup["inline_keyboard"][0]
    assert [b["text"] for b in row] == ["Stop now", "30 more min"]
    assert [b["callback_data"] for b in row] == ["balance:2026-11-04:stop", "balance:2026-11-04:snooze"]

def test_tick_sends_once_and_records_state(tmp_path):
    sent = []
    r = nudge.tick({}, str(tmp_path), NOW, fetch=lambda env: status(), sender=lambda t, m: sent.append((t, m)))
    assert r["sent"] and len(sent) == 1
    st = nudge.load_state(str(tmp_path))
    assert st == {"date": "2026-11-04", "sent": 1, "last_sent": "21:32", "snooze_until": None}
    r = nudge.tick({}, str(tmp_path), NOW, fetch=lambda env: status(), sender=lambda t, m: sent.append((t, m)))
    assert not r["sent"] and len(sent) == 1

def test_tick_resets_state_on_a_new_day(tmp_path):
    nudge.save_state(str(tmp_path), {"date": "2026-11-03", "sent": 2, "last_sent": "22:00", "snooze_until": None})
    sent = []
    assert nudge.tick({}, str(tmp_path), NOW, fetch=lambda env: status(), sender=lambda t, m: sent.append(t))["sent"]

def test_unreachable_worklog_sends_nothing(tmp_path):
    def boom(env): raise OSError("connection refused")
    r = nudge.tick({}, str(tmp_path), NOW, fetch=boom, sender=lambda t, m: (_ for _ in ()).throw(AssertionError))
    assert not r["sent"] and "unreachable" in r["reason"]
    assert not (tmp_path / "nudge.json").exists()

def test_tap_snooze_then_stop(tmp_path):
    nudge.save_state(str(tmp_path), {"date": "2026-11-04", "sent": 1, "last_sent": "21:32", "snooze_until": None})
    reply = nudge.handle_tap("balance:2026-11-04:snooze", {}, NOW, str(tmp_path))
    assert reply == "OK, 30 more minutes. I will ask once more."
    assert nudge.load_state(str(tmp_path))["snooze_until"] == "22:02"
    stopped = []
    reply = nudge.handle_tap("balance:2026-11-04:stop", {}, NOW, str(tmp_path),
                             fetch=lambda env: status(),
                             stop=lambda env: stopped.append(1) or {"state": "stopped", "today": {"work_h": 8.2}})
    assert stopped and reply == "Stopped at 21:32 · today 8 h 12"

def test_tap_on_a_stale_message_does_nothing(tmp_path):
    reply = nudge.handle_tap("balance:2026-11-03:stop", {}, NOW, str(tmp_path),
                             stop=lambda env: (_ for _ in ()).throw(AssertionError))
    assert reply == "That nudge was for 2026-11-03; nothing changed."
    assert nudge.handle_tap("coach:2026-11-04:load:ok", {}, NOW, str(tmp_path)) is None

def test_past_stop_exactly_at_the_grace_nudges():
    assert nudge.decide(status(past_stop_min=30), {}, NOW, DEFAULT_RULES) == "nudge"

def test_tick_sends_the_second_nudge_after_snooze_expires(tmp_path):
    nudge.save_state(str(tmp_path), {"date": "2026-11-04", "sent": 1, "last_sent": "21:00", "snooze_until": "21:30"})
    sent = []
    r = nudge.tick({}, str(tmp_path), NOW, fetch=lambda env: status(), sender=lambda t, m: sent.append(t))
    assert r["sent"] and len(sent) == 1
    assert nudge.load_state(str(tmp_path))["sent"] == 2

def test_two_nudges_are_the_limit():
    st = {"date": "2026-11-04", "sent": 2, "last_sent": "21:30", "snooze_until": "21:00"}
    assert nudge.decide(status(), st, NOW, DEFAULT_RULES) is None

def test_snooze_clamps_at_end_of_day(tmp_path):
    late = datetime(2026, 11, 4, 23, 45)
    nudge.handle_tap("balance:2026-11-04:snooze", {}, late, str(tmp_path))
    assert nudge.load_state(str(tmp_path))["snooze_until"] == "23:59"

def test_snooze_uses_rules_override(tmp_path):
    reply = nudge.handle_tap("balance:2026-11-04:snooze", {}, NOW, str(tmp_path),
                             rules={"nudge_snooze_min": 45})
    assert nudge.load_state(str(tmp_path))["snooze_until"] == "22:17"
    assert "45 more minutes" in reply


def test_stop_tap_after_midnight_is_honoured(tmp_path):
    after = datetime(2026, 11, 5, 0, 10)
    stopped = []
    reply = nudge.handle_tap("balance:2026-11-04:stop", {}, after, str(tmp_path),
                             fetch=lambda env: status(),
                             stop=lambda env: stopped.append(1) or {"today": {"work_h": 8.2}})
    assert stopped and reply == "Stopped at 00:10 · today 8 h 12"
    reply = nudge.handle_tap("balance:2026-11-03:stop", {}, after, str(tmp_path),
                             stop=lambda env: (_ for _ in ()).throw(AssertionError))
    assert reply == "That nudge was for 2026-11-03; nothing changed."
    reply = nudge.handle_tap("balance:2026-11-04:snooze", {}, after, str(tmp_path))
    assert reply == "That nudge was for 2026-11-04; nothing changed."


def test_tick_honours_config_rules(tmp_path, monkeypatch):
    monkeypatch.setattr(nudge, "load_rules", lambda: {**DEFAULT_RULES, "nudge_after_min": 300})
    sent = []
    r = nudge.tick({}, str(tmp_path), NOW, fetch=lambda env: status(),
                   sender=lambda t, m: sent.append(t))
    assert not r["sent"] and not sent


def test_stop_tap_when_nothing_running(tmp_path):
    reply = nudge.handle_tap("balance:2026-11-04:stop", {}, NOW, str(tmp_path),
                             fetch=lambda env: {"state": "stopped", "today": {"work_h": 8.2}},
                             stop=lambda env: (_ for _ in ()).throw(AssertionError))
    assert reply == "Nothing was running · today 8 h 12"


def test_snooze_after_second_message(tmp_path):
    nudge.save_state(str(tmp_path), {"date": "2026-11-04", "sent": 2, "last_sent": "21:00"})
    reply = nudge.handle_tap("balance:2026-11-04:snooze", {}, NOW, str(tmp_path))
    assert reply == "OK, no more reminders tonight."
    assert nudge.load_state(str(tmp_path))["snooze_until"]
