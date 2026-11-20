import QtQuick
import QtCore

// Desktop: remembers the main window's size, position and maximised state across starts. A saved
// position that no screen shows any more (monitor unplugged) is not used.
Item {
    id: root

    property var appWindow: null
    property bool startHidden: false   // started with --minimized and a tray is wanted (the setting is on)
    property bool trayAvailable: false // the tray icon exists; at logon it can appear a moment after the app starts
    property int settleMs: 15000       // how long a --minimized start waits for the tray before showing the window
    readonly property bool desktop: Qt.platform.os !== "android" && Qt.platform.os !== "ios"

    Settings {
        id: saved
        category: "window"
        property int x: -1
        property int y: -1
        property int width: 0
        property int height: 0
        property bool maximized: false
        property bool hasGeometry: false
    }

    // screens: [{ x, y, w, h }]. The saved rect {x, y, w, h} is shrunk to the screen that shows most of
    // it, and moved so that at least a title bar's worth is on that screen. Returns null when there is
    // no screen showing it (then the window keeps its default place).
    function fit(r, screens, minW, minH) {
        if (!r || !(r.w > 0) || !(r.h > 0) || !screens || screens.length === 0)
            return null
        let best = null
        let bestArea = 0
        for (const s of screens) {
            const ix = Math.min(r.x + r.w, s.x + s.w) - Math.max(r.x, s.x)
            const iy = Math.min(r.y + r.h, s.y + s.h) - Math.max(r.y, s.y)
            if (ix > 0 && iy > 0 && ix * iy > bestArea) {
                best = s
                bestArea = ix * iy
            }
        }
        // the title bar (top 40 px) needs 100 px on screen, or the window can't be grabbed
        if (best === null || Math.min(r.x + r.w, best.x + best.w) - Math.max(r.x, best.x) < 100
                || r.y + 40 < best.y || r.y > best.y + best.h - 40)
            return null
        const w = Math.max(minW, Math.min(r.w, best.w))
        const h = Math.max(minH, Math.min(r.h, best.h))
        const x = Math.max(best.x, Math.min(r.x, best.x + best.w - w))
        const y = Math.max(best.y, Math.min(r.y, best.y + best.h - h))
        return { x: x, y: y, w: w, h: h }
    }

    function screenRects() {
        const out = []
        for (const s of Application.screens)
            out.push({ x: s.virtualX, y: s.virtualY, w: s.width, h: s.height })
        return out
    }

    // call before the window is shown
    function restore() {
        const win = root.appWindow
        if (!root.desktop || !win || !saved.hasGeometry)
            return
        const g = fit({ x: saved.x, y: saved.y, w: saved.width, h: saved.height },
                      screenRects(), win.minimumWidth, win.minimumHeight)
        if (g === null)
            return
        win.x = g.x
        win.y = g.y
        win.width = g.w
        win.height = g.h
        if (saved.maximized)
            win.visibility = Window.Maximized
    }

    function save() {
        const win = root.appWindow
        if (!root.desktop || !win || win.visibility === Window.Minimized || !win.visible)
            return
        saved.maximized = win.visibility === Window.Maximized
        if (win.visibility === Window.Windowed) {   // a maximised window keeps its normal size
            saved.x = win.x
            saved.y = win.y
            saved.width = win.width
            saved.height = win.height
            saved.hasGeometry = true
        }
    }

    Component.onCompleted: {
        restore()
        if (!appWindow)
            return
        if (!startHidden)
            appWindow.show()
        else if (!trayAvailable)
            settle.start()   // stay hidden for now: the tray may only be ready in a moment
    }
    // A quiet start without a tray would leave no way to reach the app: show the window after a while.
    Timer {
        id: settle
        interval: root.settleMs
        onTriggered: if (!root.trayAvailable && root.appWindow) root.appWindow.show()
    }
    Connections {
        target: Qt.application
        function onAboutToQuit() { root.save() }
    }
    Timer { id: later; interval: 600; onTriggered: root.save() }
    Connections {
        target: root.appWindow
        enabled: root.desktop
        function onXChanged() { later.restart() }
        function onYChanged() { later.restart() }
        function onWidthChanged() { later.restart() }
        function onHeightChanged() { later.restart() }
        function onVisibilityChanged() { later.restart() }
    }
}
