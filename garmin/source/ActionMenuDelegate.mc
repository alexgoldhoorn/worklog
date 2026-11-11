import Toybox.Lang;
import Toybox.WatchUi;

class ActionMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var _view as MainView;

    function initialize(view as MainView) {
        Menu2InputDelegate.initialize();
        _view = view;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        if (!_view.settled()) {
            return; // the release of the press that opened the menu
        }
        if (item.getId() == :pause) {
            var choices = Logic.breakChoices(_view.status);
            if (choices.size() > 1) {
                // Pick the break type; the action menu stays underneath and closes with it.
                var menu = new WatchUi.Menu2({:title => "Break"});
                for (var i = 0; i < choices.size(); i++) {
                    menu.addItem(new WatchUi.MenuItem(choices[i], null, choices[i], null));
                }
                _view.markNav();
                WatchUi.pushView(menu, new BreakMenuDelegate(_view), WatchUi.SLIDE_UP);
                return;
            }
        }
        // Send first: busy is set before the main view's onShow runs, so it doesn't refetch.
        _view.act(item.getId() as Symbol, null);
        _view.markNav();
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}

//! Second step of Pause: the break type. Same press/release guard as the action menu.
class BreakMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var _view as MainView;

    function initialize(view as MainView) {
        Menu2InputDelegate.initialize();
        _view = view;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        if (!_view.settled()) {
            return;
        }
        _view.act(:pause, Logic.pauseBody(item.getId() as String));
        _view.markNav();
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE); // this menu
        WatchUi.popView(WatchUi.SLIDE_DOWN);      // the action menu
    }
}
