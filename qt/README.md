# worklog for desktop and Android (Qt Quick app)

A client for the worklog server's JSON API: the same timer, log, reports and planner pages as the
web UI, plus what a browser tab cannot do. On Windows it lives in the tray with a global hotkey; on
Android it adds a home-screen widget, a Quick Settings tile and an ongoing notification.

The web UI (`worklog/web/static/`) is the reference for behaviour. The app mirrors it.

## What it does

| Tab | What you get |
|---|---|
| **Timer** | Start, Switch, Pause and Stop; type, project and break chips; today, week and balance tiles; today's blocks with gaps to fill |
| **Pomodoro** | A countdown per device that offers to pause or resume the log at each interval and never acts on its own |
| **Log** | Any day's blocks and totals; add, edit, delete (with Undo) and move blocks; calendar proposals. Tap the date for a calendar |
| **Week** | The planner's week: meetings, personal events, proposed and approved blocks, the capacity gate, goals |
| **Find** | "Where does this fit": pick a length, travel time and target, get the best slot per day, put it in |
| **Reports** | Summary per week, month, quarter or year; charts; weekly stats; the monthly invoice; CSV/XLSX export |
| **Days** | Expected and sick hours per day |
| **Settings** | Server and login, week length, rate, and the options below |

Week and Find need the server's planner (`BALANCE_DB`, `BALANCE_STATE_DIR`, `DAY_RULES`; see
[docs/host-integration.md](../docs/host-integration.md)). Without it they show the server's message.

**Offline.** Start, Pause and Stop tapped while the server cannot be reached are kept, in order, with
the time they were tapped, and sent when the server answers again. The Timer shows the state those
actions imply and marks it as waiting. Edits to blocks are not queued.

**Windows.**

- Closing the window keeps the app in the tray. The tray icon shows working, break, stopped or
  unreachable; its menu starts, pauses (per break type) and stops.
- A global hotkey (default Ctrl+Alt+W) toggles between work and break. A balloon says what happened.
- "Start with Windows" starts it minimised to the tray.
- After 10 minutes (configurable) without keyboard or mouse input during a work block, it asks on
  your return whether that time was a break.
- Starting it a second time brings the running copy to the front.
- The password is kept in the Windows Credential Manager.

**Android.**

- A widget, a Quick Settings tile and an ongoing notification control the timer without opening the
  app. They queue actions offline too.
- A notification when a Pomodoro interval ends, also when the app was closed.
- Optional fingerprint/face (or screen lock) before the app opens; it locks again after 2 minutes in
  the background. The widget, tile and notification stay usable while it is locked.
- The password is encrypted with a key in the Android Keystore. App data is excluded from backups.

Not in the app: import (XLSX/CSV), the planner's Move and Workcal pages and the balance settings.
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
