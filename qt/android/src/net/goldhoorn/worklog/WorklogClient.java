package net.goldhoorn.worklog;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.TimeZone;

// The timer part of the server's JSON API for the home-screen widget, the Quick Settings tile and the
// ongoing notification, which run without the Qt app. The server URL and user are mirrored here by the
// app (TimerWidget, C++) whenever they change; the password is read from SecretStore, as the app does.
// Every call uses ?brief=1 (worklog/status.py brief()): state, now, since, elapsed_s, type, project,
// today_work_h, resume, breaks.
//
// Offline queue (the same idea as Api.timerAction/flushQueue in Api.qml): an action tapped while the
// server cannot be reached is kept in order with `at`, the server's wall clock when it was tapped, and
// replayed before the next call. All of this runs on TimerWidget's single worker thread.
public class WorklogClient {
    static final String PREFS = "worklog_widget";

    // The server could not be reached (no answer, a 5xx, or the time budget ran out): try again later
    static class Unreachable extends Exception {
        Unreachable(String m) {
            super(m);
        }
    }

    // The server answered with an error (4xx); `code` 401 means the login is missing or wrong
    static class Refused extends Exception {
        final int code;

        Refused(int code, String m) {
            super(m);
            this.code = code;
        }
    }

    // The point in time by which the current call chain must be done (goAsync() gives a receiver about
    // 10 s); every request shrinks its timeouts to what is left of it
    private static final ThreadLocal<Long> DEADLINE = new ThreadLocal<>();

    static void setDeadline(long uptimeMs) {
        DEADLINE.set(uptimeMs);
    }

    private static long remaining() {
        Long d = DEADLINE.get();
        return d == null ? 8000 : d - System.currentTimeMillis();
    }

