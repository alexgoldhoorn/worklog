"""Everything the day model reads, loaded once per request into a Context."""
import os
from dataclasses import dataclass, field
from datetime import date, datetime

from balance import db as bdb, inputs, sessions


@dataclass
class Context:
    date: date
    now: datetime
    state_dir: str
    balance_conn: object
    plan_path: str | None
    holidays: dict
    rules: dict
    worklog_status: dict
    balance_settings: dict = field(default_factory=dict)
    client_holidays: dict = field(default_factory=dict)   # the client's calendar (work days); `holidays` is the school's


def _with_pending(annotations: dict, queue: list[dict]) -> dict:
    """Owner/tier/note changes queued (or applied after the snapshot was taken) show at once."""
    taken = (annotations.get("taken") or "").replace("T", " ")
    extra = []
    for q in queue:
        if q["kind"] != "annotate":
            continue
        if q["status"] == "pending" or (q["status"] == "done" and (q.get("applied_at") or "") > taken):
            extra.append({**q["payload"], "pending": True})
    if extra:
        annotations = {**annotations, "one_off": extra + list(annotations.get("one_off", []))}
    return annotations


def load(ctx: Context) -> dict:
    """Read every file and table once; the model is pure on top of this."""
    st = ctx.state_dir
    d = ctx.date.isoformat()
    queue = bdb.queue_recent(ctx.balance_conn, days=7)
    ann = inputs.read_json(os.path.join(st, "annotations.json"), {})
    return {
        "gate": inputs.read_json(os.path.join(st, "gate.json"), {}),
        "goals": inputs.read_json(os.path.join(st, "goals.json"), {}),
        "personal": [e for e in inputs.personal_events(st) if e.get("date") == d],
        "personal_fetched": inputs.read_json(os.path.join(st, "personal.json"), {}).get("fetched", ""),
        "mirror": inputs.read_mirror(st),
        "annotations": _with_pending({"one_off": ann.get("one_off", []), "recurring": ann.get("recurring", []),
                                      "taken": ann.get("taken", "")}, queue),
        "sync": inputs.read_json(os.path.join(st, "sync.json"), {}),
        "blocks": [b for b in bdb.blocks_between(ctx.balance_conn, d, d, states=("proposed", "approved"))],
        "queue": queue,
        "prep": bdb.get_prep_notes(ctx.balance_conn, d),
        "plan": inputs.read_plan(ctx.plan_path) if ctx.plan_path else [],
        "session_times": sessions.read(st),
        "school_days": inputs.read_school_days(st),
        "event_class": bdb.get_event_classes(ctx.balance_conn, d),
        "family_rules": bdb.family_rules(ctx.balance_conn),
    }


def host_context(d: date, *, state_dir: str | None = None, db_path: str | None = None, plan_path: str | None = None,
                 holidays_cache: str | None = None, worklog_status: dict | None = None, now: datetime | None = None,
                 rules_path: str | None = None) -> Context:
    """The Context the PA tools build on the host (credentials there, real paths by default).
    The caller closes `balance_conn`."""
    from balance import config as bconf
    from . import holidays as _hol, rules as _rules

    state_dir = state_dir or bconf.STATE_DIR
    db_path = db_path or bconf.DB_PATH
    from balance import inputs as binputs
    plan_path = plan_path or binputs.PLAN_CSV
    holidays_cache = holidays_cache or binputs.HOLIDAYS_CACHE
    conn = bdb.connect(db_path, check_same_thread=False)
    client = _hol.client_holidays(holidays_cache)
    return Context(date=d, now=now or datetime.now(), state_dir=state_dir, balance_conn=conn, plan_path=plan_path,
                   holidays=_hol.school_holidays(holidays_cache), rules=_rules.load(rules_path),
                   worklog_status=worklog_status or {}, balance_settings=bdb.get_settings(conn),
                   client_holidays=client)
