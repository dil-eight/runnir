# 0004 Single App-Owned Core Process With Local gRPC

Status: proposed for MVP, 2026-10-17. Amends the transport decision in [ADR 0002](0002-swiftui-go-core.md) and realizes the shared-runtime direction of [ADR 0003](0003-workspaces-sessions-offline-storage.md). Nothing here is implemented yet.

## Decision

Runnir.app starts exactly one Go Core process per app instance. That process serves every open repository and every SwiftUI window over local gRPC. Window lifetime never controls Core lifetime; app quit does.

- **Transport:** gRPC over a Unix domain socket in the app-private container. No TCP listener, no external interface. If the chosen Swift or Go gRPC library cannot use a UDS, fall back to loopback with a per-launch random token and record the exception in this ADR.
- **Lifecycle:** Swift `Process` launches the bundled helper (`runnir-core serve`), waits for `HealthCheck`, and owns shutdown. A lock file beside the socket prevents duplicate Cores; a stale socket is removed only after the lock is proven free. Core exits when the parent dies (stdin EOF or parent-pid watch). No launch agent, no permanent daemon.
- **Crash recovery:** Swift detects a lost channel, shows a recovery prompt, restarts Core, reconnects, and re-opens the registered repositories and event subscription.
- **Domain model:** `RepositoryManager` holds one `RepositoryContext` per stable `repository_id`. This id is the `workspaceId` from ADR 0003, never a path or a window title. Opening an already-open path returns the existing context. Contexts share no mutable state without synchronization.
- **Concurrency:** workflow executions run through an `ExecutionCoordinator` with a default limit of three concurrent runs and a FIFO queue. The limit applies to executions, not open repositories. Long operations never block the gRPC server or the UI.
- **Events:** one `SubscribeEvents` server stream. Events carry `repository_id` where relevant. Delivery uses bounded per-subscriber buffers; a slow subscriber is dropped or coalesced, never allowed to grow memory.
- **Refresh:** manual in MVP. Refresh rereads `.github/workflows`, resolves the branch, reparses YAML and publishes `REPOSITORY_REFRESHED`. A running execution keeps the workflow snapshot it started with. No file watcher in MVP.
- **MCP:** a later MCP adapter connects to this same Core and calls the same services. Every operation names its `repository_id`; dangerous operations go through the trusted approval authority described in ADR 0002/IPC v1.

## Contract

`contracts/grpc/v1/runnir_core.proto` is the source of truth, versioned in its package (`runnir.core.v1`). RPCs: `HealthCheck`, `OpenRepository`, `CloseRepository`, `RefreshRepository`, `ListWorkflows`, `StartWorkflow` (interface only in MVP), `SubscribeEvents`. Event types: `CORE_READY`, `REPOSITORY_OPENED`, `REPOSITORY_REFRESHED`, `REPOSITORY_CLOSED`, `WORKFLOW_STARTED`, `WORKFLOW_STATUS_CHANGED`, `WORKFLOW_COMPLETED`, `WORKFLOW_FAILED`, `CORE_ERROR`. Additive fields are compatible; breaking changes need a new package version. `HealthCheck` returns the product version and a protocol version that clients check before any domain call.

## Reconciliation With Existing Rules

- **Stdio JSON-RPC (ADR 0002, IPC v1):** `runnir rpc` and `core.v1.version` stay as the compatibility handshake and for CLI/diagnostics until gRPC reaches parity. Removal is a separate decision. ADR 0002's "no permanent daemon, app-owned lifetime" is preserved.
- **Dependencies:** this adds `google.golang.org/grpc` and `protobuf` to Core and a Swift gRPC package (grpc-swift 2 via Swift Package Manager; no CocoaPods or Carthage). AGENTS.md asks to prefer the standard library, so versions, licenses and binary-size impact must be reviewed before merge. Generated code is committed so builds need no `protoc`.
- **Pure Go:** `CGO_ENABLED=0` still holds; grpc-go is pure Go.
- **Sandbox:** the helper inherits the app sandbox; the socket lives in the app container and its directory is mode 0700. Signed-build behavior needs separate verification before any claim.
- **Credentials:** never cross gRPC metadata, logs or events. Keychain stays in Swift.
- **Existing Swift services:** preserved. GitHub domain logic is not duplicated; new workflow parsing lives only in Go.

## Resource Targets

Internal targets, not guarantees: at most 300 MB combined idle footprint with 10 open repositories and no executions. Measure memory and CPU at 1, 3 and 10 repositories with a diagnostics RPC or script. Keep contexts lazy: load workflow summaries, not file bodies, and hold no log history in RAM.

## Alternatives

- **One Core per repository:** simpler isolation, but process count grows with repositories and works against the memory target.
- **Keep one-shot stdio JSON-RPC:** cannot stream events or share state between windows.
- **Persistent stdio multiplexing:** reinvents framing, cancellation and streaming that gRPC provides.
- **Always-on launchd daemon:** rejected by ADR 0002; adds lifecycle and authentication requirements.

## Open Decisions

gRPC-Swift version: the [phase 0 spike](../architecture/core-process-plan.md) showed UDS works under the App Sandbox with grpc-swift 2, which needs macOS 15 while the project targets 14.0 (raise the target or evaluate grpc-swift 1.x); YAML parser for Go (the standard library has none, so a dependency must be chosen); event-buffer overflow policy; `repository_id` derivation and its relation to the ADR 0003 registry; whether the one-shot `rpc` handshake is retired.
