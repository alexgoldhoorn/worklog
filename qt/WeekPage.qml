pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// The balance week (the web's Week page): the seven days with work meetings, personal events and
// planned blocks (approve / reject), then the load gate, work goals and the 28-day gate history.
ScrollView {
    id: page
    property string start: ""        // Monday of the shown week; "" = this week
    property var weekData: null       // the /api/balance/week answer
    property string error: ""
    property string info: ""
    property string outlook: ""
    property bool adding: false

    readonly property var kinds: ["family", "run", "stop", "other"]
    readonly property var gate: weekData ? weekData.gate : ({})
    readonly property var nums: gate && gate.numbers ? gate.numbers : ({})
    readonly property string todayIso: weekData ? weekData.today : Api.today()
    readonly property var meaning: ({
        green: qsTr("Capacity ok. Nothing to protect this week."),
        amber: qsTr("Two or more signals are up. Keep the hard stop and one easy day."),
        red: qsTr("Work load and body signals are both up. The gate protects the week: approve the blocks below.") })

    contentWidth: availableWidth

    function gateColor(c) { return c === "green" ? Api.workColor : c === "amber" ? Api.breakColor : c === "red" ? Api.errorColor : Api.muted }
    function dayLabel(iso) { return Api.parseDate(iso).toLocaleDateString(Qt.locale(), "ddd d MMM") }
    function fmt(v, unit) { return v === null || v === undefined ? "–" : v + (unit || "") }
    function range(s, e) { return e ? s + "–" + e : s }

    // one entry per day, its items sorted by start time
    readonly property var agenda: {
        const w = weekData
        if (!w)
            return []
        return w.days.map(d => {
            const items = []
            for (const e of w.work.filter(x => x.date === d))
                items.push({ start: e.start, time: range(e.start, e.end), text: e.title, sub: qsTr("work"), tone: Api.workColor, block: null })
            for (const e of w.personal.filter(x => x.date === d && !x.all_day))
                items.push({ start: e.start, time: range(e.start, e.end), text: e.title, sub: e.calendar || "", tone: Api.muted, block: null })
            for (const b of w.blocks.filter(x => x.date === d && x.state !== "rejected"))
                items.push({ start: b.start, time: range(b.start, b.end), text: b.title, sub: b.kind + " · " + b.state,
                             tone: b.state === "proposed" ? Api.warnColor : b.kind === "stop" ? Api.errorColor : Api.accent, block: b })
            items.sort((a, b) => a.start < b.start ? -1 : a.start > b.start ? 1 : 0)
            return { date: d, label: page.dayLabel(d), isToday: d === w.today,
                     allDay: w.personal.filter(x => x.date === d && x.all_day).map(x => x.title), items: items }
        })
    }

    readonly property var gateRows: [
        [qsTr("Work, last 7 days"), fmt(nums.hours_7d, " h")],
        [qsTr("Work, 3-week average"), fmt(nums.hours_21d_week_avg, " h/wk")],
        [qsTr("Evenings past the stop"), fmt(nums.evenings_7d)],
        [qsTr("Resting HR (7 d / usual)"), fmt(nums.rhr_7d) + " / " + fmt(nums.rhr_base)],
        [qsTr("HRV (7 d / usual)"), fmt(nums.hrv_7d, " ms") + " / " + fmt(nums.hrv_base, " ms")],
        [qsTr("Sleep (7 d)"), fmt(nums.sleep_7d_h, " h")],
        [qsTr("Stress (7 d / usual)"), fmt(nums.stress_7d) + " / " + fmt(nums.stress_base)],
        [qsTr("Runs done / planned (14 d)"), fmt(nums.runs_done_14d) + " / " + fmt(nums.runs_planned_14d)],
        [qsTr("Heavy days tapped (7 d)"), fmt(nums.felt_heavy_7d)]
    ]

    function reload() {
        Api.request("GET", "/api/balance/week" + (start !== "" ? "?" + Api.query({ start: start }) : ""), undefined,
                    function (d) {
                        page.weekData = d
                        page.error = ""
                    }, e => page.error = e)
    }

    function shift(days) { start = Api.addDays(weekData ? weekData.start : Api.today(), days) }

    function decide(id, action) {
        Api.request("POST", "/api/balance/blocks/" + id + "/" + action, undefined, function () {
            page.info = action === "approve" ? qsTr("Approved.") : qsTr("Rejected.")
        }, e => page.error = e)
    }

    function propose() {
        const from = weekData.start < weekData.today ? weekData.today : weekData.start
        if (from > weekData.end) {
            info = qsTr("This week is over; nothing to propose.")
            return
        }
        Api.request("POST", "/api/balance/propose", { start: from, end: weekData.end }, function (r) {
            page.info = r.created.length ? qsTr("%1 block(s) proposed.").arg(r.created.length)
                                         : qsTr("Nothing to propose: every day already has its blocks, or no runs are planned.")
        }, e => page.error = e)
    }

    function showOutlook() {
        if (outlook !== "") {
            outlook = ""
            return
        }
        Api.request("GET", "/api/balance/outlook?" + Api.query({ start: weekData.start }), undefined,
                    (d, text) => page.outlook = text, e => page.error = e)
    }

    function addBlock() {
        Api.request("POST", "/api/balance/blocks",
                    { date: dateField.text, start: fromField.text, end: toField.text,
                      kind: kindBox.currentText, title: titleField.text }, function () {
            page.adding = false
            titleField.text = ""
            page.info = qsTr("Block saved and approved.")
        }, e => page.error = e)
    }

    onStartChanged: reload()
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
            ToolButton {
                text: "‹"
                font.pixelSize: 22
                implicitWidth: 48
                Accessible.name: qsTr("Previous week")
                Accessible.role: Accessible.Button
                onClicked: page.shift(-7)
            }
            ColumnLayout {
                spacing: 0
                Layout.fillWidth: true
                Label {
                    text: page.weekData ? page.dayLabel(page.weekData.start) + " – " + page.dayLabel(page.weekData.end) : qsTr("Week")
                    font.pixelSize: 18
                    font.weight: Font.Bold
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth: true
                }
                Label {
                    text: page.weekData ? qsTr("Week %1").arg(Api.weekKey(page.weekData.start).slice(5)) : ""
                    color: Api.muted
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth: true
                }
            }
            ToolButton {
                text: qsTr("Today")
                Accessible.name: qsTr("This week")
                Accessible.role: Accessible.Button
                onClicked: page.start = ""
            }
            ToolButton {
                text: "›"
                font.pixelSize: 22
                implicitWidth: 48
                Accessible.name: qsTr("Next week")
                Accessible.role: Accessible.Button
                onClicked: page.shift(7)
            }
        }

        NoticeBanner {
            visible: page.error !== ""
            text: qsTr("Error: %1").arg(page.error)
            level: "error"
        }
        NoticeBanner {
            visible: page.info !== ""
            text: page.info
            level: "info"
            tappable: true
            onTapped: page.info = ""
        }

        Card {
            title: qsTr("Load gate")
            visible: page.weekData !== null
            actions: Label {
                text: page.gate && page.gate.colour ? page.gate.colour : qsTr("no verdict")
                color: page.gateColor(page.gate ? page.gate.colour : "")
                font.weight: Font.Bold
            }

            Label {
                visible: !(page.gate && page.gate.colour)
                text: qsTr("No verdict yet: the gate runs daily.")
                color: Api.muted
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: !!(page.gate && page.gate.colour)
                text: (page.meaning[page.gate.colour] || "") + (page.gate.date ? " (" + page.gate.date + ")" : "")
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Repeater {
                model: page.gate && page.gate.signals ? page.gate.signals : []
                delegate: Label {
                    required property var modelData
                    text: "• " + modelData.text
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
            }
            Label {
                visible: !!(page.gate && page.gate.protect)
                text: qsTr("Protect: %1").arg(page.gate.protect || "")
                font.weight: Font.DemiBold
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            DataTable {
                visible: !!(page.gate && page.gate.colour)
                columns: [{ title: qsTr("Signal"), w: 190 }, { title: qsTr("Value"), w: 110, num: true }]
                rows: page.gateRows.map(r => ({ cells: r }))
            }
            Label {
                visible: !!(page.gate && page.gate.gaps && page.gate.gaps.length)
                text: qsTr("No data: %1").arg(page.gate && page.gate.gaps ? page.gate.gaps.join(", ") : "")
                color: Api.warnColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }

        RowLayout {
            visible: page.weekData !== null
            spacing: 8
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            Button {
                text: qsTr("Propose")
                Layout.fillWidth: true
                Accessible.name: qsTr("Propose blocks for this week")
                Accessible.role: Accessible.Button
                onClicked: page.propose()
            }
            Button {
                text: qsTr("Outlook")
                Layout.fillWidth: true
                Accessible.name: qsTr("Outlook list")
                Accessible.role: Accessible.Button
                onClicked: page.showOutlook()
            }
            Button {
                text: qsTr("Add")
                Layout.fillWidth: true
                Accessible.name: qsTr("Add a block")
                Accessible.role: Accessible.Button
                onClicked: {
                    dateField.text = page.todayIso
                    page.adding = !page.adding
                }
            }
        }

        Card {
            visible: page.outlook !== ""
            title: qsTr("Outlook list")
            Label {
                text: page.outlook
                wrapMode: Text.Wrap
                font.family: "monospace"
                font.pixelSize: 12
                Layout.fillWidth: true
            }
        }

        Card {
            visible: page.adding
            title: qsTr("Add a block")
            GridLayout {
                columns: 2
                columnSpacing: 8
                Layout.fillWidth: true
                TextField {
                    id: dateField
                    placeholderText: qsTr("Date YYYY-MM-DD")
                    Layout.columnSpan: 2
                    Layout.fillWidth: true
                    Accessible.name: qsTr("Date")
                }
                TextField {
                    id: fromField
                    placeholderText: qsTr("From HH:MM")
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Accessible.name: qsTr("From")
                }
                TextField {
                    id: toField
                    placeholderText: qsTr("To HH:MM")
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Accessible.name: qsTr("To")
                }
                ComboBox {
                    id: kindBox
                    model: page.kinds
                    Layout.columnSpan: 2
                    Layout.fillWidth: true
                    Accessible.name: qsTr("Kind")
                }
                TextField {
                    id: titleField
                    placeholderText: qsTr("Title")
                    maximumLength: 120
                    Layout.columnSpan: 2
                    Layout.fillWidth: true
                    Accessible.name: qsTr("Title")
                }
            }
            Button {
                text: qsTr("Save as approved")
                enabled: titleField.text !== "" && fromField.text !== "" && toField.text !== ""
                Accessible.name: text
                Accessible.role: Accessible.Button
                onClicked: page.addBlock()
            }
        }

        Repeater {
            model: page.agenda
            delegate: Card {
                id: dayCard
                required property var modelData
                title: modelData.label + (modelData.isToday ? " · " + qsTr("today") : "")

                Label {
                    visible: dayCard.modelData.allDay.length > 0
                    text: dayCard.modelData.allDay.join(" · ")
                    color: Api.muted
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
                Label {
                    visible: dayCard.modelData.items.length === 0
                    text: qsTr("nothing on the calendars")
                    color: Api.faint
                }
                Repeater {
                    model: dayCard.modelData.items
                    delegate: RowLayout {
                        id: row
                        required property var modelData
                        spacing: 8
                        Layout.fillWidth: true
                        Rectangle { implicitWidth: 4; radius: 2; color: row.modelData.tone; Layout.fillHeight: true }
                        ColumnLayout {
                            spacing: 0
                            Layout.fillWidth: true
                            Label {
                                text: row.modelData.time + "  " + row.modelData.text
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                            }
                            Label {
                                visible: text !== ""
                                text: row.modelData.sub
                                color: Api.muted
                                font.pixelSize: 11
                                Layout.fillWidth: true
                            }
                        }
                        ToolButton {
                            visible: !!row.modelData.block && row.modelData.block.state === "proposed"
                            text: "✓"
                            Accessible.name: qsTr("Approve %1").arg(row.modelData.text)
                            Accessible.role: Accessible.Button
                            onClicked: page.decide(row.modelData.block.id, "approve")
                        }
                        ToolButton {
                            visible: !!row.modelData.block
                            text: "✗"
                            Accessible.name: qsTr("Reject %1").arg(row.modelData.text)
                            Accessible.role: Accessible.Button
                            onClicked: page.decide(row.modelData.block.id, "reject")
                        }
                    }
                }
            }
        }

        Card {
            id: goalsCard
            title: qsTr("Work goals")
            visible: page.weekData !== null
            readonly property var goals: page.weekData ? page.weekData.goals : null
            readonly property bool has: !!goals && !!goals.project

            Label {
                visible: !goalsCard.has
                text: qsTr("No Todoist snapshot yet.")
                color: Api.muted
            }
            Label {
                visible: goalsCard.has
                text: goalsCard.has ? qsTr("%1 · %2 open").arg(goalsCard.goals.project).arg(goalsCard.goals.open) : ""
                color: Api.muted
                font.pixelSize: 12
            }
            Caption { visible: goalsCard.has; text: qsTr("Milestones") }
            Repeater {
                model: goalsCard.has ? goalsCard.goals.milestones : []
                delegate: RowLayout {
                    id: ms
                    required property var modelData
                    readonly property int daysLeft: Math.round((Api.parseDate(modelData.due.slice(0, 10)) - Api.parseDate(page.todayIso)) / 864e5)
                    Layout.fillWidth: true
                    Label { text: ms.modelData.due.slice(0, 10); color: ms.daysLeft < 0 ? Api.errorColor : ms.daysLeft <= 7 ? Api.warnColor : Api.muted }
                    Label { text: ms.modelData.content; wrapMode: Text.Wrap; Layout.fillWidth: true }
                    Label {
                        text: ms.daysLeft < 0 ? qsTr("%1 d ago").arg(-ms.daysLeft) : ms.daysLeft === 0 ? qsTr("today") : qsTr("in %1 d").arg(ms.daysLeft)
                        color: Api.muted
                    }
                }
            }
            Caption { visible: goalsCard.has; text: qsTr("Top 3 today") }
            Repeater {
                model: goalsCard.has ? goalsCard.goals.top3 : []
                delegate: Label {
                    required property var modelData
                    required property int index
                    text: (index + 1) + ". " + modelData.content
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
            }
        }

        Card {
            title: qsTr("Gate history")
            visible: page.weekData !== null && page.weekData.history.length > 0
            Flow {
                spacing: 4
                Layout.fillWidth: true
                Repeater {
                    model: page.weekData ? page.weekData.history : []
                    delegate: Rectangle {
                        id: sq
                        required property var modelData
                        width: 24
                        height: 24
                        radius: 4
                        color: Qt.alpha(page.gateColor(modelData.colour), 0.35)
                        border.color: page.gateColor(modelData.colour)
                        Accessible.role: Accessible.StaticText
                        Accessible.name: modelData.date + ": " + modelData.colour
                        Label {
                            anchors.centerIn: parent
                            text: sq.modelData.date.slice(8)
                            font.pixelSize: 10
                        }
                    }
                }
            }
            Caption {
                text: qsTr("One square per day, last 28 days; the number is the day of the month")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
            }
        }

        Item { implicitHeight: 12 }
    }
}
