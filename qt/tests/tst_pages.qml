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
    Component { id: plannerPage; PlannerPage {} }
    Component { id: weekPage; WeekPage {} }
    Component { id: todayPage; TodayPage {} }

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
    function test_planner_page() { const p = load(plannerPage); compare(p.error, ""); verify(p.day !== null) }
    function test_week_page() { const p = load(weekPage); compare(p.error, ""); verify(p.weekData !== null) }

    // the Today screen is the Timer on today and the Log on any other day
    function test_today_screen_switches_between_timer_and_log() {
        const p = load(todayPage)
        compare(p.viewDate, "")
        verify(p.timer.visible, "the Timer shows on today")
        verify(!p.log.visible, "the Log is hidden on today")
        verify(p.heading.indexOf("Today") === 0)
        const yesterday = Api.addDays(p.today, -1)
        p.step(-1)
        compare(p.date, yesterday)
        compare(p.log.date, yesterday)
        verify(p.log.visible && !p.timer.visible)
        tryVerify(() => p.log.day !== null && p.log.day.date === yesterday, 3000)
        p.log.date = Api.addDays(yesterday, -1)   // the Log's own picker or arrow keys move the screen along
        compare(p.viewDate, Api.addDays(yesterday, -1))
        p.log.date = p.today                      // its "Back to today"
        verify(p.isToday && p.timer.visible)
        p.show(yesterday)
        p.show("")
        verify(p.isToday)
        p.timer.openDay(yesterday)                // a tap on a notice or a week bar
        compare(p.viewDate, yesterday)
    }
}
