"""The capacity gate: rule-based, no LLM, explainable.

evaluate() takes plain inputs (read by inputs.py on the host, or built in tests)
and returns a Verdict: a colour, the signals that fired in words, the data gaps,
one thing to protect, and whether today is a day the gate speaks.

Missing data never fires a signal. It is reported as a gap so a quiet gate on an
empty day cannot be mistaken for a green one.
"""
from __future__ import annotations

import statistics
from dataclasses import dataclass, field
from datetime import date, timedelta

GREEN, AMBER, RED = "green", "amber", "red"
WORK_SIGNALS = ("hours", "hours_trend", "evenings")
BODY_SIGNALS = ("rhr", "hrv", "sleep", "stress")
HEAVY = ("heavy", "crushing")
FELT_ANSWERS = ("light", "ok", "heavy", "crushing")


@dataclass
class Inputs:
    today: date
    work_hours: dict = field(default_factory=dict)      # date -> hours of work blocks
    evening_days: set = field(default_factory=set)      # dates with work past hard stop + grace
    wellness: list = field(default_factory=list)        # dicts: date, resting_hr, hrv, sleep_h, sleep_score, stress
    runs_planned: list = field(default_factory=list)    # dates (last 14 days)
    runs_done: list = field(default_factory=list)       # dates
    illness_open: bool = False
    felt: list = field(default_factory=list)            # dicts: date, answer
    events: list = field(default_factory=list)          # dicts: date, title, kind (race|travel)
    hard_stop: str = "18:00"
    gaps: list = field(default_factory=list)            # reader-reported gaps


@dataclass
class Verdict:
    colour: str
    signals: list            # [{name, text}]
    gaps: list
    protect: str
    speak: bool
    pre_event: dict | None
    numbers: dict
    today: str

    def as_dict(self) -> dict:
        return {"date": self.today, "colour": self.colour, "signals": self.signals,
                "gaps": self.gaps, "protect": self.protect, "speak": self.speak,
                "pre_event": self.pre_event, "numbers": self.numbers,
                "line": telegram_line(self)}


def _mean(xs):
    xs = [x for x in xs if x is not None]
    return (sum(xs) / len(xs)) if xs else None


def _window(rows, today, days, key="date"):
    lo = today - timedelta(days=days - 1)
    return [r for r in rows if lo <= r[key] <= today]


def _baseline(rows, today, rules, field_):
    # Ends `baseline_gap_days` ago so the last weeks being judged do not drag their own baseline.
    # Fewer than 14 samples = no baseline, so no signal (the gate reports nothing, not a guess).
    """Median of a field over baseline_days ending baseline_gap_days ago."""
    hi = today - timedelta(days=rules["baseline_gap_days"])
    lo = hi - timedelta(days=rules["baseline_days"] - 1)
    xs = [r.get(field_) for r in rows if lo <= r["date"] <= hi and r.get(field_) is not None]
    return statistics.median(xs) if len(xs) >= 14 else None


