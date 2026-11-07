import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

//! One line in the glance list: state, elapsed time and project, or an error.
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
    }

    function onShow() as Void {
        _client.call(:status, null, method(:onStatus));
    }

    function onStatus(ok as Boolean, result as Dictionary or String) as Void {
        _ok = ok;
        _text = ok ? Logic.glanceLine(result as Dictionary) : result as String;
        WatchUi.requestUpdate();
    }

    function onUpdate(dc as Dc) as Void {
        dc.setColor(_ok ? Graphics.COLOR_WHITE : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(0, dc.getHeight() / 2, Graphics.FONT_TINY, _text,
            Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
