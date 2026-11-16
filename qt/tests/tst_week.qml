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
}
