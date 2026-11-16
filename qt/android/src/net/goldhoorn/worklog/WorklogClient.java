package net.goldhoorn.worklog;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Base64;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

// The timer part of the server's JSON API for the home-screen widget, the Quick Settings tile and the
// ongoing notification, which run without the Qt app. The server URL and user are mirrored here by the
// app (TimerWidget, C++) whenever they change; the password is read from SecretStore, as the app does.
// Every call uses ?brief=1 (worklog/status.py brief()): state, since, elapsed_s, type, project,
// today_work_h, resume, breaks.
public class WorklogClient {
    static final String PREFS = "worklog_widget";
    private static final int TIMEOUT_MS = 8000;

    static SharedPreferences prefs(Context ctx) {
        return ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    // called from the app (TimerWidget, C++) at start and after Api.setServer
    public static void configure(Context ctx, String url, String user) {
        prefs(ctx).edit()
                .putString("url", url == null ? "" : url.trim().replaceAll("/+$", ""))
                .putString("user", user == null ? "" : user)
                .apply();
    }

    static boolean hasServer(Context ctx) {
        return !prefs(ctx).getString("url", "").isEmpty();
    }

    // the brief status after GET /api/status, or after a POST to /api/start|pause|stop
    static JSONObject call(Context ctx, String method, String path, JSONObject body) throws Exception {
        SharedPreferences p = prefs(ctx);
        String base = p.getString("url", "");
        if (base.isEmpty())
            throw new Exception("Open Worklog and set the server");
        HttpURLConnection c = (HttpURLConnection) new URL(base + path + "?brief=1").openConnection();
        try {
            c.setConnectTimeout(TIMEOUT_MS);
            c.setReadTimeout(TIMEOUT_MS);
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
                throw new Exception("Login required: open Worklog");
            if (code < 200 || code >= 300)
                throw new Exception(data != null && data.has("error") ? data.optString("error") : "HTTP " + code);
            if (data == null)
                throw new Exception("Not a worklog server");
            return data;
        } catch (java.io.IOException e) {
            throw new Exception("Cannot reach " + base);
        } finally {
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

    static JSONObject status(Context ctx) throws Exception {
        return call(ctx, "GET", "/api/status", null);
    }

    // continues the last work block's type and project, as the watch does (brief "resume")
    static JSONObject start(Context ctx, JSONObject last) throws Exception {
        JSONObject body = new JSONObject();
        JSONObject resume = last == null ? null : last.optJSONObject("resume");
        if (resume != null) {
            if (!resume.isNull("type"))
                body.put("type", resume.optString("type"));
            if (!resume.isNull("project"))
                body.put("project", resume.optString("project"));
        }
        return call(ctx, "POST", "/api/start", body);
    }

    // the most used break type ("eat" first, like the app's default)
    static JSONObject pause(Context ctx, JSONObject last) throws Exception {
        JSONObject body = new JSONObject();
        String type = "eat";
        if (last != null && last.optJSONArray("breaks") != null && last.optJSONArray("breaks").length() > 0)
            type = last.optJSONArray("breaks").optString(0, "eat");
        body.put("type", type);
        return call(ctx, "POST", "/api/pause", body);
    }

    static JSONObject stop(Context ctx) throws Exception {
        return call(ctx, "POST", "/api/stop", new JSONObject());
    }

    // the last status seen (for the tile and for start's resume), or null
    static JSONObject cached(Context ctx) {
        try {
            String s = prefs(ctx).getString("status", null);
            return s == null ? null : new JSONObject(s);
        } catch (Exception e) {
            return null;
        }
    }

    static void cache(Context ctx, JSONObject st, String error) {
        SharedPreferences.Editor e = prefs(ctx).edit()
                .putString("error", error == null ? "" : error)
                .putLong("triedAt", System.currentTimeMillis());
        if (st != null)
            e.putString("status", st.toString()).putLong("statusAt", System.currentTimeMillis());
        e.apply();
    }
}
