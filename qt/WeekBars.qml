pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

// One bar per weekday: worked hours filled, expected hours as a dashed line, today outlined.
RowLayout {
    id: root
    property var days: []        // [{date, weekday, worked_h, expected_h}]
    property string today: ""
    property real liveH: 0       // running hours, added to today's bar
    signal dayClicked(string date)

    readonly property real maxH: Math.max(1, ...days.map(d => Math.max(worked(d), d.expected_h)))
    function worked(d) { return d.worked_h + (d.date === today ? liveH : 0) }

    spacing: 4
    Layout.fillWidth: true

    Repeater {
        model: root.days
        delegate: ColumnLayout {
            id: cell
            required property var modelData
            readonly property real w: root.worked(modelData)
            readonly property bool isToday: modelData.date === root.today
            readonly property bool over: modelData.expected_h > 0 && w > modelData.expected_h
            spacing: 3
            Layout.fillWidth: true
            Layout.preferredWidth: 1   // equal columns

            Rectangle {
                id: track
                implicitHeight: 40
                Layout.fillWidth: true
                radius: 4
                color: Api.line2
                clip: true

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: parent.height * cell.w / root.maxH
                    radius: 4
                    color: cell.isToday ? Api.workColor : cell.over ? Api.accent : Api.workColor
                    opacity: cell.isToday ? 1 : 0.85
                    Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                }

                Row {   // expected hours, dashed
                    visible: cell.modelData.expected_h > 0
                    y: parent.height * (1 - cell.modelData.expected_h / root.maxH) - 1
                    spacing: 3
                    Repeater {
                        model: Math.ceil(track.width / 7)
                        Rectangle { width: 4; height: 2; color: Api.faint }
                    }
                }

                Rectangle {   // today's outline, drawn on top
                    anchors.fill: parent
                    visible: cell.isToday
                    color: "transparent"
                    radius: 4
                    border.width: 1.5
                    border.color: Api.fg
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.dayClicked(cell.modelData.date)
                }
            }

            Text {
                text: cell.modelData.weekday.charAt(0)
                color: cell.isToday ? Api.fg : Api.muted
                font.pixelSize: 11
                font.weight: Font.DemiBold
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
            }
        }
    }
}
