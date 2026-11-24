pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Browse and edit the blocks of any day, and add calendar proposals.
ScrollView {
    id: page
    property string date: Api.today()
    property var day: null
    readonly property var chips: Api.status ? Api.status.chips.types.concat(Api.status.chips.break_types) : []
    property string error: ""
    readonly property bool isToday: date === Api.today()

    property bool showArrows: true   // off inside the Today screen: its header steps the day
    property bool navEnabled: true   // off while the Today screen's own calendar is open

    property alias dialog: blockDialog   // for tests
    property alias picker: datePicker

    contentWidth: availableWidth

    function reload() {
        Api.request("GET", "/api/day/" + date, undefined, function (d) {
            if (d.date !== page?.date)
                return  // a slower answer for a day we already left
            page.day = d
            page.error = ""
        }, e => { if (page) page.error = e })
    }

    onDateChanged: {
        day = null
        reload()
    }
    Component.onCompleted: if (visible) reload()
    onVisibleChanged: if (visible) reload()
    // ← / → step a day, as on the web (a focused text field keeps its arrow keys)
    // not while a dialog or the calendar is open
    readonly property bool shortcutsOn: visible && navEnabled && !blockDialog.visible && !datePicker.visible
                                        && Api.keyShortcuts && Api.focusFree(Window.window ? Window.window.activeFocusItem : null)
    Shortcut { sequence: "Left"; enabled: page.shortcutsOn; onActivated: page.date = Api.addDays(page.date, -1) }
    Shortcut { sequence: "Right"; enabled: page.shortcutsOn; onActivated: page.date = Api.addDays(page.date, 1) }
    Connections {
        target: Api
        // a hidden page reloads when its tab is shown
        function onChanged() { if (page.visible) page.reload() }
        function onServerChanged() { if (page.visible) page.reload() }
    }

    component Stat: ColumnLayout {
        property string caption
        property string value
        spacing: 0
        Layout.fillWidth: true
        Label {
            text: parent.value
            font.pixelSize: 22
            font.bold: true
            font.features: { "tnum": 1 }
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
        }
        Caption {
            text: parent.caption
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
        }
    }

    ColumnLayout {
        width: page.availableWidth
        spacing: 16

        // ---- date hero --------------------------------------------------------
        Pane {
            Layout.fillWidth: true
            Layout.topMargin: 12
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            padding: 12
            Material.background: Qt.alpha(Material.accent, 0.15)
            Material.elevation: 0
            Material.roundedScale: Material.LargeScale

            ColumnLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 8

                RowLayout {
                    Layout.fillWidth: true
                    AppIconButton {
                        visible: page.showArrows
                        text: "‹"
                        name: qsTr("Previous day")
                        onClicked: page.date = Api.addDays(page.date, -1)
                    }
                    ColumnLayout {   // tap the date to pick any day
                        id: dateHeader
                        spacing: 0
                        Layout.fillWidth: true
                        Accessible.role: Accessible.Button
                        Accessible.name: qsTr("Pick a date, now %1").arg(page.date)
                        Accessible.onPressAction: datePicker.openFor(page.date)
                        TapHandler { onTapped: datePicker.openFor(page.date) }
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        Label {
                            text: Api.parseDate(page.date).toLocaleDateString(Api.locale, "dddd")
                            font.pixelSize: 12
                            opacity: 0.7
                            horizontalAlignment: Text.AlignHCenter
                            Layout.fillWidth: true
                        }
                        Label {
                            text: Api.parseDate(page.date).toLocaleDateString(Api.locale, "d MMMM yyyy")
                            font.pixelSize: 20
                            font.bold: true
                            horizontalAlignment: Text.AlignHCenter
                            Layout.fillWidth: true
                        }
                    }
                    AppIconButton {
                        visible: page.showArrows
                        text: "›"
                        name: qsTr("Next day")
                        onClicked: page.date = Api.addDays(page.date, 1)
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Stat { caption: qsTr("Work"); value: page.day ? Api.fmtHM(page.day.totals.work_h) : "–" }
                    Stat { caption: qsTr("Breaks"); value: page.day ? Api.fmtHM(page.day.totals.other_h) : "–" }
                    Stat { caption: qsTr("Billable"); value: page.day ? Api.fmtHM(page.day.totals.billable_h) : "–" }
                }

                AppButton {
                    visible: !page.isToday
                    text: qsTr("Today")
                    flat: true
                    Layout.alignment: Qt.AlignHCenter
                    onClicked: page.date = Api.today()
                }
            }
        }

        // ---- notices ----------------------------------------------------------
        NoticeBanner {
            visible: page.error !== ""
            text: qsTr("Error: %1").arg(page.error)
            level: "error"
        }
        Repeater {
            model: page.day ? page.day.notices.concat(Api.overlapItems(page.day).map(o => o.text)) : []
            delegate: NoticeBanner {
                required property string modelData
                text: modelData
                level: "warn"
            }
        }

        // ---- blocks -----------------------------------------------------------
        Card {
            title: qsTr("Blocks")
            actions: AppRoundButton {
                text: "+"
                font.pixelSize: 20
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Add block")
                Accessible.name: qsTr("Add block")
                Accessible.role: Accessible.Button
                onClicked: blockDialog.newBlock(page.date)
            }

            BlockList {
                loading: !page.day && !page.error
                blocks: page.day ? page.day.blocks : []
                onEditRequested: b => blockDialog.editBlock(b)
                onBillableToggled: (b, next) => Api.request("PUT", "/api/blocks/" + b.id, { billable: next }, null, e => page.error = e)
                onStretchRequested: (b, fields) => Api.request("PUT", "/api/blocks/" + b.id, fields, null, e => page.error = e)
                onFillGap: (start, end, asBreak) => {
                    const body = { date: page.date, start: start, end: end }
                    if (asBreak && Api.defaultBreak())
                        body.type = Api.defaultBreak()
                    Api.request("POST", "/api/blocks", body, null, e => page.error = e)
                }
            }
        }

        // ---- calendar proposals -----------------------------------------------
        ProposalCard {
            date: page.date
            showAll: true
            meetings: page.day ? page.day.meetings || page.day.proposals : []
            onFailed: e => page.error = e
        }
        Item { implicitHeight: 8 }
    }

    BlockDialog {
        id: blockDialog
        parent: Overlay.overlay
        typeSuggestions: page.chips
        blocks: page.day ? page.day.blocks : []
        onOffer: (text, action) => snackbar.show(text, action, qsTr("Move it too"))
        onDeleted: (text, undo) => snackbar.show(text, undo)
        onTrimmed: (text, undo) => snackbar.show(text, undo)
    }

    DatePicker {
        id: datePicker
        date: page.date
        onPicked: iso => page.date = iso
    }

    Snackbar { id: snackbar }
}
