pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtQuick.Dialogs
import QtCore
import WorkLogApp

// The Day planner (the web's Day page, `day.js` / `templates/day.html`, API in `day/web.py`): one day's
// timeline of work meetings, personal and family events, the child's duties and protected blocks, the
// first things to do, training, work today, and the writes that still wait for the host, in three parts
// as the Week screen's (Day · Work · Sync; the web's day.html has the same panes). Needs the
// planner's balance store on the server; without it the page shows the server's message (503).
// The timeline is one list sorted by start, as the web does on a phone, with a pill for the lane.
// Move (MoveDialog), the work-calendar PDF upload, the timer row and "work on this" are here too, as on the web.
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
                                  { value: "blocks", label: qsTr("Week blocks") }]
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
            label += ev.owner ? " · " + ev.owner : " · " + qsTr("who does it?")
        if (ev.layer === "personal" && ev.classification === "unclassified")
            label += " · " + qsTr("whose is it?")
        if (ev.layer === "personal" && ev.creator_name && ev.lane !== "personal")
            label += " · " + qsTr("by %1").arg(ev.creator_name)
        if (ev.layer === "work" && ev.source && ev.source !== "pdf" && !/\.pdf$/i.test(ev.source))
            label += " · " + qsTr("added by %1").arg(ev.source)
        if (ev.layer === "protected")
            label += " · " + ev.state
        if (ev.pending)
            label += " · " + qsTr("waiting to sync")
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
    // the Sync tab's first line: when the snapshots were made
    function subLine(d) {
        if (!d)
            return ""
        const full = d.sync && (d.sync.full_ran || d.sync.ran)
        return full ? qsTr("snapshots %1 · google %2").arg(String(full).replace("T", " ").slice(0, 16)).arg(d.sync.google || "?")
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
    // ---- the three parts and their figures -----------------------------------------------------------
    property string view: "day"      // "day" | "work" | "sync": the part of the page that shows (not remembered, as Week)
    // the Sync tab's label: what waits to be written, else that the work calendar is out of date
    function syncLabel(d) {
        if (!d)
            return qsTr("Sync")
        const n = d.queue ? d.queue.length : 0
        return n > 0 ? qsTr("Sync: %1").arg(n) : d.mirror && mirrorNote(d) !== "" ? qsTr("Sync: stale") : qsTr("Sync")
    }
    // the Day tiles: meetings still to come, tasks done of all
    function meetingsTile(d) {
        const n = d && d.counts ? d.counts.meetings_left : null
        return n === null || n === undefined ? "–" : String(n)
    }
    function tasksTile(d) { return d && d.counts ? d.counts.done + " / " + (d.counts.done + d.counts.todo) : "–" }
    // "2 family events to classify" ("" when there are none)
    function classifyLine(d) {
        const n = d && d.counts ? d.counts.unclassified : 0
        return !n ? "" : n === 1 ? qsTr("1 family event to classify") : qsTr("%1 family events to classify").arg(n)
    }
    // the work card's figures
    readonly property var work: day && day.work ? day.work : null
    readonly property var wst: work && work.status ? work.status : ({})
    readonly property real expectedH: wst.today && wst.today.expected_h ? wst.today.expected_h : 0
    readonly property bool overStop: wst.state === "working" && wst.past_stop_min > 0
    readonly property string timerNow: timerState(day)
    readonly property color tone: overStop ? Api.warnColor : timerNow === "working" ? Api.workColor
                                : timerNow === "break" ? Api.breakColor : Api.idleColor
    readonly property color toneBg: overStop ? Api.warnBg : timerNow === "working" ? Api.workBg
                                  : timerNow === "break" ? Api.breakBg : Api.card
    // the "Before stop" tile: the time left before the hard stop, or how far past it
    function stopTile(d) {
        const w = d && d.work ? d.work : null
        const s = w && w.status ? w.status : {}
        if (!w)
            return "–"
        if (s.state === "working" && s.past_stop_min > 0)
            return h2(s.past_stop_min / 60)
        return w.left_before_stop_h === null || w.left_before_stop_h === undefined ? "–" : h2(w.left_before_stop_h)
    }
    function stopNote(d) {
        const w = d && d.work ? d.work : null
        if (!w)
            return ""
        return (w.left_before_stop_h === null || w.left_before_stop_h === undefined) && !(w.status && w.status.state === "working" && w.status.past_stop_min > 0)
               ? qsTr("work calendar unknown") : qsTr("stop %1").arg(w.hard_stop)
    }
    function fmtDate(iso) { return Api.parseDate(iso).toLocaleDateString(Api.locale, "ddd d MMM") }

    // ---- the timer row and "work on this" (day.js: renderWork, taskRow) ------------------------------
    // the work card's status ("working" | "break" | "stopped"; "none" when the server sent no status)
    function timerState(d) {
        const w = d && d.work ? d.work : null
        return w && w.status ? (w.status.state || "stopped") : "none"
    }
    // "Working · meeting · project · since 09:12", "Break · since 10:30" or "Not working"
    function timerLine(d) {
        const s = d && d.work && d.work.status ? d.work.status : {}
        const st = timerState(d)
        return st === "working" ? qsTr("Working") + (s.block && s.block.type ? " · " + s.block.type : "")
                                  + (s.block && s.block.project ? " · " + s.block.project : "") + " · " + qsTr("since %1").arg(s.since || "")
             : st === "break" ? qsTr("Break · since %1").arg(s.since || "") : qsTr("Not working")
    }
    // the type chips (today only, at most six)
    function chipTypes(d) {
        const s = d && d.work && d.work.status ? d.work.status : null
        return d && d.is_today && s && s.chips ? (s.chips.types || []).slice(0, 6) : []
    }
    // a Todoist task's text as the block's project: markdown links flattened, 80 characters
    function plainTitle(content) { return Api.mdPlain(String(content || "")).trim().slice(0, 80) }
    // What "work on this" sends: the running block is retitled in place, otherwise the timer starts on the task
    // (with the type picked while stopped). { method, path, body }
    function workOnRequest(d, task, pendingType) {
        const st = d && d.work && d.work.status ? d.work.status : null
        const project = plainTitle(task.content)
        if (st && st.state === "working" && st.block)
            return { method: "PUT", path: "/api/blocks/" + st.block.id, body: { project: project, require_open: true } }
        return { method: "POST", path: "/api/start", body: pendingType ? { project: project, type: pendingType } : { project: project } }
    }

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

    // the type chip picked while the timer is stopped; the next Start uses it
    property string pendingType: ""
    property bool timerBusy: false
    function timerDone() { timerBusy = false }
    function timerFailed(e) { timerBusy = false; error = e }
    function timerQueued() { timerBusy = false; info = qsTr("Saved offline, it is sent when the server answers") }
    function startTimer() {
        if (timerBusy) return
        timerBusy = true
        const body = pendingType ? { type: pendingType } : {}
        pendingType = ""
        Api.timerAction("/api/start", body, timerDone, timerFailed, timerQueued)
    }
    function pauseTimer() {
        if (timerBusy) return
        timerBusy = true
        Api.timerAction("/api/pause", {}, timerDone, timerFailed, timerQueued)
    }
    function stopTimer() {
        if (timerBusy) return
        timerBusy = true
        Api.timerAction("/api/stop", {}, timerDone, timerFailed, timerQueued)
    }
    // a type chip: retypes the running block, or picks the type for the next Start
    function pickType(name) {
        const st = day && day.work ? day.work.status : null
        if (st && st.state === "working" && st.block)
            Api.request("PUT", "/api/blocks/" + st.block.id, { type: name, require_open: true }, null, e => page.error = e)
        else
            pendingType = pendingType === name ? "" : name
    }
    function workOn(task) {
        if (timerBusy || !day) return
        const r = workOnRequest(day, task, pendingType)
        if (r.method === "PUT") {
            Api.request("PUT", r.path, r.body, null, e => page.error = e)
        } else {
            timerBusy = true
            pendingType = ""
            Api.timerAction(r.path, r.body, timerDone, timerFailed, timerQueued)
        }
    }

    // ---- Move and the PDF upload ---------------------------------------------------------------
    function openMove(kind, id, uid) { moveDialog.openFor(day, kind, id, uid) }
    property alias moveDialogItem: moveDialog   // tests
    MoveDialog {
        id: moveDialog
        onMoved: date => page.show(date)
    }

    // The Outlook calendar PDF goes into the planner's inbox (POST /api/day/calendar-pdf, 12 MB at most);
    // the host job imports it within 15 minutes.
    property alias uploaderItem: uploader   // tests
    function uploadPdf(fileUrl) {
        info = ""
        error = ""
        uploader.upload(Api.baseUrl + "/api/day/calendar-pdf", Api.authHeader(), fileUrl, "file", 12 * 1024 * 1024)
    }
    FileUploader {
        id: uploader
        onFinished: out => { page.info = qsTr("Saved %1: %2.").arg(out.saved).arg(out.note) }
        onFailed: msg => { page.info = ""; page.error = qsTr("Upload failed: %1").arg(msg) }
    }
    FileDialog {
        id: pdfDialog
        title: qsTr("Upload Outlook PDF")
        fileMode: FileDialog.OpenFile
        nameFilters: [qsTr("PDF files (*.pdf)")]
        onAccepted: page.uploadPdf(selectedFile)
    }
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

    AppDialog {
        id: classifyDialog
        parent: Overlay.overlay
        modal: true
        title: page.askEv ? qsTr("Mark \"%1\" as %2?").arg(page.askEv.title).arg(page.askWho) : ""
        width: Math.min(parent ? parent.width - 32 : 320, 420)
        Material.accent: Api.accent
        // Esc or a tap outside is Cancel: nothing is saved
        onRejected: page.askEv = null
        contentItem: ScrollBody {
            spacing: 12
            Label {
                text: qsTr("Save it for this occurrence only, or for every event with this title. Esc or Cancel saves nothing.")
                wrapMode: Text.Wrap
                color: Api.muted
                Layout.fillWidth: true
            }
            AppButton {
                text: qsTr("Only this one")
                primary: true
                Accessible.name: text
                Layout.fillWidth: true
                onClicked: page.answer("once")
            }
            AppButton {
                text: qsTr("Always for this title")
                Accessible.name: text
                Layout.fillWidth: true
                onClicked: page.answer("always")
            }
            AppButton {
                text: qsTr("Cancel")
                flat: true
                Accessible.name: text
                Layout.fillWidth: true
                onClicked: { classifyDialog.close(); page.askEv = null }
            }
        }
    }

    property var prepMeeting: null
    AppDialog {
        id: prepDialog
        parent: Overlay.overlay
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
        contentItem: ScrollBody {
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

    // the small text actions of an event row: the shared flat button
    component Tiny: AppButton {
        flat: true
        font.pixelSize: 13
        Accessible.name: text
        Accessible.role: Accessible.Button
    }

    // ---- layout -------------------------------------------------------------------------------------
    // As the Week screen: the stepper, the banners, then three parts of which one shows (Day · Work · Sync).
    // Inside a part the Timer's shape: a hero card (radius 14), tiles, cards.

    // a figure with a line under it, as the Timer's tiles
    component StatTile: Tile {
        id: stat
        property string value
        property string sub: ""
        property color ink: Api.fg
        Layout.fillWidth: true
        Layout.fillHeight: true
        Layout.preferredWidth: 1
        Label {
            text: stat.value
            color: stat.ink
            font.pixelSize: 22
            font.weight: Font.Bold
            font.features: { "tnum": 1 }
            fontSizeMode: Text.HorizontalFit   // "3 h 10" in a third of a 320 dp screen
            minimumPixelSize: 13
            Layout.fillWidth: true
        }
        Label {
            visible: text !== ""
            text: stat.sub
            color: Api.muted
            font.pixelSize: 12
            wrapMode: Text.Wrap
            Layout.fillWidth: true
        }
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
                name: qsTr("Previous day")
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
                    text: page.day ? Api.relDay(page.day.date, Api.today()) : ""
                    visible: text !== ""
                    color: Api.muted
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth: true
                }
            }
            AppButton {
                flat: true
                text: qsTr("Today")
                Accessible.name: qsTr("Back to today")
                Accessible.role: Accessible.Button
                onClicked: page.show("")
            }
            AppIconButton {
                text: "›"
                name: qsTr("Next day")
                onClicked: page.step(1)
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
            text: page.day ? qsTr("Load: %1").arg(page.day.capacity.colour) + String(page.day.capacity.line || "").replace(/^[^A-Za-z]*Capacity:\s*\w+\.\s*/, " · ") : ""
        }

        // the three parts; what waits to be synced stays in sight on the Sync tab's label
        RowLayout {
            visible: page.day !== null
            spacing: 8
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            Repeater {
                model: [
                    { key: "day", label: qsTr("Day") },
                    { key: "work", label: qsTr("Work") },
                    { key: "sync", label: page.syncLabel(page.day) }
                ]
                delegate: AppButton {
                    id: viewTab
                    required property var modelData
                    text: modelData.label
                    primary: page.view === modelData.key
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Accessible.name: modelData.label
                    Accessible.role: Accessible.PageTab
                    onClicked: page.view = viewTab.modelData.key
                }
            }
        }

        // ================= Day =================

        // ---- first up: the hero of the day ----
        Pane {
            visible: page.day !== null && page.view === "day"
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            padding: 16
            background: Rectangle {
                radius: 14
                color: Api.card
                border.color: Api.line
            }
            ColumnLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 8
                Label {
                    text: qsTr("First up")
                    font.pixelSize: 16
                    font.weight: Font.DemiBold
                    color: page.Material.accent
                    Layout.fillWidth: true
                }
                Label {
                    visible: !!page.day && page.day.first_things.length === 0
                    text: qsTr("Nothing first up.")
                    color: Api.muted
                    Layout.fillWidth: true
                }
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
                                text: ft.modelData.kind === "duty" ? ft.modelData.title + " · " + (ft.modelData.owner || qsTr("who does it?"))
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
        }

        // ---- the day in three figures (they were the counts line at the foot) ----
        RowLayout {
            visible: page.day !== null && page.view === "day"
            spacing: 12
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            StatTile { caption: qsTr("Meetings"); value: page.meetingsTile(page.day); sub: qsTr("left") }
            StatTile { caption: qsTr("Tasks"); value: page.tasksTile(page.day); sub: qsTr("done") }
            StatTile {
                caption: qsTr("Worked")
                value: page.work && page.work.today_h !== null && page.work.today_h !== undefined ? page.h2(page.work.today_h) : "–"
                sub: page.expectedH > 0 ? qsTr("of %1").arg(page.h2(page.expectedH)) : ""
                ink: page.overStop ? Api.errorColor : Api.fg
            }
        }

        Card {
            title: qsTr("Timeline")
            visible: page.day !== null && page.view === "day"
            actions: RowLayout {
                spacing: 0
                Tiny {
                    text: qsTr("Add")
                    Accessible.name: qsTr("Add a meeting or appointment at a time you know")
                    onClicked: page.addRequested()
                }
                Tiny {
                    text: qsTr("Find a date")
                    onClicked: page.findRequested()
                }
            }

            ChipMulti {
                model: page.lanes
                selected: page.lanes.map(l => l.value).filter(v => page.lanesOff.split(",").indexOf(v) < 0)
                onToggled: value => page.toggleLane(value)
            }
            Label {
                visible: text !== ""
                text: page.classifyLine(page.day)
                color: Api.warnColor
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
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
                        // as a row of the Week screen: a bar in the lane's colour, the line, the lane under it
                        RowLayout {
                            id: evRow
                            readonly property var ev: tl.modelData.ev
                            readonly property string lane: tl.modelData.lane
                            readonly property var hh: page.day.household || { me: "me", partner: "partner", child: "child" }
                            spacing: 8
                            Rectangle {
                                implicitWidth: 4
                                radius: 2
                                color: page.laneColor(evRow.lane)
                                opacity: evRow.ev.cancelled ? 0.4 : 1
                                Layout.fillHeight: true
                            }
                            ColumnLayout {
                                spacing: 0
                                Layout.fillWidth: true
                                Label {
                                    text: page.eventLabel(evRow.ev)
                                    font.strikeout: !!evRow.ev.cancelled
                                    color: evRow.ev.cancelled ? Api.faint : Api.fg
                                    wrapMode: Text.Wrap
                                    Layout.fillWidth: true
                                    Accessible.name: text
                                }
                                Label {
                                    text: page.laneName(evRow.lane)
                                    color: page.laneColor(evRow.lane)
                                    font.pixelSize: 12
                                    Layout.fillWidth: true
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
                                        text: qsTr("Whose?")
                                        Accessible.name: qsTr("Change whose \"%1\" is").arg(evRow.ev.title)
                                        onClicked: page.reopened = page.reopened.concat([page.evKey(evRow.ev)])   // shows the four choices again
                                    }
                                    Tiny {
                                        visible: page.canLog(evRow.ev)
                                        text: qsTr("Log")
                                        Accessible.description: qsTr("Add this meeting to the time log")
                                        onClicked: page.logMeeting(evRow.ev)
                                    }
                                    Tiny {
                                        visible: evRow.ev.layer === "personal" && !!evRow.ev.uid && !evRow.ev.pending
                                        text: qsTr("Move")
                                        Accessible.name: qsTr("Move %1").arg(evRow.ev.title)
                                        onClicked: page.openMove("personal", 0, evRow.ev.uid)
                                    }
                                    Tiny {
                                        visible: evRow.ev.layer === "protected" && evRow.ev.state === "approved" && !!evRow.ev.id
                                        text: qsTr("Move")
                                        Accessible.name: qsTr("Move %1–%2 %3").arg(evRow.ev.start).arg(evRow.ev.end).arg(evRow.ev.title)
                                        onClicked: page.openMove(evRow.ev.kind === "run" ? "run" : "block", evRow.ev.id, "")
                                    }
                                    AppIconButton {
                                        visible: evRow.ev.layer === "protected" && evRow.ev.state === "proposed"
                                        text: "✓"
                                        ink: Api.accent
                                        name: qsTr("Approve %1–%2 %3").arg(evRow.ev.start).arg(evRow.ev.end).arg(evRow.ev.title)
                                        onClicked: page.post("/api/balance/blocks/" + evRow.ev.id + "/approve")
                                    }
                                    AppIconButton {
                                        visible: evRow.ev.layer === "protected" && evRow.ev.state === "proposed"
                                        text: "✗"
                                        ink: Api.errorColor
                                        name: qsTr("Reject %1–%2 %3").arg(evRow.ev.start).arg(evRow.ev.end).arg(evRow.ev.title)
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
            title: qsTr("Training")
            visible: page.day !== null && page.view === "day"
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
                Tiny {
                    text: qsTr("Move")
                    Layout.alignment: Qt.AlignTop
                    Accessible.name: qsTr("Move the run: see where it fits")
                    onClicked: page.openMove("run", 0, "")
                }
            }
        }

        // ================= Work =================

        // ---- the timer: the hero, tinted by its state as on the Timer screen ----
        Pane {
            visible: page.day !== null && page.view === "work" && page.timerNow !== "none"
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            padding: 16
            background: Rectangle {
                radius: 14
                color: page.toneBg
                border.color: page.timerNow === "stopped" ? Api.line : Qt.alpha(page.tone, 0.3)
            }
            ColumnLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 8
                RowLayout {
                    spacing: 8
                    Layout.fillWidth: true
                    Rectangle {
                        implicitWidth: 10
                        implicitHeight: 10
                        radius: 5
                        Layout.alignment: Qt.AlignTop
                        Layout.topMargin: 8
                        color: page.timerNow === "working" ? Api.workColor
                             : page.timerNow === "break" ? Api.breakColor : Api.idleColor
                    }
                    Label {
                        text: page.timerLine(page.day)
                        font.pixelSize: 18
                        font.weight: Font.Bold
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                        Accessible.name: text
                    }
                }
                RowLayout {
                    spacing: 8
                    Layout.fillWidth: true
                    ActionButton {
                        visible: page.timerNow !== "working"
                        text: page.timerNow === "break" ? qsTr("Resume") : qsTr("Start")
                        subtext: page.pendingType !== "" ? page.pendingType : qsTr("work")
                        fill: Api.workColor
                        ink: Api.workFg
                        enabled: !page.timerBusy
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        onClicked: page.startTimer()
                    }
                    ActionButton {
                        visible: page.timerNow === "working"
                        text: qsTr("Pause")
                        subtext: qsTr("break")
                        fill: Api.breakColor
                        ink: Api.breakFg
                        enabled: !page.timerBusy
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        onClicked: page.pauseTimer()
                    }
                    ActionButton {
                        visible: page.timerNow !== "stopped"
                        text: qsTr("Stop")
                        subtext: qsTr("close block")
                        fill: Api.idleColor
                        ink: Api.card
                        enabled: !page.timerBusy
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        onClicked: page.stopTimer()
                    }
                }
                ChipRow {
                    id: typeChips
                    readonly property var blk: page.wst.block ? page.wst.block : null
                    visible: page.chipTypes(page.day).length > 0
                    label: qsTr("Type")
                    model: page.chipTypes(page.day)
                    current: page.timerNow === "working" ? (blk && blk.type ? blk.type : "") : page.pendingType
                    onPicked: value => page.pickType(value)
                }
            }
        }

        // ---- hours: today, what is left before the stop, the week ----
        GridLayout {
            visible: page.day !== null && page.view === "work"
            columns: page.availableWidth >= 720 ? 3 : 2
            columnSpacing: 12
            rowSpacing: 12
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            StatTile {
                caption: qsTr("Today")
                value: page.work && page.work.today_h !== null && page.work.today_h !== undefined ? page.h2(page.work.today_h) : "–"
                sub: page.expectedH > 0 ? qsTr("of %1").arg(page.h2(page.expectedH)) : ""
                Rectangle {   // progress towards today's expected hours
                    id: hoursBar
                    implicitHeight: 6
                    radius: 3
                    color: Api.line2
                    Layout.fillWidth: true
                    Rectangle {
                        width: page.expectedH > 0 && page.work && page.work.today_h !== null && page.work.today_h !== undefined
                               ? hoursBar.width * Math.min(1, page.work.today_h / page.expectedH) : 0
                        height: hoursBar.height
                        radius: 3
                        color: page.overStop ? Api.errorColor : Api.workColor
                    }
                }
            }
            StatTile {
                caption: page.overStop ? qsTr("Past stop") : qsTr("Before stop")
                value: page.stopTile(page.day)
                sub: page.stopNote(page.day)
                ink: page.overStop ? Api.errorColor : Api.fg
            }
            StatTile {
                caption: qsTr("Week")
                value: page.work ? page.h2(page.work.week_h) : "–"
                sub: page.work && page.work.band ? qsTr("normal %1–%2 h").arg(page.work.band[0]).arg(page.work.band[1]) : ""
            }
        }

        Card {
            title: qsTr("Top 3 tasks")
            visible: page.day !== null && page.view === "work"
            Label {
                visible: !!page.work && page.work.top3.length === 0
                text: qsTr("No work tasks due today.")
                color: Api.muted
                Layout.fillWidth: true
            }
            Repeater {
                model: page.work ? page.work.top3 : []
                delegate: TaskRow { Layout.fillWidth: true }
            }
        }

        Card {
            title: qsTr("Milestones")
            visible: page.day !== null && page.view === "work"
            Label {
                visible: !!page.work && page.work.milestones.length === 0
                text: qsTr("No dated milestones (label them `milestone` in Todoist).")
                color: Api.muted
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Repeater {
                model: page.work ? page.work.milestones : []
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

        // ================= Sync =================

        Card {
            title: qsTr("Snapshots")
            visible: page.day !== null && page.view === "sync"
            Label {
                text: page.subLine(page.day)
                color: Api.muted
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            AppButton {
                text: qsTr("Refresh")
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Ask the host sync to refresh the snapshots")
                Accessible.name: text
                onClicked: page.refreshSnapshots()
            }
        }

        Card {
            title: qsTr("Work calendar")
            visible: page.day !== null && page.view === "sync"
            Label {
                text: page.day ? (page.day.mirror.last_import_end ? qsTr("covered to %1").arg(page.fmtDate(page.day.mirror.last_import_end)) : qsTr("no PDF imported yet")) : ""
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                readonly property var m: page.day ? page.day.mirror : null
                visible: text !== ""
                text: !m ? "" : m.unknown ? qsTr("This day is past the last Outlook export: meetings unknown, free slots not to be trusted.")
                      : m.stale_days === null || m.stale_days === undefined ? ""
                      : qsTr("Last export %1. Meetings added since come from you or the PA.")
                        .arg(m.stale_days === 0 ? qsTr("today") : m.stale_days === 1 ? qsTr("yesterday") : qsTr("%1 days ago").arg(m.stale_days))
                color: Api.muted
                font.pixelSize: 12
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            AppButton {
                text: uploader.busy ? qsTr("Uploading…") : qsTr("Upload Outlook PDF")
                enabled: !uploader.busy
                Accessible.name: qsTr("Upload an Outlook calendar PDF export")
                onClicked: pdfDialog.open()
            }
        }

        Card {
            title: qsTr("Pending writes")
            visible: page.day !== null && page.view === "sync"
            Label {
                visible: !!page.day && page.day.queue.length === 0
                text: qsTr("Nothing waiting.")
                color: Api.muted
                Layout.fillWidth: true
            }
            Repeater {
                model: page.day ? page.day.queue : []
                delegate: ColumnLayout {
                    id: qrow
                    required property var modelData
                    spacing: 0
                    Layout.fillWidth: true
                    Label { text: qrow.modelData.line; wrapMode: Text.Wrap; Layout.fillWidth: true }
                    Label {
                        text: qrow.modelData.status === "failed" ? qsTr("failed: %1").arg(qrow.modelData.error) : qsTr("waiting to sync")
                        color: qrow.modelData.status === "failed" ? Api.errorColor : Api.muted
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                        Layout.fillWidth: true
                    }
                    RowLayout {
                        visible: qrow.modelData.status === "failed"
                        spacing: 8
                        AppButton {
                            text: qsTr("Retry")
                            Accessible.name: text
                            onClicked: page.post("/api/balance/queue/" + qrow.modelData.id + "/retry")
                        }
                        AppButton {
                            text: qsTr("Dismiss")
                            flat: true
                            Accessible.name: text
                            onClicked: page.post("/api/balance/queue/" + qrow.modelData.id + "/dismiss")
                        }
                    }
                }
            }
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
        ColumnLayout {
            spacing: 2
            Layout.fillWidth: true
            Label {
                text: Api.mdHtml(task.modelData.content) + (task.modelData.pending ? " · " + qsTr("waiting to sync") : "")
                      + (task.modelData.priority === 4 ? " · P1" : "")
                      + ((task.modelData.labels || []).indexOf("doubt") >= 0 ? " · " + qsTr("doubt") : "")
                textFormat: Text.StyledText
                font.strikeout: !!task.modelData.done
                wrapMode: Text.Wrap
                Layout.fillWidth: true
                onLinkActivated: link => Qt.openUrlExternally(link)
            }
            Tiny {
                visible: !task.modelData.done && !!page.day && page.day.is_today
                text: "▶ " + qsTr("work on this")
                Accessible.name: qsTr("Start the timer on this task")
                enabled: !page.timerBusy
                onClicked: page.workOn(task.modelData)
            }
        }
    }
}
