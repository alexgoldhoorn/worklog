import re

import pytest


@pytest.mark.parametrize("path,ids", [
    ("/timer", ["btn-start", "btn-pause", "btn-stop", "blocks", "proposals", "totals",
           "state", "state-counters", "today-clock", "today-label", "project", "chips-types", "chips-projects", "chips-breaks", "day", "notices", "kbd-hint",
           "queue-strip", "idle-card"]),
    ("/settings", ["settings-notices", "defaults", "def-type", "def-client", "def-break", "def-close", "def-autoadd", "def-save", "def-msg",
                   "rate", "rate-unit", "rate-hint", "basis", "basis-seg", "basis-hint", "pref-shortcuts", "currency",
                   "clients-list", "client-form", "client-new", "client-new-bill", "client-add", "clients-msg",
                   "breaks-list", "break-form", "break-new", "break-add", "breaks-msg", "pref-idle", "pref-idle-min"]),
    ("/day", ["day-chips", "day-start", "timeline", "top3", "day-add", "day-find", "find-dialog", "find-form", "find-close", "f-date"]),
    ("/find", ["find-form", "f-what", "f-date", "f-start", "f-end", "find-submit", "options", "put-btn", "find-notices"]),
    ("/week", ["propose", "outlook", "add", "add-cal"]),
    ("/reports", ["group", "start", "end", "invoice", "charts", "reports-notices", "import-form", "import-result"]),
    ("/days", ["days"]),
    ("/pomodoro", ["pomo-clock", "pomo-phase", "pomo-bar", "pomo-start", "pomo-pause", "pomo-plus", "pomo-reset", "pomo-log",
                   "pomo-card", "pomo-work", "pomo-break", "pomo-long", "pomo-rounds", "pomo-presets", "pomo-beep", "pomo-notices"])])
def test_pages_render_with_required_elements(client, path, ids):
    r = client.get(path)
    assert r.status_code == 200 and "<title>worklog</title>" in r.text
    for i in ids:
        assert f'id="{i}"' in r.text


def test_static_served(client):
    assert client.get("/static/app.js").status_code == 200
    assert client.get("/static/style.css").status_code == 200


def test_static_urls_are_versioned_and_revalidated(client):
    from worklog.web.pages import STATIC_VERSION
    html = client.get("/day").text
    assert f'href="/static/style.css?v={STATIC_VERSION}"' in html
    assert f'src="/static/app.js?v={STATIC_VERSION}"' in html and f'src="/static/day.js?v={STATIC_VERSION}"' in html
    assert len(STATIC_VERSION) == 10
    assert client.get("/static/style.css").headers["cache-control"] == "no-cache"
    assert client.get("/day").headers["cache-control"] == "no-cache"
    assert "cache-control" not in client.get("/healthz").headers


def test_timer_accepts_date_param(client):
    assert client.get("/timer?date=2026-10-01").status_code == 200


def test_day_table_has_billable_column(client):
    js = client.get("/static/app.js").text
    assert '"Billable"' in js and "cycleBillable" in js


def test_pomodoro_script_only_on_pomodoro_page(client):
    assert "/static/pomodoro.js" in client.get("/pomodoro").text
    assert "/static/pomodoro.js" not in client.get("/day").text
    assert client.get("/static/pomodoro.js").status_code == 200


def test_root_is_day_page(client):
    r = client.get("/day")
    assert r.status_code == 200 and 'id="day-root"' in r.text and 'id="blocks"' not in r.text
    assert '/static/day.js' in r.text


def test_timer_page_is_old_index(client):
    r = client.get("/timer")
    assert 'id="blocks"' in r.text and 'day-root' not in r.text and '/static/day.js' not in r.text


def test_day_page_nav_marks_day(client):
    r = client.get("/day")
    assert re.search(r'<a href="/day" class="on"><svg[^>]*>.*?</svg>Day</a>', r.text)


def _tabs(html):
    """The links of the navigation itself, without the More list."""
    return html.split("<nav>")[1].split("</nav>")[0].split('class="more-menu"')[0]


