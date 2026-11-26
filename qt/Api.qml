pragma Singleton
import QtQuick
import QtCore

// Talks to the worklog server's JSON API (see worklog/web/api.py) and holds shared helpers.
QtObject {
    id: api

    property string serverUrl: ""
    property string username: ""
    property string password: ""   // kept in SecretStore (Credential Manager / Android Keystore), not in Settings
    property Settings settings: Settings {
        property alias baseUrl: api.serverUrl
        property alias username: api.username
        property alias trayKeep: api.trayKeep
        property alias hotkeyOn: api.hotkeyOn
        property alias hotkeySeq: api.hotkeySeq
        property alias idleOn: api.idleOn
        property alias idleAfterMinutes: api.idleMinutes   // renamed from idleMinutes: the old default of 10 was saved everywhere
        property alias idleRaise: api.idleRaise
        property alias requireUnlock: api.requireUnlock
        property alias keyShortcuts: api.keyShortcuts
    }
    // Windows desktop: keep running in the tray when the window closes, and the global start/pause hotkey
    property bool trayKeep: true
    property bool hotkeyOn: true
    property string hotkeySeq: "Ctrl+Alt+W"
    // Windows: ask whether to log the time as a break when you come back after being away this long.
    // Long on purpose: reading, a call or a meeting without touching the keyboard is still work.
    property bool idleOn: true
    property int idleMinutes: 60
    // false: the question waits in the window and a tray balloon announces it; true: the window comes to the front
    property bool idleRaise: false
    // window-level single-key shortcuts (S P X 1-6, arrows) on or off; Settings switch
    property bool keyShortcuts: true
    // Is the keyboard focus somewhere the single-key shortcuts may act? Not on a text field, ComboBox
    // or SpinBox/Slider (they use those keys themselves); buttons and the pages are fine.
    function focusFree(item) {
        if (!item)
            return true
        return !("inputMethodHints" in item) && !("stepSize" in item) && !("editable" in item) && !("popup" in item)
    }
    property bool hotkeyCapturing: false   // the Settings field is waiting for a key: release the hotkey so it can be pressed
    property string hotkeyError: ""   // set by TrayController when the hotkey could not be registered
    property bool trayCapable: Qt.platform.os === "windows"   // not readonly: the tests switch it off (no QApplication there)
    // Android: fingerprint/face (or the screen lock) before the saved password is read (Settings switch)
    property bool requireUnlock: false
    // true until Biometric confirms; requests wait and Main.qml shows a locked screen
    property bool locked: false
    Component.onCompleted: {
        // one-time migration: a password an older version left in the plain-text settings moves to the
        // secret store, and is deleted from Settings only once it reads back identically
        const legacy = settings.value("password", "")
        if (legacy !== "") {
            if (SecretStore.set("password", legacy) && SecretStore.get("password") === legacy)
                SecretStore.removeLegacy("password")
            else
                password = legacy   // the store is unavailable: keep working, retry next start
        }
        if (requireUnlock && Biometric.isAvailable())
            locked = true
        else if (password === "")
            password = SecretStore.get("password")
        loadQueue()
        if (queue.length > 0 && baseUrl !== "")
            flushQueue()
        if (baseUrl !== "" && !locked)
            refreshStatus()
        TimerWidget.configure(serverUrl, username)   // Android's widget/tile/notification call the server too
    }
    readonly property string baseUrl: serverUrl.trim().replace(/\/+$/, "")

    // the web app's palette (worklog/web/static/style.css), light and dark
    readonly property bool dark: Application.styleHints.colorScheme === Qt.Dark
    readonly property color bg: dark ? "#0f1216" : "#f3f4f6"
    readonly property color card: dark ? "#181c23" : "#ffffff"
    readonly property color line: dark ? "#2a313c" : "#e1e4e9"
    readonly property color line2: dark ? "#222831" : "#eef0f3"
    readonly property color fg: dark ? "#e7eaef" : "#15181d"
    readonly property color muted: dark ? "#98a2b3" : "#6b7380"
    readonly property color faint: dark ? "#8591a2" : "#5f6978"
    readonly property color accent: dark ? "#5b9dff" : "#2563eb"
    readonly property color accentBg: dark ? "#16284a" : "#e8effd"
    readonly property color accentFg: dark ? "#0b1220" : "#ffffff"
    readonly property color workColor: dark ? "#4ade80" : "#15803d"
    readonly property color workBg: dark ? "#11301c" : "#e3f6e9"
    readonly property color workFg: dark ? "#06200f" : "#ffffff"
    readonly property color breakColor: dark ? "#fbbf24" : "#b45309"
    readonly property color breakBg: dark ? "#3a2c0c" : "#fdf0d5"
    readonly property color breakFg: dark ? "#2a1d00" : "#ffffff"
    readonly property color idleColor: dark ? "#aeb7c4" : "#4b5563"
    readonly property color idleBg: dark ? "#262c36" : "#e9ebef"
    readonly property color errorColor: dark ? "#f87171" : "#dc2626"
    readonly property color warnColor: dark ? "#fbbf24" : "#b45309"
    readonly property color warnBg: dark ? "#3a2c0c" : "#fdf0d5"
    readonly property color infoColor: accent

    // colour for a signed hours figure: green when ahead, muted around zero
    function signColor(h) { return h > 0.005 ? workColor : h < -0.005 ? errorColor : muted }

    // "1.5 h left" or "+0.4 h extra"; empty when nothing is expected
    // (one decimal when `oneDecimal`, as the web's hero does)
    function leftOrExtra(worked, expected, oneDecimal) {
        if (!(expected > 0))
            return ""
        const d = worked - expected
        const f = oneDecimal ? fmtH1 : fmtH
        return d < -0.005 ? qsTr("%1 left").arg(f(-d))
                          : qsTr("%1 extra").arg((d > 0.005 ? "+" : "") + f(d))
    }

    // emitted after any successful mutation, so every page reloads what it shows
    signal changed()
    // emitted when the server address or login changes; every page reloads from scratch
    signal serverChanged()
    // a banner asked for the Settings tab (the window switches to it)
    signal settingsRequested()

    // the error for a 401; a NoticeBanner showing it links to Settings
    readonly property string loginMessage: qsTr("Login required: set the server, user and password in Settings")

    // after Biometric confirmed: read the login and let the pages load
    function unlock() {
        if (!locked)
            return
        if (password === "")
            password = SecretStore.get("password")
        locked = false
        serverChanged()
        refreshStatus()
        flushQueue()   // what was tapped before the lock could not be sent while locked
    }

    // lock again: the password leaves memory and the pages wait behind the lock screen until unlock()
    function lock() {
        if (locked)
            return
        password = ""
        locked = true
    }

    // Android, "Require fingerprint/face to open": the app locks again when it comes back after being
    // away (another app, screen off) for longer than this
    readonly property int relockAfterMs: 2 * 60 * 1000
    property double leftAt: 0   // when the app stopped being active, 0 while it is
    property Connections appState: Connections {
        target: Application
        function onStateChanged(state) {
            if (state !== Qt.ApplicationActive) {
                if (api.leftAt === 0)
                    api.leftAt = Date.now()
                return
            }
            const away = api.leftAt > 0 ? Date.now() - api.leftAt : 0
            api.leftAt = 0
            if (Qt.platform.os === "android" && api.requireUnlock && away > api.relockAfterMs && Biometric.isAvailable())
                api.lock()
        }
    }

    // The one English locale for every date the app shows: the app ships in English only, and
    // Qt.locale() would mix in the device's language.
    readonly property var locale: Qt.locale("en_GB")
    // "Tue 20 Oct" for an ISO date
    function fmtDay(iso) { return locale.toString(parseDate(iso), "ddd d MMM") }

    // Saves the login. Returns "" when all went well, else a message (the password could not be stored).
    function setServer(url, user, pass) {
        // actions queued for another server or login must never be replayed to this one
        if ((url.trim().replace(/\/+$/, "") !== baseUrl || user !== username) && queue.length > 0)
            dropQueue(qsTr("%n queued action(s) for the previous server or login dropped", "", queue.length))
        status = null
        statusError = ""
        statusGen++   // an answer still on its way belongs to the old server or login
        serverUrl = url
        username = user
        password = pass
        const stored = SecretStore.set("password", pass)
        TimerWidget.configure(url, user)
        TimerWidget.refresh()
        serverChanged()
        refreshStatus()
        return stored ? "" : qsTr("Could not save the password on this device")
    }

    // ---- shared status -------------------------------------------------------
    // One copy of /api/status for the Timer, the Pomodoro, the Log's chips and the tray: fetched at start,
    // after every mutation, every 30 s, and whenever a page asks. It keeps its last value while the server
    // is unreachable (see `online`), so the pages can show what they last knew.

    property var status: null
    property real statusAt: 0          // Date.now() when `status` arrived
    property string statusError: ""    // why the last fetch failed, "" after a good one
    // false after a request that got no answer, true after any answer (also an error answer)
    property bool online: true
    property bool statusLoading: false
    property var statusWaiters: []

    // Bumped whenever an answer already on its way would be out of date: another server or login, or a
    // mutation. Such an answer is thrown away and asked for again, so the waiters get a current one.
    property int statusGen: 0
    onBaseUrlChanged: statusGen++

    // then(status, error): the fresh status, or null and the error text. Calls made while one is in
    // flight share its answer.
    function refreshStatus(then) {
        if (then)
            statusWaiters = statusWaiters.concat([then])
        if (statusLoading)
            return
        statusLoading = true
        const gen = statusGen
        const outdated = function () {
            if (gen === api.statusGen)
                return false
            api.statusLoading = false
            api.refreshStatus()
            return true
        }
        const done = function (s, e) {
            statusLoading = false
            const waiters = statusWaiters
            statusWaiters = []
            for (const w of waiters)
                w(s, e)
        }
        request("GET", "/api/status", undefined, function (s) {
            if (outdated())
                return
            status = s
            statusAt = Date.now()
            statusError = ""
            done(s, "")
        }, function (e) {
            if (outdated())
                return
            statusError = e
            done(null, e)
        })
    }
    onChanged: {
        statusGen++   // a status fetched before the mutation no longer counts
        refreshStatus()
    }
    property Timer statusTimer: Timer {
        interval: 30000
        repeat: true
        // Android stops polling in the background (the widget and notification fetch for themselves)
        running: api.baseUrl !== "" && !api.locked
                 && (Qt.platform.os !== "android" || Application.state === Qt.ApplicationActive)
        onTriggered: api.refreshStatus()
    }

    // the break type Pause uses when none was picked: the server's first (most used)
    // (empty before any status: the request then sends no type and the server picks its own)
    function defaultBreak() {
        const b = status && status.chips ? status.chips.break_types : []
        return b && b.length > 0 ? b[0] : ""
    }
    // the body of a Pause: the type is left out when none is known
    function pauseBody(type) {
        const t = type || defaultBreak()
        return t ? { type: t } : {}
    }
    // the body of a Start: with no type and no project picked, the last work block's (status.resume)
    function startBody(type, project) {
        const body = {}
        if (type) body.type = type
        if (project) body.project = project
        const r = status ? status.resume : null
        if (!type && !project && r) {
            if (r.type) body.type = r.type
            if (r.project) body.project = r.project
        }
        return body
    }

    // ---- requests ------------------------------------------------------------

    // a request without an answer for this long counts as unreachable (status 0)
    property int requestTimeoutMs: 20000
    property var inflight: []   // [{xhr, at, finished, fail}]
    property Timer watchdog: Timer {
        interval: 2000
        repeat: true
        running: api.inflight.length > 0
        onTriggered: {
            const now = Date.now()
            for (const e of api.inflight.slice())
                if (now - e.at > api.requestTimeoutMs) {
                    e.fail()        // answers the caller first, so whatever abort() reports is ignored
                    e.xhr.abort()
                }
        }
    }

    function request(method, path, body, onOk, onErr) {
        if (api.locked) {   // no password yet: the pages reload on serverChanged() after unlock()
            if (onErr) onErr(qsTr("Locked"), 0)   // status 0: nothing reached the server, so a queued action stays queued
            return
        }
        const xhr = new XMLHttpRequest()
        const entry = { xhr: xhr, at: Date.now(), finished: false, fail: null }
        const finish = function (status, text) {
            if (entry.finished)
                return
            entry.finished = true
            api.inflight = api.inflight.filter(x => x !== entry)
            api.online = status !== 0
            let data = null
            try { data = JSON.parse(text) } catch (e) { /* non-JSON body */ }
            if (status >= 200 && status < 300) {
                if (data && typeof data.now === "string" && path.indexOf("/api/status") === 0)
                    api.syncClock(data.now)
                if (method !== "GET") {
                    api.changed()
                    TimerWidget.refresh()   // Android: the widget, tile and ongoing notification
                }
                if (onOk) onOk(data, text)
            } else if (onErr) {
                onErr(status === 0 ? qsTr("Cannot reach %1").arg(api.baseUrl)
                      : status === 401 ? api.loginMessage
                      : (data && data.error) || ("HTTP " + status), status)   // status 0: unreachable
            }
            // any answer proves the server is there: send what was queued while it was not
            if (api.flushVerdict(status) !== "keep" && !api.flushing && api.queue.length > 0)
                Qt.callLater(api.flushQueue)
        }
        entry.fail = () => finish(0, "")
        xhr.onreadystatechange = function () {
            if (xhr.readyState === XMLHttpRequest.DONE)
                finish(xhr.status, xhr.responseText)
        }
        api.inflight = api.inflight.concat([entry])
        xhr.open(method, api.baseUrl + path)
        if (api.username !== "")
            xhr.setRequestHeader("Authorization", authHeader())
        if (body !== undefined) {
            xhr.setRequestHeader("Content-Type", "application/json")
            xhr.send(JSON.stringify(body))
        } else {
            xhr.send()
        }
    }

    // What "Test connection" says about an answer from /api/status?brief=1: { ok, message }.
    // `status` is the HTTP status (0 = no answer), `text` the body.
    function probeVerdict(status, text, url) {
        if (status === 0)
            return { ok: false, message: qsTr("Cannot reach %1: check the address, and that the server is running").arg(url) }
        if (status === 401 || status === 403)
            return { ok: false, message: qsTr("The server is there, but it refused this user or password") }
        if (status >= 200 && status < 300) {
            let d = null
            try { d = JSON.parse(text) } catch (e) { /* not JSON */ }
            if (d && typeof d === "object" && !Array.isArray(d) && (typeof d.state === "string" || typeof d.now === "string"))
                return { ok: true, message: qsTr("It works: the server accepted this login") }
            return { ok: false, message: qsTr("Not a worklog server: %1 answered, but not with a worklog status").arg(url) }
        }
        if (status >= 500)
            return { ok: false, message: qsTr("The server answered with an error (HTTP %1)").arg(status) }
        return { ok: false, message: qsTr("Not a worklog server: %1 answered HTTP %2 to the status request").arg(url).arg(status) }
    }

    // Checks an address and login without saving them or touching the queue: done({ ok, message })
    function probe(url, user, pass, done) {
        const base = url.trim().replace(/\/+$/, "")
        if (base === "") {
            done({ ok: false, message: qsTr("Enter the server address first") })
            return
        }
        const xhr = new XMLHttpRequest()
        const entry = { xhr: xhr, at: Date.now(), finished: false, fail: null }
        const finish = function (status, text) {
            if (entry.finished)
                return
            entry.finished = true
            api.inflight = api.inflight.filter(x => x !== entry)
            done(api.probeVerdict(status, text, base))
        }
        entry.fail = () => finish(0, "")
        xhr.onreadystatechange = function () {
            if (xhr.readyState === XMLHttpRequest.DONE)
                finish(xhr.status, xhr.responseText)
        }
        try {
            api.inflight = api.inflight.concat([entry])
            xhr.open("GET", base + "/api/status?brief=1")
            if (user !== "") {
                xhr.setRequestHeader("Authorization", "Basic " + api.base64(unescape(encodeURIComponent(user + ":" + pass))))
            }
            xhr.send()
        } catch (e) {
            finish(0, "")
        }
    }

    // ---- offline queue -------------------------------------------------------
    // Start/pause/stop tapped while the server is unreachable are kept (in order, each with the server
    // time it was tapped, the API's `at`) and sent when it answers again.

    property var queue: []   // [{ path, body }]
    property bool flushing: false
    // bumped whenever the queue is replaced or cleared: a flush request still in flight must not touch the new one
    property int queueGen: 0
    // why the head of the queue is stuck, "" when it is only waiting for the network
    property string queueStuck: ""
    // a queued action the server refused when it was replayed (e.g. a block changed meanwhile)
    signal queueFailed(string message)
    property Settings offline: Settings {
        category: "offline"
        property string queueJson: "[]"
    }
    function loadQueue() {
        try { queue = JSON.parse(offline.queueJson) } catch (e) { queue = [] }
        if (!Array.isArray(queue))
            queue = []
    }
    function saveQueue() { offline.queueJson = JSON.stringify(queue) }

    // empty the queue (another login, or Discard)
    function dropQueue(message) {
        queueGen++
        flushing = false
        queueStuck = ""
        queue = []
        saveQueue()
        if (message)
            queueFailed(message)
    }

    // "2026-10-20T09:30", the server's wall clock now
    function atNow() { return today() + "T" + nowHHMM() }

    // POST /api/start|pause|stop. When the server cannot be reached the action is queued and
    // onQueued() runs instead of onErr. A queue that is not empty also takes the action, to keep the
    // order, and is sent again at once.
    function timerAction(path, body, onOk, onErr, onQueued) {
        // one id per action: it stays with the action in the queue and on every replay, so a request that
        // timed out after the server applied it is not applied a second time
        body = Object.assign({}, body, { request_id: newRequestId() })
        const queueIt = function () {
            const b = Object.assign({}, body)
            b.at = b.at || atNow()   // a backdated action keeps its own time
            queue = queue.concat([{ path: path, body: b }])
            saveQueue()
            if (onQueued) onQueued()
        }
        if (queue.length > 0) {
            queueIt()
            Qt.callLater(flushQueue)
            return
        }
        request("POST", path, body, onOk, function (e, status) {
            if (status === 0)
                queueIt()
            else if (onErr)
                onErr(e)
        })
    }

    // 1-64 characters, unique per action
    property int requestSeq: 0
    function newRequestId() {
        requestSeq++
        return "q" + Date.now().toString(36) + "-" + requestSeq + "-" + Math.floor(Math.random() * 1e9).toString(36)
    }

    // What to do with the head of the queue after the server answered it with `status`:
    // "keep" (try again later: unreachable, login, timeout, rate limit, server error) or "drop"
    // (the server refused the action for good).
    function flushVerdict(status) {
        if (status === 0 || status === 401 || status === 408 || status === 429 || status >= 500)
            return "keep"
        return "drop"
    }

    // send the queue front to back; stops at the first answer that says "later", drops an action the server refuses
    function flushQueue() {
        if (flushing || queue.length === 0)
            return
        flushing = true
        const gen = queueGen
        const next = function () {
            if (gen !== api.queueGen)
                return   // the queue was replaced meanwhile: this chain belongs to the old one
            if (queue.length === 0) {
                flushing = false
                queueStuck = ""
                return
            }
            const item = queue[0]
            request("POST", item.path, item.body, function () {
                if (gen !== api.queueGen)
                    return
                queue = queue.slice(1)
                saveQueue()
                queueStuck = ""
                next()
            }, function (e, status) {
                if (gen !== api.queueGen)
                    return
                if (flushVerdict(status) === "keep") {
                    flushing = false
                    queueStuck = status === 401 ? qsTr("Login required")
                               : status >= 500 ? qsTr("Server error")
                               : status === 0 ? "" : e
                    return
                }
                queue = queue.slice(1)
                saveQueue()
                queueFailed(e)
                next()
            })
        }
        next()
    }
    property Timer retryTimer: Timer {
        interval: 15000
        repeat: true
        running: api.queue.length > 0 && !api.flushing
        onTriggered: api.flushQueue()
    }

    // "Basic …" for the configured login, "" without one
    function authHeader() {
        if (api.username === "")
            return ""
        return "Basic " + base64(unescape(encodeURIComponent(api.username + ":" + api.password)))
    }

    // base64 of a byte string (one char per byte: the login's UTF-8, what the server decodes).
    // Not Qt.btoa(): its string overload is deprecated, and Qt 6.10 has no byte-array overload
    // (it encodes the array's text "97,98,…", so every login fails on Linux's system Qt).
    function base64(bytes) {
        const abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
        let out = ""
        for (let i = 0; i < bytes.length; i += 3) {
            const n = bytes.charCodeAt(i) << 16 | (i + 1 < bytes.length ? bytes.charCodeAt(i + 1) << 8 : 0)
                    | (i + 2 < bytes.length ? bytes.charCodeAt(i + 2) : 0)
            out += abc[n >> 18 & 63] + abc[n >> 12 & 63]
                 + (i + 1 < bytes.length ? abc[n >> 6 & 63] : "=") + (i + 2 < bytes.length ? abc[n & 63] : "=")
        }
        return out
    }

    // "start=…&end=…" with the empty values left out
    function query(params) {
        return Object.keys(params).filter(k => params[k] !== "" && params[k] !== null && params[k] !== undefined)
                     .map(k => k + "=" + encodeURIComponent(params[k])).join("&")
    }

    // ---- formatting ----------------------------------------------------------

    // chart series colours (style.css --s1…--s7, --s-other)
    readonly property var series: dark ? ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9"]
                                       : ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6"]
    readonly property color seriesOther: dark ? "#5f6b7a" : "#9aa3b0"   // not `faint`, which follows the web's contrast fix

    // free text going into a StyledText label
    function esc(t) { return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
    // The little Markdown Todoist puts in task text (the web's mdlite.js): **bold**, __bold__ and `code`
    // markers are dropped, [text](http…) links stay. mdHtml() gives StyledText with <a> for the links,
    // mdPlain() the text alone.
    function mdStrip(t) { return String(t === null || t === undefined ? "" : t).replace(/\*\*(.+?)\*\*/g, "$1").replace(/__(.+?)__/g, "$1").replace(/`(.+?)`/g, "$1") }
    function mdHtml(t) {
        const s = mdStrip(t)
        const re = /\[((?:[^\[\]]|\[[^\[\]]*\]){1,200})\]\((https?:\/\/[^\s)]{1,500})\)/g
        let out = "", last = 0, m
        while ((m = re.exec(s)) !== null) {
            out += esc(s.slice(last, m.index)) + '<a href="' + esc(m[2]).replace(/"/g, "&quot;") + '">' + esc(m[1]) + "</a>"
            last = m.index + m[0].length
        }
        return out + esc(s.slice(last))
    }
    function mdPlain(t) {
        return mdStrip(t).replace(/\[((?:[^\[\]]|\[[^\[\]]*\]){1,200})\]\((https?:\/\/[^\s)]{1,500})\)/g, "$1")
    }
    function pad(n) { return (n < 10 ? "0" : "") + n }

    // "7.5" and "7,5" -> 7.5 whatever the device's locale; NaN for anything that is not a plain number
    function parseNum(t) {
        const v = String(t).trim()
        return /^\d+([.,]\d+)?$/.test(v) ? Number(v.replace(",", ".")) : NaN
    }

    // 2.50 -> "2.5", at most dp decimals
    function fmtNum(v, dp) {
        const f = Math.pow(10, dp === undefined ? 2 : dp)
        return (Math.round(v * f) / f).toString()
    }

    // The server's currency symbol (status.currency, Settings), "€" until it says otherwise
    property string currency: "€"
    onStatusChanged: {
        if (status && typeof status.currency === "string" && status.currency !== "")
            currency = status.currency
    }

    // 1234.4 -> "1 234 €"
    function fmtEur(v) {
        if (v === null || v === undefined)
            return ""
        return Math.round(v).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ") + " " + currency
    }

    // ISO week key as the server writes it: "2026-43"
    function weekKey(iso) {
        const d = parseDate(iso)
        d.setDate(d.getDate() + 3 - (d.getDay() + 6) % 7)   // the Thursday of this week
        const jan4 = new Date(d.getFullYear(), 0, 4)
        const week = 1 + Math.round(((d - jan4) / 86400000 - 3 + (jan4.getDay() + 6) % 7) / 7)
        return d.getFullYear() + "-" + pad(week)
    }

    // [{text, date}] for the overlap notices of a /api/status or /api/day answer: the server's
    // overlap_details when present, else the plain overlaps texts with the date parsed out of them
    function overlapItems(d) {
        if (!d)
            return []
        if (Array.isArray(d.overlap_details))
            return d.overlap_details.map(o => ({ text: o.text, date: o.date || "" }))
        return (d.overlaps || []).map(t => ({ text: t, date: overlapDate(t) }))
    }

    // fallback for servers without overlap_details: "Overlap Tue 20 Oct: …" -> ISO date in the last year, or "" when the text has no date
    function overlapDate(text) {
        const m = /^Overlap \w+ (\d+) (\w+):/.exec(text)
        if (!m)
            return ""
        const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        const now = api.now()
        const d = new Date(now.getFullYear(), months.indexOf(m[2]), Number(m[1]))
        if (d > now)
            d.setFullYear(now.getFullYear() - 1)
        return isoDate(d)
    }

    function isoDate(d) { return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) }

    function parseDate(iso) {
        const p = iso.split("-").map(Number)
        return new Date(p[0], p[1] - 1, p[2])  // local midnight, never UTC
    }

    // "Yesterday", "3 days ago", "In 2 days": where a day lies from today (the Timer on another day, the Day screen)
    function relDay(iso, today) {
        const n = Math.round((parseDate(iso) - parseDate(today)) / 86400000)
        return n === 0 ? qsTr("Today") : n === -1 ? qsTr("Yesterday") : n === 1 ? qsTr("Tomorrow")
             : n < 0 ? qsTr("%1 days ago").arg(-n) : qsTr("In %1 days").arg(n)
    }

    function addDays(iso, n) {
        const d = parseDate(iso)
        d.setDate(d.getDate() + n)
        return isoDate(d)
    }

    // Server clock: the offset (ms) between the server's wall clock and this device's, refreshed by
    // every /api/status answer. now() is a Date whose local fields read the server's local time, so
    // "today" and "now" follow the server's timezone and clock. With an offset of 0 it is new Date().
    property real clockOffsetMs: 0
    function syncClock(iso) {
        const m = /^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d)(?::(\d\d))?/.exec(iso)   // the zone suffix is ignored
        if (!m)
            return
        const wall = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6] || 0))
        if (!isNaN(wall.getTime()))
            clockOffsetMs = wall.getTime() - Date.now()
    }
    function now() { return new Date(Date.now() + clockOffsetMs) }
    function today() { return isoDate(now()) }

    function nowHHMM() {
        const d = now()
        return pad(d.getHours()) + ":" + pad(d.getMinutes())
    }

    // "700", "7:00", "07.00", "19h00" -> "HH:MM" (same as normTime in the web's app.js); anything else comes back trimmed
    function normTime(text) {
        const v = String(text).trim()
        const m = /^(\d{1,2})[:.hH]?(\d{2})$/.exec(v)
        return m && Number(m[1]) < 24 && Number(m[2]) < 60 ? pad(Number(m[1])) + ":" + m[2] : v
    }

    // 2.54 -> "2.5 h" (one decimal, trailing zero dropped, like the web's fmtH1)
    function fmtH1(h) {
        if (h === null || h === undefined)
            return "–"
        return fmtNum(h, 1) + " h"
    }

    // 2.5 -> "2.5 h", trailing zeros dropped
    function fmtH(h) {
        if (h === null || h === undefined)
            return "–"
        return (Math.round(h * 100) / 100).toString() + " h"
    }

    // "+2.5 h extra" / "-3 h short": a signed total that says which way it goes (the web's shortOrExtra)
    function shortOrExtra(h) {
        return h < -0.005 ? qsTr("%1 short").arg(fmtSigned(h)) : qsTr("%1 extra").arg(fmtSigned(h))
    }
    // "3 Mar 2025"
    function fmtSince(iso) { return iso ? locale.toString(parseDate(iso), "d MMM yyyy") : "" }
    // what the Timer's Balance figure means (the web's balanceHelp)
    function balanceHelp(since) {
        return (since ? qsTr("Hours worked minus hours expected, added up over every week since %1, your first logged day.").arg(since)
                      : qsTr("Hours worked minus hours expected, added up over every week."))
               + " " + qsTr("Plus means you are ahead, minus that you are behind.") + "\n\n"
               + qsTr("This week's full expected hours already count, so the figure is low on Monday and climbs as you work. \"Before this week\" is where you stood at the end of last week.")
    }
    function fmtSigned(h) {
        if (h === null || h === undefined)
            return "–"
        return (h > 0.005 ? "+" : "") + fmtH(h)
    }

    // hours -> "7:30"
    function fmtHM(h) {
        const m = Math.round(Math.abs(h) * 60)
        return (h < 0 ? "-" : "") + Math.floor(m / 60) + ":" + pad(m % 60)
    }

    // seconds -> "1:02:03"
    function fmtClock(s) {
        return Math.floor(s / 3600) + ":" + pad(Math.floor(s / 60) % 60) + ":" + pad(s % 60)
    }
}
