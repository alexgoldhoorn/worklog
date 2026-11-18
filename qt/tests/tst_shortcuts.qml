import QtQuick
import QtQuick.Controls
import QtTest
import WorkLogApp

// The pages' window shortcuts (Timer: S P X 1-6 /, Log: left/right) stay quiet while a dialog is open.
TestCase {
    id: tc
    name: "Shortcuts"
    width: 480
    height: 820
    visible: true
    when: windowShown

    Component { id: winComp; ApplicationWindow { width: 480; height: 820; visible: true } }
    Component { id: timerComp; TimerPage {} }
    Component { id: dayComp; DayPage {} }

    function initTestCase() {
        Api.serverUrl = testServer
        Api.username = ""
    }

    function page(comp) {
        const win = createTemporaryObject(winComp, tc)
        verify(win)
        win.requestActivate()
        tryVerify(() => win.active, 3000)
        const p = comp.createObject(win.contentItem, { width: win.width, height: win.height })
        verify(p)
        return { win: win, page: p }
    }

    function test_timer_type_shortcut_not_while_dialog_open() {
        const r = page(timerComp)
        const p = r.page
        tryVerify(() => p.status !== null, 5000)
        verify(p.status.chips.types.length > 0)
        p.forceActiveFocus()
        // control: with no dialog the key picks the first type
        keyClick(Qt.Key_1)
        tryVerify(() => p.pendingType !== "", 2000)
        p.pendingType = ""

        p.dialog.newBlock(Api.today())
        tryVerify(() => p.dialog.opened, 2000)
        keyClick(Qt.Key_1)
        wait(100)
        compare(p.pendingType, "", "1 picked a type behind the dialog")
        p.dialog.close()
        tryVerify(() => !p.dialog.visible, 2000)
    }

    function test_log_arrows_not_while_dialog_or_calendar_open() {
        const r = page(dayComp)
        const p = r.page
        p.forceActiveFocus()
        const day = p.date
        keyClick(Qt.Key_Left)
        tryVerify(() => p.date !== day, 2000)   // control
        p.date = day

        p.dialog.newBlock(day)
        tryVerify(() => p.dialog.opened, 2000)
        keyClick(Qt.Key_Left)
        wait(100)
        compare(p.date, day, "the dialog let the arrow step the day")
        p.dialog.close()
        tryVerify(() => !p.dialog.visible, 2000)

        p.picker.openFor(day)
        tryVerify(() => p.picker.opened, 2000)
        keyClick(Qt.Key_Left)   // moves the calendar's cursor, not the page
        wait(100)
        compare(p.date, day)
        compare(p.picker.cursor, Api.addDays(day, -1))
        p.picker.close()
    }
}
