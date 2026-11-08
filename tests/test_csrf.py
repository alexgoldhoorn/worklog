import pytest

CROSS = {"Sec-Fetch-Site": "cross-site"}


def test_cross_site_post_is_refused(client):
    r = client.post("/api/start", headers=CROSS)
    assert r.status_code == 403
    assert client.get("/api/status").json().get("state") != "working"


def test_foreign_origin_without_fetch_metadata_is_refused(client):
    r = client.post("/api/start", headers={"Origin": "https://evil.example"})
    assert r.status_code == 403


def test_null_origin_is_refused(client):
    assert client.post("/api/start", headers={"Origin": "null"}).status_code == 403


@pytest.mark.parametrize("headers", [
    {},                                                   # curl, app, MCP, host jobs
    {"Sec-Fetch-Site": "same-origin"},
    {"Sec-Fetch-Site": "none"},
    {"Origin": "http://testserver"},                      # same host
])
def test_legitimate_post_passes(client, headers):
    assert client.post("/api/start", headers=headers).status_code == 200


def test_get_is_never_blocked(client):
    assert client.get("/api/status", headers=CROSS).status_code == 200
