# MVP Architecture Gap Analysis

Updated: 2026-10-25. The [MVP checklist](../product/mvp-implementation-checklist.md#progress-2026-10-20) records what exists per backlog item. This document groups that evidence by requirement and lists what still stands between the code and the acceptance of each one. Older reports: [desktop verification](desktop-foundation-verification.md) (2026-10-15 and 16) and [foundation verification](foundation-verification.md).

Evidence behind this update: the checklist, the ADRs, the Core and app sources at `eb0632f` (B28 and B31 included), and `go test ./...` run from `core/` on 2026-10-25 (every package with tests passed). The app unit tests were not re-run for it: the Xcode "Build Go Core" phase runs with `GOTOOLCHAIN=local` and `core/go.mod` requires Go 1.27.3, while the Go on the checking Mac was 1.27.2.

## Requirement Inventory

| Requirement | State | Existing evidence | Missing for acceptance |
| --- | --- | --- | --- |
| FR-01 authentication | Implemented, partly verified | Device Flow with the registered Runnir Desktop GitHub App (no secret), personal access token as the alternative and the only way into Enterprise servers; token only in Keychain and Core memory; restore, sign-out, revoked token, offline launch with retry; real sign-in confirmed by hand (B05, B06; [GitHub authentication](../security/github-authentication.md)) | Keychain denial on a Developer ID signed build; rate-limit scheduling review |
| FR-02 dashboard | Implemented, partly verified | Workspace Manager GitHub tab listing the repositories the token reaches (up to 1,000, search, owner filter, installations); starred repositories; per-workspace favorite workflows; Overview with each workflow's latest run, a pipeline of the last run, recent runs and stale-data banners (B07, B08); a Saved section with the GitHub Actions minutes local runs saved (B31) | A real-GitHub check with installations on several accounts; a real-GitHub check of the pipeline; the Saved section is drawn as a tile where the design settled on rows, and cancelled and superseded savings are design only |
| FR-03 dispatch | Implemented, partly verified | Branch and tag selection; typed inputs read at the chosen ref; validation in the Core; device-private presets and presets from `.runnir/launches`; single-use confirmation, no retry, run located by polling; optional Touch ID before sending (B09, B10, B25) | Controlled real dispatch; signed-build check of repository presets |
| FR-04 run inspector | Implemented, partly verified | Runs, jobs and steps with active and idle polling; bounded job logs with search and a whole-log hand-off to an editor; cancel, re-run all, re-run failed jobs and re-run one job with single-use confirmation; runs linked to pull requests and commits (B11 to B13, B30) | Controlled real logs and operations; a live check of B30 on a real pull request with pushes, a merge and a manual run |
| FR-05 local workspace | Implemented, partly verified | Folder grants through security-scoped bookmarks, no-symlink bounded reads, discovery in the Core, actionlint as a library in the Core, editor with diagnostics, atomic save with conflict detection, new files and renames (B01 to B04) | Developer ID signed build check; shellcheck and pyflakes integrations are off by design |
| FR-06 local execution | Implemented, partly verified | Bundled act ([ADR 0006](../decisions/0006-bundled-act-for-local-runs.md)), Docker CLI, engine and context detection, job plan with supported and unsupported jobs, fixed act command line, live bounded output, stop and timeout, cleanup; checked end to end on OrbStack with small images (B14 to B16); secrets and variables for local runs: names read from `secrets.X` and `vars.X`, values in Keychain per workspace, a secret shown only after Touch ID or the password, `.env` import, values passed to act through pipes and masked in the output (B28) | Docker Desktop and Colima checks; the full runner images; workflows with services and matrices; signed-build check, including the Keychain behavior of B28; decrypting dotenvx files. Scenario runs (B32) are designed and not built |
| FR-07 feedback and diagnostics | Partial | Fixed public project link in the toolbar and Help; issue template; a bug-report sheet that drafts an issue with app, Core, macOS and architecture only (`BugReport.swift`); no collection of any kind | B18 to B21: the Privacy & Diagnostics settings, reviewed browser hand-off semantics (Draft Opened versus Issue Created), bounded crash import, and a documented analytics destination, schema and retention before any delivery |
| FR-08 lifecycle and workspaces | Implemented, partly verified | AppKit splash, singleton Manager, independent windows with their own state, atomic registry and session snapshot with fsync, transactional relink, quit ordering ([desktop verification](desktop-foundation-verification.md)) | Crash and power-loss injection; signed grants; native failed-write and cancelled-quit interaction; missing monitors; real stale-bookmark recovery (B22 to B24 stay unchecked) |
| FR-09 config, offline storage and sync | Partly implemented | `.runnir/launches` presets (B25); one SQLite database per workspace in the Core with migrations, budgets, backup of local run history and Clear Cache ([ADR 0007](../decisions/0007-workspace-sqlite.md), B26); one runtime and sync loop per workspace with cache-first windows (B27) | B29 (hardening, recovery UI) not started; environments and effective values beyond presets; a check against github.com itself; UI automation of several windows; signed-build check |
| Release (B17) | Not started | `Release Build` workflow creates draft release assets on version tags | Developer ID signing, notarization, an updater, the license decision and the end-to-end acceptance checklist; no distribution claim until then |

No requirement is accepted yet: each still lacks the controlled real-GitHub or signed-build evidence in its last column. Implemented means present in `main` with deterministic tests, not verified in production conditions.

## What Exists

- **App:** Swift 6, SwiftUI and Observation. Features: Authentication, Desktop (Manager, workspace windows, Overview, Workflows editor, Runs, Run inspector, local runs, the menu bar with pull requests and CI state, notifications), Settings (Tools, Storage, Enterprise servers).
- **Core:** pure Go, `CGO_ENABLED=0`, one app-managed child process. Packages: `approval` and `dispatch` (two-step confirmations), `changes` (runs linked to pull requests and commits), `events`, `execution`, `github`, `ipc` (stdio JSON-RPC, version handshake only), `joblog`, `localrun` (act), `repository`, `scanner`, `server` (gRPC), `store` (SQLite), `tools` (Docker and act detection), `validate` (actionlint), `workspace` (shared runtime and sync).
- **Contract:** `runnir.core.v1` over a Unix socket with 44 RPCs ([gRPC API](grpc-api.md), [ADR 0004](../decisions/0004-single-core-process-grpc.md)); protobuf sources in `contracts/`, generated Go and Swift committed and compared in CI.
- **Persistence:** Application Support registry and session; one SQLite database per workspace; credentials only in Keychain.
- **CI:** workflows `CI`, `Go Core`, `App Build` and `Release Build`.
- **Not present:** an MCP server (`mcp/runnir-tools.json` is a design-only catalog), AI features, telemetry, a signed build.

## Open Gaps

| Gap | Affects | Required resolution |
| --- | --- | --- |
| No Developer ID signed, notarized build | FR-01, FR-05, FR-06, B17 | Sign the app and the helper ([ADR 0005](../decisions/0005-developer-id-without-app-sandbox.md)), then repeat the Keychain, folder-grant, process and container checks. No signing, notarization or updater claim before |
| Real-GitHub evidence | FR-02 to FR-04, FR-09 | A controlled fixture repository: dispatch, logs, cancel and re-run, pull-request links, installations on several accounts, sync against github.com |
| Local runs on realistic workflows | FR-06 | Docker Desktop and Colima by hand, full runner images, services and matrices; B32 scenario runs |
| Hardening | FR-08, FR-09 | B29, crash and power-loss injection, multiple monitors, a recovery UI, UI automation across windows |
| Feedback delivery | FR-07 | B18 to B21 with consent and allowlist tests before any transmission |
| License | Public release | `LICENSE` is GPLv3; Apache-2.0 is proposed and needs a separate explicit decision |
| Authentication details | FR-01 | Rate-limit scheduling review; confirm the no-expiry user-token choice against GitHub's current documentation |
| Field research candidates | Not a gate | B33 to B39 ([findings](../research/github-actions-pain-points.md), [pain tracker](../research/pain-tracker.md)) |

## Closed Since The Previous Version

The 2026-10-16 version listed these as gaps. They are resolved in code, except where the signed-build check is noted.

| Earlier gap | Resolution |
| --- | --- |
| Repository capability boundary | Core-enforced scope: chosen folder only, no symlinks or `..` escapes, bounded reads; bookmarks refreshed, Locate and relink (B01, B02). Signed-build check open |
| Validation process boundary | actionlint is built into the Core as a library; no external process (B03) |
| Secure session bridge | Token in Keychain and held in Core memory only; cleared on sign-out (B05, B06) |
| Feature-level GitHub migration | Runs, jobs, logs, dispatch, cancel and re-run, pull requests and repositories are served by the Core; Swift keeps Device Flow and the Keychain |
| Input and YAML metadata | `DescribeWorkflowDispatch` reads the workflow at the chosen ref; the scanner parses without evaluating expressions |
| Persistent non-secret configuration | Presets (device-private and repository), per-workspace SQLite (B25, B26) |
| Long-running process and events | `SubscribeEvents` stream; local run lifecycle with live output, stop and cleanup (B16) |
| Docker access and trust | ADR 0006: fixed act command line, no socket mount, no repository env or secret files, labelled-container cleanup |
| Dispatch and run correlation | Single-use confirmation, no retry, run located by polling, ambiguity shown (B10) |
| Logs resource controls | The last 2 MiB or 50,000 lines read, viewer limited to the last 100 lines, whole log saved to a temporary file (B12) |

## Test Coverage Boundary

Core: unit and gRPC tests in every package except `buildinfo`, `ipc` and the generated code; `go test ./...` passed on 2026-10-25. App: unit tests under `RunnirTests` cover Device Flow and sessions, Keychain, REST decoding, the Core process and client, dispatch forms and presets, the run inspector and run links, local runs, the workspace cache, pull requests, Enterprise servers, workflow editing, the workspace switcher and desktop state; they were not re-run for this update. A UI-test target exists, but an earlier automated run stalled at startup and was not counted; windows are checked by hand.

Not verified: everything in the last column above, hostile filesystem races beyond the descriptor and root-replacement fixtures, power loss, act with the full runner images, and large real logs. Add tests with the feature they protect, and use controlled real integrations before calling authentication, signing, notarization, updates or deployment complete.

## Scope Reconciliation

Preserve [ADR 0002](../decisions/0002-swiftui-go-core.md) and the current Xcode paths. [ADR 0003](../decisions/0003-workspaces-sessions-offline-storage.md) to [ADR 0007](../decisions/0007-workspace-sqlite.md) add workspace and window identity, the single Core process with gRPC, Developer ID distribution without the App Sandbox, bundled act and the workspace database. Product spelling stays Runnir; `.runnir` is exact. Dashboard is a tab inside a workspace. AI and MCP stay deferred to v0.3. FR-06 is implemented with act and Docker, and its acceptance evidence is the open part.

See the [prioritized backlog](../product/mvp-implementation-checklist.md) and the [first slice](../product/first-implementation-slice.md).
