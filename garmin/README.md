# worklog for Garmin (Connect IQ widget)

A widget with a glance for the Forerunner 965. The glance shows the timer state and elapsed
time (`Working 2:14 · acme`, `Break 0:12`, `Stopped · 6.5 h`). Opening it shows the state with a
ticking clock, and Select (button or tap) opens Start / Pause / Stop. After every action the watch
shows what the server returned, with one short vibration on success and three on failure.

It is sideloaded only and does no background work: it fetches when the glance or widget is shown.

## Layout

| File | Role |
|---|---|
| `manifest.xml` | App id, type `widget`, `minApiLevel` 3.4.0, product `fr965`, permission `Communications` |
| `source/Logic.mc` | Pure helpers (formatting, error text, URL/login checks, Basic auth, start body, actions) |
| `source/LogicTest.mc` | `(:test)` unit tests for `Logic` |
| `source/WorklogClient.mc` | `makeWebRequest` through the phone to `/api/<status|start|pause|stop>?brief=1` |
| `source/GlanceView.mc` | The glance (one line) |
| `source/MainView.mc`, `MainDelegate.mc`, `ActionMenuDelegate.mc` | The full widget, action menu, vibration |
| `resources/properties/`, `resources/settings/` | App settings: `serverUrl`, `user`, `password` (defaults; `local.jungle` swaps in a git-ignored `local/properties.xml` with the login) |
| `tools/mock_server.py` | Stdlib mock of the brief API for the simulator |

The server side is `?brief=1` on `GET /api/status` and `POST /api/start|pause|stop`
(`worklog/web/api.py`, `_brief`). Its payload is
`{state, date, since, elapsed_s, type, project, today_work_h, resume, breaks}`. `resume` is the latest
work block today, else the latest of the previous 14 days: Start sends its type and project, so starting
after a break (or the next morning) continues the same project. `breaks` lists the break types (eat first,
then by recent use); Pause opens a second menu with them and sends the picked one.

## Toolchain (Windows)

- Connect IQ SDK Manager with SDK 9.3.0 in `%APPDATA%/Garmin/ConnectIQ/Sdks/`. Download the
  **Forerunner 965** device in the SDK Manager (Devices tab). Java 21 is on the PATH.
- VS Code extension "Monkey C" (optional; the commands below work without it).
- Developer key: `~/.garmin/developer_key.der`, kept outside the repo. To make a new one:
  `openssl genrsa -out developer_key.pem 4096 && openssl pkcs8 -topk8 -inform PEM -outform DER -in developer_key.pem -out developer_key.der -nocrypt`
  (or *Monkey C: Generate a Developer Key* in VS Code). Sideloaded builds must be signed with the
  same key every time, or the watch treats it as a different app and drops its settings.

```sh
SDK="$APPDATA/Garmin/ConnectIQ/Sdks/connectiq-sdk-win-9.3.0-2026-10-20-95888f262/bin"
KEY=~/.garmin/developer_key.der
```

## Build, test, run (Git Bash, from the repo root)

```sh
"$SDK/monkeyc.bat" -d fr965 -f garmin/monkey.jungle -o garmin/bin/worklog.prg -y $KEY -w     # debug build
"$SDK/monkeyc.bat" -d fr965 -f garmin/monkey.jungle -o garmin/bin/test.prg -y $KEY --unit-test
"$SDK/monkeyc.bat" -d fr965 -f garmin/monkey.jungle -o garmin/bin/worklog.prg -y $KEY -r     # release, for the watch
```

Expect `BUILD SUCCESSFUL` and no warnings.

Run in the simulator (start it once with `"$SDK/simulator.exe" &`, then push builds to it).
`monkeydo.bat` takes Windows-style flags (`/t`; `-t` only prints the usage), so run the tests from
PowerShell:

```powershell
$sdk = "$env:APPDATA\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-9.3.0-2026-10-20-95888f262\bin"
& "$sdk\monkeydo.bat" garmin\bin\test.prg fr965 /t   # unit tests: expect PASSED (passed=9)
& "$sdk\monkeydo.bat" garmin\bin\worklog.prg fr965   # the widget; it opens as the glance
```

