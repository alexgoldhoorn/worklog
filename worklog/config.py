"""Server settings, read once from the environment (see docs/configuration.md)."""
import os
from dataclasses import dataclass


@dataclass
class Settings:
    db_path: str
    calendar_db_path: str | None = None
    holidays_path: str | None = None
    tz: str = "UTC"
    # both set: HTTP Basic auth on everything but /healthz (worklog/auth.py); either unset: no login
    auth_user: str | None = None
    auth_password_hash: str | None = None
    # balance (gate, blocks, snapshots) and the Day page; all optional
    balance_db_path: str | None = None
    balance_state_dir: str | None = None
    plan_path: str | None = None
    calendar_inbox: str | None = None     # where an uploaded Outlook PDF goes (the inbox job imports it)
    sentry_dsn: str | None = None         # Sentry-compatible error reporting; unset = off


def from_env() -> Settings:
    """Empty strings count as unset, so `VAR=` in an env file switches a feature off."""
    return Settings(
        db_path=os.environ.get("WORKLOG_DB", "./data/worklog.db"),
        calendar_db_path=os.environ.get("WORKLOG_CALENDAR_DB") or None,
        holidays_path=os.environ.get("WORKLOG_HOLIDAYS") or None,
        tz=os.environ.get("TZ") or "UTC",
        auth_user=os.environ.get("WORKLOG_AUTH_USER") or None,
        auth_password_hash=os.environ.get("WORKLOG_AUTH_PASSWORD_HASH") or None,
        balance_db_path=os.environ.get("BALANCE_DB") or None,
        balance_state_dir=os.environ.get("BALANCE_STATE_DIR") or None,
        plan_path=os.environ.get("BALANCE_PLAN") or None,
        calendar_inbox=os.environ.get("WORK_CALENDAR_INBOX") or None,
        sentry_dsn=os.environ.get("WORKLOG_SENTRY_DSN") or None,
    )
