"""Balance sync: Todoist goals + personal-calendar snapshots for the page, the Google
Calendar mirror of approved blocks, and the write queue the Day page fills.
Run every 2 minutes: a light tick drains the queue (and pushes blocks when something is
pending); the full snapshots run every 14+ minutes or when the page touched
<state_dir>/sync_now. Prints nothing when not on a terminal; `--dry-run` prints the status
it would write.

    python -m balance.jobs.sync [--dry-run]
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import date, datetime

FULL_EVERY_MIN = 14

from balance import db as bdb, sync
from balance.config import DB_PATH, STATE_DIR


def _full_due(state_dir: str) -> bool:
    """A full run when the page asked for one (sync_now) or the last full run is old."""
    # The page writes the flag beside the store (its state-dir mount is read-only); the
    # state dir is still honoured for hand-made flags.
    due = False
    for flag in (os.path.join(os.path.dirname(DB_PATH), "sync_now"), os.path.join(state_dir, "sync_now")):
        if os.path.exists(flag):
            due = True
            try:
                os.remove(flag)
            except OSError:
                pass
    if due:
        return True
    try:
        with open(os.path.join(state_dir, "sync.json")) as f:
            prev = json.load(f)
        ran = datetime.fromisoformat(prev.get("full_ran") or prev["ran"])
    except (OSError, ValueError, KeyError, TypeError):
        return True
    return (datetime.now() - ran).total_seconds() >= FULL_EVERY_MIN * 60


def _nudge(env: dict, state_dir: str) -> None:
    """Hard-stop Telegram nudge. Silent while the checkout lacks balance.nudge."""
    try:
        from balance import nudge
    except ImportError as e:
        if e.name in ("balance.nudge", "balance"):
            return
        raise
    try:
        r = nudge.tick(env, state_dir)
        if str(r.get("reason", "")).startswith("worklog unreachable"):
            print(f"WARN balance.jobs.sync nudge: {r['reason']}", file=sys.stderr)
    except Exception as e:  # noqa: BLE001 - never fail the sync tick over a nudge
        print(f"WARN balance.jobs.sync nudge: {e}", file=sys.stderr)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dry-run", action="store_true", help="snapshots to a temp dir, no Google push")
    args = ap.parse_args()
    state_dir = STATE_DIR
    if args.dry_run:
        import tempfile
        state_dir = tempfile.mkdtemp(prefix="balance-sync-")
    light = not args.dry_run and not _full_due(state_dir)
    conn = bdb.connect(DB_PATH if not args.dry_run else ":memory:")
    env = sync._env()
    try:
        status = sync.run(conn, state_dir, date.today(), env=env, light=light)
    finally:
        conn.close()
    if not args.dry_run:
        _nudge(env, state_dir)
    if status.get("errors"):
        for e in status["errors"]:
            print(f"WARN balance.jobs.sync: {e}", file=sys.stderr)
    if args.dry_run or sys.stdout.isatty():
        print(json.dumps(status, indent=1, ensure_ascii=False))
        if args.dry_run:
            print(f"snapshots in {state_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
