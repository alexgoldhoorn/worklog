import re

import pytest


@pytest.mark.parametrize("path,ids", [
    ("/timer", ["btn-start", "btn-pause", "btn-stop", "blocks", "proposals", "totals",
           "state", "state-counters", "today-clock", "today-label", "project", "chips-types", "chips-projects", "chips-breaks", "day", "notices", "kbd-hint"]),
    ("/settings", ["settings-notices", "defaults", "def-type", "def-client", "def-break", "def-close", "def-autoadd", "def-save", "def-msg",
                   "rate", "rate-unit", "rate-hint", "basis", "basis-seg", "basis-hint", "pref-shortcuts"]),
    ("/", ["day-chips", "day-start", "timeline", "top3", "day-add", "day-find", "find-dialog", "find-form", "find-close", "f-date"]),
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
    html = client.get("/").text
    assert f'href="/static/style.css?v={STATIC_VERSION}"' in html
    assert f'src="/static/app.js?v={STATIC_VERSION}"' in html and f'src="/static/day.js?v={STATIC_VERSION}"' in html
    assert len(STATIC_VERSION) == 10
    assert client.get("/static/style.css").headers["cache-control"] == "no-cache"
    assert client.get("/").headers["cache-control"] == "no-cache"
    assert "cache-control" not in client.get("/healthz").headers


def test_timer_accepts_date_param(client):
    assert client.get("/timer?date=2026-10-01").status_code == 200


def test_day_table_has_billable_column(client):
    js = client.get("/static/app.js").text
    assert '"Billable"' in js and "cycleBillable" in js


def test_pomodoro_script_only_on_pomodoro_page(client):
    assert "/static/pomodoro.js" in client.get("/pomodoro").text
    assert "/static/pomodoro.js" not in client.get("/").text
    assert client.get("/static/pomodoro.js").status_code == 200


def test_root_is_day_page(client):
    r = client.get("/")
    assert r.status_code == 200 and 'id="day-root"' in r.text and 'id="blocks"' not in r.text
    assert '/static/day.js' in r.text


def test_timer_page_is_old_index(client):
    r = client.get("/timer")
    assert 'id="blocks"' in r.text and 'day-root' not in r.text and '/static/day.js' not in r.text


def test_day_page_nav_marks_day(client):
    r = client.get("/")
    assert re.search(r'<a href="/" class="on"><svg[^>]*>.*?</svg>Day</a>', r.text)


def test_nav_has_the_app_order_and_names(client):
    nav = client.get("/timer").text.split("<nav>")[1].split("</nav>")[0]
    assert re.findall(r"</svg>([^<]+)</a>", nav) == ["Timer", "Week", "Pomodoro", "Day", "Reports", "Expected hours"]


def test_more_menu_holds_the_pages_the_tabs_do_not(client):
    html = client.get("/timer").text
    menu = html.split('id="more-list"')[1].split("</div>")[0]
    assert re.findall(r'href="([^"]+)"[^>]*>([^<]+)</a>', menu) == [
        ("/find", "Add or find a date"), ("/move", "Move"), ("/workcal", "Workcal"), ("/settings", "Settings")]
    assert 'id="more-btn"' in html and 'aria-haspopup="true"' in html and 'aria-expanded="false"' in html
    # the tabs themselves are unchanged and come first
    assert html.index("</nav>") < html.index('id="more-btn"')
    for page in ("/find", "/move", "/workcal", "/settings"):
        assert re.search(r'id="more-btn" class="more-btn on"', client.get(page).text), page
    assert 'class="more-btn on"' not in html


def test_settings_page_and_links_where_settings_used_to_be(client):
    assert 'id="def-save"' not in client.get("/timer").text and 'href="/settings"' in client.get("/timer").text
    reports = client.get("/reports").text
    assert 'id="rate"' not in reports and 'id="basis"' not in reports and 'href="/settings"' in reports
    js = client.get("/static/app.js").text
    assert "basisSelect" not in js and "/settings#week-basis" in js


def test_root_opens_the_day_planner_only_when_it_is_configured(app, client):
    assert client.get("/", follow_redirects=False).status_code == 200
    app.state.settings.balance_db_path = None
    r = client.get("/", follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == "/timer"
    assert client.get("/").status_code == 200 and 'id="blocks"' in client.get("/").text   # followed: the Timer, no error page


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
    r = client.get("/").text
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
    nav = client.get("/").text.split("<nav>")[1].split("</nav>")[0]
    assert "/move" not in nav and "/find" not in nav                      # reached from the Day/Week pages, not the nav


def test_day_and_week_scripts_link_to_move_and_find(client):
    assert 'href="/find"' in client.get("/").text and "/move?" in client.get("/static/day.js").text
    assert "/move?" in client.get("/static/week.js").text


def test_workcal_page_renders(client):
    r = client.get("/workcal")
    assert r.status_code == 200 and 'id="workcal-root"' in r.text and "/static/workcal.js" in r.text and "/static/mdlite.js" in r.text
    for i in ("wc-banner", "wc-week", "wc-paste", "wc-preview", "wc-prep", "pdf-file"):
        assert f'id="{i}"' in r.text
    assert client.get("/static/workcal.js").status_code == 200
    nav = client.get("/").text.split("<nav>")[1].split("</nav>")[0]
    assert "/workcal" not in nav


def test_day_page_links_to_the_work_calendar_page(client):
    assert 'href="/workcal"' in client.get("/").text


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
    html = client.get("/").text
    assert f'<link rel="manifest" href="/static/manifest.webmanifest?v={STATIC_VERSION}" crossorigin="use-credentials">' in html
    assert '<link rel="apple-touch-icon" href="/static/icon-192.png">' in html
    assert '<meta name="apple-mobile-web-app-capable" content="yes">' in html
    r = client.get("/static/manifest.webmanifest")
    assert r.status_code == 200 and "manifest" in r.headers["content-type"]
    m = r.json()
    assert m["name"] == "worklog" and m["display"] == "standalone" and m["start_url"] == "/timer"
    for icon in m["icons"]:
        assert client.get(icon["src"]).status_code == 200
