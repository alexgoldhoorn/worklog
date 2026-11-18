import QtQuick
import QtQuick.Controls
import QtTest
import WorkLogApp

// Each page loads against the real server without a QML warning and shows no error.
TestCase {
    id: tc
    name: "Pages"
    width: 480
    height: 820
    visible: true
    when: windowShown

    Component { id: timerPage; TimerPage {} }
    Component { id: dayPage; DayPage {} }
    Component { id: reportsPage; ReportsPage {} }
    Component { id: expectedPage; ExpectedPage {} }
    Component { id: pomodoroPage; PomodoroPage {} }
    Component { id: settingsPage; SettingsPage {} }
    Component { id: findPage; FindPage {} }

    function initTestCase() {
        Api.serverUrl = testServer
        Api.username = ""
    }

    function load(comp) {
        // QML warnings name their file and line ("qrc:/…/Page.qml:60: TypeError…"). Qt Multimedia's own
        // complaints on a machine without an audio device (CI) are not the page's fault.
        failOnWarning(/\.qml:\d+/)
        const p = createTemporaryObject(comp, tc, { width: tc.width, height: tc.height })
        verify(p, "page did not instantiate")
        wait(800)   // the page's first requests
        return p
    }

    function test_timer_page() {
        const p = load(timerPage)
        compare(p.error, "")
        verify(p.status !== null)
    }
    function test_day_page() { compare(load(dayPage).error, "") }
    function test_reports_page() { compare(load(reportsPage).error, "") }
    function test_expected_page() { compare(load(expectedPage).error, "") }
    function test_pomodoro_page() { load(pomodoroPage) }
    function test_settings_page() { load(settingsPage) }
    function test_find_page() { compare(load(findPage).error, "") }
}
