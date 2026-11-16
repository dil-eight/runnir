# MCP Tools For The Values Of Local Runs: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `runnir-core mcp` serves `runnir_list_value_sets` and `runnir_set_values` to MCP clients (Claude Code, Codex); the running app answers them, and writes Keychain only after Save in its own panel.

**Architecture:** The stdio MCP server is a thin adapter in the Core binary. It calls a small gRPC service, `McpBridge`, on a second socket (`mcp.sock` in the data folder) of the app's Core. The Core's broker holds each call and hands it to the app over a stream on the main, authenticated socket; the app answers with `AnswerMcpRequest`.

**Tech Stack:** Go 1.27 standard library and grpc-go (Core); Swift 6, SwiftUI, Observation (app); protobuf contract `runnir.core.v1`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-11-08-mcp-value-sets-design.md`; tool schemas from `mcp/runnir-tools.json`.
- No new dependency; pure Go, `CGO_ENABLED=0`.
- No secret value in any log, error, stored file or answer to a client; only names.
- Names: `^(?![Gg][Ii][Tt][Hh][Uu][Bb]_)[A-Za-z_][A-Za-z0-9_]*$`, at most 255 bytes; values 1 to 49152 bytes; at most 100 names; a name not both a secret and a variable.
- The Core waits for the app at most 5 minutes; one set request waits at a time.
- Protocol versions answered: `2025-11-25`, `2025-06-18`, `2025-03-26`, `2024-11-05`.
- App: Runnir's own panels, never SwiftUI `Menu`, `.popover` or a menu-style `Picker` (AGENTS.md); every clickable control shows the hand pointer (`PointerCoverageTests`).
- Build and test into a separate `-derivedDataPath`, never the default DerivedData.
- Commits: no AI attribution (AGENTS.md).

---

### Task 1: Contract

**Files:**
- Modify: `contracts/grpc/runnir/core/v1/runnir_core.proto`
- Regenerate: `core/internal/gen/...`, `apps/macos/Runnir/IPC/Generated/...` (`scripts/generate-contracts.sh`, plugins on `PATH`)

**Produces:**
- `rpc SubscribeMcpRequests(SubscribeMcpRequestsRequest) returns (stream McpRequest)` and `rpc AnswerMcpRequest(AnswerMcpRequestRequest) returns (AnswerMcpRequestResponse)` on `RunnirCore`.
- `service McpBridge { rpc ListValueSets(McpBridgeListValueSetsRequest) returns (McpValueSets); rpc SetValues(McpBridgeSetValuesRequest) returns (McpSavedValues); }`
- Messages: `McpTool` (`MCP_TOOL_LIST_VALUE_SETS`, `MCP_TOOL_SET_VALUES`); `McpValue {name, value}`; `McpRequest {id, client, tool, repository, set, repeated McpValue secrets, repeated McpValue variables}`; `McpValueState` (`SAVED`, `FROM_REPOSITORY`, `MISSING`, `NOT_NEEDED`); `McpValueName {name, bool secret, McpValueState state, string value}`; `McpValueSet {name, workspace, bool stale, repeated McpValueName names}`; `McpValueSets {workspace, repeated McpValueSet sets}`; `McpSavedValues {workspace, set, repeated string secrets, repeated string variables}`; `AnswerMcpRequestRequest {id, oneof answer {McpValueSets sets; McpSavedValues saved; string refusal}}`; `McpBridgeListValueSetsRequest {client, repository}`; `McpBridgeSetValuesRequest {client, repository, set, secrets, variables}`.

- [ ] Add the messages and RPCs with comments; `buf lint` clean.
- [ ] Run `scripts/generate-contracts.sh`; `go build ./...` from `core/`.
- [ ] Commit `Contract: MCP requests to the app and the McpBridge service`.

### Task 2: The broker (`core/internal/mcpbridge`)

**Files:**
- Create: `core/internal/mcpbridge/broker.go`, `checks.go`, `broker_test.go`, `checks_test.go`

**Produces:**
- `func CheckSet(r *corev1.McpBridgeSetValuesRequest) error` — the spec's checks; the error text is the refusal.
- `type Broker struct`; `func NewBroker(wait time.Duration, log io.Writer) *Broker`.
- `func (b *Broker) Subscribe(ctx context.Context) (<-chan *corev1.McpRequest, func())` — one subscriber; a new one replaces the old.
- `func (b *Broker) List(ctx, client, repository string) (*corev1.McpValueSets, error)` and `func (b *Broker) Set(ctx, *corev1.McpBridgeSetValuesRequest) (*corev1.McpSavedValues, error)` — `ErrNoApp`, `ErrBusy`, `ErrTimeout`, `Refusal` (string error).
- `func (b *Broker) Answer(*corev1.AnswerMcpRequestRequest) error` — `ErrUnknownRequest` for an id not waiting.
- Log line per call: `mcp: <tool> <workspace> <set> secrets=[A B] variables=[C] -> <outcome>`.

- [ ] Tests first: each check (empty, 101 names, bad names incl. `GITHUB_X`, `1A`, 256 bytes, empty value, 49153 bytes, a name in both); list answered; set answered; refusal answered; no subscriber → `ErrNoApp`; timeout → `ErrTimeout`; second set while one waits → `ErrBusy`; caller's context cancelled removes the request; the log holds names and never a value (a value `s3cr3t-VALUE` never appears in the log).
- [ ] Implement; `go test ./internal/mcpbridge/`.
- [ ] Commit `Core: broker for MCP requests to the app`.

### Task 3: The Core serves both sides

**Files:**
- Create: `core/internal/server/mcp.go`, `core/internal/server/peer_darwin.go`, `core/internal/server/peer_other.go`, `core/internal/server/mcp_test.go`
- Modify: `core/internal/server/server.go`, `core/internal/server/service.go`

**Consumes:** Task 2's `Broker`.
**Produces:** `RunnirCore.SubscribeMcpRequests` / `AnswerMcpRequest`; with `Options.DataDir` set, a second listener at `DataDir/mcp.sock` (stale one removed, mode 0600, skipped with a log line when the path exceeds `MaxSocketPathBytes`) serving only `McpBridge`; on darwin each connection's peer uid must equal ours (`LOCAL_PEERCRED` via `syscall`), else closed. `const McpSocketName = "mcp.sock"`.

- [ ] Tests first: over gRPC, a fake app subscribes on the main socket and answers; `McpBridge.ListValueSets` and `SetValues` on `mcp.sock` get its answers; refusals map to `codes.FailedPrecondition` with the reason; no app → `codes.Unavailable` "Runnir is not running…"; `mcp.sock` mode 0600; the main service is not reachable on `mcp.sock` (`RunnirCore.HealthCheck` → `Unimplemented`).
- [ ] Implement; `go test ./internal/server/`.
- [ ] Commit `Core: the MCP socket and the app's stream of MCP requests`.

