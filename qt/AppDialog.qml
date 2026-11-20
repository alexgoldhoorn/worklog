import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material

// A Dialog with an opaque panel in the palette's card colour (the style's own panel is drawn through an
// elevation effect that left the page showing through on some renderers), kept inside the room that is
// really there: below the top safe-area inset (the status bar) and above the on-screen keyboard.
// It is centred in that room and never taller than it; put long content in a ScrollBody so it scrolls.
Dialog {
    id: dlg
    parent: Overlay.overlay

    // What is free, in the overlay's coordinates: { y, height }. Pure.
    //  parentH   the overlay's height        topInset / bottomInset   the system bars (safe area)
    //  kbTop     where the keyboard starts in the overlay, or -1 / >= parentH when there is none
    //  margin    the gap to keep to the edges        minH   never smaller than this
    function area(parentH, topInset, bottomInset, kbTop, margin, minH) {
        const top = topInset + margin
        const bottom = (kbTop > 0 && kbTop < parentH) ? kbTop - margin : parentH - bottomInset - margin
        return { y: top, height: Math.max(minH, bottom - top) }
    }

    // the keyboard's top edge in the overlay's coordinates (Qt reports it in screen coordinates), -1 when it is down
    // qmllint disable missing-property
    readonly property real keyboardTop: {
        if (!Qt.inputMethod.visible || !parent || Qt.inputMethod.keyboardRectangle.height <= 0)
            return -1
        return parent.mapFromGlobal(0, Qt.inputMethod.keyboardRectangle.y).y
    }
    // qmllint enable missing-property
    readonly property var safe: parent ? parent.SafeArea.margins : null
    readonly property var room: parent ? area(parent.height, safe ? safe.top : 0, safe ? safe.bottom : 0, keyboardTop, 8, 160)
                                       : ({ y: 0, height: 400 })
    // dialogs may set a smaller width or height of their own; the room is the ceiling
    readonly property real maxHeight: room.height
    height: Math.min(implicitHeight, maxHeight)
    x: parent ? Math.round((parent.width - width) / 2) : 0
    y: Math.round(room.y + Math.max(0, (room.height - height) / 2))

    background: Rectangle {
        color: Api.card
        radius: 12
        border.color: Api.line
    }
}
