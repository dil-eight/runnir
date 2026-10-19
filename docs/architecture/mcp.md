# MCP Architecture

Status: planned. The checked-in catalog is a design artifact; `runnir rpc` (version handshake) and `runnir serve` (the app's [gRPC API](grpc-api.md)) are desktop IPC endpoints, not MCP servers.

MCP is deferred to the optional v0.3 direction. It is not an active v0.1 implementation requirement; see the [current roadmap](../product/roadmap.md).

MCP server belongs in portable Go Core. Start with local stdio and read-only capabilities. A future MCP client is optional and out of initial scope. MCP adapters reuse Core services rather than reimplementing GitHub/workflow logic.

## Initial Tools

- runnir_list_repositories
- runnir_list_workflows
- runnir_get_run
- runnir_get_job_logs
- runnir_analyze_workflow
- runnir_validate_workflow
- runnir_suggest_improvements

Future: runnir_generate_workflow, runnir_plan_execution, runnir_test_workflow, runnir_get_test_results, runnir_dispatch_workflow, runnir_prepare_deployment. See `mcp/runnir-tools.json` for the planned catalog.

## Enforcement

Read-only by default, per-repository grants, separate validation/execution permissions, no unrestricted shell, no token responses and no unauthenticated network listener. Logs/workflows are untrusted. Consequential actions create a minimal local audit trail with retention controls and no secrets/content dumps.

Approval is enforced by Runnir outside both model and MCP client. A client-supplied confirmation boolean is insufficient. Bind approval to a specific operation and inputs; production deployment always requires explicit authorization. Design CLI/headless approval authority before exposing any mutation.

Before release, test actual MCP initialization, tools/list, tools/call, invalid inputs, repository denial, secret redaction, prompt injection, and approval behavior against supported clients.

## Readiness Against The gRPC Core API

Reviewed 2026-10-17 against the implemented [gRPC API v1](grpc-api.md). This is a design review plus a manual check of multi-client behavior, not an MCP implementation; no adapter was built or tested.

The intended shape is one MCP adapter process (stdio toward Claude or Codex) that connects to the app's existing Core over its socket and calls the same services. It never starts a Core per repository, and the instance lock keeps a second Core from appearing.

**No existing call or message has to change.** Everything needed below is additive: new calls or fields in `runnir.core.v1`, a restricted way to connect, and request metadata. The base API therefore stays compatible, which is what acceptance criterion 10 asks. It does not mean the Core is safe to expose to an MCP client today.

| Catalog tool | Core support | Needed |
| --- | --- | --- |
| `runnir_list_workflows` | `ListWorkflows` (the `repository` argument is a `repository_id`) | nothing |
| `runnir_list_repositories` | none | a `ListRepositories` call returning only repositories the client may see |
| `runnir_analyze_workflow`, `runnir_validate_workflow`, `runnir_suggest_improvements` | workflow ids are relative paths, matching `relativePath`; the Core has structure only | calls for bounded workflow source and validation (actionlint) |
| `runnir_get_run`, `runnir_get_job_logs` | none: GitHub runs and logs are still in the Swift REST client | Core services for runs and logs after their migration; no duplicate logic |
| future `runnir_dispatch_workflow`, `runnir_test_workflow` | `StartWorkflow` (stub runner) | an approval authority first |

Blocking before any client other than the app connects. Observed on 2026-10-17 with a standalone Core and separate clients: a second client could open an unrelated folder, close the first client's repository so that its next refresh failed `NOT_FOUND`, and start a workflow, all without any grant or approval.
1. **Client identity and a restricted surface.** The app now proves itself with a per-launch secret (see [gRPC API](grpc-api.md#security-model-today)), so a client without it is refused. An MCP adapter must not receive that secret. Give the adapter a different way in (a second listener or a per-client token) and let the Core enforce an allow-list of calls and repository grants per client. Read-only by default, with no `OpenRepository` of arbitrary paths, no `CloseRepository` and no `StartWorkflow`. Event subscriptions must be filtered by the Core, because `repository_ids` is chosen by the client.
2. **Per-client leases for open and close.** Today closing is global, so one client can end another's repository. Opens and closes need reference counting per client.
3. **Approval authority.** `StartWorkflow` and every later mutation need approval bound to repository, operation and inputs, enforced by Runnir outside the model and the MCP client. None exists.
4. **Discovery.** The sandboxed app's socket sits in its container's temporary directory, which an adapter started by another application cannot assume. Define a discoverable location and what the adapter does when Runnir is not running: report it, rather than start a second Core.
