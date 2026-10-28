# Why a job was skipped (B35)

Status: built (the Core's reasons in `GetRunWorkflow`, the reason on the node and the panel in the run graph), drawn in `runnir.pen` (journey D, Row — Why a job was skipped (B35)): option A, a panel on click, was chosen; a line under the node (B) and a list under the graph (C) were not. Builds on the run graph of B41 ([spec](2026-10-26-run-graph-inspector-design.md)) and the `if:` evaluator of B32 (`core/internal/flow`). Not tried against real runs on GitHub.

## Problem

The run graph marks a job GitHub skipped as "skipped" and nothing more. Why it was skipped (a job it needs failed, its `if:` was false for the run's event, a value only the run knew) is in the workflow file at the run's commit and in the run itself, and GitHub shows neither. A node the run has no job for is marked "skipped" too, which is a guess: GitHub may have run another version of the file.

## Decisions

| Question | Decision |
| --- | --- |
| Where the reason shows | A short reason on the skipped node instead of "skipped"; a click opens a panel under the node's column with the whole reason (option A) |
| A node the finished run has no job for | "not in this run", not "skipped"; the panel says which file GitHub ran instead when the event tells |
| Who explains | The Core, with the graph: `GetRunWorkflow` returns an explanation for every skipped job and every node without a job, worked out next to `flow.Evaluate`. The app only draws them |
| A condition Runnir cannot decide | Shown as text with what Runnir does not know; never guessed |

## What the Core knows of a run

- From the run: the event, the branch (`head_branch`), the actor, the repository, the workflow's name, the head commit, and for `pull_request` and `pull_request_target` the pull request's number.
- From the workspace's pull requests (B30): the base and whether the pull request is a draft.
- From the run's jobs: each job's result, as `needs.<id>.result` (success, failure, cancelled, skipped).
- Whether a push was of a tag or a branch: the local repository's refs decide. A name git knows only as a tag is a tag, one it knows as a branch is a branch; otherwise `github.ref` and `github.ref_type` are unknown.
- Status functions for the run: `success()` holds when every job the job needs, directly or through others, succeeded; `failure()` when one of them failed; `cancelled()` when the run was cancelled; `always()` always.
- Never known: `vars.*`, `secrets.*`, `inputs.*`, `needs.<id>.outputs.*`, `matrix.*`, `steps.*` and the `workflow_run` payload beyond its head branch. A condition that reads one of them is "not known".

The jobs come from the workspace's cache (the graph has read them already); outside a workspace one read of the run's jobs. Nothing else is asked of GitHub.

## Kinds of reason

For a job the run has as skipped, in this order:

1. **a need did not succeed** (on the node: "need failed", "need cancelled" or "need skipped", by the need's result). A job it needs did not succeed (failed, cancelled or skipped) and its `if:` has no status function, so GitHub's implicit `success()` held it back. The panel names that job and its result; when several did not succeed, the first the job lists.
2. **condition false** ("condition false"). Its `if:` is false for this run. The panel shows the condition and the values of the run it read, for example `github.event_name: push`.
3. **not known** ("not known"). Its `if:` reads something Runnir does not know. The panel shows the condition and the names Runnir does not know, for example `vars.RELEASE_NOTES`. Also when Runnir reads the condition as true and the needs as met, but GitHub skipped the job: the panel says so and that the file at this commit may differ from the one GitHub ran.

For a node without a job in a finished run:

4. **not in this run** ("not in this run", dashed outline). GitHub ran no job for it. The panel says so and, by event: for `pull_request` GitHub ran the file of the merge commit with the base, for `pull_request_target` the file of the base branch, so the file read here at the head commit may differ.

While the run is going on, only jobs it has already skipped are explained; nodes without a job are still to come, as today.

Special nodes:

- A job that calls a reusable workflow (`uses:`) is explained by the same rules; the jobs inside the called workflow are not.
- A matrix with `exclude` (or `include`) is not a skip: combinations the matrix leaves out are never explained as skipped. A matrix job skipped by its `if:` is one skipped job, as GitHub reports it.
- A file that cannot be read or does not parse keeps today's list of jobs without their order, and says that the reasons cannot be told.

## The run graph (S08)

- A skipped node keeps its icon and says its reason in place of "skipped": "need failed" (or "need cancelled", "need skipped"), "condition false", "not known". A node without a job in a finished run has a dashed outline and "not in this run".
- A click on such a node opens the panel under its column. The panel is part of the graph's layout and moves what is below it (the failure line) down; nothing is drawn over it. One panel at a time: a click on another such node moves the panel there; ×, Escape or a click on the same node closes it. A click on a job that ran opens its log as today and closes the panel. Re-run job stays in the node's menu.
- The panel: "Why <job> was skipped" (or "<job> is not in this run"), the reason in a sentence, then by kind:
  - a need did not succeed: the job it needs and its result, with its status icon.
  - condition false: the condition in monospace, then "This run had" and the values it read.
  - not known: the condition in monospace, then "Runnir does not know" and the names.
  - not in this run: the sentence about the file GitHub ran.
- The last line names the source: "Read from <file> at <short commit>, the file this run used." For `pull_request`: "Read from <file> at <short commit>; GitHub ran this file merged with the base, which may differ." For `pull_request_target`: "Read from <file> at <short commit>; GitHub ran the file of the base branch, which may differ."
- VoiceOver reads the reason with the node's name.

## Contract

Changed in place (no release yet):

- `GetRunWorkflowResponse` gets `repeated JobSkip skips` and `string source_note` (the sentence about which file GitHub ran; empty when it is the file read).
- `JobSkip`: `job_id`, `kind` (`SKIP_KIND_NEEDS`, `SKIP_KIND_CONDITION_FALSE`, `SKIP_KIND_NOT_KNOWN`, `SKIP_KIND_NOT_IN_RUN`), `need` and `need_result` (for needs), `condition`, `values` (name and value, in the order the condition reads them), `unknown` (names), `note` (for not known when GitHub disagrees, and for not in this run).
- The app asks again when the run finishes; the file and the jobs come from the Core's caches then.

## Core

- `flow`: a pure function from the workflow file, the run's facts and its jobs to the explanations. `flow.Evaluate` reports the names a condition read with their values and the names it could not know; its status functions come from the context, so the scenarios of the Overview keep theirs (`success()` and `always()` hold, `failure()` and `cancelled()` are unknown).
- `GetRunWorkflow` builds the run's facts (the run, the workspace's pull requests, the local refs), takes the jobs from the workspace's cache, and adds the explanations to its answer. The file stays cached per run as today.

## States drawn

1. The panel for a condition that is false (option A, chosen).
2. The panel for a job whose need failed.
3. The panel for a condition Runnir does not know.
4. A node not in this run, with its panel, in a pull request's run. Pen has no dashed stroke: the node's outline is drawn muted there and is dashed in the app.

Not chosen, kept on the canvas: B, the reason as a second line on the node; C, a list of skipped jobs under the graph.

## Tests

- Core, table tests: a failed need; a cancelled need and a skipped need; a condition false on the event; a condition that reads `vars` (not known, as text); a condition read as true while GitHub skipped the job; a matrix with `exclude` without false skips; a reusable workflow node; `always()` after a failed need (it ran, nothing to explain); a node not in a finished run, with the notes for `pull_request` and `pull_request_target`; a run still going on; a tag or branch decided by local refs, and an unknown one.
- Core, server: `GetRunWorkflow` against a fake GitHub with a run, its jobs and its file.
- App: the reason on each kind of node, the panel opening, moving and closing, a run job's click still opening its log; the panel rendered offscreen against the Pen frames.
- Not covered by unit tests: real runs on GitHub, in particular `pull_request` runs whose base changed the workflow.

## Delivery

One pull request: this spec and the Pen frames, the Core (contract, `flow`, `GetRunWorkflow`), the app, and the docs (B35 row in the checklist, `grpc-api.md`, `screens-and-states.md`).
