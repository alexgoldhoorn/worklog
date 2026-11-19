import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Server address (stored locally) and the server-side week basis / rate.
ScrollView {
    id: page
    property var settings: null
    property var connected: null   // null = unknown / testing, then true or false
    property string serverMessage: ""
    property string hoursMessage: ""
    property string rateMessage: ""
    // "12,5" and "12.5" both work; anything else is NaN and keeps Save disabled
    function parseRate(t) { return Api.parseNum(t) }

    // ---- server address helpers (pure; tests call them) -----------------------------------------

    // "https://user@Host:8000/x" -> "host"; an IPv6 literal comes without its brackets
    function hostOf(url) {
        const m = /^(?:[a-z][a-z0-9+.-]*:\/\/)?(?:[^@\/]*@)?(\[[^\]]*\]|[^:\/?#]*)/i.exec(url.trim())
        return m ? m[1].replace(/^\[|\]$/g, "").toLowerCase() : ""
    }
    // localhost, loopback, private ranges, *.local and a bare hostname (no dot): a LAN server
    function isLocalHost(host) {
        const h = host.toLowerCase()
        if (h === "")
            return false
        if (h.indexOf(":") >= 0)   // IPv6: loopback, link-local, unique-local
            return h === "::1" || /^fe80:/.test(h) || /^f[cd][0-9a-f]{2}:/.test(h)
        return h === "localhost" || /^127\./.test(h) || /^10\./.test(h) || /^192\.168\./.test(h)
               || /^172\.(1[6-9]|2\d|3[01])\./.test(h) || /\.local$/.test(h) || h.indexOf(".") < 0
    }
    // "worklog.example.com" -> "https://worklog.example.com", "nas:8000" -> "http://nas:8000"; an address that
    // already has a scheme is kept; trailing slashes go
    function normalizeUrl(text) {
        const t = text.trim().replace(/\/+$/, "")
        if (t === "" || /^[a-z][a-z0-9+.-]*:\/\//i.test(t))
            return t
        return (isLocalHost(hostOf(t)) ? "http://" : "https://") + t
    }
    // true when connecting would send the password unencrypted over the internet
    function clearTextLogin(url, user) {
        return /^http:\/\//i.test(url.trim()) && user.trim() !== "" && !isLocalHost(hostOf(url))
    }

    function connectNow() {
        const url = normalizeUrl(urlField.text)
        urlField.text = url
        Api.setServer(url, userField.text, passwordField.text)
    }
    // forgets the user and the password (and the stored secret); the pages then show the login message
    function signOut() {
        userField.text = ""
        passwordField.text = ""
        Api.setServer(Api.serverUrl, "", "")
    }

    property alias weekFieldItem: weekField   // tests
    // the typed week length, NaN when it is not a number
    readonly property real weekHours: Api.parseNum(weekField.text)

    // "Saved" disappears after a few seconds
    function flash(set) {
        set(qsTr("Saved"))
        savedTimer.restart()
    }
    Timer {
        id: savedTimer
        interval: 4000
        onTriggered: {
            if (page.hoursMessage === qsTr("Saved"))
                page.hoursMessage = ""
            if (page.rateMessage === qsTr("Saved"))
                page.rateMessage = ""
            if (page.defaultsMessage === qsTr("Saved"))
                page.defaultsMessage = ""
        }
    }

    contentWidth: availableWidth

    // the server's defaults for Start and Pause (a server from before them does not send any)
    readonly property bool hasDefaults: !!settings && settings.default_type !== undefined
    property string defaultsMessage: ""

    function reload() {
        connected = null
        Api.request("GET", "/api/settings", undefined, function (s) {
            if (!weekField)   // the answer came after the page was gone
                return
            page.settings = s
            page.connected = true
            page.serverMessage = qsTr("Connected to %1").arg(Api.baseUrl)
            weekField.text = String(s.week_basis_h)
            rateField.text = s.rate === null ? "" : String(s.rate)
            unitBox.currentIndex = Math.max(0, unitBox.model.indexOf(s.rate_unit))
            if (page.hasDefaults) {
                typeField.text = s.default_type
                clientField.text = s.default_client || ""
                breakBox.currentIndex = s.break_types.indexOf(s.default_break_type)
                closeField.text = s.auto_close_time
                autoAddSwitch.checked = s.calendar_auto_add
            }
        }, function (e) {
            page.connected = false
            page.serverMessage = e
        })
    }

    function save(body, setMessage) {
        Api.request("PUT", "/api/settings", body, function (s) {
            page.flash(setMessage)
            page.reload()
        }, e => setMessage(qsTr("Error: %1").arg(e)))
    }

    Component.onCompleted: reload()
    Connections {
        target: Api
        function onServerChanged() { page.reload() }
    }

    property bool confirmingUnlock: false
    property string unlockMessage: ""
    Connections {
        target: Biometric
        function onResult(ok, error) {
            if (!page.confirmingUnlock)
                return
            page.confirmingUnlock = false
            Api.requireUnlock = ok
            page.unlockMessage = ok ? "" : error
        }
    }

    ColumnLayout {
        width: page.availableWidth
        spacing: 16

        Card {
            title: qsTr("Server")
            Layout.topMargin: 12

            RowLayout {
                spacing: 8
                Layout.fillWidth: true
                Rectangle {
                    implicitWidth: 10
                    implicitHeight: 10
                    radius: 5
                    color: page.connected === null ? Api.idleColor
                         : page.connected ? Api.workColor : Api.errorColor
                }
                TextField {
                    id: urlField
                    text: Api.serverUrl
                    placeholderText: qsTr("Server URL, e.g. https://worklog.example.com")
                    inputMethodHints: Qt.ImhUrlCharactersOnly
                    Layout.fillWidth: true
                    onAccepted: connectButton.clicked()
                }
            }
            RowLayout {
                spacing: 8
                Layout.fillWidth: true
                Layout.leftMargin: 18
                TextField {
                    id: userField
                    text: Api.username
                    placeholderText: qsTr("User")
                    Layout.fillWidth: true
                    onAccepted: connectButton.clicked()
                }
                TextField {
                    id: passwordField
                    text: Api.password
                    placeholderText: qsTr("Password")
                    echoMode: showPassword.checked ? TextInput.Normal : TextInput.Password
                    inputMethodHints: showPassword.checked ? Qt.ImhSensitiveData | Qt.ImhNoPredictiveText : Qt.ImhNone
                    Layout.fillWidth: true
                    onAccepted: connectButton.clicked()
                }
                ToolButton {
                    id: showPassword
                    checkable: true
                    text: checked ? qsTr("Hide") : qsTr("Show")
                    Accessible.name: checked ? qsTr("Hide password") : qsTr("Show password")
                    Accessible.role: Accessible.Button
                    Accessible.checkable: true
                    Accessible.checked: checked
                }
            }
            NoticeBanner {
                id: clearTextWarning
                visible: page.clearTextLogin(page.normalizeUrl(urlField.text), userField.text)
                level: "warn"
                text: qsTr("This address is plain http:// on the internet: the password would travel unencrypted. Use https://.")
                Layout.leftMargin: 0
                Layout.rightMargin: 0
            }
            RowLayout {
                Layout.fillWidth: true
                Label {
                    text: page.connected === null ? qsTr("Connecting…") : page.serverMessage
                    color: page.connected === false ? Api.errorColor : page.Material.foreground
                    opacity: page.connected ? 0.7 : 1
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
                Button {
                    id: signOutButton
                    visible: Api.username !== "" || Api.password !== ""
                    text: qsTr("Sign out")
                    flat: true
                    Accessible.name: qsTr("Sign out: forget the saved user and password")
                    Accessible.role: Accessible.Button
                    onClicked: page.signOut()
                }
                Button {
                    id: connectButton
                    text: qsTr("Connect")
                    highlighted: true
                    onClicked: page.connectNow()
                }
            }
            // Android only: the saved login opens after a fingerprint/face (or the screen lock)
            Switch {
                id: unlockSwitch
                visible: Qt.platform.os === "android" && Biometric.isAvailable()
                text: qsTr("Require fingerprint/face to open")
                checked: Api.requireUnlock
                Accessible.name: text
                Layout.fillWidth: true
                // switching it on asks once first, so nobody locks themselves out with an unusable prompt
                onToggled: {
                    const want = checked
                    checked = Qt.binding(() => Api.requireUnlock)
                    if (!want) {
                        Api.requireUnlock = false
                    } else {
                        page.confirmingUnlock = true
                        Biometric.authenticate(qsTr("Require unlock"), qsTr("Confirm to turn it on"))
                    }
                }
            }
            Label {
                visible: unlockSwitch.visible && page.unlockMessage !== ""
                text: page.unlockMessage
                color: Api.errorColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }

        Card {
            visible: Api.trayCapable
            title: qsTr("Tray and hotkey")

            Switch {
                text: qsTr("Keep running in the tray")
                checked: Api.trayKeep
                onToggled: Api.trayKeep = checked
            }
            Switch {
                text: qsTr("Start with Windows, minimised to the tray")
                visible: Autostart.supported
                checked: Autostart.enabled
                Component.onCompleted: Autostart.refresh()   // the registry is the truth, not a saved setting
                onToggled: {
                    Autostart.enabled = checked
                    checked = Qt.binding(() => Autostart.enabled)   // snaps back when the entry could not be changed
                }
            }
            Label {
                text: Autostart.error
                visible: text !== ""
                color: Api.errorColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Switch {
                text: qsTr("Global start/pause hotkey")
                checked: Api.hotkeyOn
                onToggled: Api.hotkeyOn = checked
            }
            HotkeyField {
                enabled: Api.hotkeyOn
                sequence: Api.hotkeySeq
                Layout.fillWidth: true
                onCaptured: seq => Api.hotkeySeq = seq
            }
            Label {
                text: Api.hotkeyError
                visible: Api.hotkeyOn && text !== ""
                color: Api.errorColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Switch {
                text: qsTr("Ask when I come back after being away")
                visible: IdleMonitor.available
                checked: Api.idleOn
                onToggled: Api.idleOn = checked
            }
            RowLayout {
                visible: IdleMonitor.available
                enabled: Api.idleOn
                Layout.fillWidth: true
                Label {
                    text: qsTr("Away for at least (minutes)")
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
                SpinBox {
                    from: 1
                    to: 240
                    editable: true
                    value: Api.idleMinutes
                    onValueModified: Api.idleMinutes = value
                    Accessible.name: qsTr("Minutes away before asking")
                }
            }
            Switch {
                text: qsTr("Bring the window to the front to ask")
                visible: IdleMonitor.available
                enabled: Api.idleOn
                checked: Api.idleRaise
                onToggled: Api.idleRaise = checked
            }
            Caption {
                visible: IdleMonitor.available
                text: qsTr("Off: a tray message tells you, and the question waits in the window")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }

        Card {
            title: qsTr("Hours")
            enabled: page.connected === true

            Caption { text: qsTr("Full week (hours)") }
            RowLayout {
                Layout.fillWidth: true
                TextField {
                    id: weekField
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                    // "37.5" and "37,5" both, whatever the device's locale
                    validator: RegularExpressionValidator { regularExpression: /^\d{0,2}([.,]\d{0,2})?$/ }
                    Layout.fillWidth: true
                    Accessible.name: qsTr("Full week (hours)")
                    onTextEdited: page.hoursMessage = ""
                }
                Button {
                    text: qsTr("Save")
                    enabled: page.weekHours >= 1 && page.weekHours <= 80
                    onClicked: page.save({ week_basis_h: page.weekHours }, m => page.hoursMessage = m)
                }
            }
            Label {
                text: page.hoursMessage
                visible: text !== ""
                opacity: 0.7
            }
        }

        Card {
            title: qsTr("Rate")
            enabled: page.connected === true

            Caption { text: qsTr("Amount per unit (empty = none)") }
            RowLayout {
                Layout.fillWidth: true
                TextField {
                    id: rateField
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                    Layout.fillWidth: true
                    Accessible.name: qsTr("Amount per unit")
                    onTextEdited: page.rateMessage = ""
                }
                ComboBox { id: unitBox; model: ["h", "day"]; Layout.preferredWidth: 96 }
                Button {
                    text: qsTr("Save")
                    enabled: rateField.text.trim() === "" || isFinite(page.parseRate(rateField.text))
                    onClicked: page.save({ rate: rateField.text.trim() === "" ? null : page.parseRate(rateField.text),
                                           rate_unit: unitBox.currentText }, m => page.rateMessage = m)
                }
            }
            Label {
                text: [page.rateMessage,
                       page.settings && page.settings.rate_h !== null ? qsTr("= %1 per hour").arg(page.settings.rate_h) : ""]
                      .filter(x => x).join(" · ")
                visible: text !== ""
                opacity: 0.7
            }
        }

        Card {
            title: qsTr("Defaults")
            visible: page.hasDefaults
            enabled: page.connected === true

            Caption { text: qsTr("Work type when none is picked") }
            TextField {
                id: typeField
                maximumLength: 40
                Layout.fillWidth: true
                Accessible.name: qsTr("Default work type")
                onTextEdited: page.defaultsMessage = ""
            }
            Caption { text: qsTr("Client (empty = none)") }
            TextField {
                id: clientField
                maximumLength: 100
                Layout.fillWidth: true
                Accessible.name: qsTr("Default client")
                onTextEdited: page.defaultsMessage = ""
            }
            Caption { text: qsTr("Break type for Pause") }
            ComboBox {
                id: breakBox
                model: page.hasDefaults ? page.settings.break_types : []
                Layout.fillWidth: true
                Accessible.name: qsTr("Default break type")
            }
            Caption { text: qsTr("Close a forgotten block at (HH:MM)") }
            TextField {
                id: closeField
                inputMethodHints: Qt.ImhTime
                Layout.fillWidth: true
                Accessible.name: qsTr("Auto-close time")
                onTextEdited: page.defaultsMessage = ""
            }
            Switch {
                id: autoAddSwitch
                text: qsTr("Add finished meetings on their own")
                Layout.fillWidth: true
            }
            Caption {
                text: qsTr("A work-calendar meeting that is over and falls inside logged time becomes a meeting block")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            RowLayout {
                Layout.fillWidth: true
                Label {
                    text: page.defaultsMessage
                    opacity: 0.7
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
                Button {
                    text: qsTr("Save")
                    enabled: typeField.text.trim() !== "" && breakBox.currentIndex >= 0
                             && /^\d{1,2}[:.h]?\d{2}$/.test(closeField.text.trim())
                    onClicked: page.save({ default_type: typeField.text.trim(), default_client: clientField.text.trim() || null,
                                           default_break_type: breakBox.currentText,
                                           auto_close_time: Api.normTime(closeField.text),
                                           calendar_auto_add: autoAddSwitch.checked }, m => page.defaultsMessage = m)
                }
            }
        }

        Card {
            title: qsTr("About")

            Label {
                visible: !!Qt.application.version
                text: qsTr("App version %1").arg(Qt.application.version)
                Layout.fillWidth: true
            }
            Label {
                visible: Api.baseUrl !== ""
                text: qsTr("Server %1").arg(Api.baseUrl)
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                readonly property string tz: Api.status && Api.status.tz ? String(Api.status.tz) : ""
                visible: tz !== ""
                text: qsTr("Server time zone %1").arg(tz)
                Layout.fillWidth: true
            }
        }
        Item { implicitHeight: 8 }
    }
}
