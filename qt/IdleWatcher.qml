pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import WorkLogApp

// Windows: when you come back after being away (no keyboard or mouse input) for at least
// Api.idleMinutes while a work block runs, asks once whether that time was a break. "Log as break"
// pauses at the moment you left and starts the same work again now (POST /api/pause with `at`, then
// /api/start). Sleep and lock count as away: the timer stalls, and the stall is added to the idle time.
Item {
    id: root

    property var appWindow: null
    property var tray: null           // TrayController, for the balloon; may be null
    property bool watching: IdleMonitor.available && Api.idleOn && Api.baseUrl !== "" && !Api.locked
    property real prevIdleS: 0        // idle seconds at the previous poll
    property real lastTickMs: Date.now()
    property var pending: null        // { startMs, endMs, minutes, block } while the question is open
    readonly property bool asking: pending !== null
    property bool sending: false      // the break is being logged: the question stays open until the server accepted it
    property string error: ""         // why the last attempt failed, shown in the question

    // ---- pure parts ----------------------------------------------------------

    // a poll that came late (the machine slept) was idle for the whole gap as well
    function effectivePrevIdle(prevIdleS, gapS) {
        return gapS > 30 ? prevIdleS + gapS : prevIdleS
    }
    // ask when the previous poll saw at least `thresholdMin` of idling and the user has touched
    // something since (idle time dropped), while work runs and no question is open
    function shouldAsk(on, state, prevIdleS, curIdleS, thresholdMin, open) {
        return on && !open && state === "working" && prevIdleS >= thresholdMin * 60
               && curIdleS < prevIdleS
    }
    // the away span in server-clock ms: from the last input before the idling to the first one after,
    // not before the running block started and at most 23 h back (what /api/pause accepts)
    function awaySpan(prevIdleS, curIdleS, nowMs, blockStartMs) {
        let start = nowMs - prevIdleS * 1000
        const end = nowMs - curIdleS * 1000
        start = Math.max(start, nowMs - 23 * 3600 * 1000)
        if (blockStartMs !== null && blockStartMs !== undefined)
            start = Math.max(start, blockStartMs)
        const minutes = Math.max(0, Math.round((end - start) / 60000))
        return { startMs: start, endMs: end, minutes: minutes }
    }
    function fmtDuration(min) {
        if (min < 60)
            return qsTr("%1 min").arg(min)
        const h = Math.floor(min / 60)
        const m = min % 60
        return m === 0 ? qsTr("%1 h").arg(h) : qsTr("%1 h %2 min").arg(h).arg(m)
    }
    function hhmm(ms) {
        const d = new Date(ms)
        return Api.pad(d.getHours()) + ":" + Api.pad(d.getMinutes())
    }
    function question(span) {
        return qsTr("You were away %1 (%2–%3). Log it as a break?")
            .arg(fmtDuration(span.minutes)).arg(hhmm(span.startMs)).arg(hhmm(span.endMs))
    }
    // "2026-10-20T09:30" for the API's `at`, from a server-clock ms value
    function atString(ms) {
        const d = new Date(ms)
        return Api.isoDate(d) + "T" + hhmm(ms)
    }
    // "2026-10-20 09:30" (a block's date and start) as server-clock ms
    function blockStartMs(blk) {
        if (!blk || !blk.date || !blk.start)
            return null
        const m = /^(\d{4})-(\d\d)-(\d\d)$/.exec(blk.date)
        const t = /^(\d\d):(\d\d)/.exec(blk.start)
        if (!m || !t)
            return null
        return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(t[1]), Number(t[2])).getTime()
    }

    // ---- polling -------------------------------------------------------------

    function poll() {
        const cur = IdleMonitor.idleSeconds()
        const nowMs = Date.now()
        const prev = effectivePrevIdle(prevIdleS, (nowMs - lastTickMs) / 1000)
        lastTickMs = nowMs
        prevIdleS = cur
        const st = Api.status ? Api.status.state : "stopped"
        // the status can be 30 s old: look again before asking, so a timer stopped elsewhere is not questioned
        if (!shouldAsk(Api.idleOn, st, prev, cur, Api.idleMinutes, asking))
            return
        Api.refreshStatus(function (s) {
            const fresh = s   // a failed refresh must not make us decide from a stale status
            if (!fresh || fresh.state !== "working" || root.asking)
                return
            const clock = Api.now().getTime()
            const span = root.awaySpan(prev, cur, clock, root.blockStartMs(fresh.block))
            if (span.minutes < 1)
                return
            root.pending = { startMs: span.startMs, endMs: span.endMs, minutes: span.minutes, block: fresh.block }
            root.announce(span)
        })
    }
    Timer {
        interval: 10000
        repeat: true
        running: root.watching
        onTriggered: root.poll()
    }

    // Without Api.idleRaise the question does not take the focus: it waits in the window and the tray
    // balloon says so. With no tray to say it, the window has to come forward.
    function raises(wanted, trayAvailable) {
        return wanted || !trayAvailable
    }
    function announce(span) {
        const win = root.appWindow
        const quiet = !raises(Api.idleRaise, !!root.tray && root.tray.available)
        if (win && !quiet) {
            if (win.visibility === Window.Minimized)
                win.showNormal()
            else
                win.show()
            win.raise()
            win.requestActivate()
        }
        if (root.tray)
            root.tray.notify(qsTr("Worklog"), quiet ? qsTr("%1 Open Worklog to answer.").arg(root.question(span))
                                                    : root.question(span), false)
        dialog.open()
    }

    // ---- answers -------------------------------------------------------------

    function logAsBreak() {
        const p = root.pending
        if (!p || root.sending)
            return
        root.sending = true
        root.error = ""
        const fail = function (e) {
            if (root.tray)
                root.tray.notify(qsTr("Could not log the break"), e, true)
        }
        // not Api.timerAction: a queued pause would get the time of the replay instead of `at`
        const body = Api.pauseBody("")
        body.at = root.atString(p.startMs)
        Api.request("POST", "/api/pause", body, function () {
            // logged: the question is answered
            root.sending = false
            root.pending = null
            dialog.close()
            const startBody = {}
            if (p.block && p.block.type) startBody.type = p.block.type
            if (p.block && p.block.project) startBody.project = p.block.project
            Api.timerAction("/api/start", startBody, null, fail, function () {
                if (root.tray)
                    root.tray.notify(qsTr("Worklog"), qsTr("Break logged; resuming is saved offline and will be sent later"), false)
            })
        }, function (e) {
            // not logged (network not up yet after sleep, ...): the question stays, with the reason
            root.sending = false
            root.error = e
            fail(e)
            if (!dialog.opened)
                dialog.open()
        })
    }
    function keepAsWork() {
        if (root.sending)
            return
        root.pending = null
        root.error = ""
        dialog.close()
    }

    Dialog {
        id: dialog
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        closePolicy: Popup.NoAutoClose
        title: qsTr("Welcome back")
        width: Math.min(parent ? parent.width - 32 : 320, 400)
        Material.accent: Api.accent

        contentItem: ColumnLayout {
            spacing: 8
            Label {
                text: root.pending ? root.question(root.pending) : ""
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: root.error !== ""
                text: qsTr("Could not log it: %1. Try again.").arg(root.error)
                color: Api.errorColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }
        footer: DialogButtonBox {
            Button {
                text: qsTr("Log as break")
                enabled: !root.sending
                highlighted: true
                Accessible.name: text
                DialogButtonBox.buttonRole: DialogButtonBox.ActionRole   // not Accept: the dialog stays open until the server took the break
                onClicked: root.logAsBreak()
            }
            Button {
                text: qsTr("Keep as work")
                enabled: !root.sending
                Accessible.name: text
                DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
                onClicked: root.keepAsWork()
            }
        }
    }
}
