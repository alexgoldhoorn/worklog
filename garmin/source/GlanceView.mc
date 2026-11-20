import Toybox.Application;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;

//! One line in the glance list: state, elapsed time and project. The last answer is cached in
//! Application.Storage and shown at once (marked " ?" when old); the fetch then replaces it.
(:glance)
class WorklogGlanceView extends WatchUi.GlanceView {
    private var _client as WorklogClient;
    private var _text as String;
    private var _ok as Boolean;

    function initialize() {
        GlanceView.initialize();
        _client = new WorklogClient();
        _text = "…";
        _ok = true;
        var c = Application.Storage.getValue("glance");
        if (c instanceof Dictionary) {
            _text = Logic.cachedLine(c, Time.now().value(), false);
        }
    }

    function onShow() as Void {
        _client.call(:status, null, method(:onStatus));
    }

    function onStatus(ok as Boolean, result as Dictionary or String, code as Number) as Void {
        _ok = ok;
        if (ok) {
            _text = Logic.glanceLine(result as Dictionary);
        } else {
            // Keep the last known state when the phone is away; give the reason only if there is none.
            var c = Application.Storage.getValue("glance");
            _text = c instanceof Dictionary ? Logic.cachedLine(c, Time.now().value(), true) : result as String;
        }
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(_ok ? Graphics.COLOR_WHITE : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(0, dc.getHeight() / 2, Graphics.FONT_TINY, _text,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
