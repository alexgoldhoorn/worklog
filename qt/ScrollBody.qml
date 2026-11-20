import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The scrolling body of a dialog: put the content in it like in a ColumnLayout. It is as tall as its content
// until the dialog is capped (AppDialog caps it to the room above the keyboard), then it scrolls, and a field
// that gets the focus is scrolled into view, so the fields and the buttons stay reachable.
Flickable {
    id: body
    default property alias content: col.data
    property alias spacing: col.spacing

    clip: true
    boundsBehavior: Flickable.StopAtBounds
    implicitWidth: col.implicitWidth
    implicitHeight: col.implicitHeight
    contentWidth: width
    contentHeight: col.implicitHeight
    ScrollBar.vertical: ScrollBar { policy: body.contentHeight > body.height + 1 ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }

    // the new contentY that shows [top, top + h) of the content inside a view `viewH` high; pure
    function contentYFor(contentY, top, h, viewH, maxY) {
        if (top < contentY)
            return Math.max(0, top - 8)
        if (top + h > contentY + viewH)
            return Math.min(Math.max(0, maxY), top + h - viewH + 8)
        return contentY
    }
    function reveal(item) {
        if (!item || !col.contains(col.mapFromItem(item, 0, 0)))
            return
        const y = item.mapToItem(col, 0, 0).y
        contentY = contentYFor(contentY, y, item.height, height, contentHeight - height)
    }
    // the focused field comes into view, and again when the keyboard has taken part of the room
    Connections {
        target: body.Window.window
        function onActiveFocusItemChanged() { body.reveal(body.Window.window.activeFocusItem) }
    }
    onHeightChanged: if (Window.window) reveal(Window.window.activeFocusItem)

    ColumnLayout {
        id: col
        width: body.width
        spacing: 8
    }
}
