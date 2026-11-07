import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

(:glance)
class WorklogApp extends Application.AppBase {

    function initialize() {
        AppBase.initialize();
    }

    function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var view = new MainView();
        return [view, new MainDelegate(view)];
    }

    (:glance)
    function getGlanceView() as [WatchUi.GlanceView] or [WatchUi.GlanceView, WatchUi.GlanceViewDelegate] or Null {
        return [new WorklogGlanceView()];
    }
}
