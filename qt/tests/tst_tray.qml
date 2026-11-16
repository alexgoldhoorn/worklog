import QtQuick
import QtTest
import WorkLogApp

// The tray controller's tooltip text and hotkey toggling, without a tray icon.
TestCase {
    id: tc
    name: "Tray"
    when: true

    Component { id: ctl; TrayController { showIcon: false } }

    function test_tooltip() {
        const c = createTemporaryObject(ctl, tc)
        verify(c)
        compare(c.tooltipFor(null, 0, 0), "Worklog")
        compare(c.tooltipFor({ state: "stopped" }, 0, 0), "Worklog · stopped")
        const st = { state: "working", elapsed_s: 3660, block: { type: "dev" } }
        compare(c.tooltipFor(st, 0, 0), "Working · 1:01 · dev")
        // the clock keeps running between status reloads
        compare(c.tooltipFor(st, 120000, 0), "Working · 1:03 · dev")
        compare(c.tooltipFor({ state: "break", elapsed_s: 30, block: { type: "eat" } }, 0, 0), "Break · 0:00 · eat")
    }

    function test_toggle() {
        const c = createTemporaryObject(ctl, tc)
        c.status = { state: "working" }
        compare(c.toggleRequest().path, "/api/pause")
        compare(c.toggleRequest().body.type, "eat")
        c.status = { state: "break" }
        compare(c.toggleRequest().path, "/api/start")
        c.status = null
        compare(c.toggleRequest().path, "/api/start")
    }
}