def test_nav_has_the_app_order_and_names(client):
    html = client.get("/timer").text
    assert html.count("<nav>") == 1                                       # one navigation, two layouts
    tabs = _tabs(html)
    assert re.findall(r"</svg>([^<]+)</a>", tabs) == ["Timer", "Day", "Week", "Pomodoro", "Reports", "Expected hours"]
    # the bottom bar (narrow) has the first four and More; Reports and Expected hours are tabs only when wide
    assert re.findall(r'<a href="[^"]+" class="wide-only[^"]*">(?:<svg.*?</svg>)([^<]+)</a>', tabs) == ["Reports", "Expected hours"]
    # More is the app's three horizontal dots, inside the navigation
    more = html.split("<nav>")[1].split("</nav>")[0].split('class="more-menu"')[1]
    assert 'id="more-btn"' in more and "M5 12h.01 M12 12h.01 M19 12h.01" in more and "M12 5h.01" not in html
    assert 'class="on wide-only' not in html and re.search(r'href="/reports" class="wide-only on"', client.get("/reports").text)


def test_more_menu_holds_the_pages_the_tabs_do_not(client):
    html = client.get("/timer").text
    menu = html.split('id="more-list"')[1].split("</div>")[0]
    assert re.findall(r'href="([^"]+)"[^>]*>(?:<svg.*?</svg>)?([^<]+)</a>', menu) == [
        ("/reports", "Reports"), ("/days", "Expected hours"),
        ("/find", "Add or find a date"), ("/move", "Move an event"), ("/workcal", "Work calendar"), ("/settings", "Settings")]
    # Reports and Expected hours are in the list only for the bottom bar; a separator stands before Settings
    assert re.findall(r'href="([^"]+)" class="narrow-only', menu) == ["/reports", "/days"]
    assert menu.index("<hr") > menu.index("/workcal") and menu.index("<hr") < menu.index("/settings")
    assert 'id="more-btn"' in html and 'aria-haspopup="true"' in html and 'aria-expanded="false"' in html
    # the tabs come first, More closes the navigation
    assert html.index("Expected hours</a>") < html.index('id="more-btn"') < html.index("</nav>")
    for page in ("/find", "/move", "/workcal", "/settings"):
        assert re.search(r'id="more-btn" class="more-btn on"', client.get(page).text), page
    # on the bottom bar More is also the place of Reports and Expected hours
    for page in ("/reports", "/days"):
        assert re.search(r'id="more-btn" class="more-btn on-narrow"', client.get(page).text), page
    assert 'class="more-btn on' not in html


def test_bottom_bar_styles_and_no_scrolling_nav(client):
    css = client.get("/static/style.css").text
    assert "@media (max-width: 759.98px)" in css and "@media (min-width: 760px)" in css
    assert "safe-area-inset-bottom" in css and ".more-btn.on-narrow" in css and "mask-image" not in css
    js = client.get("/static/app.js").text
    assert "initNav" not in js and "scrollLeft" not in js


def test_settings_page_and_links_where_settings_used_to_be(client):
    assert 'id="def-save"' not in client.get("/timer").text and 'href="/settings"' in client.get("/timer").text
    reports = client.get("/reports").text
    assert 'id="rate"' not in reports and 'id="basis"' not in reports and 'href="/settings"' in reports
    js = client.get("/static/app.js").text
    assert "basisSelect" not in js and "/settings#week-basis" in js


