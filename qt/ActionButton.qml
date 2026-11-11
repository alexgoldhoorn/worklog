import QtQuick
import QtQuick.Controls

// A big coloured hero button with a small second line ("Pause" / "eat"). Disabled it turns neutral grey
// rather than see-through, so its label stays readable.
AbstractButton {
    id: btn
    property string subtext
    property color fill
    property color ink

    implicitHeight: 52
    hoverEnabled: true
    Accessible.role: Accessible.Button
    Accessible.name: btn.subtext !== "" ? btn.text + ", " + btn.subtext : btn.text
    Accessible.onPressAction: btn.clicked()
    readonly property color inkNow: enabled ? ink : Api.muted

    background: Rectangle {
        radius: 10
        color: !btn.enabled ? Api.line2
             : btn.pressed ? Qt.darker(btn.fill, 1.15) : btn.hovered ? Qt.lighter(btn.fill, 1.06) : btn.fill
        Behavior on color { ColorAnimation { duration: 120 } }
    }

    contentItem: Column {
        spacing: 0
        topPadding: 6
        Text {
            text: btn.text
            color: btn.inkNow
            font.pixelSize: 15
            font.weight: Font.DemiBold
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
        }
        Text {
            text: btn.subtext
            color: btn.inkNow
            opacity: 0.75
            font.pixelSize: 11
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }
    }
}
