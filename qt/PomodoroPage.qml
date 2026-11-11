pragma ComponentBehavior: Bound
import QtQuick
import QtCore
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia

// A per-device countdown that offers to pause / resume the log at each interval, never acting on its own
// (the web's pomodoro.js). It keeps counting while another tab is shown.
ScrollView {
    id: page
    signal attention()   // an interval ended: the window should show this tab

    readonly property var defaults: ({ work: 25, brk: 5, long: 15, rounds: 4, beep: false })
    readonly property var presets: [[25, 5], [50, 10], [90, 15]]
    readonly property int minute: 60000
    readonly property string breakType: "pomo"   // dedicated break type, seeded by schema v4

    property var st: fresh(defaults)
    property real nowMs: Date.now()
    property int gen: 0          // bumped on every state change; a card built for an older state is dropped
    property var card: null      // {question, why, buttons: [{text, primary, fn}]}
    property var logStatus: null
    property real logFetchedAt: 0
    property bool logReachable: true
    property string error: ""
    property bool flashing: false

    Settings {
        id: store
        category: "pomodoro"
        property string state: ""
    }

    // ---- pure helpers ----------------------------------------------------------------

    function intOr(v, dflt, min) {
        const n = parseInt(v, 10)
        return isFinite(n) ? Math.max(min, n) : dflt
    }
    function cleanSettings(r) {
        r = r || {}
        return { work: intOr(r.work, defaults.work, 1), brk: intOr(r.brk, defaults.brk, 1),
                 long: intOr(r.long, defaults.long, 1), rounds: intOr(r.rounds, 0, 0), beep: !!r.beep }
    }
    function fresh(settings) {
        return { phase: "ready", endsAt: null, pausedLeft: null, round: 0, settings: settings || Object.assign({}, defaults) }
    }
    function phaseLength(s) { return s.phase === "work" ? s.settings.work : s.phase === "long" ? s.settings.long : s.settings.brk }
    function isLongAfter(round, rounds) { return rounds > 0 && round > 0 && round % rounds === 0 }
    function nextAfterWork(s) { return isLongAfter(s.round, s.settings.rounds) ? "long" : "break" }
    function isCounting(s) { return s.phase === "work" || s.phase === "break" || s.phase === "long" }
    function isAwaiting(s) { return s.phase === "awaiting_break" || s.phase === "awaiting_work" }
    function remainingMs(s, now) {
        return s.pausedLeft !== null ? s.pausedLeft : s.endsAt === null ? 0 : Math.max(0, s.endsAt - now)
    }
    function startPhase(s, phase, now) {
        const n = Object.assign({}, s, { phase: phase, pausedLeft: null })
        if (phase === "work")
            n.round = s.phase === "ready" ? 1 : s.phase === "awaiting_work" ? s.round + 1 : s.round
        n.endsAt = now + phaseLength(n) * minute
        return n
    }
    function fmtMS(ms) {
        const sec = Math.ceil(ms / 1000)
        return Api.pad(Math.floor(sec / 60)) + ":" + Api.pad(sec % 60)
    }
    function phaseLabel(s) {
        const n = s.settings.rounds
        switch (s.phase) {
        case "ready": return qsTr("Ready")
        case "work": return qsTr("Work · round %1").arg(s.round) + (n ? " " + qsTr("of %1").arg(n) : "")
        case "break": return qsTr("Break")
        case "long": return qsTr("Long break")
        case "awaiting_break": return isLongAfter(s.round, n) ? qsTr("Long break?") : qsTr("Break?")
        case "awaiting_work": return qsTr("Back to work?")
        }
        return ""
    }

    // ---- state -----------------------------------------------------------------------

    function save(s) {
        st = s
        store.state = JSON.stringify(s)
        notify(s)
    }
    // the OS reminds us when the running interval ends, in case the app is in the background by then
    function notify(s) {
        if (!isCounting(s) || s.endsAt === null)
            return Notifier.cancel()
        if (s.phase === "work")
            Notifier.schedule(s.endsAt, qsTr("Work interval done"),
                              isLongAfter(s.round, s.settings.rounds) ? qsTr("Time for a long break.") : qsTr("Time for a break."))
        else
            Notifier.schedule(s.endsAt, qsTr("Break over"), qsTr("Back to work?"))
    }
    function load() {
        let raw = null
        try { raw = JSON.parse(store.state) } catch (e) { /* unreadable → fresh */ }
        const s = Object.assign(fresh(), raw || {})
        s.settings = cleanSettings(s.settings)
        st = s
    }
    function applySettings(raw) {
        save(Object.assign({}, st, { settings: cleanSettings(raw) }))
    }
    function begin(phase) {
        gen++
        save(startPhase(st, phase, Date.now()))
    }

    function tick() {
        nowMs = Date.now()
        if (isCounting(st) && st.pausedLeft === null && remainingMs(st, nowMs) === 0)
            fire()
    }

    function fire() {
        save(Object.assign({}, st, { phase: st.phase === "work" ? "awaiting_break" : "awaiting_work", endsAt: null, pausedLeft: null }))
        flashing = true
        flashTimer.restart()
        if (st.settings.beep)
            beep.play()
        attention()
        showCard(st.phase === "awaiting_break" ? "work_end" : "break_end")
    }

    function onStart() {
        if (st.phase === "ready")
            showCard("start")
    }
    function onPause() {
        if (!isCounting(st))
            return
        const now = Date.now()
        if (st.pausedLeft === null)
            save(Object.assign({}, st, { pausedLeft: remainingMs(st, now), endsAt: null }))
        else
            save(Object.assign({}, st, { endsAt: now + st.pausedLeft, pausedLeft: null }))
    }
    function onPlus() {
        if (st.phase === "ready")
            return
        gen++
        const now = Date.now(), s = Object.assign({}, st)
        if (isAwaiting(s)) {
            // back into the phase that just ended, for five more minutes (the round is unchanged)
            s.phase = s.phase === "awaiting_break" ? "work" : nextAfterWork(s)
            s.endsAt = now + 5 * minute
            s.pausedLeft = null
            card = null
        } else if (s.pausedLeft !== null) {
            s.pausedLeft += 5 * minute
        } else {
            s.endsAt += 5 * minute
        }
        save(s)
    }
    function onReset() {
        gen++
        card = null
        save(fresh(st.settings))
    }

    // ---- log link --------------------------------------------------------------------

    function refreshLog(then) {
        Api.request("GET", "/api/status", undefined, function (s) {
            page.logStatus = s
            page.logFetchedAt = Date.now()
            page.logReachable = true
            if (then) then(s)
        }, function (e) {
            page.logStatus = null
            page.logReachable = false
            page.error = e
            if (then) then(null)
        })
    }

    // POST to the log, then carry on; what "resume work" logs is today's most recent work block
    function logAction(path, bodyFn, then) {
        bodyFn(function (body) {
            Api.request("POST", path, body, function () {
                page.error = ""
                refreshLog()
                then()
            }, function (e) {
                page.error = e
                then()
            })
        })
    }
    function lastWorkBody(cb) {
        Api.request("GET", "/api/day/" + Api.isoDate(new Date()), undefined, function (d) {
            const work = (d.blocks || []).filter(b => b.work_type === "work")
            const last = work[work.length - 1]
            cb(last ? { type: last.type, project: last.project || null } : undefined)
        }, () => cb(undefined))
    }
    function startWork(then) { logAction("/api/start", lastWorkBody, then) }
    function startBreak(then) { logAction("/api/pause", cb => cb({ type: page.breakType }), then) }

    // ---- confirm card ----------------------------------------------------------------

    function go(phase, action) {
        return function () {
            card = null
            gen++
            if (action)
                action(() => page.begin(phase))
            else
                begin(phase)
        }
    }
    function showCard(kind) {
        const g = gen
        refreshLog(function (log) {
            if (g !== page.gen)
                return
            const logState = log ? log.state : "unknown"
            const s = page.st
            if (kind === "start") {
                if (logState === "working")
                    return page.begin("work")
                if (logState === "break")
                    return page.card = { question: qsTr("Back to work in the log too?"), why: qsTr("A break is running in the log."),
                                         buttons: [{ text: qsTr("Resume work"), primary: true, fn: page.go("work", page.startWork) },
                                                   { text: qsTr("Just count"), fn: page.go("work") }] }
                return page.card = { question: qsTr("Also start a work block?"),
                                     why: logState === "stopped" ? qsTr("Nothing is running in the log.") : qsTr("The log could not be reached."),
                                     buttons: [{ text: qsTr("Start block"), primary: true, fn: page.go("work", page.startWork) },
                                               { text: qsTr("Just count"), fn: page.go("work") }] }
            }
            const next = s.phase === "awaiting_break" ? page.nextAfterWork(s) : "work"
            const question = s.phase === "awaiting_break"
                    ? (page.isLongAfter(s.round, s.settings.rounds) ? qsTr("Start long break?") : qsTr("Start break?"))
                    : qsTr("Back to work?")
            if (kind === "work_end") {
                if (logState === "break")
                    return page.card = { question: qsTr("Already on a break."), why: qsTr("The log is already paused."),
                                         buttons: [{ text: qsTr("Continue"), primary: true, fn: page.go(next) }] }
                if (logState === "stopped")
                    return page.card = { question: question, why: qsTr("Log is stopped, so nothing to pause."),
                                         buttons: [{ text: qsTr("Skip"), primary: true, fn: page.go(next) }] }
                return page.card = { question: question, why: "",
                                     buttons: [{ text: qsTr("Start break"), primary: true, fn: page.go(next, page.startBreak) },
                                               { text: qsTr("Skip"), fn: page.go(next) }] }
            }
            if (logState === "working")
                return page.card = { question: qsTr("Already working."), why: qsTr("The log is already on a work block."),
                                     buttons: [{ text: qsTr("Continue"), primary: true, fn: page.go(next) }] }
            page.card = { question: question, why: "",
                          buttons: [{ text: qsTr("Resume work"), primary: true, fn: page.go(next, page.startWork) },
                                    { text: qsTr("Skip"), fn: page.go(next) }] }
        })
    }

    Component.onCompleted: {
        load()
        refreshLog()
        if (isAwaiting(st))   // the app closed while a card was pending: show it again
            showCard(st.phase === "awaiting_break" ? "work_end" : "break_end")
    }
    Connections {
        target: Api
        function onChanged() { page.refreshLog() }
        function onServerChanged() { page.refreshLog() }
    }
    Timer { interval: 1000; running: true; repeat: true; onTriggered: page.tick() }
    Timer { interval: 60000; running: true; repeat: true; onTriggered: page.refreshLog() }
    Timer { id: flashTimer; interval: 2400; onTriggered: page.flashing = false }

    SoundEffect {
        id: beep
        source: "beep.wav"
    }

    // ---- view ------------------------------------------------------------------------

    readonly property real ms: isCounting(st) ? remainingMs(st, nowMs) : st.phase === "ready" ? st.settings.work * minute : 0
    readonly property real progress: isCounting(st) ? Math.min(1, 1 - ms / (phaseLength(st) * minute)) : isAwaiting(st) ? 1 : 0
    readonly property color tone: st.phase === "work" ? Api.workColor
                                : st.phase === "break" || st.phase === "long" ? Api.breakColor : Api.idleColor
    readonly property color toneBg: st.phase === "work" ? Api.workBg
                                  : st.phase === "break" || st.phase === "long" ? Api.breakBg : Api.card

    contentWidth: availableWidth

    // on a phone the card can sit below the fold: scroll it into view once it is laid out
    onCardChanged: if (card) revealTimer.restart()
    Timer {
        id: revealTimer
        interval: 50
        onTriggered: {
            const f = page.contentItem as Flickable
            const bottom = confirmCard.y + confirmCard.height + 12
            if (f && bottom > f.contentY + f.height)
                f.contentY = Math.max(0, Math.min(bottom - f.height, f.contentHeight - f.height))
        }
    }

    ColumnLayout {
        width: page.availableWidth
        spacing: 12

        Pane {
            Layout.fillWidth: true
            Layout.topMargin: 12
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            padding: 20
            background: Rectangle {
                radius: 14
                color: page.flashing ? Qt.alpha(page.tone, 0.45) : page.toneBg
                border.color: Qt.alpha(page.tone, 0.3)
                Behavior on color { ColorAnimation { duration: 400 } }
            }

            ColumnLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 6

                Label {
                    text: page.phaseLabel(page.st) + (page.st.pausedLeft !== null ? " · " + qsTr("paused") : "")
                    color: page.tone
                    font.pixelSize: 18
                    font.weight: Font.Bold
                    Layout.alignment: Qt.AlignHCenter
                }
                Label {
                    text: page.fmtMS(page.ms)
                    font.pixelSize: 64
                    font.weight: Font.Bold
                    font.features: { "tnum": 1 }
                    opacity: page.st.pausedLeft !== null ? 0.5 : 1
                    Layout.alignment: Qt.AlignHCenter
                }
                Rectangle {
                    implicitHeight: 6
                    radius: 3
                    color: Api.line2
                    Layout.fillWidth: true
                    Rectangle {
                        height: parent.height
                        radius: 3
                        width: parent.width * page.progress
                        color: page.tone
                    }
                }

                GridLayout {
                    columns: page.availableWidth >= 520 ? 4 : 2
                    columnSpacing: 8
                    rowSpacing: 8
                    Layout.fillWidth: true
                    Layout.topMargin: 10
                    ActionButton {
                        text: qsTr("Start")
                        subtext: qsTr("%1 min").arg(page.st.settings.work)
                        fill: Api.workColor
                        ink: Api.workFg
                        enabled: page.st.phase === "ready"
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        onClicked: page.onStart()
                    }
                    ActionButton {
                        text: page.st.pausedLeft !== null ? qsTr("Resume") : qsTr("Pause")
                        subtext: qsTr("countdown")
                        fill: Api.breakColor
                        ink: Api.breakFg
                        enabled: page.isCounting(page.st)
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        onClicked: page.onPause()
                    }
                    ActionButton {
                        text: qsTr("+5 min")
                        subtext: qsTr("extend")
                        fill: Api.accentBg
                        ink: Api.accent
                        enabled: page.st.phase !== "ready"
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        onClicked: page.onPlus()
                    }
                    ActionButton {
                        text: qsTr("Reset")
                        subtext: qsTr("back to ready")
                        fill: Api.idleColor
                        ink: Api.card
                        enabled: page.st.phase !== "ready"
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        onClicked: page.onReset()
                    }
                }
            }
        }

        NoticeBanner {
            visible: page.error !== ""
            text: qsTr("Error: %1").arg(page.error)
            level: "error"
        }

        // the question at the end of an interval
        Card {
            id: confirmCard
            visible: page.card !== null
            title: page.card ? page.card.question : ""
            Label {
                visible: !!page.card && page.card.why !== ""
                text: page.card ? page.card.why : ""
                color: Api.muted
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            RowLayout {
                spacing: 8
                Repeater {
                    model: page.card ? page.card.buttons : []
                    delegate: Button {
                        required property var modelData
                        text: modelData.text
                        highlighted: !!modelData.primary
                        flat: !modelData.primary
                        onClicked: modelData.fn()
                    }
                }
            }
        }

        Label {
            Layout.leftMargin: 16
            textFormat: Text.StyledText
            color: Api.muted
            text: {
                const s = page.logStatus
                if (!s)
                    return qsTr("Log: <b>%1</b>").arg(page.logReachable ? "…" : qsTr("unreachable"))
                if (s.state === "stopped")
                    return qsTr("Log: <b>stopped</b>")
                const b = s.block
                const min = s.elapsed_min + Math.floor((page.nowMs - page.logFetchedAt) / page.minute)
                return qsTr("Log: <b>%1</b>").arg(s.state === "working" ? qsTr("working") : qsTr("break"))
                       + " · " + Api.esc(b.type) + (b.project ? " · " + Api.esc(b.project) : "") + " · " + Api.fmtHM(min / 60)
            }
        }

        Card {
            title: qsTr("Lengths")

            ChipRow {
                label: qsTr("Presets")
                model: page.presets.map(p => p[0] + "/" + p[1])
                current: page.st.settings.work + "/" + page.st.settings.brk
                onPicked: value => {
                    const p = value.split("/")
                    page.applySettings(Object.assign({}, page.st.settings, { work: p[0], brk: p[1] }))
                }
            }

            GridLayout {
                columns: page.availableWidth >= 520 ? 4 : page.availableWidth >= 360 ? 2 : 1   // a SpinBox needs ~150 px for its digits
                columnSpacing: 12
                rowSpacing: 4
                Layout.fillWidth: true

                Repeater {
                    model: [{ key: "work", label: qsTr("Work min"), min: 1 }, { key: "brk", label: qsTr("Break min"), min: 1 },
                            { key: "long", label: qsTr("Long break min"), min: 1 }, { key: "rounds", label: qsTr("Rounds before long"), min: 0 }]
                    delegate: ColumnLayout {
                        id: field
                        required property var modelData
                        spacing: 2
                        Layout.fillWidth: true
                        Caption { text: field.modelData.label }
                        SpinBox {
                            from: field.modelData.min
                            to: 600
                            editable: true
                            value: page.st.settings[field.modelData.key]
                            Layout.fillWidth: true
                            onValueModified: {
                                const s = Object.assign({}, page.st.settings)
                                s[field.modelData.key] = value
                                page.applySettings(s)
                            }
                        }
                    }
                }
            }

            CheckBox {
                text: qsTr("Sound")
                checked: page.st.settings.beep
                onToggled: page.applySettings(Object.assign({}, page.st.settings, { beep: checked }))
            }
            Caption {
                text: qsTr("Changes apply from the next interval.")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
            }
        }
        Item { implicitHeight: 8 }
    }
}
