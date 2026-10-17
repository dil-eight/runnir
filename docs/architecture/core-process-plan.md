# Core Process Implementation Plan

Status: proposed, 2026-10-17. Decision: [ADR 0004](../decisions/0004-single-core-process-grpc.md). Each phase ships independently, keeps existing Swift sources and `core.v1.version` working, and is verified with the commands in AGENTS.md.

## Starting Point

- Core: `core/cmd/runnir` (`version`, `rpc`) and `core/internal/ipc` (one-shot JSON-RPC). No repository, workflow or event code.
- Swift: `IPC/StdioCoreTransport.swift` and `CoreClient.swift` (one child per request). `DesktopCoordinator` owns windows, registry and sessions; `Repository`/`Workflow` models exist in `Core/Models`.
- Contracts: `contracts/ipc/v1/version.schema.json` only.

## Phases

| # | Outcome | Main work | Done when |
| --- | --- | --- | --- |
| 0 | Decisions settled | Review ADR 0004; pick gRPC-Swift version, Go YAML library; confirm UDS works in the sandbox with a spike | Open decisions in the ADR are closed or recorded |
| 1 | Contract | `contracts/grpc/v1/runnir_core.proto`, generated Go and Swift committed, README on regeneration | `go build ./...` and Xcode build pass with generated code |
| 2 | Core server | `core/internal/server` gRPC over UDS, `HealthCheck`, lock file, parent-death exit, graceful shutdown; `runnir-core serve` command | Second start refuses; killing parent ends Core; `go test -race ./...` |
| 3 | Repository Manager | `core/internal/repository`: contexts keyed by `repository_id`, idempotent Open, Close, Refresh, per-context locking | Reopening yields one context; refresh of A does not block B (race tests) |
| 4 | Workflows | Read `.github/workflows`, resolve branch, parse YAML into a graph; bounded file sizes; no execution | Fixtures: no files, malformed, oversize, worktree `.git` file, both extensions |
| 5 | Events | `SubscribeEvents` with bounded per-subscriber buffers, repository-scoped events | Slow subscriber cannot grow memory; ordering per repository tested |
| 6 | Execution interfaces | `StartWorkflow`, `ExecutionCoordinator` with limit 3 and FIFO queue, stub runner | Fourth start queues; cancellation frees a slot. No real Actions engine |
| 7 | Swift lifecycle | `CoreProcessSupervisor` (launch, health wait, reconnect, restart prompt), gRPC client behind a protocol next to `CoreClient` | Exactly one process across several windows; quit ends Core; crash then reconnect |
| 8 | Swift integration | Map `DesktopCoordinator` repository open/close/refresh to RPCs; per-window event filtering; keep local fallbacks until parity | Two to three windows show different repositories; closing one leaves others intact |
| 9 | Diagnostics | Memory and CPU sampling script at 1, 3, 10 repositories; results recorded in a verification doc | Numbers documented against the 300 MB target, honestly |
| 10 | Docs and MCP readiness | Update IPC, overview, lifecycle and MCP docs; confirm no API change is needed for an MCP adapter | Docs match shipped behavior only |

## Verification

Core: `go test ./...`, `go vet ./...`, `go build ./...` from `core/`, plus `-race`. App: the build and `-only-testing:RunnirTests` commands from AGENTS.md. Acceptance criteria 1 to 10 from the proposal map to phases 2 to 9; a process-count check (one `runnir-core` with ten repositories open) is automated in phase 8.

## Risks

- gRPC-Swift UDS support under the App Sandbox is unproven; phase 0 spike decides the transport.
- New dependencies conflict with the stdlib-first rule and add binary size.
- Stale socket or lock after a crash can block restart; the lock file must use an OS advisory lock, not mere existence.
- Dual paths (stdio and gRPC) can drift; keep the stdio path limited to version until retired.

## Phase 0 Spike Results (2026-10-17)

Setup: ad-hoc signed `.app` with `app-sandbox` + `network.client` only (same as `Runnir.entitlements`), a pure Go helper (`CGO_ENABLED=0`, grpc-go 1.84.0, standard health service, about 14.7 MB) signed with `app-sandbox` + `inherit` (as `macos-helper.entitlements`), and a Swift client on grpc-swift-2 2.4.4 + grpc-swift-nio-transport 2.11.0. Run on macOS 27.0.1, Swift 6.4, with the code in a scratch directory outside the repository.

- The sandboxed app launched the inherited helper with `Process`; the helper bound a Unix socket in the app container (`~/Library/Containers/<bundle id>/Data/Library/Caches`); the client connected and `grpc.health.v1.Health/Check` returned SERVING. No `network.server` entitlement was needed.
- Not run outside an app launch: a sandboxed binary started from a shell traps (exit 133) because it has no container.
- **Deployment target:** grpc-swift 2 requires macOS 15; the Xcode project targets macOS 14.0. Adopting it means raising the target (a product decision) or choosing another client. grpc-swift 1.x (macOS 10.15+, SwiftNIO, `swift-protobuf`) is the fallback to evaluate.
- **Socket path length:** `sun_path` holds 103 bytes. The container path is already about 83 characters with a short bundle id, so the socket name must be short and the length checked at startup; fall back to a shorter directory if needed.
- Stale socket after an unclean exit was left in place; the server must remove it only under the lock (plan phase 2).
- Not verified: a Developer ID signed and notarized build, a real Xcode-built app, grpc-swift 1.x, the Swift gRPC dependency's effect on app size and CI time, helper behavior when the parent dies.
