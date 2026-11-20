package net.goldhoorn.worklog;

import android.Manifest;
import android.app.Activity;
import android.app.AlarmManager;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.os.Build;

// Posts a notification when a Pomodoro interval ends, also while the app is in the background or
// killed: the end time is handed to AlarmManager, which wakes this receiver. Called from Notifier (C++).
public class PomodoroAlarm extends BroadcastReceiver {
    private static final String CHANNEL = "pomodoro";
    private static final int ID = 1;

    private static final String PREFS = "worklog_pomodoro";

    // the pending alarm is kept here too, so BootReceiver can set it again after a reboot (alarms are lost)
    private static void remember(Context ctx, long atMs, String title, String text) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putLong("at", atMs).putString("title", title).putString("text", text).apply();
    }

    private static void forget(Context ctx) {
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply();
    }

    // after a reboot or an update: set the alarm again when its end time is stored and still ahead
    static void restore(Context ctx) {
        android.content.SharedPreferences p = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        long at = p.getLong("at", 0);
        if (at > System.currentTimeMillis())
            setAlarm(ctx, at, p.getString("title", ""), p.getString("text", ""));
        else if (at != 0)
            forget(ctx);
    }

    public static void schedule(Context ctx, long atMs, String title, String text) {
        remember(ctx, atMs, title, text);
        setAlarm(ctx, atMs, title, text);
    }

    private static void setAlarm(Context ctx, long atMs, String title, String text) {
        Intent intent = new Intent(ctx, PomodoroAlarm.class)
                .putExtra("title", title)
                .putExtra("text", text);
        PendingIntent pending = PendingIntent.getBroadcast(ctx, ID, intent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        AlarmManager alarms = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        // exact when allowed (USE_EXACT_ALARM / SCHEDULE_EXACT_ALARM), else within a few minutes
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms())
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending);
        else
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, atMs, pending);
    }

    // drops the pending alarm and a notification that is already showing
    public static void cancel(Context ctx) {
        forget(ctx);
        Intent intent = new Intent(ctx, PomodoroAlarm.class);
        PendingIntent pending = PendingIntent.getBroadcast(ctx, ID, intent,
                PendingIntent.FLAG_NO_CREATE | PendingIntent.FLAG_IMMUTABLE);
        if (pending != null) {
            ((AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE)).cancel(pending);
            pending.cancel();
        }
        ((NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE)).cancel(ID);
    }

    // Asks once, in one dialog: Android 13+ before notifications may be posted, Android 17+ before a LAN
    // server may be reached (only when the saved server is one; a public https server needs neither)
    public static void requestPermission(Activity activity) {
        java.util.ArrayList<String> need = new java.util.ArrayList<>();
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            need.add(Manifest.permission.POST_NOTIFICATIONS);
        String lan = "android.permission.ACCESS_LOCAL_NETWORK";
        if (Build.VERSION.SDK_INT >= 37 && activity.checkSelfPermission(lan) != PackageManager.PERMISSION_GRANTED
                && LocalNet.isLocalHost(WorklogClient.prefs(activity).getString("url", "")))
            need.add(lan);
        if (!need.isEmpty())
            activity.runOnUiThread(() -> activity.requestPermissions(need.toArray(new String[0]), ID));
    }

    @Override
    public void onReceive(Context ctx, Intent intent) {
        forget(ctx);   // it fired
        NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
        nm.createNotificationChannel(new NotificationChannel(CHANNEL, "Pomodoro", NotificationManager.IMPORTANCE_HIGH));

        // tapping it brings the app back, which shows the confirm card on the Pomodoro tab
        Intent open = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
        PendingIntent content = open == null ? null : PendingIntent.getActivity(ctx, ID, open,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

        Notification n = new Notification.Builder(ctx, CHANNEL)
                .setSmallIcon(ctx.getApplicationInfo().icon)
                .setContentTitle(intent.getStringExtra("title"))
                .setContentText(intent.getStringExtra("text"))
                .setCategory(Notification.CATEGORY_ALARM)
                .setContentIntent(content)
                .setAutoCancel(true)
                .build();
        nm.notify(ID, n);
    }
}
