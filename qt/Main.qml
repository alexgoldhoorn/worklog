import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Controls.Material

ApplicationWindow {
    id: window
    width: 480
    height: 820
    minimumWidth: 320
    minimumHeight: 480
    visible: true
    title: qsTr("Worklog")

    Material.theme: Material.System
    Material.accent: Api.accent
    Material.background: Api.bg
    color: Api.bg

    // Android draws the app under the status and navigation bars: keep the tabs and pages clear of them
    readonly property var safe: SafeArea.margins

    header: Item {
        implicitHeight: tabs.implicitHeight

    TabBar {
        id: tabs
        anchors.fill: parent
        Material.background: Api.card
        topPadding: window.safe.top
        leftPadding: window.safe.left
        rightPadding: window.safe.right
        Accessible.role: Accessible.PageTabList
        Accessible.name: qsTr("Sections")
        TabButton { text: qsTr("Timer"); width: implicitWidth; Accessible.name: text; Accessible.role: Accessible.PageTab }
        TabButton { text: qsTr("Pomodoro"); width: implicitWidth; Accessible.name: text; Accessible.role: Accessible.PageTab }
        TabButton { text: qsTr("Log"); width: implicitWidth; Accessible.name: text; Accessible.role: Accessible.PageTab }
        TabButton { text: qsTr("Reports"); width: implicitWidth; Accessible.name: text; Accessible.role: Accessible.PageTab }
        TabButton { text: qsTr("Days"); width: implicitWidth; Accessible.name: text; Accessible.role: Accessible.PageTab }
        TabButton { text: qsTr("Settings"); width: implicitWidth; Accessible.name: text; Accessible.role: Accessible.PageTab }
    }
        TabFade {
            atRight: true
            shown: window.tabStrip !== null
                   && window.tabStrip.contentX + window.tabStrip.width < window.tabStrip.contentWidth - 2
        }
        TabFade {
            atRight: false
            shown: window.tabStrip !== null && window.tabStrip.contentX > 2
        }
    }
    readonly property Flickable tabStrip: tabs.contentItem as Flickable

    // scroll hints: a fade with an arrow on the side where more tabs are hidden
    component TabFade: Rectangle {
        id: fade
        property bool atRight: true
        property bool shown: false
        width: 36
        visible: shown
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: atRight ? parent.right : undefined
        anchors.left: atRight ? undefined : parent.left
        gradient: Gradient {
            orientation: Gradient.Horizontal
            GradientStop { position: 0; color: fade.atRight ? Qt.alpha(Api.card, 0) : Api.card }
            GradientStop { position: 1; color: fade.atRight ? Api.card : Qt.alpha(Api.card, 0) }
        }
        Text {
            anchors.verticalCenter: parent.verticalCenter
            anchors.right: fade.atRight ? parent.right : undefined
            anchors.left: fade.atRight ? undefined : parent.left
            anchors.margins: 4
            text: fade.atRight ? "›" : "‹"
            color: Api.muted
            font.pixelSize: 22
            font.bold: true
        }
    }

    // no login yet (first start): the tabs past "Days" are off-screen on a phone, so go straight to Settings
    Component.onCompleted: if (Api.username === "") tabs.currentIndex = tabs.count - 1
    Connections {
        target: Api
        function onSettingsRequested() { tabs.currentIndex = tabs.count - 1 }
    }

    StackLayout {
        id: stack
        anchors.fill: parent
        anchors.leftMargin: window.safe.left
        anchors.rightMargin: window.safe.right
        anchors.bottomMargin: window.safe.bottom
        currentIndex: tabs.currentIndex
        // a hidden page's text field keeps the focus and would swallow the next page's shortcuts
        onCurrentIndexChanged: stack.forceActiveFocus()
        TimerPage {
            onOpenDay: date => {
                logPage.date = date
                tabs.currentIndex = 2
            }
        }
        PomodoroPage {
            onAttention: {
                tabs.currentIndex = 1
                window.alert(0)   // flash the taskbar entry until the window is activated
            }
        }
        DayPage { id: logPage }
        ReportsPage {}
        ExpectedPage {}
        SettingsPage {}
    }
}
