# MVP v0.1 Implementation Checklist

Status: acceptance backlog, updated 2026-10-20 (see Progress below). Desktop foundation is partially implemented; [verification](../architecture/desktop-foundation-verification.md) lists evidence and remaining gates. Unchecked entries are not fully accepted, even where partial code exists. Priorities apply to product requirements; execution order also follows dependencies. See the [specification](specification.md) and [gap analysis](../architecture/gap-analysis.md).

Design planning: [Pen production plan](../design/pen-production-plan.md), [screen/state matrix](../design/screens-and-states.md) and [reusable components](../design/reusable-components.md). Design completion does not mark a functional requirement implemented.

## Baseline To Preserve

- [x] Native SwiftUI/Observation app and existing navigation/source paths.
- [x] Swift REST/DTO and Keychain abstractions.
- [x] Pure Go CLI/version IPC and app helper bundling.
- [x] Test and CI configuration; earlier results are recorded in the foundation report.

These checks describe source foundations, not complete MVP features or a fresh test run.

## Progress (2026-10-20)

What exists in code, with tests, against the backlog below. A row stays unaccepted until its full evidence column is met, including the controlled real integrations.

| ID | State | Missing for acceptance |
| --- | --- | --- |
| B01 | Import, bookmarks (stale refreshed), scoped reads, Locate/relink | Developer ID signed build check |
| B02 | Discovery and bounded parsing in the Core (both extensions, limits, worktrees, no evaluation) | Developer ID signed build check |
| B03 | actionlint as a library in the Core, no external process; diagnostics with file, line and column in the Workspace section; repository config honored; reads bounded and kept inside the repository | Shellcheck and pyflakes checks (off by design for now); signed-build check |
| B04 | Workflow editor in the Workspace: line numbers, YAML colors, diagnostics marked, undo and find; Save through the Core with an atomic write inside the repository, refused when the file changed on disk since it was loaded (Reload from Disk or Save Anyway); edits kept when a reload finds a change; read-only files open read-only; save, don't save or cancel before switching files, switching workspaces, closing the window or quitting; saved files are checked again; new workflow files (a starter that runs by hand) and renames through the Core, never replacing a file, with the editor's unsaved edits and the star kept across a rename | — |
| B05 | Device Flow with the registered app; no secret; token only in Keychain and Core memory | Rate-limit scheduling review |
| B06 | Restore, sign-out, revoked token, offline launch with retry; real sign-in confirmed by hand | Keychain denial on a signed build |
| B07 | Workspace linked to its GitHub repository through `origin`; access check through the Core; a GitHub tab in the Workspace Manager lists the repositories the token reaches (every account where the app is installed, up to 1,000) with search, an owner filter and the installations; a repository opens as its registered workspace, or shows its workflows with their latest runs and recent runs without a local clone | A real-GitHub check with installations on several accounts |
| B08 | Favorite workflows per workspace (star in Overview and Workflows; favorites first in tabs, lists and the editor's menu) and starred repositories in the Manager's GitHub tab (first in the list, a Starred filter), kept on this Mac across restarts; Overview tabs show each workflow's latest GitHub run, the selected workflow's last run as a pipeline (columns from the jobs' needs, status and time per job, matrix jobs combined), recent runs, saved presets to run, a stale-data banner when GitHub cannot be reached, and isolated job-loading errors | A real-GitHub check of the pipeline |
| B09 | Branch and tag selection; typed inputs, defaults, required and choice validation in the Core; device-private presets per workspace and workflow (branch and values, survive restart, stale branch or inputs reported, inputs that look secret never saved); a workflow file renamed in Runnir gets copies of its presets, and the old ones stay for the name GitHub still runs; presets from `.runnir/launches` (B25) listed and applied next to them | — |
| B25 | Run Workflow presets from `.runnir/launches` read and checked in the Core's repository scan (no symlinks, at most 100 files of 64 KiB, exact workflow match, unknown keys refused, problems listed per file and never failing the scan); `ListLaunchPresets`; Overview › Run manually groups presets "in this repository" and "on this Mac" with unusable files shown; the Run Workflow menu offers both, applies a repository preset like a Mac one, leaves out values that look secret and copies it to this Mac on "Save as New"; Runnir never writes `.runnir` | Signed-build check |
| B10 | Single-use confirmation; send once, no retries; run located by polling; also for a repository without a local clone, from the Manager's GitHub tab (no presets there); optional Touch ID (or password) confirmation before sending, in Settings › Manual Runs, off by default | Controlled real dispatch |
| B11 | Runs, jobs and steps, active and idle polling, rate-limit states | — |
| B12 | Last 2 MiB / 50,000 lines of a job log read by the Core, the viewer showing the last 100 lines of the job or step; the whole log saved to a temporary file and opened in Visual Studio Code or the plain-text editor; step matching, search, expired and not-ready states | Controlled real logs |
| B13 | Cancel, re-run all, re-run failed jobs with single-use confirmation; GitHub refusals shown | Controlled real operations |
| B14 | Bundled act (ADR 0006) plus experimental installed act; Docker CLI, engine and context detection (missing, stopped, remote, old API); Settings › Tools and the review show them; no installs by Runnir itself, engine starts or context switches (Install with Homebrew opens Terminal with `brew install act`, run on Return) | Docker Desktop and Colima checks by hand; signed-build check |
| B15 | Plan from the workflow file: supported, unsupported and unknown jobs, needs closure, events, images and whether present, secrets read, notes, limits, blockers; review screen with trust confirmation; single-use confirmation refused after a file change | Workflows with services and matrices on a real engine |
| B16 | act with a fixed command line (no socket mount, no repository env/secret files or .actrc, bridge network, no cache server, labels and limits); live bounded output; job states; stop and timeout with process-group interrupt and kill; labelled-container cleanup; Core shutdown stops runs; quitting, closing the workspace's last window or switching it to another workspace asks first; verified end to end on OrbStack with small images | Run with the full runner images |
| B26 | One SQLite database per workspace in the Core (modernc.org/sqlite, `CGO_ENABLED=0`, [ADR 0007](../decisions/0007-workspace-sqlite.md)) under the app's support folder; one connection per database and a file lock against other processes; migrations with a copy before each and rollback on failure; a newer schema left untouched; budgets (5000 runs since B30, 200 local run records, 100 MiB of kept logs); kept job logs as checked files, only when turned on; local run history backed up after every change and restored from a damaged or missing database, the damaged file kept; Clear Cache in Settings › Storage, keeping local run history; removing a registration deletes the workspace's data | Signed-build check; power-loss and crash-injection tests; a recovery UI beyond the note in Settings › Storage (B29) |
| B27 | One runtime and sync loop per workspace in the Core, whatever the number of windows; windows show saved activity before GitHub answers and refresh on `ACTIVITY_CHANGED`; ETag reads, deletion and origin-change reconciliation, backoff, rate-limit and sign-in states; saved data kept and labelled when access is lost; shared jobs and log reads; freshness line (saved, refreshing, up to date, no changes, showing data from); covered by Core gRPC tests and app unit tests, and checked live in a test copy with two windows against a local fake Enterprise server (one read per pass) | A check against github.com itself; UI automation of several windows |
| B30 | Runs linked to pull requests and commits ([spec](../superpowers/specs/2026-10-23-run-change-links-design.md)): pull requests read with an ETag each pass and looked up when runs miss them (merges, forks), "Pull requests: read" asked for; links after merge and on a pull request's commits, superseded runs and how long they kept going; up to 5000 runs per workspace with older ones loaded as lists scroll; Runs `List \| By change` (List by default) with links on every row, completed superseded runs hidden, outdated runs labelled; inspector pull request, commit and superseded lines; a concurrency suggestion inserted into the editor as one undoable, unsaved edit; covered by Core and app unit tests, and checked live in a test copy with a seeded cache | A live check on a real pull request with pushes, a merge and a manual run; the concurrency block's effect on a real repository |

Not started: B18–B24 and B28–B29 beyond the existing window and session foundation.

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
- [ ] B25 / F2: Read-only Run Workflow presets from `.runnir/launches` (config and environment files not introduced); bounds/schema/traversal/degraded-opening tests.
- [ ] B26 / F3: Pure-Go SQLite selection/review, one DB per workspace, migrations/indices/blob metadata, unique-local-data backup/recovery and Clear Cache tests.
- [ ] B27 / F3/F4: Cache-first render and one shared runtime/sync per workspace; no duplicate writers/network requests from multiple windows; freshness/source reconciliation tests.
- [ ] B28 / F5: Secrets for local runs from the workflow's own `secrets.X` references: entered for one run or kept in Keychain per workspace, shown only after Touch ID or the password, passed to act through its environment; environment variables from the user's tools (dotenvx, `.env`); no Runnir format for either.
- [ ] B29 / F6: Multi-monitor, corrupted session/DB, partial writes, interrupted execution history and retention hardening; no auto process resume.

B22/B23/B24 support the first lifecycle slice, whose native window/registry foundation now exists with independent AppState. B25 precedes portable launch integration; B26/B27 precede complete offline cached remote UI. B28 extends B09/B10/B15 without removing the local execution requirement. B17 release evidence must also cover L01-L10/W01-W09; the version-only Core IPC provides no database/sync/execution guarantees.

## Dependencies And Open Decisions

- GitHub client identifier/app type, device-flow enablement and least-permission mapping.
- Supported scope/session IPC contracts; current RPC supports version only.
- actionlint/act versions, license notices, artifact verification and bundled versus user-installed distribution.
- Repository execution trust model, image/network/download consent, cleanup and resource bounds.
- Session durability/native restoration ordering, pure-Go SQLite driver and single-writer lifetime, config field merging, history/blob budgets; see ADR 0003. Account-wide browsing is a GitHub tab in the Workspace Manager (decided 2026-10-20).
- LICENSE remains GPLv3; proposed Apache-2.0 requires a separate explicit decision.

These decisions gate the features they affect, not documentation work or all independent slices.

## Verification During Implementation

For native code changes, run the build and RunnirTests commands in AGENTS.md. For Core changes run go test, go vet and go build from core. Use deterministic fixtures and fakes for failures; use controlled real integrations to substantiate end-to-end claims. Do not call authentication, signing, notarization, updates or deployment complete from mocked tests alone.

AI/MCP, cloud integrations/referrals, automatic artifact reuse and cross-platform release certification are outside this checklist.
