pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// A month calendar popup (Monday first, ISO week numbers). openFor(iso) shows that day's month;
// picked(iso) fires when a day is chosen and the popup closes. Keys: arrows move, PageUp/PageDown
// change month, Enter picks, Esc closes.
Popup {
    id: picker
    property string date: ""            // selected ISO date, "" = none
    signal picked(string iso)

    property string cursor: ""          // the keyboard-focused day
    property int viewYear: 2000
    property int viewMonth: 0           // 0-11
    readonly property string todayIso: Api.today()
    readonly property var weeks: monthGrid(viewYear, viewMonth)

    parent: Overlay.overlay
    modal: true
    focus: true
    anchors.centerIn: Overlay.overlay
    width: Math.min(340, parent ? parent.width - 32 : 340)
    padding: 12
    background: Rectangle { color: Api.card; border.color: Api.line; radius: 12 }

    // ISO week number of an ISO date (the week of its Thursday)
    function isoWeek(iso) {
        const d = Api.parseDate(iso)
        const dow = (d.getDay() + 6) % 7
        const p = Api.addDays(iso, 3 - dow).split("-").map(Number)   // the Thursday
        const days = (Date.UTC(p[0], p[1] - 1, p[2]) - Date.UTC(p[0], 0, 1)) / 86400000
        return Math.floor(days / 7) + 1
    }

    // Weeks of a month (month 0-11) as [{week, days: [{iso, day, inMonth}]}], Monday first,
    // padded with the days of the neighbouring months.
    function monthGrid(year, month) {
        const first = Api.isoDate(new Date(year, month, 1))
        const lead = (new Date(year, month, 1).getDay() + 6) % 7
        let start = Api.addDays(first, -lead)
        const out = []
        for (let w = 0; w < 6; ++w) {
            const days = []
            for (let i = 0; i < 7; ++i) {
                const iso = Api.addDays(start, i)
                const p = iso.split("-").map(Number)
                days.push({ iso: iso, day: p[2], inMonth: p[1] - 1 === month })
            }
            if (w >= 4 && !days[0].inMonth)
                break   // no row that is only next month
            out.push({ week: isoWeek(days[0].iso), days: days })
            start = Api.addDays(start, 7)
        }
        return out
    }

    function show(iso) {
        const p = iso.split("-").map(Number)
        viewYear = p[0]
        viewMonth = p[1] - 1
    }
    function openFor(iso) {
        const d = iso && /^\d{4}-\d\d-\d\d$/.test(iso) ? iso : Api.today()
        cursor = d
        show(d)
        open()
    }
    function moveCursor(days) {
        cursor = Api.addDays(cursor || Api.today(), days)
        show(cursor)
    }
    function stepMonth(n) {
        const d = new Date(viewYear, viewMonth + n, 1)
        viewYear = d.getFullYear()
        viewMonth = d.getMonth()
        // keep the cursor inside the visible month
        const day = Math.min(Api.parseDate(cursor || Api.today()).getDate(), new Date(viewYear, viewMonth + 1, 0).getDate())
        cursor = Api.isoDate(new Date(viewYear, viewMonth, day))
    }
    function pick(iso) {
        picked(iso)
        close()
    }

    onOpened: contentItem.forceActiveFocus()

    contentItem: ColumnLayout {
        spacing: 6
        focus: true
        Keys.onLeftPressed: picker.moveCursor(-1)
        Keys.onRightPressed: picker.moveCursor(1)
        Keys.onUpPressed: picker.moveCursor(-7)
        Keys.onDownPressed: picker.moveCursor(7)
        Keys.onPressed: event => {
            if (event.key === Qt.Key_PageUp) { picker.stepMonth(-1); event.accepted = true }
            else if (event.key === Qt.Key_PageDown) { picker.stepMonth(1); event.accepted = true }
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) { picker.pick(picker.cursor); event.accepted = true }
        }

        RowLayout {
            Layout.fillWidth: true
            ToolButton {
                text: "‹"
                focusPolicy: Qt.NoFocus
                Accessible.name: qsTr("Previous month")
                Accessible.role: Accessible.Button
                onClicked: picker.stepMonth(-1)
            }
            Label {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                font.weight: Font.DemiBold
                text: new Date(picker.viewYear, picker.viewMonth, 1).toLocaleDateString(Api.locale, "MMMM yyyy")
            }
            ToolButton {
                text: "›"
                focusPolicy: Qt.NoFocus
                Accessible.name: qsTr("Next month")
                Accessible.role: Accessible.Button
                onClicked: picker.stepMonth(1)
            }
        }

        // header: week-number column + Monday..Sunday
        RowLayout {
            Layout.fillWidth: true
            spacing: 0
            Label { text: qsTr("Wk"); color: Api.faint; font.pixelSize: 11; horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true; Layout.preferredWidth: 1 }
            Repeater {
                model: 7
                Label {
                    required property int index
                    text: Api.locale.dayName((index + 1) % 7, Locale.ShortFormat).substring(0, 2)   // Qt: 0 = Sunday
                    color: Api.muted
                    font.pixelSize: 11
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                }
            }
        }

        Repeater {
            model: picker.weeks
            RowLayout {
                id: weekRow
                required property var modelData
                Layout.fillWidth: true
                spacing: 0
                Label {
                    text: weekRow.modelData.week
                    color: Api.faint
                    font.pixelSize: 11
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Layout.preferredHeight: 40
                }
                Repeater {
                    model: weekRow.modelData.days
                    Item {
                        id: cell
                        required property var modelData
                        readonly property bool selected: cell.modelData.iso === picker.date
                        readonly property bool isToday: cell.modelData.iso === picker.todayIso
                        readonly property bool isCursor: cell.modelData.iso === picker.cursor
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        Layout.preferredHeight: 40
                        Accessible.role: Accessible.Button
                        Accessible.name: Api.parseDate(cell.modelData.iso).toLocaleDateString(Api.locale, "dddd d MMMM yyyy")
                        Accessible.onPressAction: picker.pick(cell.modelData.iso)

                        Rectangle {
                            anchors.centerIn: parent
                            width: Math.min(parent.width, parent.height) - 2
                            height: width
                            radius: width / 2
                            color: cell.selected ? Api.accent : "transparent"
                            border.width: cell.isToday || (cell.isCursor && picker.contentItem.activeFocus) ? 2 : 0
                            border.color: cell.isToday ? Api.accent : Api.muted
                        }
                        Label {
                            anchors.centerIn: parent
                            text: cell.modelData.day
                            color: cell.selected ? Api.accentFg : cell.modelData.inMonth ? Api.fg : Api.faint
                            font.weight: cell.isToday ? Font.Bold : Font.Normal
                        }
                        TapHandler { onTapped: picker.pick(cell.modelData.iso) }
                    }
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Button {
                text: qsTr("Today")
                flat: true
                focusPolicy: Qt.NoFocus
                onClicked: picker.pick(Api.today())
            }
            Item { Layout.fillWidth: true }
            Button {
                text: qsTr("Close")
                flat: true
                focusPolicy: Qt.NoFocus
                onClicked: picker.close()
            }
        }
    }
}
