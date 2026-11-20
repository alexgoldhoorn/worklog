/* Shared by every page (loaded first): the one fetch wrapper, the server's clock, and a guard against
   answers that arrive after a newer request. Exposed as window.wl. */
"use strict";
(() => {
  const pad = (n) => String(n).padStart(2, "0");
  const isoDate = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;

  // Settings kept on this device only (never state that must survive or be shared).
  const store = {
    get(key, dflt) { try { const v = localStorage.getItem(key); return v == null ? dflt : v; } catch (_) { return dflt; } },
    set(key, value) { try { localStorage.setItem(key, value); } catch (_) { /* private mode */ } },
  };

  // ---- connection state ------------------------------------------------------------
  // Every page shows "Offline · last update HH:MM" under the header while the server does not answer. The last update
  // is the time of the last full status the Timer kept in localStorage (cachedStatus).
  const STATUS_KEY = "worklog.status";
  function cachedStatus() {
    try { const v = JSON.parse(store.get(STATUS_KEY, "null")); return v && v.status ? v : null; } catch (_) { return null; }
  }
  function cacheStatus(status) {
    store.set(STATUS_KEY, JSON.stringify({ status, epoch: Date.now(), at: nowHHMM() }));
  }
  const net = {
    online: true,
    listeners: new Set(),
    set(ok) {
      if (ok === net.online) return;
      net.online = ok;
      renderOffline();
      net.listeners.forEach((fn) => { try { fn(ok); } catch (_) { /* a listener must not break the wrapper */ } });
    },
  };
  function renderOffline() {
    let bar = document.getElementById("offline-bar");
    if (net.online) { if (bar) bar.hidden = true; return; }
    if (!bar) {
      bar = document.createElement("div");
      bar.id = "offline-bar"; bar.className = "offline-bar"; bar.setAttribute("role", "status");
      const main = document.querySelector("main");
      if (!main) return;
      main.before(bar);
    }
    const c = cachedStatus();
    bar.textContent = c ? `Offline \u00b7 last update ${c.at}` : "Offline";
    bar.hidden = false;
  }

  // ---- currency --------------------------------------------------------------------
  // The currency symbol is a server setting. It is kept on this device so a page can show it before the first answer;
  // the fallback is the server's own default.
  const CURRENCY_KEY = "worklog.currency";
  const currency = () => store.get(CURRENCY_KEY, "\u20ac");
  function setCurrency(c) { if (typeof c === "string" && c) store.set(CURRENCY_KEY, c); return currency(); }
  async function loadCurrency() {
    try { setCurrency((await call("GET", "/api/settings")).currency); } catch (_) { /* the kept one stands */ }
    return currency();
  }

  // ---- fetch wrapper -----------------------------------------------------------
  // Resolves with the parsed JSON (or the text of a non-JSON success, null when empty). Rejects with an Error whose
  // message is the server's {"error": ...}, "Server error (502)" for a non-JSON body (a proxy's HTML page), or
  // "Cannot reach the server" when the request never got an answer.
  async function call(method, url, body) {
    const opts = { method, headers: {} };
    if (body instanceof FormData) {
      opts.body = body;
    } else if (body !== undefined) {
      opts.headers["content-type"] = "application/json";
      opts.body = JSON.stringify(body);
    }
    let res;
    try { res = await fetch(url, opts); } catch (_) { net.set(false); throw Object.assign(new Error("Cannot reach the server"), { status: 0 }); }
    net.set(true);
    let text = "";
    try { text = await res.text(); } catch (_) { /* body lost */ }
    const isJson = (res.headers.get("content-type") || "").includes("json");
    let data = null;
    if (text && (isJson || !res.ok)) { try { data = JSON.parse(text); } catch (_) { data = null; } }
    if (!res.ok) {
      const msg = data && typeof data.error === "string" && data.error ? data.error : `Server error (${res.status})`;
      throw Object.assign(new Error(msg), { status: res.status });
    }
    if (queue.waiting()) setTimeout(queue.flush, 0); // any good answer: the server is there, so the waiting actions go
    if (isJson) return data;
    return text || null;
  }

  // ---- server clock --------------------------------------------------------------
  // offset (ms) = server wall clock - device clock, from the `now` of a status answer. serverNow() is a Date whose
  // local fields read the server's wall time, so isoDate() / HH:MM of it agree with the server whatever the
  // device's time zone or skew.
  let offset = 0;
  const serverNow = () => new Date(Date.now() + offset);
  function syncClock(status) {
    const m = status && typeof status.now === "string" && /^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d)(?::(\d\d))?/.exec(status.now);
    if (!m) return;
    const wall = new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0)).getTime();
    offset = wall - Date.now();
    if (Math.abs(offset) < 2000) offset = 0; // network latency / sub-second noise
  }
  let clockReady = null;
  // Pages that need today / now call this once before they start (the Timer syncs on every status anyway).
  function ensureClock() {
    if (!clockReady) clockReady = call("GET", "/api/status?brief=1").then(syncClock).catch(() => { /* device clock stands in */ });
    return clockReady;
  }
  const today = () => isoDate(serverNow());
  const nowHHMM = () => { const d = serverNow(); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };
  // whole minutes since a date + HH:MM of the server's wall clock (built field by field, never via an ISO string)
  function minutesSince(iso, hhmm) {
    const [y, mo, d] = iso.split("-").map(Number), [h, m] = hhmm.split(":").map(Number);
    return Math.max(0, Math.floor((serverNow() - new Date(y, mo - 1, d, h, m)) / 60000));
  }
  const addDays = (iso, n) => { const d = new Date(`${iso}T12:00:00`); d.setDate(d.getDate() + n); return isoDate(d); };
  // "Tue 20 Oct"
  function dayLabel(iso) {
    const d = new Date(`${iso}T12:00:00`);
    return `${d.toLocaleDateString("en", { weekday: "short" })} ${d.getDate()} ${d.toLocaleDateString("en", { month: "short" })}`;
  }


  // ---- time and number entry ---------------------------------------------------------
  // The one rule for every time field (Qt: Api.normTime): "700", "7.30", "7:30", "19h00" -> "07:30"; anything else comes
  // back trimmed. Fields are plain text inputs (class "time") so the browser's own 12/24 h widget never shows.
  const TIME_MSG = "Times must be HH:MM";
  const normTime = (v) => { const m = /^(\d{1,2})[:.hH]?(\d{2})$/.exec(String(v ?? "").trim()); return m && +m[1] < 24 && +m[2] < 60 ? `${pad(+m[1])}:${m[2]}` : String(v ?? "").trim(); };
  const isTime = (v) => /^([01]\d|2[0-3]):[0-5]\d$/.test(v || "");
  // "7.5" and "7,5" -> 7.5; NaN for anything that is not a plain number (Qt: Api.parseNum)
  const parseNum = (t) => { const v = String(t ?? "").trim(); return /^\d+([.,]\d+)?$/.test(v) ? Number(v.replace(",", ".")) : NaN; };
  // Turn the text inputs of root marked class "time" into time fields: placeholder HH:MM, normalised when left; a value that
  // is not a time is put back (to the last good one) with TIME_MSG, never silently kept.
  function bindTimes(root = document) {
    root.querySelectorAll("input.time").forEach((input) => {
      if (input.dataset.timeBound) return;
      input.dataset.timeBound = "1";
      input.type = "text"; input.inputMode = "numeric"; input.autocomplete = "off"; input.maxLength = 5;
      if (!input.placeholder) input.placeholder = "HH:MM";
      let good = isTime(input.value) ? input.value : "";
      input.addEventListener("change", () => {
        const v = normTime(input.value);
        if (v === "" || isTime(v)) { input.value = v; good = v; return; }
        input.value = good;
        input.setCustomValidity(TIME_MSG); input.reportValidity(); input.setCustomValidity("");
      });
      input.addEventListener("focus", () => { if (isTime(input.value)) good = input.value; });
    });
  }
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", () => bindTimes()); else bindTimes();

  // ---- stale answers ---------------------------------------------------------------
  // const next = wl.sequence();  ...  const current = next(); const data = await call(...); if (!current()) return;
  // current() is false once a newer next() has been made, so a slow older answer never overwrites a newer one.
  function sequence() {
    let n = 0;
    return () => { const mine = ++n; return () => mine === n; };
  }

  const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

  // Disable controls while fn runs, so a second tap cannot send the request twice.
  async function locked(controls, fn) {
    const list = [controls].flat().filter(Boolean);
    if (list.some((c) => c.disabled)) return undefined;
    list.forEach((c) => { c.disabled = true; });
    try { return await fn(); } finally { list.forEach((c) => { c.disabled = false; }); }
  }

  // The server's wall clock at a device timestamp, and the API's `at` string ("YYYY-MM-DDTHH:MM") for it.
  const serverAt = (deviceMs) => new Date(deviceMs + (serverNow().getTime() - Date.now()));
  const atString = (d) => `${isoDate(d)}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
  const newId = () => (window.crypto && crypto.randomUUID ? crypto.randomUUID() : `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 12)}`);

  // ---- offline queue for Start / Pause / Stop ----------------------------------------
  // Same rules as the Qt app. An action the server cannot be reached for is kept in localStorage with `at` (the server's
  // clock at the tap) and its request_id, and replayed in order: at load, after any good answer, every 15 s while it waits
  // and when the browser comes back online. The head stays on a network error, 401, 408, 429 and 5xx; any other
  // answer drops it and keeps the server's message. Other requests are never queued.
  const QUEUE_KEY = "worklog.queue";
  const queue = (() => {
    let items = read();
    let stuck = "";           // why the head is still waiting
    let dropped = [];         // messages of actions the server refused on replay, until the page has shown them
    let flushing = false;
    const listeners = new Set();
    function read() {
      try { const v = JSON.parse(store.get(QUEUE_KEY, "[]")); return Array.isArray(v) ? v.filter((x) => x && typeof x.path === "string" && x.body) : []; } catch (_) { return []; }
    }
    const save = () => store.set(QUEUE_KEY, JSON.stringify(items));
    const emit = (what) => listeners.forEach((fn) => { try { fn(what); } catch (_) { /* never break the queue */ } });
    const stays = (status) => status === 0 || status === 401 || status === 408 || status === 429 || status >= 500;
    async function flush() {
      if (flushing) return;
      items = read(); // another tab may have changed it
      if (!items.length) return;
      flushing = true;
      let sent = false;
      try {
        while (items.length) {
          const head = items[0];
          try {
            await call("POST", head.path, head.body);
          } catch (err) {
            if (stays(err.status || 0)) { stuck = err.message; break; }
            dropped.push(err.message);
            items = read().filter((x) => x.body.request_id !== head.body.request_id); save();
            continue;
          }
          items = read().filter((x) => x.body.request_id !== head.body.request_id); save();
          sent = true; stuck = "";
        }
      } finally { flushing = false; }
      emit(sent ? "sent" : "changed");
    }
    function push(path, body) {
      items = read();
      items.push({ path, body: { ...body, at: body.at || atString(serverNow()) } });
      save();
      emit("changed");
    }
    // Send a timer action now, or queue it. Resolves {queued} or {queued:false, status}; an error the server answered rejects.
    async function act(path, body0) {
      const body = { ...body0, request_id: newId() };
      items = read();
      if (items.length) { push(path, body); flush(); return { queued: true }; }
      try {
        return { queued: false, status: await call("POST", path, body) };
      } catch (err) {
        if ((err.status || 0) !== 0) throw err;
        push(path, body);
        return { queued: true };
      }
    }
    function discard() { items = []; stuck = ""; save(); emit("changed"); }
    window.addEventListener("storage", (e) => { if (e.key === QUEUE_KEY) { items = read(); emit("changed"); } });
    window.addEventListener("online", flush);
    setInterval(() => { if (read().length) flush(); }, 15000);
    return {
      flush, act, discard, listeners,
      waiting: () => items.length,
      items: () => items.slice(),
      stuck: () => stuck,
      takeDropped: () => { const d = dropped; dropped = []; return d; },
    };
  })();

  if ("serviceWorker" in navigator) {
    window.addEventListener("load", () => { navigator.serviceWorker.register("/sw.js").catch(() => { /* no worker: online only */ }); });
  }
  document.addEventListener("DOMContentLoaded", () => { if (queue.waiting()) queue.flush(); });

  window.wl = { call, pad, isoDate, serverNow, serverAt, atString, syncClock, ensureClock, today, nowHHMM, minutesSince, addDays, dayLabel, TIME_MSG, normTime, isTime, parseNum, bindTimes, sequence, esc, locked, store,
    currency, setCurrency, loadCurrency, cachedStatus, cacheStatus, net, renderOffline, queue, newId };
})();
