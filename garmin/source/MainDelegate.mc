import Toybox.Lang;
import Toybox.WatchUi;

//! Select (button or tap) opens the action menu for the current state.
class MainDelegate extends WatchUi.BehaviorDelegate {
    private var _view as MainView;

    function initialize(view as MainView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        if (_view.busy || !_view.settled()) {
            return true; // a request is in flight, or the menu just closed: ignore
        }
        if (_view.status == null) {
            _view.refresh(); // the first load failed: Select retries
            return true;
        }
        var menu = new WatchUi.Menu2({:title => "worklog"});
        var actions = Logic.actionsFor(_view.state());
        for (var i = 0; i < actions.size(); i++) {
            menu.addItem(new WatchUi.MenuItem(Logic.actionLabel(actions[i]), null, actions[i], null));
        }
        _view.markNav();
        WatchUi.pushView(menu, new ActionMenuDelegate(_view), WatchUi.SLIDE_UP);
        return true;
    }

    function onMenu() as Boolean {
        return onSelect();
    }
}
