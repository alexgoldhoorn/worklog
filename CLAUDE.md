# worklog

A self-hosted work/break timer with reports and an optional day planner. There are three front ends on one server:

- `worklog/`: the FastAPI server, which serves the JSON API (`worklog/web/api.py`) and the web UI (`worklog/web/templates`, `static/`)
- `qt/`: a Qt Quick client for desktop (Windows) and Android that talks to the same JSON API
- a Garmin Connect IQ widget (`garmin/`)

The Day/Week planner lives in `day/` and `balance/`; its host jobs are in `balance/jobs/`. Configuration: `docs/configuration.md`; optional host modules: `docs/host-integration.md`.

**Public repo:** never commit personal names, hosts, IPs, emails, paths or data. Personal values belong in config (env vars, `DAY_RULES`), and tests use the example household in `day/rules.example.json`. The pre-commit hook (`scripts/git-hooks/install.sh`) enforces a private deny list.

## Server

The run, test and Docker commands are in `README.md`. The app is created by `factory()`, and there is no module-level `app`.

- **Auth:** HTTP Basic on everything except `/healthz` (realm `worklog`). An unauthenticated request gets `401 {"error": "login required"}`.
- **Errors:** every error comes back as `{"error": "..."}` with a 4xx status.
- **Contract:** the web UI (`static/app.js`, `static/pomodoro.js`) is the reference for client behaviour. The Qt app mirrors it, so a change to the API or to web behaviour usually needs the same change in `qt/`.

## Qt app (`qt/`)

### Toolchain

Qt 6.12 (desktop kit plus the Android kits you need), CMake, and for Android the SDK, NDK 27, `android_openssl` and JDK 21. Set the paths below for your machine.

Build and lint outside Qt Creator (Git Bash). Use a build directory outside the source tree:

```sh
QT=<path to Qt>/6.12.0
cmake -S qt -B <builddir> -DCMAKE_PREFIX_PATH=$QT/<desktop kit>
cmake --build <builddir> -j8
cmake --build <builddir> --target all_qmllint   # must print no warnings
```

Windows release (MinGW kit): `qt/release.sh [outdir]` builds Release, bundles the Qt runtime with `windeployqt` and zips it to `../worklog-release/WorkLog-<version>-win64.zip`. Run `WorkLog.exe` from that folder; the bare `appWorkLogApp.exe` in a build directory lacks the Qt DLLs.

Android APK. Use `android_x86_64` and `-DCMAKE_BUILD_TYPE=Debug` for the emulator, because a debug APK is signed and installs with `adb install -r`:

```sh
$QT/android_arm64_v8a/bin/qt-cmake -S qt -B <builddir> -G Ninja -DQT_HOST_PATH=$QT/<desktop kit> \
  -DANDROID_SDK_ROOT=$ANDROID_SDK -DANDROID_NDK_ROOT=$ANDROID_SDK/ndk/<version> -DCMAKE_BUILD_TYPE=Release
cmake --build <builddir> --target apk   # android-build/build/outputs/apk/release/*-unsigned.apk
```

- A release APK has to be zipaligned and signed before it installs. For sideloading, the debug key is enough: `zipalign -f -p 4 in.apk out.apk`, then `java -jar build-tools/37.0.0/lib/apksigner.jar sign --ks ~/.android/debug.keystore --ks-pass pass:android`.
- If the first Gradle run hangs with no output, kill the stuck `java.exe` daemon and build again.
- The app's logs: `adb logcat --pid=$(adb shell pidof net.goldhoorn.worklog)`. Driving the app from the shell with `adb shell input tap x y` plus `adb exec-out screencap -p` works for screenshots.
- Right after the emulator boots, the first requests can fail with "Cannot reach". That's the emulator's network starting up, not TLS.

- The executable is a GUI app (`WIN32_EXECUTABLE`). To see `console.log` and QML warnings on stderr, set `QT_FORCE_STDERR_LOGGING=1`.
- If the app is running, the linker can't overwrite `appWorkLogApp.exe` ("Permission denied"). Close it first, or build into another directory.

### Layout

