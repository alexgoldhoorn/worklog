import QtQuick
import QtQuick.Controls
import QtTest
import WorkLogApp

// The Week page against the real server (balance store on a throwaway database): it loads, shows the
// seven days, and approving or adding a block changes what it lists.
TestCase {
    id: tc
    name: "Week"
    width: 480
    height: 820
    visible: true
    when: windowShown

    Component { id: weekPage; WeekPage {} }

    function initTestCase() {
        Api.serverUrl = testServer
        Api.username = ""
    }

    function load() {
        failOnWarning(/.*/)
        const p = createTemporaryObject(weekPage, tc, { width: tc.width, height: tc.height })
        verify(p, "page did not instantiate")
        tryVerify(() => p.weekData !== null || p.error !== "", 5000)
        return p
    }

    function test_loads_seven_days() {
        const p = load()
        compare(p.error, "")
        compare(p.agenda.length, 7)
        compare(p.weekData.days.length, 7)
        compare(p.weekData.start, p.agenda[0].date)
        verify(p.agenda.some(d => d.isToday))
    }

    function test_shift_week() {
        const p = load()
        const first = p.weekData.start
        p.shift(7)
        tryVerify(() => p.weekData.start === Api.addDays(first, 7), 5000)
        p.start = ""
        tryVerify(() => p.weekData.start === first, 5000)
    }

    function test_add_block_then_reject() {
        const p = load()
        const day = p.weekData.days[0]
        let made = null
        Api.request("POST", "/api/balance/blocks",
                    { date: day, start: "19:00", end: "20:00", kind: "family", title: "Qt test block" },
                    d => made = d, e => fail(e))
        tryVerify(() => made !== null, 5000)
        tryVerify(() => p.agenda[0].items.some(i => i.text === "Qt test block"), 5000)
        const item = p.agenda[0].items.find(i => i.text === "Qt test block")
        compare(item.block.state, "approved")
        p.decide(item.block.id, "reject")
        tryVerify(() => !p.agenda[0].items.some(i => i.text === "Qt test block"), 5000)
    }

    function test_outlook_text() {
        const p = load()
        p.showOutlook()
        tryVerify(() => p.outlook !== "", 5000)
    }

    function test_reject_offers_undo_that_restores_the_block() {
        const p = load()
        const day = p.weekData.days[1]
        let made = null
        Api.request("POST", "/api/balance/blocks",
                    { date: day, start: "18:00", end: "19:00", kind: "family", title: "Qt undo block" },
                    d => made = d, e => fail(e))
        tryVerify(() => made !== null, 5000)
        tryVerify(() => p.agenda[1].items.some(i => i.text === "Qt undo block"), 5000)
        p.decide(made.id, "reject")
        tryVerify(() => !p.agenda[1].items.some(i => i.text === "Qt undo block"), 5000)
        tryVerify(() => p.snackbar.undoFn !== null, 5000)
        p.snackbar.undoFn()
        tryVerify(() => p.agenda[1].items.some(i => i.text === "Qt undo block"), 5000)
        compare(p.agenda[1].items.find(i => i.text === "Qt undo block").block.state, "approved")
    }

    function test_block_form_validation() {
        const p = load()
        compare(p.blockProblem("2026-11-04", "700", "8.30", "x"), "")
        compare(p.blockProblem("2026-11-04", "19h00", "20:00", " x "), "")
        verify(p.blockProblem("2026-13-04", "07:00", "08:00", "x") !== "")
        verify(p.blockProblem("2026-02-30", "07:00", "08:00", "x") !== "")
        verify(p.blockProblem("2026-11-04", "7", "08:00", "x") !== "")
        verify(p.blockProblem("2026-11-04", "09:00", "08:00", "x") !== "")
        verify(p.blockProblem("2026-11-04", "09:00", "09:00", "x") !== "")
        verify(p.blockProblem("2026-11-04", "09:00", "10:00", "  ") !== "")
    }

    function test_add_form_normalises_times_and_enables_save() {
        const p = load()
        p.adding = true
        p.dateFieldItem.text = p.todayIso
        p.fromFieldItem.text = "700"
        p.toFieldItem.text = "7.30"
        p.titleFieldItem.text = "Qt form block"
        compare(p.formProblem, "")
        p.addBlock()
        tryVerify(() => p.agenda.some(d => d.items.some(i => i.text === "Qt form block" && i.time === "07:00–07:30")), 5000)
    }

    function test_server_words_are_translated_names() {
        const p = load()
        compare(p.stateName("proposed"), qsTr("proposed"))
        compare(p.colourName("green"), qsTr("green"))
        compare(p.colourName("odd"), "odd")
        compare(p.colourName(undefined), "")
    }
}
