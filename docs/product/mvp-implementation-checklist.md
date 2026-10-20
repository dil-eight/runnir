# MVP v0.1 Implementation Checklist

Status: acceptance backlog, updated 2026-10-19 (see Progress below). Desktop foundation is partially implemented; [verification](../architecture/desktop-foundation-verification.md) lists evidence and remaining gates. Unchecked entries are not fully accepted, even where partial code exists. Priorities apply to product requirements; execution order also follows dependencies. See the [specification](specification.md) and [gap analysis](../architecture/gap-analysis.md).

Design planning: [Pen production plan](../design/pen-production-plan.md), [screen/state matrix](../design/screens-and-states.md) and [reusable components](../design/reusable-components.md). Design completion does not mark a functional requirement implemented.

## Baseline To Preserve

- [x] Native SwiftUI/Observation app and existing navigation/source paths.
- [x] Swift REST/DTO and Keychain abstractions.
- [x] Pure Go CLI/version IPC and app helper bundling.
- [x] Test and CI configuration; earlier results are recorded in the foundation report.

These checks describe source foundations, not complete MVP features or a fresh test run.

## Progress (2026-10-19)

What exists in code, with tests, against the backlog below. A row stays unaccepted until its full evidence column is met, including the controlled real integrations.

| ID | State | Missing for acceptance |
| --- | --- | --- |
| B01 | Import, bookmarks (stale refreshed), scoped reads, Locate/relink | Developer ID signed build check |
| B02 | Discovery and bounded parsing in the Core (both extensions, limits, worktrees, no evaluation) | Developer ID signed build check |
| B03 | actionlint as a library in the Core, no external process; diagnostics with file, line and column in the Workspace section; repository config honored; reads bounded and kept inside the repository | Shellcheck and pyflakes checks (off by design for now); signed-build check |
| B05 | Device Flow with the registered app; no secret; token only in Keychain and Core memory | Rate-limit scheduling review |
| B06 | Restore, sign-out, revoked token, offline launch with retry; real sign-in confirmed by hand | Keychain denial on a signed build |
| B07 | Workspace linked to its GitHub repository through `origin`; access check through the Core | Account-wide browsing and search (if kept in scope) |
| B09 | Branch and tag selection; typed inputs, defaults, required and choice validation in the Core; device-private presets per workspace and workflow (branch and values, survive restart, stale branch or inputs reported, inputs that look secret never saved) | Portable `.runnir` presets (B25); presets follow a renamed workflow file |
| B10 | Single-use confirmation; send once, no retries; run located by polling | Controlled real dispatch |
| B11 | Runs, jobs and steps, active and idle polling, rate-limit states | — |
| B12 | Last 2 MiB / 50,000 lines of a job log, step matching, search, expired and not-ready states | Controlled real logs |
| B13 | Cancel, re-run all, re-run failed jobs with single-use confirmation; GitHub refusals shown | Controlled real operations |
| B14 | Bundled act (ADR 0006) plus experimental installed act; Docker CLI, engine and context detection (missing, stopped, remote, old API); Settings › Tools and the review show them; no installs, engine starts or context switches | Docker Desktop and Colima checks by hand; signed-build check |
| B15 | Plan from the workflow file: supported, unsupported and unknown jobs, needs closure, events, images and whether present, secrets read, notes, limits, blockers; review screen with trust confirmation; single-use confirmation refused after a file change | Workflows with services and matrices on a real engine |
| B16 | act with a fixed command line (no socket mount, no repository env/secret files or .actrc, bridge network, no cache server, labels and limits); live bounded output; job states; stop and timeout with process-group interrupt and kill; labelled-container cleanup; Core shutdown stops runs; verified end to end on OrbStack with small images | Run with the full runner images; a prompt when quitting during a run |

Not started: B04, B08, B18–B29 beyond the existing window and session foundation.

## Prioritized Backlog

