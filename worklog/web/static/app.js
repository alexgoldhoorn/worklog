/* worklog front end: plain ES2020, no modules, no build step. */
"use strict";

// ---- helpers ---------------------------------------------------------------

const $ = (id) => document.getElementById(id);

function el(tag, attrs, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k === "class") e.className = v;
    else if (k === "text") e.textContent = v;
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else if (v !== false && v != null) e.setAttribute(k, v === true ? "" : v);
  }
  for (const kid of kids.flat()) {
    if (kid != null) e.append(kid);
  }
  return e;
}

// the shared fetch wrapper, server clock and stale-answer guard live in core.js (window.wl)
const { pad, isoDate, serverNow, syncClock, minutesSince } = wl;
const api = wl.call;
const todayIso = wl.today;
const nowHHMM = wl.nowHHMM;
const fmtNum = (h, dp = 2) => (Math.round(h * 10 ** dp) / 10 ** dp).toFixed(dp).replace(/(\.\d*?)0+$/, "$1").replace(/\.$/, "");
const fmtH = (h) => (h == null ? "–" : `${fmtNum(h)} h`);
const fmtSigned = (h) => (h == null ? "–" : `${h > 0 ? "+" : ""}${fmtH(h)}`);
const signClass = (h) => (h == null || Math.abs(h) < 0.005 ? "" : h > 0 ? "pos" : "neg");
function fmtHM(min) {
  if (min == null) return "–";
  const m = Math.max(0, Math.round(min));
  return `${Math.floor(m / 60)}:${pad(m % 60)}`;
}
const fmtHMS = (sec) => { const s = Math.max(0, Math.floor(sec)); return `${Math.floor(s / 3600)}:${pad(Math.floor(s / 60) % 60)}:${pad(s % 60)}`; };
const toMin = (t) => { const [h, m] = t.split(":").map(Number); return h * 60 + m; };
// time entry: one rule for every page (core.js); "9:50", "9.50", "950" -> "09:50"
const { normTime, isTime: isHHMM } = wl;
const fmtH1 = (h) => `${fmtNum(h, 1)} h`;
const shiftDate = (iso, days) => { const d = new Date(`${iso}T12:00:00`); d.setDate(d.getDate() + days); return isoDate(d); };
const weekdayShort = (iso) => new Date(`${iso}T12:00:00`).toLocaleDateString("en", { weekday: "short" });
function fmtDayTitle(iso) {
  const d = new Date(`${iso}T12:00:00`);
  const t = `${d.toLocaleDateString("en", { weekday: "short" })} ${d.getDate()} ${d.toLocaleDateString("en", { month: "short" })}`;
  return d.getFullYear() === serverNow().getFullYear() ? t : `${t} ${d.getFullYear()}`;
}
function isoWeek(iso) {
  const d = new Date(Date.UTC(...iso.split("-").map(Number).map((v, i) => (i === 1 ? v - 1 : v))));
  const day = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() + 4 - day);
  const y = d.getUTCFullYear();
  const wk = Math.ceil(((d - Date.UTC(y, 0, 1)) / 86400000 + 1) / 7);
  return `${y}-${pad(wk)}`;
}
const isWeekend = (iso) => { const wd = new Date(`${iso}T12:00:00`).getDay(); return wd === 0 || wd === 6; };

function showMessages(target, items, cls) {
  target.replaceChildren(...items.filter(Boolean).map((t) => (typeof t === "string"
    ? el("p", { class: cls || "", text: t })
    : el("p", { class: [cls || "", t.cls || "", t.onclick ? "link" : ""].join(" ").trim(), text: t.text, onclick: t.onclick }))));
}

// "+2.5 h extra" / "-3 h short": a signed total that says which way it goes
const shortOrExtra = (h) => `${fmtSigned(h)} ${h < -0.005 ? "short" : "extra"}`;
function signedCell(h, extra) {
  return el("td", { class: `num ${signClass(h)} ${extra || ""}`.trim(), text: fmtSigned(h) });
}

// ---- timer page --------------------------------------------------------------

const CHIP_LIMIT = { type: 6, project: 4, breakType: 6 };

const timer = {
  date: null,
  today: null, // the server's date when the page last looked
  followsToday: true, // the page shows "today" (no ?date=), so it moves on when the server's date does
  status: null,
  day: null,
  pending: { type: null, project: null, breakType: null },
  expanded: { type: false, project: false, breakType: false },
  busy: false,
  serverNotices: [],
  editing: null, // {id, field} while a block cell has its editor open
  dirty: false, // the day arrived while a cell was being edited; shown when the edit ends
  refocus: null, // {id, field}: the cell to focus after the next table rebuild
  followup: null, // one-tap offer after a time edit (move the neighbouring block's edge too)
  real: null, // the last status the server (or the offline copy) gave; `status` is that plus the waiting offline actions
  realAt: 0, // Date.now() the real status is valid at
  offline: false,
  fetchedAt: 0, // Date.now() `status` is valid at; the clock ticks on from status.elapsed_s
  tick: null,
};

function timerDate() {
  const q = new URLSearchParams(location.search).get("date");
  return q || todayIso();
}

// title, "Today" button and date picker follow timer.date / the server's today
function renderDayHead() {
  const today = timer.today;
  $("day").value = timer.date;
  $("day-title").textContent = timer.date === today ? `Today · ${fmtDayTitle(timer.date)}` : fmtDayTitle(timer.date);
  $("day-today").hidden = timer.date === today;
}

// The server's date can move on while the page is open (overnight, or a skewed device clock). A page that shows
// "today" follows it; one that shows another day only updates its Today button. True when timer.date changed.
function followToday() {
  const today = todayIso();
  if (timer.today === today) return false;
  const moved = timer.followsToday && timer.date !== today;
  timer.today = today;
  if (moved) timer.date = today;
  renderDayHead();
  return moved;
}

function setBusy(on) {
  timer.busy = on;
  for (const id of ["btn-start", "btn-pause", "btn-stop"]) $(id).disabled = on;
  if (!on) renderButtons();
}

function showError(err) {
  showMessages($("notices"), [...timer.serverNotices, `Error: ${err.message}`], "error");
}

function renderNotices() {
  showMessages($("notices"), timer.serverNotices);
}

// elapsed time, ticked locally between status refreshes
function liveElapsedSec() {
  const s = timer.status;
  if (!s || s.state === "stopped" || !s.block) return 0;
  return Math.max(0, (s.elapsed_s || 0) + Math.floor((Date.now() - timer.fetchedAt) / 1000));
}
const liveElapsedMin = () => Math.floor(liveElapsedSec() / 60);
const isRunningBlock = (b) => !!(timer.status && timer.status.block && timer.status.block.id === b.id);

// hours of the running work block, added on top of the closed totals the server sent
const liveRunH = () => (timer.status && timer.status.state === "working" ? liveElapsedMin() / 60 : 0);

// "2.5 h left" or "+1.2 h extra"; empty when nothing is expected
function leftOrExtra(worked, expected, fmt = fmtH) {
  if (!(expected > 0)) return { text: "", cls: "" };
  const d = worked - expected;
  if (d < -0.005) return { text: `${fmt(-d)} left`, cls: "" };
  return { text: `${d > 0 ? "+" : ""}${fmt(d)} extra`, cls: d > 0.005 ? "pos" : "" };
}

// the two hero clocks, ticked every second
function renderHeroClocks() {
  const s = timer.status;
  if (!s) return;
  $("state-clock").textContent = s.state === "stopped" ? "—" : fmtHMS(liveElapsedSec());
  const todayMin = s.today.work_h * 60 + (s.state === "working" ? liveElapsedSec() / 60 : 0);
  const exp = s.today.expected_h || 0;
  const le = leftOrExtra(todayMin / 60, exp, fmtH1);
  $("today-clock").replaceChildren(fmtHM(todayMin), el("small", { text: exp > 0 ? `/ ${fmtH(exp)}` : "h" }));
  $("today-label").replaceChildren("Today", le.text ? el("span", { class: le.cls, text: `· ${le.text}` }) : null);
}

function renderClock() {
  const s = timer.status;
  if (!s) return;
  renderHeroClocks();
  renderCounters();
  // open rows on the day table tick along with the clock
  for (const td of document.querySelectorAll("#blocks td.dur[data-open]")) {
    const [iso, hhmm, id] = td.dataset.open.split(" ");
    td.textContent = fmtHM(isRunningBlock({ id: Number(id) }) ? liveElapsedMin() : minutesSince(iso, hhmm));
  }
}

// today / week / month counters under the clock, live while working
function renderCounters() {
  const s = timer.status;
  if (!s || !s.month) return;
  const run = liveRunH();
  const month = new Date(`${s.month.key}-01T12:00:00`).toLocaleDateString("en", { month: "short" });
  const items = [[`Week ${s.week.key.slice(5)}`, s.week.worked_h + run, s.week.expected_h],
    [month, s.month.worked_h + run, s.month.expected_h]];
  $("state-counters").replaceChildren(...items.map(([k, w, e]) => {
    const le = leftOrExtra(w, e, fmtH1);
    return el("div", { class: "ctr" }, el("span", { class: "ck", text: k }), el("span", { class: "cv", text: fmtH1(w) }),
      el("span", { class: `cs ${le.cls}`, text: le.text || (e > 0 ? "" : "nothing expected") }));
  }));
}

function renderState() {
  const s = timer.status;
  const hero = $("state");
  const cls = s.state === "working" ? "working" : s.state === "break" ? "break" : "stopped";
  const over = s.state === "working" && s.past_stop_min > 0;
  hero.className = `hero ${cls}${over ? " over" : ""}`;
  $("brand-dot").className = `dot ${cls}`;
  const label = $("state-label");
  const sub = $("state-sub");
  if (s.state === "stopped") {
    label.textContent = "Stopped";
    sub.textContent = "Nothing running. Pick a type and tap Start.";
  } else {
    const b = s.block;
    label.textContent = s.state === "working" ? "Working" : "On break";
    sub.replaceChildren(el("b", { text: b.type }), b.project ? ` · ${b.project}` : "", ` · since ${s.since}`,
      over ? ` · past your ${s.hard_stop} stop by ${fmtHM(s.past_stop_min)}` : "");
  }
  renderClock();
  document.title = s.state === "stopped" ? "worklog" : `${fmtHM(liveElapsedMin())} ${s.state === "working" ? "▶" : "⏸"} worklog`;
}

// What the next Start / Pause will use. Start: the picked chip, else the last work block's type (`resume`), else the
// server's default (the button then reads "default"). Pause: the picked break type, else the first of the server's
// break types (its default), else no type at all.
function resumeInfo() {
  const r = timer.status && timer.status.resume;
  return r && r.type ? r : null;
}
function nextStartType() {
  if (timer.pending.type) return timer.pending.type;
  const r = resumeInfo();
  return !$("project").value.trim() && r ? r.type : "default";
}
function pauseType() {
  if (timer.pending.breakType) return timer.pending.breakType;
  const list = timer.status && timer.status.chips && timer.status.chips.break_types;
  return list && list.length ? list[0] : null;
}

function renderButtons() {
  const s = timer.status;
  if (!s) return;
  const type = nextStartType();
  const start = $("btn-start");
  const pause = $("btn-pause");
  const stop = $("btn-stop");
  // the small line says what the button will use; the tooltip what it does (the Qt app's ActionButtons say the same)
  // a time set under the buttons ("At 13:00"): every button says it, and a time that cannot be disables them
  const at = atState();
  // "work · from 13:00"; a narrow screen drops the type (the chips show it), as the Qt app does
  const from = (text) => (at.time ? [el("span", { class: "at-type", text: `${text} · ` }), `from ${at.time}`] : text);
  start.replaceChildren(s.state === "working" ? "Switch" : s.state === "break" ? "Resume" : "Start", el("small", {}, from(type === "default" ? "default type" : type)));
  start.title = s.state === "working" ? "End this block and start a new one with this type" : s.state === "break" ? "End the break and go back to work" : "Start a work block";
  pause.replaceChildren(s.state === "break" ? "Change" : "Pause", el("small", {}, from(pauseType() || "break")));
  pause.title = s.state === "break" ? "Change the type of this break" : "Start a break";
  stop.replaceChildren("Stop", el("small", { text: s.state === "stopped" ? "nothing running" : at.time ? `at ${at.time}` : "close block" }));
  stop.title = "End the running block";
  start.disabled = pause.disabled = timer.busy || !!at.problem;
  stop.disabled = timer.busy || s.state === "stopped" || !!at.problem;
  $("state").classList.toggle("backdated", !!at.time);
  const note = $("at-note");
  // a half-typed time is not called wrong while it is being typed
  const typing = at.problem === wl.TIME_MSG && document.activeElement === $("at-time");
  note.textContent = at.problem ? (typing ? "" : at.problem) : at.time ? `Backdated: next press counts from ${at.time}` : "";
  note.className = at.problem ? "error" : "";
  // forgot to start after the last block: one tap sets the time to where it ended (Start then starts there)
  const last = $("at-last");
  const lastEnd = s.state === "stopped" && timer.day && timer.date === todayIso()
    ? timer.day.blocks.map((b) => b.end).filter(Boolean).sort().pop() : null;
  last.hidden = at.open || !(lastEnd && lastEnd < nowHHMM());
  if (!last.hidden) {
    last.dataset.at = lastEnd;
    last.textContent = `From ${lastEnd} (last end)`;
    last.title = `Set the time to ${lastEnd}, where the last block ended; Start then starts there`;
  }
}

