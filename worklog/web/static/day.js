/* Day page: renders /api/day and drives the timer, prep notes, owner and task ticks.
   Everything from the API lands as text (textContent); never innerHTML with API strings. */
(() => {
  const $ = (id) => document.getElementById(id);
  const H0 = 6, H1 = 22, PX = 48;
  const LANES = [["work", "Work"], ["personal", "Personal"], ["family", "Family"], ["child", "Child"], ["blocks", "Blocks"]];
  const laneOf = (ev) => ev.layer === "work" ? "work" : ev.layer === "protected" ? "blocks" : ev.layer === "duty" ? "child"
    : (ev.classification === "child" || ev.lane === "child") ? "child" : ev.lane === "family" ? "family" : "personal";
  const laneOn = (id) => { try { return localStorage.getItem("day.lane." + id) !== "0"; } catch (e) { return true; } };
  const setLane = (id, on) => { try { localStorage.setItem("day.lane." + id, on ? "1" : "0"); } catch (e) {} };
  const PHONE = window.matchMedia("(max-width: 700px)");
  let date = new URLSearchParams(location.search).get("date") || null;   // null = today
  let data = null;
  let timer = null;
  let pendingType = null;   // type chip picked while the timer is stopped; used by the next start
  const localIso = () => { const n = new Date(); return `${n.getFullYear()}-${String(n.getMonth() + 1).padStart(2, "0")}-${String(n.getDate()).padStart(2, "0")}`; };

  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const hm = (s) => { const [h, m] = String(s).split(":").map(Number); return h + m / 60; };
  const fmtDate = (iso) => new Date(iso + "T00:00").toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" });
  const h2 = (x) => { const m = Math.round(x * 60); return `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, "0")}`; };
  const shift = (iso, days) => { const d = new Date(iso + "T00:00"); d.setDate(d.getDate() + days); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; };
  const notice = (text, cls = "") => { const p = el("p", cls, text); $("notices").replaceChildren(p); };

  async function call(method, url, body) {
    const r = await fetch(url, { method, headers: { "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
    const ct = r.headers.get("content-type") || "";
    const out = ct.includes("json") ? await r.json() : await r.text();
    if (!r.ok) throw new Error((out && out.error) || r.statusText);
    return out;
  }

  async function load() {
    try {
      data = await call("GET", "/api/day" + (date ? "?date=" + date : ""));
      $("notices").replaceChildren();
      render();
    } catch (e) { notice("Could not load the day: " + e.message, "error"); }
  }

  async function act(fn) {
    try { await fn(); await load(); } catch (e) { notice(e.message, "error"); }
  }

  // ---- render ---------------------------------------------------------------
  function render() {
    const d = data;
    $("day-title").textContent = fmtDate(d.date);
    const full = d.sync && (d.sync.full_ran || d.sync.ran);
    $("day-sub").textContent = full ? `snapshots ${String(full).replace("T", " ").slice(0, 16)} · google ${d.sync.google || "?"}${d.is_today ? "" : " · not today: no timer"}` : "no snapshots yet";
    const brand = $("brand-dot"); if (brand) brand.className = "dot " + (d.capacity.colour || "");

    const cap = $("capacity");
    cap.hidden = !d.capacity.show;
    cap.className = "capacity " + d.capacity.colour;
    const line = String(d.capacity.line || "").replace(/^[^A-Za-z]*Capacity:\s*\w+\.\s*/, "");
    cap.replaceChildren(el("strong", "kw", `Load ${d.capacity.colour}`), el("span", "", line ? " · " + line : ""));

    renderTimeline(d);
    renderMirror(d);
    renderFirst(d);
    renderTraining(d);
    renderWork(d);
    renderQueue(d);
    $("counts").textContent = `Done ${d.counts.done} · to do ${d.counts.todo} · meetings left ${d.counts.meetings_left == null ? "unknown" : d.counts.meetings_left}` + (d.counts.unclassified ? ` · ${d.counts.unclassified} family event${d.counts.unclassified === 1 ? "" : "s"} to classify` : "");
  }

  function renderTimeline(d) {
    const note = $("mirror-note");
    if (d.mirror.unknown) { note.hidden = false; note.textContent = "Work calendar unknown for this day: the mirror's last import ends " + (d.mirror.last_import_end || "never") + ". Paste or import before trusting the free slots."; }
    else if (d.mirror.stale_days != null && d.mirror.stale_days > 7) { note.hidden = false; note.textContent = `Work calendar PDF is ${d.mirror.stale_days} days old.`; }
    else note.hidden = true;
    const tl = $("timeline");
    tl.replaceChildren();
    const now = d.now;
    const height = (H1 - H0) * PX;
    const on = LANES.filter(([id]) => laneOn(id));
    const hh = d.household || {};
    const laneName = (id, name) => id === "child" && hh.child ? hh.child : name;
    const ln = $("lane-child-name"); if (ln && hh.child) ln.textContent = hh.child;
    // Phone: the five lanes side by side are unreadable at 390 px (and stacking them orders events by lane,
    // not by time), so render one list sorted by start with a lane pill per event and a "now" marker.
    const phone = PHONE.matches;
    const lanes = {};
    let list = null;
    if (phone) {
      list = el("div", "tl-list");
      tl.appendChild(list);
    } else {
      const head = el("div", "tl-head");
      head.appendChild(el("div", "tl-h", ""));
      for (const [id, name] of on) head.appendChild(el("div", "tl-lane-name " + id, laneName(id, name)));
      tl.appendChild(head);
      const body = el("div", "tl-body");
      const hours = el("div", "tl-hours"); hours.style.height = height + "px";
      for (let h = H0; h <= H1; h++) { const x = el("div", "", String(h).padStart(2, "0") + ":00"); x.style.top = (h - H0) * PX + "px"; hours.appendChild(x); }
      body.appendChild(hours);
      for (const [id] of on) {
        const lane = el("div", "tl-lane " + id); lane.style.height = height + "px"; lane.style.backgroundSize = `100% ${PX}px`;
        if (d.is_today) { const n = el("div", "nowline"); n.style.top = (hm(now) - H0) * PX + "px"; lane.appendChild(n); }
        lanes[id] = lane; body.appendChild(lane);
      }
      tl.appendChild(body);
    }
    {
      const onIds = new Set(on.map(([id]) => id));
      const evs = d.timeline.filter((ev) => onIds.has(laneOf(ev)) && hm(ev.end) > H0 && hm(ev.start) < H1);
      if (phone) evs.sort((a, b) => hm(a.start) - hm(b.start) || hm(a.end) - hm(b.end));
      let nowShown = !(phone && d.is_today);
      const nowRow = () => { nowShown = true; return el("div", "tl-now", `now ${now}`); };
      for (const ev of evs) {
        const laneId = laneOf(ev);
        const s = Math.max(H0, hm(ev.start)), e = Math.min(H1, Math.max(hm(ev.end), s + 0.5));
        if (!nowShown && hm(ev.start) > hm(now)) list.appendChild(nowRow());
        const box = el("div", "ev " + ev.layer + (ev.cancelled ? " cancelled" : "") + (ev.state ? " " + ev.state : ""));
        if (phone) {
          box.appendChild(el("span", "tl-pill " + laneId, laneName(laneId, LANES.find(([i]) => i === laneId)[1])));
        } else {
          box.style.top = (s - H0) * PX + "px";
          box.style.height = Math.max(22, (e - s) * PX - 2) + "px";
        }
        box.title = `${ev.start}–${ev.end} ${ev.title}` + (ev.source ? ` · ${ev.source}` : "") + (ev.creator_name ? ` · created by ${ev.creator_name}` : "");
        let label = phone ? `${ev.start}–${ev.end} ${ev.title}` : `${ev.start} ${ev.title}`;
        if (ev.layer === "duty") label += ev.owner ? ` · ${ev.owner}` : " · who?";
        if (ev.layer === "personal" && ev.classification === "unclassified") label += " · whose?";
        if (ev.layer === "personal" && ev.creator_name && ev.lane !== "personal") label += ` · by ${ev.creator_name}`;
        if (ev.layer === "work" && ev.source && ev.source !== "pdf" && !/\.pdf$/i.test(ev.source)) label += ` · added by ${ev.source}`;
        if (ev.layer === "protected") label += ` · ${ev.state}`;
        if (ev.pending) label += " · pending";
        box.appendChild(el("span", "", label));
        if (ev.layer === "personal" && ev.lane === "family" && ev.classification !== "unclassified" && !ev.pending) {
          const chg = el("button", "tiny", "whose? change"); chg.type = "button";
          chg.onclick = () => { ev.classification = "unclassified"; renderTimeline(d); };
          box.appendChild(chg);
        }
        if (ev.layer === "personal" && ev.classification === "unclassified" && !ev.pending) {
          const hh = d.household || { me: "me", partner: "partner", child: "child" };
          const who = el("span", "btns");
          for (const [cls, text] of [["mine", "me"], ["family", "us"], ["partner", hh.partner], ["child", hh.child]]) {
            const b = el("button", "tiny", text); b.type = "button"; b.title = "whose is this?";
            b.onclick = () => {
              const always = window.confirm(`Only this one? OK = only this occurrence, Cancel = always for events titled "${ev.title}"`) ? false : true;
              act(() => call("POST", "/api/day/classify", { date: d.date, start: ev.start, title: ev.title, cls, always }));
            };
            who.appendChild(b);
          }
          box.appendChild(who);
        }
        if (ev.layer === "personal" && ev.uid && !ev.pending) {
          const mv = el("a", "tiny btn", "Move"); mv.href = `/move?kind=personal&date=${d.date}&uid=${encodeURIComponent(ev.uid)}`;
          box.appendChild(mv);
        }
        if (ev.layer === "work" && !ev.cancelled && ((d.work && d.work.proposals) || []).some((p) => p.start === ev.start && (p.title || "") === (ev.title || ""))
            && (d.is_today ? ev.start <= d.now : d.date < localIso())) {
          const lg = el("button", "tiny", "Log"); lg.type = "button"; lg.title = "Add this meeting to the time log";
          lg.onclick = () => act(() => call("POST", "/api/calendar/add", { date: d.date, start: ev.start, end: ev.end, title: ev.title }));
          box.appendChild(lg);
        }
        if (ev.layer === "protected" && ev.state === "approved" && ev.id) {
          const mv = el("a", "tiny btn", "Move"); mv.href = `/move?kind=${ev.kind === "run" ? "run" : "block"}&date=${d.date}&id=${ev.id}`;
          box.appendChild(mv);
        }
        if (ev.layer === "protected" && ev.state === "proposed") {
          const b = el("span", "btns");
          const ok = el("button", "tiny", "✓"); ok.type = "button"; ok.title = "approve";
          ok.onclick = () => act(() => call("POST", `/api/balance/blocks/${ev.id}/approve`));
          const no = el("button", "tiny", "✗"); no.type = "button"; no.title = "reject";
          no.onclick = () => act(() => call("POST", `/api/balance/blocks/${ev.id}/reject`));
          b.append(ok, no); box.appendChild(b);
        }
        if (ev.layer === "duty") {
          const hh = d.household || { me: "me", partner: "partner" };
          const mine = ev.owner === hh.me;
          const flip = el("button", "tiny", mine ? `${hh.partner} brings her` : "I bring her"); flip.type = "button";
          flip.onclick = () => act(() => call("POST", "/api/day/owner", { date: d.date, start: ev.at, title: ev.title, owner: mine ? hh.partner : hh.me }));
          box.appendChild(flip);
        }
        (phone ? list : lanes[laneId]).appendChild(box);
      }
      if (!nowShown) list.appendChild(nowRow());
      if (phone && !evs.length) list.appendChild(el("p", "hint", "Nothing on the calendars for this day."));
    }
  }

  function renderMirror(d) {
    const m = d.mirror;
    $("mirror-cov").textContent = m.last_import_end ? `covered to ${fmtDate(m.last_import_end)}` : "no PDF imported yet";
    $("mirror-line").textContent = m.unknown ? "This day is past the last Outlook export: meetings unknown, free slots not to be trusted." :
      (m.stale_days == null ? "" : `Last export ${m.stale_days === 0 ? "today" : m.stale_days === 1 ? "yesterday" : m.stale_days + " days ago"}. Meetings added since come from you or the PA.`);
  }

  function renderFirst(d) {
    const list = $("first-list");
    list.replaceChildren();
    for (const x of d.first_things) {
      const row = el("div", "item");
      if (x.kind === "duty") {
        row.appendChild(el("span", "t", x.at));
        const body = el("div", "grow");
        body.appendChild(el("div", "title", `${x.title} · ${x.owner || "who?"}`));
        body.appendChild(el("div", "hint " + (x.fits === false ? "warn" : ""), x.fit_line));
        row.appendChild(body);
      } else if (x.kind === "meeting") {
        row.appendChild(el("span", "t", x.start));
        const body = el("div", "grow");
        body.appendChild(el("div", "title", x.title));
        const p = x.prep;
        body.appendChild(el("div", "hint", p ? `Prep: ${p.text || "(no text)"} · ${p.minutes} min · start by ${p.start_by}` : "No prep note yet."));
        const btn = el("button", "tiny", p ? "Edit prep" : "Add prep"); btn.type = "button";
        btn.onclick = () => promptPrep(d, x);
        body.appendChild(btn);
        row.appendChild(body);
      } else if (x.kind === "urgent") {
        row.appendChild(el("span", "t", "now"));
        const body = el("div", "grow");
        body.appendChild(el("div", "title", x.tasks.length ? `${x.tasks.length} urgent` : "Nothing urgent"));
        for (const t of x.tasks) body.appendChild(taskRow(t));
        row.appendChild(body);
      }
      list.appendChild(row);
    }
  }

  function promptPrep(d, meeting) {
    const minutes = window.prompt(`Prep minutes for "${meeting.title}" at ${meeting.start}:`, meeting.prep ? meeting.prep.minutes : 30);
    if (minutes === null) return;
    const text = window.prompt("What to prepare:", meeting.prep ? meeting.prep.text : "");
    if (text === null) return;
    act(() => call("POST", "/api/day/prep", { date: d.date, start: meeting.start, title: meeting.title, minutes: Number(minutes), text }));
  }

  // Plain text of a Todoist task (its markdown links flattened), cut to 80 chars, used as the block's project.
  function plainTitle(content) {
    let text = String(content || "");
    if (window.mdlite) {
      const box = document.createElement("div");
      box.appendChild(mdlite.toNodes(text));
      text = box.textContent;
    }
    return text.trim().slice(0, 80);
  }

  function taskRow(t) {
    const row = el("label", "task" + (t.done ? " done" : ""));
    const cb = el("input"); cb.type = "checkbox"; cb.checked = !!t.done; cb.disabled = !!t.done;
    cb.onchange = () => act(() => call("POST", `/api/day/task/${encodeURIComponent(t.id)}/complete`));
    row.appendChild(cb);
    const text = el("span", "grow"); text.appendChild(window.mdlite ? mdlite.toNodes(t.content) : document.createTextNode(t.content));
    row.appendChild(text);
    if (!t.done && data.is_today) {
      const go = el("button", "tiny", "▶ work on this"); go.type = "button"; go.title = "Start the timer on this task";
      go.onclick = (e) => {
        e.preventDefault();   // the row is a label: do not tick the checkbox
        const st = data.work.status, project = plainTitle(t.content);
        if (st && st.state === "working" && st.block) act(() => call("PUT", "/api/blocks/" + st.block.id, { project, require_open: true }));
        else act(() => { const body = pendingType ? { project, type: pendingType } : { project }; pendingType = null; return call("POST", "/api/start", body); });
      };
      row.appendChild(go);
    }
    if (t.pending) row.appendChild(el("span", "pill", "pending"));
    if (t.priority === 4) row.appendChild(el("span", "pill red", "P1"));
    if ((t.labels || []).includes("doubt")) row.appendChild(el("span", "pill amber", "doubt"));
    return row;
  }

  function renderTraining(d) {
    const body = $("training-body");
    const pill = $("training-pill");
    body.replaceChildren();
    if (!d.training) { pill.hidden = true; body.appendChild(el("p", "hint", "Rest day, nothing planned.")); return; }
    const t = d.training;
    pill.hidden = !t.easy_week; pill.textContent = "easy week";
    const row = el("div", "item");
    row.appendChild(el("span", "t", t.time));
    const b = el("div", "grow");
    b.appendChild(el("div", "title", `${t.session}${t.distance_km ? ` · ${t.distance_km} km` : ""}`));
    b.appendChild(el("div", "hint", t.block_state ? `block ${t.block_state}` : "no block yet (Sunday proposes one)"));
    row.appendChild(b);
    const mv = el("a", "small btn", "Move"); mv.href = `/move?kind=run&date=${d.date}`; mv.title = "Move the run: see where it fits";
    row.appendChild(mv);
    body.appendChild(row);
  }

  function renderWork(d) {
    const w = d.work, s = w.status || {};
    $("week-line").textContent = `week ${h2(w.week_h)} of ${w.band[0]}–${w.band[1]} h`;
    const state = w.status ? (s.state || "stopped") : "none";
    document.querySelector(".timer-row").hidden = !w.status;
    $("timer-dot").className = "dot " + state;
    $("timer-line").textContent = state === "working" ? `Working${s.block && s.block.type ? " · " + s.block.type : ""}${s.block && s.block.project ? " · " + s.block.project : ""} · since ${s.since || ""}`
      : state === "break" ? `Break · since ${s.since || ""}` : "Not working";
    renderChips(d);
    $("day-start").hidden = state === "working";
    $("day-pause").hidden = state !== "working";
    $("day-stop").hidden = state === "stopped";
    const expected = (s.today && s.today.expected_h) || 0;
    const pct = expected && w.today_h != null ? Math.min(100, (w.today_h / expected) * 100) : 0;
    $("hours-bar").style.width = pct + "%";
    const over = s.state === "working" && s.past_stop_min > 0;
    $("work").classList.toggle("over", over);
    const left = over ? `past your ${w.hard_stop} stop by ${h2(s.past_stop_min / 60)}` : w.left_before_stop_h == null ? "work calendar unknown, hours left not computed" : `about ${h2(w.left_before_stop_h)} left before the ${w.hard_stop} stop`;
    $("hours-line").textContent = (w.today_h != null ? `Today ${h2(w.today_h)}${expected ? ` of ${h2(expected)}` : ""} · ` : "") + left;
    const top = $("top3"); top.replaceChildren();
    if (!w.top3.length) top.appendChild(el("p", "hint", "No work tasks due today."));
    for (const t of w.top3) top.appendChild(taskRow(t));
    const ms = $("milestones"); ms.replaceChildren();
    if (!w.milestones.length) ms.appendChild(el("p", "hint", "No dated milestones (label them `milestone` in Todoist)."));
    for (const m of w.milestones) {
      const row = el("div", "item ms");
      const mt = el("span", "grow"); mt.appendChild(window.mdlite ? mdlite.toNodes(m.content) : document.createTextNode(m.content));
      row.appendChild(mt);
      row.appendChild(el("span", "hint", m.due ? `${fmtDate(m.due)} · ${m.days_left} d` : ""));
      ms.appendChild(row);
    }
  }

  function renderChips(d) {
    const box = $("day-chips"), s = (d.work && d.work.status) || null;
    box.replaceChildren();
    box.hidden = !d.is_today || !s || !s.chips;
    if (box.hidden) return;
    const working = s.state === "working";
    if (working) pendingType = null;
    for (const name of (s.chips.types || []).slice(0, 6)) {
      const on = working ? !!(s.block && s.block.type === name) : pendingType === name;
      const b = el("button", "chip" + (on ? " on" : ""), name); b.type = "button";
      b.onclick = () => {
        if (working) act(() => call("PUT", "/api/blocks/" + s.block.id, { type: name, require_open: true }));
        else { pendingType = pendingType === name ? null : name; renderChips(d); }
      };
      box.appendChild(b);
    }
  }

  function renderQueue(d) {
    const card = $("queue-card"), list = $("queue");
    list.replaceChildren();
    card.hidden = !d.queue.length;
    for (const q of d.queue) {
      const row = el("div", "item");
      row.appendChild(el("span", "grow", q.line));
      row.appendChild(el("span", "pill " + (q.status === "failed" ? "red" : ""), q.status === "failed" ? `failed: ${q.error}` : "pending"));
      if (q.status === "failed") {
        const r = el("button", "tiny", "Retry"); r.type = "button"; r.onclick = () => act(() => call("POST", `/api/balance/queue/${q.id}/retry`));
        const x = el("button", "tiny", "Dismiss"); x.type = "button"; x.onclick = () => act(() => call("POST", `/api/balance/queue/${q.id}/dismiss`));
        row.append(r, x);
      }
      list.appendChild(row);
    }
  }

  // ---- wiring ---------------------------------------------------------------
  function go(next) { date = next; const u = new URL(location.href); if (next) u.searchParams.set("date", next); else u.searchParams.delete("date"); history.replaceState(null, "", u); load(); }
  document.addEventListener("DOMContentLoaded", () => {
    $("day-prev").onclick = () => go(shift(data ? data.date : new Date().toISOString().slice(0, 10), -1));
    $("day-next").onclick = () => go(shift(data ? data.date : new Date().toISOString().slice(0, 10), 1));
    $("day-today").onclick = () => go(null);
    $("day-refresh").onclick = () => act(() => call("POST", "/api/day/refresh"));
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
    for (const [id] of LANES) { const cb = $("lane-" + id); cb.checked = laneOn(id); cb.onchange = () => { setLane(id, cb.checked); if (data) renderTimeline(data); }; }
    PHONE.onchange = () => { if (data) renderTimeline(data); };
    $("day-start").onclick = () => act(() => { const body = pendingType ? { type: pendingType } : {}; pendingType = null; return call("POST", "/api/start", body); });
    $("day-pause").onclick = () => act(() => call("POST", "/api/pause", {}));
    $("day-stop").onclick = () => act(() => call("POST", "/api/stop", {}));
    load();
    timer = setInterval(load, 60000);
  });
})();
