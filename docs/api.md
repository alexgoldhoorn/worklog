# HTTP API

The web pages are thin shells over this JSON API, and the Qt and Garmin clients use the
same routes. Authentication is described in the [README](../README.md#authentication).

Conventions:

- Dates are `YYYY-MM-DD`, times are `HH:MM` in the server's `TZ`.
- Errors are `{"error": "..."}` with a 4xx status (400 invalid input, 404 not found,
  409 conflict, 413 for an upload over 10 MB, 503 when the balance store is not configured). An unexpected exception is a 500 `{"error": "internal error"}`. Wrongly typed JSON (a number
  where a string is expected, a list where an object is) is a 400, never a 500.
- Dates must be exactly `YYYY-MM-DD`; forms like `20261109` or `2026-W45-1` are refused.
- Cross-site writes are refused with 403: a non-GET request whose `Sec-Fetch-Site` is not
  `same-origin` or `none`, or (without that header) whose `Origin` names another host. Clients
  that are not browsers send neither header and are unaffected.
- Writes to the timer are serialised by a lock in the server. The database allows one running block.
- Every response carries `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY` and `Referrer-Policy`.
- `/api/start`, `/api/pause` and `/api/stop` take `expect_state` (`working`, `break` or `stopped`): if the timer is in another state the answer is 409 `{"error": "state changed", "state": ...}`. It is ignored when `at` is given.
- `/api/start`, `/api/pause` and `/api/stop` also take `request_id`, a string of 1 to 64 characters. The server remembers the ids of the actions it carried out (the newest 500, kept across restarts); for an id it already acted on it does nothing and answers with the current status (also with `?brief=1`). A refused action (400, 409) is not remembered. It combines with `at` and `expect_state`.
- Times are naive local wall-clock strings in the server's `TZ`. Across a daylight-saving change the status `elapsed_s` and `elapsed_min` are true elapsed time. An `at` in the repeated hour (clocks going back) means the later pass, or the earlier one while the later is still ahead; an `at` in the skipped hour means the valid time after the gap. A block stored in the repeated hour is read as started in its first pass. Closing a block whose wall-clock end is not after its start only because the clocks went back ends it at the last minute before the change (for example `02:59`) and flags it `auto_closed`, so it is listed in `needs_review`.
- `?brief=true` on the timer routes returns a small payload for tiny clients.

## Timer

| Route | Does |
|---|---|
| `GET /healthz` | `{"ok": true}`. Never needs a login. |
| `GET /api/status` | `currency`, state (`working`, `break`, `stopped`), the open block, today's, this week's and this month's totals, net balance, chips (break types with `default_break_type` first), `resume` (the last work block's type and project), notices. |
| `POST /api/start` | Body (all optional): `type`, `project`, `client`. Closes the open block and opens a work block. A break type is refused (use pause). Starting the same work again is a no-op. |
| `POST /api/pause` | Body (optional): `type`, a break type such as `eat`. |
| `POST /api/stop` | Closes the open block. A block of zero minutes is deleted. |
| `GET /api/day/{date}` | Blocks of one day with derived fields and flags, totals, overlap notices, and the work calendar: `meetings` (every meeting of the day, with `logged` and `dismissed`) and `proposals` (those neither logged nor dismissed). A meeting counts as logged when a meeting block (source `calendar` or type `meet`) covers it; work or a break over it does not. |
| `POST /api/blocks` | Add a block: `date`, `start`, optional `end`, `type`, `project`, `client`, `billable`. An `end` that is not after `start` is a 400. |
| `PUT /api/blocks/{id}` | Edit a block. `"require_open": true` fails with 409 if it already ended. An `end` that is not after `start` is a 400. |
| `DELETE /api/blocks/{id}` | Delete a block. |
| `POST /api/calendar/add` | Turn a meeting into a block (`date`, `start`, `end`, `title`). The meeting must have started. Work and break blocks at that time make room: closed ones are trimmed, split or removed, a running one is split around the meeting. Other meeting blocks are left alone. |
| `POST` / `DELETE /api/calendar/dismiss` | Hide or restore a proposal (`date`, `start`, `title`). |

