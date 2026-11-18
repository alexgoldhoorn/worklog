import QtQuick
import QtQuick.Controls

// Captures a global shortcut: focus it and press the combination. Shows it and emits captured(seq)
// (portable text such as "Ctrl+Alt+W"). Only combinations GlobalHotkey can register are taken.
TextField {
    id: field

    property string sequence: ""
    signal captured(string seq)

    // "Ctrl+Alt+W" for a key press, "" while only modifiers are down or the key is not usable
    function sequenceFor(key, modifiers) {
        let name = ""
        if (key >= Qt.Key_A && key <= Qt.Key_Z)
            name = String.fromCharCode(key)
        else if (key >= Qt.Key_0 && key <= Qt.Key_9)
            name = String.fromCharCode(key)
        else if (key >= Qt.Key_F1 && key <= Qt.Key_F24)
            name = "F" + (key - Qt.Key_F1 + 1)
        else if (key === Qt.Key_Space)
            name = "Space"
        else
            return ""
        let out = ""
        if (modifiers & Qt.ControlModifier) out += "Ctrl+"
        if (modifiers & Qt.AltModifier) out += "Alt+"
        if (modifiers & Qt.ShiftModifier) out += "Shift+"
        if (modifiers & Qt.MetaModifier) out += "Meta+"
        return out + name
    }
    // the shortcut must carry a modifier (GlobalHotkey refuses a bare key)
    function usable(seq) { return /^(Ctrl\+|Alt\+|Shift\+|Meta\+)+[^+]+$/.test(seq) }

    property string hint: ""
    readOnly: true
    text: activeFocus ? (hint !== "" ? hint : qsTr("Press the shortcut…")) : field.sequence
    placeholderText: qsTr("Click, then press a shortcut")
    Accessible.name: qsTr("Global hotkey")
    Accessible.role: Accessible.EditableText
    Accessible.description: field.sequence

    Keys.onPressed: event => {
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab)
            return   // keep keyboard navigation working
        event.accepted = true
        if (event.key === Qt.Key_Escape) {
            field.focus = false
            return
        }
        const seq = field.sequenceFor(event.key, event.modifiers)
        if (seq === "")
            return   // a modifier on its own: wait for the key
        if (!field.usable(seq)) {
            field.hint = qsTr("Add Ctrl, Alt or Shift")
            return
        }
        field.hint = ""
        field.captured(seq)
        field.focus = false
    }
    onActiveFocusChanged: {
        if (activeFocus)
            hint = ""
        Api.hotkeyCapturing = activeFocus   // the registered hotkey would swallow the very keys being captured
    }
    Component.onDestruction: Api.hotkeyCapturing = false
}
