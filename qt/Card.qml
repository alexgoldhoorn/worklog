import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// A rounded, raised section with an accent title and optional header actions.
Pane {
    id: card
    property string title
    property alias actions: actionRow.data
    default property alias content: body.data

    Layout.fillWidth: true
    Layout.leftMargin: 12
    Layout.rightMargin: 12
    padding: 16
    background: Rectangle {
        color: Api.card
        border.color: Api.line
        radius: 12
    }

    ColumnLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 8

        RowLayout {
            visible: card.title !== ""
            Layout.fillWidth: true
            Label {
                text: card.title
                font.pixelSize: 16
                font.weight: Font.DemiBold
                color: card.Material.accent
                Layout.fillWidth: true
            }
            RowLayout { id: actionRow }
        }
    }
}