function renderTotals() {
  const s = timer.status;
  const run = liveRunH();
  const live = s.state === "working";
  const liveTag = live ? el("span", { class: "live", text: "live" }) : null;
  const todayW = s.today.work_h + run;
  const weekW = s.week.worked_h + run;
  const weekLE = leftOrExtra(weekW, s.week.expected_h);
  const exp = s.today.expected_h || 0;
  const leftMin = Math.round((exp - todayW) * 60);
  let target;
  if (exp <= 0) target = "no hours expected today";
  else if (leftMin <= 0) target = `target met · ${leftOrExtra(todayW, exp).text} today`;
  else if (s.state === "working") {
    const done = new Date(serverNow().getTime() + leftMin * 60000); // the server's wall clock, not the device's
    target = `done at ${pad(done.getHours())}:${pad(done.getMinutes())}`;
  }
  else target = `${fmtHM(leftMin)} left`;
  const byType = Object.entries(s.today.by_type || {}).sort((a, b) => b[1] - a[1]).map(([k, v]) => `${k} ${fmtNum(v, 1)}`).join(" · ");
  const pct = exp > 0 ? Math.min(100, (todayW / exp) * 100) : (todayW > 0 ? 100 : 0);
  const today = el("div", { class: "card" },
    el("div", { class: "k" }, "Today", liveTag),
    el("div", { class: "v" }, fmtNum(todayW), exp > 0 ? el("small", { text: ` / ${fmtH(exp)}` }) : el("small", { text: " h" })),
    el("div", { class: "bar-track" }, el("div", { class: `bar-fill${todayW > exp ? " over" : ""}`, style: `width:${pct}%` })),
    el("div", { class: "s", text: target }),
    byType ? el("div", { class: "s ell", text: byType, title: byType }) : null);
  const week = el("div", { class: "card wide" },
    // the badge says what the figure is ("12.5 h left" / "+1.2 h extra"), never a bare signed number
    el("div", { class: "k" }, `Week ${s.week.key.slice(5)}`,
      weekLE.text ? el("span", { class: weekLE.cls, text: weekLE.text, title: WEEK_HELP }) : null),
    el("div", { class: "v" }, fmtNum(weekW), el("small", { text: ` / ${fmtH(s.week.expected_h)}` }), basisLink(s.week_basis_h)),
    weekStrip(s),
    el("div", { class: "s", text: `${s.week.days_worked} day${s.week.days_worked === 1 ? "" : "s"} worked · ${fmtH(s.week.billable_h)} billable` }));
  const since = s.net.since ? fmtSince(s.net.since) : "";
  const net = el("div", { class: "card net" },
    el("div", { class: "k" }, "Balance", helpDot(balanceHelp(since))),
    el("div", { class: `v ${signClass(s.net.with_current_h)}`, text: fmtSigned(s.net.with_current_h) }),
    el("div", { class: "s", text: since ? `extra hours since ${since}` : "extra hours, all weeks" }),
    el("div", { class: "s", text: `${fmtSigned(s.net.without_current_h)} before this week` }));
  tipHide(); // a help text of the tiles being replaced must not stay up
  $("totals").replaceChildren(today, week, net);
}

// The words for the signed hours figures (the Qt app's TimerPage uses the same texts).
const WEEK_HELP = "Worked hours against this whole week's expected hours";
const fmtSince = (iso) => new Date(`${iso}T12:00:00`).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric" });
function balanceHelp(since) {
  return `Hours worked minus hours expected, added up over every week${since ? ` since ${since}, your first logged day` : ""}. `
    + "Plus means you are ahead, minus that you are behind.\n\n"
    + "This week's full expected hours already count, so the figure is low on Monday and climbs as you work. "
    + "\"Before this week\" is where you stood at the end of last week.";
}

// the hours a full week counts as is set on the Settings page (one editable copy of it)
function basisLink(cur) {
  if (cur == null) return null;
  return el("a", { class: "basis-link", href: "/settings#week-basis", title: "Hours a full week counts as, for Balance and Reports", text: `full week ${fmtNum(cur, 1)} h · Settings` });
}

function weekStrip(s) {
  const days = s.week.days || [];
  const todayStr = todayIso();
  const run = liveRunH();
  const scale = Math.max(1, ...days.map((d) => Math.max(d.worked_h + (d.date === todayStr ? run : 0), d.expected_h)));
  return el("div", { class: "wk" }, ...days.map((d) => {
    const worked = d.worked_h + (d.date === todayStr ? run : 0);
    const over = d.expected_h > 0 && worked > d.expected_h;
    const title = `${d.weekday} ${d.date.slice(5)}: ${fmtH(worked)} of ${fmtH(d.expected_h)}`;
    return el("button", { type: "button", class: `wd-cell${d.date === todayStr ? " today" : ""}${d.date === timer.date ? " sel" : ""}`, title, "aria-label": title,
      onclick: () => gotoDate(d.date) },
      el("span", { class: "wd-bar" },
        d.expected_h > 0 ? el("i", { class: "wd-exp", style: `bottom:${(d.expected_h / scale) * 100}%` }) : null,
        el("i", { class: `wd-fill${over ? " over" : ""}`, style: `height:${(worked / scale) * 100}%` })),
      el("span", { class: "wd-lbl", text: d.weekday[0] }));
  }));
}

function renderChips(id, names, key) {
  const box = $(id);
  const limit = CHIP_LIMIT[key];
  let shown = names;
  if (!timer.expanded[key] && names.length > limit + 1) {
    shown = names.slice(0, limit);
    const sel = timer.pending[key];
    if (sel && names.includes(sel) && !shown.includes(sel)) shown = [...shown, sel];
  }
  const chips = shown.map((name) => {
    const on = timer.pending[key] === name;
    return el("button", {
      type: "button", class: `chip${on ? " on" : ""}`, text: name, "aria-pressed": on ? "true" : "false",
      onclick: () => {
        const state = timer.status ? timer.status.state : "stopped";
        // with a block running, the chip retypes that block (work chips while working, break chips while on a break)
        if (state === "working" && key === "type") { timer.pending.type = name; return retypeRunning({ type: name }); }
        if (state === "working" && key === "project") {
          timer.pending.project = on ? null : name;
          $("project").value = timer.pending.project || "";
          return retypeRunning({ project: timer.pending.project });
        }
        if (state === "break" && key === "breakType") { timer.pending.breakType = name; return retypeRunning({ type: name }); }
        // otherwise the chip picks what the next Start / Pause uses; tapping the highlighted chip again clears it
        timer.pending[key] = (on && key !== "breakType") ? null : name;
        if (key === "project") $("project").value = timer.pending.project || "";
        renderChipRows();
        renderButtons();
      },
    });
  });
  if (shown.length < names.length) {
    chips.push(el("button", { type: "button", class: "chip more", text: `+${names.length - shown.length}`,
      onclick: () => { timer.expanded[key] = true; renderChipRows(); } }));
  } else if (timer.expanded[key] && names.length > limit + 1) {
    chips.push(el("button", { type: "button", class: "chip more", text: "less",
      onclick: () => { timer.expanded[key] = false; renderChipRows(); } }));
  }
  box.replaceChildren(...chips);
}

function renderChipRows() {
  const c = timer.status.chips;
  renderChips("chips-types", c.types, "type");
  renderChips("chips-projects", c.projects, "project");
  renderChips("chips-breaks", c.break_types, "breakType");
}

function renderStatus() {
  renderState();
  renderButtons();
  renderTotals();
  renderChipRows();
  const review = timer.status.needs_review || [];
  const reviewNotice = review.length
    ? [`${review.length} auto-closed block(s) to review: ${[...new Set(review.map((r) => r.date))].join(", ")}`] : [];
  const overlaps = [...new Set([...(timer.status.overlaps || []), ...((timer.day && timer.day.overlaps) || [])])]
    .map((text) => ({ text: `⚠ ${text}`, cls: "warn", onclick: () => gotoDate(overlapDate(text)) }));
  timer.serverNotices = [...new Set([...(timer.status.notices || []), ...reviewNotice, ...((timer.day && timer.day.notices) || [])]), ...overlaps, timer.followup];
  renderNotices();
}

// "Overlap Tue 20 Oct: …" → ISO date, resolved against today's year (the status window is 14 days)
function overlapDate(text) {
  const m = /^Overlap \w+ (\d+) (\w+):/.exec(text);
  if (!m) return timer.date;
  const now = serverNow();
  const d = new Date(`${m[1]} ${m[2]} ${now.getFullYear()}`);
  if (d > now) d.setFullYear(now.getFullYear() - 1);
  return isoDate(d);
}

// "09:00–10:30 dev": names a row for assistive technology and the Undo message
const blockLabel = (b) => `${b.start}–${b.end || "…"} ${b.type}`;

// two blocks that touch and say the same thing: one block cut in two by a stop and a start
const mergeable = (a, b) => !!a && a.end === b.start && a.type === b.type && (a.project || "") === (b.project || "")
  && (a.client || "") === (b.client || "") && a.billable === b.billable;

// prev: the block in the row above when it touches this one, else null
function blockRow(b, prev) {
  const kind = b.work_type === "work" ? "wrk" : "brk";
  const tr = el("tr", { class: [kind, b.flags.start_gt_end || b.flags.overlap ? "flag" : "", b.auto_closed ? "auto" : "", b.end ? "" : "open"].join(" ").trim(),
    "data-id": String(b.id),
    title: b.flags.start_gt_end ? "Ends before it starts" : b.flags.overlap ? "Overlaps an earlier block · both count in full" : "" });
  // a cell is a click target and a keyboard one: focusable, Enter or F2 edits, Esc cancels the editor
  const editKey = (e) => {
    if (e.target !== e.currentTarget || e.altKey || e.ctrlKey || e.metaKey) return;
    if (e.key === "Enter" || e.key === "F2") { e.preventDefault(); editBlockCell(e.currentTarget, b); }
  };
  const edit = (e) => editBlockCell(e.currentTarget, b);
  const cell = (field, text, cls) => el("td", { "data-field": field, class: cls || "", text: text || "", tabindex: "0",
    "aria-label": `Edit ${field}: ${text || "empty"}`, onclick: edit, onkeydown: editKey });
  const typeCell = el("td", { "data-field": "type", class: "type", tabindex: "0", "aria-label": `Edit type: ${b.type}`, onclick: edit, onkeydown: editKey }, el("span", { text: b.type }));
  const bill = b.billable === true ? ["yes", wl.currency()] : b.billable === false ? ["no", "✗"] : ["na", "–"];
  const billName = b.billable === true ? "billable" : b.billable === false ? "not billable" : "billing not set";
  const dur = b.end ? b.duration : fmtHM(isRunningBlock(b) ? liveElapsedMin() : minutesSince(b.date, b.start));
  tr.append(
    cell("start", b.start), cell("end", b.end), typeCell,
    cell("project", b.project, "ell"), cell("client", b.client, b.client ? "" : "muted"),
    el("td", { class: `bill ${bill[0]}`, "data-field": "billable", text: bill[1], title: `${billName[0].toUpperCase()}${billName.slice(1)}. Click to change (${wl.currency()} billable, ✗ not billable, – not set)`, tabindex: "0", role: "button",
      "aria-label": `${blockLabel(b)}: ${billName}. Press Enter to change`, onclick: () => cycleBillable(b),
      onkeydown: (e) => { if (e.target === e.currentTarget && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); cycleBillable(b); } } }),
    el("td", b.end ? { class: "num dur", text: dur } : { class: "num dur", text: dur, "data-open": `${b.date} ${b.start} ${b.id}` }),
    el("td", { class: "num" },
      // closed by the server because it was left running: ✓ saves the end as it is, which clears the review notice
      b.auto_closed && b.end ? el("button", { type: "button", class: "ghost x", text: "✓", title: `Closed automatically at ${b.end}: confirm this end time (or edit it)`,
        "aria-label": `Confirm the automatic end time of ${blockLabel(b)}`, onclick: () => mutate(() => api("PUT", `/api/blocks/${b.id}`, { end: b.end })) }) : null,
      mergeable(prev, b) ? el("button", { type: "button", class: "ghost x", text: "⤒", title: "Same as the block above: merge the two into one",
        "aria-label": `Merge ${blockLabel(b)} with the block above`, onclick: (e) => wl.locked(e.currentTarget, () => mutate(() => api("POST", `/api/blocks/${prev.id}/merge-next`))) }) : null,
      b.work_type === "work" && b.end ? el("button", { type: "button", class: "ghost x", text: "▶", title: "Start the timer with this type and project",
        "aria-label": `Start the timer again as ${blockLabel(b)}`, onclick: () => startAgain(b) }) : null,
      el("button", { type: "button", class: "ghost x", text: "✂", title: "Split: cut a part out as another block (a break you forgot)",
        "aria-label": `Split ${blockLabel(b)}`, onclick: () => splitBlock(b) }),
      el("button", { type: "button", class: "ghost x", text: "×", "aria-label": `Delete ${blockLabel(b)}`, onclick: (e) => wl.locked(e.currentTarget, () => deleteBlock(b)) })));
  return tr;
}

// prev: the block the gap comes after (the one that ends last); next: the block it comes before
function gapRow(start, end, prev, next) {
  const [h1, m1] = start.split(":").map(Number);
  const [h2, m2] = end.split(":").map(Number);
  // no type unless one is picked: the server's default applies (work), or the first break type (break)
  const fill = (btns, type) => wl.locked(btns, () => mutate(() => api("POST", "/api/blocks", { date: timer.date, start, end, type })));
  const work = el("button", { type: "button", class: "small ghost fill", text: "+ work", "aria-label": `Fill ${start}–${end} as work` });
  const brk = el("button", { type: "button", class: "small ghost fill", text: "+ break", "aria-label": `Fill ${start}–${end} as a break` });
  work.addEventListener("click", () => fill([work, brk], timer.pending.type || undefined));
  brk.addEventListener("click", () => fill([work, brk], pauseType() || undefined));
  // or close it by moving one edge of a neighbour; a block still running gets require_open, as every edit of it
  const ext = el("button", { type: "button", class: "small ghost fill", text: `↓ to ${end}`, title: `Extend the previous block to ${end}`,
    "aria-label": `Extend ${blockLabel(prev)} to ${end}` });
  const pull = el("button", { type: "button", class: "small ghost fill", text: `↑ from ${start}`, title: `Start the next block at ${start}`,
    "aria-label": `Start ${blockLabel(next)} at ${start}` });
  const stretch = (b, fields) => wl.locked([ext, pull, work, brk], () => mutate(() => api("PUT", `/api/blocks/${b.id}`, fields)));
  ext.addEventListener("click", () => stretch(prev, { end }));
  pull.addEventListener("click", () => stretch(next, next.end ? { start } : { start, require_open: true }));
  return el("tr", { class: "gap" },
    el("td", { text: start, class: "muted" }), el("td", { text: end, class: "muted" }),
    el("td", { colspan: 4, class: "muted" }, `gap ${fmtHM((h2 * 60 + m2) - (h1 * 60 + m1))} · `, ext, pull, " · fill as ", work, brk),
    el("td", { colspan: 2 }));
}

