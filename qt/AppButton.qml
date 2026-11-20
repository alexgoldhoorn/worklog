import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material

// The one text button. Three weights, the same on every screen:
//   primary      the main action of a view or dialog: filled with the accent, the label in the colour made for
//                that fill (Api.accentFg) in both themes. Material's own highlighted button takes its label
//                colour from the style's theme, which left white-on-light text when the two disagreed.
//   (default)    a quiet tonal button (a neutral fill, the normal text colour)
//   flat         a text action with no fill (Cancel, Today, Pick, Dismiss ...), its label in flatInk
// destructive paints the label (or, highlighted, the fill) in the error colour (Delete).
// 40 dp high, so every button is a touch target.
Button {
    id: btn
    property bool primary: false   // not Button.highlighted: a DialogButtonBox resets that on its buttons
    property bool destructive: false
    property color flatInk: Api.accent
    hoverEnabled: true
    implicitHeight: 40
    leftPadding: 16
    rightPadding: 16
    font.capitalization: Font.MixedCase

    readonly property color fillBase: destructive ? Api.errorColor : Api.accent

    background: Rectangle {
        implicitWidth: 64
        radius: 8
        // highlighted wins over flat: a DialogButtonBox makes its buttons flat, which left Save as bare text
        color: !btn.enabled ? (btn.flat && !btn.primary ? "transparent" : Api.line2)
             : btn.primary ? (btn.down ? Qt.darker(btn.fillBase, 1.15) : btn.hovered ? Qt.lighter(btn.fillBase, 1.06) : btn.fillBase)
             : btn.flat ? (btn.down ? Api.line : btn.hovered ? Api.line2 : "transparent")
             : btn.down ? (Api.dark ? Qt.lighter(Api.line, 1.25) : Api.line)
             : btn.hovered ? (Api.dark ? Qt.lighter(Api.line, 1.12) : Qt.darker(Api.line2, 1.04))
             : (Api.dark ? Api.line : Api.line2)
        border.color: btn.activeFocus && !btn.primary ? Api.accent : "transparent"
        Behavior on color { ColorAnimation { duration: 100 } }
    }
    contentItem: Label {
        text: btn.text
        font: btn.font
        color: !btn.enabled ? Api.muted
             : btn.primary ? Api.accentFg
             : btn.destructive ? Api.errorColor
             : btn.flat ? btn.flatInk : Api.fg
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        elide: Text.ElideRight
    }
}
