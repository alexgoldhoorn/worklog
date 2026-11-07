"""HTTP Basic auth for the whole app (browser, Qt client, MCP), except /healthz.

The password is stored as a PBKDF2 hash (`pbkdf2_sha256:<iterations>:<salt hex>:<hash hex>`;
colons, not `$`, so a compose env_file never interpolates it). Print one with
`python -m worklog.auth`. A header that verified once is remembered by its SHA-256, so the
deliberately slow hash runs once per client, not once per request.
"""
import base64
import binascii
import getpass
import hashlib
import hmac
import secrets
import sys

ITERATIONS = 600_000
OPEN_PATHS = {"/healthz"}


def hash_password(password: str, iterations: int = ITERATIONS) -> str:
    salt = secrets.token_bytes(16)
    dk = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    return f"pbkdf2_sha256:{iterations}:{salt.hex()}:{dk.hex()}"


def verify_password(password: str, stored: str) -> bool:
    try:
        algo, iterations, salt, want = stored.split(":")
        if algo != "pbkdf2_sha256":
            return False
        dk = hashlib.pbkdf2_hmac("sha256", password.encode(), bytes.fromhex(salt), int(iterations))
    except ValueError:
        return False
    return hmac.compare_digest(dk.hex(), want)


class BasicAuth:
    """ASGI middleware; every HTTP request but OPEN_PATHS needs `Authorization: Basic`."""

    def __init__(self, app, user: str, password_hash: str):
        self.app = app
        self.user = user
        self.password_hash = password_hash
        self._ok: set[str] = set()

    def _allowed(self, header: str) -> bool:
        key = hashlib.sha256(header.encode()).hexdigest()
        if key in self._ok:
            return True
        scheme, _, token = header.partition(" ")
        if scheme.lower() != "basic":
            return False
        try:
            user, sep, password = base64.b64decode(token, validate=True).decode().partition(":")
        except (binascii.Error, UnicodeDecodeError):
            return False
        if not sep or not hmac.compare_digest(user, self.user) or not verify_password(password, self.password_hash):
            return False
        self._ok.add(key)
        return True

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["path"] in OPEN_PATHS:
            return await self.app(scope, receive, send)
        headers = dict(scope["headers"])
        header = headers.get(b"authorization", b"").decode("latin-1")
        if header and self._allowed(header):
            return await self.app(scope, receive, send)
        await send({"type": "http.response.start", "status": 401,
                    "headers": [(b"content-type", b"application/json"),
                                (b"www-authenticate", b'Basic realm="worklog", charset="UTF-8"')]})
        await send({"type": "http.response.body", "body": b'{"error":"login required"}'})


if __name__ == "__main__":
    pw = sys.argv[1] if len(sys.argv) > 1 else getpass.getpass("worklog password: ")
    print(hash_password(pw))
