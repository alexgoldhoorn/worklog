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
import android.graphics.Color;
import android.graphics.drawable.Icon;
import android.os.SystemClock;
import android.service.quicksettings.TileService;
import android.view.View;
import android.widget.RemoteViews;

import org.json.JSONObject;

import java.util.Locale;

// The home-screen widget, and the receiver for every timer action outside the app: the widget's and the
// ongoing notification's Start/Pause/Stop buttons, the periodic refresh alarm and the app's refresh
// requests. The network call runs on a thread while goAsync() keeps the receiver alive; the result
// redraws the widgets, the ongoing notification and the Quick Settings tile (TimerTile).
// There is no polling service: the elapsed time counts on the device (Chronometer), and the status is
// fetched again on an inexact alarm while a block runs, on the widget's update period and after actions.
public class TimerWidget extends AppWidgetProvider {
    static final String ACTION_REFRESH = "net.goldhoorn.worklog.REFRESH";
    static final String ACTION_START = "net.goldhoorn.worklog.START";
    static final String ACTION_PAUSE = "net.goldhoorn.worklog.PAUSE";
    static final String ACTION_STOP = "net.goldhoorn.worklog.STOP";

    private static final String CHANNEL = "timer";
    private static final int NOTIFICATION_ID = 2;   // 1 is the Pomodoro's
    private static final long REFRESH_MS = 10 * 60 * 1000;   // while a block runs, to catch changes made elsewhere

    // called from the app (TimerWidget, C++) after its own timer actions
    public static void refresh(Context ctx) {
        ctx.sendBroadcast(new Intent(ACTION_REFRESH).setClass(ctx, TimerWidget.class));
    }

    // runs an action (or only a refresh) off the main thread and redraws everything; used by the tile too
    static void run(Context ctx, String action, Runnable done) {
        Context app = ctx.getApplicationContext();
        new Thread(() -> {
            try {
                JSONObject last = WorklogClient.cached(app);
                JSONObject st;
                if (ACTION_START.equals(action))
                    st = WorklogClient.start(app, last);
                else if (ACTION_PAUSE.equals(action))
                    st = WorklogClient.pause(app, last);
                else if (ACTION_STOP.equals(action))
                    st = WorklogClient.stop(app);
                else
                    st = WorklogClient.status(app);
                WorklogClient.cache(app, st, null);
            } catch (Exception e) {
                WorklogClient.cache(app, null, e.getMessage());
            }
            render(app);
            if (done != null)
                done.run();
        }).start();
    }

    @Override
    public void onReceive(Context ctx, Intent intent) {
        String action = intent.getAction();
        if (ACTION_REFRESH.equals(action) || ACTION_START.equals(action) || ACTION_PAUSE.equals(action)
                || ACTION_STOP.equals(action)) {
            PendingResult pending = goAsync();
            run(ctx, action, pending::finish);
        } else {
            super.onReceive(ctx, intent);   // APPWIDGET_UPDATE etc. -> onUpdate / onDisabled
        }
    }

    @Override
    public void onUpdate(Context ctx, AppWidgetManager manager, int[] ids) {
        render(ctx);   // the last status at once, then a fresh one
        PendingResult pending = goAsync();
        run(ctx, ACTION_REFRESH, pending::finish);
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
        return "working".equals(state) ? "Working" : "break".equals(state) ? "Break" : "Stopped";
    }

    private static int color(String state) {
        return "working".equals(state) ? Color.parseColor("#4ade80")
                : "break".equals(state) ? Color.parseColor("#fbbf24") : Color.parseColor("#aeb7c4");
    }

    private static String str(JSONObject o, String k) {
        return o == null || o.isNull(k) ? "" : o.optString(k, "");
    }

    // the running block's start on the wall clock, from the cached status and when it was fetched
    private static long startedAtMs(Context ctx, JSONObject st) {
        long at = WorklogClient.prefs(ctx).getLong("statusAt", System.currentTimeMillis());
        return at - st.optLong("elapsed_s", 0) * 1000;
    }

    // redraws the widgets, the ongoing notification and the tile from the cached status
    static void render(Context ctx) {
        JSONObject st = WorklogClient.cached(ctx);
        String error = WorklogClient.prefs(ctx).getString("error", "");
        if (!WorklogClient.hasServer(ctx))
            error = "Open Worklog and set the server";
        String state = st == null ? "stopped" : st.optString("state", "stopped");
        boolean running = "working".equals(state) || "break".equals(state);
        String type = str(st, "type");
        String project = str(st, "project");

        // widget
        RemoteViews v = new RemoteViews(ctx.getPackageName(), R.layout.timer_widget);
        v.setTextViewText(R.id.widget_state, label(state) + (running && !type.isEmpty() ? " · " + type : ""));
        v.setTextColor(R.id.widget_state, color(state));
        if (running) {
            long base = SystemClock.elapsedRealtime() - (System.currentTimeMillis() - startedAtMs(ctx, st));
            v.setChronometer(R.id.widget_elapsed, base, null, true);
            v.setViewVisibility(R.id.widget_elapsed, View.VISIBLE);
        } else {
            v.setChronometer(R.id.widget_elapsed, SystemClock.elapsedRealtime(), null, false);
            v.setViewVisibility(R.id.widget_elapsed, View.GONE);
        }
        String line = !error.isEmpty() ? error
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

        notification(ctx, st, state, type, project);
        TileService.requestListeningState(ctx, new ComponentName(ctx, TimerTile.class));
        scheduleRefresh(ctx, running);
    }

    static String fmtH(double h) {
        String s = String.format(Locale.ROOT, "%.2f", h);
        return s.replaceAll("\\.?0+$", "");
    }

    // an ongoing notification with the elapsed time and the actions while a block runs; none when stopped
    private static void notification(Context ctx, JSONObject st, String state, String type, String project) {
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        if (!"working".equals(state) && !"break".equals(state)) {
            nm.cancel(NOTIFICATION_ID);
            return;
        }
        nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Running timer", NotificationManager.IMPORTANCE_LOW));
        Icon icon = Icon.createWithResource(ctx, R.drawable.ic_timer);
        Notification.Builder b = new Notification.Builder(ctx, CHANNEL)
                .setSmallIcon(icon)
                .setContentTitle(label(state) + (type.isEmpty() ? "" : " · " + type))
                .setContentText(project.isEmpty() ? "Today " + fmtH(st.optDouble("today_work_h", 0)) + " h" : project)
                .setWhen(startedAtMs(ctx, st))
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

    // an inexact, non-waking alarm while a block runs; none while stopped (the widget's update period covers that)
    private static void scheduleRefresh(Context ctx, boolean running) {
        AlarmManager alarms = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        PendingIntent pi = actionIntent(ctx, ACTION_REFRESH, 5);
        if (running)
            alarms.set(AlarmManager.RTC, System.currentTimeMillis() + REFRESH_MS, pi);
        else
            alarms.cancel(pi);
    }
}
