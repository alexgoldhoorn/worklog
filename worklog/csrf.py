"""Cross-site request guard for state-changing requests.

A browser that holds cached Basic credentials attaches them to a cross-site form post, and several
routes need no JSON body. So a non-safe request is refused when the browser says it is not same-origin
(`Sec-Fetch-Site`, so a sibling subdomain is refused too) or, for older browsers, when `Origin` names another host than the one asked.
Clients that are not browsers (curl, the Qt/Android app, the MCP server, host jobs) send neither
header and are unaffected.
"""
from urllib.parse import urlsplit

SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}


def _hostport(origin: str) -> str:
    return urlsplit(origin).netloc.lower()


class CrossSiteGuard:
    def __init__(self, app):
        self.app = app

    def _cross_site(self, headers: dict) -> bool:
        fetch_site = headers.get(b"sec-fetch-site", b"").decode("latin-1").lower()
        if fetch_site:
            # same-site is refused too: a sibling subdomain is another app.
            return fetch_site not in ("same-origin", "none")
        origin = headers.get(b"origin", b"").decode("latin-1")
        if not origin:
            return False
        if origin == "null":
            return True
        allowed = {headers.get(b"host", b"").decode("latin-1").lower(),
                   headers.get(b"x-forwarded-host", b"").decode("latin-1").lower()}
        return _hostport(origin) not in allowed

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and scope["method"] not in SAFE_METHODS \
                and self._cross_site(dict(scope["headers"])):
            body = b'{"error":"cross-site request refused"}'
            await send({"type": "http.response.start", "status": 403,
                        "headers": [(b"content-type", b"application/json"),
                                    (b"content-length", str(len(body)).encode())]})
            await send({"type": "http.response.body", "body": body})
            return
        await self.app(scope, receive, send)
