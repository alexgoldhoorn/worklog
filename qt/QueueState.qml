import QtQuick

// What the timer looks like once the actions queued while the server was unreachable have been
// applied: pure functions, so the Timer page and the tests share them.
QtObject {
    // "2026-10-20T09:30" (the server's wall clock) -> Date with those local fields, or null
    function parseAt(at) {
        const m = /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)/.exec(at || "")
        return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5])) : null
    }

    // seconds from `at` to nowDate (a Date on the server's clock, Api.now()), never negative; 0 when `at` is unusable
    function elapsedSince(at, nowDate) {
        const d = parseAt(at)
        return d ? Math.max(0, Math.floor((nowDate.getTime() - d.getTime()) / 1000)) : 0
    }

    // The state the last queued action leads to: {state: "working" | "break" | "stopped", type, project, at},
    // or null for an empty queue. Type and project are "" when the action did not name one (the server's
    // default applies).
    function implied(queue) {
        if (!queue || queue.length === 0)
            return null
        const last = queue[queue.length - 1]
        const body = last.body || {}
        if (last.path === "/api/stop")
            return { state: "stopped", type: "", project: "", at: body.at || "" }
        if (last.path === "/api/pause")
            return { state: "break", type: body.type || "", project: "", at: body.at || "" }
        if (last.path === "/api/start")
            return { state: "working", type: body.type || "",
                     project: body.project || "", at: body.at || "" }
        return null
    }
}
