import QtQuick
import QtQuick.Controls

// A text field that completes what is typed from a list and offers the list as a drop-down (an editable
// ComboBox). Any text is allowed, the list only helps. `text` is what the field says.
ComboBox {
    id: field

    property var suggestions: []
    property alias text: field.editText
    // Return or Enter in the field; not the one that picks a row of the open list
    signal enterPressed()

    property string shownList: "[]"   // the list the model holds, to tell a real change from a new array

    // the names once each, without empty ones, in the order given
    function unique(list) {
        const seen = {}, out = []
        for (const v of list || []) {
            const s = String(v === undefined || v === null ? "" : v).trim()
            if (s !== "" && !seen[s.toLowerCase()]) {
                seen[s.toLowerCase()] = true
                out.push(s)
            }
        }
        return out
    }

    // A new model puts its first row in the field: the text typed or set before stays instead
    function sync() {
        const list = unique(suggestions), key = JSON.stringify(list)
        if (key === shownList)
            return
        const keep = editText
        shownList = key
        model = list
        currentIndex = find(keep, Qt.MatchFixedString)
        editText = keep
    }

    editable: true
    model: []
    onSuggestionsChanged: sync()
    Component.onCompleted: sync()
    // Return reaches here from the text (which ignores it) and when the box itself has the focus; the
    // ComboBox would keep the key, so nothing behind it ever saw it. With the list open it picks a row.
    function returnKey(event) {
        if (popup.visible)
            event.accepted = false
        else
            field.enterPressed()
    }
    Keys.onReturnPressed: event => field.returnKey(event)
    Keys.onEnterPressed: event => field.returnKey(event)
}
