# worklog

A self-hosted work/break timer with reports, plus an optional day planner that protects
your evenings and training time.

- **Timer** (`/timer`): start, pause and stop work blocks; switch type or project; the day's
  blocks with gaps; meeting proposals from a work-calendar database.
- **Pomodoro**: a per-device countdown that *offers* to pause or resume the timer at each
  interval, never on its own.
- **Reports**: summaries per week, month, quarter and year, charts, weekly stats, an invoice
  view, XLSX/CSV import and export.
- **Days**: expected and sick hours per day, with holidays from a cache file.
- **Day dashboard** (`/`) and **Week** (`/week`), optional: one timeline of work meetings,
  personal and family calendars, care duties (school runs) and protected blocks; a capacity
  gate (green/amber/red over rolling weeks of hours, wellness and training); "where does this
  fit" and "move this" helpers.

Clients that talk to the same JSON API:

- a Qt Quick app for desktop and Android (`qt/`)
- a Garmin Connect IQ widget with a glance (`garmin/`, see [garmin/README.md](garmin/README.md))

Everything personal (people, calendars, timezone, holiday scopes, paths, credentials) is
configuration. Nothing is hardcoded to one household or one server.

## Quick start

```sh
uv sync
export WORKLOG_DB=./data/worklog.db TZ=Europe/Amsterdam
uv run uvicorn worklog.web.app:factory --factory --port 8503
```

Open <http://127.0.0.1:8503/timer>. The app is created by `factory()` (there is no
module-level `app`), which reads its settings from the environment through
`worklog/config.py`.

To require a login, hash a password and set both variables:

```sh
uv run python -m worklog.auth          # prints a pbkdf2_sha256 hash
export WORKLOG_AUTH_USER=me WORKLOG_AUTH_PASSWORD_HASH='pbkdf2_sha256:...'
```

All variables are listed in [docs/configuration.md](docs/configuration.md); a starting
point is [examples/worklog.env.example](examples/worklog.env.example).

## Docker

```sh
docker build -t worklog .
docker run --rm -p 8503:8000 -v "$PWD/data:/data" -e WORKLOG_DB=/data/worklog.db -e TZ=Europe/Amsterdam worklog
```

The image runs as uid 1000 and listens on port 8000. Health check: `GET /healthz`. A compose
file with the optional mounts is in [examples/docker-compose.yml](examples/docker-compose.yml).

Error reporting is optional: set `WORKLOG_SENTRY_DSN` to a Sentry (or Sentry-compatible) DSN
and unhandled exceptions are reported; expected 4xx errors are not. Unset, `sentry_sdk` is
never imported.

## The day planner (optional)

The timer works on its own. The Day and Week pages add three things around it:

1. **Household rules**: copy [day/rules.example.json](day/rules.example.json), edit the
   people, calendar names, care duties and timezone, and point `DAY_RULES` at it.
2. **Inputs**: JSON snapshots and data files in a state directory (calendar events, Todoist
   goals, a training plan, wellness). Formats are in [docs/configuration.md](docs/configuration.md).
3. **Host jobs** that fill the state directory and push approved blocks to Google Calendar:

   ```sh
   uv run python -m balance.jobs.gate      # daily: the capacity verdict
   uv run python -m balance.jobs.sync      # every 2 min: snapshots, write queue, mirror, nudge
   uv run python -m balance.jobs.propose   # weekly: next week's run and hard-stop blocks
   ```

   They run without any integration and report what is missing. Calendar fetching, Google
   OAuth and the school calendar come from an optional host library; see
   [docs/host-integration.md](docs/host-integration.md).

The container never holds credentials: it only reads the state directory and writes its
requests to a queue in `balance.db`, which the sync job drains.

## Tests

```sh
uv run pytest -q
```

The suite runs against the example household (`day/rules.example.json`). The Excel parity
test is skipped unless `WORKLOG_EXCEL` points at a spreadsheet to compare against.

## Packages

- `worklog/`: timer, blocks, reports, the web app and its JSON API (`worklog/web/api.py`).
- `balance/`: capacity gate, protection blocks, snapshots, the Google mirror, the hard-stop
  nudge and the job runners (`balance/jobs/`).
- `day/`: the Day dashboard model, the slot engine behind "find" and "move", and its API.

## Contributing

Install the pre-commit hook once: `scripts/git-hooks/install.sh`. It refuses data files and
local config, checks staged text against your own deny list
(`~/.config/worklog/deny-patterns.txt`, one regex per line, never committed) and runs the
tests.

## License

MIT, see [LICENSE](LICENSE).
