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
        // Send first: busy is set before the main view's onShow runs, so it doesn't refetch.
        _view.act(item.getId() as Symbol);
        _view.markNav();
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}
