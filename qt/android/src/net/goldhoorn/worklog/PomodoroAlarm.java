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

    public static void schedule(Context ctx, long atMs, String title, String text) {
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
        Intent intent = new Intent(ctx, PomodoroAlarm.class);
        PendingIntent pending = PendingIntent.getBroadcast(ctx, ID, intent,
                PendingIntent.FLAG_NO_CREATE | PendingIntent.FLAG_IMMUTABLE);
        if (pending != null) {
            ((AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE)).cancel(pending);
            pending.cancel();
        }
        ((NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE)).cancel(ID);
    }

    // Android 13+ asks the user once before an app may post notifications
    public static void requestPermission(Activity activity) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                && activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
            activity.runOnUiThread(() ->
                    activity.requestPermissions(new String[] { Manifest.permission.POST_NOTIFICATIONS }, ID));
    }

    @Override
    public void onReceive(Context ctx, Intent intent) {
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
