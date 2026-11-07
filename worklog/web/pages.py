"""HTML page shells; static/app.js fetches the JSON API and renders."""
import hashlib
import os

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse
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


def _page(request: Request, name: str, page: str) -> HTMLResponse:
    return templates.TemplateResponse(request, name, {"page": page})


@router.get("/", response_class=HTMLResponse)
def index(request: Request):
    return _page(request, "day.html", "day")


@router.get("/timer", response_class=HTMLResponse)
def timer(request: Request):
    return _page(request, "index.html", "timer")


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
