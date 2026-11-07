# Host integration

The host jobs need a few things that depend on where you run them: how credentials are
loaded, how calendars are fetched, how Google OAuth is done. Instead of hardcoding one
setup, they import small modules from an optional directory, `WORKLOG_HOST_LIB`. Without
it each feature reports itself as unavailable and the rest keeps working.

| Module (relative to `WORKLOG_HOST_LIB`) | Function | Used for | Without it |
|---|---|---|---|
| `common.py` | `load_env() -> dict` | Credentials for the jobs | `os.environ` |
| `personal/calendar_ics.py` | `fetch_ics_events(urls, start, end) -> (events, warnings)` | Personal calendar snapshot from `GOOGLE_CALENDAR_ICS_URLS` | snapshot reports an error |
| `gcal/oauth.py` | `access_token() -> str` | Google Calendar API: read calendars, mirror approved blocks | mirror waits |
| `personal/holidays.py` | `load_rules_checked() -> (rules, warning)`, `school_status(date, rules) -> (status, name)` | School open/closed for care duties | duties stay, flagged "unknown" |
| `scripts/notify.py` | `send_telegram(text, token, chat, reply_markup=None)` | The hard-stop nudge | plain Telegram Bot API call |

`fetch_ics_events` returns events as dicts with `start`/`end` (aware datetimes or dates
for all-day), `title`, `calendar` (the name from the URL list) and `uid`.

## Scheduling

Any scheduler works. With cron:

```cron
*/2 * * * *  cd /opt/worklog && .venv/bin/python -m balance.jobs.sync
20 7 * * *   cd /opt/worklog && .venv/bin/python -m balance.jobs.gate
30 17 * * 0  cd /opt/worklog && .venv/bin/python -m balance.jobs.propose
```

The jobs print nothing when stdout is not a terminal, warnings go to stderr, and a
failure exits non-zero.
