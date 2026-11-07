pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// One column per period with a value axis. Rows: [{label, tip, parts: [{v, color}], dim}].
// Bars stack their parts (negative parts grow down from zero); `line` draws parts[0] as a line instead.
Item {
    id: chart
    property var rows: []
    property bool line: false
    property bool signedAxis: false
    property color lineColor: Api.accent

    implicitHeight: 180
    Layout.fillWidth: true

    readonly property real ml: 40
    readonly property real mr: 8
    readonly property real mt: 10
    readonly property real mb: 22
    readonly property real iw: Math.max(1, width - ml - mr)
    readonly property real ih: Math.max(1, height - mt - mb)
    readonly property real slot: iw / Math.max(rows.length, 1)
    readonly property real barW: Math.min(24, Math.max(2, slot - 2))

    // [lo, hi, step] with "nice" tick steps, always including zero
    readonly property var axis: {
        let lo = 0, hi = 0
        for (const r of rows) {
            let pos = 0, neg = 0
            for (const p of r.parts)
                p.v >= 0 ? pos += p.v : neg += p.v
            hi = Math.max(hi, pos)
            lo = Math.min(lo, neg)
        }
        const raw = (hi - lo) / 4 || 1
        const p10 = Math.pow(10, Math.floor(Math.log10(raw)))
        const step = [1, 2, 2.5, 5, 10].map(m => m * p10).find(s => s >= raw) || p10 * 10
        lo = Math.floor(lo / step) * step
        hi = Math.ceil(hi / step) * step
        if (hi === lo)
            hi = lo + step
        return [lo, hi, step]
    }
    readonly property var ticks: {
        const out = []
        for (let v = axis[0]; v <= axis[1] + 1e-9; v += axis[2])
            out.push(Math.round(v * 1000) / 1000)
        return out
    }
    readonly property int labelEvery: Math.ceil(rows.length / Math.max(2, Math.floor(iw / 44)))

    function py(v) { return mt + ih - (v - axis[0]) / (axis[1] - axis[0]) * ih }
    function px(i) { return ml + i * slot }

    // y grid and labels
    Repeater {
        model: chart.ticks
        delegate: Item {
            id: tick
            required property real modelData
            Rectangle {
                x: chart.ml
                y: chart.py(tick.modelData)
                width: chart.iw
                height: 1
                color: tick.modelData === 0 ? Api.faint : Api.line2
            }
            Text {
                x: 0
                width: chart.ml - 6
                y: chart.py(tick.modelData) - height / 2
                text: (chart.signedAxis && tick.modelData > 0 ? "+" : "") + Api.fmtNum(tick.modelData, 1)
                color: Api.muted
                font.pixelSize: 10
                horizontalAlignment: Text.AlignRight
            }
        }
    }

    // bars
    Repeater {
        model: chart.line ? [] : chart.rows
        delegate: Item {
            id: col
            required property var modelData
            required property int index
            readonly property var segments: {
                let pos = 0, neg = 0
                return modelData.parts.filter(p => p.v !== 0).map(p => {
                    const from = p.v >= 0 ? pos : neg + p.v
                    p.v >= 0 ? pos += p.v : neg += p.v
                    return { from: from, to: from + Math.abs(p.v), color: p.color }
                })
            }
            x: chart.px(index) + (chart.slot - chart.barW) / 2
            width: chart.barW
            height: chart.height
            opacity: modelData.dim ? 0.55 : 1

            Repeater {
                model: col.segments
                delegate: Rectangle {
                    required property var modelData
                    width: col.width
                    y: chart.py(modelData.to)
                    height: Math.max(1, chart.py(modelData.from) - chart.py(modelData.to) - (col.segments.length > 1 ? 1 : 0))
                    radius: col.segments.length > 1 ? 0 : 2
                    color: modelData.color
                }
            }
        }
    }

    // line with a wash down to zero
    Canvas {
        id: canvas
        anchors.fill: parent
        visible: chart.line
        onPaint: {
            const ctx = getContext("2d")
            ctx.reset()
            if (!chart.line || chart.rows.length === 0)
                return
            const pts = chart.rows.map((r, i) => [chart.px(i) + chart.slot / 2, chart.py(r.parts[0].v)])
            const zero = chart.py(0)
            ctx.beginPath()
            ctx.moveTo(pts[0][0], zero)
            for (const p of pts)
                ctx.lineTo(p[0], p[1])
            ctx.lineTo(pts[pts.length - 1][0], zero)
            ctx.closePath()
            ctx.fillStyle = Qt.alpha(chart.lineColor, 0.15)
            ctx.fill()
            ctx.beginPath()
            pts.forEach((p, i) => i ? ctx.lineTo(p[0], p[1]) : ctx.moveTo(p[0], p[1]))
            ctx.strokeStyle = chart.lineColor
            ctx.lineWidth = 2
            ctx.stroke()
            const last = pts[pts.length - 1]
            ctx.beginPath()
            ctx.arc(last[0], last[1], 4, 0, 2 * Math.PI)
            ctx.fillStyle = chart.lineColor
            ctx.fill()
        }
        Connections {
            target: chart
            function onRowsChanged() { canvas.requestPaint() }
            function onWidthChanged() { canvas.requestPaint() }
            function onHeightChanged() { canvas.requestPaint() }
            function onLineColorChanged() { canvas.requestPaint() }
        }
    }

    // x labels
    Repeater {
        model: chart.rows
        delegate: Text {
            required property var modelData
            required property int index
            readonly property bool last: index === chart.rows.length - 1
            visible: last || (index % chart.labelEvery === 0 && chart.rows.length - 1 - index >= chart.labelEvery)
            x: chart.px(index) + chart.slot / 2 - width / 2
            y: chart.height - height
            text: modelData.label
            color: Api.muted
            font.pixelSize: 10
        }
    }

    // hover / touch: one hit area per period
    Repeater {
        model: chart.rows
        delegate: MouseArea {
            id: hit
            required property var modelData
            required property int index
            x: chart.px(index)
            y: chart.mt
            width: chart.slot
            height: chart.ih
            hoverEnabled: true
            Rectangle {
                anchors.fill: parent
                color: Api.fg
                opacity: hit.containsMouse || hit.pressed ? 0.06 : 0
            }
            ToolTip.visible: containsMouse || pressed
            ToolTip.delay: 0
            ToolTip.text: modelData.tip
        }
    }

    Label {
        anchors.centerIn: parent
        visible: chart.rows.length === 0
        text: qsTr("No data")
        color: Api.muted
    }
}
