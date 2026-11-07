import base64

import pytest
from fastapi.testclient import TestClient

from worklog.auth import hash_password, verify_password
from worklog.config import Settings
from worklog.web.app import create_app


def basic(user, password):
    return {"Authorization": "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()}


@pytest.fixture
def secured(tmp_path):
    app = create_app(Settings(db_path=str(tmp_path / "t.db"), auth_user="sam",
                              auth_password_hash=hash_password("s3cret:x", iterations=1000)))
    return TestClient(app)


def test_hash_roundtrip():
    h = hash_password("pw", iterations=1000)
    assert h.startswith("pbkdf2_sha256:1000:") and "$" not in h
    assert verify_password("pw", h) and not verify_password("pW", h)
    assert not verify_password("pw", "garbage") and not verify_password("pw", "md5:1:00:00")


def test_requests_need_login(secured):
    for path in ["/", "/api/status", "/static/app.js"]:
        r = secured.get(path)
        assert r.status_code == 401 and r.headers["www-authenticate"].startswith("Basic realm=")
    assert secured.post("/api/start", json={}).status_code == 401


def test_right_login_passes_and_wrong_fails(secured):
    assert secured.get("/api/status", headers=basic("sam", "s3cret:x")).status_code == 200
    assert secured.get("/api/status", headers=basic("sam", "s3cret:x")).status_code == 200  # cached path
    assert secured.get("/api/status", headers=basic("sam", "wrong")).status_code == 401
    assert secured.get("/api/status", headers=basic("bob", "s3cret:x")).status_code == 401
    assert secured.get("/api/status", headers={"Authorization": "Basic !!!"}).status_code == 401
    assert secured.get("/api/status", headers={"Authorization": "Bearer s3cret:x"}).status_code == 401


def test_healthz_stays_open(secured):
    assert secured.get("/healthz").json() == {"ok": True}


def test_no_auth_configured_is_open(client):
    assert client.get("/api/status").status_code == 200