async function cycleBillable(b) {
  const next = b.billable === true ? false : b.billable === false ? null : true;
  try {
    await api("PUT", `/api/blocks/${b.id}`, { billable: next });
    await refreshAll();
  } catch (err) { showError(err); }
}

function renderBlocks() {
  // [label, class, short label on a phone, tooltip]
  const heads = [["Start"], ["End"], ["Type"], ["Project"], ["Client", "", "", "The client this block is billed to"],
    ["Billable", "num", wl.currency(), `${wl.currency()} = billable, ✗ = not billable, – = not set. Click a cell to change it`],
    ["Duration", "num", "Dur"], [""]];
  const head = el("tr", {}, ...heads.map(([t, c, short, tip]) => (short
    ? el("th", { class: c || "", title: tip || t }, el("span", { class: "th-long", text: t }), el("span", { class: "th-short", text: short }))
    : el("th", { class: c || "", text: t, title: tip || null }))));
  const blocks = timer.day.blocks;
  const rows = [];
  const sorted = [...blocks].sort((a, b) => a.start.localeCompare(b.start));
  let covered = null; // latest end seen so far, so an overlapping block never fakes a gap
  let last = null; // the block that ends at `covered`
  let above = null; // the block in the row above
  for (const b of sorted) {
    if (covered && covered < b.start) rows.push(gapRow(covered, b.start, last, b));
    if (!b.end || !covered || b.end > covered) last = b;
    if (!b.end) covered = "24:00";
    else if (!covered || b.end > covered) covered = b.end;
    rows.push(blockRow(b, above));
    above = b;
  }
  if (!rows.length) rows.push(el("tr", {}, el("td", { colspan: 8, class: "muted", text: "No blocks on this day." })));
  $("blocks").replaceChildren(el("thead", {}, head), el("tbody", {}, rows));
  if (timer.refocus) { // a cell editor just closed with Enter or Esc: give the keyboard back to its cell
    const { id, field } = timer.refocus;
    timer.refocus = null;
    const td = $("blocks").querySelector(`tr[data-id="${id}"] td[data-field="${field}"]`);
    if (td) td.focus();
  }
  const work = blocks.filter((b) => b.work_type === "work" && b.minutes != null).reduce((a, b) => a + b.minutes, 0);
  const brk = blocks.filter((b) => b.work_type !== "work" && b.minutes != null).reduce((a, b) => a + b.minutes, 0);
  const open = blocks.some((b) => !b.end);
  $("dayfoot").replaceChildren(
    el("span", {}, "Worked ", el("b", { text: fmtHM(work) }), open ? " + running" : "", " · breaks ", el("b", { text: fmtHM(brk) })),
    el("span", { class: "muted", text: `${blocks.length} block${blocks.length === 1 ? "" : "s"}` }));
}

function renderProposals() {
  const ul = $("proposals");
  // every meeting of the day: one without a block can be added (the server cuts it out of what was
  // logged there) or dismissed; logged and dismissed ones stay listed, dimmed
  const props = timer.day.meetings || timer.day.proposals || [];
  $("proposals-sec").classList.toggle("has", props.length > 0);
  ul.replaceChildren(...props.map((p) => el("li", { class: p.logged ? "done" : p.dismissed ? "off" : "" },
    el("span", {}, el("span", { class: "t", text: `${p.start}–${p.end}` }), p.title || ""),
    p.logged ? el("span", { class: "mark", text: "✓ logged" }) : el("span", { class: "btns" },
      el("button", { type: "button", class: p.dismissed ? "small ghost" : "small", text: "Add as meeting",
        title: "Add as a meeting block; work logged at that time makes room for it", onclick: (e) => wl.locked(e.currentTarget, () => addProposal(p)) }),
      p.dismissed ? el("span", { class: "mark", text: "dismissed" })
        : el("button", { type: "button", class: "small ghost", text: "Dismiss", title: "Dismiss for today",
          onclick: (e) => wl.locked(e.currentTarget, () => dismissProposal(p)) })))));
}

function dismissProposal(p) {
  return mutate(() => api("POST", "/api/calendar/dismiss", { date: timer.date, start: p.start, title: p.title }));
}

// the highlighted chips always show what the running block is, not what was picked before it started;
// a calendar meeting is the exception: its project is the meeting title, so the pending type/project keep
// what ran before it and Resume / Switch afterwards continues that work
function syncPendingFromStatus() {
  const b = timer.status && timer.status.block;
  if (!b) return;
  if (b.work_type === "work") {
    if (b.source === "calendar") return;
    timer.pending.type = b.type;
    timer.pending.project = b.project || null;
    if (document.activeElement !== $("project")) $("project").value = b.project || "";
  } else {
    timer.pending.breakType = b.type;
  }
}

const statusSeq = wl.sequence(), daySeq = wl.sequence();

// The status the page shows: the real one, plus what the waiting offline actions (Start / Pause / Stop) would have done.
function parseAt(at) {
  const m = /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d)/.exec(at || "");
  return m ? new Date(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]) : serverNow();
}
function impliedStatus(real, items) {
  const s = JSON.parse(JSON.stringify(real));
  for (const it of items) {
    const kind = it.path.split("/").pop();
    if (kind === "stop") { Object.assign(s, { state: "stopped", block: null, elapsed_s: 0, elapsed_min: 0, since: null, past_stop_min: null }); continue; }
    const at = parseAt(it.body.at), start = `${pad(at.getHours())}:${pad(at.getMinutes())}`;
    const work = kind === "start";
    const type = it.body.type || (work ? "work" : ((s.chips && s.chips.break_types && s.chips.break_types[0]) || "break"));
    const elapsed = Math.max(0, Math.floor((serverNow() - at) / 1000));
    Object.assign(s, { state: work ? "working" : "break", since: start, elapsed_s: elapsed, elapsed_min: Math.floor(elapsed / 60), past_stop_min: null,
      block: { id: -1, date: isoDate(at), start, end: null, type, project: it.body.project || null, work_type: work ? "work" : "break", source: "queue" } });
  }
  return s;
}

// timer.status from timer.real and the queue; the totals dim while actions wait
function applyQueue() {
  if (!timer.real) return;
  const items = wl.queue.items();
  timer.status = items.length ? impliedStatus(timer.real, items) : timer.real;
  timer.fetchedAt = items.length ? Date.now() : timer.realAt;
  $("totals").classList.toggle("dim", items.length > 0);
  renderQueueStrip();
}

function renderQueueStrip() {
  const strip = $("queue-strip"), n = wl.queue.waiting();
  strip.hidden = n === 0;
  if (!n) { strip.replaceChildren(); return; }
  const stuck = wl.queue.stuck();
  strip.replaceChildren(
    el("span", { class: "q-text", text: `${n} action${n === 1 ? "" : "s"} waiting${stuck ? ` · ${stuck}` : ""}` }),
    el("button", { type: "button", class: "small ghost", text: "Retry now", onclick: (e) => wl.locked(e.currentTarget, () => wl.queue.flush()) }),
    el("button", { type: "button", class: "small ghost", text: "Discard", "aria-label": "Discard the waiting actions",
      onclick: () => { if (confirm(`Discard waiting actions? ${n === 1 ? "The action that has" : `The ${n} actions that have`} not been sent yet will be thrown away and never reach the server.`)) wl.queue.discard(); } }));
}

function onQueueChange(what) {
  applyQueue();
  if (timer.status) renderStatus();
  const refused = wl.queue.takeDropped().map((m) => new Error(`A waiting action was refused: ${m}`));
  if (what === "sent") refreshAll().then(() => refused.forEach(showError));
  else refused.forEach(showError);
}

const DAY_KEY = "worklog.day";

async function loadStatus() {
  const current = statusSeq();
  let status;
  try {
    status = await api("GET", "/api/status");
  } catch (err) {
    const c = err.status === 0 ? wl.cachedStatus() : null;
    if (!c) throw err; // unreachable and nothing kept: the error shows
    if (!current()) return;
    timer.real = c.status; timer.realAt = c.epoch; timer.offline = true;
    applyQueue(); syncPendingFromStatus(); renderStatus();
    return;
  }
  if (!current()) return; // a newer request is on its way (or has already been shown)
  timer.offline = false;
  wl.cacheStatus(status);
  wl.setCurrency(status.currency);
  timer.real = status;
  timer.realAt = Date.now();
  syncClock(status);
  applyQueue();
  syncPendingFromStatus();
  renderStatus();
}

async function loadDay() {
  const current = daySeq();
  let day;
  try {
    day = await api("GET", `/api/day/${timer.date}`);
    wl.store.set(DAY_KEY, JSON.stringify({ date: timer.date, day }));
  } catch (err) {
    let kept = null;
    try { kept = JSON.parse(wl.store.get(DAY_KEY, "null")); } catch (_) { /* unreadable */ }
    if (err.status !== 0 || !kept || kept.date !== timer.date) throw err;
    day = kept.day;
  }
  if (!current()) return;
  timer.day = day;
  if (timer.editing) { timer.dirty = true; renderProposals(); return; } // never rebuild the table under an open editor
  renderBlocks();
  renderProposals();
}

async function refreshAll() {
  try {
    await Promise.all([loadStatus(), loadDay()]);
    if (followToday()) await loadDay(); // the server's date moved on: show the new day
    if (timer.status) renderStatus();
  } catch (err) { showError(err); }
}

// After a failed action the page may be stale (409: the block already closed): show the truth, then the error.
async function failed(err) {
  await refreshAll();
  showError(err);
}

// ---- "when": the next Start, Pause or Stop counts from now, or from a time today set under the buttons ----

// "" when the typed time can be used, else why not. `since`: the running block's start when it began today.
function atProblem(typed, now, since) {
  const v = typed.trim();
  if (!v) return "";
  const t = normTime(v);
  if (!isHHMM(t)) return wl.TIME_MSG;
  if (t > now) return "Later than now";
  if (since && t < since) return `Before this block started (${since})`;
  return "";
}

// { open, problem, time }: time is "HH:MM" only when one is set and usable
function atState() {
  const open = !$("at-box").hidden;
  const typed = open ? $("at-time").value : "";
  const b = timer.status && timer.status.block;
  const problem = atProblem(typed, nowHHMM(), b && b.date === todayIso() ? b.start : "");
  return { open, problem, time: typed.trim() && !problem ? normTime(typed.trim()) : "" };
}

let atDay = ""; // the day the time was set on: a time left open over midnight is not used
let atIdle = null;
function showAt(on, value) {
  $("at-box").hidden = !on;
  $("at-open").hidden = on;
  $("at-time").value = on ? value || "" : "";
  atDay = on ? todayIso() : "";
  if (on) $("at-time").focus();
  touchAt();
}
// the time changed: the buttons say it; left untouched for half an hour it goes back to now
function touchAt() {
  clearTimeout(atIdle);
  if (!$("at-box").hidden) atIdle = setTimeout(() => showAt(false), 30 * 60000);
  renderButtons();
}

async function timerAction(path, body) {
  if (timer.busy) return;
  const at = atState();
  if (at.problem) { showError(new Error(at.problem)); return; }
  if (at.time && atDay !== todayIso()) { showAt(false); showError(new Error("The day changed: set the time again")); return; }
  if (at.time) body = { ...body, at: `${todayIso()}T${at.time}` }; // the action happened then, not now
  setBusy(true);
  try {
    const r = await wl.queue.act(path, body); // goes now, or waits in the offline queue
    showAt(false); // only after a good answer: a refused time stays to be corrected
    if (r.queued) { applyQueue(); if (timer.status) renderStatus(); return; }
    await refreshAll();
    if (at.time) {
      const did = { "/api/start": "Started", "/api/pause": "Paused", "/api/stop": "Stopped" }[path];
      timer.followup = { text: `${did} at ${at.time}`, cls: "offer" };
      renderStatus();
    }
  } catch (err) { await failed(err); } finally { setBusy(false); }
}

function startTimer() {
  const body = {};
  const project = $("project").value.trim();
  if (timer.pending.type) body.type = timer.pending.type;
  if (project) body.project = project;
  else if (!timer.pending.type) { // nothing picked: continue the last work block, like the watch and the widget
    const r = resumeInfo();
    if (r) { body.type = r.type; if (r.project) body.project = r.project; }
  }
  return timerAction("/api/start", body);
}

function pauseTimer() {
  const type = pauseType();
  return timerAction("/api/pause", type ? { type } : {});
}

function stopTimer() {
  return timerAction("/api/stop", {});
}

// change the running block in place (type / project); nothing running → nothing to do
function retypeRunning(fields) {
  if (!timer.status || !timer.status.block) return Promise.resolve();
  // require_open: the snapshot can be up to 60 s old; a block closed meanwhile gets a 409, never retyped
  return mutate(() => api("PUT", `/api/blocks/${timer.status.block.id}`, { ...fields, require_open: true }));
}

