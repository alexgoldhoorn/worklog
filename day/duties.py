"""Care duties (the school run today) synthesised per school day from the rules, with the
owner from, in order: an overlay one_off annotation, the weekday override, the default."""
from datetime import date, datetime, timedelta

from . import rules as _rules


def _shift(hhmm: str, minutes: int) -> str:
    t = datetime.strptime(hhmm, "%H:%M") + timedelta(minutes=minutes)
    return t.strftime("%H:%M")


def _owner(duty: dict, d: date, overlay: dict, me: str, aliases: tuple = ("you", "me")) -> tuple[str | None, str]:
    for a in overlay.get("one_off", []):
        if a.get("date") == d.isoformat() and a.get("start") == duty["at"] and a.get("title") == duty["name"] and a.get("owner"):
            owner = me if a["owner"] in aliases else a["owner"]              # the annotation store writes "you" for the owner of this dashboard
            return owner, "pending" if a.get("pending") else "overlay"
    wd = duty.get("owner_by_weekday", {}).get(str(d.weekday()))
    if wd:
        return wd, "weekday"
    return duty.get("default_owner"), "rule"


def for_day(d: date, rules: dict, holidays: dict[str, str], overlay: dict, school: dict | None = None) -> list[dict]:
    """Duties on `d`: none on a weekend day not listed, on a holiday, or when the school calendar
    says `off` (closure or free day). An `unknown` or absent school status keeps the duties,
    flagged `school_status: "unknown"`: never dropped on a guess."""
    if d.isoformat() in holidays:
        return []
    sd = (school or {}).get(d.isoformat()) or {}
    status = sd.get("status") or "unknown"
    if status == "off":
        return []
    out = []
    for duty in rules.get("duties", []):
        if d.weekday() not in duty.get("days", []):
            continue
        h = _rules.household(rules)
        owner, src = _owner(duty, d, overlay, h["me"], tuple(h["me_aliases"]))
        out.append({
            "kind": "duty", "title": duty["name"], "date": d.isoformat(),
            "start": _shift(duty["at"], -int(duty.get("leave_before_min", 0))),
            "at": duty["at"],
            "end": _shift(duty["at"], int(duty.get("travel_min", 0))),
            "owner": owner, "owner_source": src, "tier": "context", "school_status": status,
        })
    return out
