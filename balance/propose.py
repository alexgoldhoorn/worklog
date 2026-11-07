"""Proposed protection blocks for a stretch of days. Pure given its inputs."""
from __future__ import annotations

from datetime import date, timedelta

from . import db as bdb
from .inputs import RUN_TYPES

RUN_MINUTES = {"easy": 60, "long": 120, "intervals": 75, "tempo": 75, "race": 120, "strength": 45}


def _hm(s: str) -> int:
    h, m = s.split(":")
    return int(h) * 60 + int(m)


def _fmt(m: int) -> str:
    return f"{m // 60:02d}:{m % 60:02d}"


def _clashes(d: date, start: int, end: int, busy: list[dict]) -> bool:
    ds = d.isoformat()
    for b in busy:
        if b["date"] != ds or not b.get("end"):
            continue
        if _hm(b["start"]) < end and _hm(b["end"]) > start:
            return True
    return False


def plan_blocks(days: list[date], plan: list[dict], busy: list[dict], settings: dict,
                existing: list[dict], personal: list[dict] | None = None) -> list[dict]:
    """Blocks to propose: one run (or strength) per plan day, a hard stop per weekday.

    busy: work-calendar meetings ({date,start,end}). existing: blocks already in the
    store for those days (any state but rejected) — a day never gets a second
    block of the same kind. personal: personal-calendar events; a day that already
    carries a "hard stop" event there (you may keep one by hand) gets no second one.
    """
    have = {(b["date"], b["kind"]) for b in existing}
    for e in personal or []:
        if "hard stop" in str(e.get("title", "")).lower():
            have.add((e["date"], "stop"))
    slots = [settings.get("run_slot", "07:30")] + [
        s.strip() for s in settings.get("run_alt_slots", "13:00,18:00").split(",") if s.strip()]
    hard_stop = settings.get("hard_stop", "18:00")
    by_day = {}
    for r in plan:
        if r["type"] in RUN_TYPES or r["type"] == "strength":
            by_day.setdefault(r["date"], []).append(r)
    out = []
    for d in days:
        ds = d.isoformat()
        for r in by_day.get(d, [])[:1]:
            if (ds, "run") in have:
                continue
            minutes = RUN_MINUTES.get(r["type"], 60)
            title = r["session"] or r["type"].title()
            placed = None
            for s in slots:
                st = _hm(s)
                if not _clashes(d, st, st + minutes, busy):
                    placed = st
                    break
            note = "" if placed is not None else "every slot clashes with a meeting; placed at the run slot anyway"
            st = placed if placed is not None else _hm(slots[0])
            out.append({"date": ds, "start": _fmt(st), "end": _fmt(st + minutes), "kind": "run",
                        "title": title, "note": note})
        if d.weekday() < 5 and (ds, "stop") not in have:
            st = _hm(hard_stop)
            out.append({"date": ds, "start": hard_stop, "end": _fmt(st + 30), "kind": "stop",
                        "title": "Hard stop", "note": "laptop closed; the evening is yours"})
    return out


def week_days(start: date, end: date) -> list[date]:
    return [start + timedelta(days=i) for i in range((end - start).days + 1)]


def next_monday(today: date) -> date:
    return today + timedelta(days=(7 - today.weekday()) % 7 or 7)


def propose(conn, days: list[date], plan: list[dict], busy: list[dict], reason: str,
            source: str = "propose", personal: list[dict] | None = None) -> list[dict]:
    """Write proposals into the store; returns the blocks created."""
    settings = bdb.get_settings(conn)
    lo, hi = days[0].isoformat(), days[-1].isoformat()
    existing = [b for b in bdb.blocks_between(conn, lo, hi) if b["state"] != "rejected"]
    created = []
    for b in plan_blocks(days, plan, busy, settings, existing, personal):
        bid = bdb.add_block(conn, b["date"], b["start"], b["end"], b["kind"], b["title"],
                            note=b["note"], source=source)
        created.append(bdb.get_block(conn, bid))
    if created:
        bdb.record_proposal(conn, days[0].isoformat(), reason)
    return created
