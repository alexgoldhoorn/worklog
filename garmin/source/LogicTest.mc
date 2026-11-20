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
        & check(logger, Logic.stateLabel("break"), "On break")
        & check(logger, Logic.stateLabel("stopped"), "Stopped")
        & check(logger, Logic.stateLabel("odd"), "Stopped");
}

(:test)
function testGlanceLine(logger as Logger) as Boolean {
    return check(logger, Logic.glanceLine({"state" => "working", "elapsed_s" => 8040, "project" => "acme"}), "Working 2:14 · acme")
        & check(logger, Logic.glanceLine({"state" => "working", "elapsed_s" => 8040, "project" => null}), "Working 2:14")
        & check(logger, Logic.glanceLine({"state" => "break", "elapsed_s" => 720, "project" => null}), "On break 0:12")
        & check(logger, Logic.glanceLine({"state" => "stopped", "elapsed_s" => null, "today_work_h" => 6.5}), "Stopped · 6.5 h")
        & check(logger, Logic.glanceLine({"state" => "stopped", "elapsed_s" => null, "today_work_h" => 0}), "Stopped · 0.0 h");
}

(:test)
function testErrorText(logger as Logger) as Boolean {
    return check(logger, Logic.errorText(-1001, null), "Needs https://")
        & check(logger, Logic.errorText(-104, null), "No phone link")
        & check(logger, Logic.errorText(-2, null), "No phone link")
        & check(logger, Logic.errorText(-300, null), "Timed out")
        & check(logger, Logic.errorText(401, {"error" => "login required"}), "Login required")
        & check(logger, Logic.errorText(409, {"error" => "state changed", "state" => "break"}), "Changed elsewhere")
        & check(logger, Logic.errorText(409, {"error" => "nope"}), "nope")
        & check(logger, Logic.errorText(400, {"error" => "0123456789012345678901234567890123456789XYZ"}),
            "0123456789012345678901234567890123456789")
        & check(logger, Logic.errorText(404, "not json"), "Error 404")
        & check(logger, Logic.errorText(500, {"error" => "boom"}), "Server error")
        & check(logger, Logic.errorText(503, null), "Server error")
        & check(logger, Logic.errorText(-400, null), "Error -400");
}

(:test)
function testConflictAndLoginProblem(logger as Logger) as Boolean {
    return check(logger, Logic.isConflict(409, {"error" => "state changed"}), true)
        & check(logger, Logic.isConflict(409, {"error" => "x"}), false)
        & check(logger, Logic.isConflict(500, {"error" => "state changed"}), false)
        & check(logger, Logic.loginProblem("https://x", "a", "b"), null)
        & check(logger, Logic.loginProblem("http://127.0.0.1:8503", "a", "b"), null)
        & check(logger, Logic.loginProblem("http://x", "a", "b"), "Needs https://")
        & check(logger, Logic.loginProblem("x.example", "a", "b"), "Needs https://")
        & check(logger, Logic.loginProblem("", "a", "b"), "No login")
        & check(logger, Logic.loginProblem("https://x", "", "b"), "No login")
        & check(logger, Logic.loginProblem("https://x", "a", null), "No login");
}

(:test)
function testWithExpect(logger as Logger) as Boolean {
    var base = {"type" => "dev"};
    var a = Logic.withExpect(base, "break");
    var b = Logic.withExpect(null, "working");
    return check(logger, a["expect_state"], "break") & check(logger, a["type"], "dev")
        & check(logger, base.hasKey("expect_state"), false)
        & check(logger, b.size(), 1) & check(logger, b["expect_state"], "working")
        & check(logger, Logic.withExpect({}, null).size(), 0);
}

(:test)
function testGlanceCache(logger as Logger) as Boolean {
    var c = Logic.cacheOf({"state" => "working", "elapsed_s" => 8040, "project" => "acme",
        "today_work_h" => 3.5, "resume" => {"type" => "dev"}, "breaks" => ["eat"]}, 1000);
    var stopped = Logic.cacheOf({"state" => "stopped", "elapsed_s" => null, "project" => null, "today_work_h" => 6.5}, 1000);
    return check(logger, c.size(), 5)
        & check(logger, Logic.cachedLine(c, 1000, false), "Working 2:14 · acme")
        & check(logger, Logic.cachedLine(c, 1120, false), "Working 2:16 · acme")
        & check(logger, Logic.cachedLine(c, 1120, true), "Working 2:16 ?")
        & check(logger, Logic.cachedLine(c, 1601, false), "Working 2:24 ?")
        & check(logger, Logic.cachedLine(c, 900, false), "Working 2:14 · acme")
        & check(logger, Logic.cachedLine(stopped, 1050, false), "Stopped · 6.5 h")
        & check(logger, Logic.cachedLine(stopped, 9000, false), "Stopped · 6.5 h ?");
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

(:test)
function testActionLabel(logger as Logger) as Boolean {
    return check(logger, Logic.actionLabel(:start, "break"), "Resume")
        & check(logger, Logic.actionLabel(:start, "stopped"), "Start")
        & check(logger, Logic.actionLabel(:start, null), "Start")
        & check(logger, Logic.actionLabel(:pause, "working"), "Pause")
        & check(logger, Logic.actionLabel(:stop, "break"), "Stop");
}