    static SharedPreferences prefs(Context ctx) {
        return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    // called from the app (TimerWidget, C++) at start and after Api.setServer
    public static void configure(Context ctx, String url, String user) {
        String newUrl = url == null ? "" : url.trim().replaceAll("/+$", "");
        SharedPreferences p = prefs(ctx);
        SharedPreferences.Editor e = p.edit()
                .putString("url", newUrl)
                .putString("user", user == null ? "" : user);
        if (!newUrl.equals(p.getString("url", newUrl)))   // another server: its status and queue do not apply
            e.remove("status").remove("queue").remove("error").remove("notice").remove("clockOffset");
        e.apply();
    }

    static boolean hasServer(Context ctx) {
        return !prefs(ctx).getString("url", "").isEmpty();
    }

    // ---- the server's clock --------------------------------------------------

    private static SimpleDateFormat utc(String pattern) {
        SimpleDateFormat f = new SimpleDateFormat(pattern, Locale.ROOT);
        f.setTimeZone(TimeZone.getTimeZone("UTC"));
        return f;
    }

    // The server's local wall-clock time is carried as a "fake UTC" instant: clockOffset is
    // (server wall clock read as UTC) - (device time). Before the first answer the device's own zone is assumed.
    private static void syncClock(Context ctx, JSONObject data) {
        String now = data.optString("now", "");
        if (now.length() < 19)
            return;
        try {
            long wall = utc("yyyy-MM-dd'T'HH:mm:ss").parse(now.substring(0, 19)).getTime();
            prefs(ctx).edit().putLong("clockOffset", wall - System.currentTimeMillis()).apply();
        } catch (Exception ignored) {
            // an unexpected format: keep the old offset
        }
    }

    // "2026-10-20T09:30": the server's wall clock now, as the `at` of a queued action
    static String wallNow(Context ctx) {
        long t = System.currentTimeMillis();
        SharedPreferences p = prefs(ctx);
        long offset = p.contains("clockOffset") ? p.getLong("clockOffset", 0) : TimeZone.getDefault().getOffset(t);
        return utc("yyyy-MM-dd'T'HH:mm").format(new Date(t + offset));
    }

    // ---- requests ------------------------------------------------------------

    // the brief status after GET /api/status, or after a POST to /api/start|pause|stop
    static JSONObject call(Context ctx, String method, String path, JSONObject body) throws Unreachable, Refused {
        SharedPreferences p = prefs(ctx);
        String base = p.getString("url", "");
        if (base.isEmpty())
            throw new Refused(0, "Open Worklog and set the server");
        long left = remaining();
        if (left < 1000)
            throw new Unreachable("Timed out");
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) new URL(base + path + "?brief=1").openConnection();
            // connect + read together stay within what is left of the receiver's budget
            int connect = (int) Math.min(3000, left / 2);
            c.setConnectTimeout(connect);
            c.setReadTimeout((int) Math.min(5000, left - connect));
            c.setRequestMethod(method);
            c.setRequestProperty("Accept", "application/json");
            String user = p.getString("user", "");
            if (!user.isEmpty()) {
                String login = user + ":" + SecretStore.get(ctx, "password");
                c.setRequestProperty("Authorization", "Basic "
                        + Base64.encodeToString(login.getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP));
            }
            if (body != null) {
                byte[] out = body.toString().getBytes(StandardCharsets.UTF_8);
                c.setDoOutput(true);
                c.setRequestProperty("Content-Type", "application/json");
                c.setFixedLengthStreamingMode(out.length);
                try (OutputStream os = c.getOutputStream()) {
                    os.write(out);
                }
            }
            int code = c.getResponseCode();
            String text = read(code < 400 ? c.getInputStream() : c.getErrorStream());
            JSONObject data = null;
            try {
                data = new JSONObject(text);
            } catch (Exception ignored) {
                // a body that is not JSON (a proxy's error page)
            }
            if (code == 401)
                throw new Refused(401, "Login required: open Worklog");
            if (code >= 500)
                throw new Unreachable(data != null && data.has("error") ? data.optString("error") : "Server error " + code);
            if (code < 200 || code >= 300)
                throw new Refused(code, data != null && data.has("error") ? data.optString("error") : "HTTP " + code);
            if (data == null)
                throw new Refused(code, "Not a worklog server");
            syncClock(ctx, data);
            return data;
        } catch (java.io.IOException e) {
            android.util.Log.w("WorklogClient", method + " " + path + ": " + e);   // for `adb logcat`
            throw new Unreachable("Cannot reach " + base);
        } finally {
            if (c != null)
                c.disconnect();
        }
    }

    private static String read(InputStream in) throws java.io.IOException {
        if (in == null)
            return "";
        try (InputStream s = in) {
            ByteArrayOutputStream buf = new ByteArrayOutputStream();
            byte[] chunk = new byte[4096];
            for (int n; (n = s.read(chunk)) > 0; )
                buf.write(chunk, 0, n);
            return buf.toString("UTF-8");
        }
    }

    static JSONObject status(Context ctx) throws Unreachable, Refused {
        return call(ctx, "GET", "/api/status", null);
    }

    // ---- actions -------------------------------------------------------------

    // continues the last work block's type and project, as the watch does (brief "resume")
    static JSONObject startBody(JSONObject last) throws Exception {
        JSONObject body = new JSONObject();
        JSONObject resume = last == null ? null : last.optJSONObject("resume");
        if (resume != null) {
            if (!resume.isNull("type"))
                body.put("type", resume.optString("type"));
            if (!resume.isNull("project"))
                body.put("project", resume.optString("project"));
        }
        return body;
    }

    // the most used break type ("eat" first, like the app's default)
    static String breakType(JSONObject last) {
        JSONArray b = last == null ? null : last.optJSONArray("breaks");
        return b != null && b.length() > 0 ? b.optString(0, "eat") : "eat";
    }

    static JSONObject pauseBody(JSONObject last) throws Exception {
        return new JSONObject().put("type", breakType(last));
    }

    // ---- the offline queue ---------------------------------------------------

    private static JSONArray queue(Context ctx) {
        try {
            return new JSONArray(prefs(ctx).getString("queue", "[]"));
        } catch (Exception e) {
            return new JSONArray();
        }
    }

    static int queued(Context ctx) {
        return queue(ctx).length();
    }

    // keeps an action for later with the server's wall clock of now as its `at`
    static void enqueue(Context ctx, String path, JSONObject body) throws Exception {
        JSONObject b = new JSONObject(body.toString());
        b.put("at", wallNow(ctx));
        JSONArray q = queue(ctx);
        q.put(new JSONObject().put("path", path).put("body", b));
        prefs(ctx).edit().putString("queue", q.toString()).commit();
    }

    private static void dropFirst(Context ctx) {
        JSONArray q = queue(ctx);
        JSONArray rest = new JSONArray();
        for (int i = 1; i < q.length(); i++)
            rest.put(q.opt(i));
        prefs(ctx).edit().putString("queue", rest.toString()).commit();
    }

    // What flush() found out
    static class Flush {
        String notice = "";        // what the server refused (the action was dropped), "" if nothing
        JSONObject last;           // the answer of the last action that went through
        Exception stopped;         // why the rest stays queued (Unreachable, or Refused 401), or null
    }

    // Sends the queue front to back. Stops at the first unreachable answer (or a missing login) and keeps
    // the rest; an action the server refuses is dropped and its message returned.
    static Flush flush(Context ctx) {
        Flush f = new Flush();
        while (true) {
            JSONArray q = queue(ctx);
            if (q.length() == 0)
                return f;
            JSONObject item = q.optJSONObject(0);
            try {
                if (item == null)
                    throw new Refused(400, "Bad queued action");
                f.last = call(ctx, "POST", item.optString("path"), item.optJSONObject("body"));
                dropFirst(ctx);
            } catch (Unreachable e) {
                f.stopped = e;
                return f;
            } catch (Refused e) {
                if (e.code == 401 || e.code == 0) {
                    f.stopped = e;
                    return f;
                }
                dropFirst(ctx);
                f.notice = f.notice.isEmpty() ? e.getMessage() : f.notice + "; " + e.getMessage();
            }
        }
    }

    // ---- the cache -----------------------------------------------------------

    // the last status seen (for the tile and for start's resume), or null; "_at" is when it was fetched
    // (device clock), kept inside the same JSON so a reader never sees a status with another one's time
    static JSONObject cached(Context ctx) {
        try {
            String s = prefs(ctx).getString("status", null);
            return s == null ? null : new JSONObject(s);
        } catch (Exception e) {
            return null;
        }
    }

    static void cache(Context ctx, JSONObject st, String error, String notice) {
        SharedPreferences.Editor e = prefs(ctx).edit()
                .putString("error", error == null ? "" : error)
                .putString("notice", notice == null ? "" : notice)
                .putLong("triedAt", System.currentTimeMillis());
        if (st != null) {
            try {
                st.put("_at", System.currentTimeMillis());
            } catch (Exception ignored) {
                // a plain key on a JSONObject cannot fail
            }
            e.putString("status", st.toString());
        }
        e.apply();
    }
}
