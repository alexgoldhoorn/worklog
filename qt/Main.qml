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
    visible: false   // WindowState shows it once the saved geometry is applied (and not for --minimized)
    title: qsTr("Worklog")

    Material.theme: Material.System
    Material.accent: Api.accent
    Material.background: Api.bg
    color: Api.bg

    // Windows: closing the window hides it to the tray (when the tray exists and the setting is on)
    readonly property var trayCtl: trayLoader.item
    readonly property bool hidesToTray: Api.trayCapable && Api.trayKeep && !!trayCtl && trayCtl.available
    onClosing: close => {
        // Android's back key: from a screen of the More menu it leads back to Today first
        if (Qt.platform.os === "android" && window.inMore) {
            close.accepted = false
            window.current = window.navToday
            return
        }
        if (hidesToTray) {
            close.accepted = false
            window.hide()
        } else {
            Qt.quit()
        }
    }
    Loader {
        id: trayLoader
        active: Api.trayCapable
        source: "TrayController.qml"
        onLoaded: window.trayCtl.window = window
    }
    // Declared after the tray loader: its start-up logic needs to know whether a tray exists
    WindowState {
        appWindow: window
        startHidden: Autostart.startMinimized && window.hidesToTray
    }
    IdleWatcher {   // Windows: "you were away, log it as a break?"
        appWindow: window
        tray: window.trayCtl
    }

    // Android draws the app under the status and navigation bars: keep the tabs and pages clear of them
    readonly property var safe: SafeArea.margins

    // ---- navigation -----------------------------------------------------------
    // Positions in the StackLayout below. The first three have a button at the bottom; the rest are
    // reached through the header's More menu and get a back arrow. Update these when a page is inserted.
    readonly property int navToday: 0
    readonly property int navWeek: 1
    readonly property int navFocus: 2
    readonly property int navReports: 3
    readonly property int navExpected: 4
    readonly property int navFind: 5
    readonly property int navSettings: 6
    property int current: navToday
    readonly property bool inMore: current > navFocus
    readonly property var titles: [qsTr("Today"), qsTr("Week"), qsTr("Focus"), qsTr("Reports"),
                                   qsTr("Expected hours"), qsTr("Find a free date"), qsTr("Settings")]

    header: Rectangle {
        color: Api.card
        implicitHeight: bar.implicitHeight + window.safe.top

        RowLayout {
            id: bar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: window.safe.left + 4
            anchors.rightMargin: window.safe.right + 4
            spacing: 0

            ToolButton {
                visible: window.inMore
                text: "‹"
                font.pixelSize: 24
                implicitWidth: 48
                Accessible.name: qsTr("Back to Today")
                Accessible.role: Accessible.Button
                onClicked: window.current = window.navToday
            }
            // the Today screen: step a day, or tap the date for the calendar
            ToolButton {
                visible: window.current === window.navToday
                text: "‹"
                font.pixelSize: 24
                implicitWidth: 48
                Accessible.name: qsTr("Previous day")
                Accessible.role: Accessible.Button
                onClicked: todayScreen.step(-1)
            }
            ToolButton {
                visible: window.current === window.navToday
                text: todayScreen.heading
                font.pixelSize: 16
                font.weight: Font.DemiBold
                font.capitalization: Font.MixedCase
                Layout.fillWidth: true
                Accessible.name: qsTr("Pick a date, now %1").arg(todayScreen.date)
                Accessible.role: Accessible.Button
                onClicked: todayScreen.pickDate()
            }
            ToolButton {
                visible: window.current === window.navToday
                text: "›"
                font.pixelSize: 24
                implicitWidth: 48
                Accessible.name: qsTr("Next day")
                Accessible.role: Accessible.Button
                onClicked: todayScreen.step(1)
            }
            Label {
                visible: window.current !== window.navToday
                text: window.titles[window.current] || ""
                font.pixelSize: 16
                font.weight: Font.DemiBold
                color: Api.fg
                elide: Text.ElideRight
                leftPadding: window.inMore ? 4 : 12
                Layout.fillWidth: true
            }
            ToolButton {
                text: "⋮"
                font.pixelSize: 22
                implicitWidth: 48
                Accessible.name: qsTr("More screens")
                Accessible.role: Accessible.ButtonMenu
                onClicked: moreMenu.open()
                Menu {
                    id: moreMenu
                    y: parent.height
                    MenuItem { text: window.titles[window.navReports]; onTriggered: window.current = window.navReports }
                    MenuItem { text: window.titles[window.navExpected]; onTriggered: window.current = window.navExpected }
                    MenuItem { text: window.titles[window.navFind]; onTriggered: window.current = window.navFind }
                    MenuSeparator {}
                    MenuItem { text: window.titles[window.navSettings]; onTriggered: window.current = window.navSettings }
                }
            }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Api.line }
    }

    footer: Rectangle {
        color: Api.card
        implicitHeight: navRow.implicitHeight + window.safe.bottom

        Rectangle { width: parent.width; height: 1; color: Api.line }
        RowLayout {
            id: navRow
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: window.safe.left
            anchors.rightMargin: window.safe.right
            spacing: 0
            NavButton {
                text: window.titles[window.navToday]
                active: window.current === window.navToday
                onClicked: {
                    todayScreen.show("")   // a second tap comes back from another day
                    window.current = window.navToday
                }
            }
            NavButton {
                text: window.titles[window.navWeek]
                active: window.current === window.navWeek
                onClicked: window.current = window.navWeek
            }
            NavButton {
                text: window.titles[window.navFocus]
                active: window.current === window.navFocus
                onClicked: window.current = window.navFocus
            }
        }
    }

    // one of the bottom buttons: a label under a marker that shows where you are
    component NavButton: AbstractButton {
        id: nav
        property bool active: false
        implicitHeight: 52
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        Accessible.name: text
        Accessible.role: Accessible.PageTab
        contentItem: Label {
            text: nav.text
            color: nav.active ? Api.accent : Api.muted
            font.pixelSize: 14
            font.weight: nav.active ? Font.Bold : Font.Normal
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        background: Rectangle {
            color: nav.down ? Qt.alpha(Api.accent, 0.14) : nav.hovered ? Qt.alpha(Api.accent, 0.06) : "transparent"
            Rectangle {
                visible: nav.active
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width * 0.4
                height: 3
                radius: 1.5
                color: Api.accent
            }
        }
    }

    // no login yet (first start): go straight to Settings
    Component.onCompleted: if (Api.username === "") window.current = window.navSettings
    Connections {
        target: Api
        function onSettingsRequested() { window.current = window.navSettings }
    }

    StackLayout {
        id: stack
        anchors.fill: parent
        anchors.leftMargin: window.safe.left
        anchors.rightMargin: window.safe.right
        currentIndex: window.current
        // a hidden page's text field keeps the focus and would swallow the next page's shortcuts
        onCurrentIndexChanged: stack.forceActiveFocus()
        TodayPage { id: todayScreen }
        WeekPage {}
        PomodoroPage {
            onAttention: {
                window.current = window.navFocus
                window.alert(0)   // flash the taskbar entry until the window is activated
            }
        }
        ReportsPage {}
        ExpectedPage {}
        FindPage {}
        SettingsPage {}
    }

    // Android, "Require fingerprint/face to open": covers everything until Biometric confirms
    Rectangle {
        id: lockScreen
        visible: Api.locked
        parent: Overlay.overlay
        anchors.fill: parent
        color: Api.bg
        property string message: ""
        // swallow touches meant for the tabs and pages underneath
        MouseArea { anchors.fill: parent }
        function ask() {
            lockScreen.message = ""
            Biometric.authenticate(qsTr("Unlock Worklog"), qsTr("Opens the saved login"))
        }
        Component.onCompleted: if (Api.locked) ask()
        Connections {
            target: Api
            function onLockedChanged() {   // locked again after the app was away
                if (Api.locked)
                    lockScreen.ask()
            }
        }
        Connections {
            target: Biometric
            function onResult(ok, error) {
                if (!Api.locked)
                    return
                if (ok)
                    Api.unlock()
                else
                    lockScreen.message = error
            }
        }
        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(parent.width - 32, 360)
            spacing: 16
            Label {
                text: qsTr("Worklog is locked")
                font.pixelSize: 22
                font.bold: true
                color: Api.fg
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
            }
            Label {
                text: lockScreen.message
                visible: text !== ""
                color: Api.errorColor
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
            }
            Button {
                text: qsTr("Unlock")
                highlighted: true
                Accessible.name: text
                Layout.alignment: Qt.AlignHCenter
                onClicked: lockScreen.ask()
            }
        }
    }
}
