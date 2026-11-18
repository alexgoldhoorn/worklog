import QtQuick
import QtQuick.Controls
import QtTest
import WorkLogApp

// The Find page against the real server (example household, balance store on a throwaway database).
TestCase {
    id: tc
    name: "Find"
    width: 480
    height: 820
    visible: true
    when: windowShown

    Component { id: findPage; FindPage {} }

    function initTestCase() {
        Api.serverUrl = testServer
        Api.username = ""
    }

    function load() {
        failOnWarning(/.*/)
        const p = createTemporaryObject(findPage, tc, { width: tc.width, height: tc.height })
        verify(p, "page did not instantiate")
        return p
    }

    function test_needs_a_title() {
        const p = load()
        p.find()
        compare(p.error, "Say what it is first.")
        compare(p.slotsData, null)
    }

    function test_item_from_form() {
        const p = load()
        p.what = "  Dentist  "
        p.minutes = 60
        p.travel = 15
        p.target = "training"
        const it = p.itemFromForm()
        compare(it.title, "Dentist")
        compare(it.minutes, 60)
        compare(it.travel_before, 15)
        compare(it.travel_after, 15)
        compare(it.kind, "gym")
        compare(it.prefer, ["not_school_runs"])
        p.target = "work"
        compare(p.itemFromForm().kind, "work")
        p.target = "family"
        compare(p.itemFromForm().kind, "personal")
    }

    function test_best_slot_per_day() {
        const p = load()
        const out = p.bestPerDay([
            { date: "2030-01-01", verdict: "clash" },
            { date: "2030-01-01", verdict: "tight", start: "09:00" },
            { date: "2030-01-01", verdict: "fits", start: "10:00" },
            { date: "2030-01-02", verdict: "ask_trainer" },
            { date: "2030-01-03", verdict: "fits", start: "08:00" }])
        compare(out.length, 2)
        compare(out[0].start, "09:00")
        compare(out[1].date, "2030-01-03")
    }

    // search, pick, put in a training block (approved at once, so it shows in the Week's blocks)
    function test_find_then_put() {
        const p = load()
        p.what = "Qt find test"
        p.target = "training"
        p.days = 7
        p.find()
        tryVerify(() => p.slotsData !== null || p.error !== "", 5000)
        compare(p.error, "")
        compare(Object.keys(p.slotsData.days).length, 7)
        verify(p.options.length > 0, "no option offered")
        const s = p.options[0]
        p.pick(s)
        p.put()
        tryVerify(() => p.putDone || p.error !== "", 5000)
        compare(p.error, "")
        verify(p.info.indexOf("block approved") >= 0)
        let week = null
        Api.request("GET", "/api/balance/week?" + Api.query({ start: s.date }), undefined, d => week = d, e => fail(e))
        tryVerify(() => week !== null, 5000)
        const b = week.blocks.find(x => x.title === "Qt find test" && x.date === s.date)
        verify(b, "the block is not in the week")
        Api.request("POST", "/api/balance/blocks/" + b.id + "/reject", undefined, () => {}, e => fail(e))
    }

    // work: nothing is stored here, the line to paste into Outlook comes back
    function test_work_target_pastes() {
        const p = load()
        p.what = "Qt paste test"
        p.target = "work"
        p.find()
        tryVerify(() => p.options.length > 0 || p.error !== "", 5000)
        compare(p.error, "")
        p.pick(p.options[0])
        p.put()
        tryVerify(() => p.putDone || p.error !== "", 5000)
        compare(p.error, "")
        verify(p.paste.indexOf("Qt paste test") >= 0)
    }

    function test_out_of_order_answer_dropped() {
        const p = load()
        p.what = "Qt stale"
        p.find()
        p.seq++   // as a server change would: the answer in flight is no longer wanted
        wait(1500)
        compare(p.slotsData, null)
    }
}
