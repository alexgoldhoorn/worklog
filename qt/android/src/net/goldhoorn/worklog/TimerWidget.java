package net.goldhoorn.worklog;

import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.drawable.Icon;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.service.quicksettings.TileService;
import android.view.View;
import android.widget.RemoteViews;

import org.json.JSONObject;

import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicBoolean;

// The home-screen widget, and the receiver for every timer action outside the app: the widget's and the
// ongoing notification's Start/Pause/Stop buttons, the periodic refresh alarm and the app's refresh
// requests. The network call runs on a worker thread while goAsync() keeps the receiver alive; the result
// redraws the widgets, the ongoing notification and the Quick Settings tile (TimerTile).
// There is no polling service: the elapsed time counts on the device (Chronometer), and the status is
// fetched again on an inexact alarm while a block runs, on the widget's update period and after actions.
// An action tapped while the server cannot be reached is queued with its time (WorklogClient) and replayed
// before the next call; the widget, tile and notification then say how many actions are waiting.
public class TimerWidget extends AppWidgetProvider {
    static final String ACTION_REFRESH = "net.goldhoorn.worklog.REFRESH";
    static final String ACTION_START = "net.goldhoorn.worklog.START";
    static final String ACTION_PAUSE = "net.goldhoorn.worklog.PAUSE";
    static final String ACTION_STOP = "net.goldhoorn.worklog.STOP";
    // the tile's tap: stop if the server says a work block runs now, else start (decided from a fresh status)
    static final String ACTION_TOGGLE = "net.goldhoorn.worklog.TOGGLE";

    private static final String CHANNEL = "timer";
    private static final int NOTIFICATION_ID = 2;   // 1 is the Pomodoro's
    private static final long REFRESH_MS = 10 * 60 * 1000;   // while a block runs, to catch changes made elsewhere
    private static final long RETRY_MS = 2 * 60 * 1000;      // while actions wait in the queue
    // goAsync() keeps a receiver alive for about 10 s: all network calls of one run share this budget
    // (WorklogClient shrinks its timeouts to it), leaving time to draw; finish() is forced just before the limit
    private static final long BUDGET_MS = 8000;
    private static final long FINISH_MS = 9000;
    // one run at a time, in the order the taps came, so queued actions keep their order
    private static final ExecutorService WORKER = Executors.newSingleThreadExecutor();

    // called from the app (TimerWidget, C++) after its own timer actions
    public static void refresh(Context ctx) {
        ctx.sendBroadcast(new Intent(ACTION_REFRESH).setClass(ctx, TimerWidget.class));
    }

    // The least time a run needs to be worth starting (a status fetch plus an action)
    private static final long MIN_START_MS = 2000;

    // runs an action (or only a refresh) off the main thread and redraws everything; used by the tile too
    // (which has no system limit to keep to)
    static void run(Context ctx, String action, Runnable done) {
        run(ctx, action, done, Long.MAX_VALUE);
    }

    // `limit` is the point in time by which this run must be done (a receiver's goAsync() allows about
    // 10 s from its start). The budget starts when the worker picks the run up, not when it was queued
    // behind a slow one; a run that can no longer start in time is dropped (not queued as an offline
    // action: the server was never tried) with a notice, and finishes cleanly.
    static void run(Context ctx, String action, Runnable done, long limit) {
        Context app = ctx.getApplicationContext();
        WORKER.execute(() -> {
            try {
                long start = System.currentTimeMillis();
                long deadline = limit == Long.MAX_VALUE ? start + BUDGET_MS : Math.min(start + BUDGET_MS, limit);
                if (deadline - start < MIN_START_MS) {
                    if (!ACTION_REFRESH.equals(action))
                        WorklogClient.setNotice(app, "Busy: tap again");
                } else {
                    WorklogClient.setDeadline(deadline);
                    try {
                        work(app, action);
                    } catch (Exception e) {
                        WorklogClient.cache(app, null, String.valueOf(e.getMessage()), null);
                    }
                }
                render(app);
            } catch (Throwable t) {
                android.util.Log.w("TimerWidget", "run failed: " + t);
            } finally {
                if (done != null) {
                    try {
                        done.run();
                    } catch (Throwable t) {
                        android.util.Log.w("TimerWidget", "done failed: " + t);
                    }
                }
            }
        });
    }

