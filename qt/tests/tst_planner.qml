import QtQuick
import QtQuick.Controls
import QtTest
import WorkLogApp

// The Day planner's Move dialog, the timer row, "work on this", the PDF upload, the Back key and the
// break-type rename. Pure logic is called directly; the upload and the rename run against the real server.
TestCase {
    id: tc
    name: "Planner"
    width: 480
    height: 900
    visible: true
    when: windowShown

    Component { id: plannerPage; PlannerPage {} }
    Component { id: moveDialog; MoveDialog {} }
    Component { id: settingsPage; SettingsPage {} }
    Component { id: mainWindow; Main {} }
    Component { id: uploaderC; FileUploader {} }

    function initTestCase() {
        Api.serverUrl = testServer
        Api.username = ""
        Api.trayCapable = false   // the tests run on a QGuiApplication: Qt Labs Platform has no tray there
    }

    // a Main window as it looks with a saved login (no login opens Settings)
    function newMain() {
        Api.username = "tester"
        const w = createTemporaryObject(mainWindow, null)
        Api.username = ""
        verify(w)
        w.current = w.navTimer
        return w
    }

    // a day shaped like the /api/day answer, as far as these helpers read it
    readonly property var day: ({
        date: "2026-03-02", is_today: true, now: "10:00",
        training: { time: "07:00", end: "08:00", session: "Easy run", distance_km: 8 },
        timeline: [
            { layer: "protected", kind: "run", id: 11, state: "approved", start: "07:00", end: "08:00", title: "Run" },
            { layer: "protected", kind: "stop", id: 12, state: "approved", start: "18:00", end: "18:30", title: "Hard stop" },
            { layer: "personal", uid: "u1", source: "personal", start: "12:00", end: "12:20", title: "Dentist" },
            { layer: "work", start: "09:00", end: "10:00", title: "Standup" }
        ],
        work: { status: { state: "stopped", chips: { types: ["dev", "meeting", "a", "b", "c", "d", "e"] } } }
    })

    // ---- Move ---------------------------------------------------------------------------------------

    function test_move_resolves_each_kind() {
        const m = createTemporaryObject(moveDialog, tc)
        const run = m.resolveItem(day, "run", 0, "")
        compare(run.title, "Easy run")
        compare(run.minutes, 60)
        compare(run.ref.block_id, 11)
        compare(run.ref.start, "07:00")
        const blk = m.resolveItem(day, "block", 12, "")
        compare(blk.minutes, 30)
        compare(blk.kind, "personal")
        compare(blk.ref.kind, "block")
        const ev = m.resolveItem(day, "personal", 0, "u1")
        compare(ev.minutes, 20)
        compare(ev.ref.calendar, "personal")
        compare(m.resolveItem(day, "block", 11, "").kind, "run")
    }

    function test_move_missing_items_throw_the_web_wording() {
        const m = createTemporaryObject(moveDialog, tc)
        let msg = ""
        try { m.resolveItem(day, "block", 99, "") } catch (e) { msg = e.message }
        compare(msg, "No such block on 2026-03-02.")
        try { m.resolveItem(day, "personal", 0, "nope") } catch (e) { msg = e.message }
        compare(msg, "That calendar event is not in today's snapshot.")
        try { m.resolveItem({ date: "2026-03-03", timeline: [], training: null }, "run", 0, "") } catch (e) { msg = e.message }
        compare(msg, "No planned session on 2026-03-03.")
        // a short event is moved as 15 minutes at least, a run as 30
        compare(m.resolveItem({ date: "d", timeline: [{ layer: "personal", uid: "x", start: "10:00", end: "10:05", title: "t" }] }, "personal", 0, "x").minutes, 15)
        compare(m.resolveItem({ date: "d", timeline: [], training: { time: "07:00", end: "07:10", session: "s" } }, "run", 0, "").minutes, 30)
        compare(m.resolveItem({ date: "d", timeline: [], training: { time: "07:00", session: "s" } }, "run", 0, "").ref.end, "08:00")
    }

    function test_move_write_choices() {
        const m = createTemporaryObject(moveDialog, tc)
        const run = m.writeDefs(m.resolveItem(day, "run", 0, ""))
        compare(run.map(d => d.key), ["session_time", "block", "mirror_busy"])
        compare(run.map(d => d.on), [true, true, false])
        // no block to follow: that write starts off
        const noBlock = m.writeDefs({ ref: { kind: "run", block_id: null } })
        compare(noBlock[1].on, false)
        compare(m.writeDefs({ ref: { kind: "block" } }).map(d => d.key), ["block"])
        compare(m.writeDefs({ ref: { kind: "personal", calendar: "x" } }).map(d => d.key), ["gcal", "mirror_busy"])
    }

    function test_move_slots_and_texts() {
        const m = createTemporaryObject(moveDialog, tc)
        const found = [{ date: "2026-03-02", start: "09:00", end: "10:00", verdict: "clash", reasons: ["x"] },
                       { date: "2026-03-02", start: "11:00", end: "12:00", verdict: "fits", reasons: ["current slot"], best: true },
                       { date: "2026-03-04", start: "07:00", end: "08:00", verdict: "ask_trainer", reasons: ["another day", "current slot"] },
                       { date: "2026-03-02", start: "13:00", end: "14:00", verdict: "tight", reasons: [] }]
        const shown = m.shownSlots(found)
        compare(shown.length, 3)   // the clash is gone
        verify(m.isCurrent(shown[0]))
        verify(!m.isCurrent(shown[1]))
        compare(m.slotTitle(shown[0], "2026-03-02"), "11:00–12:00")
        verify(m.slotTitle(shown[1], "2026-03-02").indexOf("07:00–08:00") > 0)
        verify(m.slotTitle(shown[1], "2026-03-02").indexOf("·") > 0)   // another day shows its date
        compare(m.slotHint(shown[1]), "another day")
        compare(m.slotHint(shown[2]), "tight")   // no reasons: the verdict says it
        compare(m.shownSlots(Array.from({ length: 20 }, (_, i) => ({ date: "d", start: "0" + i, end: "x", verdict: "fits", reasons: [] }))).length, 12)
        const item = m.resolveItem(day, "run", 0, "")
        compare(m.askLine(item, shown[1]), "move my Easy run from 2026-03-02 to 2026-03-04")
    }

    function test_move_body_and_result() {
        const m = createTemporaryObject(moveDialog, tc)
        const item = m.resolveItem(day, "run", 0, "")
        const slot = { date: "2026-03-02", start: "17:00", end: "18:00" }
        const body = m.moveBody(item, slot, { session_time: true, block: false, mirror_busy: true })
        compare(body.date, "2026-03-02")
        compare(body.start, "17:00")
        compare(body.writes, ["session_time", "mirror_busy"])
        compare(body.ref.kind, "run")
        compare(m.resultLine(item, slot, { queued: [1], blocks: [{}] }), "Moved Easy run to 17:00. 1 write queued for the next sync, block moved.")
        compare(m.resultLine(item, slot, { queued: [1, 2], blocks: [] }), "Moved Easy run to 17:00. 2 writes queued for the next sync.")
    }

    function test_move_preview_hides_the_item_and_shows_the_slot() {
        const m = createTemporaryObject(moveDialog, tc)
        const item = m.resolveItem(day, "run", 0, "")
        // nothing picked: the whole day, the run included
        compare(m.previewRows(day, item, null).length, 4)
        const rows = m.previewRows(day, item, { date: "2026-03-02", start: "17:00", end: "18:00" })
        compare(rows.length, 4)   // the run left, the ghost came
        verify(!rows.some(r => r.text === "Run"))
        const ghost = rows.find(r => r.ghost)
        compare(ghost.start, "17:00")
        compare(rows.map(r => r.start), ["09:00", "12:00", "17:00", "18:00"])   // sorted by start
        // another day: no ghost on this one
        verify(!m.previewRows(day, item, { date: "2026-03-03", start: "17:00", end: "18:00" }).some(r => r.ghost))
    }

    function test_move_dialog_opens_with_the_error_when_the_item_is_missing() {
        const m = createTemporaryObject(moveDialog, tc)
        m.openFor({ date: "2026-03-02", timeline: [], training: null }, "run", 0, "")
        compare(m.error, "No planned session on 2026-03-02.")
        compare(m.item, null)
        verify(m.opened || m.visible)
        m.close()
    }

    function test_planner_has_move_links_and_no_error_on_a_real_day() {
        const p = createTemporaryObject(plannerPage, tc, { width: tc.width, height: tc.height })
        tryVerify(() => p.day !== null || p.error !== "", 5000)
        compare(p.error, "")
        // the real day has no session: the dialog says so instead of failing
        p.openMove("run", 0, "")
        compare(p.moveDialogItem.error.indexOf("No planned session"), 0)
        p.moveDialogItem.close()
    }

    // ---- the timer row and "work on this" -------------------------------------------------------------

    function test_timer_row_text() {
        const p = createTemporaryObject(plannerPage, tc, { width: tc.width, height: tc.height })
        compare(p.timerState(null), "none")
        compare(p.timerState({ work: {} }), "none")
        compare(p.timerState(day), "stopped")
        compare(p.timerLine(day), "Not working")
        const working = { work: { status: { state: "working", since: "09:12", block: { id: 5, type: "dev", project: "alpha" } } } }
        compare(p.timerState(working), "working")
        compare(p.timerLine(working), "Working · dev · alpha · since 09:12")
        compare(p.timerLine({ work: { status: { state: "break", since: "10:30" } } }), "Break · since 10:30")
    }

    function test_type_chips_only_today_and_six() {
        const p = createTemporaryObject(plannerPage, tc, { width: tc.width, height: tc.height })
        compare(p.chipTypes(day), ["dev", "meeting", "a", "b", "c", "d"])
        compare(p.chipTypes({ is_today: false, work: day.work }), [])
        compare(p.chipTypes({ is_today: true, work: { status: { state: "stopped" } } }), [])
    }

    function test_work_on_this_starts_or_retitles() {
        const p = createTemporaryObject(plannerPage, tc, { width: tc.width, height: tc.height })
        const task = { id: "1", content: "Fix [the bug](https://example.com/x) now" }
        const start = p.workOnRequest(day, task, "")
        compare(start.method, "POST")
        compare(start.path, "/api/start")
        compare(start.body, { project: "Fix the bug now" })
        // the type picked while stopped goes along
        compare(p.workOnRequest(day, task, "dev").body, { project: "Fix the bug now", type: "dev" })
        // a running block is retitled in place, and only if it is still open
        const running = { work: { status: { state: "working", block: { id: 7 } } } }
        const put = p.workOnRequest(running, task, "dev")
        compare(put.method, "PUT")
        compare(put.path, "/api/blocks/7")
        compare(put.body, { project: "Fix the bug now", require_open: true })
        // the project is cut to 80 characters
        compare(p.plainTitle("x".repeat(100)).length, 80)
    }

    function test_type_chip_while_stopped_toggles_the_pending_type() {
        const p = createTemporaryObject(plannerPage, tc, { width: tc.width, height: tc.height })
        p.pickType("dev")
        compare(p.pendingType, "dev")
        p.pickType("dev")
        compare(p.pendingType, "")
    }

    // ---- the PDF upload ---------------------------------------------------------------------------------

    function test_upload_name() {
        const u = createTemporaryObject(uploaderC, tc)
        compare(u.uploadName("file:///C:/Users/x/Outlook%20Calendar.pdf", "calendar.pdf"), "Outlook Calendar.pdf")
        compare(u.uploadName("file:///home/x/cal.PDF", "calendar.pdf"), "cal.PDF")
        // a content:// document: the name after the last "/" and ":"
        compare(u.uploadName("content://com.android.providers.downloads.documents/document/primary%3ADownload%2Fweek.pdf", "calendar.pdf"), "week.pdf")
        // no usable name: the fallback
        compare(u.uploadName("content://media/external/file/42", "calendar.pdf"), "calendar.pdf")
        compare(u.uploadName("file:///tmp/notes.txt", "calendar.pdf"), "calendar.pdf")
    }

    function test_upload_a_pdf_to_the_inbox() {
        const p = createTemporaryObject(plannerPage, tc, { width: tc.width, height: tc.height })
        tryVerify(() => p.day !== null, 5000)   // the page's own first load would clear a message
        p.uploadPdf(Qt.resolvedUrl("sample.pdf"))
        tryVerify(() => p.info !== "" || p.error !== "", 5000)
        compare(p.error, "")
        verify(p.info.indexOf("Saved ") === 0, p.info)
        verify(p.info.indexOf("sample.pdf") > 0, p.info)
        verify(!p.uploaderItem.busy)
    }

    function test_upload_refuses_what_is_not_a_pdf() {
        const p = createTemporaryObject(plannerPage, tc, { width: tc.width, height: tc.height })
        tryVerify(() => p.day !== null, 5000)
        p.uploadPdf(Qt.resolvedUrl("notapdf.pdf"))
        tryVerify(() => p.error !== "", 5000)
        compare(p.error, "Upload failed: that is not a PDF")
        verify(!p.uploaderItem.busy)
        // a file that is not there
        p.uploadPdf(Qt.resolvedUrl("missing.pdf"))
        tryVerify(() => p.error.indexOf("Cannot read the file") > 0, 5000)
    }

    // ---- break types: rename ----------------------------------------------------------------------------

    function test_break_type_rename() {
        failOnWarning(/.*/)
        const p = createTemporaryObject(settingsPage, tc, { width: tc.width, height: tc.height })
        tryVerify(() => p.connected === true && p.breakList.length > 0, 5000)
        p.addBreak("Qt Walk")
        tryVerify(() => p.breakList.indexOf("qt walk") >= 0, 5000)
        p.renameBreak("qt walk", "Qt Stroll")
        tryVerify(() => p.breakList.indexOf("qt stroll") >= 0, 5000)
        verify(p.breakList.indexOf("qt walk") < 0)
        compare(p.breakError, "")
        // a taken name is refused with the server's text
        p.renameBreak("qt stroll", p.breakList[0])
        tryVerify(() => p.breakError !== "", 5000)
        verify(p.breakError.indexOf("already exists") > 0, p.breakError)
        // an unknown one too
        p.renameBreak("no such type", "x")
        tryVerify(() => p.breakError.indexOf("no such") >= 0, 5000)
        p.deleteBreak("qt stroll")
        tryVerify(() => p.breakList.indexOf("qt stroll") < 0, 5000)
    }

    // ---- the Back key ------------------------------------------------------------------------------------

    function test_back_goes_to_the_timer_and_stays_on_it() {
        const w = newMain()
        compare(w.current, w.navTimer)
        verify(!w.goBack(), "on the Timer the system gets the key")
        for (const nav of [w.navDay, w.navWeek, w.navPomodoro, w.navReports, w.navExpected, w.navFind, w.navSettings]) {
            w.current = nav
            verify(w.goBack(), "from screen " + nav)
            compare(w.current, w.navTimer)
        }
    }

    // the bottom bar has Timer, Day, Week and Pomodoro; More is selected on every other screen
    function test_more_is_selected_on_the_screens_of_its_menu() {
        const w = newMain()
        compare([w.navTimer, w.navDay, w.navWeek, w.navPomodoro, w.navReports, w.navExpected, w.navFind, w.navSettings],
                [0, 1, 2, 3, 4, 5, 6, 7])
        compare(w.titles.length, 8)
        compare(w.icons, ["timer", "day", "week", "pomodoro", "reports", "expected", "find", "settings"])
        for (const nav of [w.navTimer, w.navDay, w.navWeek, w.navPomodoro]) {
            w.current = nav
            verify(!w.inMore, "screen " + nav + " has its own button")
        }
        for (const nav of [w.navReports, w.navExpected, w.navFind, w.navSettings]) {
            w.current = nav
            verify(w.inMore, "screen " + nav + " is in the More menu")
        }
        w.closeMore()   // harmless while the menu is closed
    }

    function test_wide_bar_threshold() {
        const w = newMain()
        verify(!w.wideBarFor(480) && !w.wideBarFor(899))
        verify(w.wideBarFor(900) && w.wideBarFor(1920))
    }

    function test_back_key_is_left_to_an_open_popup() {
        const w = newMain()
        verify(!w.inOverlay(null))
        verify(!w.inOverlay(w.contentItem))
        // an item below the overlay counts, one outside it does not
        const inside = Qt.createQmlObject('import QtQuick; Item {}', w.header.Overlay.overlay)
        verify(w.inOverlay(inside))
        inside.destroy()
        verify(!w.inOverlay(tc))
    }

    // the Back key's shortcut is a sequence Qt understands (Key_Back), not a silently empty one
    function test_back_sequence_parses() {
        const sc = Qt.createQmlObject('import QtQuick; Shortcut { sequence: "Back" }', tc)
        verify(sc.nativeText !== "", "the sequence \"Back\" must parse")
        compare(sc.nativeText, "Back")
        sc.destroy()
    }

    // ---- dialogs and the on-screen keyboard -------------------------------------------------------------

    Component { id: appDialogC; AppDialog {} }
    Component { id: blockDialogC; BlockDialog {} }
    Component { id: scrollBodyC; ScrollBody {} }

    function test_dialog_area_without_keyboard() {
        const d = createTemporaryObject(appDialogC, tc)
        // 640 high, a 24 status bar and a 48 navigation bar, 8 margin: the room between them
        const a = d.area(640, 24, 48, -1, 8, 160)
        compare(a.y, 32)
        compare(a.height, 640 - 48 - 8 - 32)
        // a keyboard that is not in the window (or whose top is at the very bottom) changes nothing
        compare(d.area(640, 24, 48, 640, 8, 160).height, a.height)
        compare(d.area(640, 24, 48, 900, 8, 160).height, a.height)
    }

    function test_dialog_area_above_the_keyboard() {
        const d = createTemporaryObject(appDialogC, tc)
        // the keyboard starts at y 360: the dialog starts below the status bar and ends above the keyboard
        const a = d.area(640, 24, 48, 360, 8, 160)
        compare(a.y, 32)
        compare(a.height, 360 - 8 - 32)
        verify(a.y >= 24, "never under the status bar")
        verify(a.y + a.height <= 360, "never under the keyboard")
        // a keyboard that leaves almost nothing: not smaller than the minimum
        compare(d.area(640, 24, 48, 150, 8, 160).height, 160)
    }

    function test_dialog_stays_inside_the_window() {
        const d = createTemporaryObject(appDialogC, tc)
        verify(d.parent !== null)
        verify(d.height <= d.parent.height)
        verify(d.y >= 0)
        compare(d.keyboardTop, -1)   // no keyboard in the tests
    }

    function test_scroll_body_reveals_the_focused_field() {
        const b = createTemporaryObject(scrollBodyC, tc, { width: 200, height: 100 })
        // inside the view: nothing moves
        compare(b.contentYFor(0, 10, 30, 100, 200), 0)
        // below it: scrolled so the field ends 8 above the bottom edge
        compare(b.contentYFor(0, 150, 30, 100, 200), 88)
        // above it: scrolled up to it
        compare(b.contentYFor(120, 40, 30, 100, 200), 32)
        // never past the end of the content
        compare(b.contentYFor(0, 290, 30, 100, 150), 150)
    }

    function test_block_dialog_titles() {
        const d = createTemporaryObject(blockDialogC, tc)
        d.newBlock(Api.today())
        compare(d.title, "New block")
        d.editBlock({ id: 1, date: Api.today(), start: "09:00", end: "10:00", type: "dev" })
        compare(d.title, "Edit block")
        d.newBlock(Api.today())
        compare(d.title, "New block")   // a new block after an edit is new again
        d.close()
    }

    function test_page_height_follows_the_keyboard() {
        const w = newMain()
        compare(w.overlap(600, -1), 0)
        compare(w.overlap(600, 700), 0)
        compare(w.overlap(600, 350), 250)
        compare(w.keyboardOverlap, 0)
    }
}
