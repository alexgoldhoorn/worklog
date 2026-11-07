import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A compact bordered stat card: an uppercase caption with an optional right-hand badge, then content.
Pane {
    id: tile
    property string caption
    property alias badge: badgeRow.data
    default property alias content: body.data

    padding: 12
    background: Rectangle {
        color: Api.card
        border.color: Api.line
        radius: 12
    }

    ColumnLayout {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 4

        RowLayout {
            Layout.fillWidth: true
            Caption {
                text: tile.caption
                font.weight: Font.DemiBold
                Layout.fillWidth: true
            }
            RowLayout { id: badgeRow }
        }
    }
}
