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
    property var chips: []
    property string error: ""
    readonly property bool isToday: date === Api.today()

    contentWidth: availableWidth

    function reload() {
        Api.request("GET", "/api/day/" + date, undefined, function (d) {
            if (d.date !== page.date)
                return  // a slower answer for a day we already left
            page.day = d
            page.error = ""
        }, e => page.error = e)
        Api.request("GET", "/api/status", undefined,
                    s => page.chips = s.chips.types.concat(s.chips.break_types), null)
    }

    onDateChanged: {
        day = null
        reload()
    }
    Component.onCompleted: reload()
    onVisibleChanged: if (visible) reload()
    // ← / → step a day, as on the web (a focused text field keeps its arrow keys)
    Shortcut { sequence: "Left"; enabled: page.visible; onActivated: page.date = Api.addDays(page.date, -1) }
    Shortcut { sequence: "Right"; enabled: page.visible; onActivated: page.date = Api.addDays(page.date, 1) }
    Connections {
        target: Api
        function onChanged() { page.reload() }
        function onServerChanged() { page.reload() }
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
                    ToolButton {
                        text: "‹"
                        font.pixelSize: 24
                        implicitWidth: 48
                        onClicked: page.date = Api.addDays(page.date, -1)
                    }
                    ColumnLayout {
                        spacing: 0
                        Layout.fillWidth: true
                        Label {
                            text: Api.parseDate(page.date).toLocaleDateString(Qt.locale(), "dddd")
                            font.pixelSize: 12
                            opacity: 0.7
                            horizontalAlignment: Text.AlignHCenter
                            Layout.fillWidth: true
                        }
                        Label {
                            text: Api.parseDate(page.date).toLocaleDateString(Qt.locale(), "d MMMM yyyy")
                            font.pixelSize: 20
                            font.bold: true
                            horizontalAlignment: Text.AlignHCenter
                            Layout.fillWidth: true
                        }
                    }
                    ToolButton {
                        text: "›"
                        font.pixelSize: 24
                        implicitWidth: 48
                        onClicked: page.date = Api.addDays(page.date, 1)
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Stat { caption: qsTr("Work"); value: page.day ? Api.fmtHM(page.day.totals.work_h) : "–" }
                    Stat { caption: qsTr("Breaks"); value: page.day ? Api.fmtHM(page.day.totals.other_h) : "–" }
                    Stat { caption: qsTr("Billable"); value: page.day ? Api.fmtHM(page.day.totals.billable_h) : "–" }
                }

                Button {
                    visible: !page.isToday
                    text: qsTr("Back to today")
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
            model: page.day ? page.day.notices.concat(page.day.overlaps) : []
            delegate: NoticeBanner {
                required property string modelData
                text: modelData
                level: "warn"
            }
        }

        // ---- blocks -----------------------------------------------------------
        Card {
            title: qsTr("Blocks")
            actions: RoundButton {
                text: "+"
                font.pixelSize: 20
                highlighted: true
                Material.elevation: 1
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Add block")
                onClicked: blockDialog.newBlock(page.date)
            }

            BlockList {
                loading: !page.day && !page.error
                blocks: page.day ? page.day.blocks : []
                onEditRequested: b => blockDialog.editBlock(b)
                onBillableToggled: (b, next) => Api.request("PUT", "/api/blocks/" + b.id, { billable: next }, null, e => page.error = e)
                onFillGap: (start, end, asBreak) => {
                    const body = { date: page.date, start: start, end: end }
                    const t = asBreak ? ("eat") : ""
                    if (t)
                        body.type = t
                    Api.request("POST", "/api/blocks", body, null, e => page.error = e)
                }
            }
        }

        // ---- calendar proposals -----------------------------------------------
        Card {
            visible: !!page.day && page.day.proposals.length > 0
            title: qsTr("Calendar proposals")

            Caption {
                text: qsTr("Meetings without a block")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
            }

            Repeater {
                model: page.day ? page.day.proposals : []
                delegate: ColumnLayout {
                    id: proposal
                    required property var modelData
                    required property int index
                    spacing: 4
                    Layout.fillWidth: true

                    Rectangle {
                        visible: proposal.index > 0
                        implicitHeight: 1
                        color: proposal.Material.dividerColor
                        Layout.fillWidth: true
                    }
                    RowLayout {
                        spacing: 12
                        Layout.fillWidth: true
                        Label {
                            text: proposal.modelData.start + "–" + proposal.modelData.end
                            font.features: { "tnum": 1 }
                            Layout.preferredWidth: 96
                        }
                        Label {
                            text: proposal.modelData.title || qsTr("(no title)")
                            font.weight: Font.DemiBold
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                    RowLayout {
                        Layout.alignment: Qt.AlignRight
                        Button {
                            text: qsTr("Dismiss")
                            flat: true
                            onClicked: Api.request("POST", "/api/calendar/dismiss",
                                                   { date: page.date, start: proposal.modelData.start, title: proposal.modelData.title },
                                                   null, e => page.error = e)
                        }
                        Button {
                            text: qsTr("Add as meeting")
                            highlighted: true
                            onClicked: Api.request("POST", "/api/calendar/add",
                                                   { date: page.date, start: proposal.modelData.start, end: proposal.modelData.end, title: proposal.modelData.title },
                                                   null, e => page.error = e)
                        }
                    }
                }
            }
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
    }

    Snackbar { id: snackbar }
}
