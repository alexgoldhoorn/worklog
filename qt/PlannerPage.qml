pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtCore

// The Day planner (the web's Day page, `day.js` / `templates/day.html`, API in `day/web.py`): one day's
// timeline of work meetings, personal and family events, the child's duties and protected blocks, the
// first things to do, training, work today, and the writes that still wait for the host. Needs the
// planner's balance store on the server; without it the page shows the server's message (503).
// The timeline is one list sorted by start, as the web does on a phone, with a pill for the lane.
// Left to the web: Move, the work-calendar PDF upload and the Start / Pause / Stop row (the Timer has them).
// Not to be confused with DayPage.qml, which is the Timer screen on another day (the old Log).
ScrollView {
    id: page
    signal addRequested()    // Add: a meeting or appointment at a time you know (Main opens Add or find a date)
    signal findRequested()   // Find a date

    property string date: ""         // "" = today
    property var day: null           // the /api/day answer
    property string error: ""
    property string info: ""
    property int requestId: 0

    // the timeline's lanes; each can be switched off (kept in Settings, like the web's localStorage)
    readonly property var lanes: [{ value: "work", label: qsTr("Work") }, { value: "personal", label: qsTr("Personal") },
                                  { value: "family", label: qsTr("Family") }, { value: "child", label: childName },
                                  { value: "blocks", label: qsTr("Blocks") }]
    readonly property string childName: day && day.household && day.household.child ? day.household.child : qsTr("Child")
    property string lanesOff: ""     // "family,child"
    Settings {
        category: "planner"
        property alias lanesOff: page.lanesOff
    }
    function laneOn(id) { return lanesOff.split(",").indexOf(id) < 0 }
    function toggleLane(id) {
        const off = lanesOff.split(",").filter(x => x !== "" && x !== id)
        if (laneOn(id))
            off.push(id)
        lanesOff = off.join(",")
    }

    contentWidth: availableWidth

    // ---- pure helpers (the tests call them) ---------------------------------------------------------

    // which lane an event belongs to (day.js laneOf)
    function laneOf(ev) {
        return ev.layer === "work" ? "work" : ev.layer === "protected" ? "blocks" : ev.layer === "duty" ? "child"
             : (ev.classification === "child" || ev.lane === "child") ? "child" : ev.lane === "family" ? "family" : "personal"
    }
    function hm(s) { const p = String(s).split(":").map(Number); return p[0] + p[1] / 60 }
    // 7.08 -> "7 h 05"
    function h2(x) { const m = Math.round(x * 60); return Math.floor(m / 60) + " h " + Api.pad(m % 60) }
    function laneColor(id) {
        return id === "work" ? Api.workColor : id === "blocks" ? Api.errorColor : id === "family" ? Api.series[3]
             : id === "child" ? Api.series[4] : Api.accent
    }
    function laneName(id) { const l = lanes.find(x => x.value === id); return l ? l.label : id }

    // events whose "whose?" choices were opened again with "whose? change"
    property var reopened: []
    function evKey(ev) { return ev.start + "|" + ev.title }

    // the line an event shows (day.js: label)
    function eventLabel(ev) {
        let label = ev.start + "–" + ev.end + " " + ev.title
        if (ev.layer === "duty")
            label += ev.owner ? " · " + ev.owner : " · " + qsTr("who?")
        if (ev.layer === "personal" && ev.classification === "unclassified")
            label += " · " + qsTr("whose?")
        if (ev.layer === "personal" && ev.creator_name && ev.lane !== "personal")
            label += " · " + qsTr("by %1").arg(ev.creator_name)
        if (ev.layer === "work" && ev.source && ev.source !== "pdf" && !/\.pdf$/i.test(ev.source))
            label += " · " + qsTr("added by %1").arg(ev.source)
        if (ev.layer === "protected")
            label += " · " + ev.state
        if (ev.pending)
            label += " · " + qsTr("pending")
        return label
    }

    // The timeline as one list: the events of the lanes that are on, sorted by start, with a "now" marker
    // (today only) before the first event that starts later. Each entry is { ev, lane } or { now: "HH:MM" }.
    function timelineRows(d, off) {
        if (!d)
            return []
        const evs = d.timeline.map(ev => ({ ev: ev, lane: laneOf(ev) }))
                      .filter(r => off.indexOf(r.lane) < 0 && hm(r.ev.end) > 6 && hm(r.ev.start) < 22)
        evs.sort((a, b) => hm(a.ev.start) - hm(b.ev.start) || hm(a.ev.end) - hm(b.ev.end))
        if (!d.is_today)
            return evs
        const out = []
        let shown = false
        for (const r of evs) {
            if (!shown && hm(r.ev.start) > hm(d.now)) {
                out.push({ now: d.now })
                shown = true
            }
            out.push(r)
        }
        if (!shown)
            out.push({ now: d.now })
        return out
    }
    readonly property var rows: timelineRows(day, lanesOff.split(","))

    // The body of POST /api/day/classify for a choice of the dialog ("once" | "always"); null for Cancel
    function classifyBody(d, ev, cls, choice) {
        if (choice !== "once" && choice !== "always")
            return null
        return { date: d.date, start: ev.start, title: ev.title, cls: cls, always: choice === "always" }
    }
    // the body of POST /api/day/owner: the other person takes the duty
    function ownerBody(d, ev) {
        const hh = d.household || { me: "me", partner: "partner" }
        return { date: d.date, start: ev.at, title: ev.title, owner: ev.owner === hh.me ? hh.partner : hh.me }
    }
    // the line under the title: when the snapshots were made
    function subLine(d) {
        if (!d)
            return ""
        const full = d.sync && (d.sync.full_ran || d.sync.ran)
        return full ? qsTr("snapshots %1 · google %2").arg(String(full).replace("T", " ").slice(0, 16)).arg(d.sync.google || "?")
                      + (d.is_today ? "" : " · " + qsTr("not today: no timer"))
                    : qsTr("no snapshots yet")
    }
    function mirrorNote(d) {
        if (!d)
            return ""
        if (d.mirror.unknown)
            return qsTr("Work calendar unknown for this day: the mirror's last import ends %1. Paste or import before trusting the free slots.")
                   .arg(d.mirror.last_import_end || qsTr("never"))
        if (d.mirror.stale_days !== null && d.mirror.stale_days !== undefined && d.mirror.stale_days > 7)
            return qsTr("Work calendar PDF is %1 days old.").arg(d.mirror.stale_days)
        return ""
    }
    function countsLine(d) {
        if (!d)
            return ""
        const c = d.counts
        return qsTr("Done %1 · to do %2 · meetings left %3").arg(c.done).arg(c.todo).arg(c.meetings_left === null || c.meetings_left === undefined ? qsTr("unknown") : c.meetings_left)
               + (c.unclassified ? " · " + (c.unclassified === 1 ? qsTr("1 family event to classify") : qsTr("%1 family events to classify").arg(c.unclassified)) : "")
    }
    function fmtDate(iso) { return Api.parseDate(iso).toLocaleDateString(Api.locale, "ddd d MMM") }

    // ---- loading ----------------------------------------------------------------------------------

    function reload() {
        const id = ++requestId
        Api.request("GET", "/api/day" + (date !== "" ? "?" + Api.query({ date: date }) : ""), undefined, function (d) {
            if (!page || id !== page.requestId)   // an older answer for a day the user already left
                return
            page.day = d
            page.error = ""
        }, function (e) {
            if (page && id === page.requestId)
                page.error = e
        })
    }
    function show(iso) { date = iso }
    function step(days) { date = Api.addDays(day ? day.date : Api.today(), days) }
    onDateChanged: { reopened = []; reload() }
    Component.onCompleted: if (visible) reload()
    onVisibleChanged: if (visible) reload()
    Connections {
        target: Api
        function onChanged() { if (page.visible) page.reload() }
        function onServerChanged() { if (page.visible) page.reload() }
    }
    Timer {
        interval: 60000
        repeat: true
        running: page.visible
        onTriggered: page.reload()
    }

    // a write the page did: the reload follows from Api.changed(); an error shows in the banner
    function post(path, body, done) {
        Api.request("POST", path, body, function (d) {
            page.error = ""
            if (done) done(d)
        }, e => page.error = e)
    }
    function classify(ev, cls, choice) {
        const body = classifyBody(day, ev, cls, choice)
        if (body)
            post("/api/day/classify", body)
    }
    function refreshSnapshots() {
        post("/api/day/refresh", undefined, function (r) {
            page.info = r && r.error ? r.error : qsTr("Asked the host sync to refresh the snapshots.")
        })
    }
    function completeTask(id) { post("/api/day/task/" + encodeURIComponent(id) + "/complete") }
    function logMeeting(ev) {
        post("/api/calendar/add", { date: day.date, start: ev.start, end: ev.end, title: ev.title })
    }
    function savePrep(meeting, minutes, text) {
        post("/api/day/prep", { date: day.date, start: meeting.start, title: meeting.title, minutes: minutes, text: text })
    }
    // a work meeting that is over and still waits in the proposals can be added to the time log
    function canLog(ev) {
        if (!day || ev.layer !== "work" || ev.cancelled)
            return false
        const props = day.work && day.work.proposals ? day.work.proposals : []
        return props.some(p => p.start === ev.start && (p.title || "") === (ev.title || ""))
               && (day.is_today ? ev.start <= day.now : day.date < Api.today())
    }

    // ---- dialogs ----------------------------------------------------------------------------------

    property var askEv: null
    property string askCls: ""
    property string askWho: ""
    function ask(ev, cls, who) {
        askEv = ev
        askCls = cls
        askWho = who
        classifyDialog.open()
    }
    function answer(choice) {
        const ev = askEv, cls = askCls
        classifyDialog.close()
        askEv = null
        classify(ev, cls, choice)
    }
    property alias classifyDialogItem: classifyDialog   // tests

    Dialog {
        id: classifyDialog
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        title: page.askEv ? qsTr("Mark \"%1\" as %2?").arg(page.askEv.title).arg(page.askWho) : ""
        width: Math.min(parent ? parent.width - 32 : 320, 420)
        Material.accent: Api.accent
        // Esc or a tap outside is Cancel: nothing is saved
        onRejected: page.askEv = null
        contentItem: ColumnLayout {
            spacing: 12
            Label {
                text: qsTr("Save it for this occurrence only, or for every event with this title. Esc or Cancel saves nothing.")
                wrapMode: Text.Wrap
                color: Api.muted
                Layout.fillWidth: true
            }
            Button {
                text: qsTr("Only this one")
                highlighted: true
                Accessible.name: text
                Layout.fillWidth: true
                onClicked: page.answer("once")
            }
            Button {
                text: qsTr("Always for this title")
                Accessible.name: text
                Layout.fillWidth: true
                onClicked: page.answer("always")
            }
            Button {
                text: qsTr("Cancel")
                flat: true
                Accessible.name: text
                Layout.fillWidth: true
                onClicked: { classifyDialog.close(); page.askEv = null }
            }
        }
    }

    property var prepMeeting: null
    Dialog {
        id: prepDialog
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        title: page.prepMeeting ? qsTr("Prep for %1").arg(page.prepMeeting.title) : ""
        width: Math.min(parent ? parent.width - 32 : 320, 420)
        standardButtons: Dialog.Save | Dialog.Cancel
        Material.accent: Api.accent
        readonly property real minutes: Api.parseNum(prepMinutes.text)
        onAboutToShow: {
            const p = page.prepMeeting ? page.prepMeeting.prep : null
            prepMinutes.text = p ? String(p.minutes) : "30"
            prepText.text = p ? p.text || "" : ""
        }
        onAccepted: page.savePrep(page.prepMeeting, Math.round(minutes), prepText.text.trim())
        contentItem: ColumnLayout {
            spacing: 8
            Caption { text: qsTr("Prep minutes (0–480)") }
            TextField {
                id: prepMinutes
                inputMethodHints: Qt.ImhDigitsOnly
                Layout.fillWidth: true
                Accessible.name: qsTr("Prep minutes")
            }
            Caption { text: qsTr("What to prepare") }
            TextField {
                id: prepText
                maximumLength: 500
                Layout.fillWidth: true
                Accessible.name: qsTr("What to prepare")
            }
            Label {
                visible: !(prepDialog.minutes >= 0 && prepDialog.minutes <= 480)
                text: qsTr("Minutes must be a number from 0 to 480")
                color: Api.warnColor
                font.pixelSize: 12
                Layout.fillWidth: true
            }
        }
    }

    // a small action button inside an event row
    component Tiny: Button {
        id: tiny
        flat: true
        implicitHeight: 36
        leftPadding: 10
        rightPadding: 10
        font.pixelSize: 13
        Accessible.name: text
        Accessible.role: Accessible.Button
        background: Rectangle {
            radius: 6
            color: tiny.down ? Qt.alpha(Api.accent, 0.18) : "transparent"
            border.color: Api.line
        }
    }

    // ---- layout -------------------------------------------------------------------------------------

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
                Accessible.name: qsTr("Previous day")
                Accessible.role: Accessible.Button
                onClicked: page.step(-1)
            }
            ColumnLayout {
                spacing: 0
                Layout.fillWidth: true
                Label {
                    text: page.day ? page.fmtDate(page.day.date) : qsTr("Day")
                    font.pixelSize: 18
                    font.weight: Font.Bold
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth: true
                }
                Label {
                    text: page.subLine(page.day)
                    visible: text !== ""
                    color: Api.muted
                    font.pixelSize: 11
                    wrapMode: Text.Wrap
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth: true
                }
            }
            ToolButton {
                text: qsTr("Today")
                Accessible.name: qsTr("Back to today")
                Accessible.role: Accessible.Button
                onClicked: page.show("")
            }
            ToolButton {
                text: "›"
                font.pixelSize: 22
                implicitWidth: 48
                Accessible.name: qsTr("Next day")
                Accessible.role: Accessible.Button
                onClicked: page.step(1)
            }
        }
        RowLayout {
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            Layout.fillWidth: true
            spacing: 8
            Button {
                text: qsTr("Refresh")
                flat: true
                Material.foreground: Api.accent
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Ask the host sync to refresh the snapshots")
                Accessible.name: text
                onClicked: page.refreshSnapshots()
            }
            Item { Layout.fillWidth: true }
            Button {
                text: qsTr("Add")
                flat: true
                Material.foreground: Api.accent
                Accessible.name: qsTr("Add a meeting or appointment at a time you know")
                onClicked: page.addRequested()
            }
            Button {
                text: qsTr("Find a date")
                flat: true
                Material.foreground: Api.accent
                Accessible.name: text
                onClicked: page.findRequested()
            }
        }

        NoticeBanner {
            visible: page.error !== ""
            text: page.day ? qsTr("Error: %1").arg(page.error) : page.error
            level: "error"
        }
        NoticeBanner {
            visible: page.info !== ""
            text: page.info
            level: "info"
            tappable: true
            onTapped: page.info = ""
        }
        NoticeBanner {
            visible: !!page.day && page.day.capacity.show
            level: page.day && page.day.capacity.colour === "red" ? "error" : page.day && page.day.capacity.colour === "amber" ? "warn" : "info"
            text: page.day ? qsTr("Load %1").arg(page.day.capacity.colour) + String(page.day.capacity.line || "").replace(/^[^A-Za-z]*Capacity:\s*\w+\.\s*/, " · ") : ""
        }

        Card {
            title: qsTr("Timeline")
            visible: page.day !== null

            Flow {
                spacing: 6
                Layout.fillWidth: true
                Repeater {
                    model: page.lanes
                    delegate: AbstractButton {
                        id: laneChip
                        required property var modelData
                        readonly property bool on: page.laneOn(modelData.value)
                        text: modelData.label
                        implicitHeight: 32
                        leftPadding: 12
                        rightPadding: 12
                        Accessible.role: Accessible.CheckBox
                        Accessible.name: modelData.label
                        Accessible.checkable: true
                        Accessible.checked: on
                        Accessible.onPressAction: laneChip.clicked()
                        onClicked: page.toggleLane(modelData.value)
                        contentItem: Label {
                            text: laneChip.text
                            color: laneChip.on ? Api.accentFg : Api.fg
                            font.pixelSize: 13
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                        background: Rectangle {
                            radius: 16
                            color: laneChip.on ? page.laneColor(laneChip.modelData.value) : "transparent"
                            border.color: laneChip.on ? "transparent" : Api.line
                        }
                    }
                }
            }
            Label {
                visible: page.mirrorNote(page.day) !== ""
                text: page.mirrorNote(page.day)
                color: Api.warnColor
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: page.day !== null && page.rows.filter(r => !r.now).length === 0
                text: qsTr("Nothing on the calendars for this day.")
                color: Api.muted
                Layout.fillWidth: true
            }
            Repeater {
                model: page.rows
                delegate: Loader {
                    id: tl
                    required property var modelData
                    Layout.fillWidth: true
                    sourceComponent: modelData.now !== undefined ? nowRow : eventRow
                    Component {
                        id: nowRow
                        RowLayout {
                            spacing: 8
                            Rectangle { height: 2; color: Api.errorColor; Layout.fillWidth: true }
                            Label { text: qsTr("now %1").arg(tl.modelData.now); color: Api.errorColor; font.pixelSize: 12; font.weight: Font.DemiBold }
                            Rectangle { height: 2; color: Api.errorColor; Layout.fillWidth: true }
                        }
                    }
                    Component {
                        id: eventRow
                        Rectangle {
                            id: evRow
                            readonly property var ev: tl.modelData.ev
                            readonly property string lane: tl.modelData.lane
                            readonly property var hh: page.day.household || { me: "me", partner: "partner", child: "child" }
                            implicitHeight: evCol.implicitHeight + 16
                            radius: 8
                            color: ev.cancelled ? "transparent" : Qt.alpha(page.laneColor(lane), 0.1)
                            border.color: Qt.alpha(page.laneColor(lane), 0.4)
                            Rectangle { x: 0; width: 4; height: parent.height; radius: 2; color: page.laneColor(evRow.lane) }
                            ColumnLayout {
                                id: evCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: 8
                                anchors.leftMargin: 14
                                spacing: 2
                                Label {
                                    text: page.laneName(evRow.lane).toUpperCase()
                                    color: page.laneColor(evRow.lane)
                                    font.pixelSize: 10
                                    font.weight: Font.Bold
                                    font.letterSpacing: 0.6
                                }
                                Label {
                                    text: page.eventLabel(evRow.ev)
                                    font.strikeout: !!evRow.ev.cancelled
                                    wrapMode: Text.Wrap
                                    Layout.fillWidth: true
                                    Accessible.name: text
                                }
                                Flow {
                                    spacing: 4
                                    Layout.fillWidth: true
                                    // whose is this? four choices, each asking "only this one / always / cancel"
                                    Repeater {
                                        model: evRow.ev.layer === "personal" && !evRow.ev.pending
                                               && (evRow.ev.classification === "unclassified" || page.reopened.indexOf(page.evKey(evRow.ev)) >= 0)
                                               ? [{ cls: "mine", text: qsTr("me") }, { cls: "family", text: qsTr("us") },
                                                  { cls: "partner", text: evRow.hh.partner }, { cls: "child", text: evRow.hh.child }] : []
                                        delegate: Tiny {
                                            id: who
                                            required property var modelData
                                            text: modelData.text
                                            Accessible.name: qsTr("%1: whose is \"%2\"?").arg(modelData.text).arg(evRow.ev.title)
                                            onClicked: page.ask(evRow.ev, modelData.cls, modelData.text)
                                        }
                                    }
                                    Tiny {
                                        visible: evRow.ev.layer === "personal" && evRow.ev.lane === "family" && evRow.ev.classification !== "unclassified"
                                                 && !evRow.ev.pending && page.reopened.indexOf(page.evKey(evRow.ev)) < 0
                                        text: qsTr("whose? change")
                                        onClicked: page.reopened = page.reopened.concat([page.evKey(evRow.ev)])   // shows the four choices again
                                    }
                                    Tiny {
                                        visible: page.canLog(evRow.ev)
                                        text: qsTr("Log")
                                        Accessible.description: qsTr("Add this meeting to the time log")
                                        onClicked: page.logMeeting(evRow.ev)
                                    }
                                    Tiny {
                                        visible: evRow.ev.layer === "protected" && evRow.ev.state === "proposed"
                                        text: "✓"
                                        Accessible.name: qsTr("Approve %1–%2 %3").arg(evRow.ev.start).arg(evRow.ev.end).arg(evRow.ev.title)
                                        onClicked: page.post("/api/balance/blocks/" + evRow.ev.id + "/approve")
                                    }
                                    Tiny {
                                        visible: evRow.ev.layer === "protected" && evRow.ev.state === "proposed"
                                        text: "✗"
                                        Accessible.name: qsTr("Reject %1–%2 %3").arg(evRow.ev.start).arg(evRow.ev.end).arg(evRow.ev.title)
                                        onClicked: page.post("/api/balance/blocks/" + evRow.ev.id + "/reject")
                                    }
                                    Tiny {
                                        visible: evRow.ev.layer === "duty"
                                        text: evRow.ev.owner === evRow.hh.me ? qsTr("%1 takes it").arg(evRow.hh.partner) : qsTr("I take it")
                                        onClicked: page.post("/api/day/owner", page.ownerBody(page.day, evRow.ev))
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        Card {
            title: qsTr("First things")
            visible: page.day !== null
            Repeater {
                model: page.day ? page.day.first_things : []
                delegate: RowLayout {
                    id: ft
                    required property var modelData
                    spacing: 10
                    Layout.fillWidth: true
                    Label {
                        text: ft.modelData.kind === "duty" ? ft.modelData.at : ft.modelData.kind === "meeting" ? ft.modelData.start : qsTr("now")
                        color: Api.muted
                        font.features: { "tnum": 1 }
                        Layout.alignment: Qt.AlignTop
                        Layout.preferredWidth: 44
                    }
                    ColumnLayout {
                        spacing: 2
                        Layout.fillWidth: true
                        Label {
                            text: ft.modelData.kind === "duty" ? ft.modelData.title + " · " + (ft.modelData.owner || qsTr("who?"))
                                : ft.modelData.kind === "meeting" ? ft.modelData.title
                                : ft.modelData.tasks.length > 0 ? qsTr("%n urgent", "", ft.modelData.tasks.length) : qsTr("Nothing urgent")
                            font.weight: Font.DemiBold
                            wrapMode: Text.Wrap
                            Layout.fillWidth: true
                        }
                        Label {
                            visible: ft.modelData.kind === "duty"
                            text: ft.modelData.fit_line || ""
                            color: ft.modelData.fits === false ? Api.warnColor : Api.muted
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                            Layout.fillWidth: true
                        }
                        Label {
                            visible: ft.modelData.kind === "meeting"
                            readonly property var prep: ft.modelData.prep
                            text: prep ? qsTr("Prep: %1 · %2 min · start by %3").arg(prep.text || qsTr("(no text)")).arg(prep.minutes).arg(prep.start_by)
                                       : qsTr("No prep note yet.")
                            color: Api.muted
                            font.pixelSize: 12
                            wrapMode: Text.Wrap
                            Layout.fillWidth: true
                        }
                        Tiny {
                            visible: ft.modelData.kind === "meeting"
                            text: ft.modelData.prep ? qsTr("Edit prep") : qsTr("Add prep")
                            onClicked: { page.prepMeeting = ft.modelData; prepDialog.open() }
                        }
                        Repeater {
                            model: ft.modelData.kind === "urgent" ? ft.modelData.tasks : []
                            delegate: TaskRow { Layout.fillWidth: true }
                        }
                    }
                }
            }
        }

        Card {
            title: qsTr("Training")
            visible: page.day !== null
            actions: Label {
                visible: !!(page.day && page.day.training && page.day.training.easy_week)
                text: qsTr("easy week")
                color: Api.workColor
                font.pixelSize: 12
                font.weight: Font.DemiBold
            }
            Label {
                visible: !!page.day && !page.day.training
                text: qsTr("Rest day, nothing planned.")
                color: Api.muted
                Layout.fillWidth: true
            }
            RowLayout {
                visible: !!page.day && !!page.day.training
                spacing: 10
                Layout.fillWidth: true
                Label { text: page.day && page.day.training ? page.day.training.time : ""; color: Api.muted; font.features: { "tnum": 1 }; Layout.alignment: Qt.AlignTop }
                ColumnLayout {
                    spacing: 2
                    Layout.fillWidth: true
                    Label {
                        readonly property var t: page.day ? page.day.training : null
                        text: t ? t.session + (t.distance_km ? " · " + qsTr("%1 km").arg(t.distance_km) : "") : ""
                        font.weight: Font.DemiBold
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                    Label {
                        readonly property var t: page.day ? page.day.training : null
                        text: t ? (t.block_state ? qsTr("block %1").arg(t.block_state) : qsTr("no block yet (Sunday proposes one)")) : ""
                        color: Api.muted
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                }
            }
        }

        Card {
            id: workCard
            title: qsTr("Work today")
            visible: page.day !== null
            readonly property var w: page.day ? page.day.work : null
            readonly property var st: w && w.status ? w.status : ({})
            readonly property real expected: st.today && st.today.expected_h ? st.today.expected_h : 0
            readonly property bool over: st.state === "working" && st.past_stop_min > 0
            actions: Label {
                text: workCard.w ? qsTr("week %1 of %2–%3 h").arg(page.h2(workCard.w.week_h)).arg(workCard.w.band[0]).arg(workCard.w.band[1]) : ""
                color: Api.muted
                font.pixelSize: 12
            }
            Rectangle {
                Layout.fillWidth: true
                height: 8
                radius: 4
                color: Api.line2
                Rectangle {
                    width: workCard.expected > 0 && workCard.w && workCard.w.today_h !== null && workCard.w.today_h !== undefined
                           ? parent.width * Math.min(1, workCard.w.today_h / workCard.expected) : 0
                    height: parent.height
                    radius: 4
                    color: workCard.over ? Api.errorColor : Api.workColor
                }
            }
            Label {
                readonly property var w: workCard.w
                text: !w ? "" : (w.today_h !== null && w.today_h !== undefined ? qsTr("Today %1").arg(page.h2(w.today_h)) + (workCard.expected ? qsTr(" of %1").arg(page.h2(workCard.expected)) : "") + " · " : "")
                      + (workCard.over ? qsTr("past your %1 stop by %2").arg(w.hard_stop).arg(page.h2(workCard.st.past_stop_min / 60))
                         : w.left_before_stop_h === null || w.left_before_stop_h === undefined ? qsTr("work calendar unknown, hours left not computed")
                         : qsTr("about %1 left before the %2 stop").arg(page.h2(w.left_before_stop_h)).arg(w.hard_stop))
                color: workCard.over ? Api.errorColor : Api.muted
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Caption { text: qsTr("Top 3") }
            Label {
                visible: !!workCard.w && workCard.w.top3.length === 0
                text: qsTr("No work tasks due today.")
                color: Api.muted
                Layout.fillWidth: true
            }
            Repeater {
                model: workCard.w ? workCard.w.top3 : []
                delegate: TaskRow { Layout.fillWidth: true }
            }
            Caption { text: qsTr("Milestones") }
            Label {
                visible: !!workCard.w && workCard.w.milestones.length === 0
                text: qsTr("No dated milestones (label them `milestone` in Todoist).")
                color: Api.muted
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Repeater {
                model: workCard.w ? workCard.w.milestones : []
                delegate: RowLayout {
                    id: mrow
                    required property var modelData
                    spacing: 8
                    Layout.fillWidth: true
                    Label {
                        text: Api.mdHtml(mrow.modelData.content)
                        textFormat: Text.StyledText
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                        onLinkActivated: link => Qt.openUrlExternally(link)
                    }
                    Label {
                        visible: !!mrow.modelData.due
                        text: mrow.modelData.due ? page.fmtDate(mrow.modelData.due) + " · " + qsTr("%1 d").arg(mrow.modelData.days_left) : ""
                        color: Api.muted
                        font.pixelSize: 12
                    }
                }
            }
        }

        Card {
            title: qsTr("Work calendar")
            visible: page.day !== null
            actions: Label {
                text: page.day ? (page.day.mirror.last_import_end ? qsTr("covered to %1").arg(page.fmtDate(page.day.mirror.last_import_end)) : qsTr("no PDF imported yet")) : ""
                color: Api.muted
                font.pixelSize: 12
            }
            Label {
                readonly property var m: page.day ? page.day.mirror : null
                text: !m ? "" : m.unknown ? qsTr("This day is past the last Outlook export: meetings unknown, free slots not to be trusted.")
                      : m.stale_days === null || m.stale_days === undefined ? ""
                      : qsTr("Last export %1. Meetings added since come from you or the PA.")
                        .arg(m.stale_days === 0 ? qsTr("today") : m.stale_days === 1 ? qsTr("yesterday") : qsTr("%1 days ago").arg(m.stale_days))
                color: Api.muted
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }

        Card {
            title: qsTr("Pending writes")
            visible: !!page.day && page.day.queue.length > 0
            Repeater {
                model: page.day ? page.day.queue : []
                delegate: ColumnLayout {
                    id: qrow
                    required property var modelData
                    spacing: 0
                    Layout.fillWidth: true
                    Label { text: qrow.modelData.line; wrapMode: Text.Wrap; Layout.fillWidth: true }
                    Label {
                        text: qrow.modelData.status === "failed" ? qsTr("failed: %1").arg(qrow.modelData.error) : qsTr("pending")
                        color: qrow.modelData.status === "failed" ? Api.errorColor : Api.muted
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                    RowLayout {
                        visible: qrow.modelData.status === "failed"
                        Tiny { text: qsTr("Retry"); onClicked: page.post("/api/balance/queue/" + qrow.modelData.id + "/retry") }
                        Tiny { text: qsTr("Dismiss"); onClicked: page.post("/api/balance/queue/" + qrow.modelData.id + "/dismiss") }
                    }
                }
            }
        }

        Label {
            visible: page.day !== null
            text: page.countsLine(page.day)
            color: Api.muted
            font.pixelSize: 12
            wrapMode: Text.Wrap
            Layout.leftMargin: 16
            Layout.rightMargin: 16
            Layout.fillWidth: true
        }
        Item { implicitHeight: 12 }
    }

    // a Todoist task: tick it to complete (queued for the host), its text keeps the links
    component TaskRow: RowLayout {
        id: task
        required property var modelData
        spacing: 4
        CheckBox {
            checked: !!task.modelData.done
            enabled: !task.modelData.done
            Accessible.name: qsTr("Done: %1").arg(Api.mdPlain(task.modelData.content))
            onToggled: page.completeTask(task.modelData.id)
        }
        Label {
            text: Api.mdHtml(task.modelData.content) + (task.modelData.pending ? " · " + qsTr("pending") : "")
                  + (task.modelData.priority === 4 ? " · P1" : "")
            textFormat: Text.StyledText
            font.strikeout: !!task.modelData.done
            wrapMode: Text.Wrap
            Layout.fillWidth: true
            onLinkActivated: link => Qt.openUrlExternally(link)
        }
    }
}
