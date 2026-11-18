pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.platform as Platform
import WorkLogApp

// Windows tray icon (state icon, tooltip, menu) and the global start/pause hotkey. Loaded by Main.qml
// only on Windows. It reads the shared Api.status; start/pause/stop go through Api.timerAction (queued
// while the server is unreachable, like the Timer page) and never fail silently: a balloon says what happened.
Item {
    id: root

    property var window: null
    property real nowMs: Date.now()
    property bool showIcon: true   // false in the tests
    property bool busy: false      // an action is on its way: ignore a second hotkey press
    property string lastMessage: ""   // the last balloon text (also kept when there is no tray, for tests)
    readonly property var trayItem: trayLoader.item
    readonly property bool available: !!trayItem && trayItem.available

    readonly property var status: Api.status
    readonly property string timerState: status ? status.state : "stopped"
    readonly property var breakTypes: status && status.chips ? status.chips.break_types : []

    // "Working · 1:05 · dev", "Break · 0:12 · eat" or "Worklog · stopped"; " · server unreachable" when offline
    function tooltipFor(st, now, fetched, online) {
        const off = online === false ? " · " + qsTr("server unreachable") : ""
        if (!st)
            return qsTr("Worklog") + off
        if (st.state !== "working" && st.state !== "break")
            return qsTr("Worklog · stopped") + off
        const sec = Math.max(0, (st.elapsed_s || 0) + Math.floor((now - fetched) / 1000))
        const min = Math.floor(sec / 60)
        const t = Math.floor(min / 60) + ":" + (min % 60 < 10 ? "0" : "") + (min % 60)
        const kind = st.state === "working" ? qsTr("Working") : qsTr("Break")
        return kind + " · " + t + (st.block && st.block.type ? " · " + st.block.type : "") + off
    }
    // which of icons/tray-*.png to show
    function iconName(st, online) {
        if (online === false)
            return "offline"
        return st && (st.state === "working" || st.state === "break") ? st.state : "stopped"
    }
    // the hotkey: working -> pause, anything else -> start / resume
    function toggleRequestFor(state, breakType) {
        return state === "working" ? { path: "/api/pause", body: { type: breakType || "eat" } }
                                   : { path: "/api/start", body: {} }
    }
    // the balloon after a successful action; `data` is the server's new status
    function doneText(path, data) {
        const type = data && data.block && data.block.type ? " · " + data.block.type : ""
        if (path === "/api/pause")
            return qsTr("Paused") + type
        if (path === "/api/start")
            return qsTr("Started") + type
        return qsTr("Stopped")
    }

    function notify(title, text, isError) {
        root.lastMessage = text
        if (root.trayItem && root.trayItem.available)
            root.trayItem.showMessage(title, text,
                isError ? Platform.SystemTrayIcon.Warning : Platform.SystemTrayIcon.Information, 4000)
    }
    // path: "/api/start|pause|stop"; announce: also report success (the hotkey has no other feedback)
    function send(path, body, announce) {
        root.busy = true
        Api.timerAction(path, body, function (data) {
            root.busy = false
            if (announce)
                root.notify(qsTr("Worklog"), root.doneText(path, data), false)
        }, function (e) {
            root.busy = false
            root.notify(qsTr("Worklog: action failed"), e, true)
        }, function () {
            root.busy = false
            root.notify(qsTr("Worklog"), qsTr("Saved offline, will be sent when the server answers"), false)
        })
    }
    function startOrResume() { send("/api/start", {}, false) }
    function pause(type) { send("/api/pause", { type: type || Api.defaultBreak() }, false) }
    function stop() { send("/api/stop", {}, false) }

    // The hotkey decides from a fresh status: one that is up to 30 s old would turn "start" into a Switch
    // (splitting the block) when the timer was started elsewhere. Unreachable: use the last known one and queue.
    function toggle() {
        if (root.busy)
            return
        root.busy = true
        Api.refreshStatus(function (s, e) {
            if (!s && Api.online) {   // the server answered with an error (login, ...): don't guess
                root.busy = false
                root.notify(qsTr("Worklog: action failed"), e, true)
                return
            }
            const st = s || Api.status
            const r = root.toggleRequestFor(st ? st.state : "stopped", Api.defaultBreak())
            root.send(r.path, r.body, true)
        })
    }
    function showWindow() {
        if (!window)
            return
        if (window.visibility === Window.Minimized)
            window.showNormal()
        else
            window.show()
        window.raise()
        window.requestActivate()
    }
    function toggleWindow() {
        if (window && window.visible && window.active)
            window.hide()
        else
            showWindow()
    }

    Connections {
        target: Api
        // a replayed action the server refused
        function onQueueFailed(message) { root.notify(qsTr("Worklog: queued action failed"), message, true) }
    }
    Timer { interval: 10000; running: true; repeat: true; onTriggered: root.nowMs = Date.now() }

    GlobalHotkey {
        id: hotkey
        sequence: Api.hotkeySeq
        enabled: root.showIcon && Api.hotkeyOn && !Api.hotkeyCapturing
        onActivated: root.toggle()
    }
    Binding { target: Api; property: "hotkeyError"; value: hotkey.error }

    // not created in the tests: Qt Labs Platform needs QApplication
    Loader {
        id: trayLoader
        active: root.showIcon
        sourceComponent: trayComponent
    }
    Component {
        id: trayComponent
        Platform.SystemTrayIcon {
            id: tray
            visible: true
            icon.source: Qt.resolvedUrl("icons/tray-" + root.iconName(root.status, Api.online) + ".png")
            tooltip: root.tooltipFor(root.status, root.nowMs, Api.statusAt, Api.online)
            onActivated: reason => {
                if (reason === Platform.SystemTrayIcon.Trigger)
                    root.toggleWindow()
            }
            menu: Platform.Menu {
                id: menu
                onAboutToShow: Api.refreshStatus()
                Platform.MenuItem {
                    text: root.timerState === "break" ? qsTr("Resume") : root.timerState === "working" ? qsTr("Switch") : qsTr("Start")
                    onTriggered: root.startOrResume()
                }
                Platform.Menu {
                    id: pauseMenu
                    title: qsTr("Pause")
                    Instantiator {
                        model: root.breakTypes
                        delegate: Platform.MenuItem {
                            required property string modelData
                            text: modelData
                            onTriggered: root.pause(modelData)
                        }
                        onObjectAdded: (index, object) => pauseMenu.insertItem(index, object)
                        onObjectRemoved: (index, object) => pauseMenu.removeItem(object)
                    }
                }
                Platform.MenuItem {
                    text: qsTr("Stop")
                    enabled: root.timerState !== "stopped"
                    onTriggered: root.stop()
                }
                Platform.MenuSeparator {}
                Platform.MenuItem { text: qsTr("Show window"); onTriggered: root.showWindow() }
                Platform.MenuItem { text: qsTr("Quit"); onTriggered: Qt.quit() }
            }
        }
    }
}
