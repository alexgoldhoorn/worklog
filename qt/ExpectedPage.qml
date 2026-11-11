pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Expected hours per day (the web's Days page): defaults greyed, overrides marked and resettable.
ScrollView {
    id: page
    property string month: Api.today().slice(0, 7)   // "2026-10"
    property var days: []
    property string error: ""

    // sources the server computes; anything else is a stored override
    readonly property var computed: ["default", "holiday", "before-first"]
    readonly property var badges: ({ holiday: qsTr("holiday"), manual: qsTr("set"), import: qsTr("imported"),
                                     "before-first": qsTr("before first log") })

    // day rows with a header row before each ISO week
    readonly property var rows: {
        const out = []
        let week = ""
        for (const d of days) {
            const wk = Api.weekKey(d.date)
            if (wk !== week) {
                week = wk
                const total = days.filter(x => Api.weekKey(x.date) === wk).reduce((a, x) => a + Number(x.expected_h), 0)
                out.push({ sep: true, text: qsTr("Week %1 · %2 expected").arg(wk.slice(5)).arg(Api.fmtH(total)) })
            }
            out.push(d)
        }
        return out
    }

    contentWidth: availableWidth

    function shiftMonth(n) {
        const d = Api.parseDate(month + "-01")
        d.setMonth(d.getMonth() + n)
        month = Api.isoDate(d).slice(0, 7)
    }

    function reload() {
        const first = Api.parseDate(month + "-01")
        const last = new Date(first.getFullYear(), first.getMonth() + 1, 0)
        Api.request("GET", "/api/days?" + Api.query({ start: Api.isoDate(first), end: Api.isoDate(last) }), undefined,
                    function (d) {
                        page.days = d
                        page.error = ""
                    }, e => page.error = e)
    }

    function save(d, expected, sick, reason) {
        Api.request("PUT", "/api/days/" + d.date,
                    { expected_h: Number(expected), sick_h: Number(sick || 0), reason: reason }, null, e => page.error = e)
    }

    onMonthChanged: reload()
    Component.onCompleted: reload()
    onVisibleChanged: if (visible) reload()
    Connections {
        target: Api
        function onChanged() { page.reload() }
        function onServerChanged() { page.reload() }
    }

    ColumnLayout {
        width: page.availableWidth
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 12
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            ToolButton { text: "‹"; font.pixelSize: 22; implicitWidth: 48; onClicked: page.shiftMonth(-1) }
            Label {
                text: Api.parseDate(page.month + "-01").toLocaleDateString(Qt.locale(), "MMMM yyyy")
                font.pixelSize: 20
                font.weight: Font.Bold
                horizontalAlignment: Text.AlignHCenter
                Layout.fillWidth: true
            }
            ToolButton { text: "›"; font.pixelSize: 22; implicitWidth: 48; onClicked: page.shiftMonth(1) }
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
                Caption { text: qsTr("Day"); Layout.preferredWidth: 110; Layout.maximumWidth: 110 }
                Caption { text: qsTr("Exp."); horizontalAlignment: Text.AlignRight; Layout.preferredWidth: 56 }
                Caption { text: qsTr("Sick"); horizontalAlignment: Text.AlignRight; Layout.preferredWidth: 56 }
                Caption { text: qsTr("Reason"); Layout.fillWidth: true }
                Item { implicitWidth: 36 }
            }

            Repeater {
                model: page.rows
                delegate: Loader {
                    id: rowLoader
                    required property var modelData
                    Layout.fillWidth: true
                    sourceComponent: modelData.sep ? sepRow : dayRow

                    Component {
                        id: sepRow
                        Label {
                            text: rowLoader.modelData.text
                            color: Api.muted
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            topPadding: 10
                            bottomPadding: 2
                        }
                    }

                    Component {
                        id: dayRow
                        RowLayout {
                            id: dr
                            readonly property var d: rowLoader.modelData
                            readonly property bool stored: page.computed.indexOf(d.source) < 0
                            readonly property bool weekend: [0, 6].indexOf(Api.parseDate(d.date).getDay()) >= 0
                            spacing: 8
                            opacity: dr.weekend && !dr.stored && Number(dr.d.expected_h) === 0 ? 0.55 : 1

                            function commit() {
                                if (expField.text === String(dr.d.expected_h) && sickField.text === String(dr.d.sick_h)
                                        && reasonField.text === (dr.d.reason || ""))
                                    return
                                page.save(dr.d, expField.text, sickField.text, reasonField.text)
                            }

                            ColumnLayout {
                                spacing: 0
                                Layout.preferredWidth: 110
                                Layout.maximumWidth: 110
                                Label {
                                    text: Api.parseDate(dr.d.date).toLocaleDateString(Qt.locale(), "ddd d")
                                    font.weight: dr.stored ? Font.DemiBold : Font.Normal
                                    color: dr.stored ? Api.fg : Api.muted
                                }
                                Label {
                                    visible: !!page.badges[dr.d.source]
                                    text: page.badges[dr.d.source] || ""
                                    color: dr.d.source === "holiday" ? Api.breakColor : Api.accent
                                    font.pixelSize: 11
                                }
                            }
                            TextField {
                                id: expField
                                text: String(dr.d.expected_h)
                                color: dr.stored ? Api.fg : Api.muted
                                validator: DoubleValidator { bottom: 0; top: 24; notation: DoubleValidator.StandardNotation }
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                horizontalAlignment: Text.AlignRight
                                topPadding: 6
                                bottomPadding: 6
                                implicitHeight: 36
                                Layout.preferredWidth: 56
                                onEditingFinished: dr.commit()
                            }
                            TextField {
                                id: sickField
                                text: String(dr.d.sick_h)
                                color: Number(dr.d.sick_h) > 0 ? Api.fg : Api.muted
                                validator: DoubleValidator { bottom: 0; top: 24; notation: DoubleValidator.StandardNotation }
                                inputMethodHints: Qt.ImhFormattedNumbersOnly
                                horizontalAlignment: Text.AlignRight
                                topPadding: 6
                                bottomPadding: 6
                                implicitHeight: 36
                                Layout.preferredWidth: 56
                                onEditingFinished: dr.commit()
                            }
                            TextField {
                                id: reasonField
                                text: dr.d.reason || ""
                                topPadding: 6
                                bottomPadding: 6
                                implicitHeight: 36
                                Layout.fillWidth: true
                                onEditingFinished: dr.commit()
                            }
                            ToolButton {
                                text: "↺"
                                enabled: dr.stored
                                opacity: dr.stored ? 1 : 0
                                implicitWidth: 36
                                ToolTip.visible: hovered
                                ToolTip.text: qsTr("Back to default")
                                onClicked: Api.request("DELETE", "/api/days/" + dr.d.date, undefined, null, e => page.error = e)
                            }
                        }
                    }
                }
            }
        }
        Item { implicitHeight: 8 }
    }
}