In the simulator:

- The app opens as the glance. Click (tap) it to open the widget. **Enter** is Select; the arrow
  keys do not move through menus, so click a menu item to pick it.
- Settings: *File → Edit Persistent Storage → Edit Application.Properties* (serverUrl, user,
  password). Saved settings override the defaults in `properties.xml`, also across rebuilds; to
  reset them, delete `%TEMP%\com.garmin.connectiq\GARMIN\APPS\SETTINGS\*.SET`.
  The real server works with the HTTPS check left on.
- Phone link off: *Settings → Connection Type → BLE → Not Connected*. Expect `Phone not connected`.
- Memory is in the status bar. Measured on fr965 (2026-11-05): glance 8.6 kB of 59.9 kB, widget
  12.9 kB of 763.6 kB.
- Against the mock: untick *Settings → Use Device HTTPS Requirements* (otherwise every request
  fails with -1001 and shows `Server error`), run `python garmin/tools/mock_server.py` and set
  serverUrl to `http://127.0.0.1:8503`. Plain `http://` is accepted only for `127.0.0.1` /
  `localhost`; any other non-https URL shows `No login`. `--fail 401` and `--fail 500` show
  `Login failed` and `Server error`. The simulator never times out a request (it waited 130 s
  for `--fail slow` and showed the late reply), so `Timed out` (code -300, from the phone) can
  only be seen on the watch, e.g. with the phone paired but offline. Which message that gives is
  not verified yet. Tick the HTTPS check again afterwards.

### Manual checks (simulator, then the watch)

1. Stopped → Select → Start: `Working`, and the web UI shows the block.
2. Select → Pause: `Break`, the clock restarts at `0:00`.
3. Select → Start: `Working` with the same project as before the break (check the web Day view).
4. Select → Stop: `Stopped`, with today's hours below.
5. Press Select twice quickly while `…` shows: no menu opens, no double action. One press opens
   the menu without also picking its first item, and picking an item does not reopen the menu
   (selects within 500 ms of the menu opening or closing are ignored).
6. Connection off: an action vibrates three times, shows `Phone not connected`, and the previous
   state stays on screen.

## Sideload to the watch

A sideloaded app does **not** appear in the Connect IQ phone app, so its settings can't be edited
there. The login is built into the app instead, as its default settings, from git-ignored files:

1. Once: `cp garmin/local.jungle.example garmin/local.jungle` and create
   `garmin/local/properties.xml` (same shape as `resources/properties/properties.xml`) with the
   URL, user and password. Both are git-ignored; never commit them.
2. Release build with the override:
   `"$SDK/monkeyc.bat" -d fr965 -f "garmin/monkey.jungle;garmin/local.jungle" -o garmin/bin/worklog.prg -y $KEY -r`
   (`grep -c <your user> garmin/bin/worklog.prg` should be non-zero).
3. Connect the watch over USB and copy `garmin/bin/worklog.prg` to `GARMIN/APPS/` (in Explorer:
   *This PC → Forerunner 965 → Internal Storage → GARMIN → Apps*; it is empty apart from system
   folders, store apps don't show there). If `GARMIN/APPS/SETTINGS/WORKLOG.SET` exists, delete it:
   saved settings override the built-in defaults. Unplug; the watch installs it.
4. On the watch, add *worklog* to the glance list (Up from the watch face → scroll to the end →
   Edit → Add).
5. Run the manual checks, once with Bluetooth off on the phone.

To change the login, edit `garmin/local/properties.xml` and repeat steps 2–3.

The real watch refuses plain `http://`, so it can only reach the public HTTPS server, not the LAN
one.

## Another device

Add one `<iq:product id="..."/>` line to `manifest.xml`, download the device in the SDK Manager,
build with `-d <id>`, and check the layout in the simulator (all positions are fractions of the
screen size). If the build warns about the launcher icon size, render `qt/icons/worklog.svg` to
the size from the device's `compiler.json` (`launcherIcon`), e.g.
`magick -background none qt/icons/worklog.svg -resize 65x65 garmin/resources/drawables/launcher.png`.
