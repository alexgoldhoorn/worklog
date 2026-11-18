pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A labelled, wrapping row of chips that can each be switched on or off; `selected` holds the
// values (not the labels) that are on. ChipRow is the single-choice variant.
ColumnLayout {
    id: root
    property string label
    property var model: []              // [{ value, label }]
    property var selected: []
    signal toggled(string value)

    spacing: 2
    Layout.fillWidth: true

    Caption {
        visible: root.label !== ""
        text: root.label
    }

    Flow {
        spacing: 6
        Layout.fillWidth: true
        Repeater {
            model: root.model
            delegate: AbstractButton {
                id: chip
                required property var modelData
                readonly property bool on: root.selected.indexOf(chip.modelData.value) >= 0
                text: chip.modelData.label
                hoverEnabled: true
                Accessible.role: Accessible.CheckBox
                Accessible.name: chip.modelData.label
                Accessible.checkable: true
                Accessible.checked: chip.on
                Accessible.onPressAction: chip.clicked()
                implicitHeight: 32
                leftPadding: 12
                rightPadding: 12
                onClicked: root.toggled(chip.modelData.value)

                background: Rectangle {
                    radius: height / 2
                    color: chip.on ? Api.accent : chip.hovered ? Api.line2 : Api.bg
                    border.color: chip.on ? Api.accent : Api.line
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
}
