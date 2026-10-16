# Product Roadmap

Updated 2026-10-14. The [MVP specification](specification.md) and [ADR 0003](../decisions/0003-workspaces-sessions-offline-storage.md) supersede earlier ordering. SwiftUI + Go Core stays; launch routing is Splash -> restored workspace windows or Manager, with Dashboard inside a workspace.

## v0.1 Usable Desktop Client

Release gate: FR-01 through FR-06, including local execution, plus FR-08/FR-09 lifecycle/offline foundations. FR-07 sharing remains optional and does not introduce a mandatory backend.

### Desktop Foundation Phases

| Phase | Outcome | Required evidence |
| --- | --- | --- |
| F1 Windows/session | Independent window IDs/state, singleton Manager, native splash, manual-close vs quit, Dock activation and durable session | L01-L06/L08/L09, no network startup dependency |
| F2 Registry/config | Stable local clone IDs, explicit import/relink/grants, read-only optional .runnir and preset display | W01-W04, no silent working-tree changes |
| F3 Offline storage | Per-workspace SQLite/migrations/index, cache-first opening, unique-local-data recovery | W05/W08, missing/corrupt DB and concurrent windows |
| F4 Shared synchronization | One logical sync per workspace, bounded incremental GitHub updates and source/freshness distinction | W06/W07, offline/auth/rate-limit/deletion reconciliation |
| F5 Environments/launches | Effective non-secret values/origins, private overrides, portable launch presets and Keychain references; separate targets | W03/W04; FR-03/06 runtime availability and approval gates |
| F6 Hardening | Multi-display/partial-write/crash recovery, retention, diagnostics and regressions | L07-L10/W08-W09; no automatic process/workflow resume |

Phases are implementation dependencies, not six mandatory releases. Auth client configuration can proceed independently. Config parsing/preset display may precede execution; complete v0.1 still requires the act/Docker path.

| Milestone | Deliverable | Dependencies |
| --- | --- | --- |
| M1 Foundation and account | Preserve native/Go foundation, new desktop lifecycle, secure auth session, Device Flow, account restoration/logout | F1/F2 and current IPC/Keychain; registered client and auth contract |
| M2 GitHub workflows | Cached repository/workflow UI, selected ref, typed dispatch, portable/private preset separation and honest correlation | M1/F3/F4/F5; parser/permission checks |
| M3 Run inspector | History, jobs/steps, bounded searchable logs, cancel/rerun, polling/error states | M1; selected repository/run; mutation confirmation |
| M4 Local workspace | Folder grants, workflow discovery/jobs, YAML editing/conflict handling, offline actionlint diagnostics | Local scope/process design and actionlint setup; independent of OAuth |
| M5 Local runner | Docker/OrbStack and act readiness, compatible jobs, opt-in execution/output/cancellation/cleanup | M4; execution approval, resource/network/credential policy |
| Release readiness | Acceptance fixtures, permission/error tests, distribution/license decisions and accurate limitations | All six FRs; controlled real integration evidence |
| Feedback and diagnostics | Top-toolbar project link, reviewed issue drafts, local sanitized crash import, optional analytics consent | FR-07; independent consent/redaction checks; analytics delivery disabled until destination/retention review |

The [first slice](first-implementation-slice.md) now establishes workspace/window lifecycle and registry identity; [offline validation](offline-validation-slice.md) follows using that context. Authentication configuration can proceed independently. Milestones group outcomes, not a mandatory serial schedule.

The brief's 7-10 days is an aggressive personal-prototype estimate, not a delivery commitment. Signed sandbox/process feasibility, tool setup, GitHub auth/dispatch correlation and local execution compatibility can change the estimate.

## v0.2 Developer Productivity

Advanced log viewer, run comparison, richer dependency visualization, notifications, improved local runner compatibility, artifact inspection and deterministic CI usage/wasted-work insights. Basic presets are already mandatory in v0.1; v0.2 may improve their ergonomics.

## v0.3 Optional AI And MCP

Context-aware chat, Apple/on-device and optional external providers, local inference, opt-in free-tier/BYOK integrations, workflow explanations/generation and MCP for external clients. Use structured tools and explicit risky-action approval; no paid AI requirement.

Retain [AI](../architecture/ai.md) and [MCP](../architecture/mcp.md) designs as extension points. Do not implement their infrastructure during v0.1 just to anticipate this release.

## v0.4 CI/CD Optimization

Build/deploy separation recommendations, explicit trusted artifact reuse, logical pipelines, duplicate execution/CI-minute analysis, deployment improvements and cross-platform expansion. Do not claim skipped GitHub jobs can be arbitrarily resumed.

## Unscheduled Startup Integrations

Preserve DigitalOcean/doctl, static landing deployment, external signed offer catalog and local recommendation research as optional future directions. They do not gate v0.1 and must not divert implementation from core Actions workflows. See [startup integrations](startup-integrations.md).

## Continuing Engineering Work

Keep Core target cross-build checks and macOS/Linux/Windows native CI; cross-platform packaging certification is outside v0.1. Continue tag-based draft releases. Resolve GPLv3 versus proposed Apache-2.0 explicitly; validate signing/notarization/updater separately before making production claims.