| ID | Priority / FR | Vertical outcome | Depends on | Acceptance tests/evidence required |
| --- | --- | --- | --- | --- |
| B01 | P0 / FR-05 | Select/revoke one local repository; enforce scope | Native folder/entitlement design | Cancel picker, denied/stale grants, traversal and symlink escape; no unrelated file reads |
| B02 | P0 / FR-05 | Discover and inspect bounded workflow files | B01 | Both extensions, no files, malformed/oversize files, worktree .git marker, readable job summary without executing expressions |
| B03 | P0 / FR-05 | Offline actionlint diagnostics | B02; verified validator executable/process policy | Valid/invalid fixtures, file/line/column, missing binary, nonzero exit, timeout/output limit, hooks denied; real Swift/Go validation path |
| B04 | P0 / FR-05 | Edit/save/revalidate selected YAML | B01-B03 | Unsaved switching/closing, external change conflict, read-only files, scoped/atomic save; preserve unrelated edits; no git/network operations |
| B05 | P0 / FR-01 | Configure Device Flow and secure session boundary | Registered client; Keychain/IPC contract | Pending/slow-down/denial/expiry, cancellation, no embedded secret, token redaction and session invalidation |
| B06 | P0 / FR-01 | Login/restore/logout and recovery | B05 | Controlled real login; app restart; Keychain denial; revoked token; local logout versus remote revocation; rate-limit scheduling |
| B07 | P0 / FR-02 | Browse/search/select repositories and workflows | B06 | Paginated/empty/forbidden/offline responses, retry, refresh cancellation, selected-repo binding; service migration parity |
| B08 | P0 / FR-02 | Favorites and meaningful dashboard status | B07; run summaries from B11 | Favorites restart persistence, failed/active/latest summaries, stale-data labels and isolated errors |
| B09 | P0 / FR-03 | Ref/input form and non-secret presets | B07; structured workflow metadata | Branch/tag selection; supported input types/defaults/required/choices; preset persistence and invalidated schema; no secret values on disk |
| B10 | P0 / FR-03 | Confirm and submit dispatch, locate run honestly | B09; action approval | Rejected submission, ambiguous response, concurrent runs/index delay, no blind retries; controlled real dispatch and Web fallback |
| B11 | P0 / FR-04 | Recent runs, jobs/steps and polling | B07 | Status/conclusion mapping, pagination, backoff/rate limit, view-switch cancellation; controlled failed-run inspection |
| B12 | P0 / FR-04 | Bounded searchable log inspection | B11 | Large/expired/missing logs, safe archive handling, cancel download, responsive search/highlights, retention/redaction |
| B13 | P0 / FR-04 | Confirm cancel/rerun and track result | B11; action approval | Insufficient permissions, changed run state, duplicate clicks, accepted versus complete states; controlled real operations |
| B14 | P1 / FR-06 | Docker/OrbStack/act readiness and explicit setup | B01; approved tool/version policy | Missing CLI, stopped daemon, selected local versus remote context, unsupported architecture, user declines setup; no silent context change |
| B15 | P1 / FR-06 | Compatible local job inventory and execution plan | B02/B03/B14; structured job inspection | Linux fixture supported; macOS/iOS/unsupported services/secrets reported; mounts/network/images and credential policy visible |
| B16 | P1 / FR-06 | Start/stream/cancel/clean up local act execution | B15; execution lifecycle/approval/resource policy | Real simple fixture without commit/push; bounded live output, exit codes, cancellation/process+container cleanup, app shutdown; no automatic GitHub token injection |
| B17 | Release gate | Usable complete macOS v0.1 | B04/B06/B08/B10/B12/B13/B16 | End-to-end acceptance checklist below; licensing decision; distribution claims match actual verification |

First proposed slice: desktop window/registry/session foundations below; B01-B03 follow in the shared workspace context. Auth client registration can proceed independently. Add SQLite in F3 for the explicit offline requirement, not in the first window-only slice. No speculative plugin framework/event bus or permanent background daemon.

## MVP Acceptance Checklist

- [ ] Real supported Device Flow, restart restoration, local logout and documented revocation/error handling.
- [ ] Repository search/filter/favorites and workflow navigation without GitHub Web.
- [ ] Ref/typed input dispatch with persisted presets and honest submission/run correlation.
- [ ] Recent runs, job/step inspection, searchable available logs, cancel and rerun.
- [ ] Local repository/workflow discovery and basic job/dependency inspection.
- [ ] YAML edit/save preserves changes; offline validation produces actionable diagnostics.
- [ ] Compatible Linux workflow runs locally through act/Docker; output, cancellation and cleanup work.
- [ ] Docker Desktop/OrbStack and act setup is explicit; unsupported behavior is visible.
- [ ] Credentials are Keychain-only; no default telemetry or implicit secret/source uploads.
- [ ] Repository bounds and process/resource policies are enforced and tested in the relevant signed configuration.
- [ ] App requires no Runnir backend/account/subscription/AI provider.
- [ ] FR-08/09: splash/Manager routing, durable manual-close vs quit, independent/shared window state and optional .runnir/per-workspace SQLite/cache-first sync pass L01-L10/W01-W09.
- [ ] Tag/release labeling and any signing/notarization/update claims are verified.

