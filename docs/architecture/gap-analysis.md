# MVP Architecture Gap Analysis

Updated: 2026-10-16. Desktop implementation/build/unit evidence is recorded in [desktop verification](desktop-foundation-verification.md). Earlier foundation verification remains in [its report](foundation-verification.md).

## Requirement Inventory

| Requirement | Status | Existing evidence | Missing for acceptance |
| --- | --- | --- | --- |
| FR-01 authentication | Partial foundation | Swift KeychainCredentialStore, CredentialStoring, REST current-user call; AuthenticationView is an empty state | Device Flow/client configuration, session/restart/logout UX, revocation path, token error recovery, rate-limit policy |
| FR-02 dashboard | Partial foundation | RepositoriesView calls listRepositories; REST repositories/workflows methods and pagination; native navigation | Real auth, search/filter/favorites/refresh, repository selection binding, latest status; WorkflowsView is an empty state |
| FR-03 dispatch | Missing | Workflow domain model only; GitHubEndpoint currently contains GET methods only | Workflow YAML/input schema/ref discovery, dispatch, presets, permission/confirmation gates, correlation and fallback |
| FR-04 inspector | Missing feature | WorkflowRun model; RunsView explicitly says monitoring is planned | Run/job/step/log APIs, polling, bounded log viewer/search, cancel/rerun |
| FR-05 workspace | Partial | Native folder picker/bookmarks, pinned directory descriptors and no-symlink traversal, bounded read-only local YAML browser | Signed scope verification, exhaustive race testing, save/editor, job inspection, actionlint adapter/diagnostics |
| FR-06 local execution | Missing | Version-only Process transport provides a narrow lifecycle example; setup/sandbox docs are plans | Docker/OrbStack/act adapters, compatible job inventory, execution approvals, streaming/cancellation, limits and cleanup |
| FR-07 optional feedback/diagnostics | Partial | Fixed public GitHub toolbar/help links and issue template; no runtime collection | Independent consent, payload/endpoint policy, crash import/sanitization and reviewed issue handoff |
| FR-08 lifecycle/workspaces | Partial | AppKit splash/Manager, independent window IDs/state, bookmarks, atomic registry/session, startup/quit regression tests, transactional multi-window relink | Crash/power-loss injection, signed grants, native failed-write/quit cancellation, multi-monitor and full recovery integration tests |
| FR-09 config/offline storage/sync | Partial registry only | Swift combined desktop-state.json; Core remains version-only | Read-only .runnir schemas, per-workspace DB/migrations, shared sync, environments/effective values, DB corruption/retention recovery |

No FR is complete. A credential abstraction is not authentication; a model/screen is not an operational feature. FR-07 adds supporting feedback/reliability work without making analytics or a backend mandatory for the six core usability requirements.

## Foundations Already Implemented

Native Swift 6/SwiftUI/Observation app and Xcode test targets; Swift typed REST client/DTOs; Keychain abstraction; pure Go version CLI; versioned bounded stdio RPC; bundled helper startup handshake; contract/unit test sources; build/test/analyzer and Go cross-build/security workflow configuration.

Current Core has no GitHub, workflow validation or execution services. Its only RPC method is core.v1.version. Do not call the desktop endpoint an MCP server.

## Specific Gaps And Dependencies

| Gap | Enables | Required resolution |
| --- | --- | --- |
| Repository capability boundary | FR-05/06 | User-selected grants, bookmark lifecycle, canonical path/symlink enforcement and signed helper access tests |
| Validation process boundary | FR-05 | Approved actionlint provenance/version, fixed argv, time/output limits, structured diagnostics, no uncontrolled hooks |
| Secure session bridge | FR-01 and Go GitHub work | Keychain-owned persistence, private in-memory handoff/lifetime, no token echo/argv/files, logout invalidation |
| Feature-level GitHub migration | FR-02/03/04 | Keep Swift services usable; replace per tested feature, avoid new duplicated domain logic |
| Input/YAML metadata | FR-03/05 | Structured inspection without executing YAML/scripts; typed supported input defaults/choices |
| Persistent non-secret configuration | FR-02/03/09 | Global local settings/registry/session; per-workspace SQLite; optional portable .runnir launches separated from private overrides; driver/version still open |
| Long-running process/events | FR-06 | Existing one-request version transport cannot stream executions; add a scoped typed execution lifecycle when needed |
| Docker access and trust policy | FR-06 | Resolve engine/socket and signed sandbox constraints; scoped workspace, no socket-in-job mounts or implicit credentials |
| Dispatch/run correlation | FR-03 | Submission != run start; ambiguity, race, indexing delay and safe retry behavior |
| Logs resource controls | FR-04 | Bounded download/archive extraction/display, redaction, nonblocking search and retention |
| License decision | Public release | LICENSE is GPLv3; Apache-2.0 in the brief remains proposed, not adopted |

## Test Coverage Boundary

All 41 unit tests pass. Coverage includes REST decoding through the production client, credential/model/version-IPC behavior, registry/session mutations, corrupt-state handling, quit during delayed load, multi-window relink and failure rollback, pinned-root replacement, child symlink rejection, bounded workflow reads and maximum-size YAML highlighting. Native smoke checks cover import/read/multiple windows/close/quit/restart, not comprehensive UI end-to-end coverage. Signed scope enforcement, exhaustive hostile filesystem races, native stale bookmarks, Keychain restart, API pagination/rate-limit, Device Flow, actionlint, act and large logs remain unverified.

Add tests with the feature they protect. Native execution on every Go target, production signing/sandbox enforcement, authentication and deployment remain unverified until separately exercised.

## Scope Reconciliation

Preserve ADR 0002 and current Xcode paths. ADR 0003 adds workspace/window identity, native startup routing and per-workspace SQLite. Product spelling stays Runnir until an explicit rename decision; .runnir is exact. Dashboard becomes a workspace tab rather than unconditional launch destination. AI/MCP remain deferred; FR-06 local execution is still required even if config parsing precedes executor implementation. Account-wide remote browsing placement, pure-Go SQLite driver, critical-close durability, signed grants and config merging details remain open.

See [prioritized backlog](../product/mvp-implementation-checklist.md) and [first slice](../product/first-implementation-slice.md).
