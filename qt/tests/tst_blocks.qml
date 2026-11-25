import QtQuick
import QtQuick.Controls
import QtTest
import WorkLogApp

// BlockDialog (validity, changed fields), Api.normTime, BlockList's gaps, QueueState and the DatePicker's grid.
TestCase {
    id: tc
    name: "Blocks"
    width: 480
    height: 820
    visible: true
    when: windowShown

    Component { id: dlgComp; BlockDialog {} }
    Component { id: listComp; BlockList {} }
    Component { id: pickerComp; DatePicker {} }
    Component { id: queueComp; QueueState {} }
    Component { id: winComp; ApplicationWindow { width: 480; height: 820; visible: true } }

    function initTestCase() {
        Api.serverUrl = testServer
        Api.username = ""
    }

    // ---- ProposalCard: which meetings it lists ----------------------------------
    Component { id: proposalComp; ProposalCard {} }
    function test_proposalCard_rows() {
        const all = [{ start: "09:00", end: "09:30", title: "open" },
                     { start: "10:00", end: "10:30", title: "done", logged: true, dismissed: false },
                     { start: "11:00", end: "11:30", title: "no", logged: false, dismissed: true }]
        const card = createTemporaryObject(proposalComp, tc, { meetings: all })
        compare(card.rows.map(m => m.title), ["open", "done", "no"])   // Timer and Log alike: everything, marked
        verify(card.visible)
        card.showAll = false                               // only what still needs an answer
        compare(card.rows.map(m => m.title), ["open"])
        card.meetings = all.slice(1)
        verify(!card.visible)
        compare(card.title, "Work calendar · the day's meetings")
    }

    // ---- Api.normTime ----------------------------------------------------------
    function test_normTime_data() {
        return [
            { tag: "700", input: "700", want: "07:00" },
            { tag: "dot", input: "7.00", want: "07:00" },
            { tag: "h", input: "19h00", want: "19:00" },
            { tag: "colon", input: " 7:05 ", want: "07:05" },
            { tag: "already", input: "19:30", want: "19:30" },
            { tag: "hour too big", input: "2500", want: "2500" },
            { tag: "minute too big", input: "7:75", want: "7:75" },
            { tag: "empty", input: "", want: "" },
            { tag: "text", input: " abc ", want: "abc" },
        ]
    }
    function test_normTime(data) {
        compare(Api.normTime(data.input), data.want)
    }

    // ---- BlockDialog -----------------------------------------------------------
    function makeDialog() {
        const win = createTemporaryObject(winComp, tc)
        verify(win)
        const dlg = dlgComp.createObject(win.contentItem)
        verify(dlg)
        return dlg
    }

    readonly property var sample: ({ id: 7, date: "2026-03-02", start: "09:00", end: "10:00", type: "dev",
                                     project: "p", client: "c", billable: true })

    function test_dialog_today_new_block_may_stay_open() {
        const dlg = makeDialog()
        dlg.typeSuggestions = ["dev"]
        dlg.newBlock(Api.today())
        verify(!dlg.needsEnd)
        dlg.startField.text = "7:00"
        dlg.typeField.editText = "dev"
        verify(dlg.valid, "today: an empty end means running")
        dlg.close()
    }

    // Return saves from the Type, Project and Client fields too, and they complete from their lists
    function test_dialog_enter_saves_and_fields_complete() {
        const dlg = makeDialog()
        dlg.typeSuggestions = ["dev", "child", "Child", ""]
        dlg.blocks = [{ id: 1, start: "08:00", end: "09:00", type: "dev", project: "alpha", client: "acme" }]
        let saves = 0
        dlg.accepted.connect(() => saves++)
        dlg.editBlock(sample)                                // nothing changed: accepting sends nothing
        tryVerify(() => dlg.opened, 2000)
        compare(dlg.typeField.count, 2, "no empty or repeated suggestion")
        compare(dlg.typeField.text, "dev")
        compare(dlg.projectField.text, "p", "a new list does not replace the block's own text")
        compare(dlg.clientField.text, "c")
        verify(dlg.projectField.find("alpha") >= 0)
        verify(dlg.clientField.find("acme") >= 0)
        // the box itself (reached by forceActiveFocus) and its text (a click, Tab)
        for (const f of [dlg.typeField, dlg.projectField, dlg.clientField,
                         dlg.typeField.contentItem, dlg.projectField.contentItem, dlg.clientField.contentItem]) {
            dlg.open()
            tryVerify(() => dlg.opened, 2000)
            f.forceActiveFocus()
            tryVerify(() => f.activeFocus, 2000)
            const before = saves
            keyClick(Qt.Key_Return)
            compare(saves, before + 1, "Return saves")
            tryVerify(() => !dlg.visible, 2000)
        }
        dlg.open()
        tryVerify(() => dlg.opened, 2000)
        dlg.typeField.contentItem.forceActiveFocus()
        tryVerify(() => dlg.typeField.contentItem.activeFocus, 2000)
        dlg.typeField.contentItem.selectAll()
        keyClick(Qt.Key_C)
        keyClick(Qt.Key_H)
        compare(dlg.typeField.text, "child", "typing completes from the list")
        dlg.typeField.text = "   "                           // an invalid form is not saved
        const n = saves
        keyClick(Qt.Key_Return)
        compare(saves, n)
        verify(dlg.visible)
        dlg.close()
    }

    function test_dialog_other_day_new_block_needs_an_end() {
        const dlg = makeDialog()
        dlg.newBlock(Api.addDays(Api.today(), -3))
        verify(dlg.needsEnd)
        compare(dlg.startField.text, "", "no 'now' prefill on another day")
        dlg.startField.text = "09:00"
        dlg.typeField.editText = "dev"
        verify(!dlg.valid, "empty end on another day")
        dlg.endField.text = "10:00"
        verify(dlg.valid)
        dlg.typeField.editText = "   "
        verify(!dlg.valid, "blank type")
        dlg.close()
    }

    function test_dialog_other_day_prefills_the_last_end() {
        const dlg = makeDialog()
        dlg.blocks = [{ id: 1, start: "08:00", end: "09:30" }, { id: 2, start: "09:30", end: "11:00" }]
        dlg.newBlock("2020-01-06")
        compare(dlg.startField.text, "11:00")
        dlg.close()
    }

    // an edge moved into a neighbour: the neighbour is trimmed, never left overlapping
    function test_dialog_overlap_fix() {
        const dlg = makeDialog()
        const a = { id: 1, start: "12:30", end: "13:00", type: "dev" }
        const b = { id: 2, start: "13:00", end: null, type: "meet" }
        dlg.blocks = [a, b]
        let fix = dlg.overlapFix(b, "start", "12:55")
        compare(fix.block.id, 1)
        compare(fix.fields, { end: "12:55" })
        compare(fix.undo, { end: "13:00" })
        compare(dlg.overlapFix(b, "start", "13:10"), null, "moved away: a gap, only the offer")
        compare(dlg.overlapFix(b, "start", "12:30"), null, "swallowed whole: left alone")
        fix = dlg.overlapFix(a, "end", "13:20")
        compare(fix.block.id, 2)
        compare(fix.fields, { start: "13:20", require_open: true })
        compare(fix.undo, { start: "13:00", require_open: true })
        compare(dlg.overlapFix(a, "end", "12:50"), null)
        compare(dlg.overlapFix(a, "end", ""), null)
    }

    // saving an auto-closed block untouched still sends its end: that is what clears the review notice
    function test_auto_closed_block_is_confirmed_by_saving() {
        const dlg = makeDialog()
        dlg.editBlock(Object.assign({}, sample, { auto_closed: true }))
        verify(dlg.needsConfirm)
        compare(JSON.stringify(dlg.changedFields()), JSON.stringify({ end: sample.end }))
        dlg.close()
    }

    function test_dialog_changed_fields() {
        const dlg = makeDialog()
        dlg.editBlock(sample)
        compare(JSON.stringify(dlg.changedFields()), "{}", "untouched form sends nothing")
        dlg.startField.text = "930"
        dlg.endField.text = ""
        dlg.typeField.editText = "  dev  "
        const c = dlg.changedFields()
        compare(c.start, "09:30")
        compare(c.end, null)
        verify(!("type" in c), "type is compared trimmed")
        verify(!("date" in c), "date only when it changed")
        dlg.date = "2026-03-03"
        compare(dlg.changedFields().date, "2026-03-03")
        dlg.billableBox.checked = false
        compare(dlg.changedFields().billable, false)
        dlg.close()
    }

    function test_dialog_edit_running_block_needs_no_end() {
        const dlg = makeDialog()
        dlg.editBlock({ id: 8, date: Api.addDays(Api.today(), -1), start: "09:00", end: null, type: "dev", project: "", client: "" })
        verify(!dlg.needsEnd)
        verify(dlg.valid)
        dlg.close()
    }

    // ---- BlockList.items -------------------------------------------------------
    function test_list_gaps() {
        const list = createTemporaryObject(listComp, tc, { blocks: [
            { id: 2, start: "11:00", end: "12:00", work_type: "work" },
            { id: 1, start: "09:00", end: "10:00", work_type: "work" },
        ] })
        verify(list)
        compare(list.items.length, 3)
        compare(list.items[0].id, 1)
        verify(list.items[1].gap)
        compare(list.items[1].start, "10:00")
        compare(list.items[1].end, "11:00")
        compare(list.minutes("10:00", "11:30"), 90)
        // closing the gap: the block before it ends later, or the block after it starts earlier
        compare(list.items[1].prev.id, 1)
        compare(list.items[1].next.id, 2)
        compare(list.stretchFields(list.items[1], true), { end: "11:00" })
        compare(list.stretchFields(list.items[1], false), { start: "10:00" })
    }

    function test_list_gap_neighbours() {
        // the block before a gap is the one that ends last, not the one that starts last
        const list = createTemporaryObject(listComp, tc, { blocks: [
            { id: 1, start: "09:00", end: "12:00", work_type: "work" },
            { id: 2, start: "10:00", end: "11:00", work_type: "work" },
            { id: 3, start: "13:00", end: null, work_type: "work" },
        ] })
        const gap = list.items[2]
        verify(gap.gap)
        compare(gap.start, "12:00")
        compare(gap.prev.id, 1)
        compare(gap.next.id, 3)
        // the block after it is still running: a stale snapshot must get a 409
        compare(list.stretchFields(gap, false), { start: "12:00", require_open: true })
    }

    // touching blocks that say the same get a seam row (Merge); any difference, or a gap, gets none
    function test_list_seam() {
        const mk = (id, s, e, extra) => Object.assign({ id: id, start: s, end: e, type: "dev", project: "p", work_type: "work" }, extra || {})
        const list = createTemporaryObject(listComp, tc, { blocks: [mk(1, "09:00", "10:00"), mk(2, "10:00", "11:00"),
            mk(3, "11:00", "12:00", { project: "q" }), mk(4, "12:30", null, { project: "q" })] })
        compare(list.items.length, 6)
        verify(list.items[1].seam)
        compare(list.items[1].prev.id, 1)
        verify(!list.items[3].seam && !list.items[3].gap, "another project: no seam")
        verify(list.items[4].gap)
        verify(list.mergeable(mk(1, "09:00", "10:00"), mk(2, "10:00", null)), "the running block can be merged into")
        verify(!list.mergeable(mk(1, "09:00", "10:00", { billable: true }), mk(2, "10:00", "11:00")))
    }

    function test_dialog_split_and_again() {
        const dlg = makeDialog()
        const b = { id: 1, date: "2020-01-06", start: "09:00", end: "12:00", type: "dev", project: "p", client: "", work_type: "work" }
        compare(dlg.againBody(b), { type: "dev", project: "p" })
        dlg.editBlock(b)
        dlg.splitBlock()
        compare(dlg.block, null)
        compare(dlg.splitOf.id, 1)
        compare(dlg.date, "2020-01-06")
        compare(dlg.startField.text, "")
        verify(dlg.title.indexOf("Split") === 0)
        dlg.close()
        dlg.newBlock("2020-01-06")
        compare(dlg.splitOf, null)
        dlg.close()
    }

    function test_list_overlap_makes_no_false_gap() {
        const list = createTemporaryObject(listComp, tc, { blocks: [
            { id: 1, start: "09:00", end: "12:00", work_type: "work" },
            { id: 2, start: "10:00", end: "11:00", work_type: "work" },   // inside the first
            { id: 3, start: "11:30", end: "12:00", work_type: "work" },   // starts before the first ended
        ] })
        compare(list.items.length, 3)
        verify(!list.items.some(i => i.gap))
    }

    function test_list_open_block_covers_the_rest_of_the_day() {
        const list = createTemporaryObject(listComp, tc, { blocks: [
            { id: 1, start: "09:00", end: null, work_type: "work" },
            { id: 2, start: "15:00", end: "16:00", work_type: "work" },
        ] })
        verify(!list.items.some(i => i.gap), "an open block never leaves a gap after it")
        // and a gap before an open block is found
        const l2 = createTemporaryObject(listComp, tc, { blocks: [
            { id: 1, start: "08:00", end: "09:00", work_type: "work" },
            { id: 2, start: "10:00", end: null, work_type: "work" },
        ] })
        compare(l2.items.length, 3)
        verify(l2.items[1].gap)
    }

    // ---- QueueState ------------------------------------------------------------
    function test_queue_implied_state() {
        const q = createTemporaryObject(queueComp, tc)
        compare(q.implied([]), null)
        compare(q.implied(null), null)
        const at = "2026-03-02T09:00"
        let s = q.implied([{ path: "/api/start", body: { type: "dev", project: "p", at: at } }])
        compare(s.state, "working")
        compare(s.type, "dev")
        compare(s.project, "p")
        compare(s.at, at)
        s = q.implied([{ path: "/api/start", body: { at: at } }, { path: "/api/pause", body: { type: "eat", at: "2026-03-02T12:00" } }])
        compare(s.state, "break")
        compare(s.type, "eat")
        compare(s.at, "2026-03-02T12:00")
        s = q.implied([{ path: "/api/start", body: { at: at } }, { path: "/api/stop", body: { at: "2026-03-02T13:00" } }])
        compare(s.state, "stopped")
    }

    function test_queue_elapsed() {
        const q = createTemporaryObject(queueComp, tc)
        const now = new Date(2026, 2, 2, 10, 30, 15)
        compare(q.elapsedSince("2026-03-02T09:00", now), 90 * 60 + 15)
        compare(q.elapsedSince("2026-03-02T11:00", now), 0, "never negative")
        compare(q.elapsedSince("", now), 0)
        compare(q.elapsedSince("2026-03-01T23:00", now), 11 * 3600 + 30 * 60 + 15, "from yesterday")
    }

    // ---- DatePicker grid -------------------------------------------------------
    function grid(y, m) {
        const p = createTemporaryObject(pickerComp, tc)
        verify(p)
        return p.monthGrid(y, m)
    }

    function test_grid_month_starting_on_monday() {
        const g = grid(2024, 3)   // April 2024: Monday the 1st
        compare(g[0].days[0].iso, "2024-04-01")
        verify(g[0].days[0].inMonth)
        compare(g[0].week, 14)
        compare(g.length, 5)
        compare(g[4].days[6].iso, "2024-05-05")
        verify(!g[4].days[6].inMonth)
    }

    function test_grid_month_starting_on_sunday() {
        const g = grid(2024, 8)   // September 2024: Sunday the 1st
        compare(g[0].days[0].iso, "2024-08-26")
        verify(!g[0].days[0].inMonth)
        compare(g[0].days[6].iso, "2024-09-01")
        verify(g[0].days[6].inMonth)
        compare(g[0].week, 35)
        compare(g.length, 6)
        compare(g[5].days[0].iso, "2024-09-30")
    }

    function test_grid_iso_week_one_starts_in_december() {
        const p = createTemporaryObject(pickerComp, tc)
        // 2025-12-29 is the Monday of ISO week 1 of 2026
        compare(p.isoWeek("2025-12-29"), 1)
        compare(p.isoWeek("2026-01-04"), 1)
        compare(p.isoWeek("2025-12-28"), 52)
        // 2021-01-01 still belongs to week 53 of 2020
        compare(p.isoWeek("2021-01-01"), 53)
        const g = p.monthGrid(2025, 11)   // December 2025
        const last = g[g.length - 1]
        compare(last.days[0].iso, "2025-12-29")
        compare(last.week, 1)
    }

    function test_picker_picks_and_closes() {
        const win = createTemporaryObject(winComp, tc)
        const p = pickerComp.createObject(win.contentItem)
        verify(p)
        let got = ""
        p.picked.connect(iso => got = iso)
        p.openFor("2026-03-02")
        tryVerify(() => p.opened, 2000)
        compare(p.cursor, "2026-03-02")
        keyClick(Qt.Key_Right)
        keyClick(Qt.Key_Down)
        compare(p.cursor, "2026-03-10")
        keyClick(Qt.Key_Return)
        compare(got, "2026-03-10")
        tryVerify(() => !p.visible, 2000)
    }
}
