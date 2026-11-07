# Configuration

Every setting is an environment variable. Only `WORKLOG_DB` matters for the plain timer;
everything else is optional and switches a feature on.

## Server (`worklog/config.py`)

| Variable | Default | Purpose |
|---|---|---|
| `WORKLOG_DB` | `./data/worklog.db` | The timer's SQLite store (created on first start). |
| `TZ` | `UTC` | Local time for "today", reports and calendar conversion. |
| `WORKLOG_AUTH_USER`, `WORKLOG_AUTH_PASSWORD_HASH` | unset | Both set: HTTP Basic on everything but `/healthz`. Hash with `python -m worklog.auth`. |
| `WORKLOG_CALENDAR_DB` | unset | Read-only work-calendar database for meeting proposals (schema below). |
| `WORKLOG_HOLIDAYS` | unset | Holidays cache JSON (format below); holidays get 0 expected hours. |
| `WORKLOG_HOLIDAY_SKIP_SCOPES` | empty | Comma-separated holiday scopes that are *not* days off for work (e.g. `town` when your client follows the city's calendar). |
| `WORKLOG_SENTRY_DSN` | unset | Report unhandled exceptions to Sentry or a compatible server. |
| `BALANCE_DB` | unset | Enables the Day/Week pages: the planner store (blocks, queue, taps). |
| `BALANCE_STATE_DIR` | unset | The snapshots the host jobs write (read-only for the server). |
| `BALANCE_PLAN` | unset | Training plan CSV, for run sessions on the timeline. |
| `WORK_CALENDAR_INBOX` | unset | Where an uploaded calendar PDF is saved for an importer to pick up. |
| `DAY_RULES` | packaged neutral defaults | Household rules JSON; start from `day/rules.example.json`. |
| `DAY_SCHOOL_HOLIDAY_SCOPES` | empty (every scope) | Holiday scopes that close the school, so care duties drop on those days. |

## Host jobs (`balance/config.py`, `balance/inputs.py`)

The jobs in `balance/jobs/` run on the host, not in the container. Paths default to files
under `WORKLOG_STATE_ROOT` (`~/.local/state/worklog`).

| Variable | Default under the root | Contents |
|---|---|---|
| `BALANCE_STATE_DIR` | `balance/` | Snapshots and `config.json` (gate thresholds, see `DEFAULT_RULES`). |
| `BALANCE_DB` | `balance.db` | The planner store, shared with the server. |
| `BALANCE_WORKLOG_DB` | `worklog.db` | The timer's store, read for hours and evenings. |
| `BALANCE_PLAN` | `inputs/plan.csv` | Columns `date,session,type,distance_km`; `type` one of easy, long, intervals, tempo, race. |
| `BALANCE_WELLNESS` | `inputs/wellness.parquet` | Columns `local_date,resting_hr,hrv_last_night_ms,sleep_s,sleep_score,stress_avg`. Needs `pyarrow`. |
| `BALANCE_ACTIVITIES` | `inputs/garmin_activities.csv` | Completed activities, for "runs kept". |
| `BALANCE_COACH_HEALTH` | `inputs/health.json` | Optional free-form health flags. |
| `BALANCE_CALENDAR_DB` | `work_calendar.db` | The work-calendar database (same schema as `WORKLOG_CALENDAR_DB`). |
| `BALANCE_ANNOTATIONS_DB` | `calendar_annotations.db` | Duty owners and notes set from the Day page. |
| `WORKLOG_HOLIDAYS` | `holidays_cache.json` | Same file as the server's. |
| `WORKLOG_HOST_LIB` | unset | Optional host integrations, see [host-integration.md](host-integration.md). |
| `WORKLOG_URL`, `WORKLOG_USER`, `WORKLOG_PASSWORD` | `http://127.0.0.1:8503` | How the nudge reaches the server. |
| `TODOIST_API_KEY` (or `TODOIST_API_TOKEN`) | unset | Goals and milestones from one Todoist project (set it on the Week page). |
| `GOOGLE_CALENDAR_ICS_URLS` | unset | `Name\|https://...ics,Name2\|https://...` personal calendars. |
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | unset | The hard-stop nudge. |

## File formats

**Holidays cache** (`WORKLOG_HOLIDAYS`):

```json
{"2026": {"holidays": [{"date": "2026-12-25", "name": "Christmas", "scope": "national"},
                       {"date": "2026-09-16", "name": "Town festival", "scope": "town"}]}}
```

Scopes are free text; the two `*_SCOPES` variables decide which ones count where.

**Work-calendar database**: SQLite with a table
`events(date TEXT, start TEXT, end TEXT, title TEXT, status TEXT)`, times as `HH:MM`,
`status` `confirmed` or `cancelled`. Anything that fills that table works (an export
importer, a CalDAV sync, a script).

**Household rules** (`DAY_RULES`): see `day/rules.example.json`. `household` names the
people (`me`, `partner`, `child`), maps calendar roles to your calendar names, and maps
organiser emails to people; `duties` are recurring care tasks with a default owner and
per-weekday overrides; `family_patterns` classify Family-calendar titles as `partner`,
`child` or `family`; `slots` bounds the day for the slot engine.
