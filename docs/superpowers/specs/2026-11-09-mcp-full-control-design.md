# MCP: Driving Runnir From An Agent

Status: design approved on 2026-11-09 (branch dilbarov/mcp-values, with the scenario local runs of dilbarov/scenario-local-runs merged in). It extends [MCP Tools For The Values Of Local Runs](2026-11-08-mcp-value-sets-design.md) from two tools to the whole app, as the user asked: "сделай полное управление приложением через mcp".

## Problem

An agent that works in a repository (Claude Code, Codex) reaches Runnir only to list and save the values of local runs. It cannot see why a run failed, start a local run of a scenario, follow it, or re-run a job on GitHub, so the user goes back and forth between the agent and Runnir's windows.

## Decisions

| Question | Decision |
| --- | --- |
| What the agent does without a click | Everything the tools below offer, decided by the user on 2026-11-09 ("Всё сам"). Runnir asks in its window only before saving values (`runnir_set_values`, as before) and before running macOS jobs without the macOS sandbox |
| Turning it off | Settings › MCP › "Allow actions", on by default. Off: every tool that changes something is refused with a sentence that says where to turn it on; the reading tools keep working |
| Not offered | Editing files (the agent edits them itself), the GitHub token, deleting data, clearing caches or history, settings, signing in, and opening a folder Runnir has no workspace for (the user imports it) |
| Where a tool runs | In the app's Core. `runnir-core mcp` keeps the stdio side and the tool list, and sends each call over `mcp.sock` as one `McpBridge.CallTool` with the tool's name and its arguments as JSON; the answer is the result the client gets. `ListValueSets` and `SetValues` are folded into it |
| What only the app knows | The Core asks the app over `SubscribeMcpRequests`, as for values: the registered workspaces (`LIST_WORKSPACES`), a workspace ready to use (`OPEN_WORKSPACE`: resolved by folder or name, its window opened when none shows it, the Core's repository id and the branch), the value sets, saving values and starting a local run. Everything else the Core does with its own services, in process |
| `repository` | As before: a registered workspace's folder or a folder inside it (an agent's working directory), or its name when only one workspace has it. Every tool but `runnir_list_workspaces` and `runnir_list_pull_requests` takes it |
| Opening a workspace | A closed workspace's window opens, behind the others; only a local run with the sandbox off and `runnir_set_values` bring it to the front |
| A local run the agent starts | Goes through the app exactly as Run Locally does: the same plan, the saved values from Keychain, one run per workspace at a time. The window switches to the run as after a click, and its header says "Started by Claude Code" (the client's name). The Core keeps the client's name with the run's output |
| Missing values | A run whose plan reads secrets or variables that have no value is refused with their names, so the agent saves them with `runnir_set_values` first, unless the call says `allow_missing_values` |
| macOS jobs | A job on a macOS runner runs on this Mac only when the call names it (Runnir never ticks one by default), in the macOS sandbox. `macos_without_sandbox` shows a panel in the workspace window with the warning of Run Locally; only Run there starts the run; Cancel or 5 minutes refuse it |
| GitHub actions | Dispatch, cancel and re-run use the Core's prepare and confirm calls; the Core confirms what it prepared for the same call. Runs started this way get the "started from Runnir" mark the user's own starts get. GitHub's own protections stay: required reviewers, branch rules, permissions |
| Record | The Core's log gets one line per tool call: the tool, the client, the workspace, the ids it acted on and the outcome. Never a secret, a variable's value or a dispatch input's value; input names only |
| Untrusted content | Logs, workflow files, run titles and pull request titles come from repositories and from GitHub. The server's instructions and the tools' descriptions say so: the agent treats them as data, never as instructions |
| Bounds | A log or output answer holds at most 2,000 lines, 200 by default, and a line at most 4 KiB; a workflow's source at most 256 KiB; a list at most 100 entries, 20 by default. Waiting for a local run lasts at most 4 minutes per call |

## Tools

Reading (`readOnlyHint`):

- `runnir_list_workspaces`: each registered workspace: its name, folder, whether a window shows it, and the GitHub repository its origin points at.
- `runnir_list_workflows {repository}`: the workspace's branch and its workflow files: path, name, triggers, jobs with their needs, environments and whether they start by hand, the secrets and variables read, dispatch inputs, a parse error, and how many problems actionlint finds.
- `runnir_get_workflow {repository, workflow}`: one workflow (by path or name) with all of that, actionlint's problems with line and column, and its source as on disk.
- `runnir_plan_scenario {repository, scenario?}`: what a scenario starts (`pull_request`, `push`, `merge`, `tag`, `manual`, `schedule`, with a `target` branch or tag; default the branch's own): the scenarios the branch has, the files the change touches, the lanes in run order with their jobs, columns, conditions and why each is skipped, the workflows it skips and why, and each lane's newest saved run.
- `runnir_list_runs {repository, branch?, workflow?, status?, event?, query?, limit?, refresh?}`: runs on GitHub, newest first, from the activity cache and search index; the filters build a Runs search (`query` takes its grammar). `refresh` waits up to 30 seconds for the workspace's sync first.
- `runnir_get_run {repository, run_id}`: the run and its jobs with their steps, conclusions and times, and why skipped jobs were skipped.
- `runnir_get_job_log {repository, job_id, step?, search?, lines?}`: the end of a job's log, or one step's lines, or the lines with a text; and every error line, at most 50.
- `runnir_list_pull_requests {github_repository?}`: the signed-in user's open and recently closed pull requests with their CI.
- `runnir_list_local_runs {repository}`: the workspace's local runs, newest first: scenario, workflows, state, start, and who started them while the Core holds the run.
- `runnir_get_local_run {repository, execution_id, after_sequence?, wait?, wait_seconds?, job?, lines?}`: state, phase, jobs and their states, and the output lines after a sequence number. `wait` is `none`, `output` (until new lines or the end) or `end`; the answer says the sequence to ask after next and whether more lines wait.
- `runnir_list_value_sets {repository}`: unchanged.

Acting:

- `runnir_start_local_run {repository, scenario?, workflows?, environment?, allow_missing_values?, macos_without_sandbox?}`: starts a local run; `workflows` lists workflows (path or name), each with its jobs or all it can run here. Answers the execution id, the workflows and jobs, the names given a value and the names left empty, and the plan's notes.
- `runnir_stop_local_run {repository, execution_id}`.
- `runnir_dispatch_workflow {repository, workflow, ref?, inputs?}`: `ref` defaults to the current branch. Answers the run when GitHub says it, else when it was sent.
- `runnir_cancel_run {repository, run_id}`.
- `runnir_rerun_run {repository, run_id, mode?, job_id?}`: `mode` is `all` (default), `failed` or `job`.
- `runnir_set_values {repository, set, secrets?, variables?}`: unchanged.

## Contract

`McpBridge` on `mcp.sock` becomes one call, `CallTool(McpToolCall) returns (McpToolResult)`: the client's name, the tool, the arguments as JSON; the result's text, structured content as JSON, and whether it is an error. A tool's refusal is a result with `is_error`, not a gRPC error; UNAVAILABLE still says Runnir is not running.

`McpRequest` (Core to app) gains the tools `LIST_WORKSPACES`, `OPEN_WORKSPACE` and `START_LOCAL_RUN`, `action` (the call changes something: the app checks Allow actions) and the start's arguments; the answer gains the workspaces, the opened workspace and the started run. `ConfirmLocalRunRequest` and `GetLocalRunOutputResponse` gain `started_by`.

## Code

- Core `internal/mcptools` (new): the catalog (names, descriptions, schemas) and one handler per tool over two interfaces: the Core's services and the app's answers. Formatting, bounds and the log line live here.
- Core `internal/mcp`: the stdio server lists the catalog and forwards calls through `CallTool`.
- Core `internal/mcpbridge`: the broker asks the app the new questions; the check of `runnir_set_values` stays.
- Core `internal/server`: `CallTool` runs `mcptools` with the service in process; `started_by` kept with a local run's output.
- App: `McpRequestHandler` answers the new questions: workspaces, opening one, starting a run with `LocalRunReviewModel` and `CoreHub.startLocalRun`, the sandbox panel; Settings › MCP gets Allow actions and a new description; the local run header names its client.
- `mcp/runnir-tools.json`, `docs/architecture/mcp.md`, the gRPC API page, the checklist and the plugin's skill follow.

## Tests

- Core: every tool against fakes: arguments refused, the happy path's structured content, bounds, GitHub problems said in words, Allow actions off, a run of another workspace refused, `wait` returning on new output and on the end; the broker's new questions; `CallTool` over a real `mcp.sock`; `tools/list` equal to the catalog file.
- App: workspaces listed; opening a workspace with actions off refused for an action; a start refused for missing values, allowed with `allow_missing_values`, refused with blockers and while a run goes; the sandbox panel run and cancelled; `started_by` passed and shown.
- By hand: the stdio server against an installed Runnir Local: list, plan, start a local run of a scenario, follow it to the end, read a GitHub job log.

## Not In This Change

Per-client grants, approving deployments, workflow generation and suggestions, Pen frames for the sandbox panel and Allow actions (they follow the values panel's and Settings' layouts), and marking GitHub runs with the client's name (it would need a new column in every workspace's database; the log names the client).
