# Anonymous Analytics: First Launch, Saved Minutes And Usage (B21)

Status: design approved on 2026-10-25, events reshaped on 2026-11-04, not implemented. Backlog: B21 in the [MVP checklist](../../product/mvp-implementation-checklist.md), with the consent question and Privacy settings of B18. It replaces the off-by-default consent model of [analytics and crash reporting](../../product/analytics-and-crash-reporting.md) (crash reporting and the GitHub link there are unchanged) and builds on the savings of B31 (`store.AddSaving`, `SavingKind`, the Saved section on the Overview). Context: [gRPC API](../../architecture/grpc-api.md), [workspace persistence](../../architecture/workspace-persistence.md), [security and privacy policy](../../legal/security-privacy-policy.md).

## Goal

Know how many people install Runnir, how many minutes it saves them, and how they use it, without learning who they are or what they work on. Every install reports its first launch once. Saved minutes are reported as anonymous counts by everyone who has not turned analytics off, and the consent question says so. Usage (screens, overlays, actions and how runs and syncs turn out) and a random analytics id that tells installs apart are reported only after the user agrees. Every count reaches the server exactly once, whatever retries, crashes or consent changes happen on the way.

## Decisions Made

| Question | Decision |
| --- | --- |
| Levels | `basic` (default): `first_launch` once and saved-minute counts, no id. `full` (consented): adds usage counts and a random analytics id. `off` (Settings only): nothing |
| What a decline means | "Basic Counts Only": the question states what basic sends; Off is in Settings › Privacy. Sending minutes after a decline the question did not disclose was rejected |
| Usage | Only at `full`. Daily counts per fixed event, never a stream of events: no times, no order, so no funnels. Each event has a category (screen, overlay, action, async) and a product area |
| Event shape | One PostHog event per category or kind of count, with the area and name as properties, so one insight with a breakdown shows a whole category |
| Saved minutes | Sent as raw parts (local, GitHub reference, wall time, cancels), separately; which parts make "saved minutes" is decided when reading the data |
| Where it lives | The Go Core, package `internal/analytics`: it already runs local runs, holds the GitHub cache and counts B31 savings. The app reports what it shows and what the user confirms, and the level, through gRPC. A future CLI or MCP gets it for free |
| Destination | PostHog Cloud US (`us.i.posthog.com`), the existing account, over plain HTTPS from Go. No SDK. The project token and host are the `release` environment's variables `RUNNIR_POSTHOG_PROJECT_TOKEN` and `RUNNIR_POSTHOG_HOST` |
| Deduplication | One ledger per Mac; counts are sealed into immutable daily batches with a random `batch_id`; a retry resends the same batch with the same event `uuid`s, which PostHog merges in ordinary insights; exact SQL takes one event per `batch_id` and kind and does not rely on that merge |
| Duplicates across Macs | Counted only from what this Mac did (its local runs, its cancels, its saved concurrency block). Savings that all Macs of a team see in GitHub data (for example B31's "potential" superseded minutes) are not sent |
| Development builds | Send nothing: the project token goes only into the app built from a tag (alpha, beta, release). Runnir Dev and Runnir Local count, so "What is sent" can be checked |

## Levels

| Level | Sent | Set by |
| --- | --- | --- |
| `basic` | `first_launch` once; `minutes_saved`, `local_runs` and `concurrency_inserted` from the minute counters below; `distinct_id` is the batch's own `batch_id` | Default from the first launch; "Basic Counts Only" in the question; Settings |
| `full` | Everything in `basic`, plus the usage counters; `distinct_id` is the analytics id | "Share Usage Analytics" in the question; Settings |
| `off` | Nothing; nothing is counted | Settings › Privacy only |

The Saved section on the Overview (B31) keeps working at every level: it reads the workspace database, not the analytics ledger.

## First Launch

The Core starts with `--data-dir` and finds no `analytics.sqlite` there. It creates the ledger at `basic` and seals a `first_launch` batch into the outbox at once. The event is sent until the server answers 2xx, always with the same `batch_id`.

- Deleting the app from /Applications keeps Application Support, so a reinstall does not send it again. Erasing Application Support does: Runnir counts installs, not people.
- Keychain is not used for this: it holds credentials only.
- Switching to `off` before the event was delivered drops it.
- No `first_launch` is sent with the analytics id later: the id is never linked to anything sent before consent.

## Consent Question

Shown once, when the first workspace window opens (not on the splash or in the Manager), as a banner at the top of the window's content, like the Core banner: work goes on under it. A sheet was rejected because it blocks the window. Never shown again after an answer; closing the window without answering shows it in the next one. Not shown when the ledger is not on disk (no data folder, as in UI tests, or another copy of Runnir holds it).

Copy (English UI; drawn in `runnir.pen`, S03 "Analytics question"):

> **Help improve Runnir**
>
> Runnir sends a few anonymous counts: that it was installed, and how many minutes local runs and cancelled runs saved. They carry no id.
>
> With your permission, Runnir also counts which screens, panels and actions you use and how runs and syncs turn out, with a random id that is not linked to you, your Mac or GitHub. This shows how many people use each feature.
>
> Runnir never sends code, repository, workflow or branch names, paths, logs or anything you type. Data is stored by PostHog in the United States. You can change this or turn everything off in Settings › Privacy.
>
> [Basic Counts Only] [Share Usage Analytics]

Both buttons have equal weight; neither is the default button.

## Settings › Privacy

Replaces the current "Telemetry" text in `SettingsOverlay.swift`.

- Analytics: radio choices Off, Basic counts, Usage analytics, each with one line on what it sends.
- What is sent: a disclosure listing, with their values, the counts sealed and waiting to be sent and the counts of today, which are sealed tomorrow, read from `GetAnalytics`, so the user sees the real payload.
- At `full`: the analytics id with Copy, for a deletion request.
- In a build without the PostHog project token (Runnir Dev, Runnir Local): "Sending is off in this build". Such a build counts, so "What is sent" can be checked, but never sends.

## Level Changes

| Change | Effect |
| --- | --- |
| `basic → full` | A new random id (UUID v4). Counts sealed before this moment stay without id |
| `full → basic` | The id is deleted. Unsealed usage counters are deleted. Outbox batches lose the id and the usage counters but keep their `batch_id`, so a batch already delivered before the change is still read once |
| `full → basic → full` | A new id each time: the periods before and after cannot be joined |
| any `→ off` | Counters and outbox are emptied; nothing is counted or sent until the level changes |
| `off → basic` or `full` | Counting starts from zero; no `first_launch` again |

## Ledger And Deduplication

`analytics.sqlite` in the data folder, one per Mac, beside the workspace databases. The Core is its only writer: the ledger takes its own file lock (`analytics.lock`), and a second copy of Runnir keeps an in-memory ledger that never sends. Without `--data-dir` the ledger is in memory and never sends. A damaged ledger, or one with another schema, is replaced at level Off with the question unanswered, so a user who chose Off never sends because of a damaged file.

Tables:

- `state`: level, analytics id (empty unless `full`), whether the question was answered.
- `counters`: `(day, name) → value`. `day` is the UTC date. Every increment is one transaction.
- `outbox`: sealed batches: `batch_id`, `day`, the event body as JSON, attempts, next attempt time.

Cycle:

1. **Count.** A counter increments in one transaction, only if the level allows that counter (minute counters at `basic` and `full`, usage counters at `full`). Names outside the allowlist are rejected.
2. **Seal.** At Core start and every 6 hours, one transaction turns each completed UTC day in `counters` into one batch in `outbox` with a new `batch_id`, and deletes those rows. Every increment is in exactly one batch. Today's counts leave tomorrow or later; no event carries a time finer than the day.
3. **Send.** One minute after Core start and every 6 hours, the outbox goes to PostHog's `/batch/` endpoint. A batch becomes several events (see Events), all in the same request. On 2xx the sent batches are deleted. On a network error, a timeout or a 5xx they stay and are retried with backoff (1 min, 5 min, 30 min, 6 h), with the same `batch_id` and the same event `uuid`s. On another status they are kept for the next send and the status is logged to the Core's stderr (the log the app shows) as one line, without the body. The payload check is the allowlist itself: `Add` refuses any other name and the event builder refuses to build an event with one, because PostHog answers 200 to events it then drops.
4. **Read.** Every event of a batch carries a `uuid` made from the `batch_id` and the event's kind, so a resend after a lost response repeats the same event and PostHog merges it: ordinary insights count it once. Exact SQL takes one event per `batch_id` and kind.

Bounds: the outbox keeps at most 256 KiB and 7 days of batches; the oldest are dropped first. `counters` rows older than 7 days are dropped at sealing.

## Events

All events go to `<host>/batch/` (`RUNNIR_POSTHOG_HOST`, `https://us.i.posthog.com`). A sealed batch becomes one event per kind below with a value that is not zero.

Every event has these properties:

| Property | Value |
| --- | --- |
| `batch_id` | The batch's random id |
| `day` | The UTC day of the counts, `2026-11-04` |
| `level` | `basic` or `full` |
| `app_version` | `0.1.0-alpha.1`; the channel shows in it |
| `os_version`, `arch` | `26.1`, `arm64` |
| `$lib` | `runnir-core` |
| `$process_person_profile` | `false`: no person profiles |
| `$geoip_disable` | `true`; the PostHog project also discards client IP data |

The `timestamp` is midnight UTC of the day. `distinct_id` is the `batch_id` at `basic` and the analytics id at `full`. The `uuid` is a name-based UUID of the `batch_id` and the event's kind (its name, plus `source`, `area` and `name` where it has them).

| Event | Level | One per | Its own properties |
| --- | --- | --- | --- |
| `first_launch` | `basic`, `full` | install | none |
| `minutes_saved` | `basic`, `full` | day and source | `source`: `local_run`, `local_run_without_dispatch`, `superseded_cancel` or `concurrency_cancel`; `minutes`; `runs` |
| `local_runs` | `basic`, `full` | day | `jobs_succeeded`, `jobs_failed`, `jobs_cancelled`, `job_seconds`, `workflow_runs`, `workflow_wall_seconds`, `gh_ref_jobs_matched`, `gh_ref_billed_minutes`, `local_billed_minutes_matched`, `gh_ref_runs_matched`, `gh_ref_run_wall_seconds` |
| `concurrency_inserted` | `basic`, `full` | day | `count` |
| `screen_viewed` | `full` | day and screen | `area`, `name`, `count` |
| `overlay_viewed` | `full` | day and overlay | `area`, `name`, `count` |
| `action_used` | `full` | day and action | `area`, `name`, `count` |
| `async_event` | `full` | day and event | `area`, `name`, `count` |

`minutes_saved` comes from the minute counters, and its sources do not overlap, so a sum over every source is the total: `local_run_without_dispatch` from `local_billed_minutes_without_dispatch` and `local_runs_without_dispatch`, `local_run` from `local_billed_minutes` and `local_runs` less those, `superseded_cancel` from `superseded_cancel_minutes_est` and `superseded_cancels`, `concurrency_cancel` from `concurrency_minutes_est` and `concurrency_cancels`. `local_runs` holds the other local run counters without their `local_` prefix (`local_runs_completed` is `workflow_runs`, `local_run_wall_seconds` is `workflow_wall_seconds`).

## Reading The Data

The events are shaped for PostHog's Trends insights; a dashboard needs no SQL:

| Insight | Series |
| --- | --- |
| Installs | `first_launch`, total count, weekly; breakdown by `app_version`, `os_version` or `arch` |
| Minutes saved | `minutes_saved`, sum of `minutes`, breakdown by `source`; `local_run_without_dispatch` is what GitHub could not have started by hand |
| Local runs | `local_runs`, sum of `jobs_succeeded`, `jobs_failed` and `jobs_cancelled`; success rate as a formula |
| Waiting saved | `local_runs`, sum of `gh_ref_run_wall_seconds` minus sum of `workflow_wall_seconds` (formula) |
| Screens, overlays, actions | `screen_viewed`, `overlay_viewed` or `action_used`, sum of `count` and unique users, breakdown by `name`, filtered by `area` |
| An area across categories | All four usage events, filtered by one `area` |
| Health | `async_event`, sum of `count`, breakdown by `name` (`github.rate_limited`, `local_run.failed`, `app.core_restarted`) |
| People who agreed | Unique users of the usage events per day or week; retention on them |

At `basic` there is no id that lasts beyond a day, so there are no daily or weekly users at `basic`; unique users of a `basic` event on one day are the installs that had it that day.

## Metrics

Minute counters (`basic` and `full`). Raw parts; totals and differences are computed when reading.

| Counter | Meaning |
| --- | --- |
| `local_runs` | Local runs on this Mac that ended succeeded or failed: B31's `LOCAL_RUNS` count, added at the same moment as `AddSaving` |
| `local_billed_minutes` | Their jobs' time, each job rounded up to a whole minute (at least one), as GitHub bills hosted runners: B31's `LOCAL_RUNS` minutes, the number on the Saved tile |
| `local_runs_without_dispatch`, `local_billed_minutes_without_dispatch` | Of those, the runs of a workflow without a `workflow_dispatch` trigger: GitHub cannot start it by hand, only on a push, a pull request or another event, while Runnir runs it directly |
| `local_jobs_succeeded`, `local_jobs_failed`, `local_jobs_cancelled` | Jobs run by act on this Mac, by result |
| `local_job_seconds` | Those jobs' total local time |
| `gh_ref_jobs_matched` | How many of the succeeded or failed local jobs have a reference on GitHub: the latest completed run of a job with the same name in the same workflow file, in the workspace cache |
| `gh_ref_billed_minutes` | The references' GitHub durations, each rounded up to a whole minute |
| `local_billed_minutes_matched` | The local billed minutes of those same matched jobs, to compare like with like |
| `local_runs_completed`, `local_run_wall_seconds` | Local runs of a whole workflow (and, once scenarios ship, of a whole scenario) from start to end |
| `gh_ref_runs_matched`, `gh_ref_run_wall_seconds` | For those, the latest completed GitHub run of the same workflow (or scenario), from creation to its last update: queue plus execution. The difference from local wall time is the developer's wait |
| `superseded_cancels`, `superseded_cancel_minutes_est` | Superseded runs (B30's `superseded_by` set) cancelled with Runnir's Cancel on this Mac, counted when GitHub accepts the cancel. Estimate per run: the median duration of that workflow's successful runs in the cache minus the time it had run, at least 0, rounded up |
| `concurrency_inserted` | Workflow files saved on this Mac with a `concurrency` block inserted by B30's suggestion (`InsertWorkflowConcurrency` then `SaveWorkflowFile` of the same file). The workspace database records the file and the save time |
| `concurrency_cancels`, `concurrency_minutes_est` | Runs of such a workflow, created after that save, that GitHub ended cancelled while superseded. Counted only by the Mac that saved the block; each run id is recorded in the workspace database so a later sync does not count it again. Estimate as for `superseded_cancels` |

Usage counters (`full` only). Each is one `UsageEvent` value of the proto, named `USAGE_EVENT_<CATEGORY>_<AREA>_<NAME>`; the Core reads its category, area and name from that name with a list of areas, and a test fails for a value that does not read. In the ledger a usage counter is `<category>:<name>`, for example `overlay:settings.privacy`. The app counts what it shows and what the user confirms (`RecordUsage`); the Core counts what it does itself.

| Category | Counted when | Counted by |
| --- | --- | --- |
| `screen` | The window's sidebar section, the Workspace tab or the Manager's tab changes to it by a click; jumps made by other buttons and the Manager opening are not counted | App |
| `overlay` | An overlay, sheet or panel opens | App |
| `action` | The user confirms an action | App, or the Core where it does the work |
| `async` | Something ends or happens without the user: a run's result, a GitHub error, a restart | Core, or the app for what only it sees |

| Area | `screen` | `overlay` | `action` | `async` |
| --- | --- | --- | --- | --- |
| `overview` | `overview.page` | | | |
| `workflows` | `workflows.list` | | `workflows.favorite` (a workflow or repository starred) | |
| `runs` | `runs.list` | `runs.dispatch` (Run Workflow) | `runs.dispatch`, `runs.cancel`, `runs.rerun` (any rerun) (Core, when GitHub accepts) | |
| `local_run` | `local_run.history` (Workspace › Local Run) | `local_run.review`, `local_run.limits`, `local_run.skipped_job` | `local_run.run` (Core, when it starts) | `local_run.succeeded`, `local_run.failed`, `local_run.cancelled` (Core) |
| `editor` | `editor.workflow` (Workspace › Editor) | `editor.file_name` (new or renamed file) | `editor.save`, `editor.create`, `editor.rename`, `editor.insert_concurrency` (Core), `editor.validate` (started by the user, not the check after a save) | |
| `secrets` | `secrets.values` | | `secrets.import_env` | |
| `presets` | | | `presets.save` (a Mac preset), `presets.apply` (any preset) | |
| `logs` | | `logs.viewer` | `logs.save` (saved and opened in an editor; Core) | |
| `workspaces` | `workspaces.manager` | | | |
| `github` | `github.manager` | `github.connect`, `github.enterprise_server` | `github.open_on_github` (any Open on GitHub link) | `github.sync_failed`, `github.rate_limited`, `github.token_rejected` (Core, once when a workspace's sync turns to that outcome, not on every retry) |
| `settings` | | `settings.account`, `settings.runs`, `settings.notifications`, `settings.pull_requests`, `settings.tools`, `settings.storage`, `settings.privacy` | | |
| `search` | | `search.global` | | |
| `notifications` | | `notifications.panel` | | `notifications.delivered` |
| `pull_requests` | | `pull_requests.menu_bar` | | |
| `app` | | `app.diagnostics`, `app.bug_report` | `app.report_bug` (a prefilled issue page opens) | `app.core_restarted` |

Adding an event later is a proto value, a row here, and the call where it happens; a new area is also added to the Core's list.

Never sent at any level: repository, owner, workflow, job, branch, tag or preset names; paths; SHAs; run, job or pull request numbers; hashes of any of these; error messages; logs; anything the user typed.

## Code

Core, `core/internal/analytics`:

- `Ledger`: opens `analytics.sqlite` (modernc.org/sqlite, as the workspace databases), holds the level and the id, `Add(at, counts)` with the allowlist, `Record(at, event)` for usage, `Seal()`, level changes.
- `Sender`: builds the PostHog events, sends the outbox, backoff. The project token and host come from `buildinfo` (`-ldflags` in `scripts/build-core-macos.sh`, from the `release` environment's `RUNNIR_POSTHOG_PROJECT_TOKEN` and `RUNNIR_POSTHOG_HOST`, only for the app of a tag); an empty token disables sending.
- Hooks: next to `AddSaving` in `workspace/runtimes.go` (`local_runs`, `local_billed_minutes`, job counters and GitHub references from the workspace store); the run-action confirmation for cancels; `SaveWorkflowFile` after `InsertWorkflowConcurrency` for `concurrency_inserted`; the sync pass for `concurrency_cancels`.

gRPC (contract changed in place; no compatibility before the first release tag):

| Method | Meaning |
| --- | --- |
| `GetAnalytics()` | Level, question answered, sending available in this build, the analytics id at `full`, and for "What is sent" the sealed counts and today's |
| `SetAnalyticsLevel(level, from_prompt)` | Changes the level as in Level Changes; `from_prompt` marks the question answered |
| `RecordUsage(UsageEvent)` | Adds one to a usage counter; ignored unless the level is `full` |

App:

- `AnalyticsModel` (Observation): reads `GetAnalytics`, decides whether to ask, changes the level.
- The consent banner (O10) and Settings › Privacy (S12) above.
- `CoreHub.recordUsage(_:)`: one call at each point of the usage table that the app counts; it does nothing unless the level is `full`.

## Tests

Core (deterministic: injected clock, random source and HTTP client):

- Every increment ends up in exactly one batch across seal, crash between seal and send, and restart.
- A retry after a failed or unanswered send uses the same `batch_id`; 2xx deletes; 5xx and timeouts keep with backoff.
- `first_launch` is sealed once across restarts and dropped by `off` before delivery.
- `full → basic` strips the id and usage counters from the outbox and keeps `batch_id`; `→ off` empties both tables; each new `full` gets a new id.
- Usage counters are refused at `basic`; unknown names are refused at every level; every `UsageEvent` value has a row in the table.
- A batch becomes the events above, with the same `uuid`s when resent.
- Bounds: 256 KiB and 7 days, oldest dropped first.
- No key or no data folder: nothing is sent.
- A fake PostHog server receives bodies that match the schema; the event builder refuses a counter outside the allowlist.
- Minute counters: a local run adds the same minutes to `local_billed_minutes` as to the B31 saving; a cancel and a concurrency cancel are counted once across repeated syncs and only on the Mac that saved the block.

App:

- The question shows once, not after an answer, not without a ledger on disk; both buttons set the right level.
- Settings shows the level, the sealed and today's counts and the id at `full` from a fake Core.
- `recordUsage` calls nothing below `full`.

## Documents To Change With The Implementation

- `AGENTS.md`: "Do not add telemetry by default" becomes "Anonymous counts without an id (first launch, saved minutes) are on by default, disclosed in the consent question and can be turned off; anything else needs consent".
- [Specification](../../product/specification.md): FR-07 and the "No telemetry by default" lines.
- [README](../../../README.md): a line on what is sent by default and with consent; the documents link no longer says "Optional analytics".
- [SECURITY.md](../../../SECURITY.md): "No telemetry by default" becomes the disclosed anonymous counts, which can be turned off.
- The Settings entry of the global search (`GlobalSearch.swift`): "Telemetry, Runnir does not enable telemetry by default" becomes "Analytics" with what is sent by default and with consent.
- [Analytics and crash reporting](../../product/analytics-and-crash-reporting.md): levels, consent and the metrics table (done with this design).
- [Security and privacy policy](../../legal/security-privacy-policy.md): what each level sends, PostHog in the US, IP not kept, retention, how to ask for deletion with the analytics id.
- [Screens and states](../../design/screens-and-states.md): O10 and S12.
- [MVP checklist](../../product/mvp-implementation-checklist.md): B18 and B21.
- [gRPC API](../../architecture/grpc-api.md): the three methods.

## Manual Setup In PostHog

Done by the account owner before the first tag build that sends:

- Use the US project; turn on "Discard client IP data".
- Check the plan's event retention and write it into the privacy policy.
- Create the insights of Reading The Data.

## Order Of Work

1. Ledger, sealing, sending, `first_launch`, levels and gRPC; the question and Settings.
2. Minute counters from local runs and GitHub references.
3. Usage counters.
4. Cancel and concurrency counters.

## Out Of Scope

Crash reporting and automatic issue creation (unchanged, see analytics and crash reporting); B31's "potential" superseded minutes; a public counter of minutes saved on the landing page (it can read PostHog later); exact daily or weekly active users at `basic`.
