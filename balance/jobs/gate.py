"""Capacity gate: one daily verdict over rolling weeks. Run once a day (early morning, before you plan the day).

Reads worklog hours, wellness, the training plan, activities, the self ratings and the
balance store; writes <BALANCE_STATE_DIR>/gate.json (the page reads it) and appends
gate_history.jsonl. On a red day mid-week it proposes blocks for the rest of the week.
Prints nothing when not on a terminal.

    python -m balance.jobs.gate [--dry-run] [--date YYYY-MM-DD]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import date, datetime, timedelta

from balance import db as bdb, gate, inputs, propose
from balance.config import DB_PATH, STATE_DIR, load_rules

HISTORY = "gate_history.jsonl"
SPOKEN = "spoken.json"


def _read_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def _write_json(path, data):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def run(today: date, dry_run: bool = False, state_dir: str = STATE_DIR, db_path: str = DB_PATH) -> gate.Verdict:
    rules = load_rules(os.path.join(state_dir, "config.json"))
    conn = bdb.connect(db_path, readonly=dry_run)
    try:
        settings = bdb.get_settings(conn)
        rules["week_hours_max"] = float(settings.get("week_hours_max") or rules["week_hours_max"])
        inp = inputs.gather(today, state_dir, rules, settings)
        spoken = _read_json(os.path.join(state_dir, SPOKEN), {})
        v = gate.evaluate(inp, rules, spoken)
        if dry_run:
            return v
        _write_json(os.path.join(state_dir, "gate.json"), v.as_dict())
        with open(os.path.join(state_dir, HISTORY), "a") as f:
            f.write(json.dumps(v.as_dict(), ensure_ascii=False) + "\n")
        if v.speak:
            spoken[v.colour] = today.isoformat()
            _write_json(os.path.join(state_dir, SPOKEN), spoken)
        # red early in the week (Mon-Thu): propose the rest of this week once
        if v.colour == gate.RED and today.weekday() <= 3:  # Mon-Thu: rest of this week
            mon = today - timedelta(days=today.weekday())
            last = bdb.last_proposal(conn, mon.isoformat())
            if not last or last["reason"] != "red":
                days = propose.week_days(today + timedelta(days=1), mon + timedelta(days=6))
                busy = inputs.read_work_calendar(days[0], days[-1])
                propose.propose(conn, days, inputs.read_plan(), busy, "red", source="gate",
                                personal=inputs.personal_events(state_dir))
        return v
    finally:
        conn.close()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="print the verdict, write nothing")
    ap.add_argument("--date", help="evaluate as of this date (YYYY-MM-DD); implies --dry-run")
    args = ap.parse_args()
    today = date.fromisoformat(args.date) if args.date else date.today()
    dry_run = args.dry_run or bool(args.date)
    try:
        v = run(today, dry_run=dry_run)
    except Exception as e:  # noqa: BLE001 - a crash must leave a trace and a stale-proof file
        print(f"ERROR balance.jobs.gate: {e}", file=sys.stderr)
        try:
            from balance import config
            _write_json(os.path.join(STATE_DIR, "gate.json"),
                        {"date": today.isoformat(), "colour": "", "error": str(e),
                         "ran": datetime.now().isoformat(timespec="seconds")})
        except Exception:  # noqa: BLE001
            pass
        return 1
    if dry_run or sys.stdout.isatty():
        print(json.dumps(v.as_dict(), indent=1, ensure_ascii=False))
        print("---\n" + gate.telegram_line(v))
    return 0


if __name__ == "__main__":
    sys.exit(main())
