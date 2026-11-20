import QtQuick
import QtQuick.Controls

// The round "+" of a card: an accent disc with its label in Api.accentFg (see AppButton for why).
Button {
    id: btn
    hoverEnabled: true
    implicitWidth: 40
    implicitHeight: 40
    padding: 0

    background: Rectangle {
        radius: width / 2
        color: !btn.enabled ? Api.line2 : btn.down ? Qt.darker(Api.accent, 1.15) : btn.hovered ? Qt.lighter(Api.accent, 1.06) : Api.accent
    }
    contentItem: Label {
        text: btn.text
        font: btn.font
        color: btn.enabled ? Api.accentFg : Api.muted
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
