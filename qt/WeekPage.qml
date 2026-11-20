pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// The balance week (the web's Week page): the seven days with work meetings, personal events and
// planned blocks (approve / reject, with Undo), then the load gate, work goals, the 28-day gate history and
// the balance settings.
ScrollView {
    id: page
    signal addToCalendar()   // a meeting or appointment, not a protected block: Main opens Add or find a date
    property string start: ""        // Monday of the shown week; "" = this week
    property var weekData: null       // the /api/balance/week answer
    property string error: ""
    property string info: ""
    property string outlook: ""
    property bool adding: false
    property string addError: ""     // why adding a block failed, shown inside the form
    property int confirmId: -1       // an approved block the user is asked about removing

    readonly property var kinds: ["family", "run", "stop", "other"]
    readonly property var kindModel: kinds.map(k => ({ value: k, text: kindName(k) }))
    readonly property string formProblem: blockProblem(dateField.text, fromField.text, toField.text, titleField.text)
    property alias dateFieldItem: dateField   // tests
    property alias fromFieldItem: fromField
    property alias toFieldItem: toField
    property alias titleFieldItem: titleField
    readonly property var gate: weekData ? weekData.gate : ({})
    readonly property var nums: gate && gate.numbers ? gate.numbers : ({})
    readonly property string todayIso: weekData ? weekData.today : Api.today()
    readonly property var meaning: ({
        green: qsTr("Capacity ok. Nothing to protect this week."),
        amber: qsTr("Two or more signals are up. Keep the hard stop and one easy day."),
        red: qsTr("Work load and body signals are both up. The gate protects the week: approve the blocks below.") })

    contentWidth: availableWidth

    // the server's words, translated
    readonly property var colourNames: ({ green: qsTr("green"), amber: qsTr("amber"), red: qsTr("red") })
    readonly property var stateNames: ({ proposed: qsTr("proposed"), approved: qsTr("approved"), rejected: qsTr("rejected") })
    readonly property var kindNames: ({ family: qsTr("family"), run: qsTr("run"), stop: qsTr("stop"), other: qsTr("other") })
    function colourName(c) { return colourNames[c] || c || "" }
    function stateName(s) { return stateNames[s] || s }
    function kindName(k) { return kindNames[k] || k }

    function gateColor(c) { return c === "green" ? Api.workColor : c === "amber" ? Api.breakColor : c === "red" ? Api.errorColor : Api.muted }
    function dayLabel(iso) { return Api.parseDate(iso).toLocaleDateString(Api.locale, "ddd d MMM") }
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
                items.push({ start: b.start, time: range(b.start, b.end), text: b.title, sub: page.kindName(b.kind) + " · " + page.stateName(b.state),
                             tone: b.state === "proposed" ? Api.warnColor : b.kind === "stop" ? Api.errorColor : Api.accent, block: b })
            items.sort((a, b) => a.start < b.start ? -1 : a.start > b.start ? 1 : 0)
            return { date: d, label: page.dayLabel(d), isToday: d === w.today,
                     allDay: w.personal.filter(x => x.date === d && x.all_day).map(x => x.title), items: items }
        })
    }

    // [label, value, note] as the web's "The numbers behind it" table
    readonly property var gateRows: [
        [qsTr("Work last 7 days"), fmt(nums.hours_7d, " h"),
         weekData && weekData.settings ? qsTr("band %1–%2 h").arg(weekData.settings.week_hours_min).arg(weekData.settings.week_hours_max) : ""],
        [qsTr("Work, 3-week average"), fmt(nums.hours_21d_week_avg, " h/week"), ""],
        [qsTr("Evenings past the stop (7 d)"), fmt(nums.evenings_7d), ""],
        [qsTr("Resting HR (7 d / usual)"), fmt(nums.rhr_7d) + " / " + fmt(nums.rhr_base), ""],
        [qsTr("HRV (7 d / usual)"), fmt(nums.hrv_7d, " ms") + " / " + fmt(nums.hrv_base, " ms"), ""],
        [qsTr("Sleep (7 d)"), fmt(nums.sleep_7d_h, " h") + (nums.sleep_score_7d !== null && nums.sleep_score_7d !== undefined ? qsTr(", score %1").arg(nums.sleep_score_7d) : ""), ""],
        [qsTr("Stress (7 d / usual)"), fmt(nums.stress_7d) + " / " + fmt(nums.stress_base), ""],
        [qsTr("Runs done / planned (14 d)"), fmt(nums.runs_done_14d) + " / " + fmt(nums.runs_planned_14d), nums.illness_open ? qsTr("illness open: runs not counted") : ""],
        [qsTr("Heavy days you tapped (7 d)"), fmt(nums.felt_heavy_7d), ""]
    ]

    // "Google Calendar: <state> (n block(s) waiting)" when the calendar sync is not ok, else ""
    readonly property string syncWarning: {
        const sy = weekData ? weekData.sync : null
        return sy && sy.google && sy.google !== "ok" ? qsTr("Google Calendar: %1 (%2 block(s) waiting)").arg(sy.google).arg(sy.pending || 0) : ""
    }
    // "Tue 20 Oct in 3 days" for the event the gate is looking ahead to
    function preEventText(pe) { return pe ? (pe.days === 1 ? qsTr("%1 in 1 day").arg(pe.title) : qsTr("%1 in %2 days").arg(pe.title).arg(pe.days)) : "" }
    function balanceRepeaterItem(i) { return balanceRepeater.itemAt(i) }

    // days from the shown "today" to an ISO date or datetime (negative: past)
    function daysFrom(iso) { return Math.round((Api.parseDate(String(iso).slice(0, 10)) - Api.parseDate(page.todayIso)) / 864e5) }
    // "3 d ago", "today", "in 3 d"
    function leftText(d) { return d < 0 ? qsTr("%1 d ago").arg(-d) : d === 0 ? qsTr("today") : qsTr("in %1 d").arg(d) }

    // ---- balance settings (the web's card at the bottom of Week) ---------------------------------
    readonly property var balanceFields: [
        { key: "hard_stop", label: qsTr("Hard stop"), time: true, help: qsTr("24h. Work past this time counts as an evening for the gate; the proposed Hard stop blocks start here.") },
        { key: "run_slot", label: qsTr("Run slot"), time: true, help: qsTr("24h. Where the Sunday proposal puts a planned run.") },
        { key: "run_alt_slots", label: qsTr("Run fallback slots"), help: qsTr("24h, comma-separated. Tried in order when the run slot clashes with a work meeting.") },
        { key: "week_hours_min", label: qsTr("Week hours min"), number: true, help: qsTr("The band the gate judges work hours against (hours signal fires above max).") },
        { key: "week_hours_max", label: qsTr("Week hours max"), number: true, help: "" },
        { key: "gcal_calendar", label: qsTr("Google calendar"), help: qsTr("Approved blocks are mirrored to this calendar (primary with a prefix until it exists).") },
        { key: "todoist_project", label: qsTr("Todoist project"), help: qsTr("Where the top 3 and milestones come from.") },
        { key: "milestone_label", label: qsTr("Milestone label"), help: qsTr("Milestones are dated Todoist tasks in that project carrying this label; they are not stored here.") }
    ]
    property bool balanceOpen: false
    property bool balanceDirty: false     // typed in, not saved: a reload must not overwrite it
    property string balanceMessage: ""
    property string balanceError: ""
    function fillBalance() {
        const st = weekData ? weekData.settings : null
        if (!st)
            return
        for (let i = 0; i < balanceRepeater.count; i++) {
            const it = balanceRepeater.itemAt(i)
            if (it)
                it.field.text = st[it.key] === null || st[it.key] === undefined ? "" : String(st[it.key])
        }
        balanceDirty = false
    }
    // the typed values, as the web sends them (every field as text)
    function balanceBody() {
        const body = {}
        for (let i = 0; i < balanceRepeater.count; i++) {
            const it = balanceRepeater.itemAt(i)
            if (it)
                body[it.key] = it.field.text.trim()
        }
        return body
    }
    function saveBalance() {
        balanceError = ""
        balanceMessage = ""
        Api.request("PUT", "/api/balance/settings", balanceBody(), function () {
            page.balanceDirty = false
            page.balanceMessage = qsTr("Settings saved. The gate reads them on its next run.")
            page.reload()
        }, e => page.balanceError = e)
    }
    onWeekDataChanged: if (!balanceDirty) Qt.callLater(fillBalance)

    property int requestId: 0

    function reload() {
        const id = ++requestId
        Api.request("GET", "/api/balance/week" + (start !== "" ? "?" + Api.query({ start: start }) : ""), undefined,
                    function (d) {
                        if (id !== page?.requestId)   // a slower answer for a week the user already left
                            return
                        page.weekData = d
                        page.error = ""
                    }, function (e) {
                        if (id === page?.requestId)
                            page.error = e
                    })
    }

    function shift(days) { start = Api.addDays(weekData ? weekData.start : Api.today(), days) }

    // ✗ on a block: an approved one is asked about first (it is on the calendar), a proposed one goes at once
    function reject(block) {
        if (block.state === "approved")
            confirmId = block.id
        else
            decide(block.id, "reject")
    }
    // action: "approve", "reject" or "propose" (back to proposed). Approving and rejecting offer Undo, which
    // calls the server's propose route: the block is "proposed" again, whatever it was before.
    function decide(id, action) {
        Api.request("POST", "/api/balance/blocks/" + id + "/" + action, undefined, function () {
            page.info = ""
            if (action === "propose")
                snack.show(qsTr("Back to proposed."))
            else
                snack.show(action === "approve" ? qsTr("Approved. Google Calendar catches up within 15 minutes.") : qsTr("Rejected."),
                           () => page.decide(id, "propose"))
        }, e => page.error = e)
    }

    Snackbar { id: snack }
    property alias snackbar: snack   // tests

    function propose() {
        const from = weekData.start < weekData.today ? weekData.today : weekData.start
        if (from > weekData.end) {
            info = qsTr("This week is over; nothing to propose.")
            return
        }
        Api.request("POST", "/api/balance/propose", { start: from, end: weekData.end }, function (r) {
            page.info = r.created.length ? qsTr("%1 block(s) proposed.").arg(r.created.length) + " " + qsTr("Tick the ones you want.")
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

    // ---- the add-a-block form (pure checks, tests call them) -----------------------------------

    function validDate(t) {
        if (!/^\d{4}-\d{2}-\d{2}$/.test(t))
            return false
        const p = t.split("-").map(Number)
        const d = new Date(p[0], p[1] - 1, p[2])
        return d.getFullYear() === p[0] && d.getMonth() === p[1] - 1 && d.getDate() === p[2]
    }
    function validTime(t) { return /^([01]\d|2[0-3]):[0-5]\d$/.test(t) }
    // "" when the form can be saved, else why not
    function blockProblem(date, from, to, title) {
        const f = Api.normTime(from), t = Api.normTime(to)
        if (!validDate(date.trim()))
            return qsTr("Date must be YYYY-MM-DD")
        if (!validTime(f) || !validTime(t))
            return qsTr("Times must be HH:MM")
        if (t <= f)
            return qsTr("End must be after the start")
        if (title.trim() === "")
            return qsTr("A title is needed")
        return ""
    }

    function addBlock() {
        Api.request("POST", "/api/balance/blocks",
                    { date: dateField.text.trim(), start: Api.normTime(fromField.text), end: Api.normTime(toField.text),
                      kind: kindBox.currentValue, title: titleField.text.trim() }, function () {
            page.adding = false
            page.addError = ""
            titleField.text = ""
            page.info = qsTr("Block saved and approved.")
        }, e => page.addError = e)
    }

    // "monospace" does not resolve on Windows: take the first fixed-width family this system has
    readonly property string monoFamily: {
        const have = Qt.fontFamilies()
        const want = ["Cascadia Mono", "Consolas", "Menlo", "DejaVu Sans Mono", "Roboto Mono", "Droid Sans Mono", "Courier New"]
        return want.find(f => have.indexOf(f) >= 0) || "monospace"
    }

    function copyOutlook() {
        outlookText.selectAll()
        outlookText.copy()
        outlookText.deselect()
        snack.show(qsTr("Copied to the clipboard"))
    }

    onStartChanged: {
        outlook = ""   // the list belongs to the week it was made for
        reload()
    }
    Component.onCompleted: if (visible) reload()
    onVisibleChanged: if (visible) reload()
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
            AppIconButton {
                text: "‹"
                name: qsTr("Previous week")
                onClicked: page.shift(-7)
            }
            ColumnLayout {
                spacing: 0
                Layout.fillWidth: true
                Label {
                    text: page.weekData ? page.dayLabel(page.weekData.start) + " – " + page.dayLabel(page.weekData.end) : qsTr("Week")
                    font.pixelSize: 18
                    font.weight: Font.Bold
                    fontSizeMode: Text.HorizontalFit   // "Mon 16 Nov – Sun 22 Nov" must not run into the Today button at 360 dp
                    minimumPixelSize: 12
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
            AppButton {
                flat: true
                text: qsTr("Today")
                Accessible.name: qsTr("This week")
                Accessible.role: Accessible.Button
                onClicked: page.start = ""
            }
            AppIconButton {
                text: "›"
                name: qsTr("Next week")
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
                text: page.gate && page.gate.colour ? qsTr("Load %1").arg(page.colourName(page.gate.colour)) : qsTr("No verdict yet")
                color: page.gateColor(page.gate ? page.gate.colour : "")
                font.weight: Font.Bold
            }

            Caption {
                text: qsTr("Daily at 07:22, from work hours, body signals and runs kept")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: !(page.gate && page.gate.colour)
                text: qsTr("The gate runs at 07:22")
                color: Api.muted
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: !!(page.gate && page.gate.colour)
                text: qsTr("Verdict of %1").arg(page.gate.date || "")
                color: Api.muted
                font.pixelSize: 12
                Layout.fillWidth: true
            }
            Label {
                visible: !!(page.gate && page.gate.pre_event)
                text: "· " + page.preEventText(page.gate ? page.gate.pre_event : null)
                color: Api.muted
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: !!(page.gate && page.gate.colour)
                text: page.meaning[page.gate.colour] || ""
                color: Api.muted
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Caption { visible: !!(page.gate && page.gate.colour); text: qsTr("Why") }
            Label {
                visible: !!(page.gate && page.gate.colour) && !(page.gate.signals && page.gate.signals.length)
                text: qsTr("No signal firing.")
                color: Api.muted
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
            Caption { visible: !!(page.gate && page.gate.protect); text: qsTr("Protect") }
            Label {
                visible: !!(page.gate && page.gate.protect)
                text: page.gate.protect || ""
                font.weight: Font.DemiBold
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Caption { visible: !!(page.gate && page.gate.colour); text: qsTr("The numbers behind it") }
            Repeater {
                model: page.gate && page.gate.colour ? page.gateRows : []
                delegate: ColumnLayout {
                    id: nrow
                    required property var modelData
                    spacing: 0
                    Layout.fillWidth: true
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: nrow.modelData[0]; wrapMode: Text.Wrap; Layout.fillWidth: true; font.pixelSize: 13 }
                        Label { text: nrow.modelData[1]; font.pixelSize: 13; font.weight: Font.DemiBold; font.features: { "tnum": 1 } }
                    }
                    Label {
                        visible: nrow.modelData[2] !== ""
                        text: nrow.modelData[2]
                        color: Api.muted
                        font.pixelSize: 11
                        Layout.fillWidth: true
                    }
                    Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: Api.line2 }
                }
            }
            Label {
                visible: !!(page.gate && page.gate.gaps && page.gate.gaps.length)
                text: qsTr("No data: %1").arg(page.gate && page.gate.gaps ? page.gate.gaps.join(", ") : "")
                color: Api.warnColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: page.syncWarning !== ""
                text: page.syncWarning
                color: Api.warnColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }

        // what you can do with the week; each action says what it is for
        Card {
            visible: page.weekData !== null
            title: qsTr("Protected time")

            // the button, and what it is for beside it (below it on a narrow screen, where the text got a few words a line)
            component Act: GridLayout {
                id: act
                property string label
                property string hint
                signal clicked()
                columns: page.availableWidth < 420 ? 1 : 2
                columnSpacing: 12
                rowSpacing: 4
                Layout.fillWidth: true
                AppButton {
                    text: act.label
                    Layout.preferredWidth: 150
                    Layout.fillWidth: page.availableWidth < 420
                    Accessible.name: act.label
                    Accessible.description: act.hint
                    Accessible.role: Accessible.Button
                    onClicked: act.clicked()
                }
                Label {
                    text: act.hint
                    color: Api.muted
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
            }
            Act {
                label: qsTr("Propose blocks")
                hint: qsTr("Suggests runs and hard stops for the rest of this week. Nothing counts until you approve it.")
                onClicked: page.propose()
            }
            Act {
                label: qsTr("Add a block")
                hint: qsTr("Protect a time yourself: family, a run, a stop. It is approved at once.")
                onClicked: {
                    dateField.text = page.todayIso
                    page.addError = ""
                    page.adding = !page.adding
                }
            }
            Act {
                label: qsTr("Outlook list")
                hint: qsTr("Your approved blocks as text, to paste into Outlook as busy time.")
                onClicked: page.showOutlook()
            }
            Act {
                label: qsTr("Add to calendar")
                hint: qsTr("A meeting or appointment at a time you know, or find a free time for it.")
                onClicked: page.addToCalendar()
            }
        }

        Card {
            visible: page.outlook !== ""
            title: qsTr("Outlook list")
            actions: Button {
                text: qsTr("Copy")
                flat: true
                Accessible.name: qsTr("Copy the Outlook list")
                Accessible.role: Accessible.Button
                onClicked: page.copyOutlook()
            }
            // selectable (and copyable with the button): the list is meant to be pasted elsewhere
            TextEdit {
                id: outlookText
                text: page.outlook
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                color: Api.fg
                selectionColor: Api.accent
                selectedTextColor: Api.accentFg
                font.family: page.monoFamily
                font.pixelSize: 12
                Layout.fillWidth: true
                Accessible.role: Accessible.StaticText
                Accessible.name: qsTr("Outlook list")
                Accessible.description: text
            }
        }

        Card {
            visible: page.adding
            title: qsTr("Add a block")
            GridLayout {
                columns: 2
                columnSpacing: 8
                Layout.fillWidth: true
                RowLayout {
                    spacing: 8
                    Layout.columnSpan: 2
                    Layout.fillWidth: true
                    TextField {
                        id: dateField
                        placeholderText: qsTr("Date YYYY-MM-DD")
                        validator: RegularExpressionValidator { regularExpression: /^[0-9-]{0,10}$/ }
                        inputMethodHints: Qt.ImhDigitsOnly
                        readOnly: true   // the date is chosen in the calendar
                        Layout.fillWidth: true
                        Accessible.name: qsTr("Date")
                        MouseArea { anchors.fill: parent; onClicked: datePicker.openFor(dateField.text) }
                    }
                    AppButton {
                        text: qsTr("Pick")
                        flat: true
                        Accessible.name: qsTr("Pick a date")
                        Accessible.role: Accessible.Button
                        onClicked: datePicker.openFor(dateField.text)
                    }
                }
                TimeField {
                    id: fromField
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Accessible.name: qsTr("From")
                }
                TimeField {
                    id: toField
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Accessible.name: qsTr("To")
                }
                ComboBox {
                    id: kindBox
                    model: page.kindModel
                    textRole: "text"
                    valueRole: "value"
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
            Label {
                // only once something is typed, so an empty form is not shouted at
                visible: page.formProblem !== "" && (titleField.text !== "" || fromField.text !== "" || toField.text !== "")
                text: page.formProblem
                color: Api.warnColor
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: page.addError !== ""
                text: qsTr("Could not save: %1").arg(page.addError)
                color: Api.errorColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            AppButton {
                text: qsTr("Save as approved")
                primary: true
                enabled: page.formProblem === ""
                Accessible.name: text
                Accessible.role: Accessible.Button
                onClicked: page.addBlock()
            }
        }

        DatePicker {
            id: datePicker
            onPicked: iso => dateField.text = iso
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
                        AppIconButton {
                            visible: !!row.modelData.block && row.modelData.block.state === "proposed"
                            text: "✓"
                            ink: Api.accent
                            name: qsTr("Approve %1").arg(row.modelData.text)
                            onClicked: page.decide(row.modelData.block.id, "approve")
                        }
                        AppIconButton {
                            visible: !!row.modelData.block
                            text: "✗"
                            ink: Api.errorColor
                            name: qsTr("Reject %1").arg(row.modelData.text)
                            onClicked: page.reject(row.modelData.block)
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
            readonly property string milestoneLabel: page.weekData && page.weekData.settings ? page.weekData.settings.milestone_label || "" : ""

            Label {
                visible: !goalsCard.has
                text: qsTr("No Todoist snapshot yet (sync runs every 15 min).")
                color: Api.muted
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: goalsCard.has
                text: goalsCard.has ? [goalsCard.goals.project, qsTr("%1 open").arg(goalsCard.goals.open),
                                       goalsCard.goals.fetched ? String(goalsCard.goals.fetched).slice(0, 16).replace("T", " ") : ""]
                                      .filter(x => x).join(" · ") : ""
                color: Api.muted
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Caption { visible: goalsCard.has; text: qsTr("Milestones") }
            Label {
                visible: goalsCard.has && goalsCard.goals.milestones.length === 0
                text: goalsCard.has ? qsTr("None yet. Milestones live in Todoist, not here: give a dated task in %1 the label %2 and it appears on the next sync.")
                                      .arg(goalsCard.goals.project).arg(goalsCard.milestoneLabel) : ""
                color: Api.muted
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Repeater {
                model: goalsCard.has ? goalsCard.goals.milestones : []
                delegate: GridLayout {
                    id: ms
                    required property var modelData
                    readonly property int daysLeft: page.daysFrom(modelData.due)
                    readonly property color tone: daysLeft < 0 ? Api.errorColor : daysLeft <= 7 ? Api.warnColor : Api.muted
                    columns: 2
                    columnSpacing: 10
                    rowSpacing: 0
                    Layout.fillWidth: true
                    Label { text: ms.modelData.due.slice(0, 10); color: ms.tone; font.pixelSize: 12 }
                    Label { text: page.leftText(ms.daysLeft); color: ms.tone; font.pixelSize: 12; horizontalAlignment: Text.AlignRight; Layout.fillWidth: true }
                    Label {
                        text: Api.mdHtml(ms.modelData.content)
                        textFormat: Text.StyledText
                        wrapMode: Text.Wrap
                        Layout.columnSpan: 2
                        Layout.fillWidth: true
                        onLinkActivated: link => Qt.openUrlExternally(link)
                    }
                }
            }
            Caption { visible: goalsCard.has; text: qsTr("Top 3 today") }
            Label {
                visible: goalsCard.has && goalsCard.goals.top3.length === 0
                text: qsTr("Nothing due today in this project.")
                color: Api.muted
                Layout.fillWidth: true
            }
            Repeater {
                model: goalsCard.has ? goalsCard.goals.top3 : []
                delegate: Label {
                    id: top
                    required property var modelData
                    required property int index
                    readonly property bool overdue: !!modelData.due && String(modelData.due).slice(0, 10) < page.todayIso
                    text: (index + 1) + ". " + Api.mdHtml(modelData.content)
                          + (overdue ? " <font color=\"" + Api.muted + "\">(" + Api.esc(String(modelData.due).slice(0, 10)) + ")</font>" : "")
                    textFormat: Text.StyledText
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                    onLinkActivated: link => Qt.openUrlExternally(link)
                }
            }
            Label {
                visible: goalsCard.has && goalsCard.goals.due_today_or_overdue > 3
                text: goalsCard.has ? qsTr("%1 due or overdue in total; the three highest priority are shown.").arg(goalsCard.goals.due_today_or_overdue) : ""
                color: Api.muted
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }

        Card {
            title: qsTr("Gate history")
            visible: page.weekData !== null
            Label {
                visible: !!page.weekData && page.weekData.history.length === 0
                text: qsTr("No history yet.")
                color: Api.muted
            }
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
                        Accessible.name: modelData.date + ": " + page.colourName(modelData.colour)
                        Label {
                            anchors.centerIn: parent
                            text: sq.modelData.date.slice(8)
                            font.pixelSize: 10
                        }
                    }
                }
            }
            Caption {
                text: qsTr("One square per day, last 28 days: green / amber / red, number = day of month")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }

        Card {
            title: qsTr("Balance settings")
            visible: page.weekData !== null
            actions: Button {
                text: page.balanceOpen ? qsTr("Hide") : qsTr("Show")
                flat: true
                Accessible.name: page.balanceOpen ? qsTr("Hide the balance settings") : qsTr("Show the balance settings")
                Accessible.role: Accessible.Button
                onClicked: page.balanceOpen = !page.balanceOpen
            }
            Caption {
                text: qsTr("Hard stop, run slot, hours band, calendar, Todoist project · stored in balance.db")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Repeater {
                id: balanceRepeater
                model: page.balanceOpen ? page.balanceFields : []
                onItemAdded: Qt.callLater(page.fillBalance)
                delegate: ColumnLayout {
                    id: brow
                    required property var modelData
                    readonly property string key: modelData.key
                    property alias field: bfield
                    spacing: 2
                    Layout.fillWidth: true
                    Label { text: brow.modelData.label; font.pixelSize: 12; color: Api.muted }
                    TextField {
                        id: bfield
                        inputMethodHints: brow.modelData.number ? Qt.ImhFormattedNumbersOnly : Qt.ImhNone
                        placeholderText: brow.modelData.time ? qsTr("HH:MM") : ""
                        Layout.fillWidth: true
                        Accessible.name: brow.modelData.label
                        Accessible.description: brow.modelData.help
                        onTextEdited: { page.balanceDirty = true; page.balanceMessage = "" }
                    }
                    Label {
                        visible: brow.modelData.help !== ""
                        text: brow.modelData.help
                        color: Api.muted
                        font.pixelSize: 11
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                }
            }
            Label {
                visible: page.balanceOpen
                text: qsTr("The gate and the Sunday proposal read them on their next run.")
                color: Api.muted
                font.pixelSize: 11
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: page.balanceError !== ""
                text: qsTr("Could not save: %1").arg(page.balanceError)
                color: Api.errorColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: page.balanceMessage !== ""
                text: page.balanceMessage
                color: Api.workColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            AppButton {
                visible: page.balanceOpen
                text: qsTr("Save")
                primary: true
                Accessible.name: text
                onClicked: page.saveBalance()
            }
        }

        Item { implicitHeight: 12 }
    }

    AppDialog {
        parent: Overlay.overlay
        modal: true
        visible: page.confirmId >= 0
        title: qsTr("Remove this approved block?")
        width: Math.min(parent ? parent.width - 32 : 320, 400)
        standardButtons: Dialog.Yes | Dialog.Cancel
        Material.accent: Api.accent
        contentItem: Label {
            text: qsTr("It is taken off the calendar on the next sync. Undo puts it back to proposed.")
            wrapMode: Text.Wrap
        }
        onAccepted: { const id = page.confirmId; page.confirmId = -1; page.decide(id, "reject") }
        onRejected: page.confirmId = -1
    }
}
