import QtQuick
import QtTest
import WorkLogApp

// Start/pause/stop tapped while the server is unreachable are queued and replayed with their time.
TestCase {
    id: tc
    name: "OfflineQueue"
    when: windowShown

    readonly property string dead: "http://127.0.0.1:1"

    function call(method, path, body) {
        const r = { done: false, ok: false, data: null, err: "" }
        Api.request(method, path, body, d => { r.done = true; r.ok = true; r.data = d },
                    e => { r.done = true; r.err = e })
        tryVerify(() => r.done, 5000, method + " " + path)
        return r
    }

    // Api.timerAction and wait for it to finish: "ok", "queued" or the error text
    function act(path, body) {
        const r = { done: false, result: "" }
        Api.timerAction(path, body, () => { r.done = true; r.result = "ok" },
                        e => { r.done = true; r.result = e }, () => { r.done = true; r.result = "queued" })
        tryVerify(() => r.done, 5000, path)
        return r.result
    }

    function initTestCase() {
        verify(testServer !== "")
        Api.serverUrl = testServer
        Api.username = ""
    }

    function init() {
        Api.serverUrl = testServer
        Api.queue = []
        Api.saveQueue()
        call("POST", "/api/stop", {})
        call("GET", "/api/status")   // sync the clock offset
    }

    function test_online_actions_are_not_queued() {
        compare(act("/api/start", { project: "online" }), "ok")
        compare(Api.queue.length, 0)
        compare(call("GET", "/api/status").data.state, "working")
    }

    function test_unreachable_server_queues_in_order_with_times() {
        Api.serverUrl = dead
        compare(act("/api/start", { project: "offline", type: "dev" }), "queued")
        compare(act("/api/pause", { type: "eat" }), "queued")
        compare(act("/api/stop", {}), "queued")
        compare(Api.queue.length, 3)
        compare(Api.queue.map(i => i.path), ["/api/start", "/api/pause", "/api/stop"])
        verify(/^\d{4}-\d\d-\d\dT\d\d:\d\d$/.test(Api.queue[0].body.at), Api.queue[0].body.at)
        compare(Api.queue[0].body.project, "offline")
        // persisted for the next start
        compare(JSON.parse(Api.offline.queueJson).length, 3)
    }

    function test_queue_is_replayed_when_the_server_answers() {
        Api.serverUrl = dead
        act("/api/start", { project: "replay", type: "dev" })
        act("/api/pause", { type: "eat" })
        // tapped 20 and 10 minutes ago (a block of zero minutes would be dropped by the server)
        const ago = min => { const d = Api.now(); d.setMinutes(d.getMinutes() - min); return Api.isoDate(d) + "T" + Api.pad(d.getHours()) + ":" + Api.pad(d.getMinutes()) }
        verify(Api.nowHHMM() > "00:30", "needs a clock after 00:30")
        Api.queue[0].body.at = ago(20)
        Api.queue[1].body.at = ago(10)
        Api.serverUrl = testServer
        Api.flushQueue()
        tryVerify(() => Api.queue.length === 0, 5000)
        const day = call("GET", "/api/day/" + Api.today()).data
        const types = day.blocks.map(b => b.type)
        verify(types.indexOf("dev") >= 0 && types.indexOf("eat") >= 0, JSON.stringify(types))
        compare(call("GET", "/api/status").data.state, "break")
    }

    function test_an_action_the_server_refuses_is_dropped_and_reported() {
        const failures = []
        const f = msg => failures.push(msg)
        Api.queueFailed.connect(f)
        Api.serverUrl = dead
        act("/api/pause", { type: "no-such-break" })
        Api.serverUrl = testServer
        Api.flushQueue()
        tryVerify(() => Api.queue.length === 0, 5000)
        compare(failures.length, 1)
        verify(failures[0].indexOf("unknown break type") >= 0, failures[0])
        Api.queueFailed.disconnect(f)
    }

    function test_a_server_error_is_not_queued() {
        compare(act("/api/pause", { type: "no-such-break" }).indexOf("unknown break type"), 0)
        compare(Api.queue.length, 0)
    }
}
