# MCP Full Control Implementation Plan

> Executed inline in one session (the user does not use subagents). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An agent drives Runnir through its MCP server: reads workspaces, workflows, scenarios, GitHub runs and logs, local runs; starts and stops local runs; dispatches, cancels and re-runs on GitHub ([design](../specs/2026-11-09-mcp-full-control-design.md)).

**Architecture:** `runnir-core mcp` forwards every `tools/call` over `mcp.sock` as `McpBridge.CallTool`. The app's Core runs the tool in `internal/mcptools`, asking the app (broker) only for workspaces, opening one, values and starting a local run, and calling its own services in process for the rest.

**Tech Stack:** Go (Core), protobuf/gRPC over Unix sockets, Swift 6 + SwiftUI (app).

## Global Constraints

- No backward compatibility before the first release tag: contracts change in place.
- Never return, log or store a secret value; dispatch inputs logged by name only.
- Use Runnir's own panels (no SwiftUI Menu, popover or menu Picker).
- Core: `go test ./...`, `go vet ./...`, `go build ./...` from `core/`. App: build and `RunnirTests` with a separate `-derivedDataPath`.
- No AI attribution in commits or docs.

## Tasks

### Task 1: Contract

**Files:** `contracts/grpc/runnir/core/v1/runnir_core.proto`, generated Go and Swift.

- [ ] `McpBridge`: replace `ListValueSets` and `SetValues` with `CallTool(McpToolCall) returns (McpToolResult)`; `McpToolCall {client, tool, arguments_json}`, `McpToolResult {text, structured_json, is_error}`.
- [ ] `McpTool`: add `LIST_WORKSPACES`, `OPEN_WORKSPACE`, `START_LOCAL_RUN`. `McpRequest`: add `action`, `McpLocalRunStart start`. Answers: add `McpWorkspaces workspaces`, `McpOpenedWorkspace workspace`, `McpLocalRunStarted started`.
- [ ] `ConfirmLocalRunRequest.started_by`, `GetLocalRunOutputResponse.started_by`.
- [ ] Regenerate with `scripts/generate-contracts.sh`; delete `McpBridgeListValueSetsRequest` and `McpBridgeSetValuesRequest`.

### Task 2: Core keeps who started a local run

**Files:** `core/internal/localrun/output.go`, `core/internal/server/localruns.go`, tests.

- [ ] `Outputs.Create(..., startedBy string)`; `Snapshot.StartedBy`; `ConfirmLocalRun` passes it; `GetLocalRunOutput` returns it. Test in `output_test.go`.

### Task 3: Broker questions

**Files:** `core/internal/mcpbridge/broker.go`, `broker_test.go`.

- [ ] `Workspaces(ctx, client)`, `Open(ctx, client, repository, action bool)`, `Start(ctx, client, start)`; `List` and `Set` stay. One start with the sandbox off waits at a time, like a set. Log lines move to `mcptools`.

### Task 4: `internal/mcptools`

**Files:** `catalog.go`, `tools.go` (dispatch, decode, results), `read.go`, `act.go`, `format.go`, tests with fake `Core` and `App`.

- [ ] `type Core interface` with the service methods used; `type App interface` with the broker's questions.
- [ ] `Tools.Call(ctx, client, name, args) Result`; one handler per tool; bounds; GitHub status in words; log line per call.

### Task 5: Server and stdio

**Files:** `core/internal/server/mcp.go`, `core/internal/mcp/server.go`, `tools.go`, tests, `mcp/runnir-tools.json`.

- [ ] `mcpBridge.CallTool` runs `mcptools` with the service; the stdio server lists `mcptools.Catalog` and forwards calls; catalog file regenerated and compared by the test.

### Task 6: App contract mapping

**Files:** `CoreMcpModels.swift`, `GRPCCoreService.swift`, `CoreService.swift`, `CoreHub.swift`, tests.

- [ ] New tools, `action`, the start's arguments; answers for workspaces, opened workspace, started run; `startedBy` on `confirmLocalRun` and the output.

### Task 7: App answers

**Files:** `McpRequests.swift`, `LocalRun.swift`, `LocalRunViews.swift`, `DesktopCoordinator.swift`, `DesktopViews.swift`, `McpSettings.swift`, new `McpRunPanel.swift`, tests.

- [ ] Workspaces; opening one (Allow actions checked for actions); starting a run (selection, environment, missing values, blockers, one run per workspace, sandbox panel); the window shows the run; header "Started by …"; Settings › MCP Allow actions and description.

### Task 8: Docs and plugin

- [ ] `docs/architecture/mcp.md`, `docs/architecture/grpc-api.md`, the checklist, the plugin's skill and README, plugin version.

### Task 9: Verify

- [ ] Core tests, vet, build; app build and unit tests; the stdio server against an installed Runnir Local.
