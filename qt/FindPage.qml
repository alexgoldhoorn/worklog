pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Add or find a date (the web's Add / Find a date dialog): say what and where it goes. "Find a time"
// has the server rank free slots (/api/day/slots) for you to pick; "I know when" takes the date and
// the times as typed. Either way it is put in with /api/day/find. Needs the planner's balance store
// on the server; without it the page shows the server's 503 message.
// Left out as browser-only: the ?what= prefill.
ScrollView {
    id: page

    // the web's chip values, with their labels
    readonly property var lengths: [{ v: 30, t: qsTr("30 min") }, { v: 45, t: qsTr("45") }, { v: 60, t: qsTr("60") },
                                    { v: 90, t: qsTr("90") }, { v: 120, t: qsTr("120") }]
    readonly property var travels: [{ v: 0, t: qsTr("none") }, { v: 15, t: qsTr("15") }, { v: 25, t: qsTr("25") }, { v: 45, t: qsTr("45") }]
    readonly property var whens: [{ v: 7, t: qsTr("this week") }, { v: 14, t: qsTr("next 2 weeks") }, { v: 21, t: qsTr("3 weeks") }]
    readonly property var prefers: [{ value: "morning", label: qsTr("mornings") }, { value: "afternoon", label: qsTr("afternoons") },
                                    { value: "evening", label: qsTr("evenings") }, { value: "not_school_runs", label: qsTr("not school-run times") }]
    readonly property var targets: [{ v: "personal", t: qsTr("Personal calendar"), where: qsTr("your Personal Google calendar") },
                                    { v: "family", t: qsTr("Family calendar"), where: qsTr("the Family Google calendar") },
                                    { v: "work", t: qsTr("Work calendar"), where: qsTr("the work calendar mirror (paste the line into Outlook)") },
                                    { v: "training", t: qsTr("Training block"), where: qsTr("an approved training block") },
                                    { v: "todoist", t: qsTr("Todoist task"), where: qsTr("a Todoist task") }]
    readonly property var priorities: [{ v: 4, t: "P1" }, { v: 3, t: "P2" }, { v: 2, t: "P3" }, { v: 1, t: "P4" }]

    property string mode: "find"          // "find": the server looks for a time; "add": the date and times are typed
    readonly property var modes: [{ v: "add", t: qsTr("I know when") }, { v: "find", t: qsTr("Find a time") }]
    property string addDate: Api.today()
    property string addStart: ""
    property string addEnd: ""
    // the typed times as "HH:MM", "" while they are not times
    readonly property string startHM: page.hhmm(addStart)
    readonly property string endHM: page.hhmm(addEnd)
    readonly property bool canAdd: what.trim() !== "" && startHM !== "" && endHM !== "" && startHM < endHM

    property string what: ""
    property int minutes: 45
    property int travel: 0
    property int days: 14
    property var prefer: ["not_school_runs"]
    property string target: "personal"
    property string project: "Personal"
    property int priority: 2

    property var slotsData: null          // the last /api/day/slots answer
    property var options: []              // best slot per day, from slotsData
    property var chosen: null
    property bool busy: false
    property bool putDone: false
    property string error: ""
    property string info: ""
    property string paste: ""
    property int seq: 0                   // only the newest answer is shown

    readonly property var unknownDays: slotsData ? Object.keys(slotsData.days).filter(d => slotsData.days[d].unknown) : []

    contentWidth: availableWidth

    function labels(list) { return list.map(x => x.t) }
    function valueOf(list, text) { const m = list.find(x => x.t === text); return m ? m.v : undefined }
    function labelOf(list, v) { const m = list.find(x => x.v === v); return m ? m.t : "" }
    function dayLabel(iso) { return Api.parseDate(iso).toLocaleDateString(Qt.locale(), "ddd d MMM") }
    function targetText(v) { return (targets.find(x => x.v === v) || { where: "" }).where }

    function hhmm(text) {
        const t = Api.normTime(text)
        return /^([01]\d|2[0-3]):[0-5]\d$/.test(t) ? t : ""
    }
    function minutesBetween(a, b) {
        return (Number(b.slice(0, 2)) * 60 + Number(b.slice(3))) - (Number(a.slice(0, 2)) * 60 + Number(a.slice(3)))
    }
    // "I know when": no search, the typed date and times go straight in
    function add() {
        if (!canAdd) {
            error = what.trim() === "" ? qsTr("Say what it is first.") : qsTr("Give a start and a later end time, like 14:00 and 15:00.")
            return
        }
        chosen = { date: addDate, start: startHM, end: endHM }
        putDone = false
        put()
    }

    // what the server is asked to place; the kind decides which rules apply to it
    function itemFromForm() {
        const kind = target === "training" ? "gym" : target === "work" ? "work" : "personal"
        if (mode === "add")
            return { title: what.trim(), minutes: Math.max(5, minutesBetween(startHM, endHM)), kind: kind,
                     travel_before: 0, travel_after: 0, prefer: [] }
        return { title: what.trim(), minutes: minutes, kind: kind, travel_before: travel, travel_after: travel, prefer: prefer.slice() }
    }

    // one option per day: the best slot of that day, best days first
    function bestPerDay(slots) {
        const seen = {}
        const out = []
        for (const s of slots) {
            if (s.verdict === "clash" || s.verdict === "ask_trainer" || seen[s.date])
                continue
            seen[s.date] = true
            out.push(s)
        }
        return out.slice(0, 8)
    }

    function verdictColor(v) {
        return v === "fits" ? Api.workColor : v === "tight" ? Api.breakColor : v === "clash" ? Api.errorColor
               : v === "ask_trainer" ? Api.accent : Api.faint
    }

    function find() {
        const item = itemFromForm()
        if (item.title === "") {
            error = qsTr("Say what it is first.")
            return
        }
        const from = Api.today()
        const my = ++seq
        busy = true
        Api.request("POST", "/api/day/slots", { item: item, from: from, to: Api.addDays(from, days - 1) }, function (d) {
            if (my !== page?.seq)
                return
            page.busy = false
            page.error = ""
            page.info = ""
            page.paste = ""
            page.slotsData = d
            page.chosen = null
            page.putDone = false
            page.options = page.bestPerDay(d.slots)
        }, function (e) {
            if (my === page?.seq) {
                page.busy = false
                page.error = e
            }
        })
    }

    function pick(slot) {
        chosen = slot
        putDone = false
        paste = ""
    }

    function put() {
        if (!chosen)
            return
        const s = chosen
        const item = itemFromForm()
        const body = { item: item, date: s.date, start: s.start, end: s.end, target: target }
        if (target === "todoist")
            body.todoist = { project: project.trim(), priority: priority, due_string: s.date }
        Api.request("POST", "/api/day/find", body, function (out) {
            const bits = []
            if (out.queued.length)
                bits.push(qsTr("queued for the next sync (within 2 minutes)"))
            if (out.blocks.length)
                bits.push(qsTr("block approved"))
            page.error = ""
            page.info = qsTr("Put in: %1, %2 %3.").arg(item.title).arg(page.dayLabel(s.date)).arg(s.start)
                        + (bits.length ? " " + bits.join(", ") + "." : "")
            page.paste = out.paste || ""
            page.putDone = true
        }, e => page.error = qsTr("Could not put it in: %1").arg(e))
    }

    // the results belong to the server they came from
    function clearResults() {
        seq++
        busy = false
        slotsData = null
        options = []
        chosen = null
        putDone = false
        paste = ""
        info = ""
        error = ""
    }

    Connections {
        target: Api
        function onServerChanged() { page.clearResults() }
    }

    ColumnLayout {
        width: page.availableWidth
        spacing: 12

        Label {
            text: page.mode === "add" ? qsTr("Add to a calendar") : qsTr("Find a date")
            font.pixelSize: 18
            font.weight: Font.Bold
            Layout.topMargin: 12
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            Layout.fillWidth: true
        }
        Label {
            text: page.mode === "add" ? qsTr("A meeting or appointment at a time you already know")
                                      : qsTr("Dentist, gym, a run, a call: say what, it finds when")
            color: Api.muted
            wrapMode: Text.Wrap
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            Layout.fillWidth: true
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
            ChipRow {
                model: page.labels(page.modes)
                current: page.labelOf(page.modes, page.mode)
                onPicked: v => {
                    page.mode = page.valueOf(page.modes, v)
                    page.clearResults()
                }
            }
            TextField {
                placeholderText: qsTr("What, e.g. Dentist check-up")
                maximumLength: 200
                text: page.what
                Layout.fillWidth: true
                Accessible.name: qsTr("What")
                onTextEdited: page.what = text
                onAccepted: page.mode === "add" ? page.add() : page.find()
            }
            // ---- "I know when": the date and the times
            RowLayout {
                visible: page.mode === "add"
                spacing: 8
                Layout.fillWidth: true
                Button {
                    text: page.dayLabel(page.addDate)
                    flat: true
                    Accessible.name: qsTr("Date, now %1").arg(page.addDate)
                    Accessible.role: Accessible.Button
                    onClicked: addPicker.openFor(page.addDate)
                }
                TextField {
                    placeholderText: qsTr("From")
                    text: page.addStart
                    inputMethodHints: Qt.ImhTime
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Accessible.name: qsTr("Start time")
                    onTextEdited: page.addStart = text
                }
                TextField {
                    placeholderText: qsTr("To")
                    text: page.addEnd
                    inputMethodHints: Qt.ImhTime
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Accessible.name: qsTr("End time")
                    onTextEdited: page.addEnd = text
                    onAccepted: page.add()
                }
            }
            ChipRow {
                visible: page.mode === "find"
                label: qsTr("Length (min)")
                model: page.labels(page.lengths)
                current: page.labelOf(page.lengths, page.minutes)
                onPicked: v => page.minutes = page.valueOf(page.lengths, v)
            }
            ChipRow {
                visible: page.mode === "find"
                label: qsTr("Travel each way (min)")
                model: page.labels(page.travels)
                current: page.labelOf(page.travels, page.travel)
                onPicked: v => page.travel = page.valueOf(page.travels, v)
            }
            ChipRow {
                visible: page.mode === "find"
                label: qsTr("When")
                model: page.labels(page.whens)
                current: page.labelOf(page.whens, page.days)
                onPicked: v => page.days = page.valueOf(page.whens, v)
            }
            ChipMulti {
                visible: page.mode === "find"
                label: qsTr("Prefer")
                model: page.prefers
                selected: page.prefer
                onToggled: v => page.prefer = page.prefer.indexOf(v) >= 0 ? page.prefer.filter(x => x !== v) : page.prefer.concat([v])
            }
            ChipRow {
                label: qsTr("Goes in")
                model: page.labels(page.targets)
                current: page.labelOf(page.targets, page.target)
                onPicked: v => page.target = page.valueOf(page.targets, v)
            }
            GridLayout {
                visible: page.target === "todoist"
                columns: 2
                columnSpacing: 8
                Layout.fillWidth: true
                TextField {
                    text: page.project
                    placeholderText: qsTr("Project")
                    Layout.fillWidth: true
                    Layout.preferredWidth: 2
                    Accessible.name: qsTr("Todoist project")
                    onTextEdited: page.project = text
                }
                ComboBox {
                    model: page.labels(page.priorities)
                    currentIndex: page.priorities.findIndex(x => x.v === page.priority)
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Accessible.name: qsTr("Todoist priority")
                    onActivated: i => page.priority = page.priorities[i].v
                }
            }
            Button {
                visible: page.mode === "find"
                text: page.busy ? qsTr("Finding…") : qsTr("Find")
                enabled: !page.busy
                highlighted: true
                Layout.alignment: Qt.AlignRight
                Accessible.name: qsTr("Find a date")
                Accessible.role: Accessible.Button
                onClicked: page.find()
            }
            Label {
                visible: page.mode === "add"
                text: qsTr("Goes into %1").arg(page.targetText(page.target))
                color: Api.muted
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Button {
                visible: page.mode === "add"
                text: qsTr("Add")
                enabled: page.canAdd && !page.putDone
                highlighted: true
                Layout.alignment: Qt.AlignRight
                Accessible.name: qsTr("Add to the calendar")
                Accessible.role: Accessible.Button
                onClicked: page.add()
            }
            TextArea {
                visible: page.mode === "add" && page.paste !== ""
                text: page.paste
                readOnly: true
                selectByMouse: true
                font.family: "monospace"
                wrapMode: Text.Wrap
                Layout.fillWidth: true
                Accessible.name: qsTr("Line to paste into Outlook")
            }
        }

        Card {
            visible: page.mode === "find"
            title: qsTr("Best options")
            Label {
                text: qsTr("ranked by what they cost you: nothing moved, run kept, child care covered, hours band kept")
                color: Api.muted
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: page.slotsData === null
                text: qsTr("Fill in the form and press Find.")
                color: Api.muted
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: page.slotsData !== null && page.options.length === 0
                text: qsTr("Nothing fits in that range without a clash. Try a longer range or fewer preferences.")
                color: Api.muted
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Repeater {
                model: page.options
                delegate: Rectangle {
                    id: row
                    required property var modelData
                    readonly property bool picked: page.chosen === row.modelData
                    Layout.fillWidth: true
                    implicitHeight: rowBody.implicitHeight + 16
                    radius: 10
                    color: row.modelData.best ? Api.workBg : "transparent"
                    border.color: row.picked ? Api.accent : row.modelData.best ? Api.workColor : Api.line
                    border.width: row.picked ? 2 : 1

                    RowLayout {
                        id: rowBody
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: 10
                        spacing: 10
                        Rectangle {
                            implicitWidth: 10
                            implicitHeight: 10
                            radius: 5
                            color: page.verdictColor(row.modelData.verdict)
                            Layout.alignment: Qt.AlignTop
                            Layout.topMargin: 6
                        }
                        ColumnLayout {
                            spacing: 2
                            Layout.fillWidth: true
                            Label {
                                text: page.dayLabel(row.modelData.date) + " · " + row.modelData.start + "–" + row.modelData.end
                                      + (row.modelData.best ? "  [" + qsTr("best") + "]" : "")
                                font.weight: Font.DemiBold
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                            }
                            Label {
                                visible: row.modelData.verdict === "unknown"
                                text: qsTr("work calendar unknown")
                                color: Api.warnColor
                                font.pixelSize: 12
                            }
                            Label {
                                text: row.modelData.reasons.join(" · ") || qsTr("fits")
                                color: Api.muted
                                font.pixelSize: 12
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                            }
                        }
                        Button {
                            text: qsTr("Pick")
                            flat: true
                            Accessible.name: qsTr("Pick %1").arg(page.dayLabel(row.modelData.date) + " " + row.modelData.start)
                            Accessible.role: Accessible.Button
                            onClicked: page.pick(row.modelData)
                        }
                    }
                }
            }
            Label {
                visible: page.unknownDays.length > 0
                text: qsTr("Work calendar unknown on: %1. Import the Outlook PDF before trusting those.")
                      .arg(page.unknownDays.map(d => page.dayLabel(d)).join(", "))
                color: Api.muted
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            // pick, then put it in
            Label {
                visible: page.chosen !== null
                text: page.chosen ? qsTr("%1 on %2 %3–%4 → %5").arg(page.what.trim()).arg(page.dayLabel(page.chosen.date))
                                      .arg(page.chosen.start).arg(page.chosen.end).arg(page.targetText(page.target)) : ""
                color: Api.muted
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Button {
                visible: page.chosen !== null
                text: qsTr("Put it in")
                enabled: !page.putDone
                highlighted: true
                Layout.alignment: Qt.AlignRight
                Accessible.name: qsTr("Put it in")
                Accessible.role: Accessible.Button
                onClicked: page.put()
            }
            TextArea {
                visible: page.paste !== ""
                text: page.paste
                readOnly: true
                selectByMouse: true
                font.family: "monospace"
                wrapMode: Text.Wrap
                Layout.fillWidth: true
                Accessible.name: qsTr("Line to paste into Outlook")
            }
        }

        Item { implicitHeight: 12 }
    }

    DatePicker {
        id: addPicker
        date: page.addDate
        onPicked: iso => {
            page.addDate = iso
            page.putDone = false
        }
    }
}
