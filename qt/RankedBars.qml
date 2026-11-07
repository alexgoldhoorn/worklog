pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A ranked list of horizontal bars. Items: [{name, value, text, tip, color, dim}].
ColumnLayout {
    id: root
    property var items: []
    readonly property real maxV: Math.max(1e-9, ...items.map(i => i.value))

    spacing: 2
    Layout.fillWidth: true

    Label {
        visible: root.items.length === 0
        text: qsTr("No data")
        color: Api.muted
        Layout.alignment: Qt.AlignHCenter
    }

    Repeater {
        model: root.items
        delegate: Item {
            id: bar
            required property var modelData
            implicitHeight: 22
            Layout.fillWidth: true

            Text {
                id: name
                width: Math.min(220, bar.width * 0.38)
                height: parent.height
                text: bar.modelData.name
                color: Api.fg
                font.pixelSize: 12
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignRight
                verticalAlignment: Text.AlignVCenter
            }
            Rectangle {
                id: fill
                x: name.width + 8
                anchors.verticalCenter: parent.verticalCenter
                height: 14
                radius: 3
                width: Math.max(2, (bar.width - name.width - 8 - 96) * bar.modelData.value / root.maxV)
                color: bar.modelData.color
                opacity: bar.modelData.dim ? 0.45 : 1
            }
            Text {
                x: fill.x + fill.width + 6
                height: parent.height
                text: bar.modelData.text
                color: Api.muted
                font.pixelSize: 11
                verticalAlignment: Text.AlignVCenter
            }
            MouseArea {
                id: hit
                anchors.fill: parent
                hoverEnabled: true
                ToolTip.visible: containsMouse || pressed
                ToolTip.delay: 0
                ToolTip.text: bar.modelData.tip
            }
        }
    }
}
