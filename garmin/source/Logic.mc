import Toybox.Lang;
import Toybox.StringUtil;

//! Pure helpers: formatting, error text, auth and request bodies. No I/O, so it is unit-tested.
(:glance)
module Logic {

    //! Seconds as h:mm. null (stopped) gives "".
    (:glance)
    function formatElapsed(s as Number or Null) as String {
        if (s == null) {
            return "";
        }
        var m = s.toNumber() / 60;
        if (m < 0) {
            m = 0;
        }
        return (m / 60).format("%d") + ":" + (m % 60).format("%02d");
    }

    (:glance)
    function stateLabel(state as String or Null) as String {
        if ("working".equals(state)) {
            return "Working";
        }
        if ("break".equals(state)) {
            return "On break";
        }
        return "Stopped";
    }

    //! One line for the glance: "Working 2:14 · acme", "Break 0:12", "Stopped · 6.5 h".
    (:glance)
    function glanceLine(st as Dictionary) as String {
        var state = st["state"] as String or Null;
        var label = stateLabel(state);
        if ("working".equals(state) || "break".equals(state)) {
            var line = label + " " + formatElapsed(st["elapsed_s"] as Number or Null);
            var project = st["project"];
            if ("working".equals(state) && project instanceof String && project.length() > 0) {
                line += " · " + project;
            }
            return line;
        }
        return label + " · " + hours(st["today_work_h"]) + " h";
    }

    //! Hours with one decimal; anything that is not a number counts as 0.
    (:glance)
    function hours(h) as String {
        if (h instanceof Number || h instanceof Float || h instanceof Long || h instanceof Double) {
            return h.toFloat().format("%.1f");
        }
        return "0.0";
    }

    //! Text for a failed request. code is the HTTP status or a Communications error (negative).
    (:glance)
    function errorText(code as Number, body) as String {
        if (code == -1001) {
            return "Needs https://";
        }
        if (code == -104 || code == -2) {
            return "No phone link";
        }
        if (code == -300) {
            return "Timed out";
        }
        if (code == 401) {
            return "Login required";
        }
        if (isConflict(code, body)) {
            return "Changed elsewhere";
        }
        if (code >= 400 && code < 500 && body instanceof Dictionary) {
            var e = body["error"];
            if (e instanceof String) {
                return e.length() > 40 ? e.substring(0, 40) as String : e;
            }
        }
        if (code >= 500) {
            return "Server error";
        }
        return "Error " + code;
    }

    //! The server refused because the state is no longer the one the watch showed (expect_state).
    (:glance)
    function isConflict(code as Number, body) as Boolean {
        return code == 409 && body instanceof Dictionary && "state changed".equals(body["error"]);
    }

    //! Why there is no usable login: "No login" (something missing) or "Needs https://".
    //! null when hasLogin() is true.
    (:glance)
    function loginProblem(url as String or Null, user as String or Null, password as String or Null) as String or Null {
        if (hasLogin(url, user, password)) {
            return null;
        }
        if (user != null && password != null && user.length() > 0 && password.length() > 0
            && baseUrl(url).length() > 0) {
            return "Needs https://";
        }
        return "No login";
    }

    //! A copy of body that tells the server which state the watch is showing; the server answers
    //! 409 if it differs. Unknown state (null) sends no expectation.
    (:glance)
    function withExpect(body as Dictionary or Null, state as String or Null) as Dictionary {
        var out = {} as Dictionary;
        if (body != null) {
            var keys = body.keys();
            for (var i = 0; i < keys.size(); i++) {
                out[keys[i]] = body[keys[i]];
            }
        }
        if (state != null) {
            out["expect_state"] = state;
        }
        return out;
    }

    //! The few fields the glance shows, for Application.Storage. t = receive time (epoch s).
    (:glance)
    function cacheOf(st as Dictionary, nowSec as Number) as Dictionary {
        var out = {"s" => st["state"], "t" => nowSec} as Dictionary;
        var e = st["elapsed_s"];
        if (e instanceof Number) {
            out["e"] = e;
        }
        var p = st["project"];
        if (p instanceof String && p.length() > 0) {
            out["p"] = p.length() > 30 ? p.substring(0, 30) : p;
        }
        var h = st["today_work_h"];
        if (h != null && !(h instanceof String)) {
            out["h"] = h;
        }
        return out;
    }

