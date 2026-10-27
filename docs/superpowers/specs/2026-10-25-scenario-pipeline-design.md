# Scenarios: The Pipeline Of A Change, And Running It Locally (B31)

Status: the planner, `GetFlow` and the Overview canvas are built (B32 in the checklist); running a scenario locally (S10, S11 below), "the file changed since", branches matching a pattern target and Review on GitHub for a waiting gate are not. Design approved on 2026-10-25. Backlog: B31 (new, B32 in the checklist) in the [MVP checklist](../../product/mvp-implementation-checklist.md). Builds on the workspace cache and sync of [B26 and B27](2026-10-22-workspace-cache-design.md), the run links of [B30](2026-10-23-run-change-links-design.md), the local runs of B14–B16 with the bundled act ([ADR 0006](../../decisions/0006-bundled-act-for-local-runs.md)) and screens S03, S10 and S11 ([screens and states](../../design/screens-and-states.md)). Context: [gRPC API](../../architecture/grpc-api.md), [workflow intelligence](../../architecture/workflow-intelligence.md) ("model logical pipelines across multiple actual GitHub runs").

## Goal

The Overview answers "what happens to my change": pick a scenario (a pull request into `main`, a push to this branch, a merge into `main`, a tag, a manual start), and see every workflow it starts, each as a lane of jobs in columns by `needs`, with arrows, chained workflows after the ones that start them, and manual steps at the end; the statuses are those of the scenario's latest run. The same scenario runs on this Mac with act: jobs in the order their dependencies give, manual steps started by hand once the rest has passed. GitHub shows one workflow run at a time; GitLab shows a pipeline. Runnir shows the pipeline GitHub Actions does not draw, without asking the repository for anything beyond its workflow files.

Example (this repository on a feature branch): "Pull request → main" shows CI, Go Core (`native tests → cross-build`, `lint-security`, `contract`) and App Build, which runs only when `apps/**` changed; Release (tags `v*`) and the nightly schedule are listed as not in this scenario, with the reason.

## Decisions Made

