# Runnir MVP v0.1 Specification

Status: proposed product scope, reconciled with the existing repository on 2026-10-14.
Platform: macOS first; portable Go Core for future clients.
Positioning: Runnir is a better way to work with GitHub Actions.

This specification supersedes the earlier AI-first MVP scope. AI and MCP remain future extension points. It does not authorize recreating the app or imply the requirements below are implemented.

## Product Principles

Developer experience first, local first, open source, fast/responsive, AI-ready without AI dependence, cross-platform by design. No mandatory backend, Runnir account, subscription or paid AI.

Reduce the commit/push/test loop, simplify manual execution, and make repeated CI work visible. Automatic pipeline restructuring and artifact reuse are beyond v0.1.

## Architecture And License Reconciliation

Keep Swift 6, SwiftUI, Observation, Foundation, Security/Keychain and the separate pure Go executable, per [ADR 0002](../decisions/0002-swiftui-go-core.md) and AGENTS.md. The supplied brief's Tauri/React/Tailwind/shadcn stack is an alternative recommendation, not an adopted migration. No Node, React, Rust or Tauri dependencies are introduced.

Use versioned local IPC with one app-managed Core child process (gRPC over a Unix socket, [ADR 0004](../decisions/0004-single-core-process-grpc.md); JSON-RPC over stdio only for the version handshake); no permanent daemon. Keep transport separate from domain logic. Preserve existing Swift GitHub services until tested feature-level migrations are practical. New portable domain behavior belongs in Go; no competing implementations.

The checked-in LICENSE contains GPLv3. Apache-2.0 is proposed in the supplied brief but is not adopted by this update. A separate explicit licensing decision is needed before representing the project as Apache-2.0; this specification does not change LICENSE.

## FR-01 GitHub Authentication

Priority: P0. Use supported OAuth Device Flow with an explicitly configured GitHub OAuth/GitHub App client identifier and device flow enabled. No embedded client secret or required manually created PAT.

Persist tokens only in macOS Keychain. Support restart restoration, logout, expired/revoked tokens, denied/expired authorization and rate-limit recovery. Distinguish deleting local credentials from revoking authorization at GitHub; document a supported user-controlled revocation path if remote revocation cannot be performed without embedding a secret.

Acceptance: browser authorization completes; restart restores the account; logout clears local credentials; auth/rate-limit failures are actionable; tokens never appear in logs, plaintext configuration, argv or repository files. Permission scopes must be justified by the selected app type and feature set.

## FR-02 Repository Dashboard

Priority: P0. List accessible repositories; search/filter, favorites, refresh, selected-repository workflows and latest execution status. Navigate directly to a workflow and provide loading, empty, error and rate-limit states.

Acceptance: after authentication, reach a selected workflow without GitHub Web. Favorites survive restart. Failed/unavailable requests do not leave misleading cached status or an endless spinner.

## FR-03 Workflow Execution

Priority: P0. Dispatch published workflow_dispatch workflows; choose branch/tag, render supported typed inputs, validate required/default/choice values and save reusable local presets. Presets are non-secret configuration; sensitive values must not be persisted as plaintext.

Show submission progress and a GitHub Web fallback. Distinguish accepted dispatch from identified run. Correlate only when evidence is sufficient; show pending/ambiguous correlation rather than selecting an unrelated run. Do not automatically retry an ambiguously accepted mutation.

Acceptance: submit a supported workflow through the app; invalid inputs are rejected before sending; presets survive restart; the UI never claims execution started from submission alone. Unsaved local workflow definitions cannot be remotely dispatched through normal workflow_dispatch.

## FR-04 Run Inspector

Priority: P0. Recent runs, queued/in-progress/completed states and success/failure/cancelled/skipped conclusions; job/step inspection; available logs; log search, error/warning highlighting, permission-aware cancel/rerun and Web links.

Bound downloads, decompression and displayed buffers; keep parsing/search off the main thread and handle expired/unavailable logs. Refresh metadata and available logs subject to API availability; do not promise a live log stream from GitHub.

