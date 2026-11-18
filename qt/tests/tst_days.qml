import QtQuick
import QtQuick.Controls
import QtTest
import WorkLogApp

// The Days page against the real server: decimal comma and point, nothing sent as NaN, rows that
// survive a reload (focus and a half-typed value), and a slow answer for another month.
TestCase {
    id: tc
    name: "Days"
    width: 600
    height: 900
    visible: true
    when: windowShown

    Component { id: daysPage; ExpectedPage {} }

    readonly property string month: Api.today().slice(0, 7)

    function initTestCase() {
        Api.serverUrl = testServer
        Api.username = ""
    }

    function load() {
        failOnWarning(/.*/)
        const p = createTemporaryObject(daysPage, tc, { width: tc.width, height: tc.height })
        verify(p, "page did not instantiate")
        tryVerify(() => p.rowItem(month + "-10") !== null, 5000)
        compare(p.error, "")
        return p
    }

    // the server's copy of a day
    function serverDay(date, then) {
        let got = null
        Api.request("GET", "/api/days?start=" + date + "&end=" + date, undefined, d => got = d[0], e => fail(e))
        tryVerify(() => got !== null, 5000)
        return got
    }

    function test_hours_parsing() {
        const p = load()
        compare(p.hours("7.5", false), 7.5)
        compare(p.hours("7,5", false), 7.5)
        compare(p.hours("", true), 0)
        verify(isNaN(p.hours("", false)))
        verify(isNaN(p.hours("abc", true)))
        verify(isNaN(p.hours("25", false)))
    }

    function test_prefilled_value_is_acceptable() {
        const p = load()
        const row = p.rowItem(month + "-10")
        row.expItem.text = "7.5"
        verify(row.expItem.acceptableInput)
        row.expItem.text = "7,5"
        verify(row.expItem.acceptableInput)
    }

    function test_comma_is_sent_as_a_number() {
        const p = load()
        const date = month + "-12"
        const row = p.rowItem(date)
        row.expItem.forceActiveFocus()
        row.expItem.selectAll()
        keyClick("7")
        keyClick(",")
        keyClick("5")
        row.sickItem.forceActiveFocus()   // leaving the field commits
        tryVerify(() => serverDay(date).expected_h === 7.5, 5000)
        tryVerify(() => row.expItem.text === "7.5", 5000)
    }

    function test_not_a_number_is_never_sent() {
        const p = load()
        const date = month + "-13"
        const before = serverDay(date).expected_h
        verify(!p.save(date, "x", "", ""))
        verify(p.error !== "")
        wait(300)
        compare(serverDay(date).expected_h, before)
    }

    function test_focus_and_half_typed_value_survive_a_save() {
        const p = load()
        const a = month + "-14", b = month + "-15"
        const rowA = p.rowItem(a), rowB = p.rowItem(b)
        verify(rowA && rowB)
        rowB.reasonItem.forceActiveFocus()
        rowB.reasonItem.text = "half typed"
        verify(rowB.reasonItem.activeFocus)
        verify(p.save(a, "6", "", "saved from another row"))
        tryVerify(() => rowA.stored && rowA.reasonItem.text === "saved from another row", 5000)
        verify(rowB.reasonItem.activeFocus, "focus was lost")
        compare(rowB.reasonItem.text, "half typed")
        verify(p.rowItem(b) === rowB, "the row was rebuilt")
        verify(p.rowItem(a) === rowA, "the row was rebuilt")
    }

    function test_slow_answer_for_another_month_is_ignored() {
        const p = load()
        const other = Api.addDays(month + "-01", -5).slice(0, 7)
        p.month = other
        p.month = month
        tryVerify(() => p.days.length > 0 && p.days[0].date.slice(0, 7) === month, 5000)
        wait(300)
        compare(p.days[0].date.slice(0, 7), month)
        verify(p.rowItem(month + "-10") !== null)
        compare(p.rowItem(other + "-10"), null)
    }

    function test_narrow_layout_stays_inside() {
        failOnWarning(/.*/)
        const p = createTemporaryObject(daysPage, tc, { width: 320, height: 700 })
        tryVerify(() => p.rowItem(month + "-10") !== null, 5000)
        verify(p.narrow)
        const row = p.rowItem(month + "-10")
        verify(row.reasonItem.width >= 200, "reason field is " + row.reasonItem.width)
        verify(row.reasonItem.y > row.expItem.y)
    }
}