## Feedback And Diagnostics Track (FR-07)

- [ ] B18: Design a top-toolbar Runnir GitHub link, opt-in analytics invitation, Privacy & Diagnostics settings and report preview; do not block primary workflows.
- [ ] B19: Implement fixed project URL and reviewed browser issue draft/fallback; test encoding, long payloads, no token reuse and Draft Opened versus Issue Created.
- [ ] B20: Add bounded user-selected Runnir crash import and allowlisted summary with redaction/retention tests; no broad crash-folder access or raw report upload.
- [ ] B21: Choose/document optional analytics operator/schema/retention; implement consent and payload allowlist tests before any delivery. Verify no queue/transmission without consent or after withdrawal.

B19 uses the checked-in issue template after it is published; B20 depends on scoped import and B19 preview. B21 is independent of crash reporting and must not introduce a mandatory backend. See [FR-07 detail](analytics-and-crash-reporting.md).

## Desktop Lifecycle And Persistence Track (FR-08/09)

- [ ] B22 / F1: AppKit splash, singleton Manager and independent windowId/WindowState; test routing/Dock/quit ordering.
- [ ] B23 / F1: Serialized SessionStore, durable manual close/tombstones, quit snapshot and transactional reassociation; crash-injection/idempotence/display tests.
- [ ] B24 / F2: Stable local-clone registry, canonical identity, explicit folder grants and move/relink/remove; distinct clones never merged by URL.
- [ ] B25 / F2: Read-only optional .runnir config/environments/launch loader; bounds/schema/traversal/degraded-opening and secret-reference permission tests.
- [ ] B26 / F3: Pure-Go SQLite selection/review, one DB per workspace, migrations/indices/blob metadata, unique-local-data backup/recovery and Clear Cache tests.
- [ ] B27 / F3/F4: Cache-first render and one shared runtime/sync per workspace; no duplicate writers/network requests from multiple windows; freshness/source reconciliation tests.
- [ ] B28 / F5: Environment/effective-value origins, machine overrides versus portable presets, scoped Keychain references and target-specific launch validation.
- [ ] B29 / F6: Multi-monitor, corrupted session/DB, partial writes, interrupted execution history and retention hardening; no auto process resume.

B22/B23/B24 support the first lifecycle slice, whose native window/registry foundation now exists with independent AppState. B25 precedes portable launch integration; B26/B27 precede complete offline cached remote UI. B28 extends B09/B10/B15 without removing the local execution requirement. B17 release evidence must also cover L01-L10/W01-W09; the version-only Core IPC provides no database/sync/execution guarantees.

## Dependencies And Open Decisions

- GitHub client identifier/app type, device-flow enablement and least-permission mapping.
- Supported scope/session IPC contracts; current RPC supports version only.
- actionlint/act versions, license notices, artifact verification and bundled versus user-installed distribution.
- Repository execution trust model, image/network/download consent, cleanup and resource bounds.
- Session durability/native restoration ordering, pure-Go SQLite driver and single-writer lifetime, config field merging, history/blob budgets and account-wide remote browsing placement; see ADR 0003.
- LICENSE remains GPLv3; proposed Apache-2.0 requires a separate explicit decision.

These decisions gate the features they affect, not documentation work or all independent slices.

## Verification During Implementation

For native code changes, run the build and RunnirTests commands in AGENTS.md. For Core changes run go test, go vet and go build from core. Use deterministic fixtures and fakes for failures; use controlled real integrations to substantiate end-to-end claims. Do not call authentication, signing, notarization, updates or deployment complete from mocked tests alone.

AI/MCP, cloud integrations/referrals, automatic artifact reuse and cross-platform release certification are outside this checklist.
