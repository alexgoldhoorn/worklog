pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Summary per week / month / quarter / year with charts and stats, the monthly invoice and export.
ScrollView {
    id: page
    property string group: "week"
    property string start: ""      // empty = first logged day
    property string end: ""        // empty = today
    property var summary: null
    property var heat: null
    // today, re-read whenever the page is shown (the app can run for days); the invoice month follows it
    // until the user steps to another one
    property string todayIso: Api.today()
    property bool invoiceChosen: false
    // the part that shows: "summary" (filters, table, weekly stats), "charts" (filters, charts) or
    // "invoice", as the web's Reports tabs; not remembered
    property string view: "summary"

    // the invoice month's day counts: workable = Mon-Fri and not a public holiday, expected = workable
    // with hours expected, worked = any work logged, offDays = worked on a day that is not workable
    function invoiceCounts(rows) {
        return {
            days: rows.length,
            workable: rows.filter(r => r.workable).length,
            expected: rows.filter(r => r.workable && r.expected_h > 0).length,
            worked: rows.filter(r => r.worked).length,
            offDays: rows.filter(r => r.worked && !r.workable).length
        }
    }
    function countsLine(c) {
        return qsTr("%1 days · %2 workable · %3 expected · %4 worked").arg(c.days).arg(c.workable).arg(c.expected).arg(c.worked)
               + (c.offDays > 0 ? qsTr(" (%1 on non-workable days)").arg(c.offDays) : "")
    }
    // the server's per-day mark: ✓ worked, ✗ a past workday missed, ⛱ a holiday or day off
    function markCell(mark) {
        return mark === "worked" ? { t: "✓", c: Api.workColor } : mark === "missed" ? { t: "✗", c: Api.errorColor }
             : mark === "holiday" ? { t: "⛱", c: Api.muted } : { t: "" }
    }
    property string invoiceMonth: Api.today().slice(0, 7)
    property string rangeError: ""
    property var invoice: []
    property string error: ""
    property string heatError: ""
    property string exportMessage: ""
    property bool exportOk: true

    readonly property bool wide: availableWidth >= 760
    readonly property var rows: summary ? summary.rows : []
    // the period that is still running, as the server keys it: "2026-43", "2026-10", "2026-Q4", "2026"
    readonly property string currentKey: {
        const t = todayIso
        return group === "week" ? Api.weekKey(t) : group === "month" ? t.slice(0, 7)
             : group === "quarter" ? t.slice(0, 4) + "-Q" + (Math.floor((Number(t.slice(5, 7)) - 1) / 3) + 1) : t.slice(0, 4)
    }
    readonly property real altWeek: summary && summary.alt_week_h ? summary.alt_week_h : 40
    readonly property bool priced: !!summary && summary.rate_h !== null

    contentWidth: availableWidth

    function periodLabel(key) {
        if (group === "week")
            return key   // "2026-43", as the web writes it
        if (group === "month")
            return Api.parseDate(key + "-01").toLocaleDateString(Api.locale, "MMM")
        return key.replace("-Q", " Q")
    }
    function periodLong(key) {
        if (group === "week")
            return qsTr("Week %1 · %2").arg(key.slice(5)).arg(key.slice(0, 4))
        if (group === "month")
            return Api.parseDate(key + "-01").toLocaleDateString(Api.locale, "MMMM yyyy")
        return key.replace("-Q", " Q")
    }
    function inProgress(key) { return key === currentKey ? " " + qsTr("(in progress)") : "" }

    // Every request takes a number; an answer whose number is no longer the latest is dropped, so a quick
    // switch of the grouping, range or month never shows the older answer.
    property int summaryReq: 0
    property int heatReq: 0
    property int invoiceReq: 0

    function reload() {
        const range = { start: start, end: end }
        const sid = ++summaryReq, hid = ++heatReq
        Api.request("GET", "/api/summary?" + Api.query(Object.assign({ group: group }, range)), undefined, function (d) {
            if (sid !== page?.summaryReq)
                return
            page.summary = d
            page.error = ""
        }, function (e) {
            if (sid === page?.summaryReq)
                page.error = e
        })
        Api.request("GET", "/api/heatmap?" + Api.query(range), undefined, function (h) {
            if (hid !== page?.heatReq)
                return
            page.heat = h
            page.heatError = ""
        }, function (e) {
            if (hid !== page?.heatReq)
                return
            page.heat = null
            page.heatError = e
        })
        loadInvoice()
    }
    function loadInvoice() {
        const id = ++invoiceReq
        Api.request("GET", "/api/invoice?month=" + invoiceMonth, undefined, function (r) {
            if (id === page?.invoiceReq)
                page.invoice = r
        }, function (e) {
            if (id === page?.invoiceReq)
                page.error = e
        })
    }

    readonly property var groups: ["week", "month", "quarter", "year"]
    readonly property var groupLabels: [qsTr("Week"), qsTr("Month"), qsTr("Quarter"), qsTr("Year")]

    // ---- range presets ---------------------------------------------------------------------
    readonly property var presets: [qsTr("All"), qsTr("This year"), qsTr("Last 12 weeks"), qsTr("Last 6 months")]
    function presetRange(name) {
        const today = Api.now()
        if (name === presets[0])
            return { start: "", end: "" }
        if (name === presets[1])
            return { start: today.getFullYear() + "-01-01", end: "" }
        if (name === presets[2])
            return { start: Api.addDays(Api.isoDate(today), -83), end: "" }
        return { start: Api.isoDate(new Date(today.getFullYear(), today.getMonth() - 5, 1)), end: "" }
    }
    // the preset the dates match, "" when they were typed by hand
    readonly property string activePreset: {
        for (const n of presets) {
            const r = presetRange(n)
            if (r.start === start && r.end === end)
                return n
        }
        return ""
    }
    property string pickTarget: "start"
    function applyDates(s, e) {
        rangeError = rangeProblem(s, e)
        if (rangeError !== "" || (s === start && e === end))
            return
        start = s
        end = e
        reload()
    }
    function shiftInvoice(n) {
        const d = Api.parseDate(invoiceMonth + "-01")
        d.setMonth(d.getMonth() + n)
        invoiceMonth = Api.isoDate(d).slice(0, 7)
        invoiceChosen = true
    }

    // "" when s and e (either may be empty) make a usable range, else what is wrong with them
    function rangeProblem(s, e) {
        const bad = t => t !== "" && !(/^\d{4}-\d{2}-\d{2}$/.test(t) && Api.isoDate(Api.parseDate(t)) === t)
        if (bad(s) || bad(e))
            return qsTr("Use a date like %1.").arg(Api.today())
        if (s !== "" && e !== "" && s > e)
            return qsTr("From is after To.")
        return ""
    }
    // a date typed in one of the fields
    function typedDate(which, text) {
        const t = text.trim()
        const s = which === "start" ? t : start, e = which === "end" ? t : end
        rangeError = rangeProblem(s, e)
        if (rangeError === "" && (which === "start" ? t !== start : t !== end))
            applyDates(s, e)
    }
    function setRange(s, e) {
        startField.text = s
        endField.text = e
        start = s
        end = e
        reload()
    }

    onInvoiceMonthChanged: loadInvoice()
    Component.onCompleted: if (visible) reload()
    onVisibleChanged: {
        if (visible) {
            todayIso = Api.today()
            if (!invoiceChosen)
                invoiceMonth = todayIso.slice(0, 7)
            reload()
        }
    }
    Connections {
        target: Api
        // a hidden page reloads when its tab is shown
        function onChanged() { if (page.visible) page.reload() }
        function onServerChanged() { if (page.visible) page.reload() }
    }

    // ---- chart data ----------------------------------------------------------------

    readonly property var extraRows: rows.map(r => ({
        label: periodLabel(r.key), dim: r.key === currentKey,
        parts: [{ v: r.extra_h, color: r.extra_h >= 0 ? Api.workColor : Api.errorColor }],
        tip: periodLong(r.key) + inProgress(r.key) + "\n"
             + qsTr("%1 worked · %2 expected").arg(Api.fmtH(r.worked_h)).arg(Api.fmtH(r.expected_h)) + "\n" + Api.shortOrExtra(r.extra_h)
    }))

    readonly property var balanceRows: {
        let acc = 0
        return rows.map(r => {
            acc += r.extra_h
            return { label: periodLabel(r.key), parts: [{ v: acc }],
                     tip: periodLong(r.key) + inProgress(r.key) + "\n" + qsTr("balance so far %1").arg(Api.fmtSigned(acc))
                          + "\n" + qsTr("this %1 %2").arg(page.group).arg(Api.fmtSigned(r.extra_h)) }
        })
    }

    // hours by type: the top six types keep a colour, the rest fold into "other"
    readonly property var typeTotals: {
        const tot = {}
        for (const r of rows)
            for (const t in r.by_type)
                tot[t] = (tot[t] || 0) + r.by_type[t]
        return tot
    }
    readonly property var typeRanked: Object.keys(typeTotals).sort((a, b) => typeTotals[b] - typeTotals[a])
    readonly property var typeSeries: typeRanked.length > 6 ? typeRanked.slice(0, 6).concat(["other"]) : typeRanked
    function typeColor(t) { return t === "other" ? Api.seriesOther : Api.series[typeRanked.indexOf(t)] }
    function typeHours(r, t) {
        return t === "other" ? typeRanked.slice(6).reduce((a, o) => a + (r.by_type[o] || 0), 0) : (r.by_type[t] || 0)
    }
    readonly property var typeRows: rows.map(r => ({
        label: periodLabel(r.key), dim: r.key === currentKey,
        parts: typeSeries.map(t => ({ v: typeHours(r, t), color: typeColor(t) })),
        tip: periodLong(r.key) + " · " + Api.fmtH(r.worked_h) + "\n"
             + typeSeries.filter(t => typeHours(r, t) > 0).map(t => t + " " + Api.fmtH(typeHours(r, t))).join("\n")
    }))

    // hours by project note: a ranked list over the whole range
    readonly property var projectItems: {
        const none = qsTr("(no project)")
        const tot = {}
        for (const r of rows)
            for (const p in r.by_project) {
                const k = p || none
                tot[k] = (tot[k] || 0) + r.by_project[p]
            }
        const ranked = Object.keys(tot).sort((a, b) => tot[b] - tot[a])
        const all = ranked.reduce((a, k) => a + tot[k], 0)
        const top = ranked.slice(0, 10), rest = ranked.slice(10)
        const item = (name, h, color, dim) => {
            const pct = all ? Math.round(h / all * 100) : 0
            return { name: name, value: h, color: color, dim: dim, text: Api.fmtNum(h, 1) + " h · " + pct + "%",
                     tip: name + "\n" + qsTr("%1 · %2% of work in range").arg(Api.fmtH(h)).arg(pct) }
        }
        const out = top.map(k => item(k, tot[k], Api.accent, k === none))
        if (rest.length)
            out.push(item(qsTr("other (%n notes)", "", rest.length), rest.reduce((a, k) => a + tot[k], 0), Api.seriesOther, false))
        return out
    }

    // ---- layout ----------------------------------------------------------------------

    ColumnLayout {
        width: page.availableWidth
        spacing: 12

        // the parts of the page, as the Week screen's tabs
        RowLayout {
            Layout.fillWidth: true
            Layout.topMargin: 12
            Layout.leftMargin: 12
            Layout.rightMargin: 12
            Repeater {
                model: [
                    { key: "summary", label: qsTr("Summary") },
                    { key: "charts", label: qsTr("Charts") },
                    { key: "invoice", label: qsTr("Invoice") }
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

        // filters: the charts use the same group and range
        Card {
            visible: page.view !== "invoice"
            title: qsTr("Summary")
            actions: ExportButtons {
                start: page.start
                end: page.end
                onMessage: (text, ok) => { page.exportMessage = text; page.exportOk = ok }
            }

            ChipRow {
                label: qsTr("Group")
                model: page.groupLabels
                current: page.groupLabels[page.groups.indexOf(page.group)]
                onPicked: value => { page.group = page.groups[page.groupLabels.indexOf(value)]; page.reload() }
            }
            ChipRow {
                label: qsTr("Range")
                model: page.presets
                current: page.activePreset
                onPicked: value => {
                    const r = page.presetRange(value)
                    page.setRange(r.start, r.end)
                }
            }
            // From and To side by side on a wide screen; below 420 each gets its own line, so the placeholders fit
            GridLayout {
                columns: page.availableWidth < 420 ? 2 : 4
                columnSpacing: 8
                rowSpacing: 4
                Layout.fillWidth: true
                TextField {
                    id: startField
                    placeholderText: qsTr("From (first log)")
                    validator: RegularExpressionValidator { regularExpression: /^(\d{4}-\d{2}-\d{2})?$/ }
                    Layout.fillWidth: true
                    Accessible.name: qsTr("From date")
                    onEditingFinished: page.typedDate("start", text)
                }
                AppButton {
                    flat: true
                    text: qsTr("Pick")
                    Accessible.name: qsTr("Pick the from date")
                    Accessible.role: Accessible.Button
                    onClicked: { page.pickTarget = "start"; datePicker.openFor(startField.text) }
                }
                TextField {
                    id: endField
                    placeholderText: qsTr("To (today)")
                    validator: RegularExpressionValidator { regularExpression: /^(\d{4}-\d{2}-\d{2})?$/ }
                    Layout.fillWidth: true
                    Accessible.name: qsTr("To date")
                    onEditingFinished: page.typedDate("end", text)
                }
                AppButton {
                    flat: true
                    text: qsTr("Pick")
                    Accessible.name: qsTr("Pick the to date")
                    Accessible.role: Accessible.Button
                    onClicked: { page.pickTarget = "end"; datePicker.openFor(endField.text) }
                }
            }
            Label {
                visible: page.rangeError !== ""
                text: page.rangeError
                color: Api.errorColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: page.exportMessage !== ""
                text: page.exportMessage
                color: page.exportOk ? Api.workColor : Api.errorColor
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }

        NoticeBanner {
            visible: page.error !== ""
            text: qsTr("Error: %1").arg(page.error)
            level: "error"
        }
        NoticeBanner {
            visible: page.heatError !== ""
            text: qsTr("Heatmap: %1").arg(page.heatError)
            level: "error"
        }

        DatePicker {
            id: datePicker
            onPicked: iso => {
                if (page.pickTarget === "start") {
                    startField.text = iso
                    page.applyDates(iso, page.end)
                } else {
                    endField.text = iso
                    page.applyDates(page.start, iso)
                }
            }
        }

        // charts
        GridLayout {
            visible: page.view === "charts"
            columns: page.wide ? 2 : 1
            columnSpacing: 12
            rowSpacing: 12
            Layout.fillWidth: true
            Layout.leftMargin: 12
            Layout.rightMargin: 12

            Card {
                title: qsTr("Extra hours")
                Layout.leftMargin: 0
                Layout.rightMargin: 0
                Layout.preferredWidth: 1
                Caption { text: qsTr("worked minus expected, per %1").arg(page.group); font.capitalization: Font.MixedCase; font.letterSpacing: 0 }
                ColumnChart { rows: page.extraRows; signedAxis: true; title: qsTr("Extra hours per period") }
            }
            Card {
                title: qsTr("Balance")
                Layout.leftMargin: 0
                Layout.rightMargin: 0
                Layout.preferredWidth: 1
                Caption {
                    text: qsTr("extra hours added up over the range shown")
                          + (page.balanceRows.length ? " · " + qsTr("now %1").arg(Api.fmtSigned(page.balanceRows[page.balanceRows.length - 1].parts[0].v)) : "")
                    font.capitalization: Font.MixedCase
                    font.letterSpacing: 0
                    wrapMode: Text.Wrap
                    Layout.fillWidth: true
                }
                ColumnChart { rows: page.balanceRows; line: true; signedAxis: true; title: qsTr("Balance, cumulative extra hours") }
            }
            Card {
                title: qsTr("Hours by type")
                Layout.columnSpan: page.wide ? 2 : 1
                Layout.leftMargin: 0
                Layout.rightMargin: 0
                Caption { text: qsTr("work only; breaks excluded"); font.capitalization: Font.MixedCase; font.letterSpacing: 0 }
                ColumnChart { rows: page.typeRows; implicitHeight: 200; title: qsTr("Hours by type per period") }
                Flow {   // legend
                    spacing: 12
                    Layout.fillWidth: true
                    Repeater {
                        model: page.typeSeries
                        delegate: Row {
                            id: legend
                            required property string modelData
                            spacing: 5
                            Rectangle { width: 10; height: 10; radius: 2; anchors.verticalCenter: parent.verticalCenter; color: page.typeColor(legend.modelData) }
                            Text {
                                text: legend.modelData + " · " + Api.fmtH(legend.modelData === "other"
                                          ? page.typeRanked.slice(6).reduce((a, o) => a + page.typeTotals[o], 0)
                                          : page.typeTotals[legend.modelData])
                                color: Api.muted
                                font.pixelSize: 12
                            }
                        }
                    }
                }
            }
            Card {
                title: qsTr("Hours by project")
                Layout.columnSpan: page.wide ? 2 : 1
                Layout.leftMargin: 0
                Layout.rightMargin: 0
                Caption { text: qsTr("top project notes in the selected range · work only"); font.capitalization: Font.MixedCase; font.letterSpacing: 0 }
                RankedBars { items: page.projectItems; title: qsTr("Hours by project") }
            }
            Card {
                title: qsTr("When I work")
                Layout.columnSpan: page.wide ? 2 : 1
                Layout.leftMargin: 0
                Layout.rightMargin: 0
                Caption {
                    text: qsTr("hours per weekday and hour") + (page.heat ? " · " + qsTr("%n day(s)", "", page.heat.days) : "")
                    font.capitalization: Font.MixedCase
                    font.letterSpacing: 0
                }
                Heatmap {
                    cells: page.heat ? page.heat.cells : []
                    days: page.heat ? page.heat.days : 0
                }
            }
        }

        // summary table
        Card {
            visible: page.view === "summary"
            title: qsTr("Per %1").arg(page.group)
            DataTable {
                columns: [{ title: qsTr("Period"), w: 90 }, { title: qsTr("Worked"), w: 76, num: true },
                          { title: qsTr("Expected"), w: 80, num: true }, { title: qsTr("Extra"), w: 76, num: true },
                          { title: qsTr("Extra %1h").arg(page.altWeek), w: 84, num: true }, { title: qsTr("Days"), w: 50, num: true },
                          { title: qsTr("Days eq."), w: 70, num: true }, { title: qsTr("Billable"), w: 80, num: true }]
                         .concat(page.priced ? [{ title: Api.currency, w: 90, num: true }] : [])
                rows: page.rows.slice().reverse().map(r => ({
                    tint: r.key === page.currentKey ? Api.accentBg : undefined,
                    cells: [page.periodLong(r.key).replace(/^Week /, "W"), Api.fmtH(r.worked_h), Api.fmtH(r.expected_h),
                            { t: Api.fmtSigned(r.extra_h), c: Api.signColor(r.extra_h) },
                            { t: Api.fmtSigned(r.extra_alt_h), c: Api.signColor(r.extra_alt_h) },
                            String(r.days_worked), Api.fmtNum(r.days_equiv, 1), Api.fmtH(r.billable_h)]
                           .concat(page.priced ? [Api.fmtEur(r.amount)] : [])
                }))
                footer: page.priced && page.rows.length ? {
                    cells: [{ t: qsTr("Total"), b: true }, "", "", "", "", "", "",
                            { t: Api.fmtH(page.rows.reduce((a, r) => a + r.billable_h, 0)), b: true },
                            { t: Api.fmtEur(page.rows.reduce((a, r) => a + (r.amount || 0), 0)), b: true }]
                } : null
            }
            Caption {
                text: qsTr("Newest first") + " · " + qsTr("Extra = worked minus expected · Extra %1h = the same if a full week were %1 h · Days eq. = worked hours as full working days").arg(page.altWeek)
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }

        // weekly stats
        Card {
            visible: page.view === "summary" && !!page.summary && !!page.summary.stats
            title: qsTr("Extra hours per week")
            DataTable {
                readonly property var s: page.summary && page.summary.stats ? page.summary.stats : null
                function cell(v) { return v === null || v === undefined ? "–" : { t: Api.fmtSigned(v), c: Api.signColor(v) } }
                columns: [{ title: "", w: 160 }, { title: qsTr("Incl. this week"), w: 120, num: true },
                          { title: qsTr("Excl. this week"), w: 120, num: true }]
                rows: !s ? [] : [
                    [qsTr("Total, all weeks"), "net_h"], [qsTr("Total, last 4 weeks"), "last4_h"],
                    [qsTr("Total at %1 h/week").arg(page.altWeek), "net_alt_h"], [qsTr("Last 4 at %1 h/week").arg(page.altWeek), "last4_alt_h"],
                    [qsTr("Lowest week"), "min_h"], [qsTr("Lower quartile"), "q1_h"], [qsTr("Median week"), "median_h"],
                    [qsTr("Upper quartile"), "q3_h"], [qsTr("Highest week"), "max_h"]
                ].map(([label, k]) => ({ cells: [label, cell(s.with_current[k]), cell(s.without_current[k])] }))
            }
            Caption {
                text: qsTr("Extra = worked minus expected, per week, over the range above. This week's full expected hours already count, so \"Excl. this week\" is the fairer figure until the week is over.")
                font.capitalization: Font.MixedCase
                font.letterSpacing: 0
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }

        // invoice
        Card {
            visible: page.view === "invoice"
            title: qsTr("Invoice")
            actions: RowLayout {
                AppIconButton {
                    text: "‹"
                    name: qsTr("Previous month")
                    onClicked: page.shiftInvoice(-1)
                }
                Label {
                    text: Api.parseDate(page.invoiceMonth + "-01").toLocaleDateString(Api.locale, "MMM yyyy")
                    font.weight: Font.DemiBold
                }
                AppIconButton {
                    text: "›"
                    name: qsTr("Next month")
                    onClicked: page.shiftInvoice(1)
                }
            }

            DataTable {
                readonly property bool invPriced: page.invoice.some(r => r.amount !== null)
                // the hours count up to today: future days would only make the month look short
                readonly property var past: page.invoice.filter(r => !r.future)
                readonly property real worked: past.reduce((a, r) => a + r.worked_h, 0)
                readonly property real expected: past.reduce((a, r) => a + r.expected_h, 0)
                readonly property int daysWorked: page.invoice.filter(r => r.worked).length
                columns: [{ title: qsTr("Date"), w: 70 }, { title: qsTr("Worked"), w: 76, num: true },
                          { title: qsTr("Expected"), w: 80, num: true }, { title: qsTr("Reason"), w: 120 },
                          { title: "✓", w: 30, num: true }].concat(invPriced ? [{ title: Api.currency, w: 80, num: true }] : [])
                rows: page.invoice.map(r => ({
                    tint: [0, 6].indexOf(Api.parseDate(r.date).getDay()) >= 0 ? Api.line2 : undefined,
                    cells: [{ t: r.weekday + " " + Number(r.date.slice(8)), c: r.future ? Api.muted : undefined },
                            r.worked_h > 0 ? Api.fmtH(r.worked_h) : "",
                            { t: r.expected_h > 0 ? Api.fmtH(r.expected_h) : "", c: Api.muted },
                            { t: r.reason || "", c: Api.muted }, page.markCell(r.mark)]
                           .concat(invPriced ? [r.billable_h > 0 ? Api.fmtEur(r.amount) : ""] : [])
                }))
                footer: page.invoice.length ? {
                    cells: [{ t: qsTr("%n day(s)", "", daysWorked), b: true }, { t: Api.fmtH(worked), b: true }, Api.fmtH(expected),
                            { t: Api.shortOrExtra(worked - expected), c: Api.signColor(worked - expected) }, ""]
                           .concat(invPriced ? [{ t: Api.fmtEur(page.invoice.reduce((a, r) => a + (r.amount || 0), 0)), b: true }] : [])
                } : null
            }
            Label {
                visible: page.invoice.length > 0
                text: page.countsLine(page.invoiceCounts(page.invoice))
                color: Api.muted
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: page.invoice.length === 0
                text: qsTr("Nothing logged in this month")
                color: Api.muted
            }
        }
        Item { implicitHeight: 8 }
    }
}