async function mutate(fn) {
  timer.followup = null;
  try {
    await fn();
    await refreshAll();
  } catch (err) { await failed(err); }
}

function editBlockCell(td, block) {
  if (td.querySelector("input")) return;
  const field = td.dataset.field;
  const original = block[field] || "";
  const isTime = field === "start" || field === "end";
  const input = el("input", { type: "text", value: original, autocomplete: "off", class: isTime ? "time" : "", "aria-label": `${field} of ${blockLabel(block)}` });
  if (isTime) {
    input.placeholder = "HH:MM";
    input.inputMode = "numeric";
    input.addEventListener("input", () => previewDur(td.closest("tr"), block, field, input.value));
  }
  timer.editing = { id: block.id, field };
  let done = false;
  // the editor is closed: show the table (and any day that arrived meanwhile)
  const finish = (refocus) => {
    done = true;
    timer.editing = null;
    timer.dirty = false;
    if (refocus) timer.refocus = { id: block.id, field };
    renderBlocks();
  };
  const commit = () => {
    if (done) return;
    let v = input.value.trim();
    if (isTime && v) v = normTime(v);
    // not a time: put the old value back and say so (the same message as every other time field)
    if (isTime && v && !isHHMM(v)) { done = true; timer.editing = null; timer.dirty = false; renderBlocks(); showMessages($("notices"), [...timer.serverNotices, `Error: ${wl.TIME_MSG}`], "error"); return; }
    // an auto-closed block stays "to review" until its end is saved again: Enter on the unchanged end confirms it
    const confirms = field === "end" && block.auto_closed && v !== "";
    if (v === original && !confirms) { finish(enterPressed); return; }
    done = true;
    timer.editing = null;
    timer.dirty = false;
    if (enterPressed) timer.refocus = { id: block.id, field };
    mutate(async () => {
      await api("PUT", `/api/blocks/${block.id}`, { [field]: v === "" && field === "end" ? null : v });
      if (!isTime) return;
      // moved into a neighbour: that one gives way at once (Undo puts it back); moved away from one: offer to follow
      const fix = overlapFix(block, field, v);
      if (!fix) { timer.followup = neighbourFollowup(block, field, original, v); return; }
      timer.followup = null;
      await api("PUT", `/api/blocks/${fix.block.id}`, fix.fields);
      showUndo(fix.text, () => mutate(() => api("PUT", `/api/blocks/${fix.block.id}`, fix.undo)));
    });
  };
  let enterPressed = false;
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); enterPressed = true; input.blur(); }
    else if (e.key === "Escape") { e.preventDefault(); finish(true); }
    else if (isTime && (e.key === "ArrowUp" || e.key === "ArrowDown")) { // 5 minutes later / earlier, 1 with Shift
      const t = nudgeTime(input.value, (e.shiftKey ? 1 : 5) * (e.key === "ArrowUp" ? 1 : -1));
      if (t) { e.preventDefault(); input.value = t; previewDur(td.closest("tr"), block, field, t); }
    }
  });
  input.addEventListener("blur", commit);
  td.replaceChildren(input);
  input.focus();
  input.select();
}

// "09:58" + 5 -> "10:03", kept inside the day; null when the text is not a time
function nudgeTime(text, minutes) {
  const v = normTime(String(text).trim());
  if (!isHHMM(v)) return null;
  const m = Math.min(1439, Math.max(0, toMin(v) + minutes));
  return `${pad(Math.floor(m / 60))}:${pad(m % 60)}`;
}

// while a start/end is being typed, the Dur cell shows what the row would become
function previewDur(tr, block, field, raw) {
  const td = tr && tr.querySelector("td.dur");
  if (!td) return;
  const v = normTime(raw);
  const start = field === "start" ? v : block.start, end = field === "end" ? v : block.end;
  td.classList.add("preview");
  if (!isHHMM(start) || !isHHMM(end)) { td.textContent = end || field === "end" ? "?" : td.textContent; return; }
  const min = toMin(end) - toMin(start);
  td.textContent = min < 0 ? `−${fmtHM(-min)}` : fmtHM(min);
  td.classList.toggle("neg", min < 0);
}

// A start moved into an earlier block, or an end moved into a later one: the edit that trims that block so the
// two do not overlap ({ block, fields, undo, text }), or null. A block swallowed whole is left alone (the
// overlap warning shows). A block still running gets require_open, as every edit of it.
function overlapFix(block, field, newV) {
  if (!isHHMM(newV)) return null;
  const others = timer.day.blocks.filter((b) => b.id !== block.id);
  if (field === "start") {
    const prev = others.filter((b) => b.end && b.start < block.start && b.start < newV && b.end > newV).sort((a, b) => b.end.localeCompare(a.end))[0];
    return prev ? { block: prev, fields: { end: newV }, undo: { end: prev.end }, text: `Previous block (${prev.type}) now ends at ${newV}, was ${prev.end}` } : null;
  }
  const next = others.filter((b) => b.start > block.start && b.start < newV && (!b.end || b.end > newV)).sort((a, b) => a.start.localeCompare(b.start))[0];
  if (!next) return null;
  const open = next.end ? {} : { require_open: true };
  return { block: next, fields: { start: newV, ...open }, undo: { start: next.start, ...open }, text: `Next block (${next.type}) now starts at ${newV}, was ${next.start}` };
}

// After moving an edge, offer to drag the neighbour's matching edge along (the timeline is contiguous).
function neighbourFollowup(block, field, oldV, newV) {
  if (!isHHMM(newV)) return null;
  const sorted = [...timer.day.blocks].sort((a, b) => a.start.localeCompare(b.start));
  const i = sorted.findIndex((b) => b.id === block.id);
  if (field === "end") {
    const next = sorted[i + 1];
    if (next && next.start === oldV && next.start !== newV) {
      return { text: `Next block (${next.type}) still starts at ${next.start} · tap to move it to ${newV}`, cls: "offer",
        onclick: () => mutate(() => api("PUT", `/api/blocks/${next.id}`, { start: newV })) };
    }
  } else {
    const prev = sorted[i - 1];
    if (prev && prev.end === oldV && prev.end !== newV) {
      return { text: `Previous block (${prev.type}) still ends at ${prev.end} · tap to move it to ${newV}`, cls: "offer",
        onclick: () => mutate(() => api("PUT", `/api/blocks/${prev.id}`, { end: newV })) };
    }
  }
  return null;
}

// Undo is offered only once the server has really deleted the row; a failed delete shows the error and no Undo.
async function deleteBlock(b) {
  const copy = { date: b.date || timer.date, start: b.start, end: b.end || null, type: b.type,
    project: b.project || null, client: b.client || null, billable: b.billable === undefined ? null : b.billable };
  timer.followup = null;
  try {
    await api("DELETE", `/api/blocks/${b.id}`);
  } catch (err) { await failed(err); return; }
  await refreshAll();
  showUndo(`Deleted ${blockLabel(b)}`, async () => {
    try {
      await api("POST", "/api/blocks", copy);
      await refreshAll();
    } catch (err) { await failed(err); } // 409 / overlap: the server's message
  });
}

// snackbar with an Undo button (aria-live status), auto-dismissed after 8 s
let undoTimer = null;
function showUndo(text, onUndo) {
  let bar = $("undo-bar");
  if (!bar) {
    bar = el("div", { id: "undo-bar", class: "undo-bar", role: "status", "aria-live": "polite" });
    document.body.append(bar);
  }
  clearTimeout(undoTimer);
  const hide = () => { clearTimeout(undoTimer); bar.hidden = true; bar.replaceChildren(); };
  const btn = el("button", { type: "button", class: "small", text: "Undo", onclick: () => { hide(); onUndo(); } });
  bar.replaceChildren(el("span", { text }), btn);
  bar.hidden = false;
  undoTimer = setTimeout(hide, 8000);
}

// a new row starts where the day's last block ended (or now) and is left open, like the Qt app;
// the server refuses it while another block is running, and showError reports that
function addRow() {
  const lastEnd = timer.day.blocks.map((b) => b.end).filter(Boolean).sort().pop();
  const start = lastEnd || nowHHMM();
  // type and client defaults are applied by the API
  return wl.locked($("add-row"), () => mutate(() => api("POST", "/api/blocks", { date: timer.date, start, end: null })));
}

// ▶ on a row: start the timer now with that block's type, project and client
function startAgain(b) {
  const body = { type: b.type };
  if (b.project) body.project = b.project;
  if (b.client) body.client = b.client;
  return timerAction("/api/start", body);
}

// ✂ on a row: cut a part out of the block as another block (the break you forgot). The server splits or trims
// whatever the new block reaches into (`cut`); the parts keep their type, project and client.
function splitBlock(b) {
  const chips = (timer.status && timer.status.chips) || {};
  const types = [...new Set([...(chips.break_types || []), ...(chips.types || []), b.type])];
  const time = (label, value) => el("input", { type: "text", class: "time", placeholder: "HH:MM", inputmode: "numeric", autocomplete: "off", "aria-label": label, value });
  const start = time("Start of the part to cut out", ""), end = time("End of the part to cut out", "");
  const type = el("select", { "aria-label": "Type of the new block" }, types.map((t) => el("option", { value: t, text: t })));
  const msg = el("p", { class: "error", role: "alert", hidden: true });
  const fail = (text) => { msg.textContent = text; msg.hidden = false; };
  const ok = el("button", { type: "submit", text: "Split" });
  const dlg = el("dialog", { class: "sheet narrow split" });
  const form = el("form", {
    onsubmit: (e) => {
      e.preventDefault();
      const s = normTime(start.value.trim()), en = normTime(end.value.trim());
      if (!isHHMM(s) || !isHHMM(en)) { fail(wl.TIME_MSG); return; }
      if (en <= s) { fail("End must be after start"); return; }
      if (s < b.start || en > (b.end || nowHHMM())) { fail(`Stay inside ${b.start}–${b.end || "now"}`); return; }
      wl.locked(ok, async () => {
        try {
          await api("POST", "/api/blocks", { date: b.date || timer.date, start: s, end: en, type: type.value, cut: true });
          dlg.close();
          timer.followup = null;
          await refreshAll();
        } catch (err) { fail(err.message); }
      });
    },
  },
  el("h3", { text: `Split ${blockLabel(b)}` }),
  el("p", { class: "muted", text: "Cut a part out as another block, for example a break you forgot. The rest keeps its type and project." }),
  el("p", {}, start, "–", end, "as", type), msg,
  el("p", {}, el("button", { type: "button", class: "ghost", text: "Cancel", onclick: () => dlg.close() }), ok));
  dlg.append(form);
  dlg.addEventListener("close", () => dlg.remove());
  document.body.append(dlg);
  dlg.showModal();
  start.focus();
}

function addProposal(p) {
  return mutate(() => api("POST", "/api/calendar/add", { date: timer.date, start: p.start, end: p.end, title: p.title }));
}

const gotoDate = (iso) => { location.href = iso === todayIso() ? "/timer" : `/timer?date=${iso}`; };

// Single-key shortcuts on the Timer page. They can be switched off on the Settings page (kept on this device only);
// they never fire while focus is in a field, a button, a link, a table cell editor or a dialog.
const SHORTCUTS_KEY = "worklog.shortcuts";
const shortcutsOn = () => wl.store.get(SHORTCUTS_KEY, "1") !== "0";
const typingTarget = (t) => !!(t && t.closest && t.closest("input, select, textarea, button, a[href], summary, dialog, td[data-field], [contenteditable]"));

function shortcut(e) {
  if (timer.busy) return;
  const k = e.key;
  if (k === "/") { e.preventDefault(); $("project").focus(); return; }
  const btn = { s: "btn-start", p: "btn-pause", x: "btn-stop" }[k.toLowerCase()];
  if (btn) { $(btn).click(); return; }
  if (/^[1-6]$/.test(k)) {
    const chip = document.querySelectorAll("#chips-types .chip:not(.more)")[Number(k) - 1];
    if (chip) chip.click();
  }
}

// ---- settings page: what used to sit under the Timer and on Reports ---------------------------------

const settingsSeq = wl.sequence();

async function loadSettings() {
  const current = settingsSeq();
  try {
    const st = await api("GET", "/api/settings");
    if (!current()) return;
    $("def-type").value = st.default_type;
    $("def-client").value = st.default_client || "";
    $("def-break").replaceChildren(...st.break_types.map((t) => el("option", { value: t, text: t })));
    $("def-break").value = st.default_break_type;
    $("def-close").value = st.auto_close_time;
    $("def-autoadd").checked = st.calendar_auto_add;
    $("rate").value = st.rate == null ? "" : fmtNum(st.rate, 2);
    $("rate-unit").value = st.rate_unit;
    wl.setCurrency(st.currency);
    $("currency").value = st.currency;
    renderCurrencyLabels();
    renderRateHint(st);
    renderBasis(st);
    $("settings-notices").replaceChildren();
    await Promise.all([loadClients(current), loadBreakTypes(current)]);
  } catch (err) { showMessages($("settings-notices"), [`Error: ${err.message}`], "error"); }
}

// the rate unit's labels carry the currency symbol
function renderCurrencyLabels() {
  const c = wl.currency();
  $("rate-unit").options[0].text = `${c}/h`;
  $("rate-unit").options[1].text = `${c}/day`;
}

async function saveCurrency() {
  const v = $("currency").value.trim();
  if (!v || v.length > 4) { showMessages($("settings-notices"), ["Error: the currency must be 1 to 4 characters"], "error"); return; }
  try {
    const st = await api("PUT", "/api/settings", { currency: v });
    wl.setCurrency(st.currency);
    $("currency").value = st.currency;
    renderCurrencyLabels();
    renderRateHint(st);
    $("settings-notices").replaceChildren();
  } catch (err) { showMessages($("settings-notices"), [`Error: ${err.message}`], "error"); await loadSettings(); }
}

