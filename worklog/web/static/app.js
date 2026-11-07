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

async function api(method, url, body) {
  const opts = { method, headers: {} };
  if (body instanceof FormData) {
    opts.body = body;
  } else if (body !== undefined) {
    opts.headers["content-type"] = "application/json";
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(url, opts);
  let data = null;
  try { data = await res.json(); } catch (_) { /* non-JSON body */ }
  if (!res.ok) throw new Error((data && data.error) || `HTTP ${res.status}`);
  return data;
}

const pad = (n) => String(n).padStart(2, "0");
const isoDate = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const nowHHMM = () => { const d = new Date(); return `${pad(d.getHours())}:${pad(d.getMinutes())}`; };
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
// 9:50 / 9.50 / 950 → 09:50 (same leniency as the API); anything else is returned trimmed
const normTime = (v) => { const m = /^(\d{1,2})[:.hH]?(\d{2})$/.exec(v.trim()); return m && +m[1] < 24 && +m[2] < 60 ? `${pad(+m[1])}:${m[2]}` : v.trim(); };
const isHHMM = (v) => /^([01]\d|2[0-3]):[0-5]\d$/.test(v || "");
const fmtH1 = (h) => `${fmtNum(h, 1)} h`;
const shiftDate = (iso, days) => { const d = new Date(`${iso}T12:00:00`); d.setDate(d.getDate() + days); return isoDate(d); };
const weekdayShort = (iso) => new Date(`${iso}T12:00:00`).toLocaleDateString("en", { weekday: "short" });
function fmtDayTitle(iso) {
  const d = new Date(`${iso}T12:00:00`);
  const t = `${d.toLocaleDateString("en", { weekday: "short" })} ${d.getDate()} ${d.toLocaleDateString("en", { month: "short" })}`;
  return d.getFullYear() === new Date().getFullYear() ? t : `${t} ${d.getFullYear()}`;
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

function signedCell(h, extra) {
  return el("td", { class: `num ${signClass(h)} ${extra || ""}`.trim(), text: fmtSigned(h) });
}

// ---- timer page --------------------------------------------------------------

const CHIP_LIMIT = { type: 6, project: 4, breakType: 6 };

const timer = {
  date: null,
  status: null,
  day: null,
  pending: { type: null, project: null, breakType: "eat" },
  expanded: { type: false, project: false, breakType: false },
  busy: false,
  serverNotices: [],
  followup: null, // one-tap offer after a time edit (move the neighbouring block's edge too)
  fetchedAt: 0, // Date.now() when `status` arrived; the clock ticks on from status.elapsed_min
  tick: null,
};

function timerDate() {
  const q = new URLSearchParams(location.search).get("date");
  return q || isoDate(new Date());
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
// minutes since a local date + HH:MM, built field by field (never via an ISO string, which Safari parses as UTC)
function minutesSince(iso, hhmm) {
  const [y, mo, d] = iso.split("-").map(Number), [h, m] = hhmm.split(":").map(Number);
  return Math.max(0, Math.floor((Date.now() - new Date(y, mo - 1, d, h, m)) / 60000));
}
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

function renderButtons() {
  const s = timer.status;
  if (!s) return;
  const type = timer.pending.type || "dev";
  const start = $("btn-start");
  const pause = $("btn-pause");
  const stop = $("btn-stop");
  start.replaceChildren(s.state === "working" ? "Switch" : s.state === "break" ? "Resume" : "Start", el("small", { text: type }));
  pause.replaceChildren(s.state === "break" ? "Change" : "Pause", el("small", { text: timer.pending.breakType || "eat" }));
  stop.replaceChildren("Stop", el("small", { text: s.state === "stopped" ? "—" : "close block" }));
  stop.disabled = timer.busy || s.state === "stopped";
}

function renderTotals() {
  const s = timer.status;
  const run = liveRunH();
  const live = s.state === "working";
  const liveTag = live ? el("span", { class: "live", text: "live" }) : null;
  const todayW = s.today.work_h + run;
  const weekW = s.week.worked_h + run;
  const weekX = weekW - s.week.expected_h;
  const weekLE = leftOrExtra(weekW, s.week.expected_h);
  const exp = s.today.expected_h || 0;
  const leftMin = Math.round((exp - todayW) * 60);
  let target;
  if (exp <= 0) target = "no hours expected today";
  else if (leftMin <= 0) target = `target met · ${fmtSigned(todayW - exp)}`;
  else if (s.state === "working") target = `done at ${new Date(Date.now() + leftMin * 60000).toTimeString().slice(0, 5)}`;
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
    el("div", { class: "k" }, `Week ${s.week.key.slice(5)}`, el("span", { class: signClass(weekX), text: fmtSigned(weekX) })),
    el("div", { class: "v" }, fmtNum(weekW), el("small", { text: ` / ${fmtH(s.week.expected_h)}` }), basisSelect(s.week_basis_h)),
    weekStrip(s),
    el("div", { class: "s" }, `${s.week.days_worked} day${s.week.days_worked === 1 ? "" : "s"} worked · ${fmtH(s.week.billable_h)} billable`,
      weekLE.text ? el("span", { class: weekLE.cls, text: ` · ${weekLE.text}` }) : null));
  const net = el("div", { class: "card net" },
    el("div", { class: "k", text: "Balance" }),
    el("div", { class: `v ${signClass(s.net.with_current_h)}`, text: fmtSigned(s.net.with_current_h) }),
    el("div", { class: "s", text: `${fmtSigned(s.net.without_current_h)} excl. this week` }));
  $("totals").replaceChildren(today, week, net);
}

// week basis picker on the Week card (same setting as Reports › Week); "custom…" prompts for a number
const BASIS_CHOICES = [30, 32.5, 35, 37.5, 40];
function basisSelect(cur) {
  if (cur == null) return null;
  const choices = BASIS_CHOICES.includes(cur) ? BASIS_CHOICES : [...BASIS_CHOICES, cur].sort((a, b) => a - b);
  const sel = el("select", { class: "basis-sel", "aria-label": "Hours per week", title: "Hours a full week counts as" },
    ...choices.map((v) => el("option", { value: String(v), text: `${fmtNum(v, 1)} h/wk` })),
    el("option", { value: "custom", text: "custom…" }));
  sel.value = String(cur);
  sel.addEventListener("change", async () => {
    let v = sel.value === "custom" ? Number(prompt("Hours per full week (1–80):", String(cur))) : Number(sel.value);
    if (!(v >= 1 && v <= 80)) { sel.value = String(cur); return; }
    try { await api("PUT", "/api/settings", { week_basis_h: v }); await refreshAll(); } catch (err) { showError(err); }
  });
  return sel;
}

function weekStrip(s) {
  const days = s.week.days || [];
  const todayIso = isoDate(new Date());
  const run = liveRunH();
  const scale = Math.max(1, ...days.map((d) => Math.max(d.worked_h + (d.date === todayIso ? run : 0), d.expected_h)));
  return el("div", { class: "wk" }, ...days.map((d) => {
    const worked = d.worked_h + (d.date === todayIso ? run : 0);
    const over = d.expected_h > 0 && worked > d.expected_h;
    const title = `${d.weekday} ${d.date.slice(5)}: ${fmtH(worked)} of ${fmtH(d.expected_h)}`;
    return el("button", { type: "button", class: `wd-cell${d.date === todayIso ? " today" : ""}${d.date === timer.date ? " sel" : ""}`, title, "aria-label": title,
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
  const now = new Date();
  const d = new Date(`${m[1]} ${m[2]} ${now.getFullYear()}`);
  if (d > now) d.setFullYear(now.getFullYear() - 1);
  return isoDate(d);
}

function blockRow(b) {
  const kind = b.work_type === "work" ? "wrk" : "brk";
  const tr = el("tr", { class: [kind, b.flags.start_gt_end || b.flags.overlap ? "flag" : "", b.auto_closed ? "auto" : "", b.end ? "" : "open"].join(" ").trim(),
    title: b.flags.start_gt_end ? "Ends before it starts" : b.flags.overlap ? "Overlaps an earlier block · both count in full" : "" });
  const cell = (field, text, cls) => el("td", { "data-field": field, class: cls || "", text: text || "", onclick: (e) => editBlockCell(e.currentTarget, b) });
  const typeCell = el("td", { "data-field": "type", class: "type", onclick: (e) => editBlockCell(e.currentTarget, b) }, el("span", { text: b.type }));
  const bill = b.billable === true ? ["yes", "€"] : b.billable === false ? ["no", "✗"] : ["na", "–"];
  const dur = b.end ? b.duration : fmtHM(isRunningBlock(b) ? liveElapsedMin() : minutesSince(b.date, b.start));
  tr.append(
    cell("start", b.start), cell("end", b.end), typeCell,
    cell("project", b.project, "ell"), cell("client", b.client, b.client ? "" : "muted"),
    el("td", { class: `bill ${bill[0]}`, "data-field": "billable", text: bill[1], title: "Billable: tap to cycle", onclick: () => cycleBillable(b) }),
    el("td", b.end ? { class: "num dur", text: dur } : { class: "num dur", text: dur, "data-open": `${b.date} ${b.start} ${b.id}` }),
    el("td", { class: "num" }, el("button", { type: "button", class: "ghost x", text: "×", "aria-label": "Delete row", onclick: () => deleteBlock(b) })));
  return tr;
}

function gapRow(start, end) {
  const [h1, m1] = start.split(":").map(Number);
  const [h2, m2] = end.split(":").map(Number);
  const fill = (type) => mutate(() => api("POST", "/api/blocks", { date: timer.date, start, end, type }));
  return el("tr", { class: "gap" },
    el("td", { text: start, class: "muted" }), el("td", { text: end, class: "muted" }),
    el("td", { colspan: 4, class: "muted" }, `gap ${fmtHM((h2 * 60 + m2) - (h1 * 60 + m1))} · fill as `,
      el("button", { type: "button", class: "small ghost fill", text: "+ work", onclick: () => fill(timer.pending.type || "dev") }),
      el("button", { type: "button", class: "small ghost fill", text: "+ break", onclick: () => fill(timer.pending.breakType || "eat") })),
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
  const heads = [["Start"], ["End"], ["Type"], ["Project"], ["Client"], ["€", "num"], ["Dur", "num"], [""]];
  const head = el("tr", {}, ...heads.map(([t, c]) => el("th", { class: c || "", text: t })));
  const blocks = timer.day.blocks;
  const rows = [];
  const sorted = [...blocks].sort((a, b) => a.start.localeCompare(b.start));
  let covered = null; // latest end seen so far, so an overlapping block never fakes a gap
  for (const b of sorted) {
    if (covered && covered < b.start) rows.push(gapRow(covered, b.start));
    if (!b.end) covered = "24:00";
    else if (!covered || b.end > covered) covered = b.end;
    rows.push(blockRow(b));
  }
  if (!rows.length) rows.push(el("tr", {}, el("td", { colspan: 8, class: "muted", text: "No blocks on this day." })));
  $("blocks").replaceChildren(el("thead", {}, head), el("tbody", {}, rows));
  const work = blocks.filter((b) => b.work_type === "work" && b.minutes != null).reduce((a, b) => a + b.minutes, 0);
  const brk = blocks.filter((b) => b.work_type !== "work" && b.minutes != null).reduce((a, b) => a + b.minutes, 0);
  const open = blocks.some((b) => !b.end);
  $("dayfoot").replaceChildren(
    el("span", {}, "Worked ", el("b", { text: fmtHM(work) }), open ? " + running" : "", " · breaks ", el("b", { text: fmtHM(brk) })),
    el("span", { class: "muted", text: `${blocks.length} block${blocks.length === 1 ? "" : "s"}` }));
}

function renderProposals() {
  const ul = $("proposals");
  const props = timer.day.proposals || [];
  $("proposals-sec").classList.toggle("has", props.length > 0);
  ul.replaceChildren(...props.map((p) => el("li", {},
    el("span", {}, el("span", { class: "t", text: `${p.start}–${p.end}` }), p.title || ""),
    el("span", { class: "btns" },
      el("button", { type: "button", class: "small", text: "Add", onclick: () => addProposal(p) }),
      el("button", { type: "button", class: "small ghost", text: "✕", "aria-label": "Dismiss for today",
        onclick: () => dismissProposal(p) })))));
}

function dismissProposal(p) {
  mutate(() => api("POST", "/api/calendar/dismiss", { date: timer.date, start: p.start, title: p.title }));
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

async function loadStatus() {
  timer.status = await api("GET", "/api/status");
  timer.fetchedAt = Date.now();
  syncPendingFromStatus();
  renderStatus();
}

async function loadDay() {
  timer.day = await api("GET", `/api/day/${timer.date}`);
  renderBlocks();
  renderProposals();
}

async function refreshAll() {
  try {
    await Promise.all([loadStatus(), loadDay()]);
    renderStatus();
  } catch (err) { showError(err); }
}

async function timerAction(path, body) {
  if (timer.busy) return;
  setBusy(true);
  try {
    await api("POST", path, body);
    await refreshAll();
  } catch (err) { showError(err); } finally { setBusy(false); }
}

function startTimer() {
  const body = {};
  if (timer.pending.type) body.type = timer.pending.type;
  const project = $("project").value.trim();
  if (project) body.project = project;
  return timerAction("/api/start", body);
}

function pauseTimer() {
  return timerAction("/api/pause", { type: timer.pending.breakType || "eat" });
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
  } catch (err) { showError(err); }
}

function editBlockCell(td, block) {
  if (td.querySelector("input")) return;
  const field = td.dataset.field;
  const original = block[field] || "";
  const isTime = field === "start" || field === "end";
  const input = el("input", { type: "text", value: original, autocomplete: "off", class: isTime ? "time" : "", "aria-label": field });
  if (isTime) {
    input.placeholder = "HH:MM";
    input.inputMode = "numeric";
    input.addEventListener("input", () => previewDur(td.closest("tr"), block, field, input.value));
  }
  let cancelled = false;
  const commit = () => {
    if (cancelled) return;
    let v = input.value.trim();
    if (isTime && v) v = normTime(v);
    if (v === original) { renderBlocks(); return; }
    mutate(async () => {
      await api("PUT", `/api/blocks/${block.id}`, { [field]: v === "" && field === "end" ? null : v });
      if (isTime) timer.followup = neighbourFollowup(block, field, original, v);
    });
  };
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); input.blur(); }
    else if (e.key === "Escape") { cancelled = true; renderBlocks(); }
  });
  input.addEventListener("blur", commit);
  td.replaceChildren(input);
  input.focus();
  input.select();
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

function deleteBlock(b) {
  if (!confirm(`Delete ${b.start}–${b.end || "…"} ${b.type}?`)) return;
  mutate(() => api("DELETE", `/api/blocks/${b.id}`));
}

function addRow() {
  const blocks = timer.day.blocks;
  const lastEnd = blocks.map((b) => b.end).filter(Boolean).sort().pop();
  const now = nowHHMM();
  const start = lastEnd || now;
  let end;
  if (timer.date === isoDate(new Date()) && now > start) {
    end = now;
  } else {
    const [h, m] = start.split(":").map(Number);
    const total = Math.min(h * 60 + m + 30, 23 * 60 + 59);
    end = `${pad(Math.floor(total / 60))}:${pad(total % 60)}`;
  }
  // type and client defaults are applied by the API
  mutate(() => api("POST", "/api/blocks", { date: timer.date, start, end }));
}

function addProposal(p) {
  mutate(() => api("POST", "/api/calendar/add", { date: timer.date, start: p.start, end: p.end, title: p.title }));
}

const gotoDate = (iso) => { location.href = iso === isoDate(new Date()) ? "/timer" : `/timer?date=${iso}`; };

// keyboard shortcuts on the Timer page (the caller has already excluded inputs and modifiers)
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

function initTimer() {
  timer.date = timerDate();
  const today = isoDate(new Date());
  $("day").value = timer.date;
  $("day-title").textContent = timer.date === today ? `Today · ${fmtDayTitle(timer.date)}` : fmtDayTitle(timer.date);
  $("day-today").hidden = timer.date === today;
  $("day").addEventListener("change", (e) => { if (e.target.value) gotoDate(e.target.value); });
  $("day-prev").addEventListener("click", () => gotoDate(shiftDate(timer.date, -1)));
  $("day-next").addEventListener("click", () => gotoDate(shiftDate(timer.date, 1)));
  $("day-today").addEventListener("click", () => gotoDate(today));
  $("btn-start").addEventListener("click", startTimer);
  $("btn-pause").addEventListener("click", pauseTimer);
  $("btn-stop").addEventListener("click", stopTimer);
  $("add-row").addEventListener("click", addRow);
  $("project").addEventListener("input", () => { timer.pending.project = null; renderChips("chips-projects", timer.status ? timer.status.chips.projects : [], "project"); });
  // a note typed while working applies to the running block, like a chip; otherwise it waits for Start
  $("project").addEventListener("change", () => {
    if (timer.status && timer.status.state === "working") retypeRunning({ project: $("project").value.trim() || null });
  });
  document.addEventListener("keydown", (e) => {
    if (e.target.matches("input, select, textarea") || e.altKey || e.ctrlKey || e.metaKey) return;
    if (e.key === "ArrowLeft") gotoDate(shiftDate(timer.date, -1));
    else if (e.key === "ArrowRight") gotoDate(shiftDate(timer.date, 1));
    else shortcut(e);
  });
  refreshAll();
  setInterval(() => loadStatus().catch(showError), 60000);
  setInterval(() => { if (timer.status && timer.status.state !== "stopped") renderHeroClocks(); }, 1000);
  timer.tick = setInterval(() => {
    if (!timer.status) return;
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

const niceStep = (range, ticks = 4) => {
  const raw = range / ticks, p = 10 ** Math.floor(Math.log10(raw || 1));
  return [1, 2, 2.5, 5, 10].map((m) => m * p).find((st) => st >= raw) || p * 10;
};
const periodLabel = (key, group) => (group === "week" ? `W${key.slice(5)}` : group === "month" ? key.slice(5) : key.replace("-Q", " Q"));
const periodLong = (key, group) => (group === "week" ? `Week ${key.slice(5)} · ${key.slice(0, 4)}` : group === "month" ? key : key);

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
  const every = Math.ceil(keys.length / Math.max(2, Math.floor(f.iw / 44)));
  keys.forEach((k, i) => {
    const last = i === keys.length - 1;
    if (!last && (i % every || keys.length - 1 - i < every)) return;
    g.append(svg("text", { x: f.x(i) + f.slot / 2, y: H - 6, "text-anchor": "middle", text: periodLabel(k, group) }));
  });
  return g;
}

// 1. Extra hours per period: diverging bars around zero
function chartExtra(rows, group, cur) {
  const card = chartCard("Extra hours", "per period, vs expected");
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
    hover(hit, `${periodLong(r.key, group)}${r.key === cur ? " (in progress)" : ""}\n${fmtH(r.worked_h)} worked · ${fmtH(r.expected_h)} expected\n${fmtSigned(v)}`);
  });
  root.append(xLabels(f, rows.map((r) => r.key), group, H));
  card.append(root);
  return card;
}

// 2. Running balance: cumulative extra hours as a line with a wash
function chartBalance(rows, group, cur) {
  let acc = 0;
  const pts = rows.map((r) => ({ key: r.key, v: (acc += r.extra_h), extra: r.extra_h }));
  const card = chartCard("Balance", `cumulative extra hours${pts.length ? ` · now ${fmtSigned(pts[pts.length - 1].v)}` : ""}`);
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
    hover(hit, `${periodLong(p.key, group)}${p.key === cur ? " (in progress)" : ""}\nbalance ${fmtSigned(p.v)}\nthis period ${fmtSigned(p.extra)}`);
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
async function renderCharts(rows, group) {
  const q = selectionQuery();
  let hm = null;
  try { hm = await api("GET", `/api/heatmap?${q}`); } catch (_) { hm = null; }
  Object.assign(chartState, { rows, group, hm });
  drawCharts();
}
function drawCharts() {
  const { rows, group, hm } = chartState;
  if (!rows) return;
  chartState.w = wideW();
  const cur = group === "week" ? isoWeek(isoDate(new Date())) : null;
  $("charts").replaceChildren(chartExtra(rows, group, cur), chartBalance(rows, group, cur), chartTypes(rows, group, cur),
    chartProjects(rows), hm ? chartHeat(hm) : null);
}
window.addEventListener("resize", () => { if (chartState.rows && wideW() !== chartState.w) drawCharts(); });

// ---- reports page ------------------------------------------------------------

const fmtEur = (v) => (v == null ? "" : `${Math.round(v).toLocaleString("en-GB").replace(/,/g, "\u202f")} €`);

let reportAlt = 40; // the alternative week basis shown next to the base columns
const reportCols = () => [
  ["key", "Period", (r) => r.key],
  ["worked", "Worked", (r) => fmtH(r.worked_h)],
  ["expected", "Expected", (r) => fmtH(r.expected_h)],
  ["extra", "Extra", (r) => r.extra_h, "signed"],
  ["extra40", `Extra ${fmtNum(reportAlt, 0)}h`, (r) => r.extra_alt_h, "signed"],
  ["days", "Days", (r) => String(r.days_worked)],
  ["equiv", "Days eq.", (r) => fmtNum(r.days_equiv, 1)],
  ["billable", "Billable", (r) => fmtH(r.billable_h)],
  ["amount", "€", (r) => fmtEur(r.amount), "eur"],
];

function table(cols, rows, rowClass) {
  // every cell carries col-<key> so the stylesheet can hide a column on phones
  const head = el("tr", {}, ...cols.map(([key, label], i) => el("th", { class: `${i ? "num" : ""} col-${key}`.trim(), text: label })));
  const body = rows.map((r) => el("tr", { class: rowClass ? rowClass(r) : "" },
    ...cols.map(([key, , f, kind], i) => (kind === "signed" ? signedCell(f(r), `col-${key}`) : el("td", { class: `${i ? "num" : ""} ${kind || ""} col-${key}`.trim(), text: f(r) })))));
  return [el("thead", {}, head), el("tbody", {}, body)];
}

function statsTable(a, b) {
  const items = [
    ["Net", "net_h"], ["Last 4 weeks", "last4_h"], [`Net at ${fmtNum(reportAlt, 0)} h`, "net_alt_h"], [`Last 4 at ${fmtNum(reportAlt, 0)} h`, "last4_alt_h"],
    ["Min week", "min_h"], ["Q1", "q1_h"], ["Median", "median_h"], ["Q3", "q3_h"], ["Max week", "max_h"],
  ];
  const head = el("tr", {}, el("th", { text: "Weekly stats" }), el("th", { text: "Incl. this week" }), el("th", { text: "Excl. this week" }));
  const body = items.map(([label, k]) => el("tr", {}, el("td", { text: label }), signedCell(a[k]), signedCell(b[k])));
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

async function loadSummary() {
  updateExportLinks();
  const q = selectionQuery();
  q.set("group", $("group").value);
  try {
    const data = await api("GET", `/api/summary?${q}`);
    const rows = data.rows; // oldest first, like the Excel pivot
    const current = isoWeek(isoDate(new Date()));
    renderCharts(rows, $("group").value);
    if (data.alt_week_h) reportAlt = data.alt_week_h;
    const cols = data.rate_h == null ? reportCols().filter(([k]) => k !== "amount") : reportCols();
    $("summary").className = "grid sticky";
    $("summary").replaceChildren(...table(cols, rows, (r) => (r.key === current ? "cur" : "")));
    if (data.rate_h != null && rows.length) {
      const total = rows.reduce((a, r) => a + (r.amount || 0), 0);
      const bill = rows.reduce((a, r) => a + r.billable_h, 0);
      $("summary").append(el("tfoot", {}, el("tr", {}, el("td", { colspan: cols.length - 2, text: "Total" }),
        el("td", { class: "num", text: fmtH(bill) }), el("td", { class: "num", text: fmtEur(total) }))));
    }
    $("stats").replaceChildren();
    if (data.stats) {
      $("stats").append(el("div", { class: "scroll" }, statsTable(data.stats.with_current, data.stats.without_current)));
    }
  } catch (err) { showMessages($("import-result"), [`Error: ${err.message}`], "error"); }
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
  if (!month) { $("invoice-table").replaceChildren(); return; }
  try {
    const rows = await api("GET", `/api/invoice?month=${month}`);
    const priced = rows.some((r) => r.amount != null);
    const cols = priced ? [...invoiceCols, ["amount", "€", null]] : invoiceCols;
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
      signedCell(sum("worked_h") - sum("expected_h")), el("td", { class: "num muted", text: priced ? `${fmtH(sum("billable_h"))} bill.` : "" }),
      priced ? el("td", { class: "num" }, el("b", { text: fmtEur(sum("amount")) })) : null);
    $("invoice-table").replaceChildren(el("thead", {}, head), el("tbody", {}, body), el("tfoot", {}, foot));
  } catch (err) { showMessages($("import-result"), [`Error: ${err.message}`], "error"); }
}

function importForm(dry) {
  const fd = new FormData($("import-form"));
  fd.set("dry_run", dry ? "1" : "0");
  if (!fd.has("workdays")) fd.set("workdays", "0");
  return fd;
}

async function importDryRun(e) {
  e.preventDefault();
  const out = $("import-result");
  try {
    const r = await api("POST", "/api/import", importForm(true));
    const mode = new FormData($("import-form")).get("mode");
    const lines = [`Dry run: ${r.would_insert} to insert, ${r.would_update} to update, ${r.skipped} skipped.`];
    if (mode === "replace") {
      lines.push(`Replace will delete ${r.would_delete} existing block(s) within the date range of the file.`);
    }
    (r.errors || []).forEach((m) => lines.push(`Problem: ${m}`));
    showMessages(out, lines);
    out.append(el("button", { type: "button", class: `small${mode === "replace" ? " danger" : " primary"}`, text: mode === "replace" ? "Confirm replace" : "Confirm import", onclick: importConfirm }));
  } catch (err) { showMessages(out, [`Error: ${err.message}`], "error"); }
}

async function importConfirm(e) {
  const btn = e.currentTarget;
  btn.disabled = true;
  try {
    const r = await api("POST", "/api/import", importForm(false));
    showMessages($("import-result"), [`Imported: ${JSON.stringify(r)}`], "ok");
    loadSummary();
  } catch (err) {
    showMessages($("import-result"), [`Error: ${err.message}`], "error");
  }
}

async function loadRate() {
  try {
    const st = await api("GET", "/api/settings");
    $("rate").value = st.rate == null ? "" : fmtNum(st.rate, 2);
    $("rate-unit").value = st.rate_unit;
    renderRateHint(st);
    renderBasis(st);
  } catch (err) { showMessages($("import-result"), [`Error: ${err.message}`], "error"); }
}

// week basis: what a full week is (35 h default = 7 h days); expected, extra, balance and charts follow it
function renderBasis(st) {
  reportAlt = st.alt_week_h;
  const v = st.week_basis_h;
  for (const b of $("basis-seg").querySelectorAll("button")) b.classList.toggle("on", Number(b.dataset.v) === v);
  $("basis").value = fmtNum(v, 1);
  $("basis-hint").textContent = `= ${fmtH(st.default_expected_h)} per day · overrides kept`;
}

async function saveBasis(v) {
  if (!(v >= 1 && v <= 80)) return;
  try {
    const st = await api("PUT", "/api/settings", { week_basis_h: v });
    renderBasis(st);
    renderRateHint(st);
    loadSummary();
    loadInvoice();
  } catch (err) { showMessages($("import-result"), [`Error: ${err.message}`], "error"); }
}

async function saveRate() {
  const raw = $("rate").value.trim();
  const rate = raw === "" ? null : Number(raw);
  if (rate != null && !(rate >= 0)) return;
  try {
    const st = await api("PUT", "/api/settings", { rate, rate_unit: $("rate-unit").value });
    renderRateHint(st);
    loadSummary();
    loadInvoice();
  } catch (err) { showMessages($("import-result"), [`Error: ${err.message}`], "error"); }
}

function renderRateHint(st) {
  const h = $("rate-hint");
  if (st.rate_h == null) { h.textContent = "billable hours × rate"; return; }
  const perDay = st.rate_h * st.default_expected_h;
  h.textContent = st.rate_unit === "day"
    ? `= ${fmtNum(st.rate_h, 2)} €/h at ${fmtH(st.default_expected_h)} per day`
    : `= ${fmtEur(perDay)} per ${fmtH(st.default_expected_h)} day`;
}

function initReports() {
  const now = new Date();
  $("invoice").value = `${now.getFullYear()}-${pad(now.getMonth() + 1)}`;
  for (const id of ["group", "start", "end"]) $(id).addEventListener("change", loadSummary);
  for (const b of $("group-seg").querySelectorAll("button")) {
    b.addEventListener("click", () => {
      $("group").value = b.dataset.v;
      for (const o of $("group-seg").querySelectorAll("button")) o.classList.toggle("on", o === b);
      loadSummary();
    });
  }
  $("invoice").addEventListener("change", loadInvoice);
  loadRate();
  $("rate").addEventListener("change", saveRate);
  $("rate-unit").addEventListener("change", saveRate);
  for (const b of $("basis-seg").querySelectorAll("button")) b.addEventListener("click", () => saveBasis(Number(b.dataset.v)));
  $("basis").addEventListener("change", () => saveBasis(Number($("basis").value)));
  $("import-form").addEventListener("submit", importDryRun);
  $("import-form").addEventListener("change", () => $("import-result").replaceChildren());
  loadSummary();
  loadInvoice();
}

// ---- days page ---------------------------------------------------------------

const KEEP_SOURCES = ["default", "holiday", "before-first"];
const SOURCE_BADGE = { holiday: ["holiday", "holiday"], manual: ["set", "set"], import: ["set", "imported"], "before-first": ["pre", "before first log"] };

function dayRow(d) {
  const stored = !KEEP_SOURCES.includes(d.source);
  const num = (field) => el("input", { type: "number", step: "0.25", min: "0", value: d[field], class: "quiet", "aria-label": field, inputmode: "decimal" });
  const exp = num("expected_h");
  const sick = num("sick_h");
  const reason = el("input", { type: "text", value: d.reason || "", class: "quiet", "aria-label": "reason" });
  const save = async () => {
    try {
      await api("PUT", `/api/days/${d.date}`, { expected_h: exp.value, sick_h: sick.value || 0, reason: reason.value });
      await loadDays();
    } catch (err) { showMessages($("days-msg"), [`Error: ${err.message}`], "error"); }
  };
  [exp, sick, reason].forEach((i) => i.addEventListener("change", save));
  const reset = stored ? el("button", {
    type: "button", class: "ghost x", text: "↺", title: "Back to default", "aria-label": "Reset to default",
    onclick: async () => {
      try { await api("DELETE", `/api/days/${d.date}`); await loadDays(); }
      catch (err) { showMessages($("days-msg"), [`Error: ${err.message}`], "error"); }
    },
  }) : null;
  const badge = SOURCE_BADGE[d.source];
  const cls = [isWeekend(d.date) ? "wknd" : "", stored ? "set" : ""].join(" ").trim();
  return el("tr", { class: cls },
    el("td", {}, el("span", { class: "wd", text: weekdayShort(d.date) }), d.date.slice(5), badge ? el("span", { class: `badge ${badge[0]}`, text: badge[1] }) : null),
    el("td", { class: "num" }, exp), el("td", { class: "num" }, sick),
    el("td", {}, reason), el("td", { class: "num" }, reset));
}

async function loadDays() {
  const q = new URLSearchParams({ start: $("days-start").value, end: $("days-end").value });
  try {
    const rows = await api("GET", `/api/days?${q}`);
    const head = el("tr", {}, ...[["Day"], ["Expected", "num"], ["Sick", "num"], ["Reason"], ["", "num"]].map(([t, c]) => el("th", { class: c || "", text: t })));
    const body = [];
    let week = null;
    for (const d of rows) {
      const wk = isoWeek(d.date);
      if (wk !== week) {
        week = wk;
        const inWeek = rows.filter((r) => isoWeek(r.date) === wk);
        const total = inWeek.reduce((a, r) => a + Number(r.expected_h), 0);
        body.push(el("tr", { class: "sep" }, el("td", { colspan: 5 }, `Week ${wk.slice(5)} · ${fmtH(total)} expected`)));
      }
      body.push(dayRow(d));
    }
    $("days").replaceChildren(el("thead", {}, head), el("tbody", {}, body));
    $("days-msg").replaceChildren();
  } catch (err) { showMessages($("days-msg"), [`Error: ${err.message}`], "error"); }
}

function initDays() {
  const now = new Date();
  $("days-start").value = isoDate(new Date(now.getFullYear(), now.getMonth(), 1));
  $("days-end").value = isoDate(new Date(now.getFullYear(), now.getMonth() + 2, 0));
  $("days-start").addEventListener("change", loadDays);
  $("days-end").addEventListener("change", loadDays);
  loadDays();
}

// ---- boot --------------------------------------------------------------------

// Top nav: six tabs overflow a phone, so the nav scrolls; keep the active tab in view and show a fade while there is more.
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

document.addEventListener("DOMContentLoaded", () => {
  const page = document.body.dataset.page;
  initNav();
  if (page === "timer") initTimer();
  else if (page === "reports") initReports();
  else if (page === "days") initDays();
});
