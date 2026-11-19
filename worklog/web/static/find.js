/* Add or find a date. "Find a time": what / how long / travel / when / goes in → /api/day/slots, pick,
   then /api/day/find. "I know when": the typed date and times go straight to /api/day/find.
   The form is the /find page and also the Day page's dialog (templates/_find.html). */
(() => {
  const $ = (id) => document.getElementById(id);
  const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text != null) e.textContent = text; return e; };
  const fmtDate = (iso) => new Date(iso + "T00:00").toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" });
  const notice = (text, cls = "") => { $("find-notices").replaceChildren(el("p", cls, text)); };
  let chosen = null, last = null, mode = "find", changed = false;

  async function call(method, url, body) {
    const r = await fetch(url, { method, headers: { "Content-Type": "application/json" }, body: body ? JSON.stringify(body) : undefined });
    const out = (r.headers.get("content-type") || "").includes("json") ? await r.json() : await r.text();
    if (!r.ok) throw new Error((out && out.error) || r.statusText);
    return out;
  }

  const groupValue = (name) => { const on = document.querySelector(`.chips[data-group="${name}"] .chip.on`); return on ? on.dataset.v : null; };
  const multiValues = (name) => [...document.querySelectorAll(`.chips[data-group="${name}"] .chip.on`)].map((c) => c.dataset.v);

  function wireChips() {
    for (const group of document.querySelectorAll("#find-root .chips")) {
      const multi = group.classList.contains("multi");
      for (const chip of group.querySelectorAll(".chip")) {
        chip.onclick = () => {
          if (multi) chip.classList.toggle("on");
          else { for (const c of group.querySelectorAll(".chip")) c.classList.remove("on"); chip.classList.add("on"); }
          if (group.dataset.group === "target") $("todoist-fields").hidden = groupValue("target") !== "todoist";
          if (group.dataset.group === "mode") setMode(chip.dataset.v);
        };
      }
    }
  }

  // "add": the date and times are typed; "find": the server looks for a time
  function setMode(m) {
    mode = m === "add" ? "add" : "find";
    $("find-root").classList.toggle("add-mode", mode === "add");
    for (const c of document.querySelectorAll('.chips[data-group="mode"] .chip')) c.classList.toggle("on", c.dataset.v === mode);
    $("find-title").textContent = mode === "add" ? "Add to a calendar" : "Find a date";
    $("find-sub").textContent = mode === "add" ? "A meeting or appointment at a time you already know"
                                                : "Dentist, gym, a run, a call: say what, it finds when";
    $("find-submit").textContent = mode === "add" ? "Add" : "Find";
    $("find-submit").disabled = false;
    $("put").hidden = true;
    $("put-paste").hidden = true;
    $("find-notices").replaceChildren();
    chosen = null;
  }

  const minutesBetween = (a, b) => (Number(b.slice(0, 2)) * 60 + Number(b.slice(3, 5))) - (Number(a.slice(0, 2)) * 60 + Number(a.slice(3, 5)));

  function itemFromForm() {
    const target = groupValue("target");
    const kind = target === "training" ? "gym" : target === "work" ? "work" : "personal";
    if (mode === "add")
      return { title: $("f-what").value.trim(), minutes: Math.max(5, minutesBetween($("f-start").value, $("f-end").value)), kind,
               travel_before: 0, travel_after: 0, prefer: [] };
    return { title: $("f-what").value.trim(), minutes: Number(groupValue("minutes")), kind,
             travel_before: Number(groupValue("travel")), travel_after: Number(groupValue("travel")), prefer: multiValues("prefer") };
  }

  function addDays(iso, n) { const d = new Date(iso + "T00:00"); d.setDate(d.getDate() + n); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; }
  const today = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`; };

  async function find(ev) {
    ev.preventDefault();
    if (mode === "add") { add(); return; }
    const item = itemFromForm();
    if (!item.title) { notice("Say what it is first.", "error"); return; }
    const from = today(), to = addDays(from, Number(groupValue("when")) - 1);
    try {
      last = await call("POST", "/api/day/slots", { item, from, to });
      $("find-notices").replaceChildren();
      renderOptions(last, item);
    } catch (e) { notice(e.message, "error"); }
  }

  // "I know when": no search, the typed date and times go straight in
  function add() {
    const date = $("f-date").value, start = $("f-start").value, end = $("f-end").value;
    if (!$("f-what").value.trim()) { notice("Say what it is first.", "error"); return; }
    if (!date || !start || !end || !(start < end)) { notice("Give a date, a start and a later end time.", "error"); return; }
    chosen = { date, start, end };
    $("put").hidden = false;
    $("put-line").textContent = `${$("f-what").value.trim()} on ${fmtDate(date)} ${start}–${end} → ${targetText()}`;
    put();
  }

  function renderOptions(data, item) {
    const list = $("options");
    list.replaceChildren();
    $("put").hidden = true;
    chosen = null;
    // one option per day: the best slot of that day, best days first
    const perDay = new Map();
    for (const s of data.slots) {
      if (s.verdict === "clash" || s.verdict === "ask_trainer") continue;
      if (!perDay.has(s.date)) perDay.set(s.date, s);
    }
    const options = [...perDay.values()].slice(0, 8);
    if (!options.length) { list.appendChild(el("p", "hint", "Nothing fits in that range without a clash. Try a longer range or fewer preferences.")); return; }
    for (const s of options) {
      const row = el("div", "slot " + s.verdict + (s.best ? " best" : ""));
      row.appendChild(el("span", "sdot " + s.verdict));
      const body = el("div", "grow");
      const head = el("div", "row-wrap");
      head.appendChild(el("span", "title", `${fmtDate(s.date)} · ${s.start}–${s.end}`));
      if (s.best) head.appendChild(el("span", "pill", "best"));
      if (s.verdict === "unknown") head.appendChild(el("span", "pill amber", "work calendar unknown"));
      body.appendChild(head);
      body.appendChild(el("div", "hint", s.reasons.join(" · ") || "fits"));
      row.appendChild(body);
      const b = el("button", "tiny", "Pick"); b.type = "button";
      b.onclick = () => { chosen = s; $("put").hidden = false; $("put-paste").hidden = true; $("put-btn").disabled = false;
        $("put-line").textContent = `${item.title} on ${fmtDate(s.date)} ${s.start}–${s.end} → ${targetText()}`; };
      row.appendChild(b);
      list.appendChild(row);
    }
    const unknownDays = Object.entries(data.days).filter(([, v]) => v.unknown).map(([d]) => fmtDate(d));
    if (unknownDays.length) list.appendChild(el("p", "hint", "Work calendar unknown on: " + unknownDays.join(", ") + ". Import the Outlook PDF before trusting those."));
  }

  const targetText = () => ({ personal: "your Personal Google calendar", family: "the Family Google calendar", work: "the work calendar mirror (paste the line into Outlook)",
                               training: "an approved training block", todoist: "a Todoist task" }[groupValue("target")]);

  async function put() {
    if (!chosen) return;
    const item = itemFromForm();
    const target = groupValue("target");
    const body = { item, date: chosen.date, start: chosen.start, end: chosen.end, target };
    if (target === "todoist") body.todoist = { project: $("f-project").value.trim(), priority: Number($("f-priority").value), due_string: chosen.date };
    try {
      const out = await call("POST", "/api/day/find", body);
      const bits = [];
      if (out.queued.length) bits.push("queued for the next sync (within 2 minutes)");
      if (out.blocks.length) bits.push("block approved");
      notice(`Put in: ${item.title}, ${fmtDate(chosen.date)} ${chosen.start}. ${bits.join(", ")}.`, "ok");
      if (out.paste) { $("put-paste").hidden = false; $("put-paste").textContent = out.paste; }
      $("put-btn").disabled = true;
      changed = true;
    } catch (e) { notice("Could not put it in: " + e.message, "error"); }
  }

  document.addEventListener("DOMContentLoaded", () => {
    if (!$("find-root")) return;
    wireChips();
    $("find-form").onsubmit = find;
    $("put-btn").onclick = put;
    const q = new URLSearchParams(location.search);
    if (q.get("what")) $("f-what").value = q.get("what");
    $("f-date").value = q.get("date") || today();
    setMode(q.get("mode") === "add" ? "add" : "find");

    // on the Day page the form is a dialog: Add and Find a date open it instead of leaving the page
    const dlg = $("find-dialog");
    if (!dlg || !dlg.showModal) return;
    const open = (m, ev) => {
      ev.preventDefault();
      setMode(m);
      $("f-date").value = new URLSearchParams(location.search).get("date") || today();
      dlg.showModal();
      $("f-what").focus();
    };
    if ($("day-find")) $("day-find").onclick = (ev) => open("find", ev);
    if ($("day-add")) $("day-add").onclick = (ev) => open("add", ev);
    $("find-close").onclick = () => dlg.close();
    dlg.addEventListener("close", () => { if (changed) location.reload(); });   // show what was put in
  });
})();
