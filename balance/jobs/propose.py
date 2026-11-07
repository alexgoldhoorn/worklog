"""Weekly proposals: run blocks and hard stops for next week, as `proposed` rows in the
balance store, approved on the /week page (or they expire unseen). Run once a week (e.g.
Sunday afternoon). Prints nothing when not on a terminal.

    python -m balance.jobs.propose [--dry-run] [--date YYYY-MM-DD]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import date, timedelta

from balance import db as bdb, inputs, propose
from balance.config import DB_PATH, STATE_DIR


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--date")
    args = ap.parse_args()
    today = date.fromisoformat(args.date) if args.date else date.today()
    mon = propose.next_monday(today)
    days = propose.week_days(mon, mon + timedelta(days=6))
    plan = inputs.read_plan()
    busy = inputs.read_work_calendar(days[0], days[-1])
    conn = bdb.connect(DB_PATH, readonly=args.dry_run)
    try:
        personal = inputs.personal_events(STATE_DIR)
        if args.dry_run:  # what would be written, against the real store, without writing
            existing = [b for b in bdb.blocks_between(conn, days[0].isoformat(), days[-1].isoformat())
                        if b["state"] != "rejected"]
            created = propose.plan_blocks(days, plan, busy, bdb.get_settings(conn), existing, personal)
        else:
            created = propose.propose(conn, days, plan, busy, "sunday", personal=personal)
    finally:
        conn.close()
    if args.dry_run or sys.stdout.isatty():
        print(json.dumps({"week": mon.isoformat(), "created": created}, indent=1, ensure_ascii=False, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
