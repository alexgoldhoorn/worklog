package net.goldhoorn.worklog;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

// After a reboot (or an app update) alarms are gone and the widget shows nothing new: draw the timer again
// from the cached status (which also sets the refresh/retry alarm when a block runs or actions wait)
// and set a pending Pomodoro alarm again.
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context ctx, Intent intent) {
        String a = intent.getAction();
        if (!Intent.ACTION_BOOT_COMPLETED.equals(a) && !Intent.ACTION_MY_PACKAGE_REPLACED.equals(a))
            return;
        try {
            TimerWidget.render(ctx);
        } catch (Throwable t) {
            android.util.Log.w("BootReceiver", "render: " + t);
        }
        try {
            PomodoroAlarm.restore(ctx);
        } catch (Throwable t) {
            android.util.Log.w("BootReceiver", "pomodoro: " + t);
        }
    }
}
