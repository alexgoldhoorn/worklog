/* Move page: one item (a run, a block or a personal event), its candidate slots from
   /api/day/slots, a preview of the day, and the writes a confirm sends to /api/day/move. */
(() => {
  const $ = (id) => document.getElementById(id);
  const q = new URLSearchParams(location.search);
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const hm = (s) => { const [h, m] = String(s).split(":").map(Number); return h + m / 60; };
  const fmtDate = (iso) => new Date(iso + "T00:00").toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" });
  const notice = (text, cls = "") => { $("notices").replaceChildren(el("p", cls, text)); };
  const H0 = 6, H1 = 22, PX = 40;
  let item = null, day = null, chosen = null, slotsData = null;

  async function call(method, url, body) {
    const r = await fetch(url, { method, headers: { "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
    const out = (r.headers.get("content-type") || "").includes("json") ? await r.json() : await r.text();
    if (!r.ok) throw new Error((out && out.error) || r.statusText);
    return out;
  }

  // ---- resolve the item from the query string against the day model ------------
  function resolveItem(d) {
    const kind = q.get("kind") || "run", date = d.date;
    if (kind === "run") {
      const t = d.training;
      if (!t) throw new Error("No planned session on " + date + ".");
      const run = d.timeline.find((e) => e.layer === "protected" && e.kind === "run");
      const end = t.end || addMin(t.time, 60);
      const minutes = Math.max(30, Math.round((hm(end) - hm(t.time)) * 60));
      return { title: t.session, minutes, kind: "run",
               ref: { kind: "run", date, start: t.time, end, session: t.session, block_id: run ? run.id : null } };
    }
    if (kind === "block") {
      const id = Number(q.get("id"));
      const b = d.timeline.find((e) => e.layer === "protected" && e.id === id);
      if (!b) throw new Error("No such block on " + date + ".");
      return { title: b.title, minutes: Math.round((hm(b.end) - hm(b.start)) * 60), kind: b.kind === "run" ? "run" : "personal",
               ref: { kind: "block", date, start: b.start, end: b.end, block_id: id, title: b.title } };
    }
    const uid = q.get("uid");
    const e = d.timeline.find((x) => x.layer === "personal" && x.uid === uid);
    if (!e) throw new Error("That calendar event is not in today's snapshot.");
    return { title: e.title, minutes: Math.max(15, Math.round((hm(e.end) - hm(e.start)) * 60)), kind: "personal",
             ref: { kind: "personal", date, start: e.start, end: e.end, uid, calendar: e.source, title: e.title } };
  }

  function addMin(hhmm, minutes) { const t = Math.round(hm(hhmm) * 60) + minutes; return `${String(Math.floor(t / 60)).padStart(2, "0")}:${String(t % 60).padStart(2, "0")}`; }

  // ---- render ---------------------------------------------------------------------
  function renderSlots(found) {
    const list = $("slots");
    list.replaceChildren();
    const shown = found.filter((s) => s.verdict !== "clash").slice(0, 12);
    if (!shown.length) list.appendChild(el("p", "hint", "Nothing fits in this range without a clash."));
    for (const s of shown) {
      const row = el("div", "slot " + s.verdict + (s.best ? " best" : ""));
      const dot = el("span", "sdot " + s.verdict);
      const body = el("div", "grow");
      const head = el("div", "row-wrap");
      head.appendChild(el("span", "title", `${s.date === day.date ? "" : fmtDate(s.date) + " · "}${s.start}–${s.end}`));
      if (s.best) head.appendChild(el("span", "pill", "best"));
      if (s.reasons[0] === "current slot") head.appendChild(el("span", "pill", "current"));
      body.appendChild(head);
      body.appendChild(el("div", "hint", s.reasons.filter((r) => r !== "current slot").join(" · ") || verdictText(s.verdict)));
      row.append(dot, body);
      if (s.verdict === "ask_trainer") {
        const b = el("button", "tiny", "Ask the trainer"); b.type = "button";
        b.onclick = async () => {
          const line = `move my ${item.title} from ${item.ref.date} to ${s.date}`;
          try { await navigator.clipboard.writeText(line); notice(`Copied "${line}". Send it to the PA on Telegram; the trainer decides.`, "ok"); }
          catch (e) { notice(`Send this to the PA on Telegram: ${line}`, "ok"); }
        };
        row.appendChild(b);
      } else if (s.reasons[0] !== "current slot") {
        const b = el("button", "tiny", "Pick"); b.type = "button";
        b.onclick = () => pick(s);
        row.appendChild(b);
      }
      list.appendChild(row);
    }
  }

  const verdictText = (v) => ({ fits: "fits", tight: "tight", unknown: "work calendar unknown", clash: "clash" }[v] || v);

  function pick(s) {
    chosen = s;
    $("confirm-card").hidden = false;
    $("paste").hidden = true;
    const w = $("writes");
    w.replaceChildren();
    const defs = item.ref.kind === "run"
      ? [["session_time", "Training plan: time changes, session stays (the coach reads it)", true],
         ["block", "Agent calendar block follows (Google updates on the next sync)", !!item.ref.block_id],
         ["mirror_busy", "Work calendar: give me a Busy line to paste into Outlook", false]]
      : item.ref.kind === "block"
      ? [["block", "Move the block (Google updates on the next sync)", true]]
      : [["gcal", `Google calendar (${item.ref.calendar}): edit the event in place`, true],
         ["mirror_busy", "Work calendar: give me a Busy line to paste into Outlook", false]];
    for (const [k, label, on] of defs) {
      const l = el("label", "task");
      const cb = el("input"); cb.type = "checkbox"; cb.checked = on; cb.dataset.k = k;
      l.append(cb, el("span", "grow", label));
      w.appendChild(l);
    }
    $("confirm-line").textContent = `${item.title}: ${item.ref.start} → ${s.start}–${s.end} on ${fmtDate(s.date)}`;
    $("confirm").textContent = `Move to ${s.start}`;
    renderPreview(s);
  }

  function renderPreview(s) {
    const tl = $("preview");
    tl.replaceChildren();
    const height = (H1 - H0) * PX;
    const lane = el("div", "tl-lane preview"); lane.style.height = height + "px"; lane.style.backgroundSize = `100% ${PX}px`;
    const hours = el("div", "tl-hours"); hours.style.height = height + "px";
    for (let h = H0; h <= H1; h++) { const x = el("div", "", String(h).padStart(2, "0") + ":00"); x.style.top = (h - H0) * PX + "px"; hours.appendChild(x); }
    const body = el("div", "tl-body"); body.append(hours, lane); tl.appendChild(body);
    const own = (e) => (item.ref.kind === "run" && e.layer === "protected" && e.kind === "run")
      || (item.ref.kind === "block" && e.id === item.ref.block_id) || (item.ref.kind === "personal" && e.uid === item.ref.uid);
    const events = s ? day.timeline.filter((e) => !own(e)) : day.timeline;
    for (const e of events) {
      if (hm(e.end) <= H0 || hm(e.start) >= H1) continue;
      const box = el("div", "ev " + e.layer + (e.cancelled ? " cancelled" : ""));
      box.style.top = (Math.max(H0, hm(e.start)) - H0) * PX + "px";
      box.style.height = Math.max(18, (Math.min(H1, Math.max(hm(e.end), hm(e.start) + 0.5)) - Math.max(H0, hm(e.start))) * PX - 2) + "px";
      box.appendChild(el("span", "", `${e.start} ${e.title}`));
      lane.appendChild(box);
    }
    if (s && s.date === day.date) {
      const ghost = el("div", "ev ghost");
      ghost.style.top = (hm(s.start) - H0) * PX + "px";
      ghost.style.height = Math.max(18, (hm(s.end) - hm(s.start)) * PX - 2) + "px";
      ghost.appendChild(el("span", "", `${s.start} ${item.title}`));
      lane.appendChild(ghost);
    }
  }

  async function confirm() {
    if (!chosen) return;
    const writes = [...$("writes").querySelectorAll("input:checked")].map((c) => c.dataset.k);
    $("confirm").disabled = true;
    try {
      const out = await call("POST", "/api/day/move", { ref: item.ref, date: chosen.date, start: chosen.start, end: chosen.end, writes });
      const bits = [];
      if (out.queued.length) bits.push(`${out.queued.length} write${out.queued.length === 1 ? "" : "s"} queued for the next sync`);
      if (out.blocks.length) bits.push("block moved");
      notice(`Moved ${item.title} to ${chosen.start}. ${bits.join(", ")}.`, "ok");
      if (out.paste) { $("paste").hidden = false; $("paste").textContent = out.paste; }
      $("confirm").disabled = true;
      setTimeout(() => { location.href = "/?date=" + chosen.date; }, out.paste ? 6000 : 1500);
    } catch (e) { notice("Move failed: " + e.message, "error"); $("confirm").disabled = false; }
  }

  async function load() {
    if (!q.get("kind") && !q.get("id") && !q.get("uid")) {
      $("move-sub").textContent = "Nothing selected yet.";
      const p = el("p", "hint", "Open Move from an event or block on the Day page, or from a block on the Week page: that picks what to move, and this page lists where it fits.");
      const links = el("p", "row-wrap");
      for (const [href, text] of [["/", "Day page"], ["/week", "Week page"]]) { const a = el("a", "small btn", text); a.href = href; links.appendChild(a); }
      $("slots").replaceChildren(p, links);
      return;
    }
    try {
      const date = q.get("date") || new Date().toISOString().slice(0, 10);
      day = await call("GET", "/api/day?date=" + date);
      item = resolveItem(day);
      $("move-title").textContent = `Move: ${item.title}, ${item.minutes} min`;
      $("move-sub").textContent = `${fmtDate(day.date)} · now at ${item.ref.start}`;
      $("move-back").href = "/?date=" + day.date;
      renderPreview(null);
      const to = item.ref.kind === "run" ? date : addDays(date, 6);
      slotsData = await call("POST", "/api/day/slots", { item: { title: item.title, minutes: item.minutes, kind: item.kind, ref: item.ref }, from: date, to });
      renderSlots(slotsData.slots);
    } catch (e) { notice(e.message, "error"); }
  }

  function addDays(iso, n) { const d = new Date(iso + "T00:00"); d.setDate(d.getDate() + n); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; }

  document.addEventListener("DOMContentLoaded", () => {
    $("confirm").onclick = confirm;
    $("cancel").onclick = () => { chosen = null; $("confirm-card").hidden = true; renderPreview(null); };
    load();
  });
})();