    // finish() exactly once: when the run is done or, at the latest, just before the system's limit
    private static Runnable finisher(PendingResult pending) {
        AtomicBoolean finished = new AtomicBoolean();
        Runnable finish = () -> {
            if (finished.compareAndSet(false, true))
                pending.finish();
        };
        new Handler(Looper.getMainLooper()).postDelayed(finish, FINISH_MS);
        return finish;
    }

    private static String pathOf(String action) {
        return ACTION_START.equals(action) ? "/api/start" : ACTION_PAUSE.equals(action) ? "/api/pause" : "/api/stop";
    }

    // what the widget shows at once after an action that is only queued (the answer will correct it)
    private static JSONObject optimistic(JSONObject last, String action) throws Exception {
        JSONObject st = last == null ? new JSONObject() : new JSONObject(last.toString());
        JSONObject resume = st.optJSONObject("resume");
        if (ACTION_START.equals(action)) {
            st.put("state", "working");
            st.put("type", resume == null || resume.isNull("type") ? JSONObject.NULL : resume.optString("type"));
            st.put("project", resume == null || resume.isNull("project") ? JSONObject.NULL : resume.optString("project"));
        } else if (ACTION_PAUSE.equals(action)) {
            st.put("state", "break");
            String bt = WorklogClient.breakType(last);
            st.put("type", bt == null ? JSONObject.NULL : bt);
            st.put("project", JSONObject.NULL);
        } else {
            st.put("state", "stopped");
            st.put("type", JSONObject.NULL);
            st.put("project", JSONObject.NULL);
        }
        st.put("elapsed_s", 0);
        return st;
    }

    // An action the fresh status says is already done or does not apply is skipped: Start on a running
    // timer would make the server switch (split the block).
    private static boolean pointless(String action, String state) {
        if (ACTION_START.equals(action))
            return "working".equals(state);
        if (ACTION_PAUSE.equals(action))
            return !"working".equals(state);
        return "stopped".equals(state);   // stop
    }

    private static JSONObject send(Context app, String action, JSONObject last) throws Exception {
        if (ACTION_START.equals(action))
            return WorklogClient.call(app, "POST", "/api/start", WorklogClient.startBody(last));
        if (ACTION_PAUSE.equals(action))
            return WorklogClient.call(app, "POST", "/api/pause", WorklogClient.pauseBody(last));
        return WorklogClient.call(app, "POST", "/api/stop", new JSONObject());
    }

    // the worker's job: replay the queue, fetch a fresh status, do the action, or queue it when the
    // server cannot be reached
    private static void work(Context app, String action) throws Exception {
        boolean isAction = !ACTION_REFRESH.equals(action);
        // 1. what was tapped offline goes first
        WorklogClient.Flush f = WorklogClient.flush(app);
        JSONObject st = f.last;
        String error = f.stopped == null ? null : f.stopped.getMessage();
        boolean reachable = f.stopped == null;
        boolean done = false;   // a user action went through (or was already in effect)
        // 2. a fresh status, so start/stop is decided on what the server has now, not on the cache
        if (reachable) {
            try {
                st = WorklogClient.status(app);
                if (ACTION_TOGGLE.equals(action))
                    action = "working".equals(st.optString("state")) ? ACTION_STOP : ACTION_START;
                if (isAction && !pointless(action, st.optString("state", "stopped")))
                    st = send(app, action, st);
                done = isAction;
            } catch (WorklogClient.Unreachable e) {
                reachable = false;
                error = e.getMessage();
            } catch (WorklogClient.Refused e) {
                error = e.getMessage();
                reachable = e.code != 401;   // a missing login keeps the action for when it is fixed
            }
        }
        // 3. no server: keep the action for later, decided from the cache
        if (!reachable && isAction) {
            JSONObject last = WorklogClient.cached(app);
            if (ACTION_TOGGLE.equals(action))
                action = last != null && "working".equals(last.optString("state")) ? ACTION_STOP : ACTION_START;
            JSONObject body = ACTION_START.equals(action) ? WorklogClient.startBody(last)
                    : ACTION_PAUSE.equals(action) ? WorklogClient.pauseBody(last) : new JSONObject();
            WorklogClient.enqueue(app, pathOf(action), body);
            st = optimistic(last, action);
        }
        // a refusal stays until the next successful user action or until the app is opened (configure())
        WorklogClient.cache(app, st, error, !f.notice.isEmpty() ? f.notice : done ? "" : null);
    }

