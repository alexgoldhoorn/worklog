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

    header: TabBar {
        id: tabs
        Material.background: Api.card
        topPadding: window.safe.top
        leftPadding: window.safe.left
        rightPadding: window.safe.right
        TabButton { text: qsTr("Timer"); width: implicitWidth }
        TabButton { text: qsTr("Pomodoro"); width: implicitWidth }
        TabButton { text: qsTr("Log"); width: implicitWidth }
        TabButton { text: qsTr("Reports"); width: implicitWidth }
        TabButton { text: qsTr("Days"); width: implicitWidth }
        TabButton { text: qsTr("Settings"); width: implicitWidth }
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
