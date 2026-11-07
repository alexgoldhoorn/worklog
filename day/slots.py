"""The slot engine: where an item (a run, a gym visit, a meeting, a personal activity) fits
on a set of days, scored against everything the day model knows, with reasons in plain words.

Pure: `find(item, days, settings, rules, today)` takes the per-date dicts from
`day.model.build_days` and returns ranked `Slot`s. The page, an optional host tool and the tests all
call this one function, so they rank alike."""
from dataclasses import asdict, dataclass, field
from datetime import date as _date, timedelta

VERDICT_ORDER = {"fits": 0, "tight": 1, "unknown": 2, "clash": 3, "ask_trainer": 4}
HARD_TYPES = {"intervals", "tempo", "race", "long"}


@dataclass
class Item:
    title: str
    minutes: int
    kind: str = "personal"                 # run | gym | meeting | personal | work
    travel_before: int = 0
    travel_after: int = 0
    prefer: list = field(default_factory=list)   # morning | afternoon | evening | not_school_runs
    ref: dict | None = None                # the occurrence being moved, if any


@dataclass
class Slot:
    date: str
    start: str
    end: str
    verdict: str
    reasons: list = field(default_factory=list)
    best: bool = False
    changes: list = field(default_factory=list)

    def as_dict(self) -> dict:
        return asdict(self)


def _hm(s: str) -> int:
    h, m = s.split(":")
    return int(h) * 60 + int(m)


def _fmt(m: int) -> str:
    return f"{m // 60:02d}:{m % 60:02d}"


def _overlap(a0, a1, b0, b1) -> bool:
    return a0 < b1 and b0 < a1


def _is_ref(ev: dict, item: Item, date: str) -> bool:
    r = item.ref
    if not r or r.get("date") != date:
        return False
    if r.get("kind") == "run":
        return ev["layer"] == "protected" and ev.get("kind") == "run"
    if r.get("kind") == "block":
        return ev["layer"] == "protected" and ev.get("id") == r.get("block_id")
    if r.get("kind") == "personal":
        return ev["layer"] == "personal" and ev.get("uid") and ev.get("uid") == r.get("uid")
    return False


def _busy(day: dict, item: Item, me: str) -> tuple[list[dict], list[dict]]:
    """(hard busy events, Sam-owned duties) for one day, the item's own occurrence left out."""
    busy, duties, soft = [], [], []
    child_mine = any(e["layer"] == "duty" and e.get("owner") == me for e in day["timeline"])
    for e in day["timeline"]:
        if _is_ref(e, item, day["date"]):
            continue
        if e["layer"] == "work" and not e.get("cancelled"):
            busy.append(e)
        elif e["layer"] == "protected" and e.get("state") in ("approved", "proposed", None):
            busy.append(e)
        elif e["layer"] == "personal":
            cls = e.get("classification", "mine")
            if cls in ("mine", "family") or e.get("pending") or (cls == "child" and child_mine):
                busy.append(e)
            elif cls == "unclassified":
                soft.append(e)
        elif e["layer"] == "duty":
            if e.get("owner") == me:
                duties.append(e)
    return busy, duties, soft


def _work_days(lo: _date, hi: _date, client_holidays: dict | None) -> int:
    n, d = 0, lo
    while d <= hi:
        if d.weekday() < 5 and d.isoformat() not in (client_holidays or {}):
            n += 1
        d += timedelta(days=1)
    return n


def work_share(day: dict, settings: dict, today: str, client_holidays: dict | None = None) -> float:
    """Hours each remaining work day of the week must deliver to reach the band's floor:
    this ISO week = (floor − hours already worked) ÷ work days left from today; a later week =
    floor ÷ that week's work days. The same number for every day of a week, never inflating."""
    floor = float(settings.get("week_hours_min", 30))
    d = _date.fromisoformat(day["date"])
    t = _date.fromisoformat(today)
    monday = d - timedelta(days=d.weekday())
    friday = monday + timedelta(days=4)
    if monday <= t <= friday + timedelta(days=2):          # the current week
        done = float(day["work"].get("week_h") or 0.0)
        left = _work_days(max(t, monday), friday, client_holidays)
        return max(0.0, floor - done) / max(1, left)
    return floor / max(1, _work_days(monday, friday, client_holidays))


