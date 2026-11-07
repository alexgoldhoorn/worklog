pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Work hours by weekday (rows, Monday first) and hour of day (columns), one hue.
Item {
    id: root
    property var cells: []    // 7 × 24 hours
    property int days: 0

    readonly property var weekdays: [qsTr("Mon"), qsTr("Tue"), qsTr("Wed"), qsTr("Thu"), qsTr("Fri"), qsTr("Sat"), qsTr("Sun")]
    readonly property real maxV: cells.length ? Math.max(0, ...cells.map(r => Math.max(...r))) : 0
    readonly property bool hasHour: maxV > 0
    function used(h) { return cells.some(r => r[h] > 0) }
    readonly property int first: {
        for (let h = 0; h < 24; h++) if (used(h)) return Math.max(0, h - 1)
        return 0
    }
    readonly property int last: {
        for (let h = 23; h >= 0; h--) if (used(h)) return Math.min(23, h + 1)
        return 23
    }
    readonly property int cols: last - first + 1
    readonly property real labelW: 34
    readonly property real headerH: 16
    readonly property real cw: (width - labelW - 4) / cols
    readonly property real ch: 18

    implicitHeight: hasHour ? headerH + 7 * ch + 4 : 40
    Layout.fillWidth: true

    Label {
        anchors.centerIn: parent
        visible: !root.hasHour
        text: qsTr("No data")
        color: Api.muted
    }

    Repeater {   // hour labels
        model: root.hasHour ? root.cols : 0
        delegate: Text {
            required property int index
            readonly property int hour: root.first + index
            visible: root.cols <= 14 || hour % 2 === 0
            x: root.labelW + index * root.cw + root.cw / 2 - width / 2
            y: 0
            text: hour
            color: Api.muted
            font.pixelSize: 10
        }
    }

    Repeater {   // one row per weekday
        model: root.hasHour ? 7 : 0
        delegate: Item {
            id: dayRow
            required property int index
            y: root.headerH + index * root.ch
            width: root.width
            height: root.ch

            Text {
                width: root.labelW - 6
                height: parent.height
                text: root.weekdays[dayRow.index]
                color: Api.muted
                font.pixelSize: 10
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
            }

            Repeater {
                model: root.cols
                delegate: Rectangle {
                    id: cell
                    required property int index
                    readonly property int hour: root.first + index
                    readonly property real v: root.cells[dayRow.index][hour]
                    x: root.labelW + index * root.cw + 1
                    y: 1
                    width: root.cw - 2
                    height: root.ch - 2
                    radius: 3
                    color: v > 0 ? Qt.alpha(Api.accent, 0.12 + 0.88 * v / root.maxV) : Api.line2

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        ToolTip.visible: containsMouse || pressed
                        ToolTip.delay: 0
                        ToolTip.text: root.weekdays[dayRow.index] + " " + Api.pad(cell.hour) + ":00–" + Api.pad(cell.hour + 1) + ":00\n"
                                      + qsTr("%1 over %2 days").arg(Api.fmtH(cell.v)).arg(root.days)
                                      + (root.days ? " · " + qsTr("%1 min/day avg").arg(Math.round(cell.v / root.days * 60)) : "")
                    }
                }
            }
        }
    }
}
