# MCP Architecture

Status: built on 2026-11-09 ([design](../superpowers/specs/2026-11-09-mcp-full-control-design.md)), after the two value tools of 2026-11-08 ([design](../superpowers/specs/2026-11-08-mcp-value-sets-design.md)). `runnir-core mcp [--data-dir PATH]` serves 17 tools over stdio; the Runnir plugin installs them in Claude Code and Codex ([below](#installing)). `runnir rpc` (version handshake) and `runnir serve` (the app's [gRPC API](grpc-api.md)) are desktop IPC endpoints, not MCP servers.

MCP was planned for v0.3 ([roadmap](../product/roadmap.md)); the user asked for it ahead of that, for the first alpha (B52).

The MCP server belongs to the portable Go Core and reuses its services, never reimplementing GitHub or workflow logic. A future MCP client is out of scope.

## How A Call Runs

`runnir-core mcp` speaks MCP over stdio, lists the catalog (`internal/mcptools`, mirrored in `mcp/runnir-tools.json`) and sends each `tools/call` to the app's Core over `mcp.sock` as `McpBridge.CallTool` (tool name, arguments as JSON, the client's name). The app's Core runs the tool in `internal/mcptools`:

- What only the app knows it asks the app over `SubscribeMcpRequests`: the registered workspaces, a workspace ready to use (resolved by folder or name, its window opened behind the others when none shows it, its repository id in the Core and branch), the value sets, saving values, and starting a local run as Run Locally does.
- Everything else it does with its own services, in process: workflows and actionlint, scenario plans, the activity cache and run search, jobs, logs, pull requests, local run output, dispatches, cancels and re-runs.

## Tools

Reading: `runnir_list_workspaces`, `runnir_list_workflows`, `runnir_get_workflow`, `runnir_plan_scenario`, `runnir_list_runs`, `runnir_get_run`, `runnir_get_job_log`, `runnir_list_pull_requests`, `runnir_list_local_runs`, `runnir_get_local_run` (waits up to 4 minutes for new output or the end) and `runnir_list_value_sets`.

Acting: `runnir_start_local_run`, `runnir_stop_local_run`, `runnir_dispatch_workflow`, `runnir_cancel_run`, `runnir_rerun_run` and `runnir_set_values`.

Decided with the user on 2026-11-09: agents act without a click. Runnir asks in the workspace's window only before saving values and before running macOS jobs without the macOS sandbox. Settings › MCP › Allow actions (on by default) turns every acting tool off. A local run an agent starts shows "Started by" with the client's name; GitHub runs it starts get the "started from Runnir" mark the user's own get. The Core's log gets one line per call with the tool, the client, the workspace, the ids acted on and the outcome, never a value. Answers are bounded (2,000 lines and 512 KiB of lines, 4 KiB a line, 256 KiB of workflow source).

Not offered: editing files, the GitHub token, deleting data, settings, signing in, opening a folder that is not a workspace. Planned: workflow generation and suggestions, approving deployments.

## Secrets And Variables

Built on 2026-11-08 as decided below. How it runs: the app's Core listens on a second socket, `mcp.sock` in the build's data folder (mode 0600, peers of this user only), serving only the `McpBridge` service; `runnir-core mcp` connects to it for each call. The Core asks the app over `SubscribeMcpRequests` on its authenticated socket and waits up to five minutes for `AnswerMcpRequest`; one `runnir_set_values` waits at a time. The app opens the workspace's window when none shows it, answers a list from the same model as Secrets and Variables, and shows a change in Runnir's own dialog over the window, Settings included; Save writes Keychain. Since 2026-11-16 a request carries when the Core stops waiting, and the question ends a few seconds before; the Core withdraws a request whose client went away or that expired, and the question comes down; Save and Run Without Sandbox first claim the request (`ClaimMcpRequest`), after which it no longer expires, so the app never saves or runs what the client was told did not happen. A window that closes, or shows another workspace, cancels its questions, and one question about a run without the sandbox shows at a time. `runnir_start_local_run` runs a macOS job only when the client names it: a workflow named alone leaves out macOS jobs and the jobs that need one, and a named job that needs an unnamed macOS job is refused. A scenario given without its target is the branch's first of that kind, as `runnir_plan_scenario` lists them. Settings › MCP gives the command for Claude Code and the block for Codex (`tool_timeout_sec = 300`). The Core's log gets one line per call with names and the outcome, never a value.


Added on 2026-11-05: a client saves the secrets and variables local runs use into one value set of a workspace, the Repository's or an environment's, as [Values Per Environment](../superpowers/specs/2026-11-03-environment-values-design.md) keeps them.

- `runnir_list_value_sets` (read-only): the sets, "Repository" and the environments as `ListEnvironments` returns them, and in each the names its jobs read, a secret or a variable, saved, empty (the Repository's value) or missing. A variable's value may come back; a secret's never does.
- `runnir_set_values`: a workspace, one set from that list and names with values, secrets apart from variables, at least one name. The client passes secret values too (decided on 2026-11-05), so a secret goes through the MCP client and the model's context; the tool's description says so. Runnir never returns, logs or audits a value, only names.
- Confirmation: the Core prepares the change and the workspace's window shows it: the set, each name, a variable's value, a secret masked with Show, and which names replace a saved value. Only Confirm in the app writes Keychain, under the accounts Secrets and Variables uses (`secret:NAME`, `environment:production:secret:NAME`). The client gets the saved names or the refusal.
- Refused before the app asks: a set the workspace does not have, a name GitHub would not take (letters, digits and `_`, not starting with a digit or `GITHUB_`, except `GITHUB_TOKEN`, which a local run may be given), an empty value, a value over 48 KiB (GitHub's limit for a secret), more than 100 names.
- Not part of it: clearing a value (Secrets and Variables does that), GitHub's own secrets and variables (these sets are local), organization secrets.

## Installing

The Runnir plugin ([plugins/runnir](../../plugins/runnir/README.md), [design](../superpowers/specs/2026-11-08-mcp-plugins-design.md)) installs the server and a skill on using it, with the same commands for every user:

- Claude Code: `claude plugin marketplace add dil-eight/runnir`, then `claude plugin install runnir@runnir`.
- Codex: `codex plugin marketplace add dil-eight/runnir`, then `codex plugin add runnir@runnir`.

The repository is the marketplace: `.claude-plugin/marketplace.json` for Claude Code, `.agents/plugins/marketplace.json` for Codex. The plugin runs `/Applications/Runnir.app/Contents/Helpers/runnir-core mcp`; without `--data-dir` the Core uses its own build's folder in Application Support, which the build passes in as `RUNNIR_BUILD`. Codex gets `tool_timeout_sec = 300` from the plugin. Settings › MCP shows these commands in a build the plugin reaches; Runnir Dev, Runnir Local and an app outside `/Applications` show `claude mcp add --scope user` and a Codex block for their own app instead.

## Enforcement

- No token responses, no unrestricted shell, no unauthenticated network listener: `mcp.sock` is mode 0600 and takes peers of this user only, and serves only `McpBridge`, never the app's own calls.
- The tool set is fixed by the Core; a client cannot reach an RPC through it. Workspaces are the ones the user registered in Runnir.
- Acting without a click was the user's decision (2026-11-09); the user turns it off in Settings › MCP. Saving values and running macOS jobs without the sandbox are confirmed by Runnir outside both model and client.
- Logs, workflow files and titles are untrusted; the server's instructions and the tools' descriptions say so.
- Secrets never leave Runnir: a value given to `runnir_set_values` is never returned, logged or stored outside Keychain, and dispatch inputs are logged by name only.

## Readiness Against The gRPC Core API

Reviewed 2026-10-17 against the implemented [gRPC API v1](grpc-api.md), before any adapter existed; kept as the record of what was decided. Since 2026-11-09: the adapter reaches the Core on its own socket with a fixed tool set (1); it never opens or closes repositories itself, the app opens a workspace's window instead (2); acting was decided as above (3); the socket is in the build's data folder, and a client without a running Runnir is told so (4).

The intended shape is one MCP adapter process (stdio toward Claude or Codex) that connects to the app's existing Core over its socket and calls the same services. It never starts a Core per repository, and the instance lock keeps a second Core from appearing.

**No existing call or message has to change.** Everything needed below is additive: new calls or fields in `runnir.core.v1`, a restricted way to connect, and request metadata. The base API therefore stays compatible, which is what acceptance criterion 10 asks. It does not mean the Core is safe to expose to an MCP client today.

| Catalog tool | Core support | Needed |
| --- | --- | --- |
| `runnir_list_workflows` | `ListWorkflows` (the `repository` argument is a `repository_id`) | nothing |
| `runnir_list_repositories` | none | a `ListRepositories` call returning only repositories the client may see |
| `runnir_analyze_workflow`, `runnir_validate_workflow`, `runnir_suggest_improvements` | workflow ids are relative paths, matching `relativePath`; the Core has structure only | calls for bounded workflow source and validation (actionlint) |
| `runnir_get_run`, `runnir_get_job_logs` | none: GitHub runs and logs are still in the Swift REST client | Core services for runs and logs after their migration; no duplicate logic |
| `runnir_list_value_sets`, `runnir_set_values` | the names jobs read (`ListWorkflows`) and `ListEnvironments`; saved values are in the app's Keychain, which the Core cannot read | a call that asks the app which names are saved, and a prepare call that the app confirms in its own window before it writes Keychain |
| future `runnir_dispatch_workflow`, `runnir_test_workflow` | `StartWorkflow` (stub runner) | an approval authority first |

Blocking before any client other than the app connects. Observed on 2026-10-17 with a standalone Core and separate clients: a second client could open an unrelated folder, close the first client's repository so that its next refresh failed `NOT_FOUND`, and start a workflow, all without any grant or approval.
1. **Client identity and a restricted surface.** The app now proves itself with a per-launch secret (see [gRPC API](grpc-api.md#security-model-today)), so a client without it is refused. An MCP adapter must not receive that secret. Give the adapter a different way in (a second listener or a per-client token) and let the Core enforce an allow-list of calls and repository grants per client. Read-only by default, with no `OpenRepository` of arbitrary paths, no `CloseRepository` and no `StartWorkflow`. Event subscriptions must be filtered by the Core, because `repository_ids` is chosen by the client.
2. **Per-client leases for open and close.** Today closing is global, so one client can end another's repository. Opens and closes need reference counting per client.
3. **Approval authority.** GitHub workflow dispatch now needs a Core-issued, single-use confirmation bound to repository, workflow, ref and inputs (`PrepareWorkflowDispatch`, then `ConfirmWorkflowDispatch`). Cancelling and re-running runs use the same two-step pattern (`PrepareRunAction`, then `ConfirmRunAction`), bound to repository, run and action. For MCP, confirming must stay with the app's own UI: an adapter may prepare, but never confirm. `StartWorkflow` (local execution) has no approval step yet.
4. **Discovery.** The socket sits in the per-user temporary directory under a name derived from the app bundle's path, which an adapter started by another application cannot assume. Define a discoverable location and what the adapter does when Runnir is not running: report it, rather than start a second Core.