// ---- clients and break types (Settings) ---------------------------------------------------------------

function listMsg(id, text) { showMessages($(id), text ? [`Error: ${text}`] : [], "error"); }

async function loadClients(current) {
  const rows = await api("GET", "/api/clients");
  if (current && !current()) return;
  $("clients-list").replaceChildren(...rows.map(clientRow));
  $("clients-empty").hidden = rows.length > 0;
}

function clientRow(c) {
  const path = `/api/clients/${encodeURIComponent(c.name)}`;
  const name = el("input", { type: "text", value: c.name, maxlength: "100", autocomplete: "off", class: "quiet", "aria-label": `Name of client ${c.name}` });
  const bill = el("input", { type: "checkbox", "aria-label": `${c.name} is billable` });
  bill.checked = c.billable;
  const save = (body, undo) => wl.locked([name, bill], async () => {
    try { await api("PUT", path, body); listMsg("clients-msg", ""); await loadClients(); }
    catch (err) { undo(); listMsg("clients-msg", err.message); }
  });
  name.addEventListener("change", () => {
    const v = name.value.trim();
    if (v === c.name) return;
    save({ name: v }, () => { name.value = c.name; });
  });
  bill.addEventListener("change", () => save({ billable: bill.checked }, () => { bill.checked = c.billable; }));
  const del = el("button", { type: "button", class: "ghost x", text: "×", title: "Delete this client", "aria-label": `Delete client ${c.name}`,
    onclick: (e) => wl.locked(e.currentTarget, async () => {
      try { await api("DELETE", path); listMsg("clients-msg", ""); await loadClients(); } catch (err) { listMsg("clients-msg", err.message); }
    }) });
  return el("li", { class: "cl-row" }, name, el("label", { class: "check" }, bill, " billable"), del);
}

async function addClient(e) {
  e.preventDefault();
  const name = $("client-new").value.trim();
  if (!name) { listMsg("clients-msg", "enter a name"); return; }
  await wl.locked($("client-add"), async () => {
    try {
      await api("POST", "/api/clients", { name, billable: $("client-new-bill").checked });
      $("client-new").value = ""; listMsg("clients-msg", ""); await loadClients();
    } catch (err) { listMsg("clients-msg", err.message); }
  });
}

async function loadBreakTypes(current) {
  const [names, st] = await Promise.all([api("GET", "/api/break-types"), api("GET", "/api/settings")]);
  if (current && !current()) return;
  const picked = $("def-break").value;
  $("def-break").replaceChildren(...names.map((t) => el("option", { value: t, text: t })));
  $("def-break").value = names.includes(picked) ? picked : st.default_break_type;
  $("breaks-list").replaceChildren(...names.map((n) => el("li", { class: "bt-row" },
    breakNameInput(n),
    n === st.default_break_type ? el("span", { class: "badge set", text: "default" })
      : el("button", { type: "button", class: "ghost x", text: "×", title: "Delete this break type", "aria-label": `Delete break type ${n}`,
        onclick: (e) => wl.locked(e.currentTarget, async () => {
          try { await api("DELETE", `/api/break-types/${encodeURIComponent(n)}`); listMsg("breaks-msg", ""); await loadBreakTypes(); }
          catch (err) { listMsg("breaks-msg", err.message); }
        }) }))));
}

// the name is an input: change it and leave the field to rename (the server keeps names in lower case)
function breakNameInput(n) {
  const input = el("input", { type: "text", value: n, maxlength: "40", autocomplete: "off", class: "quiet bt-name", "aria-label": `Name of break type ${n}` });
  input.addEventListener("change", () => {
    const v = input.value.trim();
    if (v === n) return;
    wl.locked(input, async () => {
      try { await api("PUT", `/api/break-types/${encodeURIComponent(n)}`, { name: v }); listMsg("breaks-msg", ""); await loadBreakTypes(); }
      catch (err) { input.value = n; listMsg("breaks-msg", err.message); }
    });
  });
  return input;
}

async function addBreakType(e) {
  e.preventDefault();
  const name = $("break-new").value.trim();
  if (!name) { listMsg("breaks-msg", "enter a name"); return; }
  await wl.locked($("break-add"), async () => {
    try { await api("POST", "/api/break-types", { name }); $("break-new").value = ""; listMsg("breaks-msg", ""); await loadBreakTypes(); }
    catch (err) { listMsg("breaks-msg", err.message); }
  });
}

async function saveDefaults() {
  const msg = $("def-msg");
  try {
    await api("PUT", "/api/settings", {
      default_type: $("def-type").value.trim(), default_client: $("def-client").value.trim() || null,
      default_break_type: $("def-break").value, auto_close_time: $("def-close").value,
      calendar_auto_add: $("def-autoadd").checked });
    msg.textContent = "Saved";
    setTimeout(() => { if (msg.textContent === "Saved") msg.textContent = ""; }, 4000);
  } catch (err) { msg.textContent = `Error: ${err.message}`; }
}

// what a full week is (35 h default = 7 h days); expected, extra, balance and charts follow it
function renderBasis(st) {
  const v = st.week_basis_h;
  for (const b of $("basis-seg").querySelectorAll("button")) b.classList.toggle("on", Number(b.dataset.v) === v);
  $("basis").value = fmtNum(v, 1);
  $("basis-hint").textContent = `= ${fmtH(st.default_expected_h)} per day · overrides kept`;
}

async function saveBasis(v) {
  if (!(v >= 1 && v <= 80)) { showMessages($("settings-notices"), ["Error: hours per week must be between 1 and 80"], "error"); return; }
  try {
    const st = await api("PUT", "/api/settings", { week_basis_h: v });
    renderBasis(st);
    renderRateHint(st);
    $("settings-notices").replaceChildren();
  } catch (err) { showMessages($("settings-notices"), [`Error: ${err.message}`], "error"); await loadSettings(); }
}

async function saveRate() {
  const raw = $("rate").value.trim();
  const rate = raw === "" ? null : wl.parseNum(raw);   // "7.5" and "7,5" alike
  if (rate != null && !(rate >= 0)) { showMessages($("settings-notices"), ["Error: the rate must be zero or more"], "error"); return; }
  try {
    const st = await api("PUT", "/api/settings", { rate, rate_unit: $("rate-unit").value });
    renderRateHint(st);
    $("settings-notices").replaceChildren();
  } catch (err) { showMessages($("settings-notices"), [`Error: ${err.message}`], "error"); await loadSettings(); }
}

function renderRateHint(st) {
  const h = $("rate-hint");
  if (st.rate_h == null) { h.textContent = "billable hours × rate"; return; }
  const perDay = st.rate_h * st.default_expected_h;
  h.textContent = st.rate_unit === "day"
    ? `= ${fmtNum(st.rate_h, 2)} ${wl.currency()}/h at ${fmtH(st.default_expected_h)} per day`
    : `= ${fmtEur(perDay)} per ${fmtH(st.default_expected_h)} day`;
}

function initSettings() {
  renderCurrencyLabels();
  $("currency").value = wl.currency();
  $("currency").addEventListener("change", saveCurrency);
  $("client-form").addEventListener("submit", addClient);
  $("break-form").addEventListener("submit", addBreakType);
  const on = $("pref-idle"), mins = $("pref-idle-min");
  on.checked = idleOn(); mins.value = idleMinutes(); mins.disabled = !on.checked;
  on.addEventListener("change", () => { wl.store.set(IDLE_ON_KEY, on.checked ? "1" : "0"); mins.disabled = !on.checked; });
  mins.addEventListener("change", () => {
    const n = Math.floor(Number(mins.value));
    if (n >= 1 && n <= 240) wl.store.set(IDLE_MIN_KEY, String(n)); else mins.value = idleMinutes();
  });
  $("def-save").addEventListener("click", saveDefaults);
  $("rate").addEventListener("change", saveRate);
  $("rate-unit").addEventListener("change", saveRate);
  for (const b of $("basis-seg").querySelectorAll("button")) b.addEventListener("click", () => saveBasis(Number(b.dataset.v)));
  $("basis").addEventListener("change", () => saveBasis(wl.parseNum($("basis").value)));
  const sc = $("pref-shortcuts");
  sc.checked = shortcutsOn();
  sc.addEventListener("change", () => wl.store.set(SHORTCUTS_KEY, sc.checked ? "1" : "0"));
  loadSettings();
}

// ---- idle prompt ----------------------------------------------------------------------------------
// Like the Qt app's IdleWatcher, but only while this page is open: when input (pointer, key, touch, scroll, the tab coming
// back) returns after at least N minutes without any, and a work block runs, ask once whether that time was a break.
// "Log as break" pauses at the moment the idling began (not before the block's start), then starts the same type and
// project now. A failed request keeps the question.
const IDLE_ON_KEY = "worklog.idle", IDLE_MIN_KEY = "worklog.idleMinutes";
const idleOn = () => wl.store.get(IDLE_ON_KEY, "1") !== "0";
const idleMinutes = () => { const n = Math.floor(Number(wl.store.get(IDLE_MIN_KEY, "60"))); return n >= 1 && n <= 240 ? n : 60; };
const idle = { last: Date.now(), asking: null, checking: false };

function fmtAway(min) {
  if (min < 60) return `${min} min`;
  const h = Math.floor(min / 60), m = min % 60;
  return m === 0 ? `${h} h` : `${h} h ${m} min`;
}

// the away span on the server's clock: from the last input before the idling to the first one after, not before the
// running block started and at most 23 h back (what /api/pause accepts)
function awaySpan(prevMs, nowMs, block) {
  let start = wl.serverAt(prevMs);
  const end = wl.serverAt(nowMs);
  const floor = new Date(end.getTime() - 23 * 3600 * 1000);
  if (start < floor) start = floor;
  if (block && block.date && /^\d\d:\d\d/.test(block.start || "")) {
    const [y, mo, d] = block.date.split("-").map(Number), [h, m] = block.start.split(":").map(Number);
    const bs = new Date(y, mo - 1, d, h, m);
    if (start < bs) start = bs;
  }
  return { start, end, minutes: Math.max(0, Math.round((end - start) / 60000)) };
}

function renderIdle() {
  const box = $("idle-card"), q = idle.asking;
  box.hidden = !q;
  if (!q) { box.replaceChildren(); return; }
  const hm = (d) => `${pad(d.getHours())}:${pad(d.getMinutes())}`;
  box.replaceChildren(...[
    el("p", { class: "idle-q", text: `You were away ${fmtAway(q.minutes)} (${hm(q.start)}\u2013${hm(q.end)}). Log it as a break?` }),
    q.error ? el("p", { class: "error", text: `Could not log it: ${q.error}. Try again.` }) : null,
    el("div", { class: "row" },
      el("button", { type: "button", id: "idle-log", class: "small primary", text: "Log as break", disabled: q.sending, onclick: idleLog }),
      el("button", { type: "button", id: "idle-keep", class: "small ghost", text: "Keep as work", disabled: q.sending, onclick: () => { idle.asking = null; renderIdle(); } }))].filter(Boolean));
}

async function idleLog() {
  const q = idle.asking;
  if (!q || q.sending) return;
  q.sending = true; q.error = "";
  renderIdle();
  try {
    if (!q.pausedDone) {
      const type = pauseType();
      await api("POST", "/api/pause", { ...(type ? { type } : {}), at: wl.atString(q.start), request_id: q.pauseId });
      q.pausedDone = true;
    }
    await api("POST", "/api/start", { type: q.type, ...(q.project ? { project: q.project } : {}), request_id: q.startId });
    idle.asking = null;
  } catch (err) { q.error = err.message; }
  if (idle.asking) q.sending = false;
  renderIdle();
  await refreshAll();
}

async function idleInput() {
  const now = Date.now(), prev = idle.last;
  idle.last = now;
  if (idle.asking || idle.checking || !idleOn() || now - prev < idleMinutes() * 60000) return;
  idle.checking = true;
  try {
    // the snapshot can be old after a long absence: ask the server before deciding
    await loadStatus().catch(() => {});
    const s = timer.status;
    if (!s || s.state !== "working" || !s.block || idle.asking) return;
    const span = awaySpan(prev, now, s.block);
    if (span.minutes < 1) return;
    idle.asking = { ...span, type: s.block.type, project: s.block.project, pauseId: wl.newId(), startId: wl.newId(), pausedDone: false };
    renderIdle();
  } finally { idle.checking = false; }
}

function initIdle() {
  for (const ev of ["pointerdown", "pointermove", "keydown", "touchstart", "wheel", "scroll"]) {
    window.addEventListener(ev, () => { idleInput(); }, { passive: true, capture: true });
  }
  document.addEventListener("visibilitychange", () => { if (!document.hidden) idleInput(); });
}