def test_root_opens_the_timer_and_the_day_planner_only_when_it_is_configured(app, client):
    r = client.get("/", follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == "/timer"   # the site opens on the Timer
    assert client.get("/day", follow_redirects=False).status_code == 200
    app.state.settings.balance_db_path = None
    r = client.get("/day", follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == "/timer"
    assert client.get("/day").status_code == 200 and 'id="blocks"' in client.get("/day").text   # followed: the Timer, no error page


def test_core_script_loads_first_and_is_served(client):
    html = client.get("/timer").text
    assert html.index("/static/core.js") < html.index("/static/app.js")
    js = client.get("/static/core.js").text
    assert "window.wl" in js and "Cannot reach the server" in js and "Server error (" in js
    assert client.get("/static/core.js").headers["cache-control"] == "no-cache"


def test_pages_share_one_fetch_wrapper(client):
    # one wrapper (core.js) instead of a fetch per page; the pages keep only uploads of their own out of it
    for name in ("app.js", "day.js", "week.js", "find.js", "move.js", "workcal.js"):
        js = client.get(f"/static/{name}").text
        assert "await fetch(" not in js, name


def test_server_clock_not_device_clock(client):
    for name in ("day.js", "week.js", "find.js", "move.js", "workcal.js", "pomodoro.js"):
        js = client.get(f"/static/{name}").text
        assert "toISOString" not in js and "new Date()" not in js, name
    assert "Date.now() - new Date(" not in client.get("/static/app.js").text


def test_wording_shared_with_the_qt_app(client):
    html = client.get("/timer").text
    assert "Work calendar <small>· the day's meetings</small>" in html
    js = client.get("/static/app.js").text
    assert '"Add as meeting"' in js and '"Dismiss"' in js
    find = client.get("/find").text
    assert "Length (min)" in find and "Travel each way (min)" in find and "Fill in the form and press Find." in find
    assert "Defaults are greyed; edited days are marked and can be reset" in client.get("/days").text


def test_no_hard_coded_default_types_in_the_timer(client):
    js = client.get("/static/app.js").text
    assert '"eat"' not in js and '"dev"' not in js and "status.resume" in js.replace("timer.status.resume", "status.resume")


def test_timer_navigation_stays_on_timer(client):
    js = client.get("/static/app.js").text
    assert "/timer?date=" in js and "`/?date=" not in js and 'location.href = iso === isoDate(new Date()) ? "/"' not in js


def test_day_page_has_calendar_lane_toggles_and_markdown_helper(client):
    r = client.get("/day").text
    for lane in ("work", "personal", "family", "child", "blocks"):
        assert f'id="lane-{lane}"' in r
    assert "protected" not in r.lower()
    assert "/static/mdlite.js" in r and client.get("/static/mdlite.js").status_code == 200
    assert "/static/mdlite.js" in client.get("/week").text


def test_week_settings_use_24h_text_inputs_with_help(client):
    js = client.get("/static/week.js").text
    assert '["hard_stop", "Hard stop", "text"' in js and '["run_slot", "Run slot", "text"' in js
    assert 'type="time"' not in js
    assert "pattern=" in js and "milestone" in js.lower() and "balance.db" in js


def test_markdown_helper_links_only_http(client):
    js = client.get("/static/mdlite.js").text
    assert "window.mdlite" in js and "https?" in js and "javascript" not in js.lower()


def test_move_and_find_pages_render(client):
    r = client.get("/move?kind=run&date=2026-11-03")
    assert r.status_code == 200 and 'id="move-root"' in r.text and "/static/move.js" in r.text and "/static/mdlite.js" in r.text
    r = client.get("/find")
    assert r.status_code == 200 and 'id="find-root"' in r.text and "/static/find.js" in r.text
    assert client.get("/static/move.js").status_code == 200 and client.get("/static/find.js").status_code == 200
    nav = _tabs(client.get("/day").text)
    assert "/move" not in nav and "/find" not in nav                      # in the More list, not among the tabs


def test_day_and_week_scripts_link_to_move_and_find(client):
    assert 'href="/find"' in client.get("/day").text and "/move?" in client.get("/static/day.js").text
    assert "/move?" in client.get("/static/week.js").text


def test_workcal_page_renders(client):
    r = client.get("/workcal")
    assert r.status_code == 200 and 'id="workcal-root"' in r.text and "/static/workcal.js" in r.text and "/static/mdlite.js" in r.text
    for i in ("wc-banner", "wc-week", "wc-paste", "wc-preview", "wc-prep", "pdf-file"):
        assert f'id="{i}"' in r.text
    assert client.get("/static/workcal.js").status_code == 200
    assert "/workcal" not in _tabs(client.get("/day").text)


def test_day_page_links_to_the_work_calendar_page(client):
    assert 'href="/workcal"' in client.get("/day").text


def test_week_grid_css_does_not_restyle_tables(client):
    # The timer/reports/days tables carry class "grid"; the week page's hour grid must not
    # share that selector or the <table> gets display:grid and its header drifts off the columns.
    import re
    css = client.get("/static/style.css").text
    bare = [m.group(0) for m in re.finditer(r"(?m)^\s*\.grid\s*\{[^}]*\}", css)]
    assert not bare, bare
    js = client.get("/static/week.js").text
    assert 'className = "grid"' not in js


def test_day_js_offers_work_on_this(client):
    js = client.get("/static/day.js").text
    assert "work on this" in js and "function plainTitle" in js


def test_timer_shortcuts_are_wired(client):
    js = client.get("/static/app.js").text
    assert "function shortcut(" in js and '"/"' in js


def test_manifest_and_icons(client):
    from worklog.web.pages import STATIC_VERSION
    html = client.get("/day").text
    assert f'<link rel="manifest" href="/static/manifest.webmanifest?v={STATIC_VERSION}" crossorigin="use-credentials">' in html
    assert '<link rel="apple-touch-icon" href="/static/icon-192.png">' in html
    assert '<meta name="apple-mobile-web-app-capable" content="yes">' in html
    r = client.get("/static/manifest.webmanifest")
    assert r.status_code == 200 and "manifest" in r.headers["content-type"]
    m = r.json()
    assert m["name"] == "worklog" and m["display"] == "standalone" and m["start_url"] == "/timer"
    for icon in m["icons"]:
        assert client.get(icon["src"]).status_code == 200


def test_no_literal_currency_symbol_in_pages_or_scripts(client):
    # the symbol comes from the server's `currency` setting (kept in wl.currency()), never from the markup
    import pathlib
    web = pathlib.Path(__file__).resolve().parents[1] / "worklog" / "web"
    for path in [*web.glob("static/*.js"), *web.glob("templates/*.html")]:
        assert "€" not in path.read_text(encoding="utf-8"), path.name
    settings = client.get("/settings").text
    assert 'id="currency"' in settings and "€" not in settings
    js = client.get("/static/app.js").text
    assert "wl.currency()" in js and "currency: v" in js
    assert "currency" in client.get("/static/core.js").text


def test_settings_page_manages_clients_and_break_types(client):
    js = client.get("/static/app.js").text
    for route in ("/api/clients", "/api/break-types"):
        assert route in js
    html = client.get("/settings").text
    assert "Clients" in html and "Break types" in html and "only works while the page is open" in html


def test_week_undo_calls_the_propose_route(client):
    js = client.get("/static/week.js").text
    assert "/propose`" in js and '"Undo"' in js


def test_offline_queue_and_idle_prompt_are_wired(client):
    core = client.get("/static/core.js").text
    assert "worklog.queue" in core and "request_id" in core and "setInterval(" in core and '"online"' in core
    assert "408" in core and "429" in core and "401" in core
    app = client.get("/static/app.js").text
    assert "waiting" in app and "Retry now" in app and '"Discard"' in app and "wl.queue.act(" in app
    assert "Log it as a break?" in app and '"Log as break"' in app and "/api/pause" in app
    assert "Offline \u00b7 last update" in core


def test_service_worker_is_served_from_the_root(client):
    from worklog.web.pages import STATIC_VERSION
    r = client.get("/sw.js")
    assert r.status_code == 200 and "javascript" in r.headers["content-type"]
    assert r.headers["cache-control"] == "no-cache"
    assert f'const VERSION = "{STATIC_VERSION}"' in r.text and "__VERSION__" not in r.text
    # never the API, only GET, old caches removed
    assert '"/api/"' in r.text and 'req.method !== "GET"' in r.text and "caches.delete" in r.text
    assert 'navigator.serviceWorker.register("/sw.js")' in client.get("/static/core.js").text


def test_service_worker_does_not_get_a_page_for_a_logged_out_browser(client):
    # the worker only falls back to a kept page when the network call throws; an answer, a 401 included, is returned as it is
    js = client.get("/sw.js").text
    assert "return res; // any answer" in js and js.index("const cache = await caches.open(CACHE);") > js.index("return res;")


# ---- one rule per kind, on every page (time entry, nav icons) ---------------------------------------------------

def _web(name):
    from pathlib import Path
    return (Path(__file__).resolve().parent.parent / "worklog" / "web" / name).read_text(encoding="utf-8")


def test_time_fields_are_text_inputs_bound_by_the_shared_helper(client):
    # no browser time widget anywhere: every time field is `input.time`, normalised by wl.bindTimes (core.js)
    for path in ("/find", "/week", "/settings", "/day"):
        assert 'type="time"' not in client.get(path).text, path
    for f in ("find", "week", "settings"):
        assert 'class="time"' in client.get(f"/{f}").text
    core = _web("static/core.js")
    assert "const normTime" in core and "bindTimes" in core and "Times must be HH:MM" in core
    # the time-parsing regexp lives in core.js only
    for name in ("app.js", "day.js", "find.js", "move.js", "week.js", "workcal.js", "pomodoro.js"):
        assert "[:.hH]" not in _web(f"static/{name}"), name


def test_decimal_hour_fields_accept_a_comma(client):
    for path, ident in (("/settings", "rate"), ("/settings", "basis")):
        assert f'id="{ident}" ' in client.get(path).text
        assert re.search(rf'<input type="text" id="{ident}"[^>]*inputmode="decimal"', client.get(path).text)
    assert "wl.parseNum" in _web("static/app.js")


def test_nav_icons_match_the_qt_app():
    qml = _web("../../qt/NavIcon.qml")
    qt = dict(re.findall(r'"(\w+)": "([^"]+)"', qml))
    html = _web("templates/base.html")
    paths = re.findall(r'<path d="([^"]+)"/></svg>([A-Za-z ]+)</a>', html)
    names = {"Timer": "timer", "Week": "week", "Pomodoro": "pomodoro", "Day": "day", "Reports": "reports",
             "Expected hours": "expected", "Add or find a date": "find", "Settings": "settings"}
    seen = set()
    for d, label in paths:
        if label in names:
            assert qt[names[label]] == d, label
            seen.add(label)
    assert seen == set(names)


def test_qt_buttons_all_go_through_the_shared_components():
    from pathlib import Path
    shared = {"AppButton.qml", "AppIconButton.qml", "AppRoundButton.qml", "ActionButton.qml"}
    for f in (Path(__file__).resolve().parent.parent / "qt").glob("*.qml"):
        if f.name in shared:
            continue
        assert not re.search(r"^\s*(Button|ToolButton|RoundButton)\s*\{", f.read_text(encoding="utf-8"), re.M), f.name


def test_day_page_is_in_three_parts_like_week(client):
    html = client.get("/day").text
    # the same tab strip as the Week page, switched by the one function in core.js
    for page in (html, client.get("/week").text):
        assert 'class="seg weekviews" id="views"' in page
    for view in ("day", "work", "sync"):
        assert f'data-view="{view}"' in html and f'data-pane="{view}"' in html
    assert html.index('data-view="day"') < html.index('data-view="work"') < html.index('data-view="sync"')
    assert 'id="view-sync"' in html and 'id="day-tiles"' in html and 'id="work-tiles"' in html and 'id="prep-dialog"' in html
    # Refresh, the work calendar and the pending writes are in the Sync part; the counts line and its foot are gone
    sync = html[html.index('data-pane="sync"'):]
    assert 'id="day-refresh"' in sync and 'id="pdf-file"' in sync and 'id="queue"' in sync
    assert "day-foot" not in html and 'id="counts"' not in html
    core, week, day = (client.get(f"/static/{n}.js").text for n in ("core", "week", "day"))
    assert "function showView(" in core and "data-pane" in core and "data-pane" not in week
    assert "Sync: stale" in day and "Nothing waiting." in day and "window.prompt" not in day
    # one wording with the Qt app
    for text in ("waiting to sync", "I take it", "takes it", '"Whose?"', "Week blocks"):
        assert text in day, text
    assert "brings her" not in day and "h (normal" not in day   # "37 h 05 h"
