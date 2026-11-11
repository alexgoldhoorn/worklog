pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Start / pause / stop, the running totals and today's blocks.
ScrollView {
    id: page
    property var status: null
    property var day: null
    property real fetchedAt: 0   // Date.now() when `status` arrived; the clock ticks on locally
    property real nowMs: Date.now()
    property bool busy: false
    property string error: ""

    // the next block's type / project and the break type, picked with chips
    property string pendingType: ""
    property string pendingBreak: "eat"

    signal openDay(string date)

    readonly property string timerState: status ? status.state : "stopped"
    readonly property var runningBlock: status ? status.block : null
    readonly property int liveSec: runningBlock
                                   ? Math.max(0, (status.elapsed_s || 0) + Math.floor((nowMs - fetchedAt) / 1000)) : 0
    // hours of the running work block, on top of the closed totals the server sent
    readonly property real liveRunH: timerState === "working" ? liveSec / 3600 : 0
    readonly property real todayH: status ? status.today.work_h + liveRunH : 0
    readonly property real todayExpH: status ? status.today.expected_h || 0 : 0
    readonly property real weekH: status ? status.week.worked_h + liveRunH : 0
    readonly property real monthH: status ? status.month.worked_h + liveRunH : 0

    // minutes past the hard stop (balance settings) while today's work block runs. The server
    // sends past_stop_min only then (null otherwise); the clock here keeps it live between reloads.
    readonly property int pastStopMin: {
        if (timerState !== "working" || !status || status.past_stop_min === null
                || status.past_stop_min === undefined || !status.hard_stop)
            return 0
        const hm = status.hard_stop.split(":")
        const now = new Date(nowMs)
        return Math.max(0, now.getHours() * 60 + now.getMinutes() - (Number(hm[0]) * 60 + Number(hm[1])))
    }
    readonly property bool over: pastStopMin > 0

    readonly property color tone: over ? Api.warnColor : timerState === "working" ? Api.workColor
                                : timerState === "break" ? Api.breakColor : Api.idleColor
    readonly property color toneBg: over ? Api.warnBg : timerState === "working" ? Api.workBg
                                  : timerState === "break" ? Api.breakBg : Api.card
    readonly property bool wide: availableWidth >= 720

    contentWidth: availableWidth

    function reload() {
        Api.request("GET", "/api/status", undefined, function (s) {
            page.status = s
            page.fetchedAt = Date.now()
            page.error = ""
            if (s.state === "working" && s.block.work_type === "work" && s.block.source !== "calendar" && !projectField.activeFocus)
                projectField.text = s.block.project || ""
            Api.request("GET", "/api/day/" + s.date, undefined, d => page.day = d, e => page.error = e)
        }, e => page.error = e)
    }

    function action(path, body) {
        if (busy)
            return
        busy = true
        Api.request("POST", path, body, () => page.busy = false, function (e) {
            page.busy = false
            page.error = e
        })
    }

    // change the running block in place; a block closed meanwhile gets a 409, never retyped
    function retypeRunning(fields, what) {
        if (!runningBlock)
            return
        const b = runningBlock
        const undo = { require_open: true }
        for (const k in fields)
            undo[k] = b[k]
        fields.require_open = true
        Api.request("PUT", "/api/blocks/" + b.id, fields, function () {
            snackbar.show(what, function () {
                Api.request("PUT", "/api/blocks/" + b.id, undo, null, e => page.error = e)
            })
        }, e => page.error = e)
    }

    // "done at 17:07", "1:20 left" or "target met · +0.5 h"
    function todayTarget() {
        if (todayExpH <= 0)
            return qsTr("no hours expected today")
        const leftMin = Math.round((todayExpH - todayH) * 60)
        if (leftMin <= 0)
            return qsTr("target met · %1").arg(Api.fmtSigned(todayH - todayExpH))
        if (timerState === "working") {
            const d = new Date(nowMs + leftMin * 60000)
            return qsTr("done at %1").arg(Api.pad(d.getHours()) + ":" + Api.pad(d.getMinutes()))
        }
        return qsTr("%1 left").arg(Api.fmtHM(leftMin / 60))
    }

    Component.onCompleted: reload()
    onVisibleChanged: if (visible) reload()
    Connections {
        target: Api
        function onChanged() { page.reload() }
        function onServerChanged() { page.reload() }
    }
    Timer { interval: 1000; running: true; repeat: true; onTriggered: page.nowMs = Date.now() }
    Timer { interval: 60000; running: true; repeat: true; onTriggered: page.reload() }

    // keyboard shortcuts, as on the web's Timer page. A focused text field eats plain keys,
    // so they never fire while typing; the buttons' own enabled state covers busy and state.
    function press(button) {
        if (button.enabled)
            button.clicked()
    }
    Shortcut { sequences: ["S", "Shift+S"]; enabled: page.visible; onActivated: page.press(startButton) }
    Shortcut { sequences: ["P", "Shift+P"]; enabled: page.visible; onActivated: page.press(pauseButton) }
    Shortcut { sequences: ["X", "Shift+X"]; enabled: page.visible; onActivated: page.press(stopButton) }
    Shortcut { sequence: "/"; enabled: page.visible; onActivated: projectField.forceActiveFocus() }
    Instantiator {
        model: 6
        delegate: Shortcut {
            required property int index
            sequence: String(index + 1)
            enabled: page.visible && !page.busy
            onActivated: {
                const types = page.status ? page.status.chips.types : []
                if (index < types.length)
                    typeChips.picked(types[index])
            }
        }
    }

    component Counter: ColumnLayout {
        property string caption
        property real worked
        property real expected
        spacing: 0
        Caption { text: parent.caption; font.weight: Font.DemiBold }
        Label {
            text: Api.fmtH(parent.worked)
            font.pixelSize: 18
            font.weight: Font.Bold
            font.features: { "tnum": 1 }
        }
        Label {
            text: Api.leftOrExtra(parent.worked, parent.expected) || qsTr("nothing expected")
            color: parent.worked - parent.expected > 0.005 ? Api.workColor : Api.muted
            font.pixelSize: 12
        }
    }

    ColumnLayout {
        width: page.availableWidth
        spacing: 12

        // ---- hero -------------------------------------------------------------
        Pane {
            Layout.fillWidth: true
            Layout.topMargin: 12
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            padding: 16
            background: Rectangle {
                radius: 14
                color: page.toneBg
                border.color: Qt.alpha(page.tone, 0.3)
                Behavior on color { ColorAnimation { duration: 250 } }
            }

            ColumnLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: 4

                RowLayout {
                    Layout.fillWidth: true
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Label {
                            text: !page.status ? qsTr("Loading…")
                                  : page.timerState === "working" ? qsTr("Working")
                                  : page.timerState === "break" ? qsTr("On break") : qsTr("Stopped")
                            color: page.tone
                            font.pixelSize: 18
                            font.weight: Font.Bold
                        }
                        Label {
                            text: page.timerState === "stopped" ? "—" : Api.fmtClock(page.liveSec)
                            font.pixelSize: 40
                            font.weight: Font.Bold
                            font.features: { "tnum": 1 }
                        }
                        Label {
                            text: page.timerState === "stopped"
                                  ? qsTr("Nothing running. Pick a type and tap Start.")
                                  : "<b>" + Api.esc(page.runningBlock.type) + "</b>"
                                    + (page.runningBlock.project ? " · " + Api.esc(page.runningBlock.project) : "")
                                    + " · " + qsTr("since %1").arg(page.status.since)
                                    + (page.over ? " · " + qsTr("past your %1 stop by %2")
                                                   .arg(page.status.hard_stop).arg(Api.fmtHM(page.pastStopMin / 60)) : "")
                            textFormat: Text.StyledText
                            color: Api.muted
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                    ColumnLayout {
                        spacing: 0
                        Layout.alignment: Qt.AlignTop
                        Label {
                            text: qsTr("TODAY") + (page.todayExpH > 0 ? "  · " + Api.leftOrExtra(page.todayH, page.todayExpH) : "")
                            color: page.timerState === "stopped" ? Api.muted : page.tone
                            font.pixelSize: 12
                            font.weight: Font.DemiBold
                            Layout.alignment: Qt.AlignRight
                        }
                        Label {
                            text: Api.fmtHM(page.todayH)
                                  + (page.todayExpH > 0 ? "<font color='" + Api.muted + "' size='2'> / " + Api.fmtH(page.todayExpH) + "</font>" : "")
                            textFormat: Text.StyledText
                            font.pixelSize: 24
                            font.weight: Font.Bold
                            font.features: { "tnum": 1 }
                            Layout.alignment: Qt.AlignRight
                        }
                    }
                }

                Rectangle {
                    implicitHeight: 1
                    color: Qt.alpha(page.tone, 0.25)
                    Layout.fillWidth: true
                    Layout.topMargin: 8
                    Layout.bottomMargin: 6
                }

                RowLayout {
                    spacing: 32
                    visible: !!page.status
                    Counter {
                        caption: page.status ? qsTr("Week %1").arg(page.status.week.key.slice(5).replace(/^W/, "")) : ""
                        worked: page.weekH
                        expected: page.status ? page.status.week.expected_h : 0
                    }
                    Counter {
                        caption: page.status ? Api.parseDate(page.status.month.key + "-01").toLocaleDateString(Qt.locale(), "MMM") : ""
                        worked: page.monthH
                        expected: page.status ? page.status.month.expected_h : 0
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 10
                    spacing: 8
                    ActionButton {
                        id: startButton
                        text: page.timerState === "working" ? qsTr("Switch")
                              : page.timerState === "break" ? qsTr("Resume") : qsTr("Start")
                        subtext: page.pendingType || (page.runningBlock && page.timerState === "working"
                                                      ? page.runningBlock.type : qsTr("default"))
                        fill: Api.workColor
                        ink: Api.workFg
                        enabled: !page.busy
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        onClicked: {
                            const body = {}
                            if (page.pendingType)
                                body.type = page.pendingType
                            if (projectField.text.trim())
                                body.project = projectField.text.trim()
                            page.action("/api/start", body)
                        }
                    }
                    ActionButton {
                        id: pauseButton
                        text: page.timerState === "break" ? qsTr("Change") : qsTr("Pause")
                        subtext: page.pendingBreak || "eat"
                        fill: Api.breakColor
                        ink: Api.breakFg
                        enabled: !page.busy && (page.timerState === "working"
                                                || (page.timerState === "break" && page.pendingBreak !== page.runningBlock.type))
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        onClicked: page.action("/api/pause", { type: page.pendingBreak || "eat" })
                    }
                    ActionButton {
                        id: stopButton
                        text: qsTr("Stop")
                        subtext: page.timerState === "stopped" ? "—" : qsTr("close block")
                        fill: Api.idleColor
                        ink: Api.card
                        enabled: !page.busy && page.timerState !== "stopped"
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        onClicked: page.action("/api/stop", {})
                    }
                }

                Label {
                    // the shortcuts only matter with a keyboard: desktop, wide window
                    visible: Qt.platform.os !== "android" && page.wide
                    text: qsTr("S start · P pause · X stop · 1–6 type · / project")
                    color: Api.muted
                    font.pixelSize: 12
                    horizontalAlignment: Text.AlignHCenter
                    Layout.fillWidth: true
                    Layout.topMargin: 4
                }
            }
        }

        // ---- notices ----------------------------------------------------------
        Repeater {
            model: (page.error ? [{ text: qsTr("Error: %1").arg(page.error), level: "error" }] : [])
                   .concat(page.status ? page.status.notices.map(t => ({ text: t, level: "warn" })) : [])
                   .concat(page.status ? page.status.overlaps.map(t => ({ text: t, level: "warn", date: Api.overlapDate(t) })) : [])
                   .concat(page.status && page.status.needs_review.length
                           ? [{ text: qsTr("%n auto-closed block(s) to review: %1", "", page.status.needs_review.length)
                                      .arg([...new Set(page.status.needs_review.map(r => r.date))].join(", ")),
                                level: "info", date: page.status.needs_review[0].date }] : [])
            delegate: NoticeBanner {
                required property var modelData
                text: modelData.text
                level: modelData.level
                tappable: !!modelData.date
                onTapped: page.openDay(modelData.date)
            }
        }

        // ---- next block -------------------------------------------------------
        Card {
            title: page.timerState === "stopped" ? qsTr("Next block") : qsTr("Running block")

            Caption {
                text: page.timerState === "stopped" ? qsTr("Chosen values apply when you press Start")
                                                    : qsTr("Changes apply to the running block")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
            }

            ChipRow {
                id: typeChips
                label: qsTr("Type")
                model: page.status ? page.status.chips.types : []
                current: page.timerState === "working" ? page.runningBlock.type : page.pendingType
                onPicked: value => {
                    if (page.timerState === "working") {
                        page.pendingType = value
                        if (value !== page.runningBlock.type)
                            page.retypeRunning({ type: value }, qsTr("Type changed to %1").arg(value))
                    } else {
                        page.pendingType = page.pendingType === value ? "" : value
                    }
                }
            }

            Caption { text: qsTr("Project"); Layout.topMargin: 4 }
            TextField {
                id: projectField
                placeholderText: qsTr("Project note (optional)")
                Layout.fillWidth: true
                onEditingFinished: {
                    const v = text.trim()
                    if (page.timerState === "working" && v !== (page.runningBlock.project || ""))
                        page.retypeRunning({ project: v }, qsTr("Project changed to %1").arg(v || qsTr("none")))
                }
            }
            ChipRow {
                model: page.status ? page.status.chips.projects : []
                current: projectField.text
                onPicked: value => {
                    projectField.text = projectField.text === value ? "" : value
                    projectField.editingFinished()
                }
            }

            ChipRow {
                label: qsTr("Break")
                Layout.topMargin: 4
                model: page.status ? page.status.chips.break_types : []
                current: page.timerState === "break" ? page.runningBlock.type : page.pendingBreak
                onPicked: value => {
                    page.pendingBreak = value
                    if (page.timerState === "break" && value !== page.runningBlock.type)
                        page.retypeRunning({ type: value }, qsTr("Break changed to %1").arg(value))
                }
            }
        }

        // ---- totals: today / week / balance -----------------------------------
        GridLayout {
            visible: !!page.status
            columns: page.wide ? 3 : 2
            columnSpacing: 12
            rowSpacing: 12
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.rightMargin: 12

            Tile {
                caption: qsTr("Today")
                Layout.row: 0
                Layout.column: 0
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1
                badge: Label {
                    visible: page.timerState === "working"
                    text: "● " + qsTr("live")
                    color: Api.workColor
                    font.pixelSize: 11
                }

                Label {
                    text: Api.fmtH(page.todayH).replace(" h", "")
                          + "<font color='" + Api.muted + "' size='2'> / " + (page.todayExpH > 0 ? Api.fmtH(page.todayExpH) : "h") + "</font>"
                    textFormat: Text.StyledText
                    font.pixelSize: 22
                    font.weight: Font.Bold
                    font.features: { "tnum": 1 }
                }
                Rectangle {   // progress towards today's expected hours
                    implicitHeight: 6
                    radius: 3
                    color: Api.line2
                    Layout.fillWidth: true
                    Rectangle {
                        height: parent.height
                        radius: 3
                        width: parent.width * (page.todayExpH > 0 ? Math.min(1, page.todayH / page.todayExpH)
                                                                  : page.todayH > 0 ? 1 : 0)
                        color: page.todayExpH > 0 && page.todayH > page.todayExpH ? Api.accent : Api.workColor
                        Behavior on width { NumberAnimation { duration: 300 } }
                    }
                }
                Label {
                    text: page.todayTarget()
                    color: Api.muted
                    font.pixelSize: 12
                }
                Label {
                    readonly property var byType: page.status ? page.status.today.by_type : ({})
                    visible: text !== ""
                    text: Object.keys(byType).sort((a, b) => byType[b] - byType[a])
                                .map(k => k + " " + Math.round(byType[k] * 10) / 10).join(" · ")
                    color: Api.muted
                    font.pixelSize: 12
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }

            Tile {
                id: weekTile
                readonly property real extra: page.status ? page.weekH - page.status.week.expected_h : 0
                caption: page.status ? qsTr("Week %1").arg(page.status.week.key.slice(5).replace(/^W/, "")) : ""
                Layout.row: page.wide ? 0 : 1
                Layout.column: page.wide ? 1 : 0
                Layout.columnSpan: page.wide ? 1 : 2
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: page.wide ? 1.4 : 2
                badge: Label {
                    text: Api.fmtSigned(weekTile.extra)
                    color: Api.signColor(weekTile.extra)
                    font.pixelSize: 12
                    font.weight: Font.DemiBold
                }

                RowLayout {
                    Layout.fillWidth: true
                    Label {
                        text: Api.fmtH(page.weekH).replace(" h", "")
                              + "<font color='" + Api.muted + "' size='2'> / " + Api.fmtH(page.status ? page.status.week.expected_h : 0) + "</font>"
                        textFormat: Text.StyledText
                        font.pixelSize: 22
                        font.weight: Font.Bold
                        font.features: { "tnum": 1 }
                        Layout.fillWidth: true
                    }
                    ComboBox {   // hours a full week counts as (same setting as Settings › Hours)
                        id: basisBox
                        readonly property var choices: {
                            const cur = page.status ? page.status.week_basis_h : 40
                            const base = [30, 32.5, 35, 37.5, 40]
                            return base.indexOf(cur) >= 0 ? base : base.concat([cur]).sort((a, b) => a - b)
                        }
                        model: choices.map(v => Api.fmtNum(v, 1) + " h/wk")
                        currentIndex: page.status ? choices.indexOf(page.status.week_basis_h) : -1
                        implicitHeight: 36
                        font.pixelSize: 12
                        ToolTip.visible: hovered
                        ToolTip.text: qsTr("Hours a full week counts as")
                        onActivated: index => Api.request("PUT", "/api/settings", { week_basis_h: choices[index] }, null, e => page.error = e)
                    }
                }
                WeekBars {
                    days: page.status ? page.status.week.days : []
                    today: page.status ? page.status.date : ""
                    liveH: page.liveRunH
                    Layout.topMargin: 4
                    onDayClicked: date => page.openDay(date)
                }
                Label {
                    text: page.status
                          ? qsTr("%n day(s) worked", "", page.status.week.days_worked)
                            + " · " + qsTr("%1 billable").arg(Api.fmtH(page.status.week.billable_h))
                          : ""
                    color: Api.muted
                    font.pixelSize: 12
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }

            Tile {
                caption: qsTr("Balance")
                Layout.row: 0
                Layout.column: page.wide ? 2 : 1
                Layout.fillWidth: true
                Layout.fillHeight: true
                Layout.preferredWidth: 1

                Label {
                    text: page.status ? Api.fmtSigned(page.status.net.with_current_h) : ""
                    color: page.status ? Api.signColor(page.status.net.with_current_h) : Api.fg
                    font.pixelSize: 22
                    font.weight: Font.Bold
                    font.features: { "tnum": 1 }
                }
                Label {
                    text: page.status ? qsTr("%1 excl. this week").arg(Api.fmtSigned(page.status.net.without_current_h)) : ""
                    color: Api.muted
                    font.pixelSize: 12
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
            }
        }

        // ---- today ------------------------------------------------------------
        Card {
            title: qsTr("Today")
            actions: RoundButton {
                text: "+"
                font.pixelSize: 20
                highlighted: true
                Material.elevation: 1
                ToolTip.visible: hovered
                ToolTip.text: qsTr("Add block")
                onClicked: blockDialog.newBlock(page.status ? page.status.date : Api.isoDate(new Date()))
            }

            BlockList {
                loading: !page.day && !page.error
                blocks: page.day ? page.day.blocks : []
                runningId: page.runningBlock ? page.runningBlock.id : -1
                liveSec: page.liveSec
                onEditRequested: b => blockDialog.editBlock(b)
                onBillableToggled: (b, next) => Api.request("PUT", "/api/blocks/" + b.id, { billable: next }, null, e => page.error = e)
                onFillGap: (start, end, asBreak) => {
                    const body = { date: page.status.date, start: start, end: end }
                    const t = asBreak ? (page.pendingBreak || "eat") : page.pendingType
                    if (t)
                        body.type = t
                    Api.request("POST", "/api/blocks", body, null, e => page.error = e)
                }
            }
        }
        Item { implicitHeight: 8 }
    }

    BlockDialog {
        id: blockDialog
        parent: Overlay.overlay
        typeSuggestions: page.status ? page.status.chips.types.concat(page.status.chips.break_types) : []
        blocks: page.day ? page.day.blocks : []
        onOffer: (text, action) => snackbar.show(text, action, qsTr("Move it too"))
    }

    Snackbar { id: snackbar }
}
