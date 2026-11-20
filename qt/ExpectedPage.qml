pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Expected hours per day (the web's Days page): defaults greyed, overrides marked and resettable.
ScrollView {
    id: page
    property string month: Api.today().slice(0, 7)   // "2026-10"
    property bool monthChosen: false                 // stepped by the user: stays; otherwise it follows the current month
    property var days: []
    property string error: ""

    // sources the server computes; anything else is a stored override
    readonly property var computed: ["default", "holiday", "before-first"]
    readonly property var badges: ({ holiday: qsTr("holiday"), manual: qsTr("set"), "import": qsTr("imported"),
                                     "before-first": qsTr("before first log") })
    // below this width the reason field gets its own line under the day
    readonly property bool narrow: availableWidth < 480
    readonly property int colW: 68   // the hours columns

    // The rows live in a ListModel that is updated in place by date, so a reload (after every save)
    // keeps the delegates, and with them the focus and a half-typed value in another row.
    ListModel { id: rowModel }
    property int requestId: 0

    contentWidth: availableWidth

    // day rows with a header row before each ISO week
    function buildRows(list) {
        const out = []
        let week = ""
        for (const d of list) {
            const wk = Api.weekKey(d.date)
            if (wk !== week) {
                week = wk
                const total = list.filter(x => Api.weekKey(x.date) === wk).reduce((a, x) => a + Number(x.expected_h), 0)
                out.push({ sep: true, label: qsTr("Week %1 · %2 expected").arg(wk.slice(5)).arg(Api.fmtH(total)),
                           date: "", expected: 0, sick: 0, reason: "", source: "" })
            }
            out.push({ sep: false, label: "", date: d.date, expected: Number(d.expected_h), sick: Number(d.sick_h || 0),
                       reason: d.reason || "", source: d.source || "" })
        }
        return out
    }

    function applyDays(list) {
        const rows = buildRows(list)
        let same = rowModel.count === rows.length
        for (let i = 0; same && i < rows.length; ++i)
            same = rowModel.get(i).sep === rows[i].sep && rowModel.get(i).date === rows[i].date
        if (!same) {
            rowModel.clear()
            for (const r of rows)
                rowModel.append(r)
            return
        }
        for (let i = 0; i < rows.length; ++i) {
            const cur = rowModel.get(i)
            for (const k of ["label", "expected", "sick", "reason", "source"])
                if (cur[k] !== rows[i][k])
                    rowModel.setProperty(i, k, rows[i][k])
        }
    }

    // the delegate's row of a date (tests)
    function rowItem(date) {
        for (let i = 0; i < rep.count; ++i) {
            const it = rep.itemAt(i) as Loader
            const row = it ? Object(it.item) : null   // Object(): the row type is anonymous
            if (row && row.rowDate === date)
                return row
        }
        return null
    }

    function shiftMonth(n) {
        const d = Api.parseDate(month + "-01")
        d.setMonth(d.getMonth() + n)
        month = Api.isoDate(d).slice(0, 7)
        monthChosen = true
    }

    function reload() {
        const id = ++requestId
        const m = month
        const first = Api.parseDate(m + "-01")
        const last = new Date(first.getFullYear(), first.getMonth() + 1, 0)
        Api.request("GET", "/api/days?" + Api.query({ start: Api.isoDate(first), end: Api.isoDate(last) }), undefined,
                    function (d) {
                        if (id !== page?.requestId)   // a slower answer for a month the user already left
                            return
                        page.days = d
                        page.applyDays(d)
                        page.error = ""
                    }, function (e) {
                        if (id === page?.requestId)
                            page.error = e
                    })
    }

    // hours as typed: "7.5" or "7,5", 0..24; NaN when not acceptable
    function hours(text, allowEmpty) {
        if (allowEmpty && text.trim() === "")
            return 0
        const v = Api.parseNum(text)
        return v >= 0 && v <= 24 ? v : NaN
    }

    // false (and an error shown) when the hours are not numbers: nothing is ever sent as NaN/null
    // `onFail(message)` runs when the server refuses it (the row then goes back to the saved values)
    function save(date, expected, sick, reason, onFail) {
        const e = hours(expected, false), s = hours(sick, true)
        if (isNaN(e) || isNaN(s)) {
            error = qsTr("Hours must be a number from 0 to 24")
            return false
        }
        Api.request("PUT", "/api/days/" + date, { expected_h: e, sick_h: s, reason: reason }, null, function (e2) {
            page.error = e2
            if (onFail) onFail(e2)
        })
        return true
    }

    onMonthChanged: reload()
    Component.onCompleted: if (visible) reload()
    onVisibleChanged: {
        if (visible && !monthChosen)
            month = Api.today().slice(0, 7)   // the app can run for days: follow the calendar
        if (visible)
            reload()
    }
    Connections {
        target: Api
        // a hidden page reloads when its tab is shown
        function onChanged() { if (page.visible) page.reload() }
        function onServerChanged() { if (page.visible) page.reload() }
    }

    ColumnLayout {
        width: page.availableWidth
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 12
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            ToolButton {
                text: "‹"
                font.pixelSize: 22
                implicitWidth: 48
                Accessible.name: qsTr("Previous month")
                Accessible.role: Accessible.Button
                onClicked: page.shiftMonth(-1)
            }
            Label {
                text: Api.parseDate(page.month + "-01").toLocaleDateString(Api.locale, "MMMM yyyy")
                font.pixelSize: 20
                font.weight: Font.Bold
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
            }
            ToolButton {
                text: "›"
                font.pixelSize: 22
                implicitWidth: 48
                Accessible.name: qsTr("Next month")
                Accessible.role: Accessible.Button
                onClicked: page.shiftMonth(1)
            }
        }

        NoticeBanner {
            visible: page.error !== ""
            text: qsTr("Error: %1").arg(page.error)
            level: "error"
        }

        Card {
            title: qsTr("Expected hours")

            Caption {
                text: qsTr("Defaults are greyed; edited days are marked and can be reset")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
            }

            RowLayout {   // column heads
                spacing: 8
                Layout.fillWidth: true
                Caption {
                    text: qsTr("Day")
                    Layout.preferredWidth: page.narrow ? -1 : 110
                    Layout.maximumWidth: page.narrow ? 100000 : 110
                    Layout.fillWidth: page.narrow
                }
                Caption { text: page.availableWidth < 360 ? qsTr("Exp.") : qsTr("Expected"); horizontalAlignment: Text.AlignRight; Layout.preferredWidth: page.colW }
                Caption { text: qsTr("Sick"); horizontalAlignment: Text.AlignRight; Layout.preferredWidth: page.colW }
                Caption { visible: !page.narrow; text: qsTr("Reason"); Layout.fillWidth: true }
                Item { implicitWidth: 36 }
            }

            Repeater {
                id: rep
                model: rowModel
                delegate: Loader {
                    id: rowLoader
                    required property bool sep
                    required property string label
                    required property string date
                    required property real expected
                    required property real sick
                    required property string reason
                    required property string source
                    Layout.fillWidth: true
                    sourceComponent: sep ? sepRow : dayRow

                    Component {
                        id: sepRow
                        Label {
                            text: rowLoader.label
                            color: Api.muted
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            topPadding: 10
                            bottomPadding: 2
                        }
                    }

                    Component {
                        id: dayRow
                        GridLayout {
                            id: dr
                            readonly property string rowDate: rowLoader.date
                            property alias expItem: expField
                            property alias sickItem: sickField
                            property alias reasonItem: reasonField
                            readonly property bool stored: page.computed.indexOf(rowLoader.source) < 0
                            readonly property bool weekend: [0, 6].indexOf(Api.parseDate(rowLoader.date).getDay()) >= 0
                            columns: page.narrow ? 4 : 5
                            columnSpacing: 8
                            rowSpacing: 4
                            opacity: dr.weekend && !dr.stored && rowLoader.expected === 0 ? 0.55 : 1

                            // fields show the server's value, except one the user is typing in
                            function sync() {
                                if (!expField.activeFocus) expField.text = String(rowLoader.expected)
                                if (!sickField.activeFocus) sickField.text = String(rowLoader.sick)
                                if (!reasonField.activeFocus) reasonField.text = rowLoader.reason
                            }
                            property string err: ""   // why the last edit of this row was rejected
                            function revert() {
                                expField.text = String(rowLoader.expected)
                                sickField.text = String(rowLoader.sick)
                                reasonField.text = rowLoader.reason
                            }
                            function commit() {
                                const e = page.hours(expField.text, false), s = page.hours(sickField.text, true)
                                if (!isNaN(e) && !isNaN(s) && e === rowLoader.expected && s === rowLoader.sick
                                        && reasonField.text === rowLoader.reason)
                                    return
                                dr.err = ""
                                const ok = page.save(rowLoader.date, expField.text, sickField.text, reasonField.text, function (m) {
                                    if (dr) { dr.err = m; dr.revert() }
                                })
                                if (!ok) {
                                    dr.err = page.error
                                    dr.revert()
                                }
                            }
                            Component.onCompleted: sync()
                            Connections {
                                target: rowLoader
                                function onExpectedChanged() { dr.sync() }
                                function onSickChanged() { dr.sync() }
                                function onReasonChanged() { dr.sync() }
                            }

                            ColumnLayout {
                                spacing: 0
                                Layout.preferredWidth: page.narrow ? -1 : 110
                                Layout.maximumWidth: page.narrow ? 100000 : 110
                                Layout.fillWidth: page.narrow
                                Label {
                                    text: Api.parseDate(rowLoader.date).toLocaleDateString(Api.locale, "ddd d")
                                    font.weight: dr.stored ? Font.DemiBold : Font.Normal
                                    color: dr.stored ? Api.fg : Api.muted
                                }
                                Label {
                                    visible: !!page.badges[rowLoader.source]
                                    text: page.badges[rowLoader.source] || ""
                                    color: rowLoader.source === "holiday" ? Api.breakColor : Api.accent
                                    font.pixelSize: 11
                                }
                            }
                            TextField {
                                id: expField
                                color: dr.stored ? Api.fg : Api.muted
                                // "7.5" and "7,5" both, whatever the device's locale
                                validator: RegularExpressionValidator { regularExpression: /^\d{0,2}([.,]\d{0,2})?$/ }
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                horizontalAlignment: Text.AlignRight
                                topPadding: 6
                                bottomPadding: 6
                                implicitHeight: 36
                                Layout.preferredWidth: page.colW
                                Accessible.name: qsTr("Expected hours")
                                onEditingFinished: dr.commit()
                            }
                            TextField {
                                id: sickField
                                color: rowLoader.sick > 0 ? Api.fg : Api.muted
                                validator: RegularExpressionValidator { regularExpression: /^\d{0,2}([.,]\d{0,2})?$/ }
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                horizontalAlignment: Text.AlignRight
                                topPadding: 6
                                bottomPadding: 6
                                implicitHeight: 36
                                Layout.preferredWidth: page.colW
                                Accessible.name: qsTr("Sick hours")
                                onEditingFinished: dr.commit()
                            }
                            TextField {
                                id: reasonField
                                topPadding: 6
                                bottomPadding: 6
                                implicitHeight: 36
                                placeholderText: qsTr("Reason")
                                Layout.fillWidth: true
                                Layout.row: page.narrow ? 1 : 0
                                Layout.column: page.narrow ? 0 : 3
                                Layout.columnSpan: page.narrow ? 4 : 1
                                Accessible.name: qsTr("Reason")
                                onEditingFinished: dr.commit()
                            }
                            Label {
                                visible: dr.err !== ""
                                text: dr.err
                                color: Api.errorColor
                                font.pixelSize: 12
                                wrapMode: Text.Wrap
                                Layout.row: 2
                                Layout.column: 0
                                Layout.columnSpan: page.narrow ? 4 : 5
                                Layout.fillWidth: true
                            }
                            ToolButton {
                                text: "↺"
                                enabled: dr.stored
                                opacity: dr.stored ? 1 : 0
                                implicitWidth: 36
                                Layout.row: 0
                                Layout.column: page.narrow ? 3 : 4
                                Accessible.name: qsTr("Back to default")
                                Accessible.role: Accessible.Button
                                ToolTip.visible: hovered
                                ToolTip.text: qsTr("Back to default")
                                onClicked: Api.request("DELETE", "/api/days/" + rowLoader.date, undefined, null, e => page.error = e)
                            }
                        }
                    }
                }
            }
        }
        Item { implicitHeight: 8 }
    }
}
