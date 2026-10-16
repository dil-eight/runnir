# MCP Architecture

Status: planned. The checked-in catalog is a design artifact; `runnir rpc` is a version-only desktop IPC endpoint, not an MCP server.

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
