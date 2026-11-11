import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Create or edit one block. open with editBlock(block) or newBlock(date).
Dialog {
    id: dlg
    property var block: null      // null while creating
    property string date: ""
    property var typeSuggestions: []
    property var blocks: []        // the day's blocks, to offer moving a neighbour's edge along
    property string error: ""
    signal offer(string text, var action)
    // a block was deleted; `undo` re-creates it (the page shows it in its Snackbar)
    signal deleted(string text, var undo)

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
                    // a billable flag the POST did not take (client default differs): put it back
                    if (nb && nb.id !== undefined && (nb.billable || null) !== (b.billable === undefined ? null : b.billable))
                        Api.request("PUT", "/api/blocks/" + nb.id, { billable: b.billable === undefined ? null : b.billable },
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

    // "700", "7:00", "07.00", "19h00" -> "HH:MM" (same as normTime in the web's app.js)
    function norm(v) {
        const m = /^(\d{1,2})[:.hH]?(\d{2})$/.exec(v.trim())
        return m && Number(m[1]) < 24 && Number(m[2]) < 60 ? Api.pad(Number(m[1])) + ":" + m[2] : v.trim()
    }
    function isTime(v) { return /^\d\d:\d\d$/.test(v) }

    readonly property bool valid: isTime(norm(startField.text))
                                  && (endField.text.trim() === "" || isTime(norm(endField.text)))
                                  && typeField.editText.trim() !== ""

    modal: true
    anchors.centerIn: Overlay.overlay
    width: Math.min(420, parent ? parent.width - 32 : 420)
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
        open()
    }

    // a new row starts where the day's last block ended and runs to now (or for half an hour)
    function newBlock(d) {
        block = null
        date = d
        const lastEnd = blocks.map(b => b.end).filter(e => !!e).sort().pop()
        const now = Api.nowHHMM()
        const start = lastEnd || now
        let end = ""
        if (d === Api.today() && now > start) {
            end = now
        } else {
            const p = start.split(":").map(Number)
            const t = Math.min(p[0] * 60 + p[1] + 30, 23 * 60 + 59)
            end = Api.pad(Math.floor(t / 60)) + ":" + Api.pad(t % 60)
        }
        startField.text = start
        endField.text = end
        typeField.editText = ""
        projectField.text = ""
        clientField.text = ""
        billableBox.checked = false
        error = ""
        open()
    }

    onAccepted: {
        const start = dlg.norm(startField.text)
        const end = endField.text.trim() === "" ? null : dlg.norm(endField.text)
        const body = {
            date: dlg.date,
            start: start,
            end: end,
            type: typeField.editText,
            project: projectField.text,
        }
        if (dlg.block) {
            const b = dlg.block
            // send only what changed, like the web: untouched fields (billable unset) stay as they are
            const cur = { start: b.start, end: b.end || null, type: b.type, project: b.project || "", client: b.client || "" }
            const changes = {}
            for (const k in cur)
                if (body[k] !== undefined ? body[k] !== cur[k] : clientField.text !== cur[k])
                    changes[k] = k === "client" ? clientField.text : body[k]
            if (billableBox.checked !== !!b.billable)
                changes.billable = billableBox.checked
            if (Object.keys(changes).length === 0)
                return
            if (!b.end)
                changes.require_open = true  // a stale snapshot gets a 409 instead of reopening a closed block
            Api.request("PUT", "/api/blocks/" + b.id, changes, function () {
                dlg.neighbourOffer(b, "start", b.start, dlg.norm(startField.text))
                if (b.end)
                    dlg.neighbourOffer(b, "end", b.end, dlg.norm(endField.text))
            }, fail)
        } else {
            if (clientField.text !== "")
                body.client = clientField.text  // left out, the server applies the default client
            Api.request("POST", "/api/blocks", body, null, fail)
        }
    }

    function fail(msg) {
        error = msg
        open()  // keep the user's input on screen
    }

    footer: DialogButtonBox {
        Button {
            visible: dlg.block !== null
            text: qsTr("Delete")
            flat: true
            Material.foreground: Api.errorColor
            DialogButtonBox.buttonRole: DialogButtonBox.DestructiveRole
            onClicked: dlg.deleteBlock()
        }
        Button {
            text: qsTr("Cancel")
            flat: true
            DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
        }
        Button {
            text: qsTr("Save")
            enabled: dlg.valid
            highlighted: true
            DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
        }
    }

    ColumnLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: 8

        Caption {
            text: Api.parseDate(dlg.date || Api.today()).toLocaleDateString(Qt.locale(), "dddd d MMMM yyyy")
        }

        RowLayout {
            spacing: 12
            Layout.fillWidth: true
            TextField {
                id: startField
                placeholderText: qsTr("Start (e.g. 700 or 19:00)")
                validator: RegularExpressionValidator { regularExpression: /^[\d:.hH]{0,5}$/ }
                inputMethodHints: Qt.ImhPreferNumbers
                selectByMouse: true
                onActiveFocusChanged: if (activeFocus) selectAll()
                onEditingFinished: text = dlg.norm(text)
                Layout.fillWidth: true
            }
            TextField {
                id: endField
                placeholderText: qsTr("End (empty = running)")
                validator: RegularExpressionValidator { regularExpression: /^[\d:.hH]{0,5}$/ }
                inputMethodHints: Qt.ImhPreferNumbers
                selectByMouse: true
                onActiveFocusChanged: if (activeFocus) selectAll()
                onEditingFinished: text = dlg.norm(text)
                Layout.fillWidth: true
            }
        }

        ComboBox {
            id: typeField
            editable: true
            model: dlg.typeSuggestions
            Layout.fillWidth: true
        }
        Caption { text: qsTr("Type"); Layout.topMargin: -6 }

        TextField { id: projectField; placeholderText: qsTr("Project"); Layout.fillWidth: true }
        TextField { id: clientField; placeholderText: qsTr("Client (empty = default)"); Layout.fillWidth: true }

        CheckBox {
            id: billableBox
            visible: dlg.block !== null  // new blocks take the client's billable default
            text: qsTr("Billable")
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
