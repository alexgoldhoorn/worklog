import QtQuick
import QtQuick.Controls
import QtTest
import WorkLogApp

// Settings page: server address helpers, decimal comma in the week length, sign out.
TestCase {
    id: tc
    name: "Settings"
    width: 480
    height: 900
    visible: true
    when: windowShown

    Component { id: settingsPage; SettingsPage {} }

    function initTestCase() {
        Api.serverUrl = testServer
        Api.username = ""
    }

    function load() {
        failOnWarning(/.*/)
        const p = createTemporaryObject(settingsPage, tc, { width: tc.width, height: tc.height })
        verify(p, "page did not instantiate")
        tryVerify(() => p.connected === true, 5000)
        return p
    }

    function test_local_hosts() {
        const p = load()
        for (const h of ["localhost", "127.0.0.1", "127.9.9.9", "10.1.2.3", "192.168.0.10", "172.16.0.1", "172.31.255.1",
                         "169.254.10.1", "100.64.0.1", "100.127.255.255", "nas.local", "nas", "::1", "fe80::1", "fd12::1",
                         "fc00::1", "febf::1", "0:0:0:0:0:0:0:1"])
            verify(p.isLocalHost(h), h)
        for (const h of ["worklog.example.com", "172.32.0.1", "172.15.0.1", "8.8.8.8", "11.0.0.1", "2001:db8::1", "",
                         "10.example.com", "192.168.example.com", "127.evil.com", "100.63.0.1", "100.128.0.1",
                         "169.253.0.1", "192.169.0.1", "999.1.1.1", "10.1.2", "fec0::1"])
            verify(!p.isLocalHost(h), h)
    }

    function test_host_of() {
        const p = load()
        compare(p.hostOf("https://User@Host.Example.com:8443/path"), "host.example.com")
        compare(p.hostOf("nas:8000"), "nas")
        compare(p.hostOf("http://[::1]:8000/x"), "::1")
        compare(p.hostOf(" 192.168.0.10/api "), "192.168.0.10")
    }

    function test_normalize_url() {
        const p = load()
        compare(p.normalizeUrl("worklog.example.com"), "https://worklog.example.com")
        compare(p.normalizeUrl("  worklog.example.com/  "), "https://worklog.example.com")
        compare(p.normalizeUrl("192.168.0.10:8000"), "http://192.168.0.10:8000")
        compare(p.normalizeUrl("localhost:8000"), "http://localhost:8000")
        compare(p.normalizeUrl("nas"), "http://nas")
        compare(p.normalizeUrl("box.local"), "http://box.local")
        compare(p.normalizeUrl("http://worklog.example.com"), "http://worklog.example.com")
        compare(p.normalizeUrl("HTTPS://x.example.com//"), "HTTPS://x.example.com")
        compare(p.normalizeUrl(""), "")
    }

    function test_clear_text_warning() {
        const p = load()
        verify(p.clearTextLogin("http://worklog.example.com", "someone"))
        verify(!p.clearTextLogin("http://worklog.example.com", ""))
        verify(!p.clearTextLogin("https://worklog.example.com", "someone"))
        verify(!p.clearTextLogin("http://192.168.0.10:8000", "someone"))
        verify(!p.clearTextLogin("http://nas", "someone"))
    }

    function test_week_length_accepts_comma_and_point() {
        const p = load()
        const f = p.weekFieldItem
        verify(f)
        f.text = "37,5"
        compare(p.weekHours, 37.5)
        f.text = "37.5"
        compare(p.weekHours, 37.5)
        f.text = "0"
        verify(p.weekHours < 1)
        f.text = ""
        verify(isNaN(p.weekHours))
    }

    function test_defaults_load_and_save() {
        const p = load()
        tryVerify(() => p.hasDefaults, 5000)
        const before = p.settings.default_type
        verify(p.settings.break_types.indexOf(p.settings.default_break_type) >= 0)
        p.save({ default_type: "prep", calendar_auto_add: true }, m => p.defaultsMessage = m)
        tryVerify(() => p.settings.default_type === "prep" && p.settings.calendar_auto_add === true, 5000)
        compare(p.defaultsMessage, qsTr("Saved"))
        p.save({ default_type: "eat" }, m => p.defaultsMessage = m)   // a break type: refused
        tryVerify(() => p.defaultsMessage.indexOf("Error") === 0, 5000)
        p.save({ default_type: before, calendar_auto_add: false }, m => p.defaultsMessage = m)
        tryVerify(() => p.settings.default_type === before && p.settings.calendar_auto_add === false, 5000)
    }

    function test_saved_message_goes_away() {
        const p = load()
        p.flash(m => p.hoursMessage = m)
        compare(p.hoursMessage, qsTr("Saved"))
        tryVerify(() => p.hoursMessage === "", 6000)
    }

    function test_sign_out_clears_the_login() {
        const p = load()
        Api.setServer(testServer, "someone", "secret")
        p.signOut()
        compare(Api.username, "")
        compare(Api.password, "")
        compare(Api.serverUrl, testServer)
    }
}
