# MCP Tools For The Values Of Local Runs

Status: design approved and built on 2026-11-08 on branch dilbarov/mcp-values; covered by Core and app tests, not yet tried with Claude Code or Codex. It builds the two tools that [MCP Architecture](../../architecture/mcp.md#secrets-and-variables) decided on 2026-11-05, ahead of the rest of MCP (v0.3), for the first alpha. Values are the sets of [Values Per Environment](2026-11-03-environment-values-design.md) and [Secrets And Variables For Local Runs (B28)](2026-10-25-local-run-secrets-design.md).

## Problem

Filling the secrets and variables of a workspace's local runs means typing each one in Secrets and Variables or importing a `.env`. A coding agent that already knows them (Claude Code, Codex) cannot hand them over. Two things stand in the way:

- The values live in Keychain under the app's own profile; only the app reads and writes them. The Core, a separate process, does not.
- The app's Core takes calls only with a per-launch secret only the app knows, so a process an MCP client starts cannot call it.

## Decisions

| Question | Decision |
| --- | --- |
| Tools | `runnir_list_value_sets` and `runnir_set_values`, with the input schemas of `mcp/runnir-tools.json`. No other MCP tool in this change |
| Server | `runnir-core mcp --data-dir PATH`: the Core binary inside the app, speaking MCP over stdio (JSON-RPC 2.0, one message per line): `initialize`, `notifications/initialized`, `ping`, `tools/list`, `tools/call`. Written with the standard library, no MCP dependency. It answers the protocol versions `2025-11-25`, `2025-06-18`, `2025-03-26` and `2024-11-05`, the client's when it is one of them, else the newest |
| Reaching the app | The app's Core listens on a second socket, `mcp.sock` in the build's data folder (`~/Library/Application Support/Runnir…`, mode 0600 in a 0700 folder), and accepts only connections whose peer has this user's uid. It serves one small gRPC service with the two calls and nothing else. `runnir-core mcp` connects to it for each tool call |
| Runnir not running | `initialize` and `tools/list` still answer; a tool call returns a tool error: "Runnir is not running. Open Runnir and try again." The same when the Core runs but the app has not connected to it yet |
| The app's part | The Core forwards each call to the app over the main socket: a stream the app keeps open (`SubscribeMcpRequests`) carries the request, and `AnswerMcpRequest` returns the answer. The Core waits up to 5 minutes, then refuses. One `runnir_set_values` waits at a time; a second is refused until the first is answered |
| `repository` | The absolute path of a registered workspace's folder (an agent's working directory), or a workspace's name when only one has it. The app resolves it; an unknown one is refused with the names of the registered workspaces |
| Opening the workspace | The app opens a window of the workspace when none is open (its sets need the Core's workflows and environments). `runnir_set_values` brings the window to the front; `runnir_list_value_sets` does not |
| What a list returns | For each set ("Repository", then the environments as Secrets and Variables shows them): each name a job reads, secret or variable, and its state: `saved`, `from_repository` (an environment without its own value) or `missing`; a variable's saved value; never a secret's. Stale environments with saved values are listed as stale |
| Checks before asking | In the Core: at least one name; at most 100; names GitHub would take (letters, digits, `_`, not starting with a digit or `GITHUB_`, at most 255 bytes; `GITHUB_TOKEN` is taken, as a local run has no token of its own); no empty value; at most 48 KiB a value; a name not both a secret and a variable. In the app: the workspace and the set exist |
| Confirmation | A panel of Runnir's own over the workspace window: which client asks (the `clientInfo` name from `initialize`), the set, each name with its kind, a variable's value, a secret masked with Show, "Replaces the saved value" where one exists, and a line that secret values passed through the agent's context. Cancel and Save. Only Save writes Keychain, with the accounts Secrets and Variables uses (`secret:NAME`, `environment:production:secret:NAME`); open Secrets and Variables views reload |
| Answer to the client | The names saved, by kind, or why not: cancelled in Runnir, not answered in 5 minutes, a check that failed, Keychain refused |
| Values in transit | A secret goes client → `runnir-core mcp` → `mcp.sock` → Core → main socket → app → Keychain. No process logs, stores or returns it; the Core keeps it in memory only while the request waits |
| Record | The Core's log gets one line per call: the tool, the workspace's name, the set, the names and the outcome. Never a value |
| Settings | Settings › MCP: whether the MCP socket is listening (or why not: the Core is not running, the path is too long for a socket), the command for Claude Code (`claude mcp add runnir -- <app>/Contents/Helpers/runnir-core mcp --data-dir <folder>`) and the `~/.codex/config.toml` block for Codex (with `tool_timeout_sec = 300`, as Codex waits 60 seconds by default), each with Copy; and that secret values given to these tools pass through the agent and its model |
| Builds | Every build serves it; each build's command names its own app and data folder, so Runnir Dev and an installed alpha never answer each other's clients |

## Not In This Change

The other tools of the catalog; clearing values (Secrets and Variables does it); GitHub's own secrets and variables; per-client grants (any MCP client of this user may ask, and every change is confirmed in Runnir); a Pen frame for the panel and Settings › MCP (they follow the analytics question's and Settings' layouts).

## Contract

New in `runnir.core.v1`, on the main socket:

```proto
rpc SubscribeMcpRequests(SubscribeMcpRequestsRequest) returns (stream McpRequest);
rpc AnswerMcpRequest(AnswerMcpRequestRequest) returns (AnswerMcpRequestResponse);
```

`McpRequest`: an id, the client's name, the tool (`LIST_VALUE_SETS`, `SET_VALUES`), `repository`, `set`, and the secrets and variables as name-value pairs. `AnswerMcpRequestRequest`: the id and either the sets (for a list) or the saved names, or a refusal with its reason.

New service `runnir.core.v1.McpBridge` on `mcp.sock` only: `ListValueSets` and `SetValues`, taking the tools' arguments and the client's name, returning the answer or a gRPC status whose message is the refusal.

## Code

- Core `internal/mcp`: the stdio server (framing, the five methods, the tool list from the catalog's two entries, arguments checked against their schemas), and the client of `McpBridge`.
- Core `internal/mcpbridge`: the requests waiting for the app (one subscriber, ids, 5-minute deadline, one set request at a time), the `McpBridge` service, the checks, the log line.
- Core `cmd/runnir`: `mcp --data-dir PATH`; `serve` listens on `mcp.sock` beside the main socket when it has a data folder, removes a stale one, and the peer-uid check.
- App: `CoreHub` keeps `SubscribeMcpRequests` open while the Core runs and hands each request to `McpRequestHandler`, which resolves the workspace, opens its window, loads its sets with `WorkspaceValuesModel`, answers a list at once and shows the panel for a set, then saves through `LocalRunValueStoring` and answers.
- App: the panel `McpValuesPanel` and Settings › MCP.
- `mcp/runnir-tools.json`: the two tools become `implemented`; `docs/architecture/mcp.md` and the gRPC API page follow.

## Tests

- Core: the stdio protocol (initialize with each version and an unknown one, `tools/list`, `tools/call` with valid and invalid arguments, unknown methods, notifications); each check; a list and a set answered by a fake app; a set refused, cancelled and timed out; a second set while one waits; no app connected; no secret in the log or in any answer; `mcp.sock` mode and a peer of another uid refused where it can be tested.
- App: resolving a path and a name, an unknown workspace, an unknown set; the list's states from a workspace's workflows and saved keys; the panel's rows, Show, Replaces; Save writing the right accounts through a fake store and answering the names; Cancel answering a refusal.
- By hand: Claude Code and Codex against Runnir Local on runnir, fintropy (production and staging) and memo-project: list, set into the Repository and an environment, cancel, a local run using the saved values.
