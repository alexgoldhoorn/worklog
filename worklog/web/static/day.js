/* Day page: renders /api/day and drives the timer, prep notes, owner and task ticks.
   Everything from the API lands as text (textContent); never innerHTML with API strings. */
(() => {
  const $ = (id) => document.getElementById(id);
  const H0 = 6, H1 = 22, PX = 48;
  const LANES = [["work", "Work"], ["personal", "Personal"], ["family", "Family"], ["child", "Child"], ["blocks", "Week blocks"]];
  const laneOf = (ev) => ev.layer === "work" ? "work" : ev.layer === "protected" ? "blocks" : ev.layer === "duty" ? "child"
    : (ev.classification === "child" || ev.lane === "child") ? "child" : ev.lane === "family" ? "family" : "personal";
  const laneOn = (id) => { try { return localStorage.getItem("day.lane." + id) !== "0"; } catch (e) { return true; } };
  const setLane = (id, on) => { try { localStorage.setItem("day.lane." + id, on ? "1" : "0"); } catch (e) {} };
  const PHONE = window.matchMedia("(max-width: 700px)");
  let date = new URLSearchParams(location.search).get("date") || null;   // null = today
  let data = null;
  let timer = null;
  let pendingType = null;   // type chip picked while the timer is stopped; used by the next start
  const localIso = () => wl.today();   // the server's date (core.js), not the device's

  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const hm = (s) => { const [h, m] = String(s).split(":").map(Number); return h + m / 60; };
  const fmtDate = (iso) => wl.dayLabel(iso);   // "Tue 20 Oct"
  const h2 = (x) => { const m = Math.round(x * 60); return `${Math.floor(m / 60)} h ${String(m % 60).padStart(2, "0")}`; };
  const shift = (iso, days) => { const d = new Date(iso + "T00:00"); d.setDate(d.getDate() + days); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; };
  const notice = (text, cls = "") => { const p = el("p", cls, text); $("notices").replaceChildren(p); };
  // "Yesterday", "3 days ago", "In 2 days": where the shown day lies from today (the Qt app's Api.relDay)
  const relDay = (iso, today) => {
    const at = (s) => { const [y, m, d] = s.split("-").map(Number); return Date.UTC(y, m - 1, d); };
    const n = Math.round((at(iso) - at(today)) / 86400000);
    return n === 0 ? "Today" : n === -1 ? "Yesterday" : n === 1 ? "Tomorrow" : n < 0 ? `${-n} days ago` : `In ${n} days`;
  };
  // why the work calendar cannot be trusted for this day ("" when it can)
  const mirrorNote = (d) => d.mirror.unknown ? "Work calendar unknown for this day: the mirror's last import ends " + (d.mirror.last_import_end || "never") + ". Paste or import before trusting the free slots."
    : d.mirror.stale_days != null && d.mirror.stale_days > 7 ? `Work calendar PDF is ${d.mirror.stale_days} days old.` : "";
  // the Sync tab's label: what waits to be written, else that the work calendar is out of date
  const syncLabel = (d) => d.queue.length ? `Sync: ${d.queue.length}` : mirrorNote(d) ? "Sync: stale" : "Sync";

  const call = wl.call;
  const nextLoad = wl.sequence();

  async function load() {
    const current = nextLoad();
    try {
      const fresh = await call("GET", "/api/day" + (date ? "?date=" + date : ""));
      if (!current()) return;   // a newer load was started meanwhile: drop this answer
      data = fresh;
      $("notices").replaceChildren();
      render();
    } catch (e) { if (current()) notice("Could not load the day: " + e.message, "error"); }
  }

  async function act(fn) {
    try { await fn(); await load(); } catch (e) { await load(); notice(e.message, "error"); }
  }

  // "Only this one / Always for this title / Cancel": resolves "once", "always" or null (Esc and Cancel save nothing)
  function askClassify(title, who) {
    const dlg = $("classify-dialog");
    $("classify-title").textContent = `Mark "${title}" as ${who}?`;
    dlg.returnValue = "";
    return new Promise((resolve) => {
      // answer on the button press (submit), not on "close": the close event waits for a rendering frame and can lag a
      // second behind, which left the event looking unclassified after it was saved. Esc has no submit, so close covers it.
      const done = (v) => { dlg.removeEventListener("submit", onSubmit); dlg.removeEventListener("close", onClose); resolve(v === "once" || v === "always" ? v : null); };
      const onSubmit = (e) => done(e.submitter ? e.submitter.value : "");
      const onClose = () => done(dlg.returnValue);
      dlg.addEventListener("submit", onSubmit);
      dlg.addEventListener("close", onClose);
      dlg.showModal();
    });
  }

  // ---- render ---------------------------------------------------------------
  function render() {
    const d = data;
    $("day-title").textContent = fmtDate(d.date);
    $("day-sub").textContent = relDay(d.date, localIso());
    const full = d.sync && (d.sync.full_ran || d.sync.ran);
    $("sync-line").textContent = full ? `snapshots ${String(full).replace("T", " ").slice(0, 16)} · google ${d.sync.google || "?"}` : "no snapshots yet";
    // the three parts (Day · Work · Sync, switched by core.js) show once there is a day to show
    $("views").hidden = false; $("day-body").hidden = false;
    $("view-sync").textContent = syncLabel(d);
    const brand = $("brand-dot"); if (brand) brand.className = "dot " + (d.capacity.colour || "");

    const cap = $("capacity");
    cap.hidden = !d.capacity.show;
    cap.className = "capacity " + d.capacity.colour;
    const line = String(d.capacity.line || "").replace(/^[^A-Za-z]*Capacity:\s*\w+\.\s*/, "");
    cap.replaceChildren(el("strong", "kw", `Load: ${d.capacity.colour}`), el("span", "", line ? " · " + line : ""));

    renderTimeline(d);
    renderMirror(d);
    renderFirst(d);
    renderTraining(d);
    renderWork(d);
    renderQueue(d);
    // the day in three figures (they were the counts line at the foot)
    const c = d.counts;
    $("tile-meetings").textContent = c.meetings_left == null ? "–" : String(c.meetings_left);
    $("tile-tasks").textContent = `${c.done} / ${c.done + c.todo}`;
    const cn = $("classify-note");
    cn.hidden = !c.unclassified;
    cn.textContent = c.unclassified ? (c.unclassified === 1 ? "1 family event to classify" : `${c.unclassified} family events to classify`) : "";
  }

  function renderTimeline(d) {
    const note = $("mirror-note");
    note.textContent = mirrorNote(d);
    note.hidden = !note.textContent;
    const tl = $("timeline");
    tl.replaceChildren();
    const now = d.now;
    const height = (H1 - H0) * PX;
    const on = LANES.filter(([id]) => laneOn(id));
    const hh = d.household || {};
    const laneName = (id, name) => id === "child" && hh.child ? hh.child : name;
    const ln = $("lane-child"); if (ln && hh.child) ln.textContent = hh.child;
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
        if (ev.layer === "duty") label += ev.owner ? ` · ${ev.owner}` : " · who does it?";
        if (ev.layer === "personal" && ev.classification === "unclassified") label += " · whose is it?";
        if (ev.layer === "personal" && ev.creator_name && ev.lane !== "personal") label += ` · by ${ev.creator_name}`;
        if (ev.layer === "work" && ev.source && ev.source !== "pdf" && !/\.pdf$/i.test(ev.source)) label += ` · added by ${ev.source}`;
        if (ev.layer === "protected") label += ` · ${ev.state}`;
        if (ev.pending) label += " · waiting to sync";
        box.appendChild(el("span", "", label));
        if (ev.layer === "personal" && ev.lane === "family" && ev.classification !== "unclassified" && !ev.pending) {
          const chg = el("button", "tiny", "Whose?"); chg.type = "button"; chg.setAttribute("aria-label", `Change whose "${ev.title}" is`);
          chg.onclick = () => { ev.classification = "unclassified"; renderTimeline(d); };
          box.appendChild(chg);
        }
        if (ev.layer === "personal" && ev.classification === "unclassified" && !ev.pending) {
          const hh = d.household || { me: "me", partner: "partner", child: "child" };
          const who = el("span", "btns");
          for (const [cls, text] of [["mine", "me"], ["family", "us"], ["partner", hh.partner], ["child", hh.child]]) {
            const b = el("button", "tiny", text); b.type = "button"; b.title = "whose is this?";
            b.setAttribute("aria-label", `${text}: whose is "${ev.title}"?`);
            b.onclick = async () => {
              const choice = await askClassify(ev.title, text);
              if (!choice) return;
              // show the answer at once: the server stores it before it replies, so the reload that follows only confirms it.
              // nextLoad() drops a slower reload that was already on its way with the old state; a failed save reloads the truth.
              nextLoad();
              ev.classification = cls; renderTimeline(d);
              act(() => call("POST", "/api/day/classify", { date: d.date, start: ev.start, title: ev.title, cls, always: choice === "always" }));
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
          lg.onclick = (e) => wl.locked(e.currentTarget, () => act(() => call("POST", "/api/calendar/add", { date: d.date, start: ev.start, end: ev.end, title: ev.title })));
          box.appendChild(lg);
        }
        if (ev.layer === "protected" && ev.state === "approved" && ev.id) {
          const mv = el("a", "tiny btn", "Move"); mv.href = `/move?kind=${ev.kind === "run" ? "run" : "block"}&date=${d.date}&id=${ev.id}`;
          box.appendChild(mv);
        }
        if (ev.layer === "protected" && ev.state === "proposed") {
          const b = el("span", "btns");
          const ok = el("button", "tiny", "✓"); ok.type = "button"; ok.title = "Approve"; ok.setAttribute("aria-label", `Approve ${ev.start}–${ev.end} ${ev.title}`);
          ok.onclick = (e) => wl.locked([ok, no], () => act(() => call("POST", `/api/balance/blocks/${ev.id}/approve`)));
          const no = el("button", "tiny", "✗"); no.type = "button"; no.title = "Reject"; no.setAttribute("aria-label", `Reject ${ev.start}–${ev.end} ${ev.title}`);
          no.onclick = () => wl.locked([ok, no], () => act(() => call("POST", `/api/balance/blocks/${ev.id}/reject`)));
          b.append(ok, no); box.appendChild(b);
        }
        if (ev.layer === "duty") {
          const hh = d.household || { me: "me", partner: "partner" };
          const mine = ev.owner === hh.me;
          const flip = el("button", "tiny", mine ? `${hh.partner} takes it` : "I take it"); flip.type = "button";
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
    if (!d.first_things.length) list.appendChild(el("p", "hint", "Nothing first up."));
    for (const x of d.first_things) {
      const row = el("div", "item");
      if (x.kind === "duty") {
        row.appendChild(el("span", "t", x.at));
        const body = el("div", "grow");
        body.appendChild(el("div", "title", `${x.title} · ${x.owner || "who does it?"}`));
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

  // the prep note of a meeting: minutes (0–480) and what to prepare, as the Qt app's dialog. Cancel and Esc save nothing.
  function promptPrep(d, meeting) {
    const dlg = $("prep-dialog");
    $("prep-title").textContent = `Prep for ${meeting.title}`;
    $("prep-minutes").value = meeting.prep ? meeting.prep.minutes : 30;
    $("prep-text").value = meeting.prep ? meeting.prep.text || "" : "";
    $("prep-problem").hidden = true;
    $("prep-cancel").onclick = () => dlg.close();
    dlg.querySelector("form").onsubmit = (e) => {
      const minutes = wl.parseNum($("prep-minutes").value);
      if (!(minutes >= 0 && minutes <= 480)) { e.preventDefault(); $("prep-problem").hidden = false; return; }
      const text = $("prep-text").value.trim();
      act(() => call("POST", "/api/day/prep", { date: d.date, start: meeting.start, title: meeting.title, minutes: Math.round(minutes), text }));
    };
    dlg.showModal();
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
    const pill = (cls, text, tip) => { const p = el("span", cls, text); p.title = tip; row.appendChild(p); };
    if (t.pending) pill("pill", "waiting to sync", "Ticked here; not written to Todoist yet");
    if (t.priority === 4) pill("pill red", "P1", "Todoist priority 1");
    if ((t.labels || []).includes("doubt")) pill("pill amber", "doubt", "Todoist label \"doubt\": needs a decision");
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
    $("week-v").textContent = h2(w.week_h);
    $("week-s").textContent = `normal ${w.band[0]}–${w.band[1]} h`;
    const state = w.status ? (s.state || "stopped") : "none";
    $("timer-dot").className = "dot " + state;
    $("timer-line").textContent = state === "working" ? `Working${s.block && s.block.type ? " · " + s.block.type : ""}${s.block && s.block.project ? " · " + s.block.project : ""} · since ${s.since || ""}`
      : state === "break" ? `Break · since ${s.since || ""}` : "Not working";
    renderChips(d);
    $("day-start").hidden = state === "working";
    $("day-start").textContent = state === "break" ? "Resume" : "Start";
    $("day-pause").hidden = state !== "working";
    $("day-stop").hidden = state === "stopped";
    const expected = (s.today && s.today.expected_h) || 0;
    const pct = expected && w.today_h != null ? Math.min(100, (w.today_h / expected) * 100) : 0;
    $("hours-bar").style.width = pct + "%";
    const over = s.state === "working" && s.past_stop_min > 0;
    // the timer is the hero of the Work part, tinted by its state as on the Timer page; no status, no hero
    const hero = $("work");
    hero.hidden = !w.status;
    hero.className = "hero " + (over ? "over" : state === "none" ? "stopped" : state);
    // the tiles: today (also on the Day part), what is left before the stop, the week
    const today = w.today_h != null ? h2(w.today_h) : "–", of = expected ? `of ${h2(expected)}` : "";
    $("hours-today").textContent = today; $("hours-of").textContent = of;
    $("tile-worked").textContent = today; $("tile-worked-of").textContent = of;
    $("tile-worked").classList.toggle("over", over);
    $("stop-tile").classList.toggle("over", over);
    $("stop-k").textContent = over ? "Past stop" : "Before stop";
    $("stop-v").textContent = over ? h2(s.past_stop_min / 60) : w.left_before_stop_h == null ? "–" : h2(w.left_before_stop_h);
    $("stop-s").textContent = !over && w.left_before_stop_h == null ? "work calendar unknown" : `stop ${w.hard_stop}`;
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
    const list = $("queue");
    list.replaceChildren();
    if (!d.queue.length) list.appendChild(el("p", "hint", "Nothing waiting."));
    for (const q of d.queue) {
      const row = el("div", "item");
      row.appendChild(el("span", "grow", q.line));
      row.appendChild(el("span", "pill " + (q.status === "failed" ? "red" : ""), q.status === "failed" ? `failed: ${q.error}` : "waiting to sync"));
      if (q.status === "failed") {
        const r = el("button", "tiny", "Retry"); r.type = "button"; r.onclick = () => act(() => call("POST", `/api/balance/queue/${q.id}/retry`));
        const x = el("button", "tiny ghost", "Dismiss"); x.type = "button"; x.onclick = () => act(() => call("POST", `/api/balance/queue/${q.id}/dismiss`));
        row.append(r, x);
      }
      list.appendChild(row);
    }
  }

  // ---- wiring ---------------------------------------------------------------
  function go(next) { date = next; const u = new URL(location.href); if (next) u.searchParams.set("date", next); else u.searchParams.delete("date"); history.replaceState(null, "", u); load(); }
  document.addEventListener("DOMContentLoaded", () => {
    $("day-prev").onclick = () => go(shift(data ? data.date : wl.today(), -1));
    $("day-next").onclick = () => go(shift(data ? data.date : wl.today(), 1));
    $("day-today").onclick = () => go(null);
    $("day-refresh").onclick = (e) => wl.locked(e.currentTarget, () => act(() => call("POST", "/api/day/refresh")));
    $("pdf-file").onchange = async () => {
      const f = $("pdf-file").files[0]; if (!f) return;
      const fd = new FormData(); fd.append("file", f);
      try {
        const out = await call("POST", "/api/day/calendar-pdf", fd);
        notice(`Saved ${out.saved}: ${out.note}.`, "ok");
      } catch (e) { notice("Upload failed: " + e.message, "error"); }
      $("pdf-file").value = "";
    };
    // the lane chips: each calendar can be switched off (kept on this device)
    for (const [id] of LANES) {
      const chip = $("lane-" + id);
      const paint = () => { const on = laneOn(id); chip.classList.toggle("on", on); chip.setAttribute("aria-pressed", String(on)); };
      paint();
      chip.onclick = () => { setLane(id, !laneOn(id)); paint(); if (data) renderTimeline(data); };
    }
    PHONE.onchange = () => { if (data) renderTimeline(data); };
    $("day-start").onclick = (e) => wl.locked(e.currentTarget, () => act(() => { const body = pendingType ? { type: pendingType } : {}; pendingType = null; return call("POST", "/api/start", body); }));
    $("day-pause").onclick = (e) => wl.locked(e.currentTarget, () => act(() => call("POST", "/api/pause", {})));
    $("day-stop").onclick = (e) => wl.locked(e.currentTarget, () => act(() => call("POST", "/api/stop", {})));
    wl.ensureClock().then(() => { load(); timer = setInterval(load, 60000); });
  });
})();
