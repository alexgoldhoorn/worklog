"""FastAPI application factory."""
import logging
import os
from datetime import datetime
from zoneinfo import ZoneInfo

from fastapi import FastAPI
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException
from fastapi.responses import JSONResponse
from fastapi.staticfiles import StaticFiles

from .. import config, db
from ..auth import BasicAuth
from ..csrf import CrossSiteGuard
from ..config import Settings
from .api import ApiError, router
from .pages import router as pages_router
from balance.web.api import router as balance_router
from day.web import router as day_router

_STATIC = os.path.join(os.path.dirname(__file__), "static")


def _init_sentry(dsn: str) -> None:
    """Report unhandled exceptions (500s) to Sentry (or a Sentry-compatible server such as Bugsink). ApiError and the other registered
    handlers answer 4xx themselves and never reach Sentry. Must never stop the app starting."""
    try:
        import sentry_sdk
        from sentry_sdk.integrations.fastapi import FastApiIntegration
        from sentry_sdk.integrations.starlette import StarletteIntegration
        # no PII flag: the SDK default already sends none, and send_default_pii is deprecated
        sentry_sdk.init(dsn=dsn, environment="worklog", server_name="nuc", traces_sample_rate=0,
                        integrations=[StarletteIntegration(), FastApiIntegration()])
    except Exception as e:  # noqa: BLE001
        logging.getLogger(__name__).warning("error reporting disabled: %s", e)


def create_app(settings: Settings) -> FastAPI:
    # Half a login must never mean "no login": refuse to start rather than serve open.
    if bool(settings.auth_user) != bool(settings.auth_password_hash):
        missing = "WORKLOG_AUTH_PASSWORD_HASH" if settings.auth_user else "WORKLOG_AUTH_USER"
        raise ValueError(f"authentication is half configured: {missing} is not set "
                         "(set both WORKLOG_AUTH_USER and WORKLOG_AUTH_PASSWORD_HASH, or neither)")
    if settings.sentry_dsn:
        _init_sentry(settings.sentry_dsn)
    app = FastAPI(title="worklog")
    app.state.settings = settings
    db.connect(settings.db_path).close()  # migrate once, before the first request
    tz = ZoneInfo(settings.tz)
    app.state.clock = lambda: datetime.now(tz).replace(tzinfo=None)

    @app.exception_handler(ApiError)
    async def _api_error(_request, exc: ApiError):
        return JSONResponse({"error": exc.message}, status_code=exc.status)

    @app.exception_handler(RequestValidationError)
    async def _validation(_request, exc: RequestValidationError):
        errs = exc.errors()
        msg = errs[0].get("msg", "invalid request") if errs else "invalid request"
        loc = ".".join(str(x) for x in errs[0].get("loc", ())[1:]) if errs else ""
        return JSONResponse({"error": f"{loc}: {msg}" if loc else msg}, status_code=400)

    @app.exception_handler(StarletteHTTPException)
    async def _http(_request, exc: StarletteHTTPException):
        return JSONResponse({"error": str(exc.detail)}, status_code=exc.status_code)

    app.include_router(router)
    app.include_router(pages_router)
    app.include_router(balance_router)
    app.include_router(day_router)
    app.mount("/static", StaticFiles(directory=_STATIC), name="static")

    @app.middleware("http")
    async def _revalidate(request, call_next):
        # Pages and static files are always revalidated (ETag / 304): a deploy must reach the
        # phone on the next load. Static URLs also carry ?v=<hash> (pages.py) so an already
        # cached copy is never reused after a change.
        response = await call_next(request)
        if request.url.path.startswith("/static/") or "text/html" in response.headers.get("content-type", ""):
            response.headers.setdefault("Cache-Control", "no-cache")
        return response
    app.add_middleware(CrossSiteGuard)
    if settings.auth_user and settings.auth_password_hash:
        app.add_middleware(BasicAuth, user=settings.auth_user, password_hash=settings.auth_password_hash)
    else:
        logging.getLogger(__name__).warning(
            "authentication is off: set WORKLOG_AUTH_USER and WORKLOG_AUTH_PASSWORD_HASH to require a login")
    return app


def factory() -> FastAPI:
    return create_app(config.from_env())
