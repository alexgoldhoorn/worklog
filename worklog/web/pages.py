"""HTML page shells; static/app.js fetches the JSON API and renders."""
import hashlib
import os

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, RedirectResponse, Response
from fastapi.templating import Jinja2Templates

router = APIRouter()
templates = Jinja2Templates(directory=os.path.join(os.path.dirname(__file__), "templates"))


def static_version() -> str:
    """A short hash of every file under static/, appended to their URLs as ?v=.

    Without it a phone kept the old style.css for days after a deploy (no Cache-Control
    header, so Safari used heuristic freshness) and rendered the new markup unstyled."""
    root = os.path.join(os.path.dirname(__file__), "static")
    digest = hashlib.sha1()
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        if os.path.isfile(path):
            digest.update(name.encode())
            with open(path, "rb") as fh:
                digest.update(fh.read())
    return digest.hexdigest()[:10]


STATIC_VERSION = static_version()
templates.env.globals["static_v"] = STATIC_VERSION


@router.get("/sw.js")
def service_worker():
    """The service worker has to sit at the root to control every page; its cache name carries the static version,
    so a deploy replaces the worker and the old caches go on activation."""
    with open(os.path.join(os.path.dirname(__file__), "static", "sw.js"), encoding="utf-8") as fh:
        body = fh.read().replace("__VERSION__", STATIC_VERSION)
    return Response(body, media_type="text/javascript", headers={"Cache-Control": "no-cache"})


def _page(request: Request, name: str, page: str) -> HTMLResponse:
    return templates.TemplateResponse(request, name, {"page": page})


@router.get("/")
def index():
    """The site opens on the Timer, as the app does."""
    return RedirectResponse("/timer", status_code=302)


@router.get("/day", response_class=HTMLResponse)
def day(request: Request):
    """The Day planner needs the balance store; a server without one has nothing to show there, so it opens the
    Timer instead of an error page."""
    if not request.app.state.settings.balance_db_path:
        return RedirectResponse("/timer", status_code=302)
    return _page(request, "day.html", "day")


@router.get("/timer", response_class=HTMLResponse)
def timer(request: Request):
    return _page(request, "index.html", "timer")


@router.get("/settings", response_class=HTMLResponse)
def settings(request: Request):
    return _page(request, "settings.html", "settings")


@router.get("/week", response_class=HTMLResponse)
def week(request: Request):
    return _page(request, "week.html", "week")


@router.get("/move", response_class=HTMLResponse)
def move(request: Request):
    return _page(request, "move.html", "move")


@router.get("/find", response_class=HTMLResponse)
def find(request: Request):
    return _page(request, "find.html", "find")


@router.get("/workcal", response_class=HTMLResponse)
def workcal(request: Request):
    return _page(request, "workcal.html", "workcal")


@router.get("/reports", response_class=HTMLResponse)
def reports(request: Request):
    return _page(request, "reports.html", "reports")


@router.get("/days", response_class=HTMLResponse)
def days(request: Request):
    return _page(request, "days.html", "days")


@router.get("/pomodoro", response_class=HTMLResponse)
def pomodoro(request: Request):
    return _page(request, "pomodoro.html", "pomodoro")
