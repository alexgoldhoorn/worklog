from datetime import datetime

from day.web import _save_into_inbox


def _post(client, data):
    return client.post("/api/day/calendar-pdf", files={"file": ("cal.pdf", data, "application/pdf")})


def test_inbox_name_uses_the_configured_clock_and_leaves_no_temp_file(client, app, tmp_path):
    inbox = tmp_path / "inbox"
    inbox.mkdir()
    app.state.settings.calendar_inbox = str(inbox)
    app.state.clock = lambda: datetime(2031, 1, 2, 23, 59)
    r = _post(client, b"%PDF-1 one")
    assert r.json()["saved"] == "2031-01-02_cal.pdf"
    assert [p.name for p in inbox.iterdir()] == ["2031-01-02_cal.pdf"]


def test_inbox_never_overwrites_a_different_file(client, app, tmp_path):
    inbox = tmp_path / "inbox"
    inbox.mkdir()
    app.state.settings.calendar_inbox = str(inbox)
    app.state.clock = lambda: datetime(2031, 1, 2, 9, 0)
    assert _post(client, b"%PDF-1 one").json()["saved"] == "2031-01-02_cal.pdf"
    assert _post(client, b"%PDF-1 two").json()["saved"] == "2031-01-02_cal-1.pdf"
    assert _post(client, b"%PDF-1 three").json()["saved"] == "2031-01-02_cal-2.pdf"
    assert _post(client, b"%PDF-1 two").json()["saved"] == "2031-01-02_cal-1.pdf"   # same content: kept, not duplicated
    assert (inbox / "2031-01-02_cal.pdf").read_bytes() == b"%PDF-1 one"
    assert sorted(p.name for p in inbox.iterdir()) == [
        "2031-01-02_cal-1.pdf", "2031-01-02_cal-2.pdf", "2031-01-02_cal.pdf"]


def test_save_into_inbox_cleans_up_when_the_inbox_is_missing(tmp_path):
    import pytest
    with pytest.raises(OSError):
        _save_into_inbox(str(tmp_path / "nope"), "a.pdf", b"%PDF")
