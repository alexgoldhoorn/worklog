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

    contentWidth: availableWidth

    function reload() {
        connected = null
        Api.request("GET", "/api/settings", undefined, function (s) {
            page.settings = s
            page.connected = true
            page.serverMessage = qsTr("Connected to %1").arg(Api.baseUrl)
            weekField.text = s.week_basis_h
            rateField.text = s.rate === null ? "" : s.rate
            unitBox.currentIndex = Math.max(0, unitBox.model.indexOf(s.rate_unit))
        }, function (e) {
            page.connected = false
            page.serverMessage = e
        })
    }

    function save(body, setMessage) {
        Api.request("PUT", "/api/settings", body, function (s) {
            setMessage(qsTr("Saved"))
            page.reload()
        }, e => setMessage(qsTr("Error: %1").arg(e)))
    }

    Component.onCompleted: reload()
    Connections {
        target: Api
        function onServerChanged() { page.reload() }
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
                    echoMode: TextInput.Password
                    Layout.fillWidth: true
                    onAccepted: connectButton.clicked()
                }
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
                    id: connectButton
                    text: qsTr("Connect")
                    highlighted: true
                    onClicked: Api.setServer(urlField.text, userField.text, passwordField.text)
                }
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
                    validator: DoubleValidator { bottom: 1; top: 80 }
                    Layout.fillWidth: true
                }
                Button {
                    text: qsTr("Save")
                    enabled: weekField.acceptableInput
                    onClicked: page.save({ week_basis_h: Number(weekField.text) }, m => page.hoursMessage = m)
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
                }
                ComboBox { id: unitBox; model: ["h", "day"]; Layout.preferredWidth: 96 }
                Button {
                    text: qsTr("Save")
                    onClicked: page.save({ rate: rateField.text.trim() === "" ? null : Number(rateField.text),
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
        Item { implicitHeight: 8 }
    }
}
