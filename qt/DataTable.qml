pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A compact table that scrolls sideways when it is wider than the card.
// columns: [{title, w, num}]; rows / footer: {cells: [text | {t, c, b}], tint}.
Flickable {
    id: table
    property var columns: []
    property var rows: []
    property var footer: null

    readonly property real totalW: columns.reduce((a, c) => a + c.w, 0)
    // extra room goes to the first column
    function colW(i) { return columns[i].w + (i === 0 ? Math.max(0, width - totalW) : 0) }
    function cellText(c) { return typeof c === "object" && c !== null ? c.t : c }

    implicitHeight: body.implicitHeight
    contentWidth: Math.max(width, totalW)
    contentHeight: body.implicitHeight
    flickableDirection: Flickable.HorizontalFlick
    boundsBehavior: Flickable.StopAtBounds
    clip: true
    Layout.fillWidth: true
    ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

    component Cells: Row {
        id: cells
        property var row: ({ cells: [] })
        property bool head: false
        Repeater {
            model: cells.row.cells
            delegate: Text {
                required property var modelData
                required property int index
                width: table.colW(index)
                height: 30
                leftPadding: 6
                rightPadding: 6
                text: table.cellText(modelData)
                color: cells.head ? Api.muted
                     : typeof modelData === "object" && modelData !== null && modelData.c ? modelData.c : Api.fg
                font.pixelSize: cells.head ? 11 : 13
                font.weight: cells.head || (typeof modelData === "object" && modelData !== null && modelData.b)
                             ? Font.DemiBold : Font.Normal
                font.capitalization: cells.head ? Font.AllUppercase : Font.MixedCase
                font.features: { "tnum": 1 }
                horizontalAlignment: table.columns[index] && table.columns[index].num ? Text.AlignRight : Text.AlignLeft
                verticalAlignment: Text.AlignVCenter
                elide: Text.ElideRight
            }
        }
    }

    Column {
        id: body
        width: table.contentWidth

        Cells { head: true; row: ({ cells: table.columns.map(c => c.title) }) }
        Rectangle { width: parent.width; height: 1; color: Api.line }

        Repeater {
            model: table.rows
            delegate: Rectangle {
                id: rowBg
                required property var modelData
                width: body.width
                height: 30
                color: modelData.tint || "transparent"
                Cells { row: rowBg.modelData }
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Api.line2 }
            }
        }

        Rectangle { visible: !!table.footer; width: parent.width; height: 1; color: Api.line }
        Cells { visible: !!table.footer; row: table.footer || ({ cells: [] }) }
    }
}