A block left running past midnight is closed automatically at `auto_close_time` the next
time anything reads the timer. Such blocks are flagged `auto_closed` and listed under
`needs_review` in the status. A block that crosses midnight and began before `auto_close_time` is split with both parts flagged. A start, pause or stop replayed with `at` after the auto-close extends the auto-closed block to `at` and clears its flag.

## Reports and expected hours

| Route | Does |
|---|---|
| `GET /api/summary?group=week\|month\|quarter\|year&start=&end=` | Worked, expected and extra hours per group; weekly stats for `week`. A range longer than 3660 days (about ten years) is refused with HTTP 400; `/api/heatmap` and `/api/days` have the same limit. |
| `GET /api/heatmap?start=&end=` | Hours per day for the heat map. |
| `GET /api/invoice?month=YYYY-MM` | Billable days and amounts for one month (needs a `rate`). |
| `GET /api/days?start=&end=` | Expected and sick hours per day. |
| `PUT /api/days/{date}` | Body: `expected_h`, optional `sick_h`, `reason`. |
| `DELETE /api/days/{date}` | Back to the default (holiday, weekday or weekend). |
| `GET` / `PUT /api/settings` | `rate`, `rate_unit` (`h` or `day`), `week_basis_h`; the defaults `default_type` (a work type), `default_client` (or null), `default_break_type` (one of `break_types`, read-only in the answer), `auto_close_time` (`HH:MM`); `currency` (a display symbol or code of 1 to 4 characters after trimming, default `€`; no conversion is done); and `calendar_auto_add` (true: a meeting of today that is over and falls inside logged time is added as a meeting block on the next request, once). |
| `GET /api/clients` | `[{"name", "billable"}]`, sorted by name. `name` is the value blocks carry in `client`. |
| `POST /api/clients` | `{"name", "billable"}` (`billable` defaults to true). 400 for an empty or duplicate name (case-insensitive). Answers the new client. |
| `PUT /api/clients/{name}` | `{"name"?, "billable"?}`. A rename also renames the client on existing blocks and in the `default_client` setting, in one transaction; `billable` changes the client only, not existing blocks. 404 unknown name, 400 duplicate or empty name. Answers the client. |
| `DELETE /api/clients/{name}` | 409 `{"error": ...}` while blocks or `default_client` use it; 404 for an unknown name. |
| `GET /api/break-types` | The break type names, `default_break_type` first (the order of `chips.break_types`). |
| `POST /api/break-types` | `{"name"}`, stored lower case. 400 for an empty or duplicate name (case-insensitive) or a name existing blocks use as a work type. Answers the updated list. |
| `DELETE /api/break-types/{name}` | 409 when it is `default_break_type` or any block uses it; 404 when unknown. Answers the updated list. |
| `GET /api/export.csv`, `/api/export.xlsx` | `start`, `end` optional; defaults to the first logged day until today. At most 7320 days. |
| `POST /api/import` | Multipart: `file` (`.xlsx` or `.csv`), `mode` (`merge` or `replace`), `dry_run=1` to preview, `workdays=1` to import expected days too. `replace` deletes existing blocks in the file's date range. At most 10 MB (413). The import is one transaction. The dry run reports `would_delete_running`, the result `deleted_running` when the running block was in the range. |

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
| `POST /api/balance/blocks`, `/blocks/{id}/approve`, `/blocks/{id}/reject`, `/blocks/{id}/propose` | Create, approve, reject protected blocks, or put an approved or rejected one back to `proposed` (no body; also served at `/blocks/{id}/proposed`). The sync job reconciles from the state: it creates the calendar event of an approved block and deletes the one that a rejected or proposed block still has. |
| `POST /api/balance/propose` | Propose next week's run and hard-stop blocks. |
| `GET /api/balance/outlook` | Plain text listing the week's approved blocks, to paste into an Outlook invite. |
| `GET` / `PUT /api/balance/settings` | Planner settings. |
| `GET /api/balance/queue`, `POST /api/balance/queue/{id}/retry`, `/dismiss` | The write queue the sync job drains. |

The planner routes change often; the source (`day/web.py`, `balance/web/api.py`) is the
reference for request bodies.
