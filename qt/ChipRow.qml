pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A labelled, single-line, horizontally scrolling row of single-choice chips.
ColumnLayout {
    id: root
    property string label
    property var model: []
    property string current: ""
    signal picked(string value)

    spacing: 2
    Layout.fillWidth: true

    Caption {
        visible: root.label !== ""
        text: root.label
    }

    ListView {
        orientation: ListView.Horizontal
        spacing: 6
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.model
        Layout.fillWidth: true
        implicitHeight: 34
        // on a touch screen the bar would sit on top of the chips; the cut-off last chip shows it scrolls
        ScrollBar.horizontal: ScrollBar { policy: Qt.platform.os === "android" ? ScrollBar.AlwaysOff : ScrollBar.AsNeeded }

        delegate: AbstractButton {
            id: chip
            required property string modelData
            readonly property bool on: chip.modelData === root.current
            text: chip.modelData
            hoverEnabled: true
            Accessible.role: Accessible.Button
            Accessible.name: chip.modelData
            Accessible.checkable: true
            Accessible.checked: chip.on
            Accessible.onPressAction: chip.clicked()
            implicitHeight: 32
            leftPadding: 12
            rightPadding: 12
            onClicked: root.picked(chip.modelData)

            background: Rectangle {
                radius: height / 2
                color: chip.on ? Api.accent : chip.hovered ? Api.line2 : Api.bg
                border.color: chip.on ? Api.accent : Api.line
                Behavior on color { ColorAnimation { duration: 120 } }
            }
            contentItem: Text {
                text: chip.text
                color: chip.on ? Api.accentFg : Api.fg
                font.pixelSize: 13
                font.weight: chip.on ? Font.DemiBold : Font.Normal
                verticalAlignment: Text.AlignVCenter
            }
        }
    }
}