Acceptance: inspect a failed job's available logs; cancel/rerun a permitted run after confirmation; large logs remain responsive; queued, missing, rate-limited and expired resources have explicit states.

## FR-05 Local Workflow Workspace

Priority: P0. Open a user-selected local Git repository, discover .github/workflows/*.yml and *.yaml, show YAML and jobs, edit/save YAML and validate using actionlint. Show file/line/column diagnostics when available. Work offline without GitHub authorization.

Preserve unsaved edits, detect external file changes, save only the selected workflow after user action and never commit/push automatically. Enforce repository scope, path traversal and symlink boundaries. Parse files as data; do not execute repository configuration for discovery. Configure actionlint checks so validation cannot silently invoke repository code, network access or uncontrolled helper executables.

Acceptance: edit and validate without commit/push; syntax and supported validation errors are clear; reopening preserves saved changes; switching files handles unsaved edits; denied/out-of-scope paths are rejected. Missing actionlint produces setup guidance, not a successful validation result.

## FR-06 Local Execution

Priority: P1, required for a complete v0.1. Detect Docker CLI, selected engine/context and act. Support Docker Desktop and OrbStack on macOS through a Docker-compatible adapter. Offer explicit setup when needed; never silently install tools or switch context.

List supported workflows/jobs and run through act with live bounded output, cancellation, exit code and compatibility reporting. Use a fixed executable and validated argument arrays; no general shell API. Disclose images/actions/other network downloads and any data that the workflow itself may transmit. Do not inject the app's GitHub token or host environment secrets.

Acceptance: a simple compatible Linux workflow executes without commit/push; output stays responsive; cancellation stops associated processes/containers; result distinguishes success, failure and user cancellation. Unsupported macOS/iOS, hosted tools, permissions, services, environments or secrets are reported honestly.

Docker is not a secure isolation guarantee for arbitrary workflows. Require execution consent and a documented trust/resource policy, temporary workspaces, limited mounts/network/credentials and deterministic cleanup. Do not mount the Docker socket, home directory or broad host paths into workflow jobs. A dedicated VM may be needed for stronger isolation.

## FR-07 Optional Feedback And Diagnostics

Priority: P1 supporting product quality. Add a public Runnir GitHub link in the top toolbar and a user-reviewed crash/problem report draft for GitHub. Invite users to help improve the app through separately controlled, off-by-default analytics. Never send code, secrets, repository metadata/logs or personal paths; use strict field allowlists. No automatic public issue creation or crash upload. See [analytics and crash reporting](analytics-and-crash-reporting.md) for consent, data boundaries and acceptance gates. No runtime capability is implemented yet.

Acceptance: the project link is fixed to Runnir, optional data sharing is independently controllable, a sanitized report can be inspected before browser handoff and publication is never claimed from opening a draft. Analytics transport stays disabled until its operator/schema/retention are documented; the app does not depend on it. Existing FR-01 through FR-06 remain the core usability gates.

## FR-08 Desktop Lifecycle And Workspaces

Priority: P0 architecture foundation. Cold launch shows a transient branded splash, then restores eligible workspace windows or shows a singleton Workspace Manager. Dashboard is the initial tab within a new workspace. Local Git repository instances have stable workspaceId values; every window has its own windowId and independent UI state. Same-workspace windows share runtime/DB/sync services.

Manual close durably removes only that window from restoration; Cmd+Q preserves remaining windows before teardown. Last-window close leaves the app running without automatically reopening Manager; Dock activation with zero windows opens/focuses Manager exactly once. Switching offers Reuse Current Window, Open New Window and conditional Focus Existing; failed opening retains the source window. No live processes/workflows resume on restart. See [desktop lifecycle](../architecture/desktop-lifecycle.md) and L01-L10 acceptance cases.

## FR-09 Portable Config And Offline Persistence

Priority: P0 architecture foundation, phased with GitHub features. Read optional .runnir config/environments/launches safely and read-only on open. Store per-workspace SQLite/cache/runtime/overrides outside Git under resolved Application Support; Keychain owns secret values. Render local/cached UI before background shared sync, label origin/freshness and recover missing/moved roots or invalid/corrupt state without losing unique user data. See [persistence contract](../architecture/workspace-persistence.md) and W01-W09 acceptance cases.

Local-only presets remain device-private; portable .runnir launch presets require explicit creation/editing. Local/remote execution targets and effective non-secret value origins are visible; repository settings cannot bypass approval or grant credentials. Parsing a local target does not prove an executor exists. FR-06 remains required for complete v0.1; automatic shell/process restoration stays out of scope.

## UI And Storage

App entry route: splash -> eligible restored workspace windows or Workspace Manager. Within workspace windows: Dashboard, Repositories, Runs, Local Workspace, with native Settings available. Preserve existing views until replacements are useful; Manager/Splash are not sidebar destinations. The current single WindowGroup/shared AppState does not implement this target yet.

Dashboard: favorites, recent/failed/active runs, quick actions. Workflow detail: source/name, history, ref/inputs, presets, run action, jobs/logs. Workspace: repository selector, workflows, YAML editor, diagnostics, basic job dependencies, execution controls/output.

Use versioned Application Support settings/session/registry files and an embedded SQLite DB per registered local working-tree instance. This explicit offline requirement supersedes the earlier optional-SQLite recommendation. Keep portable non-secret .runnir configuration in the working tree only by user choice; local overrides and caches stay device-private. Credentials remain in Keychain. Cache removal preserves user-authored overrides/config and requires classified retention/recovery behavior.

## Security And Release Requirements

No telemetry by default, unrestricted AI/MCP commands, automatic commits/pushes, silently uploaded source/secrets or automatic production approval. Remote mutations require explicit user authorization. Treat workflows/logs as untrusted input.

Before repository tools or local execution ship, verify folder access and process/container access in a Developer ID signed build. Runnir ships without the App Sandbox ([ADR 0005](../decisions/0005-developer-id-without-app-sandbox.md)), so the Core's own scope rules must hold.

Retain semantic tags and draft GitHub releases. Production signing, notarization, packaging and secure updater implementation remain separate prerequisites; no completed authentication, distribution or deployment claims until verified.

## Out Of Scope For v0.1

AI chat, embedded models/provider routing, AI generation/repair, MCP server, GitLab/Jenkins, hosted execution, accounts/billing, team collaboration, automatic optimization/artifact reuse/workflow restructuring, full hosted-runner parity and Linux/Windows release certification.

DigitalOcean/doctl, landing deployment, referral catalog and repository-based offer matching remain documented future work, not MVP release gates. Docker/OrbStack readiness is in v0.1 because FR-06 requires it.

## Definition Of Done

FR-01 through FR-06 must pass their usability acceptance checks on macOS. FR-08/FR-09 add window restoration, workspace identity, read-only portable config, shared cache-first storage/sync and recovery gates. FR-07 remains independently optional feedback/analytics. No backend/account/subscription is needed, and no unimplemented lifecycle/storage feature is considered shipped by this update.

Provide deterministic tests for API errors/rate limits, validation diagnostics, scope enforcement, execution state and cleanup. Add end-to-end evidence for real GitHub and Docker/act flows with a controlled fixture repository; mocked tests alone do not establish completion.

See [implementation checklist](mvp-implementation-checklist.md), [gaps](../architecture/gap-analysis.md) and [first slice](first-implementation-slice.md).

## Success Criteria

Primary: common Actions operations require fewer navigation steps; workflow validation needs no commits; supported local execution reduces remote trial/error; the app becomes useful in daily development.

After public release, voluntary feedback, public aggregate signals and explicitly opted-in coarse usage analytics can inform priorities. No telemetry is enabled by default; identifier-free counters do not establish exact unique or weekly active users. See FR-07 before introducing any collection.

North star: make working with GitHub Actions faster, simpler and more predictable.
