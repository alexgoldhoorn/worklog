import QtQuick
import QtTest
import WorkLogApp

// The Reports page's tabs and the invoice's day counts.
TestCase {
    name: "Reports"
    width: 480
    height: 900
    visible: true
    when: windowShown

    Component { id: reportsPage; ReportsPage {} }

    function row(date, o) {
        return Object.assign({ date: date, worked: false, workable: true, expected_h: 7, future: false, mark: "" }, o)
    }
    readonly property var rows: [
        row("2026-11-14", { worked: true, workable: false, expected_h: 0, mark: "worked" }),   // a Saturday worked
        row("2026-11-12", { workable: false, expected_h: 0, mark: "holiday" }),               // public holiday
        row("2026-11-11", { mark: "missed" }),
        row("2026-11-30", { future: true }),
        row("2026-11-10", { worked: true, mark: "worked" })
    ]

    function test_invoice_counts() {
        const p = createTemporaryObject(reportsPage, this)
        compare(p.invoiceCounts(rows), { days: 5, workable: 3, expected: 3, worked: 2, offDays: 1 })
        compare(p.countsLine(p.invoiceCounts(rows)), "5 days · 3 workable · 3 expected · 2 worked (1 on non-workable days)")
        compare(p.countsLine({ days: 30, workable: 21, expected: 20, worked: 17, offDays: 0 }),
                "30 days · 21 workable · 20 expected · 17 worked")
    }

    function test_invoice_totals_count_up_to_today() {
        const p = createTemporaryObject(reportsPage, this)
        const t = p.invoiceTotals([
            { worked_h: 8, expected_h: 7, amount: 400, future: false },
            { worked_h: 2, expected_h: 7, amount: 100, future: true }
        ])
        compare(t, { worked: 8, expected: 7, amount: 400 })
    }

        function test_tabs_default_to_summary() {
        const p = createTemporaryObject(reportsPage, this)
        compare(p.view, "summary")
        p.view = "invoice"
        compare(p.view, "invoice")
    }
}
