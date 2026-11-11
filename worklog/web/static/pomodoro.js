/* Pomodoro tab: a per-device countdown that offers to pause/resume the log, never acts on its own.
   Loaded after app.js, so $, el, api, fmtHM, isoDate and showMessages are in scope. */
"use strict";
(() => {
  const KEY = "worklog.pomodoro";
  const DEFAULTS = { work: 25, brk: 5, long: 15, rounds: 4, beep: false };
  const PRESETS = [[25, 5], [50, 10], [90, 15]];
  const MIN = 60000;

  // ---- pure state helpers (exposed on window.pomo for checks) ----------------------------

  const intOr = (v, dflt, min) => {
    const n = parseInt(v, 10);
    return Number.isFinite(n) ? Math.max(min, n) : dflt;
  };
  function cleanSettings(raw) {
    const r = raw || {};
    return {
      work: intOr(r.work, DEFAULTS.work, 1),
      brk: intOr(r.brk, DEFAULTS.brk, 1),
      long: intOr(r.long, DEFAULTS.long, 1),
      rounds: intOr(r.rounds, 0, 0),
      beep: !!r.beep,
    };
  }
  const fresh = (settings) => ({ phase: "ready", endsAt: null, pausedLeft: null, round: 0, settings: settings || { ...DEFAULTS } });

  function loadState() {
    let raw = null;
    try { raw = JSON.parse(localStorage.getItem(KEY)); } catch (_) { /* unreadable → fresh */ }
    const s = { ...fresh(), ...(raw || {}) };
    s.settings = cleanSettings(s.settings);
    return s;
  }
  function saveState(s) {
    try { localStorage.setItem(KEY, JSON.stringify(s)); } catch (_) { /* private mode */ }
  }

  const phaseLength = (s) => (s.phase === "work" ? s.settings.work : s.phase === "long" ? s.settings.long : s.settings.brk);
  const isLongAfter = (round, rounds) => rounds > 0 && round > 0 && round % rounds === 0;
  const nextAfterWork = (s) => (isLongAfter(s.round, s.settings.rounds) ? "long" : "break");

  function startPhase(s, phase, now) {
    const n = { ...s, phase, pausedLeft: null };
    if (phase === "work") n.round = s.phase === "ready" ? 1 : s.phase === "awaiting_work" ? s.round + 1 : s.round;
    n.endsAt = now + phaseLength(n) * MIN;
    return n;
  }
  const remainingMs = (s, now) => (s.pausedLeft != null ? s.pausedLeft : s.endsAt == null ? 0 : Math.max(0, s.endsAt - now));
  const isCounting = (s) => s.phase === "work" || s.phase === "break" || s.phase === "long";
  const isAwaiting = (s) => s.phase === "awaiting_break" || s.phase === "awaiting_work";

  // ---- live state ------------------------------------------------------------------------

  const pomo = { state: null, lastFlashAt: 0, audio: null, tick: null, gen: 0,
    DEFAULTS, PRESETS, cleanSettings, nextAfterWork, startPhase, remainingMs, phaseLength };
  window.pomo = pomo;

  const fmtMS = (ms) => { const sec = Math.ceil(ms / 1000); return `${pad(Math.floor(sec / 60))}:${pad(sec % 60)}`; };

  function phaseLabel(s) {
    const n = s.settings.rounds;
    switch (s.phase) {
      case "ready": return "Ready";
      case "work": return `Work · round ${s.round}${n ? ` of ${n}` : ""}`;
      case "break": return "Break";
      case "long": return "Long break";
      case "awaiting_break": return isLongAfter(s.round, n) ? "Long break?" : "Break?";
      case "awaiting_work": return "Back to work?";
      default: return "";
    }
  }

  function render(now) {
    const s = pomo.state;
    const hero = $("pomo");
    hero.className = `hero pomo ${s.phase === "work" ? "working" : s.phase === "break" || s.phase === "long" ? "break" : "stopped"}${s.pausedLeft != null ? " paused" : ""}`;
    const ms = isCounting(s) ? remainingMs(s, now) : s.phase === "ready" ? s.settings.work * MIN : 0;
    $("pomo-clock").textContent = fmtMS(ms);
    $("pomo-phase").textContent = phaseLabel(s);
    const len = isCounting(s) ? phaseLength(s) * MIN : 0;
    $("pomo-bar").firstElementChild.style.width = len ? `${Math.min(100, (1 - ms / len) * 100)}%` : isAwaiting(s) ? "100%" : "0%";
    $("pomo-start").disabled = s.phase !== "ready";
    $("pomo-pause").disabled = !isCounting(s);
    $("pomo-pause").textContent = s.pausedLeft != null ? "Resume" : "Pause";
    $("pomo-plus").disabled = s.phase === "ready";
    $("pomo-reset").disabled = s.phase === "ready";
    document.title = isCounting(s) ? `${fmtMS(ms)} · worklog` : isAwaiting(s) ? "00:00 · worklog" : "worklog";
  }

  // presets are built once: a number input's blur fires `change` → re-render, and a chip rebuilt
  // under the finger loses the tap; so only the highlight changes afterwards
  function renderPresets() {
    $("pomo-presets").replaceChildren(...PRESETS.map(([w, b]) => el("button", {
      type: "button", class: "chip", text: `${w}/${b}`, "data-w": w, "data-b": b,
      onclick: () => applySettings({ ...pomo.state.settings, work: w, brk: b }),
    })));
  }
  function renderSettings() {
    const st = pomo.state.settings;
    $("pomo-work").value = st.work; $("pomo-break").value = st.brk;
    $("pomo-long").value = st.long; $("pomo-rounds").value = st.rounds;
    $("pomo-beep").checked = st.beep;
    for (const c of $("pomo-presets").children) {
      c.classList.toggle("on", +c.dataset.w === st.work && +c.dataset.b === st.brk);
    }
  }

  function applySettings(raw) {
    pomo.state.settings = cleanSettings(raw);
    saveState(pomo.state);
    renderSettings();
    render(Date.now());
  }
  function readInputs() {
    return { work: $("pomo-work").value, brk: $("pomo-break").value, long: $("pomo-long").value,
      rounds: $("pomo-rounds").value, beep: $("pomo-beep").checked };
  }

  // ---- log link ----------------------------------------------------------------------------

  const log = { status: null, fetchedAt: 0 };

  async function logStatus() {
    try {
      log.status = await api("GET", "/api/status");
      log.fetchedAt = Date.now();
    } catch (err) {
      log.status = null;
      showMessages($("pomo-notices"), [`Error: ${err.message}`], "error");
    }
    renderLog();
    return log.status;
  }
  function renderLog() {
    const st = log.status;
    const p = $("pomo-log");
    if (!st) { p.replaceChildren("Log: ", el("b", { text: "unreachable" })); return; }
    if (st.state === "stopped") { p.replaceChildren("Log: ", el("b", { text: "stopped" })); return; }
    const b = st.block;
    p.replaceChildren("Log: ", el("b", { text: st.state === "working" ? "working" : "break" }),
      ` · ${b.type}${b.project ? ` · ${b.project}` : ""} · ${fmtHM(st.elapsed_min + Math.floor((Date.now() - log.fetchedAt) / MIN))}`);
  }

  // what "resume work" should log: today's most recent work block, if any
  async function lastWorkBlock() {
    try {
      const day = await api("GET", `/api/day/${isoDate(new Date())}`);
      const work = (day.blocks || []).filter((b) => b.work_type === "work");
      const last = work[work.length - 1];
      return last ? { type: last.type, project: last.project || null } : null;
    } catch (_) { return null; }
  }

  async function logAction(path, bodyFn) {
    try {
      await api("POST", path, bodyFn ? await bodyFn() : undefined);
      $("pomo-notices").replaceChildren();
    } catch (err) {
      showMessages($("pomo-notices"), [`Error: ${err.message}`], "error");
    }
    await logStatus();
  }
  const startWork = () => logAction("/api/start", async () => { const lw = await lastWorkBlock(); return lw ? { type: lw.type, project: lw.project } : undefined; });
  const BREAK_TYPE = "pomo"; // dedicated break type, seeded by schema v4
  const startBreak = () => logAction("/api/pause", async () => ({ type: BREAK_TYPE }));

  // ---- confirm card ------------------------------------------------------------------------

  const cardQuestion = (s) => (s.phase === "awaiting_break"
    ? (isLongAfter(s.round, s.settings.rounds) ? "Start long break?" : "Start break?")
    : "Back to work?");
  const nextPhaseAfterCard = (s) => (s.phase === "awaiting_break" ? nextAfterWork(s) : "work");

  function hideCard() { pomo.gen++; $("pomo-card").hidden = true; $("pomo-card").replaceChildren(); }
  pomo.hideCard = hideCard;

  function renderCard(question, why, buttons) {
    const card = $("pomo-card");
    card.replaceChildren(
      el("p", { class: "q", text: question }),
      ...(why ? [el("p", { class: "why", text: why })] : []),
      el("div", { class: "btns" }, buttons.map(([text, cls, fn]) => el("button", { type: "button", class: cls, text, onclick: fn }))));
    card.hidden = false;
  }

  // kind: "start" (Start tapped in ready), "work_end", "break_end". Re-checks the log first so a stale
  // snapshot never offers an action the log is already in.
  async function showCard(kind) {
    const gen = pomo.gen; // every state change bumps it; a card built for a state the user already left is dropped
    const st = await logStatus();
    if (gen !== pomo.gen) return;
    const logState = st ? st.state : "unknown";
    const s = pomo.state;
    const go = (phase, action) => async () => { hideCard(); if (action) await action(); begin(phase); };
    if (kind === "start") {
      if (logState === "working") return begin("work");
      if (logState === "break") return renderCard("Back to work in the log too?", "A break is running in the log.",
        [["Resume work", "primary", go("work", startWork)], ["Just count", "ghost", go("work")]]);
      return renderCard("Also start a work block?", logState === "stopped" ? "Nothing is running in the log." : "The log could not be reached.",
        [["Start block", "primary", go("work", startWork)], ["Just count", "ghost", go("work")]]);
    }
    const next = nextPhaseAfterCard(s);
    if (kind === "work_end") {
      if (logState === "break") return renderCard("Already on a break.", "The log is already paused.", [["Continue", "primary", go(next)]]);
      if (logState === "stopped") return renderCard(cardQuestion(s), "Log is stopped, so nothing to pause.", [["Skip", "primary", go(next)]]);
      return renderCard(cardQuestion(s), null, [["Start break", "primary", go(next, startBreak)], ["Skip", "ghost", go(next)]]);
    }
    if (logState === "working") return renderCard("Already working.", "The log is already on a work block.", [["Continue", "primary", go(next)]]);
    return renderCard(cardQuestion(s), null, [["Resume work", "primary", go(next, startWork)], ["Skip", "ghost", go(next)]]);
  }
  pomo.onFire = (s) => showCard(s.phase === "awaiting_break" ? "work_end" : "break_end");
  pomo.onStart = () => showCard("start");

  // ---- end of an interval ------------------------------------------------------------------

  function fire() {
    const s = pomo.state;
    s.phase = s.phase === "work" ? "awaiting_break" : "awaiting_work";
    s.endsAt = null; s.pausedLeft = null;
    saveState(s);
    render(Date.now());
    flash();
    if (s.settings.beep) beep();
    notifyEnd(s);
    if (pomo.onFire) pomo.onFire(s);
  }

  // Web Notification when an interval ends while the tab is hidden. Permission is asked on the first Start (a user gesture).
  const canNotify = () => typeof Notification !== "undefined";
  function askNotifyPermission() {
    try { if (canNotify() && Notification.permission === "default") Notification.requestPermission().catch(() => {}); } catch (_) { /* unsupported */ }
  }
  function notifyEnd(s) {
    if (!document.hidden || !canNotify() || Notification.permission !== "granted") return;
    // fire() runs once per ending (it leaves the counting phase), so this never double-notifies
    const body = s.phase === "awaiting_break" ? "Work interval done. Time for a break." : "Break over. Back to work?";
    try {
      const n = new Notification("Pomodoro", { body, tag: "worklog-pomodoro", renotify: true });
      n.onclick = () => { try { window.focus(); } catch (_) { /* ignore */ } n.close(); };
    } catch (_) { /* some mobile browsers only allow service-worker notifications */ }
  }

  function flash() {
    pomo.lastFlashAt = Date.now();
    document.body.classList.remove("flash");
    void document.body.offsetWidth; // restart the animation
    document.body.classList.add("flash");
  }
  document.body.addEventListener("animationend", (e) => { if (e.animationName === "pomo-flash") document.body.classList.remove("flash"); });

  function beep() {
    const ctx = pomo.audio;
    if (!ctx) return;
    const tone = (at) => {
      const o = ctx.createOscillator(); const g = ctx.createGain();
      o.type = "sine"; o.frequency.value = 880;
      g.gain.setValueAtTime(0.2, at); g.gain.exponentialRampToValueAtTime(0.001, at + 0.18);
      o.connect(g).connect(ctx.destination); o.start(at); o.stop(at + 0.2);
    };
    tone(ctx.currentTime); tone(ctx.currentTime + 0.33);
  }
  function unlockAudio() {
    if (pomo.audio || !window.AudioContext) return;
    try { pomo.audio = new AudioContext(); } catch (_) { return; }
    $("pomo-beep-label").textContent = "Sound";
  }

  // ---- ticking -----------------------------------------------------------------------------

  function tick() {
    const now = Date.now();
    const s = pomo.state;
    if (isCounting(s) && s.pausedLeft == null && remainingMs(s, now) === 0) { fire(); return; }
    render(now);
  }

  // ---- buttons -----------------------------------------------------------------------------

  function begin(phase) {
    pomo.gen++;
    pomo.state = startPhase(pomo.state, phase, Date.now());
    saveState(pomo.state);
    render(Date.now());
  }
  pomo.begin = begin;

  function onStart() {
    if (pomo.state.phase !== "ready") return;
    askNotifyPermission();
    if (pomo.onStart) pomo.onStart(); else begin("work");
  }
  function onPause() {
    const s = pomo.state; const now = Date.now();
    if (!isCounting(s)) return;
    if (s.pausedLeft == null) { s.pausedLeft = remainingMs(s, now); s.endsAt = null; }
    else { s.endsAt = now + s.pausedLeft; s.pausedLeft = null; }
    saveState(s); render(now);
  }
  function onPlus() {
    const s = pomo.state; const now = Date.now();
    if (s.phase === "ready") return;
    pomo.gen++;
    if (isAwaiting(s)) {
      // back into the phase that just ended, for five more minutes (the round is unchanged)
      s.phase = s.phase === "awaiting_break" ? "work" : nextAfterWork(s);
      s.endsAt = now + 5 * MIN; s.pausedLeft = null;
      if (pomo.hideCard) pomo.hideCard();
    } else if (s.pausedLeft != null) {
      s.pausedLeft += 5 * MIN;
    } else {
      s.endsAt += 5 * MIN;
    }
    saveState(s); render(now);
  }
  function onReset() {
    pomo.gen++;
    pomo.state = fresh(pomo.state.settings);
    saveState(pomo.state);
    if (pomo.hideCard) pomo.hideCard();
    render(Date.now());
  }

  // ---- init --------------------------------------------------------------------------------

  function init() {
    pomo.state = loadState();
    renderPresets();
    renderSettings();
    render(Date.now());
    for (const id of ["pomo-work", "pomo-break", "pomo-long", "pomo-rounds", "pomo-beep"]) {
      $(id).addEventListener("change", () => applySettings(readInputs()));
    }
    $("pomo-start").addEventListener("click", onStart);
    $("pomo-pause").addEventListener("click", onPause);
    $("pomo-plus").addEventListener("click", onPlus);
    $("pomo-reset").addEventListener("click", onReset);
    if (window.AudioContext) $("pomo-beep-label").textContent = "Sound (tap anywhere to enable)";
    document.addEventListener("pointerdown", unlockAudio, { once: true });
    document.addEventListener("visibilitychange", () => { tick(); }); // endsAt is absolute, so a throttled tab catches up here
    window.addEventListener("focus", tick);
    pomo.tick = setInterval(tick, 1000);
    logStatus();
    setInterval(logStatus, 60 * 1000);
    document.addEventListener("visibilitychange", () => { if (!document.hidden) logStatus(); });
    if (isAwaiting(pomo.state) && pomo.onFire) pomo.onFire(pomo.state); // a reload while a card was pending shows it again
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();
})();
