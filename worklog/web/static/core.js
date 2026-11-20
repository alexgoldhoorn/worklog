/* Shared by every page (loaded first): the one fetch wrapper, the server's clock, and a guard against
   answers that arrive after a newer request. Exposed as window.wl. */
"use strict";
(() => {
  const pad = (n) => String(n).padStart(2, "0");
  const isoDate = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;

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
    try { res = await fetch(url, opts); } catch (_) { throw Object.assign(new Error("Cannot reach the server"), { status: 0 }); }
    let text = "";
    try { text = await res.text(); } catch (_) { /* body lost */ }
    const isJson = (res.headers.get("content-type") || "").includes("json");
    let data = null;
    if (text && (isJson || !res.ok)) { try { data = JSON.parse(text); } catch (_) { data = null; } }
    if (!res.ok) {
      const msg = data && typeof data.error === "string" && data.error ? data.error : `Server error (${res.status})`;
      throw Object.assign(new Error(msg), { status: res.status });
    }
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

  // Settings kept on this device only (never state that must survive or be shared).
  const store = {
    get(key, dflt) { try { const v = localStorage.getItem(key); return v == null ? dflt : v; } catch (_) { return dflt; } },
    set(key, value) { try { localStorage.setItem(key, value); } catch (_) { /* private mode */ } },
  };

  window.wl = { call, pad, isoDate, serverNow, syncClock, ensureClock, today, nowHHMM, minutesSince, addDays, dayLabel, sequence, esc, locked, store };
})();
