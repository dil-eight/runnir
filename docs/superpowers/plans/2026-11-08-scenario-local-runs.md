# Scenario Local Runs Implementation Plan

**Goal:** Run Locally runs a scenario (what GitHub would start for the change, or the ticked part of it), one act per workflow, as decided in [Local Scenario Runs](../specs/2026-10-25-scenario-pipeline-design.md#local-scenario-runs-s10-s11).

**Architecture:** The Core plans a scenario with `internal/flow` (lanes, jobs, skip reasons) and turns each ticked workflow into a lane of a local run: its jobs planned as today (`localrun`), a trimmed copy of the file and an event payload. The runner runs the lanes one after another; output and job statuses carry their workflow. The app's review shows the scenario, the workflows and jobs with checkboxes, and the sections of today's review over the ticked jobs.

**Tech:** Go (Core, CGO off), protobuf `runnir.core.v1` changed in place (`scripts/generate-contracts.sh`), Swift 6/SwiftUI.

## Global Constraints

- No backward compatibility: change the contract, the `local_runs` table and settings in place.
- Values reach act only through pipes; trimmed copies and payloads live in the run's temporary folder, never in the repository.
- Runnir's own dropdowns only (`DropdownMenu`, `DropdownPicker`); hand pointer on everything clickable.
- No AI attribution in commits or docs.

## Tasks

1. **Contract.** `PrepareLocalRunRequest{repository_id, scenario, selection[]{workflow_id, job_ids[]}, use_installed_act, limits, reset_limits}`; `LocalRunPlan{scenarios, scenario, lanes[], images, secrets, variables, unnamed_secrets, notes, blockers, limits…, environment…, act/engine}`; `LocalRunLane{workflow_id, workflow_name, event, why, in_scenario, skipped, after, selected, parse_error, kind, jobs[]}`; `LocalRunJob` gains `needs`, `selected`, `skipped`; `LocalRunJobStatus` and `LocalRunLine` gain `workflow_id`; `SearchedLocalRun{execution_id, scenario, workflow_paths[], state, message, started_at}`. Regenerate Go and Swift.
2. **flow.** `Lane.Event()` from `Why`; nothing else changes.
3. **localrun plan.** `Request` takes `JobIDs []string` (empty: all); `JobPlan` gains `Needs`, `Selected`, `Skipped`; `Closure(workflow, ids)`; `Trim(source, ids)` keeps only those jobs (yaml.v3 nodes). `RunPlan{Scenario…, Lanes []LanePlan, aggregates}` built from per-lane plans; blockers and notes over ticked jobs; one environment for the run.
4. **Event payloads.** `localrun.Payload(EventContext)` → JSON for pull_request(_target), push (branch, merge, tag), release, workflow_dispatch, schedule, workflow_run.
5. **Runner.** `Spec.Lanes` carry the reviewed source, the trimmed copy and the payload; lanes one after another, `--workflows=<copy>`, `--eventpath=<payload>`, no `--job`; chained lanes need their source's success; per-lane timeout; Stop ends the run; cleanup after each lane.
6. **Outputs.** `JobStatus.Workflow`, `Line.Workflow`, lane state and times; job lookup by workflow and id; `Summary` with lanes for analytics.
7. **Server.** Shared scenario setup with `GetFlow`; `PrepareLocalRun` builds lanes from the flow and the selection (closure in the Core too); `ConfirmLocalRun` checks every lane's digest; output mapping; `local_runs` keeps `scenario` and `workflows`; search.
8. **Core tests**, then `go test ./...`, `go vet ./...`, `go build ./...`.
9. **App models and review.** Mapping; `LocalRunReviewModel` with scenario, ticks and propagation (pure, tested); the sheet: scenario dropdown, workflows and jobs, the other sections; dropdowns with a chevron, hover background and the hand pointer (find why the pointer is missing in the sheet).
10. **App run view.** Jobs under their workflows; Run Again with the run's scenario and ticks; history and search rows; notifications.
11. **App tests**, build, unit tests.
12. **Docs.** gRPC API, screens and states, ADR 0006 (payloads, copies), checklist (B32), README.
13. **Pen.** S10 and S11 for a scenario run in journey rows; remove frames the change makes obsolete.
14. **Build.** Local merge with `dilbarov/mcp-values`, Runnir Local signed, a local copy of the plugin pointing at it.
