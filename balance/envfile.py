"""Optional host settings file, read once when `balance` or `day` is imported.

Host processes (cron jobs, long-running tool servers) rarely share one environment, so
the paths and options in docs/configuration.md can also live in a file:
$WORKLOG_ENV_FILE, default ~/.config/worklog/host.env. `KEY=value` lines, `#` comments,
a leading `~/` is expanded. A variable already set in the environment always wins.
A missing file is fine (the container has none).
"""
import os

DEFAULT = "~/.config/worklog/host.env"
_loaded = False


def parse(text: str) -> dict[str, str]:
    out = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        value = value.strip().strip('"').strip("'")
        out[key.strip()] = os.path.expanduser(value) if value.startswith("~/") else value
    return out


def load(path: str | None = None) -> dict[str, str]:
    """Apply the file to os.environ (setdefault); returns what it applied."""
    global _loaded
    if _loaded and path is None:
        return {}
    _loaded = True
    p = os.path.expanduser(path or os.environ.get("WORKLOG_ENV_FILE") or DEFAULT)
    try:
        with open(p) as f:
            values = parse(f.read())
    except OSError:
        return {}
    applied = {}
    for k, v in values.items():
        if k not in os.environ:
            os.environ[k] = v
            applied[k] = v
    return applied
