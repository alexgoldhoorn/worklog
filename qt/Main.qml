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

    // the palette (Api) and the Material controls follow the same scheme: a mismatch left white labels on white buttons
    Material.theme: Api.dark ? Material.Dark : Material.Light
    Material.accent: Api.accent
    Material.background: Api.bg
    color: Api.bg

    // Windows: closing the window hides it to the tray (when the tray exists and the setting is on)
    readonly property var trayCtl: trayLoader.item
    readonly property bool hidesToTray: Api.trayCapable && Api.trayKeep && !!trayCtl && trayCtl.available
    onClosing: close => {
        // Android's back key, if it ever arrives as a close request (the Back key handling below is the normal path)
        if (Qt.platform.os === "android" && window.goBack()) {
            close.accepted = false
            return
        }
        if (hidesToTray) {
            close.accepted = false
            window.hide()
        } else {
            Qt.quit()
        }
    }
    // ---- the Back key (Android) ---------------------------------------------------------------
    // Qt 6.12 delivers Back to QML as Key_Back and does not call onClosing for it. From any other screen
    // (Day, Week, Pomodoro or one of the More menu) it leads to the Timer; on the Timer the system gets it
    // (home screen). The open More menu holds the focus and closes itself on Back.
    // True when it moved somewhere. The tests call it.
    function goBack() {
        if (window.current === window.navTimer)
            return false
        window.current = window.navTimer
        return true
    }
    // an open menu, dialog or picker holds the focus and closes itself on Back: the key is left to it
    function inOverlay(item) {
        for (let it = item; it; it = it.parent)
            if (it === keyHost.Overlay.overlay)
                return true
        return false
    }
    readonly property bool popupFocus: window.activeFocusItem ? window.inOverlay(window.activeFocusItem) : false
    // A shortcut sees the key wherever the focus is (on a button of the tab bar, or nowhere), so it comes
    // first; the focus scope around the pages (keyHost, below) is the second net.
    Shortcut {
        id: backShortcut
        sequences: ["Back"]
        context: Qt.ApplicationShortcut
        enabled: Qt.platform.os === "android" && window.current !== window.navTimer && !window.popupFocus
        onActivated: window.goBack()
    }
    // Taps on the header and the tab bar must not take the focus from the pages (Android only: with a
    // desktop keyboard one tabs through them)
    readonly property int tapFocus: Qt.platform.os === "android" ? Qt.NoFocus : Qt.StrongFocus
    // a lost focus (a popup closed, a hidden page) comes back to the pages, where the Back key is handled
    onActiveFocusItemChanged: {
        if (!activeFocusItem && visible)
            keyHost.forceActiveFocus()
        revealTimer.restart()
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
        startHidden: Autostart.startMinimized && Api.trayCapable && Api.trayKeep
        trayAvailable: !!window.trayCtl && window.trayCtl.available
    }
    IdleWatcher {   // Windows: "you were away, log it as a break?"
        appWindow: window
        tray: window.trayCtl
    }

    // Android draws the app under the status and navigation bars: keep the tabs and pages clear of them
    readonly property var safe: SafeArea.margins

    // The activity is resized for the keyboard (windowSoftInputMode adjustResize); as a fallback, if the window were not resized, the pages
    // end where the keyboard starts: how far it reaches into the content area, 0 when it is down.
    // Qt reports its rectangle in screen coordinates: mapFromGlobal gives the window's.
    function overlap(contentH, kbTop) { return kbTop > 0 && kbTop < contentH ? contentH - kbTop : 0 }
    // qmllint disable missing-property
    readonly property real keyboardOverlap: !Qt.inputMethod.visible || Qt.inputMethod.keyboardRectangle.height <= 0 ? 0
        : overlap(window.contentItem.height, window.contentItem.mapFromGlobal(0, Qt.inputMethod.keyboardRectangle.y).y)
    // qmllint enable missing-property
    // Android: the activity resizes for the keyboard (adjustResize), so the pages already end above it. The
    // tab bar steps aside while it is up, which gives the fields its room, and the focused field is scrolled
    // into view (a page's own Flickable; dialogs do it themselves).
    readonly property bool keyboardUp: Qt.platform.os === "android" && Qt.inputMethod.visible
    // qmllint disable missing-property
    function revealFocus() {
        const item = window.activeFocusItem
        if (!item || window.inOverlay(item))
            return
        let f = item.parent
        while (f && !(f.contentItem !== undefined && f.contentY !== undefined && f.contentHeight > f.height + 1))
            f = f.parent
        if (!f)
            return
        const top = item.mapToItem(f.contentItem, 0, 0).y
        let y = f.contentY
        if (top < y)
            y = top - 12
        else if (top + item.height > y + f.height)
            y = top + item.height - f.height + 12
        y = Math.max(0, Math.min(y, f.contentHeight - f.height))
        if (y !== f.contentY)
            f.contentY = y
    }
    // qmllint enable missing-property
    Timer { id: revealTimer; interval: 150; onTriggered: window.revealFocus() }
    onHeightChanged: revealTimer.restart()

    // ---- navigation -----------------------------------------------------------
    // Positions in the StackLayout below. The first four have a button in the bottom bar; the rest are
    // reached through the bar's fifth button, More, which opens a menu. Update these when a page is inserted.
    readonly property int navTimer: 0
    readonly property int navDay: 1
    readonly property int navWeek: 2
    readonly property int navPomodoro: 3
    readonly property int navReports: 4
    readonly property int navExpected: 5
    readonly property int navFind: 6
    readonly property int navSettings: 7
    property int current: navTimer
    readonly property bool inMore: current > navPomodoro
    // the same names, in the same order, as the web's navigation
    readonly property var titles: [qsTr("Timer"), qsTr("Day"), qsTr("Week"), qsTr("Pomodoro"), qsTr("Reports"),
                                   qsTr("Expected hours"), qsTr("Add or find a date"), qsTr("Settings")]
    readonly property var icons: ["timer", "day", "week", "pomodoro", "reports", "expected", "find", "settings"]

    // the More menu never stays open over the keyboard, the lock screen or a hidden window
    function closeMore() { moreMenu.close() }
    onKeyboardUpChanged: if (keyboardUp) closeMore()
    onVisibleChanged: if (!visible) closeMore()
    Connections {
        target: Api
        function onLockedChanged() { if (Api.locked) window.closeMore() }
    }

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

            // the Timer screen: step a day, or tap the date for the calendar
            AppIconButton {
                id: prevDay
                visible: window.current === window.navTimer
                text: "‹"
                focusPolicy: window.tapFocus
                name: qsTr("Previous day")
                onClicked: todayScreen.step(-1)
            }
            AppButton {
                flat: true
                flatInk: Api.fg
                visible: window.current === window.navTimer
                text: todayScreen.heading
                font.weight: Font.DemiBold
                font.capitalization: Font.MixedCase
                Layout.fillWidth: true
                focusPolicy: window.tapFocus
                Accessible.name: qsTr("Pick a date, now %1").arg(todayScreen.date)
                Accessible.role: Accessible.Button
                onClicked: todayScreen.pickDate()
            }
            AppIconButton {
                visible: window.current === window.navTimer
                text: "›"
                focusPolicy: window.tapFocus
                name: qsTr("Next day")
                onClicked: todayScreen.step(1)
            }
            // every other screen: its title (no back arrow: the bottom bar and the Back key lead away)
            Label {
                visible: window.current !== window.navTimer
                text: window.titles[window.current] || ""
                font.pixelSize: 16
                font.weight: Font.DemiBold
                color: Api.fg
                elide: Text.ElideRight
                verticalAlignment: Text.AlignVCenter
                leftPadding: 12
                rightPadding: 12
                Layout.fillWidth: true
                Layout.preferredHeight: prevDay.implicitHeight   // the header is as tall as on the Timer
            }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Api.line }
    }

    // The bottom bar: Timer · Day · Week · Pomodoro · More. On a wide window it stays at the bottom, its
    // five buttons centred and no wider than 560 px.
    footer: Rectangle {
        id: footerBar
        color: Api.card
        visible: !window.keyboardUp
        implicitHeight: window.keyboardUp ? 0 : navRow.implicitHeight + window.safe.bottom
        readonly property real room: width - window.safe.left - window.safe.right

        Rectangle { width: parent.width; height: 1; color: Api.line }
        RowLayout {
            id: navRow
            anchors.top: parent.top
            width: Math.min(footerBar.room, 560)
            x: window.safe.left + (footerBar.room - width) / 2
            spacing: 0
            NavButton {
                text: window.titles[window.navTimer]
                iconName: window.icons[window.navTimer]
                active: window.current === window.navTimer
                onClicked: {
                    todayScreen.show("")   // a second tap comes back from another day
                    window.current = window.navTimer
                }
            }
            NavButton {
                text: window.titles[window.navDay]
                iconName: window.icons[window.navDay]
                active: window.current === window.navDay
                onClicked: {
                    if (window.current === window.navDay)
                        plannerScreen.show("")   // a second tap comes back to today
                    window.current = window.navDay
                }
            }
            NavButton {
                text: window.titles[window.navWeek]
                iconName: window.icons[window.navWeek]
                active: window.current === window.navWeek
                onClicked: window.current = window.navWeek
            }
            NavButton {
                text: window.titles[window.navPomodoro]
                iconName: window.icons[window.navPomodoro]
                active: window.current === window.navPomodoro
                onClicked: window.current = window.navPomodoro
            }
            // More: the screens without a button of their own. Selected while one of them shows; a tap
            // opens the menu (again, on such a screen), a tap while it is open only closes it.
            NavButton {
                id: moreButton
                text: qsTr("More")
                iconName: "more"
                iconStroke: 3
                active: window.inMore
                held: moreMenu.visible
                focusPolicy: window.tapFocus
                Accessible.name: qsTr("More screens")
                Accessible.role: Accessible.ButtonMenu
                // the press that lands on the button while the menu is open closes the menu (a press
                // outside it); the click that follows must not open it again
                property bool wasOpen: false
                onPressed: wasOpen = moreMenu.visible || justClosed.running
                onClicked: {
                    if (!wasOpen)
                        moreMenu.open()
                }
                Timer { id: justClosed; interval: 300 }
                Menu {
                    id: moreMenu
                    // rises above the button, its right edge on the button's (the bar's) right edge
                    x: moreButton.width - width
                    y: -height - 4
                    onAboutToHide: justClosed.restart()
                    // an opaque themed panel (the default one let the page show through) and rows of one height
                    background: Rectangle {
                        implicitWidth: 240
                        color: Api.card
                        border.color: Api.line
                        radius: 6
                    }
                    MoreItem { text: window.titles[window.navReports]; iconName: window.icons[window.navReports]; current: window.current === window.navReports; onTriggered: window.current = window.navReports }
                    MoreItem { text: window.titles[window.navExpected]; iconName: window.icons[window.navExpected]; current: window.current === window.navExpected; onTriggered: window.current = window.navExpected }
                    MoreItem { text: window.titles[window.navFind]; iconName: window.icons[window.navFind]; current: window.current === window.navFind; onTriggered: window.current = window.navFind }
                    MenuSeparator {
                        padding: 0
                        topPadding: 4
                        bottomPadding: 4
                        contentItem: Rectangle { implicitHeight: 1; color: Api.line }
                    }
                    MoreItem { text: window.titles[window.navSettings]; iconName: window.icons[window.navSettings]; current: window.current === window.navSettings; onTriggered: window.current = window.navSettings }
                }
            }
        }
    }

    // an entry of the More menu, with its icon; `current` marks the screen that is showing
    component MoreItem: MenuItem {
        id: more
        property string iconName
        property bool current: false
        implicitHeight: 48
        topPadding: 0
        bottomPadding: 0
        leftPadding: 16
        rightPadding: 16
        contentItem: RowLayout {
            spacing: 12
            NavIcon { name: more.iconName; color: more.current ? Api.accent : Api.muted; size: 20 }
            Label {
                text: more.text
                color: more.current ? Api.accent : Api.fg
                font.weight: more.current ? Font.DemiBold : Font.Normal
                Layout.fillWidth: true
            }
        }
    }

    // one of the bottom buttons: an icon and a label under a marker that shows where you are
    component NavButton: AbstractButton {
        id: nav
        property bool active: false
        property bool held: false          // shows the pressed tint (More, while its menu is open)
        property string iconName
        property real iconStroke: 2
        implicitHeight: 56
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        focusPolicy: Qt.platform.os === "android" ? Qt.NoFocus : Qt.StrongFocus
        Accessible.name: text
        Accessible.role: Accessible.PageTab
        contentItem: Item {
            Column {
                anchors.centerIn: parent
                spacing: 2
                NavIcon {
                    name: nav.iconName
                    strokeWidth: nav.iconStroke
                    color: nav.active ? Api.accent : Api.muted
                    anchors.horizontalCenter: parent.horizontalCenter
                }
                Label {
                    text: nav.text
                    color: nav.active ? Api.accent : Api.muted
                    // five columns of 64 dp on a 320 dp screen: "Pomodoro" needs the smaller size
                    // (a column under 72 px is a window under 360 px)
                    font.pixelSize: nav.width < 72 ? 11 : 12
                    font.weight: nav.active ? Font.Bold : Font.Normal
                    elide: Text.ElideRight
                    width: Math.min(implicitWidth, Math.max(0, nav.width - 4))
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
        background: Rectangle {
            color: nav.down || nav.held ? Qt.alpha(Api.accent, 0.14) : nav.hovered ? Qt.alpha(Api.accent, 0.06) : "transparent"
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

    // Actions tapped while the server was out of reach, on every screen until they are sent or discarded
    Rectangle {
        id: queueStrip
        visible: Api.queue.length > 0
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: window.safe.left
        anchors.rightMargin: window.safe.right
        height: visible ? stripRow.implicitHeight + 8 : 0
        color: Api.warnBg
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Api.line }
        RowLayout {
            id: stripRow
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 4
            spacing: 4
            Label {
                text: qsTr("%n action(s) waiting", "", Api.queue.length)
                      + (Api.queueStuck !== "" ? " · " + Api.queueStuck : "")
                color: Api.warnColor
                font.pixelSize: 13
                font.weight: Font.DemiBold
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            AppButton {
                text: qsTr("Retry now")
                flat: true
                focusPolicy: window.tapFocus
                Accessible.name: text
                onClicked: Api.flushQueue()
            }
            AppButton {
                text: qsTr("Discard")
                flat: true
                destructive: true
                focusPolicy: window.tapFocus
                Accessible.name: qsTr("Discard the waiting actions")
                onClicked: discardDialog.open()
            }
        }
    }
    AppDialog {
        id: discardDialog
        parent: Overlay.overlay
        modal: true
        title: qsTr("Discard waiting actions?")
        width: Math.min(parent ? parent.width - 32 : 320, 400)
        standardButtons: Dialog.Yes | Dialog.Cancel
        Material.accent: Api.accent
        contentItem: Label {
            text: qsTr("The %n action(s) that could not be sent yet are thrown away and never reach the server.", "", Api.queue.length)
            wrapMode: Text.Wrap
        }
        onAccepted: Api.dropQueue("")
    }

    // every page sits inside this scope, so a key nobody on a page wants (Back) ends up here
    FocusScope {
        id: keyHost
        anchors.top: queueStrip.bottom
        anchors.bottom: parent.bottom
        anchors.bottomMargin: window.keyboardOverlap
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: window.safe.left
        anchors.rightMargin: window.safe.right
        focus: true
        property bool backHandled: false
        Keys.onBackPressed: event => {
            keyHost.backHandled = window.goBack()
            event.accepted = keyHost.backHandled
        }
        Keys.onReleased: event => {
            if (event.key === Qt.Key_Back && keyHost.backHandled) {
                keyHost.backHandled = false
                event.accepted = true
            }
        }

        StackLayout {
            id: stack
            anchors.fill: parent
            currentIndex: window.current
            // a hidden page's text field keeps the focus and would swallow the next page's shortcuts
            onCurrentIndexChanged: stack.forceActiveFocus()
            TodayPage { id: todayScreen }
            PlannerPage {
                id: plannerScreen
                onAddRequested: {
                    findPage.mode = "add"
                    window.current = window.navFind
                }
                onFindRequested: {
                    findPage.mode = "find"
                    window.current = window.navFind
                }
            }
            WeekPage {
                onAddToCalendar: {
                    findPage.mode = "add"
                    window.current = window.navFind
                }
            }
            PomodoroPage {
                onAttention: {
                    window.current = window.navPomodoro
                    window.alert(0)   // flash the taskbar entry until the window is activated
                }
            }
            ReportsPage {}
            ExpectedPage {}
            FindPage { id: findPage }
            SettingsPage {}
        }
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
            AppButton {
                text: qsTr("Unlock")
                primary: true
                Accessible.name: text
                Layout.alignment: Qt.AlignHCenter
                onClicked: lockScreen.ask()
            }
        }
    }
}
