import QtQuick
import QtQuick.Shapes

// Line icons on a 24 x 24 grid, drawn as paths so they take any colour and size. The web's
// navigation (templates/base.html) uses the same paths: change an icon in both places.
Item {
    id: icon
    property string name
    property color color: Api.fg
    property real size: 22
    property real strokeWidth: 2   // "more" (three dots) uses 3

    readonly property var paths: ({
        "timer": "M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18z M12 7v5l3 2",
        "week": "M4 6h16v14H4z M4 10h16 M8 3v4 M16 3v4",
        "pomodoro": "M12 8a7 7 0 1 0 0 14a7 7 0 1 0 0-14z M12 8c0-2 1-4 3-5 M8.5 5.5l3.5 2.5l3.5-2.5",
        "day": "M12 8a4 4 0 1 0 0 8a4 4 0 1 0 0-8z M12 2v2 M12 20v2 M2 12h2 M20 12h2 M5 5l1.5 1.5 M17.5 17.5L19 19 M5 19l1.5-1.5 M17.5 6.5L19 5",
        "reports": "M4 20h16 M7 20v-6 M12 20V6 M17 20v-9",
        "expected": "M4 6h16v14H4z M4 10h16 M8 3v4 M16 3v4 M9 15l2 2l4-4",
        "find": "M11 4a7 7 0 1 0 0 14a7 7 0 1 0 0-14z M16 16l4 4",
        "settings": "M4 7h10 M18 7h2 M4 17h2 M10 17h10 M16 5v4 M8 15v4",
        "more": "M5 12h.01 M12 12h.01 M19 12h.01",
        "quit": "M12 3v9 M6.4 6.4a8 8 0 1 0 11.2 0",
        "add": "M12 5v14 M5 12h14"
    })

    implicitWidth: size
    implicitHeight: size

    Shape {
        anchors.centerIn: parent
        width: 24
        height: 24
        scale: icon.size / 24
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeColor: icon.color
            strokeWidth: icon.strokeWidth
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: icon.paths[icon.name] || "" }
        }
    }
}
