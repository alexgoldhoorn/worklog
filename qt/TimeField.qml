import QtQuick
import QtQuick.Controls

// The one time entry field: "700", "7.30", "7:30", "19h00" are all accepted and become "HH:MM" when the field is left
// (Api.normTime, the same rule as the web's wl.normTime). Whether the result is a time is the page's call.
TextField {
    id: field

    // the normalised text, after the user left the field
    signal timeEntered(string value)

    placeholderText: qsTr("HH:MM")
    validator: RegularExpressionValidator { regularExpression: /^[\d:.hH]{0,5}$/ }
    inputMethodHints: Qt.ImhPreferNumbers
    selectByMouse: true
    onActiveFocusChanged: if (activeFocus) selectAll()
    onEditingFinished: {
        const n = Api.normTime(text)
        if (n !== text)
            text = n
        field.timeEntered(n)
    }
}
