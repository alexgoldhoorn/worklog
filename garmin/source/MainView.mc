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
    private var _watchdog as Timer.Timer or Null;
    private var _ticks as Number;
    private var _drawnMin as Number;
    private var _keep as Boolean;
    private var _acting as Boolean;

    function initialize() {
        View.initialize();
        status = null;
        message = "";
        busy = false;
        receivedAt = 0;
        _navAt = -10000;
        _client = new WorklogClient();
        _timer = null;
        _watchdog = null;
        _ticks = 0;
        _drawnMin = -1;
        _keep = false;
        _acting = false;
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
            _ticks = 0;
            _timer.start(method(:onTick), 10000, true);
        }
        // Coming back from the action menu while its request is in flight: don't send a second one.
        if (!busy) {
            refresh(false);
        }
    }

    function onHide() as Void {
        if (_timer != null) {
            _timer.stop();
            _timer = null;
        }
    }

    //! Every 10 s: redraw only when the minute shown has changed; every 60 s fetch the status
    //! again (not while a request is in flight).
    function onTick() as Void {
        _ticks++;
        if (_ticks % 6 == 0 && !busy) {
            refresh(true);
            return;
        }
        if (status != null && !"stopped".equals(state()) && shownMinutes() != _drawnMin) {
            WatchUi.requestUpdate();
        }
    }

    function state() as String or Null {
        return status == null ? null : (status as Dictionary)["state"] as String or Null;
    }

    //! Whole minutes of elapsed time as drawn now (-1 when there is no clock).
    private function shownMinutes() as Number {
        var e = status == null ? null : (status as Dictionary)["elapsed_s"];
        if (!(e instanceof Number)) {
            return -1;
        }
        return (e + (System.getTimer() - receivedAt) / 1000) / 60;
    }

    //! quiet: a background refresh, which neither shows "…" nor keeps a failure on screen.
    function refresh(quiet as Boolean) as Void {
        setBusy(true);
        if (!quiet) {
            message = status == null ? "" : "…";
        }
        _client.call(:status, null, method(:onStatus));
        WatchUi.requestUpdate();
    }

    function onStatus(ok as Boolean, result as Dictionary or String, code as Number) as Void {
        setBusy(false);
        if (ok) {
            status = result as Dictionary;
            receivedAt = System.getTimer();
            if (!_keep) {
                message = "";
            }
        } else if (!_keep) {
            message = result as String;
        }
        _keep = false;
        WatchUi.requestUpdate();
    }

    //! Start, pause or stop. `body` overrides the default one (Pause sends the picked break type).
    //! The request carries the state shown, so the server refuses it if another client changed it.
    function act(action as Symbol, body as Dictionary or Null) as Void {
        if (busy) {
            return;
        }
        setBusy(true);
        _acting = true;
        message = "…";
        var base = body != null ? body : (action == :start ? Logic.startBody(status) : {});
        _client.call(action, Logic.withExpect(base, state()), method(:onAction));
        WatchUi.requestUpdate();
    }

    function onAction(ok as Boolean, result as Dictionary or String, code as Number) as Void {
        setBusy(false);
        _acting = false;
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
            // The action may have been applied anyway (a timeout after the server acted), or
            // the state changed elsewhere (409): fetch the truth, keep the message, never retry.
            _keep = true;
            refresh(true);
        }
        WatchUi.requestUpdate();
    }

    //! busy with a 30 s watchdog, so a lost callback cannot leave the widget stuck on "…".
    private function setBusy(b as Boolean) as Void {
        busy = b;
        if (_watchdog != null) {
            _watchdog.stop();
            _watchdog = null;
        }
        if (b) {
            _watchdog = new Timer.Timer();
            _watchdog.start(method(:onWatchdog), 30000, false);
        }
    }

    function onWatchdog() as Void {
        _watchdog = null;
        if (busy) {
            busy = false;
            message = "Timed out";
            if (_acting) {
                // The action may have been applied anyway: fetch the truth, keep the message.
                _acting = false;
                _keep = true;
                refresh(true);
            } else {
                _keep = false;
            }
            WatchUi.requestUpdate();
        }
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
                _drawnMin = shownMinutes();
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
