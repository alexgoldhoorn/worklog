import QtQuick
import QtTest
import WorkLogApp

// Api.request against the real server (the same one the web UI and the watch use).
TestCase {
    id: tc
    name: "Api"
    when: windowShown

    // run an Api.request and wait for its answer: { ok, data, err }
    function call(method, path, body) {
        const r = { done: false, ok: false, data: null, err: "" }
        Api.request(method, path, body, d => { r.done = true; r.ok = true; r.data = d },
                    e => { r.done = true; r.err = e })
        tryVerify(() => r.done, 5000, method + " " + path)
        return r
    }

    function initTestCase() {
        verify(testServer !== "", "WORKLOG_TEST_URL is not set (use run_tests.py)")
        Api.serverUrl = testServer
        Api.username = ""
    }

    function init() { call("POST", "/api/stop", {}) }

    function test_status_has_the_fields_the_pages_read() {
        const r = call("GET", "/api/status")
        verify(r.ok, r.err)
        compare(r.data.state, "stopped")
        verify(typeof r.data.now === "string")
        verify(Array.isArray(r.data.chips.types))
        verify(Array.isArray(r.data.chips.break_types))
    }

    function test_start_pause_stop() {
        compare(call("POST", "/api/start", { project: "tests", type: "dev" }).data.state, "working")
        compare(call("POST", "/api/pause", {}).data.state, "break")
        compare(call("POST", "/api/stop", {}).data.state, "stopped")
    }

    function test_errors_come_back_as_text() {
        const r = call("POST", "/api/pause", { type: "no-such-break" })
        verify(!r.ok)
        verify(r.err.indexOf("unknown break type") >= 0, r.err)
    }

    function test_unreachable_server_is_reported() {
        const saved = Api.serverUrl
        Api.serverUrl = "http://127.0.0.1:1"
        const r = call("GET", "/api/status")
        Api.serverUrl = saved
        verify(!r.ok)
        verify(r.err.indexOf("Cannot reach") === 0, r.err)
    }

    function test_clock_offset_follows_the_server() {
        call("GET", "/api/status")
        verify(Math.abs(Api.clockOffsetMs) < 24 * 3600 * 1000)
        verify(/^\d{4}-\d{2}-\d{2}$/.test(Api.today()))
    }
}