def _work_window(day: dict, slot_start: int, slot_end: int, busy: list[dict], settings: dict, share_h: float, rules: dict,
                 now_m: int | None = None):
    """None when the slot is outside work hours or the day is no work day; else (free_h_left, share_h).
    On today the free time counts from now, not from the start of the work window."""
    hard_stop = _hm(day["work"].get("hard_stop") or settings.get("hard_stop", "18:00"))
    w0 = _hm(rules.get("slots", {}).get("work_start", "08:30"))
    if now_m is not None:
        w0 = max(w0, now_m)
    if not day.get("work_day") or not _overlap(slot_start, slot_end, w0, hard_stop):
        return None
    taken = sum(max(0, min(_hm(e["end"]), hard_stop) - max(_hm(e["start"]), w0)) for e in busy if e["layer"] == "work")
    slot_in = max(0, min(slot_end, hard_stop) - max(slot_start, w0))
    free = (hard_stop - w0 - taken - slot_in) / 60
    return free, share_h


def _plan_type(day: dict) -> str:
    t = day.get("training") or {}
    return t.get("type") or "rest"


def _evaluate(item: Item, day: dict, days: dict, settings: dict, rules: dict, start: int, me: str,
              busy: list[dict], duties: list[dict], share_h: float, pre_event: dict | None,
              soft: list[dict] | None = None, now_m: int | None = None) -> Slot:
    cfg = rules.get("slots", {})
    margin = int(cfg.get("travel_margin_min", 15))
    end = start + item.minutes
    w0, w1 = start - item.travel_before, end + item.travel_after
    reasons: list[str] = []
    verdict = "fits"

    clash = [e for e in busy if _overlap(w0, w1, _hm(e["start"]), _hm(e["end"]))]
    clash += [d for d in duties if _overlap(w0, w1, _hm(d["start"]), _hm(d["end"]))]
    if clash:
        verdict = "clash"
        reasons.append("clashes with " + ", ".join(f"{e['title']} {e['start']}" + (" (pending)" if e.get("pending") else "") for e in clash[:3]))
    else:
        if day["mirror"].get("unknown"):
            verdict = "unknown"
            reasons.append("work calendar unknown for this day")
        for e in (soft or []):
            if _overlap(w0, w1, _hm(e["start"]), _hm(e["end"])):
                verdict = _worse(verdict, "tight")
                reasons.append(f"Family event {e['title']} {e['start']}, may not need you")
                break
        for d in duties:
            gap = _hm(d["start"]) - w1
            if 0 <= gap < margin:
                verdict = _worse(verdict, "tight")
                reasons.append(f"ends {gap} min before {d['title'].lower()} at {d['at']}")
        if item.kind in ("run", "gym", "personal"):
            ww = _work_window(day, w0, w1, busy, settings, share_h, rules, now_m)
            if ww is not None:
                free, share = ww
                tol = float(cfg.get("work_share_tolerance_h", 0.5))
                if free + tol < share:
                    verdict = _worse(verdict, "tight")
                    reasons.append(f"{free:.1f} h of work left before the stop, the day's share is {share:.1f} h")
                else:
                    reasons.append(f"{free:.1f} h of work still fits before the {day['work'].get('hard_stop', '18:00')} stop")
        hard_stop = _hm(day["work"].get("hard_stop") or "18:00")
        if item.kind in ("run", "gym") and start >= hard_stop:
            if day["capacity"].get("colour") == "red":
                verdict = _worse(verdict, "tight")
                reasons.append("gate is red: no evening sessions this week")
            if pre_event and item.minutes >= 90:
                verdict = _worse(verdict, "tight")
                reasons.append(f"{pre_event.get('title', 'event')} in {pre_event.get('days')} days: keep long sessions out of the evening")
        if item.kind == "run":
            ptype = _plan_type(day)
            if ptype == "rest" and (item.ref or {}).get("date") != day["date"]:
                verdict = _worse(verdict, "tight")
                reasons.append("rest day in the plan")
            plan_types = day.get("plan_types") or {}
            moved_type = plan_types.get((item.ref or {}).get("date", ""), "") if item.ref else ("long" if item.minutes >= 90 else "easy")
            if moved_type in HARD_TYPES:
                d = _date.fromisoformat(day["date"])
                for other in (d - timedelta(days=1), d + timedelta(days=1)):
                    if other.isoformat() != (item.ref or {}).get("date") and plan_types.get(other.isoformat()) in HARD_TYPES:
                        verdict = _worse(verdict, "tight")
                        reasons.append(f"consecutive hard sessions with {other.strftime('%a')}")
                        break
    return Slot(date=day["date"], start=_fmt(start), end=_fmt(end), verdict=verdict, reasons=reasons,
                changes=_changes(item, day["date"], _fmt(start), _fmt(end)))