async function initTimer() {
  await wl.ensureClock();
  timer.date = timerDate();
  timer.followsToday = !new URLSearchParams(location.search).get("date") || timer.date === todayIso();
  timer.today = todayIso();
  renderDayHead();
  $("kbd-hint").hidden = !shortcutsOn();
  $("day").addEventListener("change", (e) => { if (e.target.value) gotoDate(e.target.value); });
  $("day-prev").addEventListener("click", () => gotoDate(shiftDate(timer.date, -1)));
  $("day-next").addEventListener("click", () => gotoDate(shiftDate(timer.date, 1)));
  $("day-today").addEventListener("click", () => gotoDate(todayIso()));
  $("btn-start").addEventListener("click", startTimer);
  $("btn-pause").addEventListener("click", pauseTimer);
  $("btn-stop").addEventListener("click", stopTimer);
  $("add-row").addEventListener("click", addRow);
  $("at-open").addEventListener("click", () => showAt(true));
  $("at-close").addEventListener("click", () => showAt(false));
  for (const ev of ["input", "focus", "blur"]) $("at-time").addEventListener(ev, touchAt);
  $("at-last").addEventListener("click", (e) => showAt(true, e.currentTarget.dataset.at));
  $("project").addEventListener("input", () => {
    timer.pending.project = null;
    if (timer.status) { renderChips("chips-projects", timer.status.chips.projects, "project"); renderButtons(); }
  });
  // a note typed while working applies to the running block, like a chip; otherwise it waits for Start
  $("project").addEventListener("change", () => {
    if (timer.status && timer.status.state === "working") retypeRunning({ project: $("project").value.trim() || null });
  });
  document.addEventListener("keydown", (e) => {
    if (!shortcutsOn() || typingTarget(e.target) || e.altKey || e.ctrlKey || e.metaKey) return;
    if (e.key === "ArrowLeft") gotoDate(shiftDate(timer.date, -1));
    else if (e.key === "ArrowRight") gotoDate(shiftDate(timer.date, 1));
    else shortcut(e);
  });
  wl.queue.listeners.add(onQueueChange);
  wl.net.listeners.add((ok) => { if (ok && timer.offline) refreshAll(); });
  window.addEventListener("online", refreshAll);
  renderQueueStrip();
  initIdle();
  refreshAll();
  setInterval(() => loadStatus().catch(showError), 60000);
  setInterval(() => { if (timer.status && timer.status.state !== "stopped") renderHeroClocks(); }, 1000);
  timer.tick = setInterval(() => {
    if (!timer.status) return;
    if (todayIso() !== timer.today) { refreshAll(); return; } // midnight on the server
    renderClock();
    if (timer.status.state === "working" && !$("totals").contains(document.activeElement)) renderTotals();
    document.title = document.title.replace(/^\d+:\d\d/, fmtHM(liveElapsedMin()));
  }, 15000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) refreshAll(); });
}


// ---- charts (inline SVG, no library) -----------------------------------------

const SVG_NS = "http://www.w3.org/2000/svg";
function svg(tag, attrs = {}, ...kids) {
  const e = document.createElementNS(SVG_NS, tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "text") e.textContent = v;
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else if (v != null) e.setAttribute(k, v);
  }
  for (const kid of kids.flat()) if (kid != null) e.append(kid);
  return e;
}

let tipEl = null;
function tipShow(e, text) {
  if (!tipEl) { tipEl = el("div", { class: "tip" }); document.body.append(tipEl); }
  tipEl.textContent = text;
  tipEl.classList.add("on");
  const pt = e.touches ? e.touches[0] : e;
  const w = tipEl.offsetWidth, x = Math.min(pt.clientX + 12, window.innerWidth - w - 8);
  tipEl.style.left = `${Math.max(8, x)}px`;
  tipEl.style.top = `${Math.max(8, pt.clientY - tipEl.offsetHeight - 12)}px`;
}
function tipHide() { if (tipEl) tipEl.classList.remove("on"); }
function hover(node, text) {
  node.addEventListener("mousemove", (e) => tipShow(e, typeof text === "function" ? text() : text));
  node.addEventListener("mouseleave", tipHide);
  node.addEventListener("touchstart", (e) => tipShow(e, typeof text === "function" ? text() : text), { passive: true });
  node.addEventListener("touchend", tipHide);
  return node;
}
// A small "?" next to a figure or heading: hover, focus or a tap shows what it means.
function helpDot(text) {
  const b = el("button", { type: "button", class: "help", text: "?", "aria-label": text });
  const show = () => { const r = b.getBoundingClientRect(); tipShow({ clientX: r.left, clientY: r.top }, text); };
  b.addEventListener("mouseenter", show);
  b.addEventListener("focus", show);
  b.addEventListener("mouseleave", tipHide);
  b.addEventListener("blur", tipHide);
  b.addEventListener("click", (e) => {
    e.stopPropagation();
    show();
    setTimeout(() => document.addEventListener("click", tipHide, { once: true })); // a tap anywhere else closes it
  });
  return b;
}

const niceStep = (range, ticks = 4) => {
  const raw = range / ticks, p = 10 ** Math.floor(Math.log10(raw || 1));
  return [1, 2, 2.5, 5, 10].map((m) => m * p).find((st) => st >= raw) || p * 10;
};
// axis labels, the same as the Qt app: week "2026-43", month "Oct", quarter "2026 Q4", year "2026"
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const periodLabel = (key, group) => (group === "week" ? key : group === "month" ? MONTHS[Number(key.slice(5)) - 1] : key.replace("-Q", " Q"));
const periodLong = (key, group) => (group === "week" ? `Week ${key.slice(5)} · ${key.slice(0, 4)}` : group === "month" ? new Date(`${key}-01T12:00:00`).toLocaleDateString("en", { month: "long", year: "numeric" }) : key.replace("-Q", " Q"));

function chartCard(title, sub, cls) {
  const card = el("div", { class: `chart ${cls || ""}`.trim() }, el("h3", { text: title }, sub ? el("small", { text: sub }) : null));
  return card;
}

// Frame: returns scales and axis group for a column chart with n slots. Y spans [lo, hi].
function frame(W, H, n, lo, hi, opts = {}) {
  const m = { t: 10, r: 8, b: 22, l: 34, ...(opts.margin || {}) };
  const iw = W - m.l - m.r, ih = H - m.t - m.b;
  const step = niceStep(hi - lo);
  lo = Math.floor(lo / step) * step; hi = Math.ceil(hi / step) * step;
  if (hi === lo) hi = lo + step;
  const y = (v) => m.t + ih - ((v - lo) / (hi - lo)) * ih;
  const slot = iw / Math.max(n, 1);
  const x = (i) => m.l + i * slot;
  const g = svg("g", { class: "axis" });
  for (let v = lo; v <= hi + 1e-9; v += step) {
    g.append(svg("line", { x1: m.l, x2: W - m.r, y1: y(v), y2: y(v), class: v === 0 ? "zero" : "grid-line" }));
    g.append(svg("text", { x: m.l - 6, y: y(v) + 4, "text-anchor": "end", text: opts.fmtY ? opts.fmtY(v) : fmtNum(v, 0) }));
  }
  return { m, iw, ih, y, x, slot, g, lo, hi };
}

function xLabels(f, keys, group, H) {
  const g = svg("g", { class: "axis" });
  const every = Math.ceil(keys.length / Math.max(2, Math.floor(f.iw / (group === "week" ? 56 : 44))));
  keys.forEach((k, i) => {
    const last = i === keys.length - 1;
    if (!last && (i % every || keys.length - 1 - i < every)) return;
    g.append(svg("text", { x: f.x(i) + f.slot / 2, y: H - 6, "text-anchor": "middle", text: periodLabel(k, group) }));
  });
  return g;
}

// 1. Extra hours per period: diverging bars around zero
function chartExtra(rows, group, cur) {
  const card = chartCard("Extra hours", `worked minus expected, per ${group}`);
  if (!rows.length) { card.append(el("div", { class: "empty", text: "No data" })); return card; }
  const W = 400, H = 170;
  const vals = rows.map((r) => r.extra_h);
  const f = frame(W, H, rows.length, Math.min(0, ...vals), Math.max(0, ...vals), { fmtY: (v) => fmtSigned(v).replace(" h", "") });
  const bw = Math.min(24, Math.max(2, f.slot - 2));
  const root = svg("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": "Extra hours per period" }, f.g);
  rows.forEach((r, i) => {
    const v = r.extra_h, y0 = f.y(0), y1 = f.y(v);
    const rect = svg("rect", { x: f.x(i) + (f.slot - bw) / 2, y: Math.min(y0, y1), width: bw, height: Math.max(1, Math.abs(y1 - y0)),
      rx: 2, class: `mark ${v >= 0 ? "pos" : "neg"}`, opacity: r.key === cur ? .55 : 1 });
    const hit = svg("rect", { x: f.x(i), y: f.m.t, width: f.slot, height: f.ih, class: "hit" });
    root.append(svg("g", { class: "band" }, hit, rect));
    hover(hit, `${periodLong(r.key, group)}${r.key === cur ? " (in progress)" : ""}\n${fmtH(r.worked_h)} worked · ${fmtH(r.expected_h)} expected\n${shortOrExtra(v)}`);
  });
  root.append(xLabels(f, rows.map((r) => r.key), group, H));
  card.append(root);
  return card;
}

// 2. Running balance: cumulative extra hours as a line with a wash
function chartBalance(rows, group, cur) {
  let acc = 0;
  const pts = rows.map((r) => ({ key: r.key, v: (acc += r.extra_h), extra: r.extra_h }));
  const card = chartCard("Balance", `extra hours added up over the range shown${pts.length ? ` · now ${fmtSigned(pts[pts.length - 1].v)}` : ""}`);
  if (!rows.length) { card.append(el("div", { class: "empty", text: "No data" })); return card; }
  const W = 400, H = 170;
  const vals = pts.map((p) => p.v);
  const f = frame(W, H, rows.length, Math.min(0, ...vals), Math.max(0, ...vals), { fmtY: (v) => fmtSigned(v).replace(" h", "") });
  const px = (i) => f.x(i) + f.slot / 2;
  const d = pts.map((p, i) => `${i ? "L" : "M"}${px(i).toFixed(1)},${f.y(p.v).toFixed(1)}`).join("");
  const root = svg("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": "Running balance" }, f.g);
  root.append(svg("path", { class: "wash", d: `${d}L${px(pts.length - 1).toFixed(1)},${f.y(0)}L${px(0).toFixed(1)},${f.y(0)}Z` }));
  root.append(svg("path", { class: "line", d }));
  const last = pts[pts.length - 1];
  root.append(svg("circle", { class: "dot", cx: px(pts.length - 1), cy: f.y(last.v), r: 4 }));
  pts.forEach((p, i) => {
    const hit = svg("rect", { x: f.x(i), y: f.m.t, width: f.slot, height: f.ih, class: "hit" });
    root.append(hit);
    hover(hit, `${periodLong(p.key, group)}${p.key === cur ? " (in progress)" : ""}\nbalance so far ${fmtSigned(p.v)}\nthis ${group} ${fmtSigned(p.extra)}`);
  });
  root.append(xLabels(f, rows.map((r) => r.key), group, H));
  card.append(root);
  return card;
}

// 3. Hours by type: stacked columns, top types in fixed slots, rest folded into Other
const TYPE_SLOTS = 6;
const wideW = () => (window.innerWidth < 640 ? 400 : 800);
const chartTypes = (rows, group, cur) => chartStack(rows, group, cur, "by_type", "Hours by type", "work only; breaks excluded");
const NO_PROJECT = "(no project)";
const PROJ_SLOTS = 10;
// Project notes are free text (hundreds of distinct values), so this is a ranked list for the
// selected range rather than a stack per period: identity by label, magnitude by length, one hue.
function chartProjects(rows) {
  const tot = {};
  for (const r of rows) for (const [t, h] of Object.entries(r.by_project || {})) { const k = t || NO_PROJECT; tot[k] = (tot[k] || 0) + h; }
  const ranked = Object.entries(tot).sort((a, b) => b[1] - a[1]);
  const all = ranked.reduce((a, [, h]) => a + h, 0);
  const named = ranked.filter(([k]) => k !== NO_PROJECT).length;
  const card = chartCard("Hours by project", `top ${Math.min(PROJ_SLOTS, ranked.length)} of ${named} project note${named === 1 ? "" : "s"} in the selected range · work only`, "wide");
  if (!ranked.length) { card.append(el("div", { class: "empty", text: "No data" })); return card; }
  const top = ranked.slice(0, PROJ_SLOTS), rest = ranked.slice(PROJ_SLOTS);
  const OTHER = `other (${rest.length} notes)`;
  const items = rest.length ? [...top, [OTHER, rest.reduce((a, [, h]) => a + h, 0)]] : top;
  const W = wideW(), rowH = 22, L = W > 400 ? 220 : 150, R = 92, T = 4, H = T + items.length * rowH + 4;
  const max = Math.max(...items.map(([, h]) => h));
  const maxLen = W > 400 ? 34 : 22;
  const root = svg("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": "Hours by project, ranked" });
  items.forEach(([name, h], i) => {
    const y = T + i * rowH, bw = Math.max(2, ((W - L - R) * h) / max);
    const pct = all ? Math.round((h / all) * 100) : 0;
    const g = svg("g", { class: "band" });
    const hit = svg("rect", { x: 0, y, width: W, height: rowH, class: "hit" });
    g.append(hit,
      svg("text", { x: L - 8, y: y + rowH / 2 + 4, "text-anchor": "end", class: "lbl", text: name.length > maxLen ? `${name.slice(0, maxLen - 1)}…` : name }),
      svg("rect", { x: L, y: y + 4, width: bw, height: rowH - 8, rx: 3, class: "mark",
        fill: name === OTHER ? "var(--s-other)" : "var(--accent)", opacity: name === NO_PROJECT ? .45 : 1 }),
      svg("text", { x: L + bw + 6, y: y + rowH / 2 + 4, class: "val", text: `${fmtNum(h, 1)} h · ${pct}%` }));
    hover(hit, `${name}\n${fmtH(h)} · ${pct}% of work in range`);
    root.append(g);
  });
  card.append(root);
  return card;
}
function chartStack(rows, group, cur, key, title, sub) {
  const card = chartCard(title, sub, "wide");
  if (!rows.length) { card.append(el("div", { class: "empty", text: "No data" })); return card; }
  const tot = {};
  const seriesOf = (r) => Object.fromEntries(Object.entries(r[key] || {}).map(([t, h]) => [t || NO_PROJECT, h]));
  for (const r of rows) for (const [t, h] of Object.entries(seriesOf(r))) tot[t] = (tot[t] || 0) + h;
  const ranked = Object.entries(tot).sort((a, b) => b[1] - a[1]).map(([t]) => t);
  const top = ranked.slice(0, TYPE_SLOTS), other = ranked.slice(TYPE_SLOTS);
  const series = other.length ? [...top, "other"] : top;
  const color = (t) => (t === "other" ? "var(--s-other)" : `var(--s${top.indexOf(t) + 1})`);
  const W = wideW(), H = W > 400 ? 190 : 170;
  const f = frame(W, H, rows.length, 0, Math.max(...rows.map((r) => r.worked_h), 1), { margin: { l: 30 } });
  const bw = Math.min(24, Math.max(2, f.slot - 2));
  const root = svg("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": `${title} per period` }, f.g);
  rows.forEach((r, i) => {
    const by = seriesOf(r);
    const parts = series.map((t) => [t, t === "other" ? other.reduce((a, o) => a + (by[o] || 0), 0) : (by[t] || 0)]).filter(([, h]) => h > 0);
    let base = 0;
    const g = svg("g", { class: "band" });
    const hit = svg("rect", { x: f.x(i), y: f.m.t, width: f.slot, height: f.ih, class: "hit" });
    g.append(hit);
    parts.forEach(([t, h]) => {
      const y1 = f.y(base + h), y0 = f.y(base);
      g.append(svg("rect", { x: f.x(i) + (f.slot - bw) / 2, y: y1, width: bw, height: Math.max(0, y0 - y1 - 1), fill: color(t), class: "mark", opacity: r.key === cur ? .55 : 1 }));
      base += h;
    });
    root.append(g);
    hover(hit, `${periodLong(r.key, group)} · ${fmtH(r.worked_h)}\n${parts.map(([t, h]) => `${t} ${fmtH(h)}`).join("\n")}`);
  });
  root.append(xLabels(f, rows.map((r) => r.key), group, H));
  card.append(root);
  card.append(el("div", { class: "legend" }, ...series.map((t) => el("span", { text: `${t} · ${fmtH(t === "other" ? other.reduce((a, o) => a + tot[o], 0) : tot[t])}`, style: `--sw:${color(t)}` }))));
  return card;
}

