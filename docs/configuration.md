# Configuration

Every setting is an environment variable. Only `WORKLOG_DB` matters for the plain timer;
everything else is optional and switches a feature on.

## Server (`worklog/config.py`)

| Variable | Default | Purpose |
|---|---|---|
| `WORKLOG_DB` | `./data/worklog.db` | The timer's SQLite store. The file is created on first start; its directory must already exist. |
| `TZ` | `UTC` | Local time for "today", reports and calendar conversion. |
| `WORKLOG_AUTH_USER`, `WORKLOG_AUTH_PASSWORD_HASH` | unset | Both set: HTTP Basic on everything but `/healthz`. Hash with `python -m worklog.auth`. Only one set: the server refuses to start; neither: no login, WARNING logged. |
| `WORKLOG_CALENDAR_DB` | unset | Read-only work-calendar database for meeting proposals (schema below). |
| `WORKLOG_HOLIDAYS` | unset | Holidays cache JSON (format below); holidays get 0 expected hours. |
| `WORKLOG_HOLIDAY_SKIP_SCOPES` | empty | Comma-separated holiday scopes that are *not* days off for work (e.g. `town` when your client follows the city's calendar). |
| `WORKLOG_SENTRY_DSN` | unset | Report unhandled exceptions to Sentry or a compatible server. |
| `BALANCE_DB` | unset | The planner store (blocks, write queue, taps), shared with the host jobs. Set it together with `BALANCE_STATE_DIR` to use the Day and Week pages. |
| `BALANCE_STATE_DIR` | unset | The snapshots the host jobs write (read-only for the server). |
| `BALANCE_PLAN` | unset | Training plan CSV, for run sessions on the timeline. |
| `WORK_CALENDAR_INBOX` | unset | Where an uploaded calendar PDF is saved for an importer to pick up. |
| `DAY_RULES` | packaged neutral defaults | Household rules JSON; start from `day/rules.example.json`. |
| `DAY_SCHOOL_HOLIDAY_SCOPES` | empty (every scope) | Holiday scopes that close the school, so care duties drop on those days. |

## Host jobs (`balance/config.py`, `balance/inputs.py`)

The jobs in `balance/jobs/` run on the host, not in the container. Paths default to files
under `WORKLOG_STATE_ROOT` (`~/.local/state/worklog`).

Host processes rarely share one environment (a scheduler, a tool server, a shell), so the
`balance` and `day` packages also read `~/.config/worklog/host.env` (or `$WORKLOG_ENV_FILE`)
when imported: `KEY=value` lines, `~/` expanded, a variable already in the environment wins.
`TZ` on the host defaults to the system zone (`/etc/timezone` or `/etc/localtime`).

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

Also read by the host jobs:

| Variable | Default | Purpose |
|---|---|---|
| `WORKLOG_STATE_ROOT` | `~/.local/state/worklog` | Root for every default path in the table above. |
| `WORKLOG_ENV_FILE` | `~/.config/worklog/host.env` | The settings file described above. |
| `ANNOTATIONS_DB` | the `BALANCE_ANNOTATIONS_DB` path | Used only by the queue handler that saves duty owners and notes. |
| `TELEGRAM_HOME_CHANNEL` | unset | Fallback chat id when `TELEGRAM_CHAT_ID` is not set. |

## Settings stored in the databases

These are not environment variables. They live in the databases and change from the pages
or the API.

- **Timer** (`PUT /api/settings`, see [api.md](api.md)): `rate`, `rate_unit` (`h` or `day`)
  and `week_basis_h`. Setting `week_basis_h` also sets the default workday to a fifth of it.
  Other keys (`default_type`, `default_client`, `default_break_type`, `auto_close_time`)
  have defaults seeded on first start and no API; change them with `sqlite3` if you must.
  `auto_close_time` (default `18:00`) is where a block that was left running overnight is
  closed.
- **Planner** (`GET`/`PUT /api/balance/settings`, the Week page): `hard_stop` (`18:00`),
  `run_slot` (`07:30`), `run_alt_slots`, `week_hours_min`, `week_hours_max`,
  `gcal_calendar` (the calendar the approved blocks are mirrored to, default `Agent`),
  `todoist_project`, `milestone_label`.
- **Gate thresholds**: the defaults are `DEFAULT_RULES` in `balance/config.py`. To change
  one, put just that key in `<BALANCE_STATE_DIR>/config.json`, for example
  `{"week_hours_max": 32, "sleep_min_h": 7}`. Unknown keys are ignored.

## The state directory

`BALANCE_STATE_DIR` is the hand-over point between the host jobs (which write) and the
container (which reads it, normally mounted read-only). Do not edit these by hand.

| File | Written by | Contents |
|---|---|---|
| `gate.json`, `gate_history.jsonl`, `spoken.json` | gate job | Today's verdict, one line per day, and when the gate last spoke. |
| `personal.json`, `goals.json`, `annotations.json`, `mirror.json`, `school_days.json` | sync job | Calendar events, Todoist goals, duty owners and notes, the work-calendar mirror, school open/closed. |
| `sync.json`, `sync_now` | sync job, Day page | Last run status; an empty flag file that asks for a full run. |
| `nudge.json` | sync job | Which hard-stop nudges went out today. |
| `config.json` | you | Optional gate threshold overrides. |

The sync job writes atomically (temp file, then rename), so a reader never sees half a file.

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
importer, a CalDAV sync, a script). The timer and the Day page only read these five columns.

The Day page can also add or cancel meetings in this file (through the sync job). For that
the table needs the fuller shape
`events(id INTEGER PRIMARY KEY, date, start, end, title, organizer, status, note, source, updated_at)`
plus a `meta(key, value)` table. This repository does not create the file; the job
reports an error on the queue if it is missing.

**Household rules** (`DAY_RULES`): see `day/rules.example.json`. `household` names the
people (`me`, `partner`, `child`), maps calendar roles to your calendar names, and maps
organiser emails to people; `duties` are recurring care tasks with a default owner and
per-weekday overrides; `family_patterns` classify Family-calendar titles as `partner`,
`child` or `family`; `slots` bounds the day for the slot engine.
