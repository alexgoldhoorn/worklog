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
            return "Break";
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
        if (code == -104 || code == -2) {
            return "Phone not connected";
        }
        if (code == -300) {
            return "Timed out";
        }
        if (code == 401) {
            return "Login failed";
        }
        if (code >= 400 && code < 500 && body instanceof Dictionary) {
            var e = body["error"];
            if (e instanceof String) {
                return e.length() > 40 ? e.substring(0, 40) as String : e;
            }
        }
        return "Server error";
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

    function actionLabel(action as Symbol) as String {
        if (action == :start) {
            return "Start";
        }
        if (action == :pause) {
            return "Pause";
        }
        return "Stop";
    }
}
