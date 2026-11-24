import QtQuick
import QtQuick.Controls
import QtTest
import WorkLogApp

// request_id on timer actions, the currency, Test connection, Markdown text, the clients and break
// types of Settings, the Week page's balance settings and the Day planner page.
TestCase {
    id: tc
    name: "Features"
    width: 480
    height: 900
    visible: true
    when: windowShown

    Component { id: settingsPage; SettingsPage {} }
    Component { id: weekPage; WeekPage {} }
    Component { id: plannerPage; PlannerPage {} }

    function initTestCase() {
        Api.serverUrl = testServer
        Api.username = ""
    }

    function call(method, path, body) {
        const r = { done: false, ok: false, data: null, err: "", status: -1 }
        Api.request(method, path, body, d => { r.done = true; r.ok = true; r.data = d },
                    (e, st) => { r.done = true; r.err = e; r.status = st })
        tryVerify(() => r.done, 5000, method + " " + path)
        return r
    }

    // ---- request_id --------------------------------------------------------------------------------

    function test_request_ids_are_unique_and_short() {
        const a = Api.newRequestId(), b = Api.newRequestId()
        verify(a !== b)
        verify(a.length >= 1 && a.length <= 64, a)
    }

    function test_timer_action_sends_an_id_and_the_queue_keeps_it() {
        Api.queue = []
        Api.saveQueue()
        call("POST", "/api/stop", {})
        Api.serverUrl = "http://127.0.0.1:1"
        const r = { done: false }
        Api.timerAction("/api/start", { project: "rid" }, () => r.done = true, () => r.done = true, () => r.done = true)
        tryVerify(() => r.done, 5000)
        compare(Api.queue.length, 1)
        const id = Api.queue[0].body.request_id
        verify(typeof id === "string" && id.length > 0)
        compare(JSON.parse(Api.offline.queueJson)[0].body.request_id, id)
        Api.serverUrl = testServer
        Api.dropQueue("")
    }

    function test_a_repeated_id_is_applied_once() {
        call("POST", "/api/stop", {})
        const id = Api.newRequestId()
        call("POST", "/api/start", { project: "once", request_id: id })
        const first = call("GET", "/api/status").data.block.id
        call("POST", "/api/pause", { type: "eat" })
        // the replay of the first start (same id) must not start a second block
        call("POST", "/api/start", { project: "once", request_id: id })
        compare(call("GET", "/api/status").data.state, "break")
        call("POST", "/api/stop", {})
        verify(first > 0)
    }

    // ---- currency -----------------------------------------------------------------------------------

    function test_currency_follows_the_status_and_formats_amounts() {
        Api.refreshStatus()
        tryVerify(() => Api.status !== null, 5000)
        compare(Api.currency, Api.status.currency)
        Api.currency = "CHF"
        compare(Api.fmtEur(1234.4), "1 234 CHF")
        Api.currency = "€"
        compare(Api.fmtEur(12), "12 €")
    }

    function test_settings_currency_is_saved() {
        failOnWarning(/.*/)
        const p = createTemporaryObject(settingsPage, tc, { width: tc.width, height: tc.height })
        tryVerify(() => p.connected === true, 5000)
        tryVerify(() => p.settings !== null, 5000)
        compare(p.currencyValid, p.settings.currency.trim().length > 0)
        call("PUT", "/api/settings", { currency: "CHF" })
        p.reload("currency")
        tryVerify(() => p.settings.currency === "CHF", 5000)
        tryVerify(() => Api.currency === "CHF", 5000)
        call("PUT", "/api/settings", { currency: "€" })
        tryVerify(() => Api.currency === "€", 5000)
    }

    // ---- Test connection ----------------------------------------------------------------------------

    function test_probe_verdicts() {
        verify(!Api.probeVerdict(0, "", "http://x").ok)
        verify(Api.probeVerdict(0, "", "http://x").message.indexOf("Cannot reach") === 0)
        verify(Api.probeVerdict(401, "", "http://x").message.indexOf("refused") > 0)
        verify(Api.probeVerdict(200, "<html></html>", "http://x").message.indexOf("Not a worklog server") === 0)
        verify(Api.probeVerdict(200, "{\"hello\": 1}", "http://x").message.indexOf("Not a worklog server") === 0)
        verify(Api.probeVerdict(404, "", "http://x").message.indexOf("Not a worklog server") === 0)
        verify(Api.probeVerdict(502, "", "http://x").message.indexOf("error") > 0)
        verify(Api.probeVerdict(200, "{\"state\": \"stopped\", \"now\": \"2026-01-01T10:00:00\"}", "http://x").ok)
    }

    function probe(url, user, pass) {
        const r = { done: false, res: null }
        Api.probe(url, user, pass, x => { r.done = true; r.res = x })
        tryVerify(() => r.done, 25000)
        return r.res
    }

    function test_probe_against_the_server_and_a_dead_port() {
        const before = Api.serverUrl
        const ok = probe(testServer, "", "")
        verify(ok.ok, ok.message)
        compare(Api.serverUrl, before)   // nothing was saved
        const dead = probe("http://127.0.0.1:1", "", "")
        verify(!dead.ok)
        verify(dead.message.indexOf("Cannot reach") === 0, dead.message)
        verify(!probe("", "", "").ok)
        // /healthz answers 200 but is no worklog status
        const notWorklog = probe(testServer + "/healthz", "", "")
        verify(!notWorklog.ok)
    }

    // ---- Markdown in Todoist text -------------------------------------------------------------------

    function test_markdown_subset() {
        compare(Api.mdPlain("**Pay** [the bill](https://example.com/x) `now`"), "Pay the bill now")
        compare(Api.mdHtml("a <b> [t](https://e.com/p?a=1&b=2)"), "a &lt;b&gt; <a href=\"https://e.com/p?a=1&amp;b=2\">t</a>")
        // a link that is not http(s) stays text
        compare(Api.mdHtml("[x](javascript:alert(1))"), "[x](javascript:alert(1))")
        compare(Api.mdPlain("[[Feedback] item](https://e.com)"), "[Feedback] item")
        compare(Api.mdHtml(null), "")
    }

    // ---- clients and break types --------------------------------------------------------------------

    function test_clients_add_rename_delete_and_409() {
        failOnWarning(/.*/)
        const p = createTemporaryObject(settingsPage, tc, { width: tc.width, height: tc.height })
        tryVerify(() => p.connected === true, 5000)
        p.addClient("Qt Client", true)
        tryVerify(() => p.clients.some(c => c.name === "Qt Client" && c.billable), 5000)
        p.setBillable("Qt Client", false)
        tryVerify(() => p.clients.some(c => c.name === "Qt Client" && !c.billable), 5000)
        p.renameClient("Qt Client", "Qt Client 2")
        tryVerify(() => p.clients.some(c => c.name === "Qt Client 2"), 5000)
        p.addClient("qt client 2", true)   // a duplicate, case-insensitive
        tryVerify(() => p.clientsError !== "", 5000)
        verify(p.clientsError.indexOf("exists") >= 0, p.clientsError)
        p.deleteClient("Qt Client 2")
        tryVerify(() => !p.clients.some(c => c.name === "Qt Client 2"), 5000)
        // the default client is in use: the server's 409 text shows
        const def = p.settings.default_client
        if (def) {
            p.deleteClient(def)
            tryVerify(() => p.clientsError !== "" && p.clientsError.indexOf("exists") < 0, 5000)
        }
    }

    function test_break_types_add_and_delete() {
        failOnWarning(/.*/)
        const p = createTemporaryObject(settingsPage, tc, { width: tc.width, height: tc.height })
        tryVerify(() => p.connected === true && p.breakList.length > 0, 5000)
        const first = p.breakList[0]
        p.addBreak("Qt Break")
        tryVerify(() => p.breakList.indexOf("qt break") >= 0, 5000)
        p.deleteBreak("qt break")
        tryVerify(() => p.breakList.indexOf("qt break") < 0, 5000)
        p.deleteBreak(first)   // the default
        tryVerify(() => p.breakError !== "", 5000)
        verify(p.breakError.indexOf("default") >= 0, p.breakError)
    }

    // ---- Week: balance settings, undo through propose -----------------------------------------------

    function loadWeek() {
        failOnWarning(/.*/)
        const p = createTemporaryObject(weekPage, tc, { width: tc.width, height: tc.height })
        tryVerify(() => p.weekData !== null || p.error !== "", 5000)
        compare(p.error, "")
        return p
    }

    function test_week_undo_uses_the_propose_route() {
        const p = loadWeek()
        const day = p.weekData.days[2]
        const made = call("POST", "/api/balance/blocks", { date: day, start: "17:00", end: "18:00", kind: "family", title: "Qt propose block" }).data
        p.decide(made.id, "approve")   // already approved: stays approved
        tryVerify(() => p.snackbar.undoFn !== null, 5000)
        p.snackbar.undoFn()
        tryVerify(() => {
            const it = p.agenda[2].items.find(i => i.text === "Qt propose block")
            return it && it.block.state === "proposed"
        }, 5000)
        p.decide(made.id, "reject")
        tryVerify(() => !p.agenda[2].items.some(i => i.text === "Qt propose block"), 5000)
        p.snackbar.undoFn()
        tryVerify(() => {
            const it = p.agenda[2].items.find(i => i.text === "Qt propose block")
            return it && it.block.state === "proposed"
        }, 5000)
    }

    function test_week_balance_settings_save() {
        const p = loadWeek()
        p.balanceOpen = true
        tryVerify(() => p.balanceDirty === false && p.balanceBody().hard_stop !== undefined, 5000)
        const old = p.weekData.settings.hard_stop
        tryVerify(() => p.balanceBody().hard_stop === String(old), 5000)
        p.saveBalance()
        tryVerify(() => p.balanceMessage !== "", 5000)
        compare(p.balanceError, "")
        // a bad value shows the server's refusal
        const f = p.balanceRepeaterItem(0)
        f.field.text = "99:99"
        p.saveBalance()
        tryVerify(() => p.balanceError !== "", 5000)
        f.field.text = String(old)
        p.saveBalance()
        tryVerify(() => p.balanceError === "" && p.balanceMessage !== "", 5000)
    }

    function test_week_gate_helpers() {
        const p = loadWeek()
        compare(p.leftText(-3), "3 d ago")
        compare(p.leftText(0), "today")
        compare(p.leftText(4), "in 4 d")
        compare(p.daysFrom(p.todayIso), 0)
        compare(p.daysFrom(Api.addDays(p.todayIso, 5) + "T10:00"), 5)
        compare(p.preEventText({ title: "Race", days: 1 }), "Race in 1 day")
        compare(p.preEventText({ title: "Race", days: 3 }), "Race in 3 days")
        compare(p.preEventText(null), "")
    }

    // ---- Day planner ---------------------------------------------------------------------------------

    function loadPlanner() {
        failOnWarning(/\.qml:\d+/)
        const p = createTemporaryObject(plannerPage, tc, { width: tc.width, height: tc.height })
        tryVerify(() => p.day !== null || p.error !== "", 5000)
        compare(p.error, "")
        return p
    }

    function test_planner_loads_and_steps_days() {
        const p = loadPlanner()
        verify(p.day.is_today)
        const today = p.day.date
        p.step(1)
        tryVerify(() => p.day.date === Api.addDays(today, 1), 5000)
        verify(!p.day.is_today)
        p.show("")
        tryVerify(() => p.day.date === today, 5000)
        // the example household's school runs are on the timeline of a weekday
        verify(/^\d+ \/ \d+$/.test(p.tasksTile(p.day)), p.tasksTile(p.day))
    }

    function test_planner_lane_rules() {
        const p = loadPlanner()
        compare(p.laneOf({ layer: "work" }), "work")
        compare(p.laneOf({ layer: "protected" }), "blocks")
        compare(p.laneOf({ layer: "duty" }), "child")
        compare(p.laneOf({ layer: "personal", classification: "child" }), "child")
        compare(p.laneOf({ layer: "personal", lane: "family" }), "family")
        compare(p.laneOf({ layer: "personal", lane: "personal" }), "personal")
        compare(p.h2(7.0833), "7 h 05")
    }

    function test_planner_timeline_rows_sort_and_mark_now() {
        const p = loadPlanner()
        const d = { is_today: true, now: "10:00", timeline: [
            { start: "13:00", end: "14:00", title: "B", layer: "work" },
            { start: "08:00", end: "09:00", title: "A", layer: "personal", lane: "personal" },
            { start: "07:00", end: "07:30", title: "Off", layer: "personal", lane: "family" },
            { start: "05:00", end: "05:30", title: "Too early", layer: "work" }] }
        let rows = p.timelineRows(d, [])
        compare(rows.map(r => r.now !== undefined ? "now" : r.ev.title), ["Off", "A", "now", "B"])
        rows = p.timelineRows(d, ["family"])
        compare(rows.map(r => r.now !== undefined ? "now" : r.ev.title), ["A", "now", "B"])
        d.now = "23:00"
        compare(p.timelineRows(d, [])[3].now, "23:00")
        d.is_today = false
        compare(p.timelineRows(d, []).length, 3)
        compare(p.timelineRows(null, []).length, 0)
    }

    function test_planner_classify_has_three_explicit_choices() {
        const p = loadPlanner()
        const d = { date: "2026-11-20" }
        const ev = { start: "15:00", end: "16:00", title: "Swim" }
        compare(p.classifyBody(d, ev, "child", "once"), { date: "2026-11-20", start: "15:00", title: "Swim", cls: "child", always: false })
        compare(p.classifyBody(d, ev, "child", "always").always, true)
        compare(p.classifyBody(d, ev, "child", null), null)
        compare(p.classifyBody(d, ev, "child", "cancel"), null)
        // the dialog: Cancel (and Esc) save nothing
        p.ask(ev, "child", "Kim")
        tryVerify(() => p.classifyDialogItem.visible, 3000)
        compare(p.askEv.title, "Swim")
        p.classifyDialogItem.reject()
        compare(p.askEv, null)
    }

    function test_planner_owner_flip_and_labels() {
        const p = loadPlanner()
        const d = { date: "2026-11-20", household: { me: "Sam", partner: "Robin", child: "Kim" } }
        compare(p.ownerBody(d, { at: "08:45", title: "School drop-off", owner: "Robin" }).owner, "Sam")
        compare(p.ownerBody(d, { at: "08:45", title: "School drop-off", owner: "Sam" }).owner, "Robin")
        compare(p.eventLabel({ start: "09:00", end: "10:00", title: "Plan", layer: "personal", classification: "unclassified" }), "09:00–10:00 Plan · whose is it?")
        compare(p.eventLabel({ start: "09:00", end: "10:00", title: "Run", layer: "protected", state: "approved" }), "09:00–10:00 Run · approved")
        compare(p.eventLabel({ start: "09:00", end: "10:00", title: "Drop", layer: "duty", owner: "" }), "09:00–10:00 Drop · who does it?")
    }

    function test_planner_mirror_note_and_sub_line() {
        const p = loadPlanner()
        verify(p.mirrorNote({ mirror: { unknown: true, last_import_end: null } }).indexOf("never") > 0)
        compare(p.mirrorNote({ mirror: { unknown: false, stale_days: 3 } }), "")
        verify(p.mirrorNote({ mirror: { unknown: false, stale_days: 9 } }).indexOf("9 days") > 0)
        compare(p.subLine({ sync: {}, is_today: true }), "no snapshots yet")
    }

    // ---- the three parts (Day · Work · Sync) ------------------------------------------------------------

    function test_planner_sync_label_says_what_waits() {
        const p = loadPlanner()
        const fresh = { unknown: false, stale_days: 1 }
        compare(p.syncLabel(null), "Sync")
        compare(p.syncLabel({ queue: [], mirror: fresh }), "Sync")
        compare(p.syncLabel({ queue: [{ id: 1 }, { id: 2 }], mirror: fresh }), "Sync: 2")
        compare(p.syncLabel({ queue: [], mirror: { unknown: false, stale_days: 9 } }), "Sync: stale")
        compare(p.syncLabel({ queue: [], mirror: { unknown: true, last_import_end: null } }), "Sync: stale")
        // what waits wins over an old export
        compare(p.syncLabel({ queue: [{ id: 1 }], mirror: { unknown: true } }), "Sync: 1")
    }

    function test_planner_tiles_replace_the_counts_line() {
        const p = loadPlanner()
        compare(p.meetingsTile({ counts: { meetings_left: 3 } }), "3")
        compare(p.meetingsTile({ counts: { meetings_left: null } }), "–")
        compare(p.tasksTile({ counts: { done: 2, todo: 3 } }), "2 / 5")
        compare(p.classifyLine({ counts: { unclassified: 0 } }), "")
        compare(p.classifyLine({ counts: { unclassified: 1 } }), "1 family event to classify")
        compare(p.classifyLine({ counts: { unclassified: 2 } }), "2 family events to classify")
        const w = { hard_stop: "18:00", left_before_stop_h: 4.5, status: { state: "working", past_stop_min: 0 } }
        compare(p.stopTile({ work: w }), "4 h 30")
        compare(p.stopNote({ work: w }), "stop 18:00")
        compare(p.stopTile({ work: { hard_stop: "18:00", left_before_stop_h: null } }), "–")
        compare(p.stopNote({ work: { hard_stop: "18:00", left_before_stop_h: null } }), "work calendar unknown")
        compare(p.stopTile({ work: { hard_stop: "18:00", left_before_stop_h: 0, status: { state: "working", past_stop_min: 20 } } }), "0 h 20")
    }

    // one part shows at a time; stepping a day keeps the part, and it starts on Day
    function test_planner_view_gates_the_parts() {
        const p = loadPlanner()
        compare(p.view, "day")
        const shown = (title) => {
            const hits = []
            const walk = (item) => {
                if (item.title === title && item.visible)
                    hits.push(item)
                for (const c of item.children)
                    walk(c)
            }
            walk(p.contentItem)
            return hits.length > 0
        }
        verify(shown("Timeline") && shown("Training"))
        verify(!shown("Top 3 tasks") && !shown("Milestones") && !shown("Pending writes"))
        p.view = "work"
        verify(shown("Top 3 tasks") && shown("Milestones"))
        verify(!shown("Timeline") && !shown("Snapshots"))
        p.view = "sync"
        verify(shown("Snapshots") && shown("Work calendar") && shown("Pending writes"))
        verify(!shown("Timeline") && !shown("Top 3 tasks"))
        const today = p.day.date
        p.step(1)
        tryVerify(() => p.day.date === Api.addDays(today, 1), 5000)
        compare(p.view, "sync")
    }
}
