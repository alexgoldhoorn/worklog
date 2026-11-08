# HTTP API

The web pages are thin shells over this JSON API, and the Qt and Garmin clients use the
same routes. Authentication is described in the [README](../README.md#authentication).

Conventions:

- Dates are `YYYY-MM-DD`, times are `HH:MM` in the server's `TZ`.
- Errors are `{"error": "..."}` with a 4xx status (400 invalid input, 404 not found,
  409 conflict, 503 when the balance store is not configured). Wrongly typed JSON (a number
  where a string is expected, a list where an object is) is a 400, never a 500.
- Dates must be exactly `YYYY-MM-DD`; forms like `20261109` or `2026-W45-1` are refused.
- Cross-site writes are refused with 403: a non-GET request whose `Sec-Fetch-Site` is not
  `same-origin` or `none`, or (without that header) whose `Origin` names another host. Clients
  that are not browsers send neither header and are unaffected.
- Writes to the timer are serialised by a lock in the server.
- `?brief=true` on the timer routes returns a small payload for tiny clients.

## Timer

| Route | Does |
|---|---|
| `GET /healthz` | `{"ok": true}`. Never needs a login. |
| `GET /api/status` | State (`working`, `break`, `stopped`), the open block, today's, this week's and this month's totals, net balance, chips, notices. |
| `POST /api/start` | Body (all optional): `type`, `project`, `client`. Closes the open block and opens a work block. A break type is refused (use pause). Starting the same work again is a no-op. |
| `POST /api/pause` | Body (optional): `type`, a break type such as `eat`. |
| `POST /api/stop` | Closes the open block. A block of zero minutes is deleted. |
| `GET /api/day/{date}` | Blocks of one day with derived fields and flags, totals, meeting proposals, overlap notices. |
| `POST /api/blocks` | Add a block: `date`, `start`, optional `end`, `type`, `project`, `client`, `billable`. |
| `PUT /api/blocks/{id}` | Edit a block. `"require_open": true` fails with 409 if it already ended. |
| `DELETE /api/blocks/{id}` | Delete a block. |
| `POST /api/calendar/add` | Turn a meeting proposal into a block (`date`, `start`, `end`, `title`). The meeting must have started. If a block was running, it is split around the meeting. |
| `POST` / `DELETE /api/calendar/dismiss` | Hide or restore a proposal (`date`, `start`, `title`). |

A block left running past midnight is closed automatically at `auto_close_time` the next
time anything reads the timer. Such blocks are flagged `auto_closed` and listed under
`needs_review` in the status.

## Reports and expected hours

| Route | Does |
|---|---|
| `GET /api/summary?group=week\|month\|quarter\|year&start=&end=` | Worked, expected and extra hours per group; weekly stats for `week`. A range longer than 3660 days (about ten years) is refused with HTTP 400. |
| `GET /api/heatmap?start=&end=` | Hours per day for the heat map. |
| `GET /api/invoice?month=YYYY-MM` | Billable days and amounts for one month (needs a `rate`). |
| `GET /api/days?start=&end=` | Expected and sick hours per day. |
| `PUT /api/days/{date}` | Body: `expected_h`, optional `sick_h`, `reason`. |
| `DELETE /api/days/{date}` | Back to the default (holiday, weekday or weekend). |
| `GET` / `PUT /api/settings` | `rate`, `rate_unit` (`h` or `day`), `week_basis_h`. |
| `GET /api/export.csv`, `/api/export.xlsx` | `start`, `end` optional; defaults to the first logged day until today. |
| `POST /api/import` | Multipart: `file` (`.xlsx` or `.csv`), `mode` (`merge` or `replace`), `dry_run=1` to preview, `workdays=1` to import expected days too. `replace` deletes existing blocks in the file's date range. |

## Planner (needs `BALANCE_DB` and `BALANCE_STATE_DIR`)

| Route | Does |
|---|---|
| `GET /api/day?date=` | The Day page model: merged timeline, duties, blocks, gate. |
| `POST /api/day/slots`, `/move`, `/find` | The slot engine: where something fits, and what moving it changes. |
| `POST /api/day/prep`, `/owner`, `/classify` | Prep notes, duty owners, Family-event classes. Some of these also queue a write for the sync job. |
| `GET /api/day/classify/rules`, `DELETE /api/day/classify/rules/{id}` | Title patterns that classify Family events. |
| `POST /api/day/workcal/parse`, `/workcal/add`, `/workcal/annotate`, `/calendar-pdf` | Work-calendar catch-up and PDF upload. |
| `POST /api/day/task/{id}/complete` | Queue "complete this Todoist task". |
| `POST /api/day/refresh` | Ask the sync job for a full run (touches a `sync_now` flag file). |
| `GET /api/balance/week?start=` | The week view: events, blocks, gate, goals, history. |
| `POST /api/balance/blocks`, `/blocks/{id}/approve`, `/blocks/{id}/reject` | Create, approve or reject protected blocks. |
| `POST /api/balance/propose` | Propose next week's run and hard-stop blocks. |
| `GET /api/balance/outlook` | Plain text listing the week's approved blocks, to paste into an Outlook invite. |
| `GET` / `PUT /api/balance/settings` | Planner settings. |
| `GET /api/balance/queue`, `POST /api/balance/queue/{id}/retry`, `/dismiss` | The write queue the sync job drains. |

The planner routes change often; the source (`day/web.py`, `balance/web/api.py`) is the
reference for request bodies.
