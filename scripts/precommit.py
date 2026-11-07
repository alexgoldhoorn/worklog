"""Pre-commit guard: keeps data files and personal strings out of a public repo.

Scans the staged version of each file. Deny patterns (one case-insensitive regex per
line, # for comments) come from an untracked file: $WORKLOG_DENY_PATTERNS, default
~/.config/worklog/deny-patterns.txt. Without that file the pattern check is skipped with
a warning, because clones do not have it. A match is reported by file, line and
pattern number, never by the matched text.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

DEFAULT_DENY_FILE = "~/.config/worklog/deny-patterns.txt"
FORBIDDEN_SUFFIXES = (".db", ".sqlite", ".sqlite3", ".duckdb", ".parquet", ".wal", ".csv", ".fit",
                      ".gpx", ".tcx", ".jsonl")
FORBIDDEN_NAMES = (".env", "auth.env", "local.jungle", "deny-patterns.txt")


def forbidden_file(path: str) -> bool:
    name = Path(path).name.lower()
    return name in FORBIDDEN_NAMES or name.endswith(FORBIDDEN_SUFFIXES)


def load_patterns(path: Path) -> list[re.Pattern] | None:
    if not path.is_file():
        return None
    lines = [line.strip() for line in path.read_text().splitlines()]
    return [re.compile(line, re.IGNORECASE) for line in lines if line and not line.startswith("#")]


def scan_text(text: str, patterns: list[re.Pattern]) -> list[tuple[int, int]]:
    hits = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        for pattern_number, pattern in enumerate(patterns, start=1):
            if pattern.search(line):
                hits.append((line_number, pattern_number))
    return hits


def _staged() -> list[str]:
    out = subprocess.run(["git", "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z"],
                         check=True, capture_output=True, text=True).stdout
    return [f for f in out.split("\0") if f]


def main() -> int:
    deny_file = Path(os.path.expanduser(os.environ.get("WORKLOG_DENY_PATTERNS", DEFAULT_DENY_FILE)))
    patterns = load_patterns(deny_file)
    if patterns is None:
        print(f"WARNING: {deny_file} not found; personal-string check skipped", file=sys.stderr)
    failures = []
    for path in _staged():
        if forbidden_file(path):
            failures.append(f"{path}: data or local config files must not be committed")
            continue
        if patterns:
            blob = subprocess.run(["git", "show", f":{path}"], capture_output=True).stdout
            for line, number in scan_text(blob.decode("utf-8", errors="replace"), patterns):
                failures.append(f"{path}:{line}: matches deny pattern #{number}")
    for failure in failures:
        print(failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
