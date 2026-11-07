/* balance: week view + gate strip + goals. Fetches /api/week and renders. */
(() => {
  const $ = (s) => document.querySelector(s);
  const H0 = 6, H1 = 21, PX = 40;            // grid hours and px per hour
  let start = null;                            // Monday of the shown week (ISO) or null = this week
  let data = null;

  const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;"}[c]));
  const hm = (s) => { const [h, m] = s.split(":").map(Number); return h + m / 60; };
  const fmtDay = (iso) => new Date(iso + "T00:00").toLocaleDateString("en-GB", {weekday: "short", day: "2-digit", month: "2-digit"});
  const notice = (text, cls = "") => { const p = document.createElement("p"); p.className = cls; p.textContent = text; $("#notices").replaceChildren(p); };

  async function api(path, opts = {}) {
    const r = await fetch(path, Object.assign({headers: {"Content-Type": "application/json"}}, opts));
    const ct = r.headers.get("content-type") || "";
    const body = ct.includes("json") ? await r.json() : await r.text();
    if (!r.ok) throw new Error(body.error || body || r.statusText);
    return body;
  }

  async function load() {
    try {
      data = await api("/api/balance/week" + (start ? "?start=" + start : ""));
      $("#notices").replaceChildren();
      render();
    } catch (e) { notice("Could not load: " + e.message, "error"); }
  }

  function render() {
    renderGate(data.gate, data.sync);
    $("#week-label").textContent = `${fmtDay(data.start)} – ${fmtDay(data.end)}`;
    renderWeek();
    renderGoals(data.goals);
    renderHistory(data.history);
    renderSettings(data.settings);
  }

  function renderGate(g, sync) {
    const el = $("#gate");
    el.className = "card gate " + (g.colour || "");
    { const d = $("#brand-dot"); if (d) d.className = "dot " + (g.colour || ""); }
    if (!g.colour) { el.innerHTML = '<div class="head"><span class="colour">No verdict yet</span><span class="date">the gate runs at 07:22</span></div>'; return; }
    const n = g.numbers || {};
    const fmt = (v, unit) => v == null ? "–" : `${v}${unit || ""}`;
    const rows = [
      ["Work last 7 days", fmt(n.hours_7d, " h"), "band " + esc(data.settings.week_hours_min) + "–" + esc(data.settings.week_hours_max) + " h"],
      ["Work, 3-week average", fmt(n.hours_21d_week_avg, " h/week"), ""],
      ["Evenings past the stop (7 d)", fmt(n.evenings_7d), ""],
      ["Resting HR (7 d / usual)", `${fmt(n.rhr_7d)} / ${fmt(n.rhr_base)}`, ""],
      ["HRV (7 d / usual)", `${fmt(n.hrv_7d, " ms")} / ${fmt(n.hrv_base, " ms")}`, ""],
      ["Sleep (7 d)", `${fmt(n.sleep_7d_h, " h")}${n.sleep_score_7d != null ? ", score " + n.sleep_score_7d : ""}`, ""],
      ["Stress (7 d / usual)", `${fmt(n.stress_7d)} / ${fmt(n.stress_base)}`, ""],
      ["Runs done / planned (14 d)", `${fmt(n.runs_done_14d)} / ${fmt(n.runs_planned_14d)}`, n.illness_open ? "illness open: runs not counted" : ""],
      ["Heavy days you tapped (7 d)", fmt(n.felt_heavy_7d), ""],
    ];
    const meaning = {green: "Capacity ok. Nothing to protect this week.", amber: "Two or more signals are up. Keep the hard stop and one easy day.",
                     red: "Work load and body signals are both up. The gate protects the week: approve the blocks below."}[g.colour] || "";
    let html = `<div class="head"><span class="colour">Load ${esc(g.colour)}</span><span class="date">verdict of ${esc(g.date)}</span>`;
    if (g.pre_event) html += `<span class="date">· ${esc(g.pre_event.title)} in ${g.pre_event.days} day${g.pre_event.days === 1 ? "" : "s"}</span>`;
    html += `</div><div class="hint">${esc(meaning)}</div>`;
    html += `<h4>Why</h4>`;
    if (g.signals && g.signals.length) html += "<ul>" + g.signals.map((s) => `<li>${esc(s.text)}</li>`).join("") + "</ul>";
    else html += `<div class="hint">No signal firing.</div>`;
    if (g.protect) html += `<h4>Protect</h4><div class="protect">${esc(g.protect)}</div>`;
    html += `<h4>The numbers behind it</h4><table class="numtable">${rows.map(([k, v, note]) => `<tr><td>${esc(k)}</td><td class="v">${v}</td><td class="hint">${note}</td></tr>`).join("")}</table>`;
    if (g.gaps && g.gaps.length) html += `<div class="gaps">No data: ${esc(g.gaps.join(", "))}</div>`;
    if (sync && sync.google && sync.google !== "ok") html += `<div class="gaps">Google Calendar: ${esc(sync.google)} (${sync.pending || 0} block(s) waiting)</div>`;
    el.innerHTML = html;
  }

  function renderWeek() {
    const hardStop = data.settings.hard_stop || "18:00";
    const nowD = new Date();
    const todayIso = data.today;
    const grid = document.createElement("div");
    grid.className = "wgrid";
    const dayHead = (d) => fmtDay(d) + data.personal.filter((e) => e.date === d && e.all_day).map((e) => `<span class="allday" title="${esc(e.title)}">${esc(e.title)}</span>`).join("");
    grid.innerHTML = '<div class="hd corner"></div>' + data.days.map((d) => `<div class="hd ${d === todayIso ? "today" : ""}">${dayHead(d)}</div>`).join("");
    const hours = document.createElement("div");
    hours.className = "hours"; hours.style.height = (H1 - H0) * PX + "px";
    for (let h = H0; h <= H1; h++) { const s = document.createElement("div"); s.style.top = (h - H0) * PX + "px"; s.textContent = `${String(h).padStart(2, "0")}:00`; hours.appendChild(s); }
    grid.appendChild(hours);
    for (const d of data.days) {
      const col = document.createElement("div");
      col.className = "col" + (d === todayIso ? " today" : "");
      col.style.height = (H1 - H0) * PX + "px"; col.style.backgroundSize = `100% ${PX}px`;
      // the header row above is hidden on phones, where each day becomes a list: repeat the day inside the column
      const dh = document.createElement("div"); dh.className = "dayhd" + (d === todayIso ? " today" : ""); dh.innerHTML = dayHead(d); col.appendChild(dh);
      const isWeekday = new Date(d + "T00:00").getDay() % 6 !== 0;
      if (isWeekday) { const l = document.createElement("div"); l.className = "stopline"; l.style.top = (hm(hardStop) - H0) * PX + "px"; l.title = "hard stop " + hardStop; col.appendChild(l); }
      if (d === todayIso) { const l = document.createElement("div"); l.className = "nowline"; l.style.top = (nowD.getHours() + nowD.getMinutes() / 60 - H0) * PX + "px"; col.appendChild(l); }
      // two sub-columns so a long personal event (school) never covers the work meetings;
      // appended in start order so the phone list (static flow) reads top to bottom
      const items = [];
      for (const e of data.work.filter((e) => e.date === d)) items.push([e.start, ev("work sub-l", e.start, e.end, e.title, "")]);
      for (const e of data.personal.filter((e) => e.date === d && !e.all_day)) {
        const box = ev("personal sub-r", e.start, e.end, e.title, e.calendar);
        if (e.uid) { const mv = document.createElement("a"); mv.className = "mv"; mv.textContent = "move"; mv.href = `/move?kind=personal&date=${d}&uid=${encodeURIComponent(e.uid)}`; box.appendChild(mv); }
        items.push([e.start, box]);
      }
      for (const b of data.blocks.filter((b) => b.date === d && b.state !== "rejected")) items.push([b.start, block(b)]);
      items.sort((a, b) => hm(a[0]) - hm(b[0]));
      for (const [, node] of items) col.appendChild(node);
      if (!items.length) { const n = document.createElement("div"); n.className = "nothing"; n.textContent = "nothing on the calendars"; col.appendChild(n); }
      grid.appendChild(col);
    }
    $("#week").replaceChildren(grid);
  }

  function ev(cls, s, e, title, sub) {
    const el = document.createElement("div");
    el.className = "ev " + cls;
    place(el, s, e);
    el.innerHTML = `<span class="t">${esc(s)}${e ? "–" + esc(e) : ""}</span> ${esc(title)}${sub ? ` <span class="t">${esc(sub)}</span>` : ""}`;
    el.title = `${s}–${e} ${title}`;
    return el;
  }

  function place(el, s, e) {
    const max = (H1 - H0) * PX;
    const top = Math.min(max - 18, Math.max(0, (hm(s) - H0) * PX));
    const bottom = Math.min(max, Math.max(top + 18, (hm(e || s) - H0) * PX - 2));
    el.style.top = top + "px"; el.style.height = (bottom - top) + "px";
  }

  function block(b) {
    const el = document.createElement("div");
    el.className = `ev ${b.kind} ${b.state}`;
    place(el, b.start, b.end);
    el.title = (b.note || "") + ` [${b.state}, ${b.source}]`;
    el.innerHTML = `<span class="t">${esc(b.start)}–${esc(b.end)}</span> ${esc(b.title)}`;
    if (b.state === "proposed") {
      const btns = document.createElement("div"); btns.className = "btns";
      const ok = document.createElement("button"); ok.className = "primary"; ok.textContent = "✓";
      ok.onclick = () => decide(b.id, "approve");
      const no = document.createElement("button"); no.className = "danger"; no.textContent = "✗";
      no.onclick = () => decide(b.id, "reject");
      btns.append(ok, no); el.appendChild(btns);
    }
    if (b.state === "approved") {
      const mv = document.createElement("a"); mv.className = "mv"; mv.textContent = "move";
      mv.href = `/move?kind=${b.kind === "run" ? "run" : "block"}&date=${b.date}&id=${b.id}`; el.appendChild(mv);
    }
    if (b.state === "approved" && b.source !== "manual") {
      el.ondblclick = () => { if (confirm("Reject this block? It will be removed from Google Calendar on the next sync.")) decide(b.id, "reject"); };
    } else if (b.state === "approved") {
      el.ondblclick = () => { if (confirm("Remove this block?")) decide(b.id, "reject"); };
    }
    return el;
  }

  async function decide(id, action) {
    try { await api(`/api/balance/blocks/${id}/${action}`, {method: "POST"}); await load(); notice(action === "approve" ? "Approved. Google Calendar catches up within 15 minutes." : "Rejected.", "ok"); }
    catch (e) { notice(e.message, "error"); }
  }

  function renderGoals(g) {
    const el = $("#goals");
    if (!g || !g.project) { el.innerHTML = '<div class="empty">No Todoist snapshot yet (sync runs every 15 min).</div>'; $("#goals-meta").textContent = ""; return; }
    $("#goals-meta").textContent = `${g.project} · ${g.open} open · ${g.fetched ? g.fetched.slice(0, 16).replace("T", " ") : ""}`;
    const today = new Date(data.today + "T00:00");
    const left = (iso) => Math.round((new Date(iso.slice(0, 10) + "T00:00") - today) / 864e5);
    let html = "<h3>Milestones</h3>";
    const md = (t) => (window.mdlite ? mdlite.toHtml(t) : esc(t));
    if (g.milestones.length) html += '<div class="ms">' + g.milestones.map((m) => { const d = left(m.due); const cls = d < 0 ? "past" : d <= 7 ? "soon" : ""; return `<span class="d ${cls}">${esc(m.due.slice(0, 10))}</span><span>${md(m.content)}</span><span class="left ${cls}">${d < 0 ? `${-d} d ago` : d === 0 ? "today" : `in ${d} d`}</span>`; }).join("") + "</div>";
    else html += `<div class="empty">None yet. Milestones live in Todoist, not here: give a dated task in <b>${esc(g.project)}</b> the label <code>${esc(data.settings.milestone_label)}</code> and it appears on the next sync.</div>`;
    html += "<h3>Top 3 today</h3>";
    if (g.top3.length) html += "<ol>" + g.top3.map((t) => `<li class="p${t.priority}">${md(t.content)}${t.due && t.due.slice(0, 10) < data.today ? ` <span class="hint">(${esc(t.due.slice(0, 10))})</span>` : ""}</li>`).join("") + "</ol>";
    else html += '<div class="empty">Nothing due today in this project.</div>';
    if (g.due_today_or_overdue > 3) html += `<div class="hint">${g.due_today_or_overdue} due or overdue in total; the three highest priority are shown.</div>`;
    el.innerHTML = html;
  }

  function renderHistory(h) {
    const el = $("#history");
    if (!h || !h.length) { el.innerHTML = '<div class="empty">No history yet.</div>'; return; }
    el.innerHTML = '<div class="strip">' + h.map((r) => `<span class="day ${esc(r.colour)}" title="${esc(r.date)}: ${esc((r.signals || []).join(", ") || "clear")}">${r.date.slice(8)}</span>`).join("") + "</div>";
  }

  function renderSettings(s) {
    const f = $("#settings");
    const HHMM = 'pattern="([01][0-9]|2[0-3]):[0-5][0-9]" inputmode="numeric" placeholder="HH:MM"';
    const fields = [["hard_stop", "Hard stop", "text", "24h. Work past this time counts as an evening for the gate; the proposed Hard stop blocks start here.", HHMM],
      ["run_slot", "Run slot", "text", "24h. Where the Sunday proposal puts a planned run.", HHMM],
      ["run_alt_slots", "Run fallback slots", "text", "24h, comma-separated. Tried in order when the run slot clashes with a work meeting.", ""],
      ["week_hours_min", "Week hours min", "number", "The band the gate judges work hours against (hours signal fires above max).", 'min="0" max="80" step="0.5"'],
      ["week_hours_max", "Week hours max", "number", "", 'min="0" max="80" step="0.5"'],
      ["gcal_calendar", "Google calendar", "text", "Approved blocks are mirrored to this calendar (primary with a 🛡 prefix until it exists).", ""],
      ["todoist_project", "Todoist project", "text", "Where the top 3 and milestones come from.", ""],
      ["milestone_label", "Milestone label", "text", "Milestones are dated Todoist tasks in that project carrying this label; they are not stored here.", ""]];
    f.innerHTML = fields.map(([k, l, t, help, extra]) => `<label class="srow"><span class="sl">${l}${help ? ` <span class="help" title="${esc(help)}" tabindex="0">?</span>` : ""}</span><input name="${k}" type="${t}" ${extra} value="${esc(s[k] ?? "")}"></label>`).join("")
      + '<div class="hint wide">Stored in the settings table of balance.db; the gate and the Sunday proposal read them on their next run. Hover the ? for what each one does.</div><button class="save" type="submit">Save</button>';
    f.onsubmit = async (e) => {
      e.preventDefault();
      const body = Object.fromEntries(new FormData(f).entries());
      try { await api("/api/balance/settings", {method: "PUT", body: JSON.stringify(body)}); notice("Settings saved. The gate reads them on its next run.", "ok"); await load(); }
      catch (err) { notice(err.message, "error"); }
    };
  }

  function shift(days) {
    const base = new Date((start || data.start) + "T00:00"); base.setDate(base.getDate() + days);
    start = `${base.getFullYear()}-${String(base.getMonth() + 1).padStart(2, "0")}-${String(base.getDate()).padStart(2, "0")}`; load();
  }
  $("#prev").onclick = () => shift(-7);
  $("#next").onclick = () => shift(7);
  $("#today").onclick = () => { start = null; load(); };
  $("#propose").onclick = async () => {
    try {
      const from = data.start < data.today ? data.today : data.start;
      if (from > data.end) { notice("This week is over; nothing to propose.", ""); return; }
      const r = await api("/api/balance/propose", {method: "POST", body: JSON.stringify({start: from, end: data.end})});
      notice(r.created.length ? `${r.created.length} block(s) proposed. Tick the ones you want.` : "Nothing to propose: every day already has its blocks, or no runs are planned.", "ok");
      await load();
    } catch (e) { notice(e.message, "error"); }
  };
  $("#outlook").onclick = async () => {
    const pre = $("#paste");
    if (!pre.hidden) { pre.hidden = true; return; }
    pre.textContent = await api("/api/balance/outlook?start=" + data.start); pre.hidden = false;
    try { await navigator.clipboard.writeText(pre.textContent); notice("Copied to the clipboard.", "ok"); } catch (_) {}
  };
  $("#add").onclick = () => { const f = $("#addform"); f.hidden = !f.hidden; if (!f.hidden) f.date.value = data.today; };
  $("#addform").onsubmit = async (e) => {
    e.preventDefault();
    const body = Object.fromEntries(new FormData(e.target).entries());
    try { await api("/api/balance/blocks", {method: "POST", body: JSON.stringify(body)}); e.target.hidden = true; e.target.reset(); await load(); notice("Block saved and approved.", "ok"); }
    catch (err) { notice(err.message, "error"); }
  };
  load();
})();
