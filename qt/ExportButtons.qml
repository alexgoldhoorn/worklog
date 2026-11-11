import QtQuick
import QtCore
import QtQuick.Controls
import QtQuick.Dialogs
import QtQuick.Layouts
import WorkLogApp

// CSV / XLSX export of a date range, saved where the user picks.
RowLayout {
    id: root
    property string start: ""    // empty = from the first logged day
    property string end: ""      // empty = today
    signal message(string text, bool ok)

    property string format: "csv"

    spacing: 6

    Button {
        text: "CSV"
        flat: true
        onClicked: { root.format = "csv"; saveDialog.open() }
    }
    Button {
        text: "XLSX"
        flat: true
        onClicked: { root.format = "xlsx"; saveDialog.open() }
    }

    FileDialog {
        id: saveDialog
        fileMode: FileDialog.SaveFile
        title: qsTr("Export %1").arg(root.format.toUpperCase())
        nameFilters: root.format === "csv" ? [qsTr("CSV files (*.csv)")] : [qsTr("Excel files (*.xlsx)")]
        defaultSuffix: root.format
        currentFolder: StandardPaths.writableLocation(StandardPaths.DownloadLocation)
        selectedFile: currentFolder + "/worklog-" + (root.start || "all") + "-" + (root.end || Api.today())
                      + "." + root.format
        onAccepted: {
            const q = Api.query({ start: root.start, end: root.end })
            downloader.download(Api.baseUrl + "/api/export." + root.format + (q ? "?" + q : ""),
                                Api.authHeader(), selectedFile)
        }
    }

    FileDownloader {
        id: downloader
        onFinished: path => root.message(qsTr("Saved %1").arg(path), true)
        onFailed: msg => root.message(qsTr("Export failed: %1").arg(msg), false)
    }
}
