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
    property string invoiceMonth: Api.isoDate(new Date()).slice(0, 7)
    property var invoice: []
    property string error: ""
    property string exportMessage: ""
    property bool exportOk: true

    readonly property bool wide: availableWidth >= 760
    readonly property var rows: summary ? summary.rows : []
    readonly property string currentKey: group === "week" ? Api.weekKey(Api.isoDate(new Date())) : ""
    readonly property real altWeek: summary && summary.alt_week_h ? summary.alt_week_h : 40
    readonly property bool priced: !!summary && summary.rate_h !== null

    contentWidth: availableWidth

    function periodLabel(key) {
        if (group === "week")
            return "W" + key.slice(5)
        if (group === "month")
            return Api.parseDate(key + "-01").toLocaleDateString(Qt.locale(), "MMM")
        return key.replace("-Q", " Q")
    }
    function periodLong(key) {
        if (group === "week")
            return qsTr("Week %1 · %2").arg(key.slice(5)).arg(key.slice(0, 4))
        if (group === "month")
            return Api.parseDate(key + "-01").toLocaleDateString(Qt.locale(), "MMMM yyyy")
        return key.replace("-Q", " Q")
    }
    function inProgress(key) { return key === currentKey ? " " + qsTr("(in progress)") : "" }

    function reload() {
        const range = { start: start, end: end }
        Api.request("GET", "/api/summary?" + Api.query(Object.assign({ group: group }, range)), undefined, function (d) {
            page.summary = d
            page.error = ""
        }, e => page.error = e)
        Api.request("GET", "/api/heatmap?" + Api.query(range), undefined, h => page.heat = h, () => page.heat = null)
        loadInvoice()
    }
    function loadInvoice() {
        Api.request("GET", "/api/invoice?month=" + invoiceMonth, undefined, r => page.invoice = r, e => page.error = e)
    }
    function shiftInvoice(n) {
        const d = Api.parseDate(invoiceMonth + "-01")
        d.setMonth(d.getMonth() + n)
        invoiceMonth = Api.isoDate(d).slice(0, 7)
    }
    function setRange(s, e) {
        startField.text = s
        endField.text = e
        start = s
        end = e
        reload()
    }

    onInvoiceMonthChanged: loadInvoice()
    Component.onCompleted: reload()
    onVisibleChanged: if (visible) reload()
    Connections {
        target: Api
        function onChanged() { page.reload() }
        function onServerChanged() { page.reload() }
    }

    // ---- chart data ----------------------------------------------------------------

    readonly property var extraRows: rows.map(r => ({
        label: periodLabel(r.key), dim: r.key === currentKey,
        parts: [{ v: r.extra_h, color: r.extra_h >= 0 ? Api.workColor : Api.errorColor }],
        tip: periodLong(r.key) + inProgress(r.key) + "\n"
             + qsTr("%1 worked · %2 expected").arg(Api.fmtH(r.worked_h)).arg(Api.fmtH(r.expected_h)) + "\n" + Api.fmtSigned(r.extra_h)
    }))

    readonly property var balanceRows: {
        let acc = 0
        return rows.map(r => {
            acc += r.extra_h
            return { label: periodLabel(r.key), parts: [{ v: acc }],
                     tip: periodLong(r.key) + inProgress(r.key) + "\n" + qsTr("balance %1").arg(Api.fmtSigned(acc))
                          + "\n" + qsTr("this period %1").arg(Api.fmtSigned(r.extra_h)) }
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

        // filters
        Card {
            title: qsTr("Summary")
            Layout.topMargin: 12
            actions: ExportButtons {
                start: page.start
                end: page.end
                onMessage: (text, ok) => { page.exportMessage = text; page.exportOk = ok }
            }

            ChipRow {
                label: qsTr("Group by")
                model: ["week", "month", "quarter", "year"]
                current: page.group
                onPicked: value => { page.group = value; page.reload() }
            }
            ChipRow {
                label: qsTr("Range")
                model: [qsTr("All"), qsTr("This year"), qsTr("Last 12 weeks"), qsTr("Last 6 months")]
                current: page.start === "" && page.end === "" ? qsTr("All") : ""
                onPicked: value => {
                    const today = new Date()
                    if (value === qsTr("All"))
                        page.setRange("", "")
                    else if (value === qsTr("This year"))
                        page.setRange(today.getFullYear() + "-01-01", "")
                    else if (value === qsTr("Last 12 weeks"))
                        page.setRange(Api.addDays(Api.isoDate(today), -83), "")
                    else
                        page.setRange(Api.isoDate(new Date(today.getFullYear(), today.getMonth() - 5, 1)), "")
                }
            }
            RowLayout {
                spacing: 8
                Layout.fillWidth: true
                TextField {
                    id: startField
                    placeholderText: qsTr("From (first log)")
                    validator: RegularExpressionValidator { regularExpression: /^(\d{4}-\d{2}-\d{2})?$/ }
                    Layout.fillWidth: true
                    onEditingFinished: if (acceptableInput && text !== page.start) { page.start = text; page.reload() }
                }
                TextField {
                    id: endField
                    placeholderText: qsTr("To (today)")
                    validator: RegularExpressionValidator { regularExpression: /^(\d{4}-\d{2}-\d{2})?$/ }
                    Layout.fillWidth: true
                    onEditingFinished: if (acceptableInput && text !== page.end) { page.end = text; page.reload() }
                }
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

        // charts
        GridLayout {
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
                Caption { text: qsTr("per period, vs expected"); font.capitalization: Font.MixedCase; font.letterSpacing: 0 }
                ColumnChart { rows: page.extraRows; signedAxis: true }
            }
            Card {
                title: qsTr("Balance")
                Layout.leftMargin: 0
                Layout.rightMargin: 0
                Layout.preferredWidth: 1
                Caption {
                    text: qsTr("cumulative extra hours")
                          + (page.balanceRows.length ? " · " + qsTr("now %1").arg(Api.fmtSigned(page.balanceRows[page.balanceRows.length - 1].parts[0].v)) : "")
                    font.capitalization: Font.MixedCase
                    font.letterSpacing: 0
                }
                ColumnChart { rows: page.balanceRows; line: true; signedAxis: true }
            }
            Card {
                title: qsTr("Hours by type")
                Layout.columnSpan: page.wide ? 2 : 1
                Layout.leftMargin: 0
                Layout.rightMargin: 0
                Caption { text: qsTr("work only; breaks excluded"); font.capitalization: Font.MixedCase; font.letterSpacing: 0 }
                ColumnChart { rows: page.typeRows; implicitHeight: 200 }
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
                RankedBars { items: page.projectItems }
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
            title: qsTr("Per %1").arg(page.group)
            DataTable {
                columns: [{ title: qsTr("Period"), w: 90 }, { title: qsTr("Worked"), w: 76, num: true },
                          { title: qsTr("Expected"), w: 80, num: true }, { title: qsTr("Extra"), w: 76, num: true },
                          { title: qsTr("Extra %1h").arg(page.altWeek), w: 84, num: true }, { title: qsTr("Days"), w: 50, num: true },
                          { title: qsTr("Days eq."), w: 70, num: true }, { title: qsTr("Billable"), w: 80, num: true }]
                         .concat(page.priced ? [{ title: "€", w: 90, num: true }] : [])
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
            Caption { text: qsTr("Newest first"); font.capitalization: Font.MixedCase; font.letterSpacing: 0 }
        }

        // weekly stats
        Card {
            visible: !!page.summary && !!page.summary.stats
            title: qsTr("Weekly stats")
            DataTable {
                readonly property var s: page.summary && page.summary.stats ? page.summary.stats : null
                function cell(v) { return v === null || v === undefined ? "–" : { t: Api.fmtSigned(v), c: Api.signColor(v) } }
                columns: [{ title: "", w: 130 }, { title: qsTr("Incl. this week"), w: 120, num: true },
                          { title: qsTr("Excl. this week"), w: 120, num: true }]
                rows: !s ? [] : [
                    [qsTr("Net"), "net_h"], [qsTr("Last 4 weeks"), "last4_h"],
                    [qsTr("Net at %1 h").arg(page.altWeek), "net_alt_h"], [qsTr("Last 4 at %1 h").arg(page.altWeek), "last4_alt_h"],
                    [qsTr("Min week"), "min_h"], ["Q1", "q1_h"], [qsTr("Median"), "median_h"], ["Q3", "q3_h"], [qsTr("Max week"), "max_h"]
                ].map(([label, k]) => ({ cells: [label, cell(s.with_current[k]), cell(s.without_current[k])] }))
            }
        }

        // invoice
        Card {
            title: qsTr("Invoice")
            actions: RowLayout {
                ToolButton { text: "‹"; font.pixelSize: 18; onClicked: page.shiftInvoice(-1) }
                Label {
                    text: Api.parseDate(page.invoiceMonth + "-01").toLocaleDateString(Qt.locale(), "MMM yyyy")
                    font.weight: Font.DemiBold
                }
                ToolButton { text: "›"; font.pixelSize: 18; onClicked: page.shiftInvoice(1) }
            }

            DataTable {
                readonly property bool invPriced: page.invoice.some(r => r.amount !== null)
                readonly property real worked: page.invoice.reduce((a, r) => a + r.worked_h, 0)
                readonly property real expected: page.invoice.reduce((a, r) => a + r.expected_h, 0)
                readonly property int daysWorked: page.invoice.filter(r => r.worked).length
                columns: [{ title: qsTr("Date"), w: 70 }, { title: qsTr("Worked"), w: 76, num: true },
                          { title: qsTr("Expected"), w: 80, num: true }, { title: qsTr("Reason"), w: 120 },
                          { title: "✓", w: 30, num: true }].concat(invPriced ? [{ title: "€", w: 80, num: true }] : [])
                rows: page.invoice.map(r => ({
                    tint: [0, 6].indexOf(Api.parseDate(r.date).getDay()) >= 0 ? Api.line2 : undefined,
                    cells: [r.weekday + " " + Number(r.date.slice(8)), r.worked_h > 0 ? Api.fmtH(r.worked_h) : "",
                            { t: r.expected_h > 0 ? Api.fmtH(r.expected_h) : "", c: Api.muted },
                            { t: r.reason || "", c: Api.muted }, { t: r.worked ? "✓" : "", c: Api.workColor }]
                           .concat(invPriced ? [r.billable_h > 0 ? Api.fmtEur(r.amount) : ""] : [])
                }))
                footer: page.invoice.length ? {
                    cells: [{ t: qsTr("%n day(s)", "", daysWorked), b: true }, { t: Api.fmtH(worked), b: true }, Api.fmtH(expected),
                            { t: Api.fmtSigned(worked - expected), c: Api.signColor(worked - expected) }, ""]
                           .concat(invPriced ? [{ t: Api.fmtEur(page.invoice.reduce((a, r) => a + (r.amount || 0), 0)), b: true }] : [])
                } : null
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
