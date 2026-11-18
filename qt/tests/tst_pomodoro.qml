import QtQuick
import QtTest
import WorkLogApp

// The Pomodoro tab's "not connected" error goes away once the server answers (after a login is set).
TestCase {
    id: tc
    name: "Pomodoro"
    width: 480
    height: 820
    visible: true
    when: windowShown

    Component { id: pomodoroPage; PomodoroPage {} }

    function cleanup() { Api.serverUrl = testServer }

    function test_status_error_clears_when_the_server_answers() {
        Api.serverUrl = "http://127.0.0.1:1"   // nothing listens: like a start before the login is saved
        const p = createTemporaryObject(pomodoroPage, tc, { width: tc.width, height: tc.height })
        tryVerify(() => p.shownError !== "", 5000, "the unreachable server is reported")
        Api.serverUrl = testServer
        Api.refreshStatus()                    // what Api.setServer() does after Connect
        tryVerify(() => p.shownError === "", 5000, "still showing: " + p.shownError)
    }
}
