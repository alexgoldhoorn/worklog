import Toybox.Attention;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! The full widget: state, a clock that ticks locally, the project and a feedback line.
//! It always shows the status the server returned, never a local guess.
class MainView extends WatchUi.View {
    var status as Dictionary or Null;
    var message as String;
    var busy as Boolean;
    var receivedAt as Number;
    private var _navAt as Number;
    private var _client as WorklogClient;
    private var _timer as Timer.Timer or Null;

    function initialize() {
        View.initialize();
        status = null;
        message = "";
        busy = false;
        receivedAt = 0;
        _navAt = -10000;
        _client = new WorklogClient();
        _timer = null;
    }

    //! Called when the action menu opens or closes. A key press and its release can land on two
    //! different views (the release opening the menu's first item, or reopening the menu), so
    //! selects within 500 ms of a menu change are ignored.
    function markNav() as Void {
        _navAt = System.getTimer();
    }

    function settled() as Boolean {
        return System.getTimer() - _navAt > 500;
    }

    function onShow() as Void {
        if (_timer == null) {
            _timer = new Timer.Timer();
            _timer.start(method(:onTick), 1000, true);
        }
        // Coming back from the action menu while its request is in flight: don't send a second one.
        if (!busy) {
            refresh();
        }
    }

    function onHide() as Void {
        if (_timer != null) {
            _timer.stop();
            _timer = null;
        }
    }

    function onTick() as Void {
        if (status != null && !"stopped".equals(state())) {
            WatchUi.requestUpdate();
        }
    }

    function state() as String or Null {
        return status == null ? null : (status as Dictionary)["state"] as String or Null;
    }

    function refresh() as Void {
        busy = true;
        message = status == null ? "" : "…";
        _client.call(:status, null, method(:onStatus));
        WatchUi.requestUpdate();
    }

    function onStatus(ok as Boolean, result as Dictionary or String) as Void {
        busy = false;
        if (ok) {
            status = result as Dictionary;
            receivedAt = System.getTimer();
            message = "";
        } else {
            message = result as String;
        }
        WatchUi.requestUpdate();
    }

    //! Start, pause or stop. Pause sends no type, so the server's default break type applies.
    function act(action as Symbol) as Void {
        if (busy) {
            return;
        }
        busy = true;
        message = "…";
        _client.call(action, action == :start ? Logic.startBody(status) : {}, method(:onAction));
        WatchUi.requestUpdate();
    }

    function onAction(ok as Boolean, result as Dictionary or String) as Void {
        busy = false;
        if (ok) {
            status = result as Dictionary;
            receivedAt = System.getTimer();
            message = Logic.stateLabel(state());
            buzz([new Attention.VibeProfile(50, 150)]);
        } else {
            message = result as String;
            buzz([
                new Attention.VibeProfile(75, 150), new Attention.VibeProfile(0, 100),
                new Attention.VibeProfile(75, 150), new Attention.VibeProfile(0, 100),
                new Attention.VibeProfile(75, 150)
            ]);
        }
        WatchUi.requestUpdate();
    }

    private function buzz(pattern as Array<Attention.VibeProfile>) as Void {
        if (Attention has :vibrate) {
            Attention.vibrate(pattern);
        }
    }

    function onUpdate(dc as Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_BLACK);
        dc.clear();

        var st = state();
        var label = status == null ? (busy ? "…" : "") : Logic.stateLabel(st);
        var colour = Graphics.COLOR_WHITE;
        if ("working".equals(st)) {
            colour = Graphics.COLOR_GREEN;
        } else if ("break".equals(st)) {
            colour = Graphics.COLOR_ORANGE;
        }
        dc.setColor(colour, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.24, Graphics.FONT_MEDIUM, label, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);

        if (status != null) {
            var s = status as Dictionary;
            var sub = "";
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            if ("stopped".equals(st)) {
                sub = "Today " + Logic.hours(s["today_work_h"]) + " h";
            } else {
                var elapsed = s["elapsed_s"] as Number or Null;
                if (elapsed != null) {
                    elapsed = elapsed + (System.getTimer() - receivedAt) / 1000;
                }
                dc.drawText(cx, h * 0.46, Graphics.FONT_NUMBER_MEDIUM, Logic.formatElapsed(elapsed),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
                var project = s["project"];
                var type = s["type"];
                sub = project instanceof String && project.length() > 0 ? project : (type instanceof String ? type : "");
            }
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, h * 0.66, Graphics.FONT_SMALL, sub, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h * 0.80, Graphics.FONT_XTINY, message, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
    }
}
