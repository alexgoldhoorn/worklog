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

    @Override
    public void onClick() {
        JSONObject st = WorklogClient.cached(this);
        String state = st == null ? "stopped" : st.optString("state", "stopped");
        Tile tile = getQsTile();
        if (tile != null) {   // show the change at once; the answer redraws it
            tile.setState(Tile.STATE_UNAVAILABLE);
            tile.updateTile();
        }
        TimerWidget.run(this, "working".equals(state) ? TimerWidget.ACTION_STOP : TimerWidget.ACTION_START, this::redraw);
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
            if (!error.isEmpty())
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
