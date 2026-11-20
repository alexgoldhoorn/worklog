pragma ComponentBehavior: Bound
import QtQuick
import QtQuick.Layouts

// The Today screen: the Timer while it shows today, the Log for any other day. Main.qml's header
// steps the day (step/show/pickDate) and shows `heading`; the two pages stay what they were.
Item {
    id: screen
    property string viewDate: ""   // "" = today, so the screen follows the date over midnight
    readonly property string today: Api.status ? Api.status.date : Api.today()
    readonly property string date: viewDate || today
    readonly property bool isToday: viewDate === ""
    readonly property string heading: {
        // "Tue 20 Oct", with the year when it is not this year (the web's fmtDayTitle)
        const d = Api.parseDate(date).toLocaleDateString(Api.locale, date.slice(0, 4) === Api.today().slice(0, 4) ? "ddd d MMM" : "ddd d MMM yyyy")
        return isToday ? qsTr("Today · %1").arg(d) : d
    }

    property alias timer: timerPage   // for tests
    property alias log: logPage
    property alias picker: datePicker

    function show(iso) { viewDate = !iso || iso === today ? "" : iso }
    function step(days) { show(Api.addDays(date, days)) }
    function pickDate() { datePicker.openFor(date) }

    onViewDateChanged: if (viewDate !== "" && logPage.date !== viewDate) logPage.date = viewDate

    // ← / → step a day from today as well (the Log has its own for the other days);
    // not while a dialog or the calendar is open, and a focused text field keeps its arrow keys
    readonly property bool shortcutsOn: visible && isToday && !timerPage.dialog.visible && !datePicker.visible
                                        && Api.keyShortcuts && Api.focusFree(Window.window ? Window.window.activeFocusItem : null)
    Shortcut { sequence: "Left"; enabled: screen.shortcutsOn; onActivated: screen.step(-1) }
    Shortcut { sequence: "Right"; enabled: screen.shortcutsOn; onActivated: screen.step(1) }

    StackLayout {
        anchors.fill: parent
        currentIndex: screen.isToday ? 0 : 1
        TimerPage {
            id: timerPage
            onOpenDay: date => screen.show(date)
        }
        DayPage {
            id: logPage
            showArrows: false               // the header has them
            navEnabled: !datePicker.visible
            // its own "Back to today", date picker and arrow keys move the screen along
            onDateChanged: if (!screen.isToday) screen.show(date)
        }
    }

    DatePicker {
        id: datePicker
        date: screen.date
        onPicked: iso => screen.show(iso)
    }
}
