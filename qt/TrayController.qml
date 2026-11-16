pragma ComponentBehavior: Bound
import QtQuick
import Qt.labs.platform as Platform
import WorkLogApp

// Windows tray icon (tooltip, menu) and the global start/pause hotkey. Loaded by Main.qml only on
// Windows. It keeps its own copy of /api/status; the actions are the Timer page's (POST /api/start|pause|stop).
Item {
    id: root

    property var window: null
    property var status: null
    property real fetchedAt: 0
    property real nowMs: Date.now()
    property bool showIcon: true   // false in the tests
    readonly property var trayItem: trayLoader.item
    readonly property bool available: !!trayItem && trayItem.available

    readonly property string timerState: status ? status.state : "stopped"
    readonly property var breakTypes: status && status.chips ? status.chips.break_types : []

    // "Working · 1:05 · dev", "Break · 0:12 · eat" or "Worklog · stopped"
    function tooltipFor(st, now, fetched) {
        if (!st)
            return qsTr("Worklog")
        if (st.state !== "working" && st.state !== "break")
            return qsTr("Worklog · stopped")
        const sec = Math.max(0, (st.elapsed_s || 0) + Math.floor((now - fetched) / 1000))
        const min = Math.floor(sec / 60)
        const t = Math.floor(min / 60) + ":" + (min % 60 < 10 ? "0" : "") + (min % 60)
        const kind = st.state === "working" ? qsTr("Working") : qsTr("Break")
        return kind + " · " + t + (st.block && st.block.type ? " · " + st.block.type : "")
    }

    function reload() {
        Api.request("GET", "/api/status", undefined, function (s) {
            root.status = s
            root.fetchedAt = Date.now()
        }, () => root.status = null)
    }
    // like the Timer page: the next block gets the server's default type and project
    function send(path, body) {
        Api.request("POST", path, body, null, () => root.reload())
    }
    function startOrResume() { send("/api/start", {}) }
    function pause(type) { send("/api/pause", { type: type || "eat" }) }
    function stop() { send("/api/stop", {}) }
    // the hotkey: working -> pause, anything else -> start / resume
    function toggleRequest() {
        return timerState === "working" ? { path: "/api/pause", body: { type: "eat" } }
                                        : { path: "/api/start", body: {} }
    }
    function toggle() {
        const r = toggleRequest()
        send(r.path, r.body)
    }
    function showWindow() {
        if (!window)
            return
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

    Component.onCompleted: reload()
    Connections {
        target: Api
        function onChanged() { root.reload() }
        function onServerChanged() { root.reload() }
    }
    Timer { interval: 30000; running: true; repeat: true; onTriggered: root.reload() }
    Timer { interval: 10000; running: true; repeat: true; onTriggered: root.nowMs = Date.now() }

    GlobalHotkey {
        id: hotkey
        sequence: Api.hotkeySeq
        enabled: root.showIcon && Api.hotkeyOn
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
            icon.source: Qt.resolvedUrl("icons/worklog-256.png")
            tooltip: root.tooltipFor(root.status, root.nowMs, root.fetchedAt)
            onActivated: reason => {
                if (reason === Platform.SystemTrayIcon.Trigger)
                    root.toggleWindow()
            }
            menu: Platform.Menu {
                id: menu
                onAboutToShow: root.reload()
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