// 4. When I work: weekday × hour heatmap, one hue
const WD = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
function chartHeat(hm) {
  const card = chartCard("When I work", `hours per weekday and hour · ${hm.days} day${hm.days === 1 ? "" : "s"}`, "wide");
  const cells = hm.cells;
  const max = Math.max(0, ...cells.flat());
  if (!max) { card.append(el("div", { class: "empty", text: "No data" })); return card; }
  const hours = [...Array(24).keys()];
  const first = Math.max(0, hours.find((h) => cells.some((r) => r[h] > 0)) - 1);
  const lastH = Math.min(23, hours.findLast((h) => cells.some((r) => r[h] > 0)) + 1);
  const cols = lastH - first + 1;
  const W = wideW(), L = 34, T = 16, cw = (W - L - 4) / cols, ch = W > 400 ? 18 : 16, H = T + 7 * ch + 4;
  const root = svg("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": "Work hours by weekday and hour" });
  const ax = svg("g", { class: "axis" });
  for (let h = first; h <= lastH; h += cols > 14 ? 2 : 1) ax.append(svg("text", { x: L + (h - first) * cw + cw / 2, y: T - 5, "text-anchor": "middle", text: `${h}` }));
  WD.forEach((d, i) => ax.append(svg("text", { x: L - 6, y: T + i * ch + ch / 2 + 4, "text-anchor": "end", text: d })));
  root.append(ax);
  cells.forEach((row, wd) => {
    for (let h = first; h <= lastH; h++) {
      const v = row[h], a = v ? 0.12 + 0.88 * (v / max) : 0;
      const rect = svg("rect", { x: L + (h - first) * cw, y: T + wd * ch, width: cw, height: ch, rx: 3, class: "cell",
        fill: "var(--accent)", "fill-opacity": a.toFixed(3) });
      if (!v) rect.setAttribute("fill", "var(--line2)"), rect.setAttribute("fill-opacity", "1");
      root.append(hover(rect, `${WD[wd]} ${pad(h)}:00–${pad(h + 1)}:00\n${fmtH(v)} over ${hm.days} days${hm.days ? ` · ${fmtNum((v / hm.days) * 60, 0)} min/day avg` : ""}`));
    }
  });
  card.append(root);
  return card;
}

const chartState = { rows: null, group: null, hm: null, w: 0 };
// `current` is the guard of the summary load that asked: an answer from an older load is dropped
async function renderCharts(rows, group, current) {
  const q = selectionQuery();
  let hm = null;
  try {
    hm = await api("GET", `/api/heatmap?${q}`);
    reportNotice("heatmap", null);
  } catch (err) { reportNotice("heatmap", `Heatmap: ${err.message}`); }
  if (!current()) return;
  Object.assign(chartState, { rows, group, hm });
  drawCharts();
}
// the period that is still running, for the "in progress" mark: this week / month / quarter / year of the server's date
function currentKey(group) {
  const t = todayIso();
  if (group === "week") return isoWeek(t);
  if (group === "month") return t.slice(0, 7);
  if (group === "quarter") return `${t.slice(0, 4)}-Q${Math.floor((Number(t.slice(5, 7)) - 1) / 3) + 1}`;
  return t.slice(0, 4);
}
function drawCharts() {
  const { rows, group, hm } = chartState;
  if (!rows) return;
  chartState.w = wideW();
  const cur = currentKey(group);
  $("charts").replaceChildren(chartExtra(rows, group, cur), chartBalance(rows, group, cur), chartTypes(rows, group, cur),
    chartProjects(rows), hm ? chartHeat(hm) : null);
}
window.addEventListener("resize", () => { if (chartState.rows && wideW() !== chartState.w) drawCharts(); });

// ---- reports page ------------------------------------------------------------

const fmtEur = (v) => (v == null ? "" : `${Math.round(v).toLocaleString("en-GB").replace(/,/g, " ")} ${wl.currency()}`);

// Load and save errors of the Reports page show in a notice area at the top (the Import section is collapsed).
// One message per source, cleared when that source succeeds again.
const reportMsgs = new Map();
function reportNotice(source, message) {
  if (message) reportMsgs.set(source, message); else reportMsgs.delete(source);
  showMessages($("reports-notices"), [...new Set(reportMsgs.values())].map((m) => (m.startsWith("Heatmap") ? m : `Error: ${m}`)), "error");
}

let reportAlt = 40; // the alternative week basis shown next to the base columns
const reportCols = () => [
  ["key", "Period", (r) => r.key],
  ["worked", "Worked", (r) => fmtH(r.worked_h)],
  ["expected", "Expected", (r) => fmtH(r.expected_h)],
  ["extra", "Extra", (r) => r.extra_h, "signed", "Worked minus expected"],
  ["extra40", `Extra ${fmtNum(reportAlt, 0)}h`, (r) => r.extra_alt_h, "signed", `Worked minus expected if a full week were ${fmtNum(reportAlt, 0)} h`],
  ["days", "Days", (r) => String(r.days_worked), "", "Days with work logged"],
  ["equiv", "Days eq.", (r) => fmtNum(r.days_equiv, 1), "", "Worked hours counted as full working days"],
  ["billable", "Billable", (r) => fmtH(r.billable_h), "", "Hours for billable clients"],
  ["amount", wl.currency(), (r) => fmtEur(r.amount), "eur"],
];

function table(cols, rows, rowClass) {
  // every cell carries col-<key> so the stylesheet can hide a column on phones
  const head = el("tr", {}, ...cols.map(([key, label, , , tip], i) => el("th", { class: `${i ? "num" : ""} col-${key}`.trim(), text: label, title: tip || null })));
  const body = rows.map((r) => el("tr", { class: rowClass ? rowClass(r) : "" },
    ...cols.map(([key, , f, kind], i) => (kind === "signed" ? signedCell(f(r), `col-${key}`) : el("td", { class: `${i ? "num" : ""} ${kind || ""} col-${key}`.trim(), text: f(r) })))));
  return [el("thead", {}, head), el("tbody", {}, body)];
}

function statsTable(a, b) {
  const alt = fmtNum(reportAlt, 0);
  const items = [
    ["Total, all weeks", "net_h", "Extra hours of every week in the range, added up"],
    ["Total, last 4 weeks", "last4_h", "Extra hours of the last four weeks, added up"],
    [`Total at ${alt} h/week`, "net_alt_h", `The total if a full week were ${alt} h`],
    [`Last 4 at ${alt} h/week`, "last4_alt_h", `The last four weeks if a full week were ${alt} h`],
    ["Lowest week", "min_h", "The week with the fewest extra hours"],
    ["Lower quartile", "q1_h", "A quarter of the weeks had fewer extra hours than this"],
    ["Median week", "median_h", "Half of the weeks were below this, half above"],
    ["Upper quartile", "q3_h", "A quarter of the weeks had more extra hours than this"],
    ["Highest week", "max_h", "The week with the most extra hours"],
  ];
  const head = el("tr", {}, el("th", { text: "Extra hours per week" }), el("th", { text: "Incl. this week" }), el("th", { text: "Excl. this week" }));
  const body = items.map(([label, k, tip]) => el("tr", { title: tip }, el("td", { text: label }), signedCell(a[k]), signedCell(b[k])));
  return el("table", { class: "grid" }, el("thead", {}, head), el("tbody", {}, body));
}

function selectionQuery() {
  const q = new URLSearchParams();
  if ($("start").value) q.set("start", $("start").value);
  if ($("end").value) q.set("end", $("end").value);
  return q;
}

function updateExportLinks() {
  const q = selectionQuery().toString();
  $("export-csv").href = `/api/export.csv${q ? "?" + q : ""}`;
  $("export-xlsx").href = `/api/export.xlsx${q ? "?" + q : ""}`;
}

const summarySeq = wl.sequence(), invoiceSeq = wl.sequence();

async function loadSummary() {
  updateExportLinks();
  const current = summarySeq();
  const q = selectionQuery();
  const group = $("group").value;
  q.set("group", group);
  try {
    const data = await api("GET", `/api/summary?${q}`);
    if (!current()) return;
    reportNotice("summary", null);
    const rows = data.rows; // oldest first, like the Excel pivot
    const cur = currentKey(group);
    if (data.alt_week_h) reportAlt = data.alt_week_h;
    const cols = data.rate_h == null ? reportCols().filter(([k]) => k !== "amount") : reportCols();
    $("summary").className = "grid sticky";
    $("summary").replaceChildren(...table(cols, rows, (r) => (r.key === cur ? "cur" : "")));
    $("summary-legend").textContent = `Extra = worked minus expected · Extra ${fmtNum(reportAlt, 0)}h = the same if a full week were ${fmtNum(reportAlt, 0)} h · Days eq. = worked hours as full working days`;
    if (data.rate_h != null && rows.length) {
      const total = rows.reduce((a, r) => a + (r.amount || 0), 0);
      const bill = rows.reduce((a, r) => a + r.billable_h, 0);
      $("summary").append(el("tfoot", {}, el("tr", {}, el("td", { colspan: cols.length - 2, text: "Total" }),
        el("td", { class: "num", text: fmtH(bill) }), el("td", { class: "num", text: fmtEur(total) }))));
    }
    $("stats").replaceChildren();
    if (data.stats) {
      $("stats").append(el("div", { class: "scroll" }, statsTable(data.stats.with_current, data.stats.without_current)),
        el("p", { class: "hint", text: "Extra = worked minus expected, per week, over the range above. This week's full expected hours already count, so \"Excl. this week\" is the fairer figure until the week is over." }));
    }
    await renderCharts(rows, group, current);
  } catch (err) { if (current()) reportNotice("summary", err.message); }
}

const invoiceCols = [
  ["date", "Date", (r) => r.date],
  ["worked", "Worked", (r) => (r.worked_h > 0 ? fmtH(r.worked_h) : "")],
  ["expected", "Expected", (r) => (r.expected_h > 0 ? fmtH(r.expected_h) : "")],
  ["reason", "Reason", (r) => r.reason || ""],
  ["ok", "✓", (r) => (r.worked ? "✓" : "")],
];

async function loadInvoice() {
  const month = $("invoice").value;
  const current = invoiceSeq();
  if (!month) { $("invoice-table").replaceChildren(); return; }
  try {
    const rows = await api("GET", `/api/invoice?month=${month}`);
    if (!current()) return;
    reportNotice("invoice", null);
    const priced = rows.some((r) => r.amount != null);
    const cols = priced ? [...invoiceCols, ["amount", wl.currency(), null]] : invoiceCols;
    const head = el("tr", {}, ...cols.map(([k, label]) => el("th", { class: k === "date" || k === "reason" ? "" : "num", text: label })));
    const body = rows.map((r) => el("tr", { class: isWeekend(r.date) ? "wknd" : "" },
      el("td", {}, el("span", { class: "wd", text: r.weekday }), r.date.slice(8)),
      el("td", { class: "num", text: r.worked_h > 0 ? fmtH(r.worked_h) : "" }),
      el("td", { class: "num muted", text: r.expected_h > 0 ? fmtH(r.expected_h) : "" }),
      el("td", { class: "muted ell", text: r.reason || "" }),
      el("td", { class: `num ${r.worked ? "pos" : ""}`, text: r.worked ? "✓" : "" }),
      priced ? el("td", { class: "num", text: r.billable_h > 0 ? fmtEur(r.amount) : "" }) : null));
    const sum = (k) => rows.reduce((a, r) => a + (r[k] || 0), 0);
    const days = rows.filter((r) => r.worked).length;
    const foot = el("tr", {}, el("td", {}, el("b", { text: `${days} day${days === 1 ? "" : "s"} worked` }), ` · ${rows.length - days} off`),
      el("td", { class: "num" }, el("b", { text: fmtH(sum("worked_h")) })),
      el("td", { class: "num", text: fmtH(sum("expected_h")) }),
      el("td", { class: `num ${signClass(sum("worked_h") - sum("expected_h"))}`, title: "Worked minus expected this month", text: shortOrExtra(sum("worked_h") - sum("expected_h")) }), el("td", { class: "num muted", text: priced ? `${fmtH(sum("billable_h"))} bill.` : "" }),
      priced ? el("td", { class: "num" }, el("b", { text: fmtEur(sum("amount")) })) : null);
    $("invoice-table").replaceChildren(el("thead", {}, head), el("tbody", {}, body), el("tfoot", {}, foot));
  } catch (err) { if (current()) reportNotice("invoice", err.message); }
}

