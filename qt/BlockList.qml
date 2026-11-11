pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// The blocks of one day with the gaps between them; tapping a row asks to edit it.
ColumnLayout {
    id: root
    property var blocks: []
    property bool loading: false
    property int runningId: -1
    property int liveSec: 0       // elapsed seconds of the running block, ticked by the page
    signal editRequested(var block)
    signal billableToggled(var block, var next)        // € tapped: true -> false -> null -> true
    signal fillGap(string start, string end, bool asBreak)

    // blocks in start order, with a {gap} item wherever nothing covers the time between two blocks
    readonly property var items: {
        const out = []
        let covered = null   // latest end so far, so an overlapping block never fakes a gap
        for (const b of blocks.slice().sort((x, y) => x.start.localeCompare(y.start))) {
            if (covered && covered < b.start)
                out.push({ gap: true, start: covered, end: b.start })
            covered = !b.end ? "24:00" : (!covered || b.end > covered ? b.end : covered)
            out.push(b)
        }
        return out
    }
    function minutes(a, b) {
        const p = a.split(":").map(Number), q = b.split(":").map(Number)
        return q[0] * 60 + q[1] - p[0] * 60 - p[1]
    }

    spacing: 0
    Layout.fillWidth: true

    BusyIndicator {
        visible: root.loading
        running: visible
        Layout.alignment: Qt.AlignHCenter
    }

    ColumnLayout {
        visible: !root.loading && root.blocks.length === 0
        spacing: 2
        Layout.fillWidth: true
        Layout.topMargin: 16
        Layout.bottomMargin: 16
        Label {
            text: qsTr("No blocks yet")
            font.pixelSize: 14
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
        }
        Label {
            text: qsTr("Press Start or + Block")
            font.pixelSize: 12
            opacity: 0.6
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
        }
    }

    Repeater {
        model: root.items
        delegate: ColumnLayout {
            id: row
            required property var modelData
            required property int index
            readonly property bool gap: !!row.modelData.gap
            readonly property bool isBreak: row.modelData.work_type !== "work"
            readonly property bool running: row.modelData.id === root.runningId
            readonly property bool flagged: !!row.modelData.flags
                                            && (row.modelData.flags.overlap || row.modelData.flags.start_gt_end)
            spacing: 0
            Layout.fillWidth: true

            Rectangle {
                visible: row.index > 0 && !row.gap
                implicitHeight: 1
                color: Api.line
                Layout.fillWidth: true
            }

            RowLayout {   // a gap: offer to fill it
                visible: row.gap
                spacing: 8
                Layout.fillWidth: true
                Layout.leftMargin: 26
                implicitHeight: 40
                Label {
                    text: row.gap ? qsTr("gap %1 · %2–%3").arg(Api.fmtHM(root.minutes(row.modelData.start, row.modelData.end) / 60))
                                                          .arg(row.modelData.start).arg(row.modelData.end) : ""
                    color: Api.muted
                    font.pixelSize: 12
                    Layout.fillWidth: true
                }
                Button {
                    text: qsTr("+ work")
                    flat: true
                    font.pixelSize: 12
                    onClicked: root.fillGap(row.modelData.start, row.modelData.end, false)
                }
                Button {
                    text: qsTr("+ break")
                    flat: true
                    font.pixelSize: 12
                    onClicked: root.fillGap(row.modelData.start, row.modelData.end, true)
                }
            }

            ItemDelegate {
                visible: !row.gap
                implicitHeight: 56
                leftPadding: 8
                rightPadding: 8
                Layout.fillWidth: true
                onClicked: root.editRequested(row.modelData)

                background: Rectangle {
                    radius: 8
                    color: row.running ? Qt.alpha(Api.workColor, 0.08) : "transparent"
                }

                contentItem: RowLayout {
                    spacing: 12
                    Rectangle {
                        implicitWidth: 6
                        Layout.fillHeight: true
                        Layout.topMargin: 6
                        Layout.bottomMargin: 6
                        radius: 3
                        color: row.flagged ? Api.errorColor : row.isBreak ? Api.breakColor : Api.workColor
                        opacity: row.modelData.end || row.running ? 1 : 0.6
                    }
                    Label {
                        text: row.modelData.start + "–" + (row.modelData.end || "")
                        font.pixelSize: 14
                        font.features: { "tnum": 1 }
                        Layout.preferredWidth: 96
                    }
                    ColumnLayout {
                        spacing: 0
                        Layout.fillWidth: true
                        RowLayout {
                            spacing: 6
                            Layout.fillWidth: true
                            Rectangle {   // the type as a tag, coloured like the web table
                                radius: 6
                                color: row.isBreak ? Api.breakBg : Api.workBg
                                implicitWidth: typeTag.implicitWidth + 12
                                implicitHeight: typeTag.implicitHeight + 4
                                Label {
                                    id: typeTag
                                    anchors.centerIn: parent
                                    text: row.modelData.type || ""
                                    color: row.isBreak ? Api.breakColor : Api.workColor
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                }
                            }
                            AbstractButton {   // billable: tap to cycle yes / no / unset
                                id: bill
                                visible: !row.isBreak
                                readonly property var value: row.modelData.billable
                                implicitWidth: 40   // touch target of at least 40 x 40 dp
                                implicitHeight: 40
                                Layout.topMargin: -8
                                Layout.bottomMargin: -8
                                hoverEnabled: true
                                Accessible.role: Accessible.Button
                                Accessible.name: qsTr("Billable: %1").arg(bill.value === true ? qsTr("yes")
                                                 : bill.value === false ? qsTr("no") : qsTr("not set"))
                                Accessible.description: qsTr("Tap to cycle yes, no, not set")
                                Accessible.onPressAction: bill.clicked()
                                onClicked: root.billableToggled(row.modelData, value === true ? false : value === false ? null : true)
                                ToolTip.visible: hovered
                                ToolTip.text: qsTr("Billable: tap to cycle")
                                background: Rectangle { radius: 6; color: bill.hovered ? Api.line2 : "transparent" }
                                contentItem: Text {
                                    text: bill.value === true ? "€" : bill.value === false ? "✗" : "–"
                                    color: bill.value === true ? Api.workColor : Api.faint
                                    font.weight: Font.Bold
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignVCenter
                                }
                            }
                            Label {
                                visible: !!row.flagged
                                text: "⚠"
                                color: Api.errorColor
                                ToolTip.visible: flagHover.hovered
                                ToolTip.text: row.modelData.flags && row.modelData.flags.start_gt_end
                                              ? qsTr("Ends before it starts") : qsTr("Overlaps an earlier block · both count in full")
                                HoverHandler { id: flagHover }
                            }
                            Rectangle {
                                visible: row.running
                                radius: 8
                                color: Api.workColor
                                implicitWidth: live.implicitWidth + 12
                                implicitHeight: live.implicitHeight + 4
                                Label {
                                    id: live
                                    anchors.centerIn: parent
                                    text: qsTr("LIVE")
                                    color: Api.workFg
                                    font.pixelSize: 11
                                    font.weight: Font.DemiBold
                                }
                            }
                            Item { Layout.fillWidth: true }
                        }
                        Label {
                            visible: text !== ""
                            text: [row.modelData.project, row.modelData.client].filter(x => !!x).join(" · ")
                                  + (row.modelData.auto_closed ? qsTr("  (auto-closed)") : "")
                            opacity: 0.6
                            font.pixelSize: 12
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                    Label {
                        text: row.running ? Api.fmtHM(root.liveSec / 3600) : (row.modelData.duration || "")
                        font.pixelSize: 14
                        font.features: { "tnum": 1 }
                    }
                    Label {
                        text: "›"
                        font.pixelSize: 18
                        opacity: 0.4
                    }
                }
            }
        }
    }
}
