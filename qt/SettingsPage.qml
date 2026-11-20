pragma ComponentBehavior: Bound
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
    // "10.1.2.3" -> [10, 1, 2, 3]; null when it is not a dotted IPv4 address (so "10.example.com" is not one)
    function ipv4Octets(h) {
        const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h)
        if (!m)
            return null
        const o = m.slice(1).map(Number)
        return o.every(x => x <= 255) ? o : null
    }
    // A LAN server (the password may travel over http): localhost and 127/8, 10/8, 172.16/12, 192.168/16,
    // link-local 169.254/16, carrier-grade NAT 100.64/10 (Tailscale and the like), IPv6 loopback, fc00::/7
    // and fe80::/10, *.local, and a bare hostname (no dot). Names are matched as names, never by prefix.
    function isLocalHost(host) {
        const h = host.toLowerCase().replace(/\.$/, "")
        if (h === "")
            return false
        if (h.indexOf(":") >= 0)
            return /^(0{1,4}:){7}0{0,3}1$/.test(h) || h === "::1" || /^fe[89ab][0-9a-f]:/.test(h) || /^f[cd][0-9a-f]{2}:/.test(h)
        const o = ipv4Octets(h)
        if (o)
            return o[0] === 10 || o[0] === 127 || (o[0] === 172 && o[1] >= 16 && o[1] <= 31)
                   || (o[0] === 192 && o[1] === 168) || (o[0] === 169 && o[1] === 254)
                   || (o[0] === 100 && o[1] >= 64 && o[1] <= 127)
        return h === "localhost" || /\.local$/.test(h) || h.indexOf(".") < 0
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

    // "Test connection": the typed address and login are tried (GET /api/status?brief=1) without saving them
    property bool testing: false
    property string testMessage: ""
    property bool testOk: false
    function testNow() {
        const url = normalizeUrl(urlField.text)
        testing = true
        testMessage = ""
        Api.probe(url, userField.text, passwordField.text, function (r) {
            if (!page)
                return
            page.testing = false
            page.testOk = r.ok
            page.testMessage = r.message
        })
    }

    property string saveError: ""
    function connectNow() {
        const url = normalizeUrl(urlField.text)
        urlField.text = url
        saveError = Api.setServer(url, userField.text, passwordField.text)   // "" or "Could not save the password on this device"
    }
    // forgets the user and the password (and the stored secret); the pages then show the login message
    function signOut() {
        userField.text = ""
        passwordField.text = ""
        saveError = Api.setServer(Api.serverUrl, "", "")   // also drops the waiting actions (another login)
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
            if (page.currencyMessage === qsTr("Saved"))
                page.currencyMessage = ""
        }
    }

    contentWidth: availableWidth

    // the server's defaults for Start and Pause (a server from before them does not send any)
    readonly property bool hasDefaults: !!settings && settings.default_type !== undefined
    property string defaultsMessage: ""

    // the break types the Defaults card offers; replaced only when they changed, so the ComboBox keeps an unsaved pick
    property var breakTypes: []

    function fillHours(st) { weekField.text = String(st.week_basis_h) }
    function fillRate(st) {
        rateField.text = st.rate === null ? "" : String(st.rate)
        unitBox.currentIndex = Math.max(0, unitBox.find(st.rate_unit))
    }
    // the currency symbol: 1 to 4 characters once trimmed
    readonly property bool currencyValid: currencyField.text.trim().length >= 1 && currencyField.text.trim().length <= 4
    property string currencyMessage: ""
    function fillCurrency(st) { if (st.currency !== undefined) currencyField.text = st.currency }

    // ---- clients and break types (the lists the server keeps; a 409 comes back as its own text) ----------
    property var clients: []
    property var breakList: []
    property string clientsError: ""
    property string breakError: ""
    property string renaming: ""        // the client the rename dialog is for
    property string renamingBreak: ""   // the break type the other rename dialog is for
    function loadLists() {
        Api.request("GET", "/api/clients", undefined, function (l) { if (page) page.clients = l }, function (e) { if (page) page.clientsError = e })
        Api.request("GET", "/api/break-types", undefined, function (l) { if (page) page.breakList = l }, function (e) { if (page) page.breakError = e })
    }
    // one change to a list; the answer (or the error) lands in `setError`, the lists are read again
    function listCall(method, path, body, setError) {
        setError("")
        Api.request(method, path, body, function () {
            if (!page)
                return
            page.loadLists()
            page.reload("defaults")   // a renamed client or a new break type shows in the Defaults card
        }, e => setError(e))
    }
    function addClient(name, billable) {
        listCall("POST", "/api/clients", { name: name.trim(), billable: billable }, e => page.clientsError = e)
    }
    function setBillable(name, billable) {
        listCall("PUT", "/api/clients/" + encodeURIComponent(name), { billable: billable }, e => page.clientsError = e)
    }
    function renameClient(name, to) {
        listCall("PUT", "/api/clients/" + encodeURIComponent(name), { name: to.trim() }, e => page.clientsError = e)
    }
    function deleteClient(name) {
        listCall("DELETE", "/api/clients/" + encodeURIComponent(name), undefined, e => page.clientsError = e)
    }
    function addBreak(name) {
        listCall("POST", "/api/break-types", { name: name.trim() }, e => page.breakError = e)
    }
    function renameBreak(name, to) {
        listCall("PUT", "/api/break-types/" + encodeURIComponent(name), { name: to.trim() }, e => page.breakError = e)
    }
    function deleteBreak(name) {
        listCall("DELETE", "/api/break-types/" + encodeURIComponent(name), undefined, e => page.breakError = e)
    }
    function fillDefaults(st) {
        if (JSON.stringify(page.breakTypes) !== JSON.stringify(st.break_types))
            page.breakTypes = st.break_types
        typeField.text = st.default_type
        clientField.text = st.default_client || ""
        breakBox.currentIndex = st.break_types.indexOf(st.default_break_type)
        closeField.text = st.auto_close_time
        autoAddSwitch.checked = st.calendar_auto_add
    }

    // Reads the server's settings. `section` ("hours", "rate", "defaults") refreshes only that card's
    // fields, so saving one card never overwrites what was typed in another; without it all are filled.
    function reload(section) {
        if (!section)
            connected = null
        Api.request("GET", "/api/settings", undefined, function (s) {
            if (!weekField)   // the answer came after the page was gone
                return
            page.settings = s
            page.connected = true
            page.serverMessage = qsTr("Connected to %1").arg(Api.baseUrl)
            if (!section || section === "hours")
                page.fillHours(s)
            if (!section || section === "rate")
                page.fillRate(s)
            if (page.hasDefaults && (!section || section === "defaults"))
                page.fillDefaults(s)
            if (!section || section === "currency")
                page.fillCurrency(s)
        }, function (e) {
            if (!weekField)   // the page was gone
                return
            page.connected = false
            page.serverMessage = e
        })
    }

    function save(body, setMessage, section) {
        Api.request("PUT", "/api/settings", body, function (s) {
            page.flash(setMessage)
            page.reload(section)
        }, e => setMessage(qsTr("Error: %1").arg(e)))
    }

    Component.onCompleted: { reload(); loadLists() }
    Connections {
        target: Api
        function onServerChanged() { page.reload(); page.loadLists() }
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
            // user and password side by side on a wide screen; below 420 the user has its own line, so the
            // password field is wide enough to show what is typed
            GridLayout {
                columns: page.availableWidth < 420 ? 2 : 3
                columnSpacing: 8
                rowSpacing: 4
                Layout.fillWidth: true
                Layout.leftMargin: 18
                TextField {
                    id: userField
                    text: Api.username
                    placeholderText: qsTr("User")
                    Layout.fillWidth: true
                    Layout.columnSpan: page.availableWidth < 420 ? 2 : 1
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
                AppButton {
                    flat: true
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
            Flow {
                id: serverRow
                Layout.fillWidth: true
                spacing: 8
                Label {
                    width: Math.max(160, serverRow.width - 8)
                    text: page.connected === null ? qsTr("Connecting…") : page.serverMessage
                    color: page.connected === false ? Api.errorColor : page.Material.foreground
                    opacity: page.connected ? 0.7 : 1
                    wrapMode: Text.Wrap
                }
                AppButton {
                    id: signOutButton
                    visible: Api.username !== "" || Api.password !== ""
                    text: qsTr("Sign out")
                    flat: true
                    Accessible.name: qsTr("Sign out: forget the saved user and password")
                    Accessible.role: Accessible.Button
                    onClicked: signOutDialog.open()
                }
                AppButton {
                    id: testButton
                    text: page.testing ? qsTr("Testing…") : qsTr("Test connection")
                    flat: true
                    enabled: !page.testing && urlField.text.trim() !== ""
                    Accessible.name: qsTr("Test connection: try this address and login without saving them")
                    Accessible.role: Accessible.Button
                    onClicked: page.testNow()
                }
                AppButton {
                    id: connectButton
                    text: qsTr("Connect")
                    highlighted: true
                    onClicked: page.connectNow()
                }
            }
            Label {
                visible: page.testMessage !== ""
                text: page.testMessage
                color: page.testOk ? Api.workColor : Api.errorColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
                Accessible.name: text
            }
            Label {
                visible: page.saveError !== ""
                text: page.saveError
                color: Api.errorColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            // Android only: the saved login opens after a fingerprint/face (or the screen lock)
            AppSwitch {
                id: unlockSwitch
                visible: Qt.platform.os === "android" && Biometric.isAvailable()
                text: qsTr("Ask for fingerprint or face when the app opens")
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
            Caption {
                visible: unlockSwitch.visible
                text: qsTr("The home-screen widget, the quick tile and the notification stay usable without it.")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
                wrapMode: Text.Wrap
                Layout.fillWidth: true
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
            visible: Qt.platform.os !== "android"
            title: qsTr("Keyboard")

            AppSwitch {
                id: shortcutSwitch
                text: qsTr("Single-key shortcuts (S, P, X, 1–6, arrows)")
                checked: Api.keyShortcuts
                onToggled: Api.keyShortcuts = checked
                Accessible.name: text
            }
            Caption {
                text: qsTr("They never act while a text field, list or number box has the focus.")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }

        Card {
            visible: Api.trayCapable
            title: qsTr("Tray and hotkey")

            AppSwitch {
                text: qsTr("Keep running in the tray")
                checked: Api.trayKeep
                onToggled: Api.trayKeep = checked
            }
            AppSwitch {
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
            AppSwitch {
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
            AppSwitch {
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
            AppSwitch {
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
                AppButton {
                    text: qsTr("Save")
                    highlighted: true
                    enabled: page.weekHours >= 1 && page.weekHours <= 80
                    onClicked: page.save({ week_basis_h: page.weekHours }, m => page.hoursMessage = m, "hours")
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
                ComboBox {
                    id: unitBox
                    model: ["h", "day"]
                    displayText: Api.currency + "/" + currentText
                    delegate: ItemDelegate {
                        required property string modelData
                        width: unitBox.width
                        text: Api.currency + "/" + modelData
                    }
                    Layout.preferredWidth: 110
                    Accessible.name: qsTr("Rate unit")
                }
                AppButton {
                    text: qsTr("Save")
                    highlighted: true
                    enabled: rateField.text.trim() === "" || isFinite(page.parseRate(rateField.text))
                    onClicked: page.save({ rate: rateField.text.trim() === "" ? null : page.parseRate(rateField.text),
                                           rate_unit: unitBox.currentText }, m => page.rateMessage = m, "rate")
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
                model: page.breakTypes
                Layout.fillWidth: true
                Accessible.name: qsTr("Default break type")
            }
            Caption { text: qsTr("Close a forgotten block at (HH:MM)") }
            TimeField {
                id: closeField
                Layout.fillWidth: true
                Accessible.name: qsTr("Auto-close time")
                onTextEdited: page.defaultsMessage = ""
            }
            AppSwitch {
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
                AppButton {
                    text: qsTr("Save")
                    highlighted: true
                    enabled: typeField.text.trim() !== "" && breakBox.currentIndex >= 0
                             && /^\d{1,2}[:.h]?\d{2}$/.test(closeField.text.trim())
                    onClicked: page.save({ default_type: typeField.text.trim(), default_client: clientField.text.trim() || null,
                                           default_break_type: breakBox.currentText,
                                           auto_close_time: Api.normTime(closeField.text),
                                           calendar_auto_add: autoAddSwitch.checked }, m => page.defaultsMessage = m, "defaults")
                }
            }
        }

        Card {
            title: qsTr("Currency")
            enabled: page.connected === true

            Caption {
                text: qsTr("Symbol or code shown beside amounts (1 to 4 characters, no conversion)")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            RowLayout {
                Layout.fillWidth: true
                TextField {
                    id: currencyField
                    maximumLength: 4
                    Layout.fillWidth: true
                    Accessible.name: qsTr("Currency")
                    onTextEdited: page.currencyMessage = ""
                }
                AppButton {
                    text: qsTr("Save")
                    highlighted: true
                    enabled: page.currencyValid
                    onClicked: page.save({ currency: currencyField.text.trim() }, m => page.currencyMessage = m, "currency")
                }
            }
            Label {
                text: page.currencyMessage
                visible: text !== ""
                opacity: 0.7
            }
        }

        Card {
            title: qsTr("Clients")
            enabled: page.connected === true

            Caption {
                text: qsTr("Billable clients are priced with the rate; a block carries its client's name. A client in use cannot be deleted.")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: page.clients.length === 0
                text: qsTr("No clients yet.")
                color: Api.muted
            }
            Repeater {
                model: page.clients
                // the name on its own line, then the controls: a long name never squeezes them
                delegate: ColumnLayout {
                    id: crow
                    required property var modelData
                    spacing: 0
                    Layout.fillWidth: true
                    Label { text: crow.modelData.name; wrapMode: Text.Wrap; font.weight: Font.DemiBold; Layout.fillWidth: true }
                    RowLayout {
                        spacing: 4
                        Layout.fillWidth: true
                        AppSwitch {
                            text: qsTr("Billable")
                            checked: crow.modelData.billable
                            Accessible.name: qsTr("%1 is billable").arg(crow.modelData.name)
                            onToggled: page.setBillable(crow.modelData.name, checked)
                        }
                        AppIconButton {
                            text: "✎"
                            name: qsTr("Rename %1").arg(crow.modelData.name)
                            onClicked: { page.renaming = crow.modelData.name; renameField.text = crow.modelData.name; renameDialog.open() }
                        }
                        AppIconButton {
                            text: "×"
                            name: qsTr("Delete %1").arg(crow.modelData.name)
                            onClicked: page.deleteClient(crow.modelData.name)
                        }
                    }
                }
            }
            TextField {
                id: newClient
                placeholderText: qsTr("New client")
                maximumLength: 100
                Layout.fillWidth: true
                Accessible.name: qsTr("New client name")
                onAccepted: addClientButton.clicked()
            }
            RowLayout {
                Layout.fillWidth: true
                CheckBox { id: newClientBillable; text: qsTr("Billable"); checked: true }
                Item { Layout.fillWidth: true }
                AppButton {
                    id: addClientButton
                    text: qsTr("Add")
                    highlighted: true
                    enabled: newClient.text.trim() !== ""
                    onClicked: { page.addClient(newClient.text, newClientBillable.checked); newClient.text = "" }
                }
            }
            Label {
                visible: page.clientsError !== ""
                text: page.clientsError
                color: Api.errorColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }

        Card {
            title: qsTr("Break types")
            enabled: page.connected === true

            Caption {
                text: qsTr("What Pause can log. The default (first) and the ones blocks use cannot be deleted.")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Flow {
                spacing: 6
                Layout.fillWidth: true
                Repeater {
                    model: page.breakList
                    delegate: Rectangle {
                        id: bchip
                        required property var modelData
                        required property int index
                        implicitHeight: 36
                        implicitWidth: brow.implicitWidth + 20
                        radius: 18
                        color: "transparent"
                        border.color: bchip.index === 0 ? Api.accent : Api.line
                        Row {
                            id: brow
                            anchors.left: parent.left
                            anchors.leftMargin: 12
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 0
                            Label {
                                anchors.verticalCenter: parent.verticalCenter
                                rightPadding: 4
                                text: bchip.modelData + (bchip.index === 0 ? " · " + qsTr("default") : "")
                            }
                            AppIconButton {
                                text: "✎"
                                name: qsTr("Rename break type %1").arg(bchip.modelData)
                                onClicked: { page.renamingBreak = bchip.modelData; renameBreakField.text = bchip.modelData; renameBreakDialog.open() }
                            }
                            AppIconButton {
                                text: "×"
                                name: qsTr("Delete break type %1").arg(bchip.modelData)
                                onClicked: page.deleteBreak(bchip.modelData)
                            }
                        }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                TextField {
                    id: newBreak
                    placeholderText: qsTr("New break type")
                    maximumLength: 40
                    Layout.fillWidth: true
                    Accessible.name: qsTr("New break type name")
                    onAccepted: addBreakButton.clicked()
                }
                AppButton {
                    id: addBreakButton
                    text: qsTr("Add")
                    highlighted: true
                    enabled: newBreak.text.trim() !== ""
                    onClicked: { page.addBreak(newBreak.text); newBreak.text = "" }
                }
            }
            Label {
                visible: page.breakError !== ""
                text: page.breakError
                color: Api.errorColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
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

    AppDialog {
        id: renameDialog
        parent: Overlay.overlay
        modal: true
        title: qsTr("Rename %1").arg(page.renaming)
        width: Math.min(parent ? parent.width - 32 : 320, 400)
        standardButtons: Dialog.Save | Dialog.Cancel
        Material.accent: Api.accent
        onAccepted: page.renameClient(page.renaming, renameField.text)
        contentItem: ScrollBody {
            Label {
                text: qsTr("Blocks and the default client with this name follow the new name.")
                wrapMode: Text.Wrap
                color: Api.muted
                Layout.fillWidth: true
            }
            TextField {
                id: renameField
                maximumLength: 100
                Layout.fillWidth: true
                Accessible.name: qsTr("New name")
                onAccepted: renameDialog.accept()
            }
        }
    }

    AppDialog {
        id: renameBreakDialog
        parent: Overlay.overlay
        modal: true
        title: qsTr("Rename %1").arg(page.renamingBreak)
        width: Math.min(parent ? parent.width - 32 : 320, 400)
        standardButtons: Dialog.Save | Dialog.Cancel
        Material.accent: Api.accent
        onAccepted: page.renameBreak(page.renamingBreak, renameBreakField.text)
        contentItem: ScrollBody {
            Label {
                text: qsTr("Blocks and the default break type with this name follow the new name. Names are kept in lower case.")
                wrapMode: Text.Wrap
                color: Api.muted
                Layout.fillWidth: true
            }
            TextField {
                id: renameBreakField
                maximumLength: 40
                Layout.fillWidth: true
                Accessible.name: qsTr("New name")
                onAccepted: renameBreakDialog.accept()
            }
        }
    }

    AppDialog {
        id: signOutDialog
        parent: Overlay.overlay
        modal: true
        title: qsTr("Sign out?")
        width: Math.min(parent ? parent.width - 32 : 320, 400)
        standardButtons: Dialog.Yes | Dialog.Cancel
        Material.accent: Api.accent
        contentItem: Label {
            text: Api.queue.length > 0
                  ? qsTr("The saved user and password are forgotten. The %n action(s) still waiting to be sent are discarded.", "", Api.queue.length)
                  : qsTr("The saved user and password are forgotten.")
            wrapMode: Text.Wrap
        }
        onAccepted: page.signOut()
    }
}
