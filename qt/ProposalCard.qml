pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// The work-calendar meetings of one day. A meeting without a block can be added as one (the
// server cuts it out of whatever was logged there) or dismissed. The Timer shows only those;
// the Log (`showAll`) lists every meeting, the logged and the dismissed ones marked.
// Hidden when there is nothing to show.
Card {
    id: card
    property string date
    property var meetings: []      // the day's `meetings` (or `proposals` from an older server)
    property bool showAll: false

    readonly property var rows: showAll ? meetings : open(meetings)

    signal failed(string error)

    // the meetings still waiting for an answer
    function open(list) {
        return (list || []).filter(m => !m.logged && !m.dismissed)
    }

    visible: rows.length > 0
    title: showAll ? qsTr("Work calendar") : qsTr("Calendar proposals")

    Caption {
        text: card.showAll ? qsTr("The day's meetings · add one to cut it into the log")
                           : qsTr("Meetings without a block")
        font.capitalization: Font.MixedCase
        font.letterSpacing: 0
        wrapMode: Text.Wrap
        Layout.fillWidth: true
    }

    Repeater {
        model: card.rows
        delegate: ColumnLayout {
            id: meeting
            required property var modelData
            required property int index
            readonly property bool logged: !!modelData.logged
            readonly property bool dismissed: !!modelData.dismissed
            spacing: 4
            Layout.fillWidth: true

            Rectangle {
                visible: meeting.index > 0
                implicitHeight: 1
                color: meeting.Material.dividerColor
                Layout.fillWidth: true
            }
            RowLayout {
                spacing: 12
                opacity: meeting.logged || meeting.dismissed ? 0.6 : 1
                Layout.fillWidth: true
                Label {
                    text: meeting.modelData.start + "–" + meeting.modelData.end
                    font.features: { "tnum": 1 }
                    Layout.preferredWidth: 96
                }
                Label {
                    text: meeting.modelData.title || qsTr("(no title)")
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Label {
                    visible: meeting.logged || meeting.dismissed
                    text: meeting.logged ? qsTr("✓ logged") : qsTr("dismissed")
                    color: meeting.logged ? Api.workColor : Api.muted
                    font.pixelSize: 12
                }
            }
            RowLayout {
                visible: !meeting.logged
                Layout.alignment: Qt.AlignRight
                Button {
                    visible: !meeting.dismissed
                    text: qsTr("Dismiss")
                    flat: true
                    onClicked: Api.request("POST", "/api/calendar/dismiss",
                                           { date: card.date, start: meeting.modelData.start, title: meeting.modelData.title },
                                           null, e => card.failed(e))
                }
                Button {
                    text: qsTr("Add as meeting")
                    highlighted: !meeting.dismissed
                    flat: meeting.dismissed
                    onClicked: Api.request("POST", "/api/calendar/add",
                                           { date: card.date, start: meeting.modelData.start, end: meeting.modelData.end, title: meeting.modelData.title },
                                           null, e => card.failed(e))
                }
            }
        }
    }
}
