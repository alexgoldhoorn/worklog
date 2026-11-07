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

## The hard-stop nudge and its buttons

`balance.nudge.tick()` runs inside the sync job. When a work block is still running
`nudge_after_min` (default 30) minutes after `hard_stop`, it sends one Telegram message with
two buttons, "stop" and "snooze". It sends at most one message, plus one more after a snooze.
It reads the timer through `WORKLOG_URL` (with `WORKLOG_USER` and `WORKLOG_PASSWORD` when a
login is set) and needs `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID`.

This repository only sends the message. Something on your side must receive the button
taps (a bot that polls `getUpdates`, or a webhook) and pass the callback data, which looks
like `balance:2026-01-31:stop`, to `balance.nudge.handle_tap(data, env)`. It returns the
reply text to show, or `None` for data that is not a nudge tap. Without a receiver the
message still works as a plain reminder.

## Scheduling

Any scheduler works. With cron:

```cron
*/2 * * * *  cd /opt/worklog && .venv/bin/python -m balance.jobs.sync
20 7 * * *   cd /opt/worklog && .venv/bin/python -m balance.jobs.gate
30 17 * * 0  cd /opt/worklog && .venv/bin/python -m balance.jobs.propose
```

The jobs print nothing when stdout is not a terminal, warnings go to stderr, and a
failure exits non-zero.
