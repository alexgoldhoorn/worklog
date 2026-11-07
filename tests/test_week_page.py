"""The balance week page and its API live inside the worklog app (Task 2)."""


def test_week_page_renders_with_nav(client):
    r = client.get("/week")
    assert r.status_code == 200
    assert 'href="/week"' in r.text and 'href="/timer"' in r.text
    assert 'id="week"' in r.text and 'id="gate"' in r.text


def test_balance_api_is_namespaced(client):
    assert client.get("/api/balance/week").status_code == 200
    assert client.get("/api/week").status_code == 404


def test_worklog_blocks_api_untouched(client):
    assert client.get("/api/day/2026-10-20").status_code == 200


def test_timer_page_available_at_timer(client):
    r = client.get("/timer")
    assert r.status_code == 200 and 'id="blocks"' in r.text
