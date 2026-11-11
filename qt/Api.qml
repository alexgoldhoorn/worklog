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
    }
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
        if (password === "")
            password = SecretStore.get("password")
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

    function setServer(url, user, pass) {
        serverUrl = url
        username = user
        password = pass
        SecretStore.set("password", pass)
        serverChanged()
    }

    function request(method, path, body, onOk, onErr) {
        const xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            let data = null
            try { data = JSON.parse(xhr.responseText) } catch (e) { /* non-JSON body */ }
            if (xhr.status >= 200 && xhr.status < 300) {
                if (data && typeof data.now === "string" && path.indexOf("/api/status") === 0)
                    api.syncClock(data.now)
                if (method !== "GET")
                    api.changed()
                if (onOk) onOk(data)
            } else if (onErr) {
                onErr(xhr.status === 0 ? qsTr("Cannot reach %1").arg(api.baseUrl)
                      : xhr.status === 401 ? api.loginMessage
                      : (data && data.error) || ("HTTP " + xhr.status))
            }
        }
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