def evaluate(inp: Inputs, rules: dict, last_spoken: dict | None = None) -> Verdict:
    """Count the signals that fired (work: hours, hours_trend, evenings; body: rhr, hrv, sleep,
    stress; plus runs and felt) and map them to a colour: red when a work and a body signal
    coincide, or 4+ signals, or `felt` with another; amber for 2+; green otherwise. An
    upcoming race or trip (`pre_event_days`) lowers the bar: one signal is amber, two red.
    `last_spoken` ({"amber": ISO date}) rate-limits amber messages; red always speaks."""
    last_spoken = last_spoken or {}
    today = inp.today
    signals: list[dict] = []
    gaps = list(inp.gaps)
    numbers: dict = {}

    # ---- work ---- (windows end yesterday: the gate runs in the morning, so today has no hours yet)
    if inp.work_hours:
        y = today - timedelta(days=1)
        h7 = sum(v for d, v in inp.work_hours.items() if y - timedelta(days=6) <= d <= y)
        h21 = sum(v for d, v in inp.work_hours.items() if y - timedelta(days=20) <= d <= y)
        numbers["hours_7d"] = round(h7, 1)
        numbers["hours_21d_week_avg"] = round(h21 / 3, 1)
        if h7 > rules["week_hours_max"]:
            signals.append({"name": "hours", "text": f"{h7:.0f} h of work in the last 7 days"})
        if h21 / 3 > rules["week_hours_max"]:
            signals.append({"name": "hours_trend",
                            "text": f"three weeks averaging {h21 / 3:.0f} h"})
        ev = sorted(d for d in inp.evening_days if y - timedelta(days=6) <= d <= y)
        numbers["evenings_7d"] = len(ev)
        if len(ev) >= rules["evenings_in_7d"]:
            signals.append({"name": "evenings",
                            "text": f"{len(ev)} evenings of work past {inp.hard_stop} this week"})
    else:
        gaps.append("no worklog hours")

    # ---- body ----
    w7 = _window(inp.wellness, today, 7)
    if not inp.wellness:
        gaps.append("no Garmin wellness")
    elif not w7:
        gaps.append("Garmin wellness older than a week")
    else:
        rhr = _mean(r.get("resting_hr") for r in w7)
        rhr_b = _baseline(inp.wellness, today, rules, "resting_hr")
        numbers.update(rhr_7d=rhr and round(rhr, 1), rhr_base=rhr_b)
        if rhr is not None and rhr_b is not None and rhr >= rhr_b + rules["rhr_over_baseline"]:
            signals.append({"name": "rhr", "text": f"resting HR {rhr:.0f} against your usual {rhr_b:.0f}"})
        hrv = _mean(r.get("hrv") for r in w7)
        hrv_b = _baseline(inp.wellness, today, rules, "hrv")
        numbers.update(hrv_7d=hrv and round(hrv, 1), hrv_base=hrv_b)
        if hrv is not None and hrv_b is not None and hrv < hrv_b * rules["hrv_ratio"]:
            signals.append({"name": "hrv", "text": f"HRV {hrv:.0f} ms against your usual {hrv_b:.0f}"})
        sleep_h = _mean(r.get("sleep_h") for r in w7)
        score = _mean(r.get("sleep_score") for r in w7)
        numbers.update(sleep_7d_h=sleep_h and round(sleep_h, 1), sleep_score_7d=score and round(score))
        if (sleep_h is not None and sleep_h < rules["sleep_min_h"]) or \
           (score is not None and score < rules["sleep_score_min"]):
            parts = []
            if sleep_h is not None:
                parts.append(f"{sleep_h:.1f} h a night")
            if score is not None:
                parts.append(f"score {score:.0f}")
            signals.append({"name": "sleep", "text": "sleep " + ", ".join(parts)})
        stress = _mean(r.get("stress") for r in w7)
        stress_b = _baseline(inp.wellness, today, rules, "stress")
        numbers.update(stress_7d=stress and round(stress, 1), stress_base=stress_b)
        if stress is not None and stress_b is not None and stress >= stress_b + rules["stress_over_baseline"]:
            signals.append({"name": "stress",
                            "text": f"Garmin stress {stress:.0f} against your usual {stress_b:.0f}"})

    # ---- runs ----
    planned = [d for d in inp.runs_planned if today - timedelta(days=13) <= d <= today]
    done = {d for d in inp.runs_done if today - timedelta(days=13) <= d <= today}
    numbers.update(runs_planned_14d=len(planned), runs_done_14d=len(done))
    if inp.illness_open:
        numbers["illness_open"] = True
    elif len(planned) >= rules["runs_planned_min"] and len(planned) - len(done) >= rules["runs_missed"]:
        signals.append({"name": "runs",
                        "text": f"{len(done)} of {len(planned)} planned runs done in two weeks"})

    # ---- self rating ----
    felt7 = [f for f in inp.felt if today - timedelta(days=6) <= f["date"] <= today]
    heavy = [f for f in felt7 if f.get("answer") in HEAVY]
    numbers["felt_heavy_7d"] = len(heavy)
    if len(heavy) >= rules["felt_heavy_in_7d"]:
        signals.append({"name": "felt", "text": f"you rated {len(heavy)} of the last 7 days heavy"})

    # ---- colour ----
    names = {s["name"] for s in signals}
    work = bool(names & set(WORK_SIGNALS))
    body = bool(names & set(BODY_SIGNALS))
    pre = _pre_event(inp.events, today, rules["pre_event_days"])
    n = len(signals)
    if pre:
        colour = RED if n >= 2 else AMBER if n >= 1 else GREEN
    elif (work and body) or n >= 4 or ("felt" in names and n >= 2):
        colour = RED
    elif n >= 2:
        colour = AMBER
    else:
        colour = GREEN

    protect = _protect(names, inp, colour, pre)
    speak = _speak(colour, today, last_spoken, rules)
    return Verdict(colour, signals, gaps, protect, speak, pre, numbers, today.isoformat())


def _pre_event(events, today, days) -> dict | None:
    soon = [e for e in events if 0 <= (e["date"] - today).days < days]
    if not soon:
        return None
    e = min(soon, key=lambda x: x["date"])
    return {"date": e["date"].isoformat(), "title": e["title"], "kind": e.get("kind", "race"),
            "days": (e["date"] - today).days}


def _protect(names, inp, colour, pre) -> str:
    if colour == GREEN:
        return ""
    if "evenings" in names:
        return f"a hard stop at {inp.hard_stop} every day this week"
    if "runs" in names:
        nxt = sorted(d for d in inp.runs_planned if d > inp.today)
        when = nxt[0].strftime("%A") if nxt else "the next"
        return f"{when}'s run, as planned"
    if "sleep" in names:
        return "lights out by 23:00"
    if "hours" in names or "hours_trend" in names:
        return "one afternoon off this week"
    if pre:
        return f"an easy week before {pre['title']}"
    if names & set(BODY_SIGNALS):
        return "an easy week: no hard sessions, no late evenings"
    return "the plan as it stands"


def _speak(colour, today, last_spoken, rules) -> bool:
    if colour == GREEN:
        return False
    if colour == RED:
        return True
    last = last_spoken.get("amber")
    try:
        last_d = date.fromisoformat(last) if last else None
    except ValueError:
        last_d = None
    if last_d == today:
        return True  # a re-run the same day repeats the line rather than silencing it
    return last_d is None or (today - last_d).days >= rules["amber_every_days"]


def telegram_line(v: Verdict) -> str:
    """One short paragraph for the coach message. Plain text, HTML-escaped by the caller."""
    dot = {GREEN: "🟢", AMBER: "🟠", RED: "🔴"}[v.colour]
    if v.colour == GREEN:
        return f"{dot} Capacity: green."
    why = "; ".join(s["text"] for s in v.signals) or "no single signal, but close to the line"
    out = f"{dot} Capacity: {v.colour}. {why}."
    if v.pre_event:
        d = v.pre_event["days"]
        when = "today" if d == 0 else f"in {d} day{'s' if d != 1 else ''}"
        out += f" {v.pre_event['title']} is {when}."
    if v.protect:
        out += f" Protect: {v.protect}."
    if v.gaps:
        out += " (no data: " + ", ".join(v.gaps) + ")"
    return out
