import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// A short message at the bottom of the window, with an optional action (Undo by default).
Popup {
    id: bar
    property var undoFn: null
    property string actionText: qsTr("Undo")

    function show(message, action, label) {
        text.text = message
        undoFn = action || null
        actionText = label || qsTr("Undo")
        open()
        hideTimer.interval = action ? 8000 : 4000
        hideTimer.restart()
    }

    parent: Overlay.overlay
    x: (parent.width - width) / 2
    y: parent.height - height - 24
    width: Math.min(420, parent.width - 32)
    padding: 12
    leftPadding: 16
    closePolicy: Popup.NoAutoClose
    Material.theme: Material.Dark
    Material.elevation: 6
    Material.roundedScale: Material.SmallScale

    Timer { id: hideTimer; interval: 4000; onTriggered: bar.close() }

    contentItem: RowLayout {
        spacing: 8
        Label {
            id: text
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
        Button {
            visible: bar.undoFn !== null
            text: bar.actionText
            flat: true
            Material.foreground: Material.color(Material.Green, Material.Shade300)
            onClicked: {
                bar.close()
                bar.undoFn()
            }
        }
    }
}
