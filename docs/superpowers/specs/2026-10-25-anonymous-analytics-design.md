# Anonymous Analytics: First Launch, Saved Minutes And Usage (B21)

Status: design approved on 2026-10-25, not implemented. Backlog: B21 in the [MVP checklist](../../product/mvp-implementation-checklist.md), with the consent prompt and Privacy settings of B18. It replaces the off-by-default consent model of [analytics and crash reporting](../../product/analytics-and-crash-reporting.md) (crash reporting and the GitHub link there are unchanged) and builds on the savings of B31 (`store.AddSaving`, `SavingKind`, the Saved section on the Overview). Context: [gRPC API](../../architecture/grpc-api.md), [workspace persistence](../../architecture/workspace-persistence.md), [security and privacy policy](../../legal/security-privacy-policy.md).

## Goal

Know how many people install Runnir, how many minutes it saves them, and which sections and actions they use, without learning who they are or what they work on. Every install reports its first launch once. Saved minutes are reported as anonymous counts by everyone who has not turned analytics off, and the consent prompt says so. Clicks on sections and actions, and a random analytics id that tells installs apart, are reported only after the user agrees. Every count reaches the server exactly once, whatever retries, crashes or consent changes happen on the way.

## Decisions Made

| Question | Decision |
| --- | --- |
| Levels | `basic` (default): `first_launch` once and saved-minute counts, no id. `full` (consented): adds section and action counts and a random analytics id. `off` (Settings only): nothing |
| What a decline means | "Basic Counts Only": the prompt states what basic sends; Off is in Settings › Privacy. Sending minutes after a decline the prompt did not disclose was rejected |
| Clicks | Only at `full`. Daily counts per fixed name, never a stream of events: no times, no order |
| Saved minutes | Sent as raw parts (local, GitHub reference, wall time, cancels), separately; which parts make "saved minutes" is decided when reading the data |
| Where it lives | The Go Core, package `internal/analytics`: it already runs local runs, holds the GitHub cache and counts B31 savings. The app reports clicks and the level through gRPC. A future CLI or MCP gets it for free |
| Destination | PostHog Cloud US (`us.i.posthog.com`), the existing account, over plain HTTPS from Go. No SDK |
| Deduplication | One ledger per Mac; counts are sealed into immutable daily batches with a random `batch_id`; a retry resends the same batch; every read takes one event per `batch_id`. PostHog's own handling of repeated events is not relied on |
| Duplicates across Macs | Counted only from what this Mac did (its local runs, its cancels, its saved concurrency block). Savings that all Macs of a team see in GitHub data (for example B31's "potential" superseded minutes) are not sent |
| Development builds | Send nothing: the PostHog key is set only in Release builds |

## Levels

| Level | Sent | Set by |
| --- | --- | --- |
| `basic` | `first_launch` once; `usage_day` with the minute counters below; `distinct_id` is the batch's own `batch_id` | Default from the first launch; "Basic Counts Only" in the prompt; Settings |
| `full` | Everything in `basic`, plus the section and action counters; `distinct_id` is the analytics id | "Share Usage Analytics" in the prompt; Settings |
| `off` | Nothing; nothing is counted | Settings › Privacy only |

The Saved section on the Overview (B31) keeps working at every level: it reads the workspace database, not the analytics ledger.

## First Launch

The Core starts with `--data-dir` and finds no `analytics.sqlite` there. It creates the ledger at `basic` and seals a `first_launch` batch into the outbox at once. The event is sent until the server answers 2xx, always with the same `batch_id`.

- Deleting the app from /Applications keeps Application Support, so a reinstall does not send it again. Erasing Application Support does: Runnir counts installs, not people.
- Keychain is not used for this: it holds credentials only.
- Switching to `off` before the event was delivered drops it.
- No `first_launch` is sent with the analytics id later: the id is never linked to anything sent before consent.

## Consent Prompt

Shown once, when the first workspace window opens (not on the splash or in the Manager), as a non-blocking sheet the user can leave open while working. Never shown again after an answer; closing the window without answering shows it next time. Not shown when the Core runs without `--data-dir` (UI tests).

Copy (English UI; final wording in design review):

> **Help improve Runnir**
>
> Runnir sends a few anonymous counts: that it was installed, and how many minutes local runs and cancelled runs saved. They carry no id.
>
> With your permission, Runnir also counts which sections and actions you use, with a random id that is not linked to you, your Mac or GitHub. This shows how many people use each feature.
>
> Runnir never sends code, repository, workflow or branch names, paths, logs or anything you type. Data is stored by PostHog in the United States. You can change this or turn everything off in Settings › Privacy.
>
> [Basic Counts Only] [Share Usage Analytics]

Both buttons have equal weight; neither is preselected as the default button.

## Settings › Privacy

Replaces the current "Telemetry" text in `SettingsOverlay.swift`.

- Analytics: a picker with Off, Basic counts, Usage analytics, each with one line on what it sends.
- What is sent: a disclosure listing the counters waiting in the ledger and the outbox with their values, read from `GetAnalytics`, so the user sees the real payload.
- At `full`: the analytics id with Copy, for a deletion request.
- In a build without a PostHog key: "Sending is off in this build".

## Level Changes

| Change | Effect |
| --- | --- |
| `basic → full` | A new random id (UUID v4). Counts sealed before this moment stay without id |
| `full → basic` | The id is deleted. Unsealed click counters are deleted. Outbox batches lose the id and the click counters but keep their `batch_id`, so a batch already delivered before the change is still read once |
| `full → basic → full` | A new id each time: the periods before and after cannot be joined |
| any `→ off` | Counters and outbox are emptied; nothing is counted or sent until the level changes |
| `off → basic` or `full` | Counting starts from zero; no `first_launch` again |

## Ledger And Deduplication

`analytics.sqlite` in the data folder, one per Mac, beside the workspace databases. The Core is its only writer (the existing instance lock keeps a second Core out). Without `--data-dir` the ledger is in memory and never sends.

Tables:

- `state`: level, analytics id (null unless `full`), whether the prompt was answered, whether `first_launch` was sealed.
- `counters`: `(day, name) → value`. `day` is the UTC date. Every increment is one transaction.
- `outbox`: sealed batches: `batch_id`, `day`, the event body as JSON, attempts, next attempt time.

Cycle:

1. **Count.** A counter increments in one transaction, only if the level allows that counter (minute counters at `basic` and `full`, click counters at `full`). Names outside the allowlist are rejected.
2. **Seal.** At Core start and every 6 hours, one transaction turns each completed UTC day in `counters` into one batch in `outbox` with a new `batch_id`, and deletes those rows. Every increment is in exactly one batch. Today's counts leave tomorrow or later; no event carries a time finer than the day.
3. **Send.** One minute after Core start and every 6 hours, the outbox goes to PostHog's `/batch/` endpoint, at most 50 events per request. On 2xx the sent batches are deleted. On a network error, a timeout or a 5xx they stay and are retried with backoff (1 min, 5 min, 30 min, 6 h), with the same `batch_id`. On another status they are kept for the next send and the status is logged in the Core log, without the body. Bodies are checked against the schema before sealing, because PostHog answers 200 to events it then drops.
4. **Read.** Every insight or SQL query that sums counters takes one event per `batch_id`. A lost response followed by a resend is then counted once.

Bounds: the outbox keeps at most 256 KiB and 7 days of batches; the oldest are dropped first. `counters` rows older than 7 days are dropped at sealing.

## Events

Both events go to `https://us.i.posthog.com/batch/`. Every event has `$process_person_profile: false` (no person profiles) and `$geoip_disable: true`; the PostHog project discards client IP data. The `timestamp` is midnight UTC of the event's day.

`first_launch`:

```json
{
  "event": "first_launch",
  "distinct_id": "<batch_id>",
  "timestamp": "2026-10-25T00:00:00Z",
  "properties": {
    "batch_id": "<batch_id>",
    "app_version": "0.2.0",
    "app_build": "42",
    "os_version": "26.1",
    "arch": "arm64",
    "$process_person_profile": false,
    "$geoip_disable": true,
    "$lib": "runnir-core"
  }
}
```

`usage_day`, one per sealed batch: the same properties plus `day`, `level` (`basic` or `full`) and the counters of that day that are not zero. `distinct_id` is the `batch_id` at `basic` and the analytics id at `full`.

## Metrics

Minute counters (`basic` and `full`). Raw parts; totals and differences are computed when reading.

| Counter | Meaning |
| --- | --- |
| `local_runs` | Local runs on this Mac that ended succeeded or failed: B31's `LOCAL_RUNS` count, added at the same moment as `AddSaving` |
| `local_billed_minutes` | Their jobs' time, each job rounded up to a whole minute (at least one), as GitHub bills hosted runners: B31's `LOCAL_RUNS` minutes, the number on the Saved tile |
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

Click counters (`full` only). Each names one `UsageEvent` value of the proto; the property is its lowercase name without the enum prefix.

| Counter | Counted when |
| --- | --- |
| `screen_overview`, `screen_workflows`, `screen_runs`, `screen_workspace` | The window's sidebar section changes to it |
| `screen_workspace_editor`, `screen_workspace_local_run` | The Workspace tab changes to it |
| `screen_manager_workspaces`, `screen_manager_github` | The Manager's tab changes to it, or the Manager opens on it |
| `screen_settings_<section>` | A Settings section opens (`account`, `runs`, `notifications`, `pull_requests`, `tools`, `storage`, `privacy`) |
| `screen_menu_bar` | The menu bar's pull request list opens |
| `action_run_local`, `action_run_scenario_local` | A local run is confirmed |
| `action_dispatch` | A workflow dispatch is confirmed |
| `action_cancel_run`, `action_rerun` | A GitHub run action is confirmed |
| `action_save_workflow`, `action_create_workflow`, `action_rename_workflow` | The Core saves, creates or renames a workflow file |
| `action_validate` | Validation is started by the user (not the automatic check after a save) |
| `action_open_log`, `action_save_log` | A job log is opened in the viewer, or saved and opened in an editor |
| `action_save_preset`, `action_apply_preset` | A Mac preset is saved; any preset is applied |
| `action_insert_concurrency` | The concurrency suggestion is inserted into the editor |
| `action_favorite` | A workflow or repository is starred |
| `action_open_on_github` | Any "Open on GitHub" link is used |
| `action_report_bug` | Report a Bug opens a prefilled issue page |

The final list is set in the implementation plan; adding a value later is a proto change and a row here.

Never sent at any level: repository, owner, workflow, job, branch, tag or preset names; paths; SHAs; run, job or pull request numbers; hashes of any of these; error messages; logs; anything the user typed.

## Code

Core, `core/internal/analytics`:

- `Ledger`: opens `analytics.sqlite` (modernc.org/sqlite, as the workspace databases), holds the level and the id, `Add(name, value)` with the allowlist, `Seal(now)`, level changes.
- `Sender`: builds the PostHog bodies, sends the outbox, backoff. Endpoint and key come from `buildinfo` (`-ldflags` in `scripts/build-core-macos.sh` and `release.yml`, Release only); an empty key disables sending.
- Hooks: next to `AddSaving` in `workspace/runtimes.go` (`local_runs`, `local_billed_minutes`, job counters and GitHub references from the workspace store); the run-action confirmation for cancels; `SaveWorkflowFile` after `InsertWorkflowConcurrency` for `concurrency_inserted`; the sync pass for `concurrency_cancels`.

gRPC (contract changed in place; no compatibility before the first release tag):

| Method | Meaning |
| --- | --- |
| `GetAnalytics()` | Level, prompt answered, sending available in this build, the analytics id at `full`, and the pending counters and outbox for "What is sent" |
| `SetAnalyticsLevel(level, from_prompt)` | Changes the level as in Level Changes; `from_prompt` marks the prompt answered |
| `RecordUsage(UsageEvent)` | Adds one to a click counter; ignored unless the level is `full` |

App:

- `AnalyticsModel` (Observation): reads `GetAnalytics`, decides whether to show the prompt, changes the level.
- The consent sheet (O10) and Settings › Privacy (S12) above.
- `UsageTracker`: one `record(_ event: UsageEvent)` call at each point in the table; it does nothing unless the level is `full`.

## Tests

Core (deterministic: injected clock, random source and HTTP client):

- Every increment ends up in exactly one batch across seal, crash between seal and send, and restart.
- A retry after a failed or unanswered send uses the same `batch_id`; 2xx deletes; 5xx and timeouts keep with backoff.
- `first_launch` is sealed once across restarts and dropped by `off` before delivery.
- `full → basic` strips the id and click counters from the outbox and keeps `batch_id`; `→ off` empties both tables; each new `full` gets a new id.
- Click counters are refused at `basic`; unknown names are refused at every level.
- Bounds: 256 KiB and 7 days, oldest dropped first.
- No key or no data folder: nothing is sent.
- A fake PostHog server receives bodies that match the schema and contain none of the synthetic repository names, paths, branches and SHAs used by the test's workspace.
- Minute counters: a local run adds the same minutes to `local_billed_minutes` as to the B31 saving; a cancel and a concurrency cancel are counted once across repeated syncs and only on the Mac that saved the block.

App:

- The prompt shows once, not after an answer, not without a data folder; both buttons set the right level.
- Settings shows the level, the pending counters and the id at `full` from a fake Core.
- `UsageTracker` calls nothing below `full`.

## Documents To Change With The Implementation

- `AGENTS.md`: "Do not add telemetry by default" becomes "Anonymous counts without an id (first launch, saved minutes) are on by default, disclosed in the consent prompt and can be turned off; anything else needs consent".
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

Done by the account owner before the first Release build that sends:

- Use the US project; turn on "Discard client IP data".
- Check the plan's event retention and write it into the privacy policy.
- Create the saved-minutes and usage insights with one event per `batch_id`.

## Order Of Work

1. Ledger, sealing, sending, `first_launch`, levels and gRPC; the prompt and Settings.
2. Minute counters from local runs and GitHub references.
3. Click counters.
4. Cancel and concurrency counters.

## Out Of Scope

Crash reporting and automatic issue creation (unchanged, see analytics and crash reporting); B31's "potential" superseded minutes; a public counter of minutes saved on the landing page (it can read PostHog later); exact daily or weekly active users at `basic`.