| Question | Decision |
| --- | --- |
| What "the whole flow" is | A scenario as a whole: every workflow it starts, one lane each, jobs in columns by `needs` with arrows; `workflow_run` chains after their source lane; manual workflows last |
| Scenarios offered | By branch: Pull request → [base], Push to the current branch, Merge into [branch], Tag (when a workflow has `push.tags` or `release`), Manual (`workflow_dispatch`), Schedule (`schedule`). Default: on a branch with an open pull request, "Pull request → its base"; on another branch, "Pull request → the default branch"; on the default branch, "Push to it" |
| Target branches | Branches named exactly in the workflows' rules come first, then the default branch, then branch patterns (masks); choosing a pattern lists existing branches that match it or takes a typed name that matches |
| Which rule wins | GitHub's own: in a list of patterns the last matching one decides and `!` excludes; `branches-ignore`, `tags`, `paths` and `paths-ignore` work the same way. The UI names the pattern that decided |
| How precise the plan is | From local changes: the branch's changed files against the base (commits and uncommitted changes) decide `paths`; `if:` conditions on `github.event_name`, `ref`, `ref_name`, `base_ref`, `head_ref` are evaluated; others are "depends on a condition" with its text. Skipped workflows and jobs stay visible, dimmed, with the reason |
| Statuses | The scenario's latest run: on GitHub from the cache, or the local run while it runs and after it (`GitHub \| Local` switch). Lanes whose run was on another commit say so |
| Manual steps | Workflows with only `workflow_dispatch` (a "Manual" section with Run), and jobs with `environment:` (on GitHub they wait for the environment's approval; locally they wait for a click) |
| Who plans | The Go Core, in a new pure package `internal/flow`, for the app, the future CLI and MCP. Changed files come from the `git` CLI |
| Local order | Lanes one after another; inside a lane act runs jobs by `needs`, independent ones in parallel within the engine's limits; a failed lane stops only what depends on it |
| act's shared tool cache | Before a lane's parallel jobs, a short "Prepare tools" job runs their `actions/setup-*` steps once, one after another, so the parallel jobs find the tools cached. Prepared sets are remembered and skipped |
| Out of scope | Reusable workflows (`uses:` jobs) are drawn as one node; `repository_dispatch`, `issue_comment` and other non-code events; editing workflows from the canvas; approving environments from Runnir (it opens GitHub) |

## Terms

- **Scenario**: an event that happens to the current branch's change, with its target: `PULL_REQUEST(base)`, `PUSH(branch)`, `MERGE(into)`, `TAG(name)`, `MANUAL(ref)`, `SCHEDULE`.
- **Lane**: one workflow in a scenario. **Direct** when the scenario's event starts it, **chained** when `workflow_run` starts it after another lane, **manual** when it has only `workflow_dispatch`.
- **Column**: a job's depth by `needs` (no needs: 0; otherwise one more than its deepest need), as the Overview already lays out one workflow.
- **Gate**: a job with `environment:`. On GitHub it may wait for approval; locally it waits for a click.
- **Plan** of a scenario: lanes, their jobs and the skipped workflows and jobs with reasons. **Status**: what the scenario's latest run did, per lane and job.

## Scenarios

`internal/flow` lists the scenarios of the current branch from the workflow files:

- **Pull request → base**: when any workflow has `pull_request` or `pull_request_target`. Bases: branches named exactly in their `branches` (filters with patterns add the pattern), plus the default branch.
- **Push to the current branch**: when any workflow has `push`.
- **Merge into branch**: a `push` to that branch carrying this branch's changes. Targets as for pull requests, from the `push` rules.
- **Tag**: when any workflow has `push.tags` or `release`; the target is a tag pattern or a typed name.
- **Manual**: when any workflow has `workflow_dispatch`; the ref is the current branch.
- **Schedule**: when any workflow has `schedule`; runs on the default branch.

Targets are ordered: exact names (by how many workflows name them), the default branch, then patterns. A pattern target carries the existing remote branches that match it (`git for-each-ref refs/remotes/origin`); the app also accepts a typed name, which the Core checks against the pattern.

## Planner (`internal/flow`)

Pure functions over parsed workflows (actionlint, already used by the scanner and local runs) and a `Changes` value; a small `git` reader behind an interface supplies the changes, so tests use fixed workflow files and file lists.

### Changed Files

From the `git` CLI in the working tree, bounded (at most 5000 paths, 5 seconds):

- Pull request and merge: `git merge-base HEAD origin/<base>`, then `git diff --name-only <merge-base>` (includes uncommitted tracked changes) plus untracked files from `git ls-files --others --exclude-standard`.
- Push to the current branch: the same against `@{upstream}`; without an upstream, against the merge base with the default branch.
- Tag, manual, schedule: no `paths` filters apply (GitHub ignores them for tags and these events).

Without `git`, or when it fails, `paths` filters are "unknown" and the summary says why ("git not found", "origin/main unknown: fetch first").

### Matching

For each workflow and the scenario's event:

1. The event is among its triggers (`pull_request` also matches `pull_request_target`; `MERGE` and `TAG` match `push`, and `TAG` also `release`; a `push` with tag filters only skips a merge, one with branch filters only skips a tag, one with neither runs for both; a tag that misses the `tags` filter of a workflow with `release` too leaves it to the release). `types` that exclude the scenario's activity (`opened`/`synchronize` for pull requests) skip the workflow.
2. Branch and tag filters (`branches`, `branches-ignore`, `tags`, `tags-ignore`) against the target, with GitHub's glob syntax (`*`, `**`, `?`, `+`, `[]`, `!`, `\` before a special character, inside a set too): the last matching pattern decides. An entry with escapes only (`hot\-fix`) names one branch, offered as a target without the backslash. For pull requests the filter is against the base.
3. Path filters (`paths`, `paths-ignore`) against the changed files, same rules: the workflow runs if at least one file is included.
4. Chains: a workflow with `workflow_run: {workflows: [...], types: [completed]}` naming a lane's workflow (by `name:`) becomes a chained lane after it, with its own `branches` filter against the source run's branch. `requested` or `in_progress` start it with the source rather than after it; it is a chained lane all the same, its reason naming the types. Its jobs' conditions see the source succeeded once it completed, and no conclusion yet for `requested` or `in_progress`. In a Tag scenario the `branches` filter is read against the tag, which is what a tagged run's `head_branch` holds. When the source is in the scenario and the filter is not met, the reason says so ("after CI: branch feature/x does not match main"); after a workflow started only by hand it reads "after Deploy, which is started by hand".
5. Manual: workflows with only `workflow_dispatch` form the Manual section of every scenario; in the Manual scenario every `workflow_dispatch` workflow is a direct lane.

A skipped workflow keeps a reason: "schedule only", "branch main does not match release/**", "excluded by !release/old/**", "paths apps/**: no changed file matches", "types: closed".

### Jobs

- Columns by `needs`; edges from each need. A cycle (invalid file) puts the jobs in column 0 and the lane shows actionlint's error.
- `if:` evaluation: literals, `==`, `!=`, `<`, `>`, `&&`, `||`, `!`, parentheses, `startsWith`, `endsWith`, `contains`, `format`, and the contexts `github.event_name`, `github.ref`, `github.ref_name`, `github.ref_type`, `github.base_ref`, `github.head_ref`, `github.event.pull_request.draft` (false) and `github.event.workflow_run.conclusion` (for chains, "success" unless the condition reads otherwise). `success()`, `always()`, `failure()`, `cancelled()` and `needs.*` make the job "after its needs". Anything else is "depends on a condition". A false condition skips the job and the jobs that need it.
- Matrix: the number of combinations after `include`/`exclude` when they are literal; otherwise "matrix". The node reads `test ×3`.
- Gates: `environment:` (a name or `{name, url}`); the node names the environment.
- Reusable workflow jobs (`uses: ./.github/workflows/x.yml`) are one node.

### Result

`Flow`: the scenario, a summary of the changes (count, base, how they were read), lanes in order (direct by file order, each chained lane after its source, manual last) with jobs, edges and conditions, and the skipped workflows with reasons. The planner never reads GitHub.

## Statuses

The Core adds statuses to a flow from the workspace cache (B26/B27, B30 links):

- **Pull request → base**: the open pull request of the current branch into that base; its runs on its latest head commit. The branch's pull request is the one whose head is the commit checked out or last pushed, from this repository or the user's fork; else the one from this repository. Another fork's pull request or run from a branch of the same name is not the branch's. No such pull request: no status ("not run yet").
- **Push**: the latest `push` runs on the branch.
- **Merge into X**: when the branch's pull request was merged into X, the runs after merge on the merge commit; otherwise the latest `push` runs on X, labelled "last merge into X, not yours".
- **Tag**: the latest runs on a tag or of `release`. GitHub names a push run by its ref only, so a push run counts as a tag's when the tag is known in the local repository or the workflow pushes only tags; a tag not fetched yet has no status.
- **Manual**: the latest `workflow_dispatch` run of each manual workflow on the ref.
- **Schedule**: the latest `schedule` run of each workflow.

Each lane takes the newest run of its workflow (matched by path) in that set. Jobs come from the run's jobs: those of completed runs once (cached), those of active runs on each pass, for the scenario's lanes only. Nodes match jobs by name; matrix jobs `test (ubuntu-latest)` fold into their node with the worst outcome. A gate waiting on GitHub (`waiting`) says so and offers "Review on GitHub".

A lane whose run was on another commit than `HEAD`, or with uncommitted changes, is labelled "statuses from 9a8a1ce"; when `.github/workflows/` changed after that commit (git), also "file changed since". Without GitHub access the flow has no statuses and one line says why, as in Runs. Flows refresh on `ACTIVITY_CHANGED` and `REPOSITORY_REFRESHED`.

A local scenario run (below) replaces the GitHub statuses while it runs and after it, labelled "Local · 2 min ago", with a `GitHub | Local` switch; choosing another scenario shows GitHub again.

## Overview (S03)

- Header: the scenario picker (`Pull request → main ▾`, sections Pull request, Push, Merge into, Tag, Manual, Schedule; targets ordered as above), the branch, "12 files changed against main", **Run locally** and **Run Workflow…**.
- Canvas, scrolling horizontally when wide. A lane: on the left its name, file, the latest run's status and why it runs (`pull_request · paths ✓`); then job columns with arrows. A node: status dot, name, duration, `×3` for a matrix, a hand icon and the environment for a gate, a dashed outline for "depends on a condition" (the condition in its help). Chained lanes sit under their source with an arrow from its last column and "after CI (success)". The Manual section lists manual lanes with **▷ Run** (GitHub's Run Workflow sheet, or locally in a local run).
- "Not in this scenario": a folded row listing skipped workflows with their reasons.
- A job opens its log in a layer over the Overview, the same layer the Runs list shows over the run graph (the run's jobs and steps on the left, the log on the right), at its failed variant when it has one; a job the run does not have opens the run in Runs. During a local run it is to open the local output (not built). A lane's name opens its file in the Workspace editor.
- Recent runs and Run manually stay below the canvas.
- States: no workflows; a file that does not parse (its lane shows the error); `git` missing (paths "unknown"); cached or offline ("saved" statuses); statuses from another commit; a local run in progress.

The Workspace's "Pipeline preview" (S09), now "Preview unavailable", shows the open file's lane with the same canvas: jobs in columns with arrows, gates and conditions for the default scenario, no statuses; unsaved edits are planned from the editor's text.

## Local Scenario Runs (S10, S11)

### Review (S10)

**Run locally** prepares the whole scenario in the Core and shows: the lanes in order with their jobs; what will not run here (`runs-on: macos-*`: no local image; skipped); images to download; that no secrets are passed; the gates that will wait; the event (ref, base, head, commit); tool preparation when needed; the trust confirmation, as today.

### Event

The Core writes the event payload and passes it with `--eventpath`, so `github.ref`, `base_ref`, `head_ref` and `github.event.*` are real:

- Pull request: `pull_request`, action `synchronize`, the open pull request's number (0 without one), head and base refs and commits, `draft`.
- Push: `refs/heads/<branch>`, `before`/`after`, `head_commit`.
- Merge into X: a push to `refs/heads/X`. The code is the working tree; the review says that a real merge can differ when X moved on.
- Tag: `refs/tags/<name>`. Manual: `workflow_dispatch` with the inputs from the form or a preset. Schedule: `schedule`.

### Order

- Lanes run one after another, direct ones in plan order. Inside a lane act runs the jobs by `needs`, independent ones in parallel within the engine's limits (`--concurrent-jobs` = the engine's CPUs, as today's limits).
- A chained lane starts after its source lane, when the source's result meets its condition (by default success).
- A failed lane stops only what depends on it: its chained lanes and later gates; independent lanes go on.
- Manual lanes wait for **▷ Run** once every lane before them has passed (or for **Run anyway**).

### Gates

act cannot pause inside a run. A lane with gates runs in two steps:

1. A temporary copy of the workflow without the gated jobs and the jobs that need them (written to the run's temporary folder, never into the repository).
2. **▷ Run** on a gate runs `act --job <gate>` on the real file. act runs the jobs the gate needs again (for example build), because it cannot resume the first run. The review and the gate's button say so.

### Tool Preparation

Parallel jobs that install the same tool version for the first time race on act's shared `act-toolcache` volume (`ENOTEMPTY … /opt/hostedtoolcache`, then `which go` finds nothing). Before a lane's first parallel stage, when two or more of its jobs use `actions/setup-*`:

- The Core builds a temporary workflow with one job: `actions/checkout`, then each distinct `setup-*` step of those jobs (same action, same `with:`, `cache: false`), one after another, on the same runner image.
- It runs first, shown as "Prepare tools" in the lane. The parallel jobs then find the tools cached.
- The set (action, version inputs, version files' digests, image) is remembered per repository; a set prepared before is skipped. Clear Cache forgets the sets.
- If a race still shows in a job's output (the signatures above), the job is marked "tool cache collision" with **Run lane again**.

### Progress (S11)

The Overview canvas switches to `Local` and shows statuses live; a job opens its output (S11 as today, with the scenario's lanes in its list). **Stop** cancels the current act and every lane not started. One local run record per scenario run, with its lanes, in `local_runs` (200 records as today).

Matrix job names in the local job list are expanded as act reports them (`Native tests (ubuntu-latest)`, not `Native tests (${{ matrix.os }})`).

## gRPC Contract (`runnir.core.v1`, changed in place)

- `ListScenarios(repository_id)` → scenarios (kind, target, label, `pattern` and `matching_branches` for pattern targets), the default scenario's id.
- `GetScenarioFlow(repository_id, scenario)` → `Flow`: changes summary; lanes (workflow path and name, kind `DIRECT|CHAINED|MANUAL`, why it runs, source lane and condition for a chain, parse error, jobs with column, needs, matrix count, gate environment, condition `RUNS|SKIPPED|DEPENDS` with text and reason); skipped workflows with reasons; statuses (source `GITHUB|LOCAL|NONE`, per lane the run id, commit, "other commit" and "file changed" flags, per job the outcome and run job ids, gate waiting).
- `PrepareScenarioRun(repository_id, scenario, inputs)` → a single-use approval id with the review: lanes with `LocalRunPlan`s, tool preparation, gates, event summary, notes and blockers.
- `ConfirmScenarioRun(approval_id)` → an execution id. `ReleaseScenarioGate(execution_id, workflow_path, job_id)` runs a gate or a manual lane. `RunScenarioLaneAgain(execution_id, workflow_path)`. `CancelExecution` stops it.
- `GetLocalRunOutput` gains the lanes of a scenario run (state per lane, "waiting for you" per gate).

## App (Swift)

`ScenarioPicker`, `PipelineCanvas` (lanes, columns, arrows; reuses `PipelineLayout` for columns), `ScenarioReviewSheet` (S10 for scenarios), lane progress in the local run view, `CoreScenario*` models and their gRPC mapping, `CoreHub` methods with the session keeping the chosen scenario per window. The app draws; it does not plan.

## Design

`docs/design/runnir.pen`: the S03 frames are redrawn (the one with CHECK/BUILD/ARCHIVE/DEPLOY stages and GitLab-style manual jobs goes): Pull request → main (default), Merge into main, Manual section, skipped workflows and conditions, offline with saved statuses, and a local scenario run in progress with a gate waiting; S10 for a scenario with tool preparation and a gate. New frames go into the journey rows A–F (settings last).

## Error Handling

- A workflow that does not parse: its lane shows actionlint's message; the others are planned.
- `git` missing or failing: paths "unknown", named in the summary; workflows with only path filters are "may run".
- An event without a target (no open pull request, no tag): the payload uses placeholders and the review says which.
- act or the engine missing: the review's blockers, as today. A lane that cannot run locally (every job unsupported) is skipped with the reason; the rest runs.
- Tool preparation failing: the lane fails at "Prepare tools" with its output; **Run lane again** retries.

## Tests

- `internal/flow`: table tests over workflow files and change lists: events and types, branch and tag globs with `!` and order, `branches-ignore`, paths with negation, `pull_request_target`, tags and `release`, chains with conditions, manual lanes, `if:` evaluation (true, false, depends), matrix counts, gates, cycles, scenario lists and target ordering, default scenario; the `git` reader against a scratch repository (merge base, uncommitted and untracked files, no upstream, no git).
- Statuses: cache fixtures for each scenario kind, matrix folding, other-commit and file-changed labels.
- Local runs: payload JSON per scenario; the gated workflow copy; tool preparation workflow and skipping a prepared set; lane order with a failed lane and a chain; the race signature; a fake runner for execution order (no Docker in unit tests); one end-to-end run behind the existing e2e tag.
- Server: the new RPCs over gRPC; app: mapping, picker defaults, canvas layout model (no UI automation).

## Documentation

`grpc-api.md` (new RPCs), `screens-and-states.md` (S03, S09, S10, S11), ADR 0006 (event payloads, tool preparation, gated copies, the flags act gets), `workflow-intelligence.md` (scenarios as the logical pipeline), the MVP checklist (B31).

## Not Verified By This Work

- Pull requests from forks (the payload uses the working tree as the head).
- Environments' protection rules (Runnir reads none; a gate is any job with `environment:`).
- Exactly how GitHub would evaluate conditions Runnir marks "depends".
