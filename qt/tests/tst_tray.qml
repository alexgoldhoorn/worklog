import QtQuick
import QtTest
import WorkLogApp

// Pure helpers of the desktop pieces: tray text/icon/toggle, idle question, window geometry, hotkey capture.
TestCase {
    id: tc
    name: "Tray"
    when: true

    Component { id: ctl; TrayController { showIcon: false } }
    Component { id: idle; IdleWatcher {} }
    Component { id: wst; WindowState {} }
    Component { id: hkf; HotkeyField {} }

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

    function test_tooltip_offline() {
        const c = createTemporaryObject(ctl, tc)
        compare(c.tooltipFor(null, 0, 0, false), "Worklog · server unreachable")
        compare(c.tooltipFor({ state: "working", elapsed_s: 60, block: { type: "dev" } }, 0, 0, false),
                "Working · 0:01 · dev · server unreachable")
        compare(c.tooltipFor({ state: "stopped" }, 0, 0, true), "Worklog · stopped")
    }

    function test_icon() {
        const c = createTemporaryObject(ctl, tc)
        compare(c.iconName({ state: "working" }, true), "working")
        compare(c.iconName({ state: "break" }, true), "break")
        compare(c.iconName({ state: "stopped" }, true), "stopped")
        compare(c.iconName(null, true), "stopped")
        compare(c.iconName({ state: "working" }, false), "offline")
    }

    function test_toggle() {
        const c = createTemporaryObject(ctl, tc)
        Api.status = null
        compare(c.toggleRequestFor("working", "walk").path, "/api/pause")
        compare(c.toggleRequestFor("working", "walk").body.type, "walk")
        compare(JSON.stringify(c.toggleRequestFor("working").body), "{}", "no break type known: none is sent, never a literal")
        compare(c.toggleRequestFor("break", "eat").path, "/api/start")
        compare(c.toggleRequestFor("stopped", "eat").path, "/api/start")
    }

    function test_done_text() {
        const c = createTemporaryObject(ctl, tc)
        compare(c.doneText("/api/pause", { block: { type: "eat" } }), "Paused · eat")
        compare(c.doneText("/api/start", { block: { type: "dev" } }), "Started · dev")
        compare(c.doneText("/api/start", null), "Started")
    }

    // ---- idle ----------------------------------------------------------------

    function test_idle_should_ask() {
        const w = createTemporaryObject(idle, tc)
        // was idle 15 min at the last poll, input since, work running
        verify(w.shouldAsk(true, "working", 900, 3, 10, false))
        verify(!w.shouldAsk(false, "working", 900, 3, 10, false))   // switched off
        verify(!w.shouldAsk(true, "break", 900, 3, 10, false))      // not working
        verify(!w.shouldAsk(true, "stopped", 900, 3, 10, false))
        verify(!w.shouldAsk(true, "working", 500, 3, 10, false))    // away less than the threshold
        verify(!w.shouldAsk(true, "working", 900, 905, 10, false))  // still away: no input yet
        verify(!w.shouldAsk(true, "working", 900, 3, 10, true))     // already asking
        verify(w.shouldAsk(true, "working", 600, 0, 10, false))     // exactly the threshold
    }

    function test_idle_question_only_takes_focus_when_asked_or_without_tray() {
        const w = createTemporaryObject(idle, tc)
        verify(!w.raises(false, true))   // the default: a tray message, the window stays where it is
        verify(w.raises(true, true))
        verify(w.raises(false, false))   // nothing else could tell the user
    }
    function test_idle_sleep_gap() {
        const w = createTemporaryObject(idle, tc)
        compare(w.effectivePrevIdle(5, 10), 5)         // a normal poll
        compare(w.effectivePrevIdle(5, 3600), 3605)    // the machine slept an hour
    }

    function test_idle_span_and_text() {
        const w = createTemporaryObject(idle, tc)
        const now = new Date(2026, 9, 20, 10, 30, 0).getTime()
        // away 25 min, back 0 s ago
        let s = w.awaySpan(1500, 0, now, null)
        compare(s.minutes, 25)
        compare(w.hhmm(s.startMs), "10:05")
        compare(w.hhmm(s.endMs), "10:30")
        compare(w.question(s), "You were away 25 min (10:05–10:30). Log it as a break?")
        compare(w.atString(s.startMs), "2026-10-20T10:05")
        // the running block started at 10:20: the break cannot begin before it
        const bs = new Date(2026, 9, 20, 10, 20).getTime()
        s = w.awaySpan(1500, 0, now, bs)
        compare(w.hhmm(s.startMs), "10:20")
        compare(s.minutes, 10)
        // never more than 23 h back
        s = w.awaySpan(30 * 3600, 0, now, null)
        compare(s.startMs, now - 23 * 3600 * 1000)
        compare(w.fmtDuration(125), "2 h 5 min")
        compare(w.fmtDuration(120), "2 h")
        compare(w.fmtDuration(9), "9 min")
        compare(w.blockStartMs({ date: "2026-10-20", start: "10:20" }), bs)
        compare(w.blockStartMs(null), null)
    }

    // ---- window geometry -----------------------------------------------------

    function test_window_fit() {
        const w = createTemporaryObject(wst, tc)
        const one = [{ x: 0, y: 0, w: 1920, h: 1080 }]
        const two = [{ x: 0, y: 0, w: 1920, h: 1080 }, { x: 1920, y: 0, w: 1920, h: 1080 }]
        // inside: unchanged
        compare(w.fit({ x: 100, y: 50, w: 480, h: 820 }, one, 320, 480).x, 100)
        // on a monitor that is gone: not used
        compare(w.fit({ x: 2100, y: 50, w: 480, h: 820 }, one, 320, 480), null)
        // the same place with the second monitor present
        compare(w.fit({ x: 2100, y: 50, w: 480, h: 820 }, two, 320, 480).x, 2100)
        // partly off the edge: pulled back in
        let g = w.fit({ x: 1700, y: 200, w: 480, h: 820 }, one, 320, 480)
        compare(g.x, 1440)
        compare(g.y, 200)
        // bigger than the screen: shrunk
        g = w.fit({ x: 0, y: 0, w: 4000, h: 3000 }, one, 320, 480)
        compare(g.w, 1920)
        compare(g.h, 1080)
        // title bar above the screen (cannot be grabbed)
        compare(w.fit({ x: 100, y: -500, w: 480, h: 820 }, one, 320, 480), null)
        // nothing saved / no screens
        compare(w.fit({ x: 0, y: 0, w: 0, h: 0 }, one, 320, 480), null)
        compare(w.fit({ x: 0, y: 0, w: 480, h: 820 }, [], 320, 480), null)
    }

    // ---- hotkey capture ------------------------------------------------------

    function test_hotkey_sequence() {
        const f = createTemporaryObject(hkf, tc)
        const C = Qt.ControlModifier, A = Qt.AltModifier, S = Qt.ShiftModifier
        compare(f.sequenceFor(Qt.Key_W, C | A), "Ctrl+Alt+W")
        compare(f.sequenceFor(Qt.Key_F9, S), "Shift+F9")
        compare(f.sequenceFor(Qt.Key_5, C), "Ctrl+5")
        compare(f.sequenceFor(Qt.Key_Space, A), "Alt+Space")
        compare(f.sequenceFor(Qt.Key_Control, C), "")   // a modifier on its own
        compare(f.sequenceFor(Qt.Key_Return, C), "")    // not registrable
        verify(f.usable("Ctrl+Alt+W"))
        verify(!f.usable("W"))
        verify(!f.usable("F9"))
    }

    // ---- start with Windows ----------------------------------------------------

    // writes and removes the test app's own HKCU Run value (named after the test organisation)
    function test_autostart_follows_registry() {
        if (!Autostart.supported)
            skip("Windows only")
        Autostart.enabled = false
        verify(!Autostart.enabled)
        Autostart.enabled = true
        Autostart.refresh()   // read the registry again, not our own flag
        verify(Autostart.enabled)
        compare(Autostart.error, "")
        Autostart.enabled = false
        Autostart.refresh()
        verify(!Autostart.enabled)
    }
}