### Task 4: `runnir mcp`

**Files:**
- Create: `core/internal/mcp/server.go`, `tools.go`, `server_test.go`
- Modify: `core/cmd/runnir/main.go`, `core/cmd/runnir/main_test.go`

**Produces:** `func Serve(ctx context.Context, in io.Reader, out io.Writer, bridge Bridge) error`; `type Bridge interface { ListValueSets(ctx, *corev1.McpBridgeListValueSetsRequest) (*corev1.McpValueSets, error); SetValues(ctx, *corev1.McpBridgeSetValuesRequest) (*corev1.McpSavedValues, error) }`; `func DialBridge(socketPath string) Bridge` (lazy: dials per call, so a later-started app is found). `runnir mcp --data-dir PATH`.

- [ ] Tests first (with a fake `Bridge`): `initialize` echoes a supported version, else the newest, with `capabilities.tools` and `serverInfo`; `tools/list` returns both tools with the catalog's schemas; `tools/call` for each tool returns `content: [{type: text, text: <JSON>}]` and `structuredContent`; invalid arguments → `isError: true` with the reason; a bridge error → `isError: true` with its message; unknown method → `-32601`; notifications get no reply; malformed JSON → `-32700`; the client's name from `initialize` reaches the bridge; a secret value never appears in output.
- [ ] Implement; `go test ./internal/mcp/ ./cmd/runnir/`; `runnir mcp` without `--data-dir` exits 2; the old `mcp` unknown-command assertion in `main_test.go` changes accordingly.
- [ ] Commit `Core: runnir mcp serves the value tools over stdio`.

### Task 5: The app receives MCP requests

