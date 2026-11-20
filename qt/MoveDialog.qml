pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Move one planned item (a run, a protected block or a personal calendar event): where it fits, a preview
// of the day, and the writes a confirm sends. A port of the web's Move page (`move.js`, `templates/move.html`;
// the API is POST /api/day/slots and /api/day/move in `day/web.py`). PlannerPage opens it from the "Move" links.
AppDialog {
    id: dlg
    parent: Overlay.overlay
    modal: true
    width: Math.min(parent ? parent.width - 16 : 320, 560)
    height: maxHeight
    padding: 12
    title: item ? qsTr("Move: %1, %2 min").arg(item.title).arg(item.minutes) : qsTr("Move")
    standardButtons: Dialog.Close
    Material.accent: Api.accent

    signal moved(string date)         // after a successful move: the page goes to that day

    property var day: null            // the /api/day answer the item comes from
    property var item: null           // { title, minutes, kind, ref }
    property var slots: []            // the candidate slots, as the server sorted them
    property var chosen: null         // the picked slot
    property var writes: ({})         // write key -> ticked
    property string error: ""
    property string info: ""
    property string paste: ""
    property bool loading: false
    property bool done: false
    property int seq: 0

    // ---- pure helpers (the tests call them) -------------------------------------------------------

    function hm(s) { const p = String(s).split(":").map(Number); return p[0] + p[1] / 60 }
    function addMin(hhmm, minutes) {
        const t = Math.round(hm(hhmm) * 60) + minutes
        return Api.pad(Math.floor(t / 60)) + ":" + Api.pad(t % 60)
    }
    function fmtDate(iso) { return Api.parseDate(iso).toLocaleDateString(Api.locale, "ddd d MMM") }

    // What the query of the web's Move page picks, found in the day model: { title, minutes, kind, ref }.
    // Throws an Error with the web's wording when the item is not there.
    function resolveItem(d, kind, id, uid) {
        const date = d.date
        if (kind === "block") {
            const b = d.timeline.find(e => e.layer === "protected" && e.id === id)
            if (!b)
                throw new Error(qsTr("No such block on %1.").arg(date))
            return { title: b.title, minutes: Math.round((hm(b.end) - hm(b.start)) * 60), kind: b.kind === "run" ? "run" : "personal",
                     ref: { kind: "block", date: date, start: b.start, end: b.end, block_id: id, title: b.title } }
        }
        if (kind === "personal") {
            const e = d.timeline.find(x => x.layer === "personal" && x.uid === uid)
            if (!e)
                throw new Error(qsTr("That calendar event is not in today's snapshot."))
            return { title: e.title, minutes: Math.max(15, Math.round((hm(e.end) - hm(e.start)) * 60)), kind: "personal",
                     ref: { kind: "personal", date: date, start: e.start, end: e.end, uid: uid, calendar: e.source, title: e.title } }
        }
        const t = d.training
        if (!t)
            throw new Error(qsTr("No planned session on %1.").arg(date))
        const run = d.timeline.find(e => e.layer === "protected" && e.kind === "run")
        const end = t.end || addMin(t.time, 60)
        return { title: t.session, minutes: Math.max(30, Math.round((hm(end) - hm(t.time)) * 60)), kind: "run",
                 ref: { kind: "run", date: date, start: t.time, end: end, session: t.session, block_id: run ? run.id : null } }
    }

    // the writes a confirm can make for this item: [{ key, label, on }]
    function writeDefs(it) {
        if (it.ref.kind === "run")
            return [{ key: "session_time", label: qsTr("Training plan: time changes, session stays (the coach reads it)"), on: true },
                    { key: "block", label: qsTr("Agent calendar block follows (Google updates on the next sync)"), on: !!it.ref.block_id },
                    { key: "mirror_busy", label: qsTr("Work calendar: give me a Busy line to paste into Outlook"), on: false }]
        if (it.ref.kind === "block")
            return [{ key: "block", label: qsTr("Move the block (Google updates on the next sync)"), on: true }]
        return [{ key: "gcal", label: qsTr("Google calendar (%1): edit the event in place").arg(it.ref.calendar), on: true },
                { key: "mirror_busy", label: qsTr("Work calendar: give me a Busy line to paste into Outlook"), on: false }]
    }

    // the slots worth showing: no clashes, at most 12
    function shownSlots(found) { return found.filter(s => s.verdict !== "clash").slice(0, 12) }
    function verdictText(v) {
        return { fits: qsTr("fits"), tight: qsTr("tight"), unknown: qsTr("work calendar unknown"), clash: qsTr("clash") }[v] || v
    }
    function slotTitle(s, dayDate) { return (s.date === dayDate ? "" : fmtDate(s.date) + " · ") + s.start + "–" + s.end }
    function slotHint(s) {
        return s.reasons.filter(r => r !== "current slot").join(" · ") || verdictText(s.verdict)
    }
    function isCurrent(s) { return s.reasons.length > 0 && s.reasons[0] === "current slot" }
    // the line to send the PA when the trainer decides
    function askLine(it, s) { return qsTr("move my %1 from %2 to %3").arg(it.title).arg(it.ref.date).arg(s.date) }
    function confirmLine(it, s) {
        return qsTr("%1: %2 → %3–%4 on %5").arg(it.title).arg(it.ref.start).arg(s.start).arg(s.end).arg(fmtDate(s.date))
    }
    // the body of POST /api/day/move
    function moveBody(it, s, ticked) {
        return { ref: it.ref, date: s.date, start: s.start, end: s.end, writes: Object.keys(ticked).filter(k => ticked[k]) }
    }
    function resultLine(it, s, out) {
        const bits = []
        if (out.queued.length)
            bits.push(out.queued.length === 1 ? qsTr("1 write queued for the next sync") : qsTr("%1 writes queued for the next sync").arg(out.queued.length))
        if (out.blocks.length)
            bits.push(qsTr("block moved"))
        return qsTr("Moved %1 to %2. %3.").arg(it.title).arg(s.start).arg(bits.join(", "))
    }
    // The day as a list for the preview, without the item itself, with the picked slot as a ghost: [{ start, end, text, layer, ghost }]
    function previewRows(d, it, s) {
        const own = e => (it.ref.kind === "run" && e.layer === "protected" && e.kind === "run")
                         || (it.ref.kind === "block" && e.id === it.ref.block_id) || (it.ref.kind === "personal" && e.uid === it.ref.uid)
        const rows = d.timeline.filter(e => !(s && own(e)) && hm(e.end) > 6 && hm(e.start) < 22)
                      .map(e => ({ start: e.start, end: e.end, text: e.title, layer: e.layer, ghost: false, cancelled: !!e.cancelled }))
        if (s && s.date === d.date)
            rows.push({ start: s.start, end: s.end, text: it.title, layer: "ghost", ghost: true, cancelled: false })
        rows.sort((a, b) => hm(a.start) - hm(b.start) || hm(a.end) - hm(b.end))
        return rows
    }
    function layerColor(layer) {
        return layer === "work" ? Api.workColor : layer === "protected" ? Api.errorColor : layer === "ghost" ? Api.accent
             : layer === "duty" ? Api.series[4] : Api.series[3]
    }

    // ---- actions ------------------------------------------------------------------------------------

    // Opens for an item of the day `d`: kind "run" (the day's session), "block" (id) or "personal" (uid)
    function openFor(d, kind, id, uid) {
        const my = ++seq
        day = d
        slots = []
        chosen = null
        writes = ({})
        error = ""
        info = ""
        paste = ""
        done = false
        item = null
        try {
            item = resolveItem(d, kind, id, uid)
        } catch (e) {
            error = e.message
            open()
            return
        }
        open()
        loading = true
        const to = item.ref.kind === "run" ? d.date : Api.addDays(d.date, 6)
        Api.request("POST", "/api/day/slots", { item: { title: item.title, minutes: item.minutes, kind: item.kind, ref: item.ref }, from: d.date, to: to },
                    function (r) {
                        if (!dlg || my !== dlg.seq)
                            return
                        dlg.loading = false
                        dlg.slots = r.slots
                    }, function (e) {
                        if (!dlg || my !== dlg.seq)
                            return
                        dlg.loading = false
                        dlg.error = e
                    })
    }
    function pick(s) {
        chosen = s
        paste = ""
        const w = {}
        for (const d of writeDefs(item))
            w[d.key] = d.on
        writes = w
    }
    function cancelPick() { chosen = null }
    function setWrite(key, on) {
        const w = Object.assign({}, writes)
        w[key] = on
        writes = w
    }
    function ask(s) {
        const line = askLine(item, s)
        clipboard.text = line
        clipboard.selectAll()
        clipboard.copy()
        info = qsTr("Copied \"%1\". Send it to the PA on Telegram; the trainer decides.").arg(line)
    }
    function confirm() {
        if (!chosen || done)
            return
        const my = seq
        const s = chosen
        error = ""
        Api.request("POST", "/api/day/move", moveBody(item, s, writes), function (out) {
            if (!dlg || my !== dlg.seq)
                return
            dlg.info = dlg.resultLine(dlg.item, s, out)
            dlg.paste = out.paste || ""
            dlg.done = true
        }, function (e) {
            if (dlg && my === dlg.seq)
                dlg.error = qsTr("Move failed: %1").arg(e)
        })
    }
    onClosed: if (done && chosen) moved(chosen.date)

    // for the clipboard: a TextEdit is the one thing QML can copy from
    TextEdit { id: clipboard; visible: false }

    contentItem: ScrollView {
        id: scroll
        contentWidth: availableWidth
        clip: true
        ColumnLayout {
            width: scroll.availableWidth
            spacing: 10

            NoticeBanner {
                visible: dlg.error !== ""
                text: dlg.error
                level: "error"
                Layout.leftMargin: 0
                Layout.rightMargin: 0
            }
            NoticeBanner {
                visible: dlg.info !== ""
                text: dlg.info
                level: "info"
                Layout.leftMargin: 0
                Layout.rightMargin: 0
            }
            Label {
                visible: !!dlg.item
                text: dlg.item ? dlg.fmtDate(dlg.day.date) + " · " + qsTr("now at %1").arg(dlg.item.ref.start) : ""
                color: Api.muted
                Layout.fillWidth: true
            }

            // ---- on confirm
            Card {
                visible: dlg.chosen !== null
                title: qsTr("On confirm, this updates")
                Layout.leftMargin: 0
                Layout.rightMargin: 0
                Repeater {
                    model: dlg.item && dlg.chosen ? dlg.writeDefs(dlg.item) : []
                    delegate: CheckBox {
                        id: wcb
                        required property var modelData
                        text: modelData.label
                        checked: !!dlg.writes[modelData.key]
                        enabled: !dlg.done
                        Layout.fillWidth: true
                        contentItem: Label {
                            text: wcb.text
                            wrapMode: Text.Wrap
                            leftPadding: wcb.indicator.width + 8
                            verticalAlignment: Text.AlignVCenter
                        }
                        onToggled: dlg.setWrite(modelData.key, checked)
                    }
                }
                Label {
                    text: dlg.item && dlg.chosen ? dlg.confirmLine(dlg.item, dlg.chosen) : ""
                    color: Api.muted
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
                RowLayout {
                    Layout.fillWidth: true
                    Item { Layout.fillWidth: true }
                    AppButton {
                        text: qsTr("Cancel")
                        flat: true
                        enabled: !dlg.done
                        Accessible.name: text
                        onClicked: dlg.cancelPick()
                    }
                    AppButton {
                        text: dlg.chosen ? qsTr("Move to %1").arg(dlg.chosen.start) : qsTr("Move")
                        primary: true
                        enabled: !dlg.done
                        Accessible.name: text
                        onClicked: dlg.confirm()
                    }
                }
                TextEdit {
                    visible: dlg.paste !== ""
                    text: dlg.paste
                    readOnly: true
                    selectByMouse: true
                    wrapMode: TextEdit.Wrap
                    color: Api.fg
                    selectionColor: Api.accent
                    selectedTextColor: Api.accentFg
                    Layout.fillWidth: true
                    Accessible.name: qsTr("Busy line for Outlook")
                }
            }

            // ---- where it fits
            Card {
                title: qsTr("Where it fits")
                visible: !!dlg.item
                Layout.leftMargin: 0
                Layout.rightMargin: 0
                Caption {
                    text: qsTr("checked against work meetings, personal and family calendars, the child, blocks, hours left and the gate")
                    font.capitalization: Font.MixedCase
                    font.letterSpacing: 0
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
                Label {
                    visible: dlg.loading
                    text: qsTr("Looking…")
                    color: Api.muted
                }
                Label {
                    visible: !dlg.loading && dlg.error === "" && dlg.shownSlots(dlg.slots).length === 0
                    text: qsTr("Nothing fits in this range without a clash.")
                    color: Api.muted
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
                Repeater {
                    model: dlg.shownSlots(dlg.slots)
                    delegate: Rectangle {
                        id: slotRow
                        required property var modelData
                        readonly property bool picked: !!dlg.chosen && dlg.chosen.date === modelData.date && dlg.chosen.start === modelData.start
                        Layout.fillWidth: true
                        implicitHeight: srow.implicitHeight + 12
                        radius: 8
                        color: picked ? Api.accentBg : "transparent"
                        border.color: picked ? Api.accent : Api.line
                        RowLayout {
                            id: srow
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.margins: 8
                            spacing: 8
                            Rectangle {
                                implicitWidth: 10
                                implicitHeight: 10
                                radius: 5
                                color: slotRow.modelData.verdict === "fits" ? Api.workColor
                                     : slotRow.modelData.verdict === "tight" ? Api.warnColor
                                     : slotRow.modelData.verdict === "ask_trainer" ? Api.series[4] : Api.idleColor
                            }
                            ColumnLayout {
                                spacing: 0
                                Layout.fillWidth: true
                                Label {
                                    text: dlg.slotTitle(slotRow.modelData, dlg.day ? dlg.day.date : "")
                                          + (slotRow.modelData.best ? " · " + qsTr("best") : "")
                                          + (dlg.isCurrent(slotRow.modelData) ? " · " + qsTr("current") : "")
                                    font.weight: Font.DemiBold
                                    wrapMode: Text.Wrap
                                    Layout.fillWidth: true
                                }
                                Label {
                                    text: dlg.slotHint(slotRow.modelData)
                                    color: Api.muted
                                    font.pixelSize: 12
                                    wrapMode: Text.Wrap
                                    Layout.fillWidth: true
                                }
                            }
                            AppButton {
                                visible: slotRow.modelData.verdict === "ask_trainer"
                                text: qsTr("Ask the trainer")
                                flat: true
                                Accessible.name: text
                                onClicked: dlg.ask(slotRow.modelData)
                            }
                            AppButton {
                                visible: slotRow.modelData.verdict !== "ask_trainer" && !dlg.isCurrent(slotRow.modelData)
                                text: qsTr("Pick")
                                flat: true
                                enabled: !dlg.done
                                Accessible.name: qsTr("Pick %1").arg(dlg.slotTitle(slotRow.modelData, dlg.day ? dlg.day.date : ""))
                                onClicked: dlg.pick(slotRow.modelData)
                            }
                        }
                    }
                }
            }

            // ---- the day with the move
            Card {
                title: qsTr("Day with the move")
                visible: !!dlg.item
                Layout.leftMargin: 0
                Layout.rightMargin: 0
                Repeater {
                    model: dlg.item && dlg.day ? dlg.previewRows(dlg.day, dlg.item, dlg.chosen) : []
                    delegate: RowLayout {
                        id: prow
                        required property var modelData
                        spacing: 8
                        Layout.fillWidth: true
                        Rectangle {
                            implicitWidth: 4
                            Layout.fillHeight: true
                            radius: 2
                            color: dlg.layerColor(prow.modelData.layer)
                        }
                        Label {
                            text: prow.modelData.start + "–" + prow.modelData.end
                            color: Api.muted
                            font.pixelSize: 12
                            font.features: { "tnum": 1 }
                        }
                        Label {
                            text: prow.modelData.text
                            font.weight: prow.modelData.ghost ? Font.Bold : Font.Normal
                            font.strikeout: prow.modelData.cancelled
                            wrapMode: Text.Wrap
                            Layout.fillWidth: true
                        }
                    }
                }
            }
            Item { implicitHeight: 4 }
        }
    }
}
