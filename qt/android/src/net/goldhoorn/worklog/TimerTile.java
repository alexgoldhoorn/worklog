package net.goldhoorn.worklog;

import android.graphics.drawable.Icon;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;

import org.json.JSONObject;

// Quick Settings tile: shows whether a block runs and toggles the timer. Tapping it stops a running work
// block, and otherwise starts work again with the last work block's type and project (brief "resume").
public class TimerTile extends TileService {
    private static final long FRESH_MS = 30 * 1000;

    // TimerWidget.render() asks for this after every status change (requestListeningState), so only a
    // status not tried in the last half minute is fetched again here; otherwise the two would keep waking each other
    @Override
    public void onStartListening() {
        draw();
        long at = WorklogClient.prefs(this).getLong("triedAt", 0);
        if (System.currentTimeMillis() - at > FRESH_MS)
            TimerWidget.run(this, TimerWidget.ACTION_REFRESH, this::redraw);
    }

    private void redraw() {
        new Handler(Looper.getMainLooper()).post(this::draw);
    }

    // The worker asks the server what runs now and decides start or stop from that, not from the cached
    // status (which can be 10 minutes old: a timer started on the web would be split by a Start). The cache
    // decides only when the server cannot be reached; the action is then queued.
    @Override
    public void onClick() {
        Tile tile = getQsTile();
        if (tile != null) {   // show the change at once; the answer redraws it
            tile.setState(Tile.STATE_UNAVAILABLE);
            tile.updateTile();
        }
        TimerWidget.run(this, TimerWidget.ACTION_TOGGLE, this::redraw);
    }

    private void draw() {
        Tile tile = getQsTile();
        if (tile == null)
            return;
        JSONObject st = WorklogClient.cached(this);
        String state = st == null ? "stopped" : st.optString("state", "stopped");
        String error = WorklogClient.prefs(this).getString("error", "");
        tile.setIcon(Icon.createWithResource(this, R.drawable.ic_timer));
        tile.setLabel("Worklog");
        tile.setState("working".equals(state) ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            String sub = TimerWidget.label(state);
            String waiting = WorklogClient.queued(this) > 0 ? WorklogClient.queued(this) + " waiting" : "";
            if (!waiting.isEmpty())
                sub = waiting;
            else if (!error.isEmpty())
                sub = "Offline";
            else if (st != null && !st.isNull("project") && !"stopped".equals(state))
                sub += " · " + st.optString("project");
            tile.setSubtitle(sub);
        }
        tile.updateTile();
    }

    @Override
    public void onTileAdded() {
        draw();
    }
}