def _worse(a: str, b: str) -> str:
    return a if VERDICT_ORDER[a] >= VERDICT_ORDER[b] else b


def _changes(item: Item, date: str, start: str, end: str) -> list[dict]:
    r = item.ref
    if not r:
        return []
    if r.get("kind") == "run":
        out = [{"kind": "session_time", "date": r.get("date", date), "session": r.get("session", item.title), "start": start, "end": end}]
        if r.get("block_id"):
            out.append({"kind": "block_move", "block_id": r["block_id"], "date": date, "start": start, "end": end})
        return out
    if r.get("kind") == "block":
        return [{"kind": "block_move", "block_id": r.get("block_id"), "date": date, "start": start, "end": end}]
    if r.get("kind") == "personal":
        from . import rules as _rules
        default_cal = _rules.household(_rules.load())["calendars"]["personal"]
        return [{"kind": "gcal_update", "calendar": r.get("calendar") or default_cal, "uid": r.get("uid"),
                 "orig_date": r.get("date"), "orig_start": r.get("start"), "date": date, "start": start, "end": end}]
    return []


def _prefers(item: Item, start: int, end: int, day: dict) -> bool:
    p = set(item.prefer or [])
    if "morning" in p and not start < 12 * 60:
        return False
    if "afternoon" in p and not (12 * 60 <= start < 18 * 60):
        return False
    if "evening" in p and not start >= 18 * 60:
        return False
    if "not_school_runs" in p:
        for e in day["timeline"]:
            if e["layer"] == "duty" and _overlap(start, end, _hm(e["start"]), _hm(e["end"])):
                return False
    return True


def find(item: Item, days: dict[str, dict], settings: dict, rules: dict, today: str, now: str | None = None,
         client_holidays: dict | None = None) -> list[Slot]:
    """`now` (HH:MM) hides slots already past on `today` and counts today's free work time from now."""
    cfg = rules.get("slots", {})
    step = int(cfg.get("step_min", 15))
    d0, d1 = _hm(cfg.get("day_start", "06:30")), _hm(cfg.get("day_end", "21:30"))
    from . import rules as _rules
    me = _rules.household(rules)["me"]
    out: list[Slot] = []
    current: Slot | None = None
    dates = sorted(days)
    now_m = _hm(now) if now else None
    for date in dates:
        day = days[date]
        busy, duties, soft = _busy(day, item, me)
        share_h = work_share(day, settings, today, client_holidays)
        pre_event = (day.get("capacity") or {}).get("pre_event")
        today_now = now_m if (date == today and now_m is not None) else None
        first = d0
        if today_now is not None:
            first = max(d0, ((today_now + step - 1) // step) * step)
        starts = list(range(first, d1 - item.minutes + 1, step))
        ref_start = _hm(item.ref["start"]) if item.ref and item.ref.get("date") == date and item.ref.get("start") else None
        if ref_start is not None and ref_start not in starts:
            starts.append(ref_start)
        for start in starts:
            end = start + item.minutes
            if not _prefers(item, start, end, day) and start != ref_start:
                continue
            slot = _evaluate(item, day, days, settings, rules, start, me, busy, duties, share_h, pre_event, soft, today_now)
            if ref_start is not None and start == ref_start:
                slot.reasons.insert(0, "current slot")
                slot.changes = []
                current = slot
            else:
                out.append(slot)
    out.sort(key=lambda s: (VERDICT_ORDER[s.verdict], len(s.reasons), s.date, s.start))
    for s in out:
        if s.verdict in ("fits", "tight"):
            s.best = True
            break
    if item.kind == "run" and item.ref and item.ref.get("date"):
        nd = (_date.fromisoformat(item.ref["date"]) + timedelta(days=1)).isoformat()
        st = item.ref.get("start", "07:30")
        out.append(Slot(date=nd, start=st, end=_fmt(_hm(st) + item.minutes), verdict="ask_trainer",
                        reasons=["tomorrow, same time: a date change is the trainer's call"], changes=[]))
    return ([current] if current else []) + out
