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
- runnir_list_value_sets

Future: runnir_set_values ([below](#secrets-and-variables)), runnir_generate_workflow, runnir_plan_execution, runnir_test_workflow, runnir_get_test_results, runnir_dispatch_workflow, runnir_prepare_deployment. See `mcp/runnir-tools.json` for the planned catalog.

## Secrets And Variables

Added on 2026-11-05: a client saves the secrets and variables local runs use into one value set of a workspace, the Repository's or an environment's, as [Values Per Environment](../superpowers/specs/2026-11-03-environment-values-design.md) keeps them.

- `runnir_list_value_sets` (read-only): the sets, "Repository" and the environments as `ListEnvironments` returns them, and in each the names its jobs read, a secret or a variable, saved, empty (the Repository's value) or missing. A variable's value may come back; a secret's never does.
- `runnir_set_values`: a workspace, one set from that list and names with values, secrets apart from variables, at least one name. The client passes secret values too (decided on 2026-11-05), so a secret goes through the MCP client and the model's context; the tool's description says so. Runnir never returns, logs or audits a value, only names.
- Confirmation: the Core prepares the change and the workspace's window shows it: the set, each name, a variable's value, a secret masked with Show, and which names replace a saved value. Only Confirm in the app writes Keychain, under the accounts Secrets and Variables uses (`secret:NAME`, `environment:production:secret:NAME`). The client gets the saved names or the refusal.
- Refused before the app asks: a set the workspace does not have, a name GitHub would not take (letters, digits and `_`, not starting with a digit or `GITHUB_`), an empty value, a value over 48 KiB (GitHub's limit for a secret), more than 100 names.
- Not part of it: clearing a value (Secrets and Variables does that), GitHub's own secrets and variables (these sets are local), organization secrets.

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
| `runnir_list_value_sets`, `runnir_set_values` | the names jobs read (`ListWorkflows`) and `ListEnvironments`; saved values are in the app's Keychain, which the Core cannot read | a call that asks the app which names are saved, and a prepare call that the app confirms in its own window before it writes Keychain |
| future `runnir_dispatch_workflow`, `runnir_test_workflow` | `StartWorkflow` (stub runner) | an approval authority first |

Blocking before any client other than the app connects. Observed on 2026-10-17 with a standalone Core and separate clients: a second client could open an unrelated folder, close the first client's repository so that its next refresh failed `NOT_FOUND`, and start a workflow, all without any grant or approval.
1. **Client identity and a restricted surface.** The app now proves itself with a per-launch secret (see [gRPC API](grpc-api.md#security-model-today)), so a client without it is refused. An MCP adapter must not receive that secret. Give the adapter a different way in (a second listener or a per-client token) and let the Core enforce an allow-list of calls and repository grants per client. Read-only by default, with no `OpenRepository` of arbitrary paths, no `CloseRepository` and no `StartWorkflow`. Event subscriptions must be filtered by the Core, because `repository_ids` is chosen by the client.
2. **Per-client leases for open and close.** Today closing is global, so one client can end another's repository. Opens and closes need reference counting per client.
3. **Approval authority.** GitHub workflow dispatch now needs a Core-issued, single-use confirmation bound to repository, workflow, ref and inputs (`PrepareWorkflowDispatch`, then `ConfirmWorkflowDispatch`). Cancelling and re-running runs use the same two-step pattern (`PrepareRunAction`, then `ConfirmRunAction`), bound to repository, run and action. For MCP, confirming must stay with the app's own UI: an adapter may prepare, but never confirm. `StartWorkflow` (local execution) has no approval step yet.
4. **Discovery.** The socket sits in the per-user temporary directory under a name derived from the app bundle's path, which an adapter started by another application cannot assume. Define a discoverable location and what the adapter does when Runnir is not running: report it, rather than start a second Core.
