# worklog for desktop and Android (Qt Quick app)

A client for the worklog server's JSON API: the same timer, log, reports and planner pages as the
web UI, plus what a browser tab cannot do. On Windows it lives in the tray with a global hotkey; on
Android it adds a home-screen widget, a Quick Settings tile and an ongoing notification.

The web UI (`worklog/web/static/`) is the reference for behaviour. The app mirrors it.

## What it does

| Screen | What you get |
|---|---|
| **Timer** | Start, Switch, Pause and Stop; type, project and break chips; today, week and balance tiles; the work calendar's meetings to add; today's blocks with gaps to fill. The arrows and the date in the header go to any other day: its blocks and totals, with add, edit, delete (with Undo) and move |
| **Week** | The planner's week: meetings, personal events, proposed and approved blocks (approve or reject, with an Undo that puts the block back to proposed), the load gate with its numbers, signals and calendar sync warning, work goals with links, the gate history and the balance settings |
| **Pomodoro** | A countdown per device that offers to pause or resume the log at each interval and never acts on its own |
| More › **Day** | The day planner: the timeline (work, personal, family, the child's duties, protected blocks) with lanes you can switch off, whose-is-this choices (me, us, partner, child: only this one, always for this title, or cancel), who takes a duty, first things, prep notes, training, work today with the timer row (Start, Pause, Stop, type chips) and task ticks with "work on this", the work-calendar state with an Outlook PDF upload, the writes that still wait for the host, and Move: pick a planned run, block or event, see where it fits and what the day looks like with it moved |
| More › **Reports** | Summary per week, month, quarter or year; charts; weekly stats; the monthly invoice; CSV/XLSX export |
| More › **Expected hours** | Expected and sick hours per day |
| More › **Add or find a date** | Put a meeting or appointment in a calendar at a time you know, or let it find the best free slot per day ("where does this fit") |
| More › **Settings** | Server and login (with Test connection, which checks the typed address and login without saving them), week length, rate, currency, the server's defaults, the clients (add, rename, billable, delete) and break types (add, rename, delete), and the options below |

Timer, Week and Pomodoro are the buttons at the bottom; the rest is under the ⋮ menu in the header.
The names, their order and the icons are the same as in the web's navigation. The web has Day as its own tab and a More menu (Add or find a date, Move, Workcal, Settings); the app puts Day first in its More menu and opens Move from the Day page's "Move" buttons.

Day, Week and Add or find a date need the server's planner (`BALANCE_DB`, `BALANCE_STATE_DIR`, `DAY_RULES`; see
[docs/host-integration.md](../docs/host-integration.md)). Without it they show the server's message.

**Offline.** Start, Pause and Stop tapped while the server cannot be reached are kept, in order, with
the time they were tapped, and sent when the server answers again. The Timer shows the state those
actions imply and marks it as waiting. Edits to blocks are not queued. A strip on every screen shows "N action(s) waiting" with Retry now and Discard. An action the server refuses for good is dropped; one that fails for a reason that may pass (offline, login, timeout, rate limit, server error) stays.

**Windows.**

- Closing the window keeps the app in the tray. The tray icon shows working, break, stopped or
  unreachable; its menu starts, pauses (per break type) and stops.
- A global hotkey (default Ctrl+Alt+W) toggles between work and break. A balloon says what happened.
- "Start with Windows" starts it minimised to the tray.
- After 60 minutes (configurable) without keyboard or mouse input during a work block, it asks on
  your return whether that time was a break. A tray message announces the question; the window only
  comes to the front if you switch that on.
- Starting it a second time brings the running copy to the front.
- The password is kept in the Windows Credential Manager.

**Android.**

- A widget, a Quick Settings tile and an ongoing notification control the timer without opening the
  app. They queue actions offline too.
- A notification when a Pomodoro interval ends, also when the app was closed.
- Optional fingerprint/face (or screen lock) before the app opens; it locks again after 2 minutes in
  the background. The widget, tile and notification stay usable while it is locked.
- The password is encrypted with a key in the Android Keystore. App data is excluded from backups.
- A dialog stays between the status bar and the on-screen keyboard, and scrolls when it is taller than that.
- The system Back key leads from Week, Pomodoro or a More screen back to the Timer, and closes an open menu or dialog first; on the Timer it sends the app to the home screen.

Not in the app: import (XLSX/CSV) and the planner's Workcal page (paste, cancel, notes).
Use the web UI for those. The app is in English only.

## First start

1. Open **Settings** (the app opens there when no login is saved).
2. Enter the server address, user and password, then **Connect**. An address without `https://`
   gets it added; local addresses (`localhost`, `192.168.…`, `name.local`) get `http://`.
3. A login over plain `http://` to a server that is not on your own network sends the password
   unencrypted. The app warns about it; put the server behind HTTPS.

On Android 17 and later the app asks for permission to reach devices on the local network when the
server has a local address. Without it the server cannot be reached.

## Build

You need Qt 6.12 (the desktop kit, plus the Android kits you want), CMake and a compiler; for Android
also the SDK, NDK 27, `android_openssl` and JDK 21. Build outside the source tree.

```sh
QT=<path to Qt>/6.12.0
cmake -S qt -B <builddir> -DCMAKE_PREFIX_PATH=$QT/<desktop kit>
cmake --build <builddir> -j8
cmake --build <builddir> --target all_qmllint   # must print no warnings
```

**Windows release** (MinGW kit, Git Bash): `QT_ROOT=<path to Qt> qt/release.sh [outdir]` builds
Release, bundles the Qt runtime and zips it to `../worklog-release/WorkLog-<version>-win64.zip`.
Unzip anywhere and run `WorkLog.exe`.

**Android APK**:

```sh
$QT/android_arm64_v8a/bin/qt-cmake -S qt -B <builddir> -G Ninja -DQT_HOST_PATH=$QT/<desktop kit> \
  -DANDROID_SDK_ROOT=$ANDROID_SDK -DANDROID_NDK_ROOT=$ANDROID_SDK/ndk/<version> -DCMAKE_BUILD_TYPE=Release
cmake --build <builddir> --target apk   # android-build/build/outputs/apk/release/*-unsigned.apk
```

A release APK must be zipaligned and signed before it installs. For sideloading the debug key is
enough:

```sh
zipalign -f -p 4 in.apk out.apk
java -jar $ANDROID_SDK/build-tools/<version>/lib/apksigner.jar sign --ks ~/.android/debug.keystore --ks-pass pass:android out.apk
adb install -r out.apk
```

For the emulator build `android_x86_64` with `-DCMAKE_BUILD_TYPE=Debug`: a debug APK is already signed.

The version is set once, in `project(WorkLogApp VERSION …)` in `CMakeLists.txt`. The Android version
code follows it (0.2 gives 2, 1.3 gives 103).

## Tests

Qt Quick tests in `qt/tests/` run against a real server on a throwaway database.

```sh
cmake -S qt -B <builddir> -DCMAKE_PREFIX_PATH=$QT/<desktop kit> -DWORKLOG_TESTS=ON
cmake --build <builddir> --target tst_worklog
uv run python qt/tests/run_tests.py <builddir>
```

`run_tests.py` starts the server on a free port and runs the tests offscreen. They use their own
settings store, so a saved login is never touched. On Windows the Python environment also needs
`tzdata` (`pip install tzdata`), or the server cannot load its timezone.

`.github/workflows/qt.yml` runs the build, qmllint and these tests.

## For developers

The file-by-file layout, how pages refresh, the offline queue, the QML pitfalls hit so far and the
Android details are in [CLAUDE.md](../CLAUDE.md) under "Qt app".
