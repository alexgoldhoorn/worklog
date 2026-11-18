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
        property alias idleMinutes: api.idleMinutes
        property alias requireUnlock: api.requireUnlock
    }
    // Windows desktop: keep running in the tray when the window closes, and the global start/pause hotkey
    property bool trayKeep: true
    property bool hotkeyOn: true
    property string hotkeySeq: "Ctrl+Alt+W"
    // Windows: ask whether to log the time as a break when you come back after being away this long
    property bool idleOn: true
    property int idleMinutes: 10
    property bool hotkeyCapturing: false   // the Settings field is waiting for a key: release the hotkey so it can be pressed
    property string hotkeyError: ""   // set by TrayController when the hotkey could not be registered
    readonly property bool trayCapable: Qt.platform.os === "windows"
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
    readonly property color faint: dark ? "#5f6b7a" : "#9aa3b0"
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
    function leftOrExtra(worked, expected) {
        if (!(expected > 0))
            return ""
        const d = worked - expected
        return d < -0.005 ? qsTr("%1 left").arg(fmtH(-d)) : qsTr("%1 extra").arg(fmtSigned(d))
    }

    // emitted after any successful mutation, so every page reloads what it shows
    signal changed()
    // emitted when the server address or login changes; every page reloads from scratch
    signal serverChanged()
    // a banner asked for the Settings tab (the window switches to it)
    signal settingsRequested()

    // the error for a 401; a NoticeBanner showing it links to Settings
    readonly property string loginMessage: qsTr("Login required: set user and password in Settings")

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

    function setServer(url, user, pass) {
        // actions queued for another server must never be replayed to this one
        if (url.trim().replace(/\/+$/, "") !== baseUrl && queue.length > 0) {
            const n = queue.length
            queue = []
            saveQueue()
            queueFailed(qsTr("%n queued action(s) for the previous server dropped", "", n))
        }
        status = null
        statusError = ""
        statusGen++   // an answer still on its way belongs to the old server or login
        serverUrl = url
        username = user
        password = pass
        SecretStore.set("password", pass)
        TimerWidget.configure(url, user)
        TimerWidget.refresh()
        serverChanged()
        refreshStatus()
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

    // the break type Pause uses when none was picked: the server's first (most used), "eat" before any status
    function defaultBreak() {
        const b = status && status.chips ? status.chips.break_types : []
        return b && b.length > 0 ? b[0] : "eat"
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
            if (status !== 0 && !api.flushing && api.queue.length > 0)
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

    // ---- offline queue -------------------------------------------------------
    // Start/pause/stop tapped while the server is unreachable are kept (in order, each with the server
    // time it was tapped, the API's `at`) and sent when it answers again.

    property var queue: []   // [{ path, body }]
    property bool flushing: false
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

    // "2026-10-20T09:30", the server's wall clock now
    function atNow() { return today() + "T" + nowHHMM() }

    // POST /api/start|pause|stop. When the server cannot be reached the action is queued and
    // onQueued() runs instead of onErr. A queue that is not empty also takes the action, to keep the order.
    function timerAction(path, body, onOk, onErr, onQueued) {
        const queueIt = function () {
            const b = Object.assign({}, body)
            b.at = atNow()
            queue = queue.concat([{ path: path, body: b }])
            saveQueue()
            if (onQueued) onQueued()
        }
        if (queue.length > 0) {
            queueIt()
            return
        }
        request("POST", path, body, onOk, function (e, status) {
            if (status === 0)
                queueIt()
            else if (onErr)
                onErr(e)
        })
    }

    // send the queue front to back; stops at the first unreachable answer, drops an action the server refuses
    function flushQueue() {
        if (flushing || queue.length === 0)
            return
        flushing = true
        const next = function () {
            if (queue.length === 0) {
                flushing = false
                return
            }
            const item = queue[0]
            request("POST", item.path, item.body, function () {
                queue = queue.slice(1)
                saveQueue()
                next()
            }, function (e, status) {
                if (status === 0 || status === 401) {   // still offline / not logged in: try again later
                    flushing = false
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
        // Qt.btoa(string) is deprecated; the byte-array overload takes the login's UTF-8 bytes
        // (what the server decodes) and returns an ArrayBuffer holding the base64 text
        const utf8 = unescape(encodeURIComponent(api.username + ":" + api.password))
        return "Basic " + Qt.btoa(Array.from(utf8, c => c.charCodeAt(0)))
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
    readonly property color seriesOther: dark ? "#5f6b7a" : "#9aa3b0"

    // free text going into a StyledText label
    function esc(t) { return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
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

    // 1234.4 -> "1 234 €"
    function fmtEur(v) {
        if (v === null || v === undefined)
            return ""
        return Math.round(v).toString().replace(/\B(?=(\d{3})+(?!\d))/g, " ") + " €"
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

    // 2.5 -> "2.5 h", trailing zeros dropped
    function fmtH(h) {
        if (h === null || h === undefined)
            return "–"
        return (Math.round(h * 100) / 100).toString() + " h"
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
