import QtQuick
import QtQuick.Controls
import QtTest
import WorkLogApp

// The fixes of the Qt review: offline queue (keep or drop, new login, stale flush), the tray/hotkey
// decision with a queue, Start/Pause bodies, focus guard for shortcuts, BlockDialog's end, the Find page's
// double submit, the Idle question and the Settings cards.
TestCase {
    id: tc
    name: "Review"
    width: 480
    height: 900
    visible: true
    when: windowShown

    readonly property string dead: "http://127.0.0.1:1"

    Component { id: ctl; TrayController { showIcon: false } }
    Component { id: idle; IdleWatcher {} }
    Component { id: dlgComp; BlockDialog {} }
    Component { id: findComp; FindPage {} }
    Component { id: settingsComp; SettingsPage {} }
    Component { id: weekComp; WeekPage {} }
    Component { id: reportsComp; ReportsPage {} }
    Component { id: fieldComp; TextField {} }
    Component { id: buttonComp; Button {} }
    Component { id: winComp; ApplicationWindow { width: 480; height: 820; visible: true } }

    function call(method, path, body) {
        const r = { done: false, ok: false, data: null, err: "" }
        Api.request(method, path, body, d => { r.done = true; r.ok = true; r.data = d },
                    e => { r.done = true; r.err = e })
        tryVerify(() => r.done, 5000, method + " " + path)
        return r
    }

    function initTestCase() {
        verify(testServer !== "")
        Api.serverUrl = testServer
        Api.username = ""
    }

    function init() {
        Api.dropQueue("")
        Api.serverUrl = testServer
        Api.username = ""
        Api.status = null
        call("POST", "/api/stop", {})
        call("GET", "/api/status")
    }

    // ---- the offline queue -----------------------------------------------------

    function test_flush_verdict() {
        for (const st of [0, 401, 408, 429, 500, 502, 503])
            compare(Api.flushVerdict(st), "keep", String(st))
        for (const st of [400, 403, 404, 409, 422])
            compare(Api.flushVerdict(st), "drop", String(st))
    }

    // a start with an `at` far in the past is refused with 400: the action is dropped, the next one goes on
    function test_flush_drops_a_refused_action_on_400() {
        const failed = []
        const h = e => failed.push(e)
        Api.queueFailed.connect(h)
        Api.queue = [{ path: "/api/start", body: { project: "bad", at: "2000-01-01T10:00" } }]
        Api.flushQueue()
        tryVerify(() => Api.queue.length === 0, 5000)
        compare(failed.length, 1)
        Api.queueFailed.disconnect(h)
    }

    // unreachable: the head stays (and so does everything behind it)
    function test_flush_keeps_the_head_when_unreachable() {
        Api.serverUrl = dead
        Api.queue = [{ path: "/api/stop", body: {} }, { path: "/api/stop", body: {} }]
        Api.flushQueue()
        tryVerify(() => !Api.flushing, 5000)
        compare(Api.queue.length, 2)
    }

    function test_queue_is_cleared_when_the_user_changes() {
        Api.queue = [{ path: "/api/stop", body: {} }]
        Api.setServer(testServer, "someone-else", "pw")
        compare(Api.queue.length, 0)
        compare(JSON.parse(Api.offline.queueJson).length, 0)
        Api.setServer(testServer, "", "")
    }

    function test_queue_is_cleared_when_the_url_changes() {
        Api.queue = [{ path: "/api/stop", body: {} }]
        Api.setServer(dead, "", "")
        compare(Api.queue.length, 0)
    }

    // a flush that was on its way when the queue was replaced must not take the first action of the new one
    function test_stale_flush_does_not_eat_the_new_queue() {
        Api.queue = [{ path: "/api/stop", body: {} }]
        Api.flushQueue()                       // a request to the test server is out
        compare(Api.flushing, true)
        Api.setServer(dead, "other", "pw")     // replaces the queue (and the server)
        Api.queue = [{ path: "/api/stop", body: { at: "2026-01-01T10:00" } }]
        Api.saveQueue()
        wait(800)                              // the old answer arrives
        compare(Api.queue.length, 1, "the new queue lost its head")
        compare(Api.queue[0].body.at, "2026-01-01T10:00")
        Api.setServer(testServer, "", "")
    }

    function test_a_non_empty_queue_still_queues_new_actions_in_order() {
        Api.serverUrl = dead
        Api.queue = [{ path: "/api/pause", body: { at: "2026-01-01T10:00" } }]
        let queued = false
        Api.timerAction("/api/start", {}, null, null, () => queued = true)
        verify(queued)
        compare(Api.queue.map(i => i.path), ["/api/pause", "/api/start"])
    }

    // ---- tray and hotkey with a queue ---------------------------------------------

    function test_tray_decides_from_the_queue() {
        const c = createTemporaryObject(ctl, tc)
        const working = { state: "working" }
        compare(c.stateFor(working, []), "working")
        compare(c.stateFor(working, [{ path: "/api/pause", body: {} }]), "break")
        compare(c.stateFor(working, [{ path: "/api/stop", body: {} }]), "stopped")
        compare(c.stateFor({ state: "stopped" }, [{ path: "/api/start", body: {} }]), "working")
        compare(c.stateFor(null, []), "stopped")
    }

    function test_two_offline_hotkey_presses_do_not_queue_two_pauses() {
        const c = createTemporaryObject(ctl, tc)
        Api.serverUrl = dead
        Api.status = { state: "working", chips: { break_types: ["walk"] }, resume: null }
        // the first press (working: pause) was queued
        compare(c.toggleRequestFor(c.stateFor(Api.status, Api.queue), "walk").path, "/api/pause")
        Api.queue = [{ path: "/api/pause", body: { type: "walk", at: "2026-01-01T10:00" } }]
        // the queue says "break": the second press resumes instead of queueing another pause
        compare(c.toggleRequestFor(c.stateFor(Api.status, Api.queue), "walk").path, "/api/start")
        c.toggle()
        tryVerify(() => Api.queue.length === 2, 3000)
        compare(Api.queue.map(i => i.path), ["/api/pause", "/api/start"])
    }

    function test_tray_tooltip_counts_waiting_actions() {
        const c = createTemporaryObject(ctl, tc)
        compare(c.tooltipFor({ state: "stopped" }, 0, 0, true, 2), "Worklog · stopped · 2 action(s) waiting")
    }

    // ---- Start and Pause bodies -----------------------------------------------------

    function test_start_body_resumes_the_last_work_block() {
        Api.status = { resume: { type: "dev", project: "alpha" }, chips: { break_types: ["walk", "eat"] } }
        compare(JSON.stringify(Api.startBody("", "")), JSON.stringify({ type: "dev", project: "alpha" }))
        compare(JSON.stringify(Api.startBody("ops", "")), JSON.stringify({ type: "ops" }))
        compare(JSON.stringify(Api.startBody("", "beta")), JSON.stringify({ project: "beta" }))
        Api.status = { resume: null }
        compare(JSON.stringify(Api.startBody("", "")), "{}")
        Api.status = null
        compare(JSON.stringify(Api.startBody("", "")), "{}")
    }

    function test_pause_body_uses_the_servers_first_break_type_or_none() {
        Api.status = { chips: { break_types: ["walk", "eat"] } }
        compare(Api.defaultBreak(), "walk")
        compare(JSON.stringify(Api.pauseBody("")), JSON.stringify({ type: "walk" }))
        compare(JSON.stringify(Api.pauseBody("eat")), JSON.stringify({ type: "eat" }))
        Api.status = null
        compare(Api.defaultBreak(), "")
        compare(JSON.stringify(Api.pauseBody("")), "{}")
    }

    // ---- small helpers ----------------------------------------------------------------

    function test_one_decimal_and_english_dates() {
        compare(Api.fmtH1(7.54), "7.5 h")
        compare(Api.fmtH1(8), "8 h")
        compare(Api.fmtDay("2026-10-20"), "Tue 20 Oct")
        compare(Api.leftOrExtra(6.04, 7.5, true), "1.5 h left")
    }

    function test_faint_follows_the_webs_contrast_fix() {
        verify(Api.faint.toString().length > 0)
        verify(Api.seriesOther !== Api.faint)
    }

    function test_shortcuts_ignore_text_fields_and_boxes() {
        const win = createTemporaryObject(winComp, tc)
        const tf = createTemporaryObject(fieldComp, win.contentItem)
        const bt = createTemporaryObject(buttonComp, win.contentItem)
        verify(!Api.focusFree(tf))
        verify(Api.focusFree(bt))
        verify(Api.focusFree(null))
    }

    // ---- BlockDialog ---------------------------------------------------------------------

    function makeDialog() {
        const win = createTemporaryObject(winComp, tc)
        const dlg = dlgComp.createObject(win.contentItem)
        verify(dlg)
        return dlg
    }
    readonly property var closed: ({ id: 7, date: "2026-03-02", start: "09:00", end: "10:00", type: "dev", project: "p", client: "c", billable: true })

    function test_closed_block_cannot_lose_its_end() {
        const dlg = makeDialog()
        dlg.editBlock(closed)
        verify(dlg.needsEnd)
        verify(dlg.valid)
        dlg.endField.text = ""
        verify(!dlg.valid, "an empty end would reopen a closed block")
        dlg.close()
    }

    function test_running_block_may_keep_an_empty_end() {
        const dlg = makeDialog()
        dlg.editBlock({ id: 8, date: Api.today(), start: "09:00", end: null, type: "dev", project: "", client: "" })
        verify(!dlg.needsEnd)
        verify(dlg.valid)
        dlg.close()
    }

    function test_end_must_be_after_start() {
        const dlg = makeDialog()
        dlg.editBlock(closed)
        dlg.endField.text = "08:30"
        compare(dlg.timeProblem, "End must be after start")
        verify(!dlg.valid)
        dlg.endField.text = "09:00"
        verify(!dlg.valid)
        dlg.endField.text = "1000"
        compare(dlg.timeProblem, "")
        verify(dlg.valid)
        compare(dlg.endProblem("9:30", "9:00"), "End must be after start")
        compare(dlg.endProblem("9:30", ""), "")
        dlg.close()
    }

    // ---- Find page -----------------------------------------------------------------------

    function test_find_add_twice_puts_in_once() {
        const p = createTemporaryObject(findComp, tc, { width: tc.width, height: tc.height })
        p.mode = "add"
        p.target = "training"
        const date = Api.addDays(Api.today(), 3)
        p.addDate = date
        p.addDateChosen = true
        p.what = "Qt twice test"
        p.addStart = "1100"
        p.addEnd = "12:00"
        p.add()
        verify(p.putting)
        p.add()                                  // a second tap or Enter while it is on its way
        tryVerify(() => p.putDone, 5000)
        verify(!p.putting)
        const info = p.info
        p.add()                                  // done: Enter again does nothing
        compare(p.info, info)
        verify(!p.putting)
        // editing the text makes a new entry possible
        p.what = "Qt twice test 2"
        p.putDone = false                        // what onTextEdited does
        verify(!p.putting)
        let week = null
        Api.request("GET", "/api/balance/week?" + Api.query({ start: date }), undefined, d => week = d, e => fail(e))
        tryVerify(() => week !== null, 5000)
        const mine = week.blocks.filter(x => x.title === "Qt twice test" && x.date === date)
        compare(mine.length, 1, "the block was put in twice")
        for (const b of mine)
            Api.request("POST", "/api/balance/blocks/" + b.id + "/reject", undefined, () => {}, e => fail(e))
        wait(300)
    }

    function test_find_default_date_follows_today_until_chosen() {
        const p = createTemporaryObject(findComp, tc, { width: tc.width, height: tc.height })
        p.addDate = "2001-01-01"
        p.visible = false
        p.visible = true
        compare(p.addDate, Api.today())
        p.addDate = "2001-01-01"
        p.addDateChosen = true
        p.visible = false
        p.visible = true
        compare(p.addDate, "2001-01-01")
    }

    // ---- Idle question ---------------------------------------------------------------------

    function test_idle_question_stays_when_the_break_could_not_be_logged() {
        const w = createTemporaryObject(idle, tc)
        Api.serverUrl = dead
        const span = { startMs: Date.now() - 1800000, endMs: Date.now(), minutes: 30, block: { type: "dev", project: "p" } }
        w.pending = span
        w.logAsBreak()
        tryVerify(() => !w.sending, 5000)
        verify(w.asking, "the question was lost")
        verify(w.error !== "")
        w.keepAsWork()
        verify(!w.asking)
    }

    // ---- Settings -------------------------------------------------------------------------

    function test_saving_one_card_keeps_edits_in_another() {
        const p = createTemporaryObject(settingsComp, tc, { width: tc.width, height: tc.height })
        tryVerify(() => p.connected === true, 5000)
        p.weekFieldItem.text = "12"                // typed, not saved
        p.reload("rate")                           // what saving the rate card does afterwards
        tryVerify(() => p.connected === true, 5000)
        wait(300)
        compare(p.weekFieldItem.text, "12")
        p.reload()                                 // a full reload fills everything again
        tryVerify(() => p.weekFieldItem.text !== "12", 5000)
    }

    function test_setserver_reports_nothing_when_the_password_is_stored() {
        compare(Api.setServer(testServer, "", ""), "")
    }

    // ---- Week and Reports ---------------------------------------------------------------

    function test_week_reject_of_an_approved_block_asks_first() {
        const p = createTemporaryObject(weekComp, tc, { width: tc.width, height: tc.height })
        tryVerify(() => p.weekData !== null, 5000)
        p.reject({ id: 424242, state: "approved" })
        compare(p.confirmId, 424242)
    }

    function test_week_outlook_clears_when_the_week_changes() {
        const p = createTemporaryObject(weekComp, tc, { width: tc.width, height: tc.height })
        tryVerify(() => p.weekData !== null, 5000)
        p.outlook = "some list"
        p.start = Api.addDays(p.weekData.start, 7)
        compare(p.outlook, "")
    }

    function test_reports_range_problems() {
        const p = createTemporaryObject(reportsComp, tc, { width: tc.width, height: tc.height })
        compare(p.rangeProblem("", ""), "")
        compare(p.rangeProblem("2026-01-01", "2026-02-01"), "")
        verify(p.rangeProblem("2026-13-45", "") !== "")
        verify(p.rangeProblem("2026-1", "") !== "")
        compare(p.rangeProblem("2026-03-01", "2026-02-01"), "From is after To.")
        compare(p.periodLabel("2026-43"), "2026-43")
    }
}