    @Override
    public void onReceive(Context ctx, Intent intent) {
        String action = intent.getAction();
        if (ACTION_REFRESH.equals(action) || ACTION_START.equals(action) || ACTION_PAUSE.equals(action)
                || ACTION_STOP.equals(action) || ACTION_TOGGLE.equals(action)) {
            run(ctx, action, finisher(goAsync()), System.currentTimeMillis() + BUDGET_MS);
        } else {
            super.onReceive(ctx, intent);   // APPWIDGET_UPDATE etc. -> onUpdate / onDisabled
        }
    }

    @Override
    public void onUpdate(Context ctx, AppWidgetManager manager, int[] ids) {
        render(ctx);   // the last status at once, then a fresh one
        run(ctx, ACTION_REFRESH, finisher(goAsync()), System.currentTimeMillis() + BUDGET_MS);
    }

    // ---- drawing -------------------------------------------------------------

    private static PendingIntent actionIntent(Context ctx, String action, int code) {
        Intent i = new Intent(action).setClass(ctx, TimerWidget.class);
        return PendingIntent.getBroadcast(ctx, code, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    private static PendingIntent openApp(Context ctx) {
        Intent open = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
        return open == null ? null : PendingIntent.getActivity(ctx, 10, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
    }

    static String label(String state) {
        return "working".equals(state) ? "Working" : "break".equals(state) ? "On break" : "Stopped";
    }

    private static int color(String state) {
        return "working".equals(state) ? Color.parseColor("#4ade80")
                : "break".equals(state) ? Color.parseColor("#fbbf24") : Color.parseColor("#aeb7c4");
    }

    private static String str(JSONObject o, String k) {
        return o == null || o.isNull(k) ? "" : o.optString(k, "");
    }

    // "1 action waiting" / "3 actions waiting", "" when the queue is empty
    static String waiting(Context ctx) {
        int n = WorklogClient.queued(ctx);
        return n == 0 ? "" : n == 1 ? "1 action waiting" : n + " actions waiting";
    }

    // the running block's start on the wall clock, from the cached status and when it was fetched
    private static long startedAtMs(JSONObject st) {
        long at = st.optLong("_at", System.currentTimeMillis());
        return at - st.optLong("elapsed_s", 0) * 1000;
    }

    // redraws the widgets, the ongoing notification and the tile from the cached status
    static void render(Context ctx) {
        JSONObject st = WorklogClient.cached(ctx);
        String error = WorklogClient.prefs(ctx).getString("error", "");
        String notice = WorklogClient.prefs(ctx).getString("notice", "");   // what the server refused when replaying
        String waiting = waiting(ctx);
        if (!WorklogClient.hasServer(ctx))
            error = "Open Worklog and set the server";
        String state = st == null ? "stopped" : st.optString("state", "stopped");
        boolean running = "working".equals(state) || "break".equals(state);
        String type = str(st, "type");
        String project = str(st, "project");

        try {
            renderWidget(ctx, st, state, running, type, project, notice, waiting, error);
        } catch (Throwable t) {
            android.util.Log.w("TimerWidget", "widget: " + t);
        }
        try {
            notification(ctx, st, state, type, project, !notice.isEmpty() ? notice : !waiting.isEmpty() ? waiting
                    : WorklogClient.needsApp(error) ? error : "");
        } catch (Throwable t) {
            android.util.Log.w("TimerWidget", "notification: " + t);
        }
        try {
            TileService.requestListeningState(ctx, new ComponentName(ctx, TimerTile.class));
        } catch (Throwable t) {
            android.util.Log.w("TimerWidget", "tile: " + t);
        }
        try {
            scheduleRefresh(ctx, running, !waiting.isEmpty());
        } catch (Throwable t) {
            android.util.Log.w("TimerWidget", "alarm: " + t);
        }
    }

    private static void renderWidget(Context ctx, JSONObject st, String state, boolean running, String type,
                                     String project, String notice, String waiting, String error) {
        RemoteViews v = new RemoteViews(ctx.getPackageName(), R.layout.timer_widget);
        v.setTextViewText(R.id.widget_state, label(state) + (running && !type.isEmpty() ? " · " + type : ""));
        v.setTextColor(R.id.widget_state, color(state));
        if (running) {
            long base = SystemClock.elapsedRealtime() - (System.currentTimeMillis() - startedAtMs(st));
            v.setChronometer(R.id.widget_elapsed, base, null, true);
            v.setViewVisibility(R.id.widget_elapsed, View.VISIBLE);
        } else {
            v.setChronometer(R.id.widget_elapsed, SystemClock.elapsedRealtime(), null, false);
            v.setViewVisibility(R.id.widget_elapsed, View.GONE);
        }
        // a refusal first, then actions waiting (not an error: they go out when the server is back), then errors
        String line = !notice.isEmpty() ? notice
                : !waiting.isEmpty() ? waiting
                : !error.isEmpty() ? error
                : running ? (project.isEmpty() ? "No project" : project)
                : st == null ? "" : String.format(Locale.ROOT, "Today %s h", fmtH(st.optDouble("today_work_h", 0)));
        v.setTextViewText(R.id.widget_project, line);
        v.setTextViewText(R.id.widget_start, "break".equals(state) ? "Resume" : "Start");
        v.setViewVisibility(R.id.widget_start, "working".equals(state) ? View.GONE : View.VISIBLE);
        v.setViewVisibility(R.id.widget_pause, "working".equals(state) ? View.VISIBLE : View.GONE);
        v.setViewVisibility(R.id.widget_stop, running ? View.VISIBLE : View.GONE);
        v.setOnClickPendingIntent(R.id.widget_start, actionIntent(ctx, ACTION_START, 1));
        v.setOnClickPendingIntent(R.id.widget_pause, actionIntent(ctx, ACTION_PAUSE, 2));
        v.setOnClickPendingIntent(R.id.widget_stop, actionIntent(ctx, ACTION_STOP, 3));
        v.setOnClickPendingIntent(R.id.widget_refresh, actionIntent(ctx, ACTION_REFRESH, 4));
        v.setOnClickPendingIntent(R.id.widget_info, openApp(ctx));
        AppWidgetManager manager = AppWidgetManager.getInstance(ctx);
        int[] ids = manager.getAppWidgetIds(new ComponentName(ctx, TimerWidget.class));
        if (ids.length > 0)
            manager.updateAppWidget(ids, v);
    }

    static String fmtH(double h) {
        String s = String.format(Locale.ROOT, "%.2f", h);
        return s.replaceAll("\\.?0+$", "");
    }

    // an ongoing notification with the elapsed time and the actions while a block runs; none when stopped
    private static void notification(Context ctx, JSONObject st, String state, String type, String project, String note) {
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (!"working".equals(state) && !"break".equals(state)) {
            nm.cancel(NOTIFICATION_ID);
            return;
        }
        // Android 13+: without the permission notify() is dropped silently; skip the work
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                && ctx.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            return;
        nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Running timer", NotificationManager.IMPORTANCE_LOW));
        Icon icon = Icon.createWithResource(ctx, R.drawable.ic_timer);
        String text = !note.isEmpty() ? note
                : project.isEmpty() ? "Today " + fmtH(st.optDouble("today_work_h", 0)) + " h" : project;
        Notification.Builder b = new Notification.Builder(ctx, CHANNEL)
                .setSmallIcon(icon)
                .setContentTitle(label(state) + (type.isEmpty() ? "" : " · " + type))
                .setContentText(text)
                .setWhen(startedAtMs(st))
                .setShowWhen(true)
                .setUsesChronometer(true)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setCategory(Notification.CATEGORY_STATUS)
                .setContentIntent(openApp(ctx));
        if ("working".equals(state))
            b.addAction(new Notification.Action.Builder(icon, "Pause", actionIntent(ctx, ACTION_PAUSE, 2)).build());
        else
            b.addAction(new Notification.Action.Builder(icon, "Resume", actionIntent(ctx, ACTION_START, 1)).build());
        b.addAction(new Notification.Action.Builder(icon, "Stop", actionIntent(ctx, ACTION_STOP, 3)).build());
        nm.notify(NOTIFICATION_ID, b.build());
    }

    // an inexact, non-waking alarm while a block runs or actions wait in the queue (the retry replays the
    // queue); none otherwise (the widget's update period covers that)
    private static void scheduleRefresh(Context ctx, boolean running, boolean queued) {
        AlarmManager alarms = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        PendingIntent pi = actionIntent(ctx, ACTION_REFRESH, 5);
        if (running || queued)
            alarms.set(AlarmManager.RTC, System.currentTimeMillis() + (queued ? RETRY_MS : REFRESH_MS), pi);
        else
            alarms.cancel(pi);
    }
}
