/* Work calendar catch-up: the mirror week with source tags and staleness, cancel/note per meeting,
   the paste box (parse → preview → add), prep notes for tomorrow, the PDF upload. Text only. */
(() => {
  const $ = (id) => document.getElementById(id);
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const fmtDate = (iso) => new Date(iso + "T00:00").toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" });
  const notice = (text, cls = "") => { $("notices").replaceChildren(el("p", cls, text)); };
  const iso = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
  const addDays = (s, n) => { const d = new Date(s + "T00:00"); d.setDate(d.getDate() + n); return iso(d); };
  const monday = (s) => { const d = new Date(s + "T00:00"); const off = (d.getDay() + 6) % 7; d.setDate(d.getDate() - off); return iso(d); };
  let start = monday(iso(new Date()));
  let parsed = [];

  async function call(method, url, body) {
    const r = await fetch(url, { method, headers: { "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
    const out = (r.headers.get("content-type") || "").includes("json") ? await r.json() : await r.text();
    if (!r.ok) throw new Error((out && out.error) || r.statusText);
    return out;
  }

  const sourceTag = (src) => /\.pdf$/i.test(src || "") || src === "pdf" ? "PDF" : src === "dashboard" ? "you" : src === "pa" ? "PA" : (src || "?");

  async function load() {
    try {
      const days = [];
      for (let i = 0; i < 7; i++) days.push(addDays(start, i));
      const payloads = await Promise.all(days.map((d) => call("GET", "/api/day?date=" + d)));
      $("notices").replaceChildren();
      renderBanner(payloads[0]);
      renderWeek(days, payloads);
      renderPrep(payloads);
      renderRules();
    } catch (e) { notice("Could not load the week: " + e.message, "error"); }
  }

  function renderBanner(d) {
    const b = $("wc-banner");
    const m = d.mirror || {};
    const hand = 0;
    if (!m.last_import_end) { b.hidden = false; b.replaceChildren(el("strong", "", "No Outlook export imported yet."), el("span", "", " Every day is unknown: upload the PDF below.")); return; }
    const stale = m.stale_days == null ? "" : m.stale_days === 0 ? "today" : m.stale_days === 1 ? "yesterday" : `${m.stale_days} days ago`;
    b.hidden = false;
    b.replaceChildren(el("strong", "", `Last Outlook export covers to ${fmtDate(m.last_import_end)}`), el("span", "", `${stale ? " · imported " + stale : ""}. Days past it are unknown, not free. Pasted meetings fill gaps but never make a week "known".`));
  }

  function renderWeek(days, payloads) {
    $("wc-week-title").textContent = `${fmtDate(days[0])} – ${fmtDate(days[6])}`;
    const list = $("wc-week");
    list.replaceChildren();
    let hand = 0;
    days.forEach((date, i) => {
      const d = payloads[i];
      const work = d.timeline.filter((e) => e.layer === "work");
      const head = el("div", "wc-day" + (d.mirror.unknown ? " unknown" : ""));
      head.appendChild(el("span", "title", fmtDate(date)));
      head.appendChild(el("span", "hint", d.mirror.unknown ? "unknown: past the last export" : work.length ? "" : "no meetings on file"));
      list.appendChild(head);
      for (const e of work) {
        const row = el("div", "item wc-row" + (e.cancelled ? " cancelled" : ""));
        row.appendChild(el("span", "t", e.start));
        const body = el("div", "grow");
        body.appendChild(el("div", "title", `${e.title}${e.end && e.end !== e.start ? " · " + e.start + "–" + e.end : ""}`));
        if (e.note) body.appendChild(el("div", "hint", e.note));
        row.appendChild(body);
        const tag = sourceTag(e.source);
        if (tag !== "PDF") hand++;
        const acts = el("span", "wc-actions");
        acts.appendChild(el("span", "pill " + (tag === "PDF" ? "" : "amber"), tag));
        const cancel = el("button", "tiny", e.cancelled ? "restore" : "cancel"); cancel.type = "button";
        cancel.onclick = () => act(() => call("POST", "/api/day/workcal/annotate", { date, start: e.start, title: e.title, status: e.cancelled ? "confirmed" : "cancelled" }));
        const note = el("button", "tiny", "note"); note.type = "button";
        note.onclick = () => { const n = window.prompt(`Note for "${e.title}" (no email addresses):`, e.note || ""); if (n !== null) act(() => call("POST", "/api/day/workcal/annotate", { date, start: e.start, title: e.title, note: n })); };
        acts.append(cancel, note);
        row.appendChild(acts);
        list.appendChild(row);
      }
    });
    const b = $("wc-banner");
    if (!b.hidden && hand) b.appendChild(el("span", "", ` ${hand} meeting${hand === 1 ? "" : "s"} this week added by hand or the PA.`));
  }

  function renderPrep(payloads) {
    const list = $("wc-prep");
    list.replaceChildren();
    const tomorrow = addDays(iso(new Date()), 1);
    const d = payloads.find((p) => p.date === tomorrow);
    const meetings = d ? d.timeline.filter((e) => e.layer === "work" && !e.cancelled) : [];
    if (!meetings.length) { list.appendChild(el("p", "hint", d ? `No meetings on file for ${fmtDate(tomorrow)}.` : "Tomorrow is not in this week's view.")); return; }
    const first = d.first_things.find((x) => x.kind === "meeting");
    for (const e of meetings) {
      const row = el("div", "item");
      row.appendChild(el("span", "t", e.start));
      const body = el("div", "grow");
      body.appendChild(el("div", "title", e.title));
      const p = first && first.title === e.title && first.start === e.start ? first.prep : null;
      body.appendChild(el("div", "hint", p ? `prep ${p.minutes} min · start by ${p.start_by}${p.text ? " · " + p.text : ""}` : "no prep note"));
      const btn = el("button", "tiny", p ? "edit prep" : "add prep"); btn.type = "button";
      btn.onclick = () => {
        const minutes = window.prompt(`Prep minutes for "${e.title}" at ${e.start}:`, p ? p.minutes : 20); if (minutes === null) return;
        const text = window.prompt("What to prepare:", p ? p.text : ""); if (text === null) return;
        act(() => call("POST", "/api/day/prep", { date: tomorrow, start: e.start, title: e.title, minutes: Number(minutes), text }));
      };
      body.appendChild(btn);
      row.appendChild(body);
      list.appendChild(row);
    }
  }

  async function renderRules() {
    const list = $("wc-rules");
    try {
      const out = await call("GET", "/api/day/classify/rules");
      list.replaceChildren();
      if (!out.rules.length) { list.appendChild(el("p", "hint", "No title rules yet.")); return; }
      for (const r of out.rules) {
        const row = el("div", "item");
        row.appendChild(el("span", "grow", `"${r.pattern}" → ${r.cls}`));
        const del = el("button", "tiny", "delete"); del.type = "button";
        del.onclick = () => act(() => call("DELETE", `/api/day/classify/rules/${r.id}`));
        row.appendChild(del);
        list.appendChild(row);
      }
    } catch (e) { list.replaceChildren(el("p", "hint", "Rules unavailable: " + e.message)); }
  }

  async function act(fn) { try { await fn(); await load(); notice("Queued; applied by the next sync within 2 minutes.", "ok"); } catch (e) { notice(e.message, "error"); } }

  async function read() {
    try {
      const out = await call("POST", "/api/day/workcal/parse", { text: $("wc-paste").value });
      parsed = out.rows;
      const pv = $("wc-preview");
      pv.replaceChildren();
      for (const r of parsed) {
        const row = el("div", "item" + (r.ok ? "" : " warn"));
        row.appendChild(el("span", "t", r.ok ? r.start : "?"));
        const body = el("div", "grow");
        body.appendChild(el("div", "title", r.ok ? `${fmtDate(r.date)} · ${r.start}–${r.end} · ${r.title}` : r.raw));
        body.appendChild(el("div", "hint", r.ok ? "reads as above" : "could not read: " + r.error));
        row.appendChild(body);
        pv.appendChild(row);
      }
      $("wc-add").disabled = !parsed.some((r) => r.ok);
      $("wc-add").textContent = `Add ${parsed.filter((r) => r.ok).length} meeting${parsed.filter((r) => r.ok).length === 1 ? "" : "s"}`;
    } catch (e) { notice(e.message, "error"); }
  }

  async function add() {
    const ok = parsed.filter((r) => r.ok).map((r) => ({ date: r.date, start: r.start, end: r.end, title: r.title }));
    if (!ok.length) return;
    $("wc-add").disabled = true;
    try {
      await call("POST", "/api/day/workcal/add", { events: ok });
      $("wc-paste").value = ""; parsed = []; $("wc-preview").replaceChildren();
      notice(`${ok.length} meeting${ok.length === 1 ? "" : "s"} queued for the mirror; applied within 2 minutes.`, "ok");
      await load();
    } catch (e) { notice("Add failed: " + e.message, "error"); $("wc-add").disabled = false; }
  }

  document.addEventListener("DOMContentLoaded", () => {
    $("wc-prev").onclick = () => { start = addDays(start, -7); load(); };
    $("wc-next").onclick = () => { start = addDays(start, 7); load(); };
    $("wc-today").onclick = () => { start = monday(iso(new Date())); load(); };
    $("wc-read").onclick = read;
    $("wc-add").onclick = add;
    $("pdf-file").onchange = async () => {
      const f = $("pdf-file").files[0]; if (!f) return;
      const fd = new FormData(); fd.append("file", f);
      try {
        const r = await fetch("/api/day/calendar-pdf", { method: "POST", body: fd });
        const out = await r.json();
        if (!r.ok) throw new Error(out.error || r.statusText);
        notice(`Saved ${out.saved}: ${out.note}.`, "ok");
      } catch (e) { notice("Upload failed: " + e.message, "error"); }
      $("pdf-file").value = "";
    };
    load();
  });
})();
