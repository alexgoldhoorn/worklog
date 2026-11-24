import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material

// The one icon-only button: a single glyph, always with an accessible name (and the same text as a tooltip).
// The glyph set is fixed: ‹ › step, ⋮ more, ✓ approve, ✗ reject, × delete, ✎ edit, ↺ reset, ↓ ↑ stretch a block over a gap. 40 x 40 dp at least.
// Set `name` (what a screen reader says); `text` is the glyph.
ToolButton {
    id: btn
    property string name: ""
    property color ink: Api.fg
    property bool tipSuppressed: false   // a menu opened from this button covers the tooltip
    hoverEnabled: true
    implicitWidth: 40
    implicitHeight: 40
    padding: 0
    font.pixelSize: 22
    font.capitalization: Font.MixedCase
    Accessible.name: btn.name
    Accessible.role: Accessible.Button
    ToolTip.visible: hovered && btn.name !== "" && !btn.tipSuppressed
    ToolTip.text: btn.name

    contentItem: Label {
        text: btn.text
        font: btn.font
        color: btn.enabled ? btn.ink : Api.muted
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
