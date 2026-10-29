# Runs started from Runnir (B46)

Status: built (the Core's record of the attempts Runnir started, `WorkflowRun.runnir_starts`, the words in the row and beside the attempt, From Runnir in the status filter), drawn in `runnir.pen` (journey D, Row — Runs started from Runnir (B46)). Option C was chosen: words at the start of the row's detail line and beside the attempt. A tag after the title (A) and the Runnir mark before it (B) were not chosen. Builds on the dispatch history (B34), the run actions (B13), the status filter (B42) and the search beyond the cache (B40). Not tried against GitHub.

## Problem

A run Runnir started looks like any other run in the runs list. Someone who dispatched a workflow or re-ran failed jobs from Runnir has to recall which run it was, or compare the actor and the time by eye. GitHub keeps no label that would tell:

- a `workflow_dispatch` input the file does not declare is refused;
- a run started with the user's token shows the user as its actor, just as one started on github.com does.

## Decisions

| Question | Decision |
| --- | --- |
| Where the mark comes from | This Mac only. Nothing is sent to GitHub and no GitHub request is added. Another Mac, a teammate and github.com see nothing |
| What is kept | Its own record in the Core, one row per attempt Runnir started. It is not derived from the dispatch history (B34), which keeps only the newest 200 entries and has Clear history |
| Which runs are marked | A run with any attempt started from Runnir |
| What counts as a start | A dispatch (Run, Run again, the Overview's ▶ on a manual job), Re-run all jobs, Re-run failed jobs, and Re-run of one job. Cancel and Approve start nothing |
| How it shows | Option C. "From Runnir · " at the start of the row's detail line. In the inspector, beside the attempt: " · from Runnir", " · re-run from Runnir" or " · attempt N from Runnir". Help on hover says it is known on this Mac only |
| Filtering | A From Runnir item in the status filter menu, with its chip |

## What the Core records

A start is recorded only after GitHub accepted the request, and only for a repository with a workspace open in this Core. A repository named directly, or a dispatch without a workspace, records nothing.

- **Dispatch.** It starts attempt 1 of its run. It is recorded when the run is known:
  - at once when GitHub names the run in its answer to the dispatch;
  - otherwise when the app links the run it found to the dispatch history entry (`LinkDispatchRun`).

  If the link is never made, nothing is recorded. The link the app found is a guess (the same workflow, ref and time), so two dispatches of one workflow at the same moment from this Mac and from elsewhere can mark the wrong run. The time it was recorded is when the dispatch was sent.
- **Re-run all jobs, re-run failed jobs, re-run one job.** Each one starts the next attempt of the run. The attempt is the run's attempt when it was reviewed plus one: `PrepareRunAction` keeps the attempt it read (1 when GitHub gives none), and `ConfirmRunAction` records it. GitHub refuses to re-run a run that is not finished. Only one case marks the wrong attempt: another re-run that starts and finishes inside the two minutes a confirmation lasts.

Kept data:

- One row per run and attempt. If the same attempt is recorded again, the first row stands.
- Table `runnir_starts` in the workspace database, local (not cache): `server_id`, `repository`, `run_id`, `attempt`, `kind` (`dispatch`, `rerun`, `rerun_failed`, `rerun_job`), `sent_at`. The server and repository work as in `dispatch_history`: a relinked folder does not show another repository's marks.
- The newest 5000 rows are kept, by `sent_at`.
- Clear Cache and Clear history (B34) do not touch them. Removing the workspace removes them.
- They are written to the backup of local data with `local_runs`, `savings` and `dispatch_history`, and carried over the same way when the database is set aside.
- The schema changes in place (no release yet). A database from an earlier build is set aside as today, and its local data is carried over.

## Contract

Changed in place (no release yet):

- `WorkflowRun` gets `repeated RunnirStart runnir_starts = 21`. It lists the attempts Runnir started, oldest first, up to the run's `run_attempt`. An attempt recorded before GitHub reports it waits until the run shows that attempt. The field is set where the runs list gets its runs:
  - workspace activity;
  - `SearchRuns` (the runs found in the search index);
  - `SearchRunsOnGitHub`.

  Elsewhere it is empty: global search, the Overview's lanes, `ListWorkflowRuns`, `PrepareRunAction`.
- `RunnirStart`: `attempt`, `kind` (`RunnirStartKind`), `sent_at`.
- `RunnirStartKind`: `RUNNIR_START_KIND_UNSPECIFIED`, `RUNNIR_START_KIND_DISPATCH`, `RUNNIR_START_KIND_RERUN`, `RUNNIR_START_KIND_RERUN_FAILED`, `RUNNIR_START_KIND_RERUN_JOB`.
- No RPC is added.

## Runs list (S07)

- **Row.** A run with any start reads "From Runnir · " before its detail line, in the accent colour: "From Runnir · CI #1482 · ios-release · release/1.4 · workflow_dispatch". VoiceOver reads "started from Runnir" with the row. The row's help on hover adds the inspector's help text (below). The Overview's recent runs use the same row, so they show the words too.
- **By change.** A run line under a change carries the same words before its workflow and number.
- **Filter menu.** Below the six statuses, after a divider, there is a From Runnir item: a checkbox, the Runnir mark (the menu bar icon's image) and a count.
  - It combines with AND with the ticked statuses, which still combine with OR among themselves, and with the typed query and the branch filter. Failed plus From Runnir shows the failed runs Runnir started.
  - The count is the number of runs matching the query and the branch filter that Runnir started. Ticking does not change it, as for the statuses (B42).
  - The footer's "N selected" counts it.
- **Chip.** When ticked, a "From Runnir" chip with the mark and its remove control appears under the field. The filter button carries its indicator. Clear all removes the chip.
- **What the filter applies to.** Like the statuses: the saved runs and the runs a search found in the index or on GitHub. In By change, a change is shown when one of its runs passes the statuses and From Runnir together.
- The filter is kept per window while the app runs, not across launches, as the statuses are.

## Run inspector (S08)

Beside the attempt in the summary line, in the accent colour, by the run's latest attempt:

- **Latest attempt was dispatched from Runnir:** " · from Runnir" ("Attempt 1 · from Runnir").
- **Latest attempt was re-run from Runnir** (any kind of re-run): " · re-run from Runnir".
- **Latest attempt was not, an earlier one was:** " · attempt N from Runnir", where N is the newest earlier attempt Runnir started.
- **No attempt was started from Runnir:** nothing.

Pen draws the attempt as "Attempt 2 of 2"; the app keeps its own "Attempt 2". The words follow it in both.

Help on hover (the system help tag; Pen draws it as a popover):

1. One sentence per attempt Runnir started, oldest first:
   - "Attempt 1 was started from Runnir on this Mac, 7 min ago."
   - "Attempt N re-ran every job from Runnir on this Mac, …"
   - "Attempt N re-ran the failed jobs from Runnir on this Mac, …"
   - "Attempt N re-ran one job from Runnir on this Mac, …"
2. The attempts it did not start, if any: "Attempt 1 was not started from this Mac." or "Attempts 1 and 3 were not started from this Mac."
3. "Only this Mac knows: GitHub keeps no mark on runs, so other Macs and github.com do not show it."

## States drawn

1. The runs list with a dispatched run marked in its row and in the inspector, with the help on hover (option C, chosen).
2. The filter menu with From Runnir ticked, its count and the chip under the field.
3. The inspector of a run whose attempt 2 re-ran the failed jobs from Runnir and whose attempt 1 was a push: "re-run from Runnir" and its help.

Not drawn: " · attempt N from Runnir". It uses the same line and help as state 3.

Not chosen, kept on the canvas: A, a "Runnir" tag after the title; B, the Runnir mark before the title.

## Not in this change

- A way to clear the marks other than removing the workspace.
- A search qualifier for them (`from:runnir`).
- Marks in global search, in the Overview's lanes, in the menu bar and in notifications.

## Tests

- **Core, store.**
  - Recording a start, with the first row kept on a repeat.
  - The newest 5000 kept.
  - Rows per repository source.
  - Clear Cache and Clear history keeping them.
  - Backup and salvage.
- **Core, server.**
  - A dispatch whose run GitHub named is recorded, as attempt 1.
  - A dispatch without a run records nothing until `LinkDispatchRun`; after the link it is recorded with the dispatch's time, and a second link changes nothing.
  - Each kind of re-run records the reviewed attempt plus one; Cancel and Approve record nothing.
  - A request GitHub refused, or one that failed, records nothing.
  - A repository without a workspace records nothing.
  - Workspace activity, `SearchRuns` and `SearchRunsOnGitHub` carry the starts up to the run's attempt.
- **App.**
  - Row words.
  - Inspector words for each case and the help text.
  - From Runnir with the statuses (AND), the query and the branch.
  - Counts that do not follow ticks.
  - The chip and Clear all.
  - By change.
- **Not covered by unit tests:** a real dispatch and re-run against GitHub.

## Delivery

One pull request:

- this spec and the Pen frames;
- the Core: contract, store, recording, run messages;
- the app;
- the docs: the B46 row in the checklist, `grpc-api.md`, `screens-and-states.md`.
