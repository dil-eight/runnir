# Core gRPC API v1

Status: implemented in the Core and used by the desktop app, 2026-10-17. Decision and history: [ADR 0004](../decisions/0004-single-core-process-grpc.md) and the [implementation plan](core-process-plan.md). Source of truth for messages: `contracts/grpc/runnir/core/v1/runnir_core.proto`. The earlier [JSON-RPC stdio contract](ipc.md) remains for the version handshake.

## Process And Transport

- One Core per app instance. The app launches the bundled `runnir-core serve --socket PATH --exit-on-stdin-eof` with Foundation `Process`. Closing a window never stops it; quitting does.
- gRPC over a Unix domain socket, mode 0600, at `<per-user temporary directory>/runnir-core.sock` (inside the container when sandboxed). No TCP listener. Paths over 103 bytes are refused.
- An advisory `flock` on `PATH.lock` allows one Core per socket. A second instance exits with status 3 and does not touch the running Core's socket. A stale socket is removed only while holding the lock. Other exit statuses: 0 clean stop, 1 failure, 2 usage.
- The Core stops on SIGINT or SIGTERM, or when stdin closes (the parent died). Stopping cancels running executions, ends event streams (`UNAVAILABLE`) and removes the socket.
- The app (`CoreProcessSupervisor`) waits for a `HealthCheck` that reports protocol version 1 and the pid of the child it launched; a Core answering with another pid is not accepted. When the child exits, the state becomes `lost` and each workspace window offers "Restart Core". There is no automatic restart.

## Calls

Every repository call carries `repository_id`: `repo_` plus a hash of the first resolved path, stable across close and reopen.

| Call | Behavior | Errors |
| --- | --- | --- |
| `HealthCheck` | Core version, protocol version, open repository count, process id, approximate memory (Go runtime total, not footprint) | |
| `OpenRepository(path)` | Absolute directory; symlinks resolved. Idempotent: the same directory returns the same context and shares one initial scan | `INVALID_ARGUMENT` (not an absolute existing directory), `PERMISSION_DENIED` (the OS refuses the Core read access) |
| `RefreshRepository` | Rescans branch and `.github/workflows`; refreshes of one repository run one at a time, other repositories are unaffected; a failed refresh keeps the last data | `NOT_FOUND`, `PERMISSION_DENIED` |
| `CloseRepository` | Releases the context and cancels its executions. Global: it closes the repository for every client | `NOT_FOUND` |
| `ListWorkflows` | Last scanned snapshot; name, triggers, jobs with `needs`, per-file `parse_error`. Expressions are kept verbatim. Limits: 200 files, 1 MiB per file, 1000 jobs per workflow | `NOT_FOUND` |
| `StartWorkflow` | Starts or queues an execution of a copy of the scanned workflow. At most 3 run at once; 100 wait in FIFO order | `NOT_FOUND`, `FAILED_PRECONDITION` (parse error), `RESOURCE_EXHAUSTED` (queue full) |
| `SubscribeEvents` | First message `CORE_READY` with the baseline sequence, then repository and execution events, optionally filtered by `repository_ids`; events without a repository always pass | ends with `RESOURCE_EXHAUSTED` when the subscriber falls behind (queue of 256), `UNAVAILABLE` at shutdown |

Execution is a stub: the runner fails every job with "workflow execution engine is not available in this build". There is no cancel call in v1; executions are cancelled by closing the repository or stopping the Core.

Events: `REPOSITORY_OPENED`, `REPOSITORY_REFRESHED`, `REPOSITORY_CLOSED`, `WORKFLOW_STARTED`, `WORKFLOW_STATUS_CHANGED` (queued, cancelled), `WORKFLOW_COMPLETED`, `WORKFLOW_FAILED`, `CORE_ERROR`. `sequence` is monotonic per Core process and matches delivery order; a gap or `RESOURCE_EXHAUSTED` means: resubscribe and reload state. Nothing keeps event history.

The scanner reads the branch from `.git/HEAD` (also linked worktrees; detached HEAD gives an empty branch), never follows symlinks, and treats an unreadable folder as an error rather than an empty repository.

## Compatibility

Package `runnir.core.v1`; `buf breaking` (FILE rules) guards it, and generated Go and Swift code is committed (`scripts/generate-contracts.sh`). Additive fields and calls keep the package; a breaking change needs `v2`. Clients check `protocol_version` before other calls.

## Security Model Today

The socket is reachable only by the same user, but any process of that user that can reach the path has full access: there is no per-client identity, grant or approval. Verified on 2026-10-17 with a standalone Core and separate `grpcurl` clients: a second client opened an unrelated folder, closed the first client's repository (whose next refresh then failed `NOT_FOUND`), and started a workflow. That is acceptable for the app as the only client. It must change before any other client, including an MCP adapter, connects; see [MCP readiness](mcp.md#readiness-against-the-grpc-core-api).

Folder access under the App Sandbox: the helper uses the app's grant. See the sandbox section of the [plan](core-process-plan.md#sandbox-folder-access-for-the-core-2026-10-17).
