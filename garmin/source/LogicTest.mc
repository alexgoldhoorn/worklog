import Toybox.Lang;
import Toybox.Test;

// Unit tests for Logic. Compiled only with --unit-test; run with `monkeydo <prg> <device> -t`.

(:debug)
function check(logger as Logger, got, want) as Boolean {
    var ok = (got == null && want == null) || (got != null && got.equals(want));
    if (!ok) {
        logger.error("got '" + got + "', want '" + want + "'");
    }
    return ok;
}

(:test)
function testFormatElapsed(logger as Logger) as Boolean {
    return check(logger, Logic.formatElapsed(null), "")
        & check(logger, Logic.formatElapsed(5), "0:00")
        & check(logger, Logic.formatElapsed(8040), "2:14")
        & check(logger, Logic.formatElapsed(108000), "30:00");
}

(:test)
function testStateLabel(logger as Logger) as Boolean {
    return check(logger, Logic.stateLabel("working"), "Working")
        & check(logger, Logic.stateLabel("break"), "Break")
        & check(logger, Logic.stateLabel("stopped"), "Stopped")
        & check(logger, Logic.stateLabel("odd"), "Stopped");
}

(:test)
function testGlanceLine(logger as Logger) as Boolean {
    return check(logger, Logic.glanceLine({"state" => "working", "elapsed_s" => 8040, "project" => "acme"}), "Working 2:14 · acme")
        & check(logger, Logic.glanceLine({"state" => "working", "elapsed_s" => 8040, "project" => null}), "Working 2:14")
        & check(logger, Logic.glanceLine({"state" => "break", "elapsed_s" => 720, "project" => null}), "Break 0:12")
        & check(logger, Logic.glanceLine({"state" => "stopped", "elapsed_s" => null, "today_work_h" => 6.5}), "Stopped · 6.5 h")
        & check(logger, Logic.glanceLine({"state" => "stopped", "elapsed_s" => null, "today_work_h" => 0}), "Stopped · 0.0 h");
}

(:test)
function testErrorText(logger as Logger) as Boolean {
    return check(logger, Logic.errorText(-104, null), "Phone not connected")
        & check(logger, Logic.errorText(-2, null), "Phone not connected")
        & check(logger, Logic.errorText(-300, null), "Timed out")
        & check(logger, Logic.errorText(401, {"error" => "login required"}), "Login failed")
        & check(logger, Logic.errorText(409, {"error" => "nope"}), "nope")
        & check(logger, Logic.errorText(400, {"error" => "0123456789012345678901234567890123456789XYZ"}),
            "0123456789012345678901234567890123456789")
        & check(logger, Logic.errorText(404, "not json"), "Server error")
        & check(logger, Logic.errorText(500, {"error" => "boom"}), "Server error")
        & check(logger, Logic.errorText(-400, null), "Server error");
}

(:test)
function testBaseUrl(logger as Logger) as Boolean {
    return check(logger, Logic.baseUrl(" https://x/ "), "https://x")
        & check(logger, Logic.baseUrl("https://x//"), "https://x")
        & check(logger, Logic.baseUrl("https://x"), "https://x")
        & check(logger, Logic.baseUrl(null), "");
}

(:test)
function testHasLogin(logger as Logger) as Boolean {
    return check(logger, Logic.hasLogin("https://x", "a", "b"), true)
        & check(logger, Logic.hasLogin("https://x/ ", "a", "b"), true)
        & check(logger, Logic.hasLogin("http://x", "a", "b"), false)
        & check(logger, Logic.hasLogin("x", "a", "b"), false)
        & check(logger, Logic.hasLogin("https://x", "", "b"), false)
        & check(logger, Logic.hasLogin("https://x", "a", ""), false)
        & check(logger, Logic.hasLogin("https://x", null, "b"), false)
        & check(logger, Logic.hasLogin("", "a", "b"), false)
        & check(logger, Logic.hasLogin("http://127.0.0.1:8503", "a", "b"), true);
}

(:test)
function testBasicAuth(logger as Logger) as Boolean {
    return check(logger, Logic.basicAuth("sam", "s3cret:x"), "Basic c2FtOnMzY3JldDp4");
}

(:test)
function testStartBody(logger as Logger) as Boolean {
    var empty = Logic.startBody({"resume" => null});
    var full = Logic.startBody({"resume" => {"type" => "dev", "project" => "acme"}});
    var noProject = Logic.startBody({"resume" => {"type" => "dev", "project" => null}});
    return check(logger, empty.size(), 0)
        & check(logger, Logic.startBody(null).size(), 0)
        & check(logger, full.size(), 2) & check(logger, full["type"], "dev") & check(logger, full["project"], "acme")
        & check(logger, noProject.size(), 1) & check(logger, noProject.hasKey("project"), false);
}

(:test)
function testActionsFor(logger as Logger) as Boolean {
    var w = Logic.actionsFor("working");
    var b = Logic.actionsFor("break");
    var s = Logic.actionsFor("stopped");
    return check(logger, w.size(), 2) & check(logger, w[0] == :pause && w[1] == :stop, true)
        & check(logger, b.size(), 2) & check(logger, b[0] == :start && b[1] == :stop, true)
        & check(logger, s.size(), 1) & check(logger, s[0] == :start, true);
}

(:test)
function testBreakChoices(logger as Logger) as Boolean {
    var none = Logic.breakChoices({"breaks" => null});
    var some = Logic.breakChoices({"breaks" => ["eat", "walk", 3, "", "run", "a", "b", "c", "d"]});
    return check(logger, Logic.breakChoices(null).size(), 1) & check(logger, none[0], "eat")
        & check(logger, some.size(), 6) & check(logger, some[1], "walk") & check(logger, some[2], "run")
        & check(logger, Logic.pauseBody("walk")["type"], "walk");
}
