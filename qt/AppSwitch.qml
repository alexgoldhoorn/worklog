import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// A Switch for a card: it takes the card's width and wraps its text onto more lines. The plain Switch
// is as wide as its text on one line, which ran off a 320 dp screen.
Switch {
    id: sw
    Layout.fillWidth: true
    contentItem: Label {
        text: sw.text
        font: sw.font
        wrapMode: Text.Wrap
        verticalAlignment: Text.AlignVCenter
        leftPadding: sw.indicator ? sw.indicator.width + sw.spacing : 0
        opacity: sw.enabled ? 1 : 0.5
    }
}