| File | Role |
|---|---|
| `main.cpp` | Sets the Material style, the organisation/app names (where QSettings stores data) and the window icon |
| `Api.qml` | A singleton holding: `request()` (XMLHttpRequest plus Basic auth), the server URL/user (QtCore `Settings`, registry `HKCU\Software\worklog\WorkLogApp`) and the password (in `SecretStore`, migrated once from the old plain-text `password` setting), the server clock (`clockOffsetMs`, refreshed from `now` in every `/api/status` answer; use `Api.now()`/`Api.today()`/`Api.nowHHMM()`, never `new Date()`, for today and now), `overlapItems()` (uses the server's `overlap_details`, falls back to parsing the overlap text), the colour palette copied from `static/style.css` (light and dark), and formatting helpers |
| `Main.qml` | Tabs: Timer · Pomodoro · Log · Reports · Days · Settings, in a `StackLayout` |
| `TimerPage.qml` | Hero card (state, clock, Switch/Pause/Stop), chips, Today/Week/Balance tiles, today's blocks |
| `PomodoroPage.qml` | A port of `pomodoro.js`. State is stored in `Settings` (category `pomodoro`). It keeps counting on other tabs, and `attention()` switches to its tab |
| `DayPage.qml` | The **Log** tab: any day's blocks, totals and calendar proposals |
| `ReportsPage.qml` | Summary per week/month/quarter/year, charts, weekly stats, invoice, export |
| `ExportButtons.qml` | Export buttons used by the Reports page |
| `ExpectedPage.qml` | The **Days** tab: expected/sick hours per day (`/api/days`) |
| `SettingsPage.qml` | Server URL and login (`Api.setServer()`), week basis, rate |
| Components | `Card`, `Tile`, `Caption`, `ChipRow` (single-row, scrolls sideways), `BlockList` (blocks plus gap rows), `BlockDialog`, `NoticeBanner`, `Snackbar`, `ActionButton`, `WeekBars`, `ColumnChart` (diverging, stacked or line), `RankedBars`, `Heatmap`, `DataTable` |
| `filedownloader.*` | C++ `QML_ELEMENT` that downloads an export to a file. QML can't write files |
| `notifier.*` | C++ QML singleton `Notifier.schedule(atMs, title, text)` / `cancel()`. On Android it calls `PomodoroAlarm.java` through JNI; elsewhere it does nothing |
| `secretstore.*` | C++ QML singleton `SecretStore.get/set/remove(key)` plus `removeLegacy(key)` (deletes a plain QSettings key, for the migration). Windows: Credential Manager (target `worklog/<key>`, links Advapi32). Android: `SecretStore.java` (AES-GCM key in the Android Keystore, ciphertext in SharedPreferences) through JNI. Elsewhere: QSettings |
| `android/` | Qt's manifest template filled in (package `net.goldhoorn.worklog`, cleartext allowed for the LAN server) plus launcher icons and `src/net/goldhoorn/worklog/PomodoroAlarm.java` and `SecretStore.java`. It is laid over Qt's template through `QT_ANDROID_PACKAGE_SOURCE_DIR`. Permissions are listed by hand, so Qt Multimedia's camera and microphone permissions stay out. OpenSSL comes from the SDK's `android_openssl` (see `CMakeLists.txt`): without it, `https://` fails |
| `icons/` | `worklog.svg` is the source. The PNGs and `worklog.ico` are rendered from it, so re-render them when the SVG changes |

### How refreshing works

- `Api.changed()` fires after every successful non-GET request, and every page reloads on it.
- `Api.serverChanged()` fires when the URL or login changes.
- Pages also reload when their tab becomes visible, so a failed load never sticks. The Timer also reloads every 60 s.
- Deleting a block (BlockDialog) is immediate; the page's Snackbar offers Undo, which POSTs the block again (billable restored with a PUT if the client default differs).
- Mutations of the running block send `require_open: true`, as the web does. A stale snapshot gets a 409 instead of retyping a block that has already closed.

### QML pitfalls hit here

- **Don't name properties after built-in Item ones.** Each of these broke a load or lint here: `state`, `scale`, `data`, `top`. (`top` passed qmllint but failed at runtime with "Cannot override FINAL property".) Use names like `timerState`, `maxH`, `summary`, `headerH`.
- **A nested layout is never wider than its children allow.** `Layout.fillWidth` on a Row/ColumnLayout does nothing if no child can grow. Centred labels need `Layout.fillWidth: true` plus `horizontalAlignment: Text.AlignHCenter`, not `Layout.alignment: Qt.AlignHCenter`.
- Files with delegates use `pragma ComponentBehavior: Bound` and qualify everything (`row.modelData`, `root.x`), so qmllint stays clean.
- Repeater models that mix item kinds (BlockList's gap rows) must guard fields that are missing: `!!x.flags`, `x.type || ""`.

### Checking the UI without the real server

There's no test suite. The UI was checked with a mock server and screenshots:

- Run a throwaway Python `http.server` mock on `127.0.0.1:8503` that returns fixture JSON for `/api/status`, `/api/day/*`, `/api/summary`, `/api/heatmap`, `/api/invoice`, `/api/days` and `/api/settings`. Use `ThreadingHTTPServer`, because the app sends several requests at once on startup.
- Build a scratch copy whose `main.cpp` uses a different organisation name, so it doesn't overwrite the real saved URL and login, and calls `grabWindow()` per tab.
- Delete the scratch registry key afterwards.
- `QT_QPA_PLATFORM=offscreen` allows windows taller than the screen, but renders no fonts.

### Android specifics

- **Pomodoro notification:** every `save()` in `PomodoroPage` schedules an exact `AlarmManager` alarm at `endsAt` (`USE_EXACT_ALARM`), or cancels it. `PomodoroAlarm` posts the notification even when the process was killed, and tapping it reopens the app. `POST_NOTIFICATIONS` is requested when `Notifier` is first used.
- **Edge to edge:** Android 15 and later draw under the status and navigation bars. `Main.qml` pads the tab bar and the pages with `SafeArea.margins`.
- **Settings is off-screen on a phone** (the tab bar scrolls, but nothing shows that). The app opens on Settings when no user is saved, and any `NoticeBanner` showing `Api.loginMessage` gets a Settings button (`Api.settingsRequested()`).
- **Tab bar overflow:** `Main.qml` shows a fade with an arrow at the side where tabs are hidden. The billable toggle in `BlockList` is 40 x 40 dp; interactive components carry `Accessible.name`/`role`.
- **Narrow screens (320 dp):** a Material `SpinBox` needs about 150 px to show two digits, so grids of SpinBoxes go to one column below 360 px.

### Still missing compared with the web

- Import (XLSX/CSV upload). It deliberately stays on the web.
- The web-only pages Week, Move, Find and Workcal.
- Export on Android writes to the `content://` link from the Save dialog through `QFile`. This is untested on a device.

## Garmin widget (`garmin/`)

A Connect IQ widget with a glance for the Forerunner 965 (Monkey C). Build, test, simulator and sideload commands are in `garmin/README.md`.

- **Toolchain:** Connect IQ SDK 9.3, Java 21 and a developer key outside the repo (keep using the same key). Devices come from the SDK Manager.
- **API:** the watch only uses `?brief=1` on `GET /api/status` and `POST /api/start|pause|stop` (`_brief` in `worklog/web/api.py`). Without `brief` the responses must stay unchanged. Start sends `resume` (the last work block's type and project), so a start after a break continues the same project.
- **HTTPS:** the real watch refuses plain `http://`. `Logic.hasLogin` allows `http://` only for `127.0.0.1`/`localhost` (the mock, `garmin/tools/mock_server.py`, with the simulator's HTTPS check off).
- **Glance code:** everything the glance uses carries `(:glance)`. Unit-test helpers that are not tests carry `(:debug)`, because a `(:test)` function must take exactly one `Logger`.
- `monkeydo.bat` takes Windows flags (`/t`); run it from PowerShell.
- **Key press and release can reach two views:** the press that opens the action menu was also selecting its first item, and the tap on an item reopened the menu. `MainView.markNav()`/`settled()` drop selects within 500 ms of the menu opening or closing. Keep that guard when changing the menu flow.
- **Simulator:** saved settings (`%TEMP%\com.garmin.connectiq\GARMIN\APPS\SETTINGS\*.SET`) override `properties.xml` defaults. With *Use Device HTTPS Requirements* ticked, `http://` fails with -1001. The simulator never times out a request. Enter is Select; arrow keys don't move menus.
- Private methods can't be named after a Toybox symbol checked with `has` (e.g. `vibrate`): the compiler warns.
- **Login on the watch:** sideloaded apps don't appear in the Connect IQ phone app, so settings can't be edited there. Build with `-f "garmin/monkey.jungle;garmin/local.jungle"`; `local.jungle` (git-ignored, from `local.jungle.example`) replaces `resources/properties/` with the git-ignored `garmin/local/properties.xml` holding the login. Never commit either.
- **Another device:** one `<iq:product>` line in `manifest.xml`, plus a simulator check and a launcher icon at the device's size.

## Git

- Conventional commits (`feat:`, `fix:`, `docs:`, `chore:`).
- `qt/` and `garmin/` are not imported by the server; a change to the API or web behaviour usually needs the same change in `qt/`.
- Never commit `garmin/local.jungle`, `garmin/local/`, `.env` files, databases or data exports.