**Files:**
- Modify: `apps/macos/Runnir/IPC/CoreService.swift`, `GRPCCoreService.swift`, `CoreWorkspaceModels.swift`, `CoreHub.swift`; test fakes in `RunnirTests/CoreHubTests.swift`, `CoreProcessSupervisorTests.swift`
- Create: `apps/macos/Runnir/IPC/CoreMcpModels.swift`

**Produces:** `CoreMcpRequest { id, client, tool: .listValueSets | .setValues, repository, set, secrets: [(name, value)], variables }`; `CoreMcpAnswer: .sets(CoreMcpValueSets) | .saved(CoreMcpSaved) | .refusal(String)`; `CoreServicing.mcpRequests() -> AsyncThrowingStream<CoreMcpRequest, Error>` and `answerMcpRequest(id:answer:)`; `CoreHub.mcpRequestHandler: (@MainActor (CoreMcpRequest) async -> CoreMcpAnswer)?`, kept open with the same retry as events.

- [ ] Tests first: a fake service yields a request; the hub calls the handler and sends its answer; with no handler it answers a refusal.
- [ ] Implement; RunnirTests for the hub.
- [ ] Commit `App: receive MCP requests from the Core and answer them`.

### Task 6: Answering in the app (`McpRequestHandler`)

**Files:**
- Create: `apps/macos/Runnir/Features/Desktop/McpRequests.swift`, `RunnirTests/McpRequestTests.swift`
- Modify: `apps/macos/Runnir/App/Desktop/DesktopCoordinator.swift` (owns the handler, sets it on the hub, opens windows)

**Produces:** `McpWorkspaceResolver.resolve(_ repository: String, in: [WorkspaceRecord]) -> Result<WorkspaceRecord, McpRefusal>`; `McpValueSetsBuilder.sets(model: WorkspaceValuesModel) -> CoreMcpValueSets`; `McpValuesPrompt` (observable: request, rows, `shown`, `replaces`) with `save(store:) async -> CoreMcpAnswer` and `cancel() -> CoreMcpAnswer`; `DesktopCoordinator.mcpPrompt: McpValuesPrompt?` with its window id.

- [ ] Tests first: resolving an exact path, a path with a trailing slash or symlink, a unique name, an ambiguous name, an unknown one (refusal lists names); the states from a values model (saved, from_repository, missing, not_needed), a variable's value, never a secret's; an unknown set refused with the sets; the prompt's rows and Replaces; Save writes `secret:NAME` / `environment:production:secret:NAME` through `MemoryLocalRunValueStore` and answers the names; Cancel answers "Cancelled in Runnir"; a second prompt while one is shown is refused by the Core already.
- [ ] Implement; RunnirTests.
- [ ] Commit `App: answer MCP value requests for a workspace`.

### Task 7: The panel and Settings › MCP

**Files:**
- Create: `apps/macos/Runnir/Features/Desktop/McpValuesPanel.swift`, `apps/macos/Runnir/Features/Settings/McpSettings.swift`
- Modify: `DesktopViews.swift` (overlay in the workspace window), `SettingsOverlay.swift` (`case mcp`), `GlobalSearch.swift` (the setting), `Runnir.xcodeproj/project.pbxproj`

**Produces:** the panel (client, set, rows with kind, variable value, masked secret with Show, "Replaces the saved value", the context note, Cancel, Save); Settings › MCP (status, Claude Code command, Codex block, Copy, note). `McpSettings.claudeCommand(helper:dataDir:) -> String` and `codexBlock(helper:dataDir:) -> String`.

- [ ] Tests first: the command and the block quote paths with spaces; the block has `tool_timeout_sec = 300`; the settings section is in search.
- [ ] Implement; full RunnirTests (pointer and dropdown rules included); build.
- [ ] Commit `App: confirm MCP values in a panel, Settings › MCP`.

### Task 8: Docs and the end-to-end check

**Files:** `mcp/runnir-tools.json` (two tools `implemented`, top-level status), `docs/architecture/mcp.md`, `docs/architecture/grpc-api.md`, `docs/product/mvp-implementation-checklist.md`, the spec's status.

- [ ] Update; `go test ./... && go vet ./... && go build ./...`; full RunnirTests; build.
- [ ] By hand with a signed Runnir Local: `claude mcp add` and Codex config; list and set on runnir, fintropy (production, staging) and memo-project; Cancel; a local run with the saved values.
- [ ] Commit `Docs: MCP value tools as built`.
