import QtQuick
import QtTest
import WorkLogApp

// Re-lock ("Require fingerprint/face to open"): lock() clears the password and locks; a locked request
// fails with status 0, so a queued action is kept instead of dropped.
TestCase {
    id: tc
    name: "Lock"
    when: windowShown

    function init() {
        Api.locked = false
        Api.password = ""
    }
    function cleanup() {
        Api.locked = false
        Api.password = ""
    }

    function test_lock_clears_the_password_and_locks() {
        Api.password = "secret"
        Api.lock()
        verify(Api.locked)
        compare(Api.password, "")
    }

    function test_a_locked_request_reports_status_0() {
        Api.lock()
        let got = -1
        Api.request("GET", "/api/status", null, () => { got = 200 }, (e, status) => { got = status })
        compare(got, 0)
    }

    function test_lock_while_locked_does_nothing() {
        Api.lock()
        Api.password = "kept"   // as if unlocked meanwhile
        Api.lock()
        compare(Api.password, "kept")
    }
}
