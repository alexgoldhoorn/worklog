"""HTTP Basic auth for the whole app (browser, Qt client, MCP), except /healthz.

The password is stored as a PBKDF2 hash (`pbkdf2_sha256:<iterations>:<salt hex>:<hash hex>`;
colons, not `$`, so a compose env_file never interpolates it). Print one with
`python -m worklog.auth`. A header that verified once is remembered by its SHA-256, so the
deliberately slow hash runs once per client, not once per request. A header that failed is
remembered for a minute too, so a client retrying a wrong password costs nothing. The hash runs
in a worker thread (never on the event loop), at most two at a time.
"""
import asyncio
import base64
import binascii
import getpass
import hashlib
import hmac
import secrets
import sys
import time
from collections import OrderedDict

ITERATIONS = 600_000
OPEN_PATHS = {"/healthz"}
MAX_VERIFICATIONS = 2          # PBKDF2 runs at once
FAIL_MEMORY_S = 60             # how long a failed header is remembered
FAIL_MEMORY_MAX = 1024         # how many failed headers are remembered


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
        self._bad: OrderedDict[str, float] = OrderedDict()
        self._sem: asyncio.Semaphore | None = None
        self._sem_loop = None

    def _semaphore(self) -> asyncio.Semaphore:
        loop = asyncio.get_running_loop()
        if self._sem is None or self._sem_loop is not loop:
            self._sem, self._sem_loop = asyncio.Semaphore(MAX_VERIFICATIONS), loop
        return self._sem

    def _remember_bad(self, key: str) -> None:
        self._bad[key] = time.monotonic()
        self._bad.move_to_end(key)
        while len(self._bad) > FAIL_MEMORY_MAX:
            self._bad.popitem(last=False)

    async def _allowed(self, header: str) -> bool:
        key = hashlib.sha256(header.encode()).hexdigest()
        if key in self._ok:
            return True
        failed_at = self._bad.get(key)
        if failed_at is not None:
            if time.monotonic() - failed_at < FAIL_MEMORY_S:
                return False
            del self._bad[key]
        scheme, _, token = header.partition(" ")
        if scheme.lower() != "basic":
            return False
        try:
            user, sep, password = base64.b64decode(token, validate=True).decode().partition(":")
        except (binascii.Error, UnicodeDecodeError):
            return False
        if not sep or not hmac.compare_digest(user.encode(), self.user.encode()):
            return False
        async with self._semaphore():
            ok = await asyncio.to_thread(verify_password, password, self.password_hash)
        if not ok:
            self._remember_bad(key)
            return False
        self._ok.add(key)
        return True

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["path"] in OPEN_PATHS:
            return await self.app(scope, receive, send)
        headers = dict(scope["headers"])
        header = headers.get(b"authorization", b"").decode("latin-1")
        if header and await self._allowed(header):
            return await self.app(scope, receive, send)
        await send({"type": "http.response.start", "status": 401,
                    "headers": [(b"content-type", b"application/json"),
                                (b"www-authenticate", b'Basic realm="worklog", charset="UTF-8"')]})
        await send({"type": "http.response.body", "body": b'{"error":"login required"}'})


class SecurityHeaders:
    """ASGI middleware: the same few hardening headers on every response (no CSP: the pages use
    inline scripts and styles)."""

    HEADERS = [(b"x-content-type-options", b"nosniff"), (b"x-frame-options", b"DENY"),
               (b"referrer-policy", b"same-origin")]

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)

        async def send_with_headers(message):
            if message["type"] == "http.response.start":
                have = {k.lower() for k, _ in message.get("headers", [])}
                message = {**message, "headers": [*message.get("headers", []),
                                                  *(h for h in self.HEADERS if h[0] not in have)]}
            await send(message)

        await self.app(scope, receive, send_with_headers)


if __name__ == "__main__":
    pw = sys.argv[1] if len(sys.argv) > 1 else getpass.getpass("worklog password: ")
    print(hash_password(pw))