    //! Glance line from a cache entry: elapsed advanced by the time since it was stored; a
    //! trailing " ?" when older than 10 minutes or when `old` (the refresh failed). The glance
    //! is narrow (about 16 characters), so a marked line drops the project to keep the "?" visible.
    (:glance)
    function cachedLine(c as Dictionary, nowSec as Number, old as Boolean) as String {
        var t = c["t"];
        var age = t instanceof Number ? nowSec - t : 0;
        if (age < 0) {
            age = 0;
        }
        var stale = old || age > 600;
        var e = c["e"];
        var st = {"state" => c["s"], "project" => stale ? null : c["p"], "today_work_h" => c["h"],
            "elapsed_s" => e instanceof Number ? e + age : null} as Dictionary;
        var line = glanceLine(st);
        return stale ? line + " ?" : line;
    }

    (:glance)
    function isSpace(c as Char) as Boolean {
        return c == ' ' || c == '\t' || c == '\n' || c == '\r';
    }

    //! Trims whitespace and trailing slashes.
    (:glance)
    function baseUrl(url as String or Null) as String {
        if (url == null) {
            return "";
        }
        var chars = url.toCharArray();
        var a = 0;
        var b = chars.size();
        while (a < b && isSpace(chars[a])) {
            a++;
        }
        while (b > a && (isSpace(chars[b - 1]) || chars[b - 1] == '/')) {
            b--;
        }
        return url.substring(a, b) as String;
    }

    //! All three set and the URL is https://. Plain http is accepted only for the loopback
    //! mock (garmin/tools/mock_server.py), which the simulator reaches with its HTTPS check off.
    (:glance)
    function hasLogin(url as String or Null, user as String or Null, password as String or Null) as Boolean {
        var u = baseUrl(url);
        if (user == null || password == null || user.length() == 0 || password.length() == 0) {
            return false;
        }
        return startsWith(u, "https://") && u.length() > 8
            || startsWith(u, "http://127.0.0.1:") || startsWith(u, "http://localhost:");
    }

    (:glance)
    function startsWith(s as String, prefix as String) as Boolean {
        return s.length() >= prefix.length() && s.substring(0, prefix.length()).equals(prefix);
    }

    (:glance)
    function basicAuth(user as String, password as String) as String {
        var enc = StringUtil.convertEncodedString(user + ":" + password, {
            :fromRepresentation => StringUtil.REPRESENTATION_STRING_PLAIN_TEXT,
            :toRepresentation => StringUtil.REPRESENTATION_STRING_BASE64
        });
        return "Basic " + enc;
    }

    //! Body for /api/start: resume the last work block's type and project, so a start after a
    //! break does not open a block without a project.
    (:glance)
    function startBody(st as Dictionary or Null) as Dictionary {
        if (st == null) {
            return {};
        }
        var r = st["resume"];
        if (!(r instanceof Dictionary)) {
            return {};
        }
        var out = {} as Dictionary<String, String>;
        var t = r["type"];
        if (t instanceof String) {
            out["type"] = t;
        }
        var p = r["project"];
        if (p instanceof String) {
            out["project"] = p;
        }
        return out;
    }

    //! Break types offered by Pause: the server's `breaks` (eat first), at most 6; ["eat"] if absent.
    (:glance)
    function breakChoices(st as Dictionary or Null) as Array<String> {
        var out = [] as Array<String>;
        if (st != null) {
            var b = st["breaks"];
            if (b instanceof Array) {
                for (var i = 0; i < b.size() && out.size() < 6; i++) {
                    if (b[i] instanceof String && b[i].length() > 0) {
                        out.add(b[i] as String);
                    }
                }
            }
        }
        if (out.size() == 0) {
            out.add("eat");
        }
        return out;
    }

    (:glance)
    function pauseBody(breakType as String) as Dictionary {
        return {"type" => breakType};
    }

    (:glance)
    function actionsFor(state as String or Null) as Array<Symbol> {
        if ("working".equals(state)) {
            return [:pause, :stop];
        }
        if ("break".equals(state)) {
            return [:start, :stop];
        }
        return [:start];
    }

    //! "Resume" from a break, else "Start".
    function actionLabel(action as Symbol, state as String or Null) as String {
        if (action == :start) {
            return "break".equals(state) ? "Resume" : "Start";
        }
        if (action == :pause) {
            return "Pause";
        }
        return "Stop";
    }
}
