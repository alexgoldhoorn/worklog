import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Create or edit one block. open with editBlock(block) or newBlock(date).
AppDialog {
    id: dlg
    property var block: null      // null while creating
    property string date: ""
    property var typeSuggestions: []
    property var blocks: []        // the day's blocks, to offer moving a neighbour's edge along
    property string error: ""
    signal offer(string text, var action)
    // a neighbour was trimmed so the edited block does not overlap it; `undo` puts its time back
    signal trimmed(string text, var undo)
    // a block was deleted; `undo` re-creates it (the page shows it in its Snackbar)
    signal deleted(string text, var undo)

    // the fields, for tests
    property alias startField: startField
    property alias endField: endField
    property alias typeField: typeField
    property alias projectField: projectField
    property alias clientField: clientField
    property alias billableBox: billableBox

    // Deletes at once (no confirmation) and offers an Undo that POSTs the block again.
    // The server's own message is shown when either step fails.
    function deleteBlock() {
        const b = block
        close()
        Api.request("DELETE", "/api/blocks/" + b.id, undefined, function () {
            dlg.deleted(qsTr("Deleted %1–%2 %3").arg(b.start).arg(b.end || "…").arg(b.type), function () {
                const body = { date: b.date, start: b.start, end: b.end || null, type: b.type,
                               project: b.project || "", client: b.client || "" }
                if (b.billable === true || b.billable === false)
                    body.billable = b.billable
                Api.request("POST", "/api/blocks", body, function (nb) {
                    // a billable flag the POST did not take (client default differs): put it back.
                    // false must stay false, so only a missing value counts as "not set"
                    const want = b.billable === undefined ? null : b.billable
                    const got = nb.billable === undefined ? null : nb.billable
                    if (nb && nb.id !== undefined && got !== want)
                        Api.request("PUT", "/api/blocks/" + nb.id, { billable: want },
                                    null, e => dlg.deleted(qsTr("Restored, but billable not set: %1").arg(e), null))
                }, e => dlg.deleted(qsTr("Undo failed: %1").arg(e), null))
            })
        }, dlg.fail)
    }

    // After moving an edge, offer to drag the neighbour's matching edge along (the timeline is contiguous).
    function neighbourOffer(b, field, oldV, newV) {
        if (!/^\d\d:\d\d$/.test(newV) || oldV === newV)
            return
        const sorted = blocks.slice().sort((x, y) => x.start.localeCompare(y.start))
        const i = sorted.findIndex(x => x.id === b.id)
        if (field === "end") {
            const next = sorted[i + 1]
            if (next && next.start === oldV)
                offer(qsTr("Next block (%1) still starts at %2").arg(next.type).arg(oldV),
                      () => Api.request("PUT", "/api/blocks/" + next.id, { start: newV }, null, null))
        } else {
            const prev = sorted[i - 1]
            if (prev && prev.end === oldV)
                offer(qsTr("Previous block (%1) still ends at %2").arg(prev.type).arg(oldV),
                      () => Api.request("PUT", "/api/blocks/" + prev.id, { end: newV }, null, null))
        }
    }

    // A start moved into an earlier block, or an end moved into a later one: the edit that trims that block so
    // the two do not overlap ({ block, fields, undo, text }), or null. A block swallowed whole is left alone
    // (the overlap warning shows). A block still running gets require_open, as every edit of it.
    function overlapFix(b, field, newV) {
        if (!/^\d\d:\d\d$/.test(newV))
            return null
        const others = blocks.filter(x => x.id !== b.id)
        if (field === "start") {
            const prev = others.filter(x => x.end && x.start < b.start && x.start < newV && x.end > newV)
                               .sort((x, y) => y.end.localeCompare(x.end))[0]
            return prev ? { block: prev, fields: { end: newV }, undo: { end: prev.end },
                            text: qsTr("Previous block (%1) now ends at %2, was %3").arg(prev.type).arg(newV).arg(prev.end) } : null
        }
        const next = others.filter(x => x.start > b.start && x.start < newV && (!x.end || x.end > newV))
                           .sort((x, y) => x.start.localeCompare(y.start))[0]
        if (!next)
            return null
        const fields = { start: newV }, undo = { start: next.start }
        if (!next.end)
            fields.require_open = undo.require_open = true
        return { block: next, fields: fields, undo: undo,
                 text: qsTr("Next block (%1) now starts at %2, was %3").arg(next.type).arg(newV).arg(next.start) }
    }

    // After a saved time edit: a neighbour the block moved into gives way at once (with Undo); a neighbour
    // it moved away from gets the offer to follow.
    function settleNeighbour(b, field, oldV, newV) {
        const fix = oldV === newV ? null : overlapFix(b, field, newV)
        if (!fix) {
            neighbourOffer(b, field, oldV, newV)
            return
        }
        const path = "/api/blocks/" + fix.block.id
        Api.request("PUT", path, fix.fields,
                    () => dlg.trimmed(fix.text, () => Api.request("PUT", path, fix.undo, null, null)), null)
    }

    function isTime(v) { return /^\d\d:\d\d$/.test(v) }

    // The end cannot be left empty when that would open a block: a new one on another day would be a
    // running block in the past, and a closed block being edited would be reopened.
    readonly property bool needsEnd: (block === null && date !== "" && date !== Api.today()) || (block !== null && !!block.end)

    // "" when start and end (as typed) are in order or not both times yet, else the server's own wording
    function endProblem(start, end) {
        const a = Api.normTime(start), b = Api.normTime(end)
        return isTime(a) && isTime(b) && b <= a ? qsTr("End must be after start") : ""
    }
    readonly property string timeProblem: endProblem(startField.text, endField.text)

    readonly property bool valid: isTime(Api.normTime(startField.text))
                                  && (endField.text.trim() === "" ? !needsEnd : isTime(Api.normTime(endField.text)))
                                  && timeProblem === ""
                                  && typeField.editText.trim() !== ""

    // what the form says now, normalised
    function formValues() {
        return {
            date: dlg.date,
            start: Api.normTime(startField.text),
            end: endField.text.trim() === "" ? null : Api.normTime(endField.text),
            type: typeField.editText.trim(),
            project: projectField.text,
            client: clientField.text,
        }
    }

    // the fields of the edited block that differ from it (only those are sent, like the web: an
    // untouched billable flag stays as it is, a date is sent only when the block moves)
    function changedFields() {
        const b = block, f = formValues()
        const cur = { date: b.date, start: b.start, end: b.end || null, type: b.type,
                      project: b.project || "", client: b.client || "" }
        const changes = {}
        for (const k in cur)
            if (f[k] !== cur[k])
                changes[k] = f[k]
        if (billableBox.checked !== !!b.billable)
            changes.billable = billableBox.checked
        // A block the server closed by itself stays "to review" until its end is saved again. Saving it
        // as it is must count as that, so the end goes along even unchanged (the server clears the flag).
        if (needsConfirm && changes.end === undefined && f.end)
            changes.end = f.end
        return changes
    }
    readonly property bool needsConfirm: !!block && !!block.auto_closed

    modal: true
    width: Math.min(420, parent ? parent.width - 32 : 420)
    // AppDialog keeps it between the status bar and the keyboard; the Flickable below scrolls
    title: block ? qsTr("Edit block") : qsTr("New block")

    function editBlock(b) {
        block = b
        date = b.date
        startField.text = b.start
        endField.text = b.end || ""
        typeField.editText = b.type
        projectField.text = b.project || ""
        clientField.text = b.client || ""
        billableBox.checked = !!b.billable
        error = ""
        scroller.contentY = 0
        open()
    }

    // Today: a new row starts where the day's last block ended (or now) and is left open, empty end =
    // running. Another day: the end is required and "now" means nothing there, so only the last end is offered.
    function newBlock(d) {
        block = null
        date = d
        const lastEnd = blocks.map(b => b.end).filter(e => !!e).sort().pop()
        startField.text = d === Api.today() ? (lastEnd || Api.nowHHMM()) : (lastEnd || "")
        endField.text = ""
        typeField.editText = ""
        projectField.text = ""
        clientField.text = ""
        billableBox.checked = false
        error = ""
        scroller.contentY = 0
        open()
    }

    onAccepted: {
        const f = formValues()
        if (dlg.block) {
            const b = dlg.block
            const changes = dlg.changedFields()
            if (Object.keys(changes).length === 0)
                return
            if (!b.end)
                changes.require_open = true  // a stale snapshot gets a 409 instead of reopening a closed block
            const sameDay = changes.date === undefined
            Api.request("PUT", "/api/blocks/" + b.id, changes, function () {
                if (!sameDay)
                    return
                dlg.settleNeighbour(b, "start", b.start, f.start)
                if (b.end)
                    dlg.settleNeighbour(b, "end", b.end, f.end || "")
            }, fail)
        } else {
            const body = { date: f.date, start: f.start, end: f.end, type: f.type, project: f.project }
            if (f.client !== "")
                body.client = f.client  // left out, the server applies the default client
            Api.request("POST", "/api/blocks", body, null, fail)
        }
    }

    // Enter/Return in any field saves (when the form is valid); Esc still cancels (closePolicy)
    function saveIfValid() {
        if (valid)
            accept()
    }

    function fail(msg) {
        error = msg
        open()  // keep the user's input on screen
    }

    // scroll so that a focused field is not under the keyboard or the edge
    function reveal(item) {
        if (!item || !form.contains(form.mapFromItem(item, 0, 0)))
            return
        const y = item.mapToItem(form, 0, 0).y
        if (y < scroller.contentY)
            scroller.contentY = Math.max(0, y - 8)
        else if (y + item.height > scroller.contentY + scroller.height)
            scroller.contentY = Math.min(Math.max(0, scroller.contentHeight - scroller.height), y + item.height - scroller.height + 8)
    }

    footer: DialogButtonBox {
        AppButton {
            visible: dlg.block !== null
            text: qsTr("Delete")
            flat: true
            destructive: true
            DialogButtonBox.buttonRole: DialogButtonBox.DestructiveRole
            onClicked: dlg.deleteBlock()
        }
        AppButton {
            text: qsTr("Cancel")
            flat: true
            DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
        }
        AppButton {
            text: dlg.needsConfirm ? qsTr("Confirm") : qsTr("Save")
            enabled: dlg.valid
            primary: true
            DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
        }
    }

    DatePicker {
        id: datePicker
        date: dlg.date
        onPicked: iso => dlg.date = iso
    }

    contentItem: Flickable {
        id: scroller
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        implicitHeight: form.implicitHeight
        contentWidth: width
        contentHeight: form.implicitHeight
        // the keyboard takes room after the field got the focus: keep the focused field in view
        onHeightChanged: if (Window.window) dlg.reveal(Window.window.activeFocusItem)
        ScrollBar.vertical: ScrollBar { policy: scroller.contentHeight > scroller.height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff }

        ColumnLayout {
            id: form
            width: scroller.width
            spacing: 4
            // TextFields ignore Return after emitting editingFinished (which normalises the time),
            // so the key reaches here; an open ComboBox popup takes it first
            Keys.onReturnPressed: dlg.saveIfValid()
            Keys.onEnterPressed: dlg.saveIfValid()

            Caption { text: qsTr("Date") }
            AppButton {
                id: dateButton
                text: Api.parseDate(dlg.date || Api.today()).toLocaleDateString(Api.locale, "dddd d MMMM yyyy")
                flat: true
                Layout.fillWidth: true
                Accessible.name: qsTr("Date: %1").arg(text)
                Accessible.role: Accessible.Button
                onClicked: datePicker.openFor(dlg.date)
            }

            RowLayout {
                spacing: 12
                Layout.fillWidth: true
                ColumnLayout {
                    spacing: 4
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Caption { text: qsTr("Start") }
                    TimeField {
                        id: startField
                        Accessible.name: qsTr("Start time")
                        onActiveFocusChanged: if (activeFocus) dlg.reveal(startField)
                        Layout.fillWidth: true
                    }
                }
                ColumnLayout {
                    spacing: 4
                    Layout.fillWidth: true
                    Layout.preferredWidth: 1
                    Caption { text: dlg.needsEnd ? qsTr("End") : qsTr("End (empty = running)") }
                    TimeField {
                        id: endField
                        Accessible.name: qsTr("End time")
                        onActiveFocusChanged: if (activeFocus) dlg.reveal(endField)
                        Layout.fillWidth: true
                    }
                }
            }

            Caption { text: qsTr("Type"); Layout.topMargin: 4 }
            ComboBox {
                id: typeField
                editable: true
                model: dlg.typeSuggestions
                Accessible.name: qsTr("Type")
                onActiveFocusChanged: if (activeFocus) dlg.reveal(typeField)
                Layout.fillWidth: true
            }

            Caption { text: qsTr("Project"); Layout.topMargin: 4 }
            TextField {
                id: projectField
                placeholderText: qsTr("Project")
                Accessible.name: qsTr("Project")
                onActiveFocusChanged: if (activeFocus) dlg.reveal(projectField)
                Layout.fillWidth: true
            }

            Caption { text: qsTr("Client"); Layout.topMargin: 4 }
            TextField {
                id: clientField
                placeholderText: qsTr("empty = default")
                Accessible.name: qsTr("Client")
                onActiveFocusChanged: if (activeFocus) dlg.reveal(clientField)
                Layout.fillWidth: true
            }

            CheckBox {
                id: billableBox
                visible: dlg.block !== null  // new blocks take the client's billable default
                text: qsTr("Billable")
            }

            NoticeBanner {
                visible: dlg.needsConfirm
                text: qsTr("This block was left running and closed automatically at %1. Correct the end if needed; Confirm clears the review notice.")
                      .arg(dlg.block && dlg.block.end ? dlg.block.end : "")
                level: "warn"
                Layout.leftMargin: 0
                Layout.rightMargin: 0
            }
            Label {
                visible: dlg.timeProblem !== ""
                text: dlg.timeProblem
                color: Api.errorColor
                font.pixelSize: 12
                Layout.fillWidth: true
            }
            NoticeBanner {
                visible: dlg.error !== ""
                text: dlg.error
                level: "error"
                Layout.leftMargin: 0
                Layout.rightMargin: 0
            }
        }
    }
}
