import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// A tinted one-line message; level is "error", "warn" or "info". Tappable when `tappable`, and always when
// it is the login error, which opens Settings.
Pane {
    id: banner
    property string text
    property string level: "info"
    property bool tappable: false
    signal tapped()

    readonly property bool isLogin: text.indexOf(Api.loginMessage) >= 0
    readonly property color tone: level === "error" ? Api.errorColor
                                : level === "warn" ? Api.warnColor : Api.infoColor

    Layout.fillWidth: true
    Layout.leftMargin: 12
    Layout.rightMargin: 12
    padding: 12
    Material.background: Qt.alpha(tone, 0.15)
    Material.elevation: 0
    Material.roundedScale: Material.SmallScale

    RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 10
        Label {
            text: banner.level === "info" ? "ⓘ" : "⚠"
            color: banner.tone
            font.pixelSize: 16
        }
        Label {
            text: banner.text
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
        Label {
            visible: banner.tappable
            text: "›"
            font.pixelSize: 18
            opacity: 0.5
        }
        Button {
            visible: banner.isLogin
            text: qsTr("Settings")
            flat: true
            Material.foreground: banner.tone
            topInset: 0
            bottomInset: 0
            onClicked: Api.settingsRequested()
        }
    }

    TapHandler {
        enabled: banner.tappable || banner.isLogin
        onTapped: banner.isLogin ? Api.settingsRequested() : banner.tapped()
    }
}
