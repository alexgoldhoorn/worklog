import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A compact bordered stat card: an uppercase caption with an optional right-hand badge, then content.
Pane {
    id: tile
    property string caption
    property string help: ""   // what the figure means: a "?" next to the caption shows it (hover or tap)
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
            Rectangle {
                id: helpDot
                property bool tapped: false
                visible: tile.help !== ""
                implicitWidth: 20
                implicitHeight: 20
                radius: 10
                color: "transparent"
                border.color: Api.line
                Accessible.role: Accessible.Button
                Accessible.name: tile.help
                Label {
                    anchors.centerIn: parent
                    text: "?"
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                    color: Api.muted
                }
                HoverHandler { id: helpHover }
                TapHandler {
                    margin: 10   // a 40 dp touch target around the 20 dp dot
                    onTapped: helpDot.tapped = !helpDot.tapped
                }
                ToolTip {
                    id: helpTip
                    text: tile.help
                    visible: helpDot.visible && (helpHover.hovered || helpDot.tapped)
                    width: Math.min(implicitWidth, 280)
                    margins: 8
                    timeout: 20000
                    onClosed: helpDot.tapped = false
                }
            }
            RowLayout { id: badgeRow }
        }
    }
}