function importForm(dry) {
  const fd = new FormData($("import-form"));
  fd.set("dry_run", dry ? "1" : "0");
  if (!fd.has("workdays")) fd.set("workdays", "0");
  return fd;
}

const plural = (n, word) => `${n} ${word}${n === 1 ? "" : "s"}`;
const runningText = (r) => `${r.type}, started ${r.date} ${r.start}`;

async function importDryRun(e) {
  e.preventDefault();
  const out = $("import-result");
  const submit = $("import-form").querySelector('button[type="submit"]');
  await wl.locked(submit, async () => {
    try {
      const r = await api("POST", "/api/import", importForm(true));
      const mode = new FormData($("import-form")).get("mode");
      const lines = [`Check done: ${plural(r.would_insert, "block")} to add, ${r.would_update} to update, ${r.skipped} skipped.`];
      if (mode === "replace") {
        lines.push(`Replace will delete ${plural(r.would_delete, "existing block")} within the date range of the file.`);
        if (r.would_delete_running) {
          lines.push({ text: `Warning: this would delete the block that is running right now (${runningText(r.would_delete_running)}). The timer stops with it.`, cls: "warn" });
        }
      }
      (r.errors || []).forEach((m) => lines.push(`Problem: ${m}`));
      showMessages(out, lines);
      const label = mode === "replace" ? (r.would_delete_running ? "Confirm replace and delete the running block" : "Confirm replace") : "Confirm import";
      out.append(el("button", { type: "button", class: `small${mode === "replace" ? " danger" : " primary"}`, text: label, onclick: importConfirm }));
    } catch (err) { showMessages(out, [`Error: ${err.message}`], "error"); }
  });
}

async function importConfirm(e) {
  const btn = e.currentTarget;
  btn.disabled = true;
  const lines = [];
  let cls = "ok";
  try {
    const r = await api("POST", "/api/import", importForm(false));
    lines.push(`Imported: ${plural(r.inserted, "block")} added, ${r.updated} updated, ${r.deleted} deleted, ${r.skipped} skipped.`);
    if (r.workdays_rows != null) lines.push(`Workday rows stored: ${r.workdays_rows}.`);
    if (r.deleted_running) { lines.push({ text: `The block that was running (${runningText(r.deleted_running)}) was deleted.`, cls: "warn" }); }
    (r.errors || []).forEach((m) => lines.push({ text: `Problem: ${m}`, cls: "warn" }));
    showMessages($("import-result"), lines, cls);
    loadSummary();
    loadInvoice();
  } catch (err) {
    showMessages($("import-result"), [`Error: ${err.message}`], "error");
  }
}

function initReports() {
  const now = serverNow();
  $("invoice").value = `${now.getFullYear()}-${pad(now.getMonth() + 1)}`;
  for (const id of ["group", "start", "end"]) $(id).addEventListener("change", loadSummary);
  for (const b of $("group-seg").querySelectorAll("button")) {
    b.addEventListener("click", () => {
      $("group").value = b.dataset.v;
      for (const o of $("group-seg").querySelectorAll("button")) {
        o.classList.toggle("on", o === b);
        o.setAttribute("aria-pressed", o === b ? "true" : "false");
      }
      loadSummary();
    });
  }
  $("invoice").addEventListener("change", loadInvoice);
  $("import-form").addEventListener("submit", importDryRun);
  $("import-form").addEventListener("change", () => $("import-result").replaceChildren());
  loadSummary();
  loadInvoice();
}

// ---- days page ---------------------------------------------------------------

const KEEP_SOURCES = ["default", "holiday", "before-first"];
// [class, text, tooltip]
const SOURCE_BADGE = { holiday: ["holiday", "holiday", "Public holiday: nothing expected"], manual: ["set", "edited", "Changed by you"],
  import: ["set", "imported", "Set by an import"], "before-first": ["pre", "before first log", "Before your first logged day: nothing expected"] };
const daysSeq = wl.sequence();
const dayRefs = new Map(); // date -> the row's elements and its last saved values, for in-place updates
const weekCells = new Map(); // week key -> the separator cell with the week's expected total

// "Tue 20": the weekday and the day of the month (the week separator and the date filter give the rest)
const dayName = (iso) => `${weekdayShort(iso)} ${Number(iso.slice(8))}`;

function updateWeekTotals() {
  for (const [wk, cell] of weekCells) {
    let total = 0;
    for (const [date, r] of dayRefs) if (isoWeek(date) === wk) total += Number(r.data.expected_h);
    cell.textContent = `Week ${wk.slice(5)} · ${fmtH(total)} expected`;
  }
}

// show the saved state of one row: marker, badge, reset button, values; nothing else on the page is touched
function paintDayRow(refs) {
  const d = refs.data;
  const stored = !KEEP_SOURCES.includes(d.source);
  const badge = SOURCE_BADGE[d.source];
  refs.tr.className = [isWeekend(d.date) ? "wknd" : "", stored ? "set" : ""].join(" ").trim();
  refs.label.replaceChildren(el("span", { class: "wd", text: weekdayShort(d.date) }), String(Number(d.date.slice(8))),
    ...(badge ? [el("span", { class: `badge ${badge[0]}`, text: badge[1], title: badge[2] })] : []));
  refs.reset.replaceChildren(stored ? el("button", {
    type: "button", class: "ghost x", text: "↺", title: "Back to default", "aria-label": `Reset ${dayName(d.date)} to default`,
    onclick: () => resetDay(refs),
  }) : "");
}

function setDayError(refs, input, message) {
  refs.err.textContent = message || "";
  for (const i of [refs.exp, refs.sick, refs.reason]) i.removeAttribute("aria-invalid");
  if (message && input) input.setAttribute("aria-invalid", "true");
}

// the number a field holds, or null when it is not a valid 0-24 hours
function hoursValue(raw, emptyIsZero) {
  const t = String(raw).trim();
  if (t === "") return emptyIsZero ? 0 : null;
  const n = wl.parseNum(t);   // "7.5" and "7,5" alike
  return Number.isFinite(n) && n >= 0 && n <= 24 ? n : null;
}

function saveDay(refs, field, input) {
  // one save at a time per row, in order; each one starts from the last saved values of the other fields
  refs.chain = refs.chain.then(async () => {
    const was = refs.data;
    let value;
    if (field === "reason") {
      value = input.value;
    } else {
      value = hoursValue(input.value, field === "sick_h");
      if (value == null) {
        input.value = was[field];
        setDayError(refs, input, `${field === "sick_h" ? "Sick hours" : "Expected hours"} must be a number from 0 to 24.`);
        return;
      }
    }
    if (String(value) === String(was[field]) && field !== "reason") { input.value = was[field]; setDayError(refs, null, ""); return; }
    if (field === "reason" && value === (was.reason || "")) return;
    const body = { expected_h: was.expected_h, sick_h: was.sick_h || 0, reason: was.reason || "", [field]: value };
    try {
      refs.data = await api("PUT", `/api/days/${was.date}`, body);
      setDayError(refs, null, "");
      input.value = refs.data[field] ?? "";
      paintDayRow(refs);
      updateWeekTotals();
    } catch (err) {
      input.value = was[field] ?? ""; // the rejected value goes back
      setDayError(refs, input, err.message);
    }
  });
  return refs.chain;
}

async function resetDay(refs) {
  const date = refs.data.date;
  refs.chain = refs.chain.then(async () => {
    try {
      await api("DELETE", `/api/days/${date}`);
      const rows = await api("GET", `/api/days?${new URLSearchParams({ start: date, end: date })}`);
      if (rows[0]) {
        refs.data = rows[0];
        refs.exp.value = refs.data.expected_h; refs.sick.value = refs.data.sick_h; refs.reason.value = refs.data.reason || "";
        paintDayRow(refs);
        updateWeekTotals();
      }
      setDayError(refs, null, "");
    } catch (err) { setDayError(refs, null, err.message); }
  });
  return refs.chain;
}

function dayRow(d) {
  const num = (field) => el("input", { type: "text", value: d[field], class: "quiet num", "aria-label": `${field === "sick_h" ? "Sick hours" : "Expected hours"} ${dayName(d.date)}`, inputmode: "decimal" });
  const refs = {
    data: d, chain: Promise.resolve(),
    exp: num("expected_h"), sick: num("sick_h"),
    reason: el("input", { type: "text", value: d.reason || "", class: "quiet", "aria-label": `Reason ${dayName(d.date)}` }),
    err: el("small", { class: "rowerr", role: "alert" }),
    label: el("td", {}), reset: el("td", { class: "num" }), tr: el("tr", {}),
  };
  refs.exp.addEventListener("change", () => saveDay(refs, "expected_h", refs.exp));
  refs.sick.addEventListener("change", () => saveDay(refs, "sick_h", refs.sick));
  refs.reason.addEventListener("change", () => saveDay(refs, "reason", refs.reason));
  refs.tr.append(refs.label, el("td", { class: "num" }, refs.exp), el("td", { class: "num" }, refs.sick),
    el("td", {}, refs.reason, refs.err), refs.reset);
  paintDayRow(refs);
  dayRefs.set(d.date, refs);
  return refs.tr;
}

async function loadDays() {
  const current = daysSeq();
  const q = new URLSearchParams({ start: $("days-start").value, end: $("days-end").value });
  try {
    const rows = await api("GET", `/api/days?${q}`);
    if (!current()) return;
    const head = el("tr", {}, ...[["Day"], ["Expected (h)", "num"], ["Sick (h)", "num"], ["Reason"], ["", "num"]].map(([t, c]) => el("th", { class: c || "", text: t })));
    const body = [];
    let week = null;
    dayRefs.clear();
    weekCells.clear();
    for (const d of rows) {
      const wk = isoWeek(d.date);
      if (wk !== week) {
        week = wk;
        const cell = el("td", { colspan: 5 });
        weekCells.set(wk, cell);
        body.push(el("tr", { class: "sep" }, cell));
      }
      body.push(dayRow(d));
    }
    updateWeekTotals();
    $("days").replaceChildren(el("thead", {}, head), el("tbody", {}, body));
    $("days-msg").replaceChildren();
  } catch (err) { if (current()) showMessages($("days-msg"), [`Error: ${err.message}`], "error"); }
}

function initDays() {
  const now = serverNow();
  $("days-start").value = isoDate(new Date(now.getFullYear(), now.getMonth(), 1));
  $("days-end").value = isoDate(new Date(now.getFullYear(), now.getMonth() + 2, 0));
  $("days-start").addEventListener("change", loadDays);
  $("days-end").addEventListener("change", loadDays);
  loadDays();
}

// ---- boot --------------------------------------------------------------------

// Top nav: the tabs can overflow a phone, so the nav scrolls; keep the active tab in view and show a fade while there is more.
function initNav() {
  const nav = document.querySelector(".top nav");
  if (!nav) return;
  const more = () => nav.classList.toggle("more", nav.scrollWidth - nav.clientWidth - nav.scrollLeft > 4);
  const on = nav.querySelector("a.on");
  if (on && nav.scrollWidth > nav.clientWidth) {
    const nr = nav.getBoundingClientRect(), ar = on.getBoundingClientRect();
    nav.scrollLeft += ar.left - nr.left - (nav.clientWidth - ar.width) / 2;
  }
  nav.addEventListener("scroll", more, { passive: true });
  window.addEventListener("resize", more);
  more();
}

// The More menu (Add or find a date, Move an event, Work calendar, Settings): a button that opens a list of links.
// Enter / Space / click / ArrowDown open it, arrows move, Home / End jump, Esc closes and returns to the button.
function initMore() {
  const btn = $("more-btn"), list = $("more-list");
  if (!btn || !list) return;
  const items = () => [...list.querySelectorAll("a")];
  const close = (refocus) => {
    list.hidden = true;
    btn.setAttribute("aria-expanded", "false");
    if (refocus) btn.focus();
  };
  const open = (focusFirst) => {
    list.hidden = false;
    btn.setAttribute("aria-expanded", "true");
    if (focusFirst) items()[0].focus();
  };
  btn.addEventListener("click", () => (list.hidden ? open(false) : close(false)));
  btn.addEventListener("keydown", (e) => { if (e.key === "ArrowDown") { e.preventDefault(); open(true); } });
  list.addEventListener("keydown", (e) => {
    const all = items(), i = all.indexOf(document.activeElement);
    const go = (n) => { e.preventDefault(); all[(n + all.length) % all.length].focus(); };
    if (e.key === "Escape") { e.preventDefault(); close(true); }
    else if (e.key === "ArrowDown") go(i + 1);
    else if (e.key === "ArrowUp") go(i - 1);
    else if (e.key === "Home") go(0);
    else if (e.key === "End") go(all.length - 1);
  });
  list.addEventListener("focusout", (e) => {
    if (!list.hidden && e.relatedTarget && !list.contains(e.relatedTarget) && e.relatedTarget !== btn) close(false);
  });
  document.addEventListener("click", (e) => { if (!list.hidden && !e.target.closest(".more-menu")) close(false); });
}

document.addEventListener("DOMContentLoaded", async () => {
  const page = document.body.dataset.page;
  initNav();
  initMore();
  if (page === "timer") initTimer();
  else if (page === "settings") initSettings();
  else if (page === "reports") { await Promise.all([wl.ensureClock(), wl.loadCurrency()]); initReports(); }
  else if (page === "days") { await wl.ensureClock(); initDays(); }
});
