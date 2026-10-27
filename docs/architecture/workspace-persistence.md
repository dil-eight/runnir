# Repository Configuration, SQLite And Synchronization

Status: in part implemented, updated 2026-10-22. Swift persists the local registry and window session together in Application Support/Runnir/desktop-state.json. The Go Core keeps one SQLite database per workspace with its GitHub activity and local run history, and runs one sync per workspace ([ADR 0007](../decisions/0007-workspace-sqlite.md), [implemented behavior](#implemented-2026-10-22)). The Core reads Run Workflow presets from `.runnir/launches` (B25, [design](../superpowers/specs/2026-10-23-repository-presets-design.md)); there is no local file index or environment subsystem. See [ADR 0003](../decisions/0003-workspaces-sessions-offline-storage.md).

## Storage Ownership

```text
<repo>/.github/workflows/*.yml|*.yaml   # user-authored local workflow source
<repo>/.runnir/launches/*.yaml          # optional portable Run Workflow presets (implemented, read-only)

<ApplicationSupport>/Runnir/settings.json
<ApplicationSupport>/Runnir/session.json
<ApplicationSupport>/Runnir/repositories.json
<ApplicationSupport>/Runnir/repositories/<workspaceId>/state.sqlite     # implemented
<ApplicationSupport>/Runnir/repositories/<workspaceId>/lock             # implemented: one writing process
<ApplicationSupport>/Runnir/repositories/<workspaceId>/blobs/           # implemented: kept job logs
<ApplicationSupport>/Runnir/repositories/<workspaceId>/backups/         # implemented: local data, pre-migration copies
<ApplicationSupport>/Runnir/repositories/<workspaceId>/recovery/        # implemented: damaged files kept as evidence
<ApplicationSupport>/Runnir/repositories/<workspaceId>/snapshots/       # planned
<ApplicationSupport>/Runnir/repositories/<workspaceId>/runtime/         # planned
```

ApplicationSupport is resolved by native platform APIs, not a hardcoded home path. Persistent DB/registry/session never live in the repo, /tmp or disposable Caches. Disposable derived data may use Caches separately. No .runnir file is generated just by opening a repository. Users decide whether portable files are Git-tracked; no auto commit/push/clone.

| Data | Authority / location |
| --- | --- |
| Workflow/local config/portable launches | Working tree; optional Git tracking |
| Registry, known paths/bookmark grants | Device-private Application Support; native grant ownership |
| Window navigation/geometry/restore set | Global SessionStore; no process liveness |
| GitHub workflows/runs/jobs/steps cache | GitHub authoritative; workspace SQLite with origin/freshness |
| Local file index | Derived from local working tree; workspace SQLite |
| Machine overrides/selections/user-authored local values | Workspace DB/local state with backup/recovery, never disposable by Clear Cache |
| Large logs/artifacts/snapshots | Bounded workspace files plus DB relative-path/checksum/retention records |
| OAuth/private credentials/secret values | Keychain only; opaque references elsewhere |

Local cache may include private repository metadata needed for functionality. It never becomes analytics/crash-report content. Inspect redaction and encryption/access requirements before retaining log bodies; default avoid secret-bearing log persistence. Retention/backup rules must account for user-authored values distinct from disposable remote cache.

## Registry Identity

Allocate workspaceId once on registration. Track path/display name/optional sanitized remote metadata/lastOpenedAt; never persist embedded URL credentials. Two separate clones or registered working-tree instances get separate IDs, even for one remote. Canonical paths/resource identity avoid accidentally registering one directory twice, with case/symlink semantics tested. Remote URL changes do not reset identity.

Missing/moved roots retain records/cache and offer user-assisted relinking; preserve workspaceId and explicit folder authorization. Do not silently grant a new path, delete state or merge clones by remote URL. No GitHub remote or .runnir directory is required for local use. Registry removal never silently deletes the working tree or portable files. Account-wide remote browsing is not local workspace registration: it is the Workspace Manager's GitHub tab. A workspace record remembers the `owner/name` its origin pointed at when the Core last opened it, only so that tab can open the registered clone.

## Registry Example And .runnir

Proposed global repositories.json entry (device-private, not portable config):

```json
{
  "version": 1,
  "repositories": [{
    "workspaceId": "ws-a7d1",
    "path": "/Users/example/dev/project",
    "displayName": "project",
    "remoteUrl": "https://github.com/example/project.git",
    "lastOpenedAt": "2026-10-14T17:00:00Z"
  }]
}
```

Folder grant/bookmark encoding is a native storage design decision, not an invented portable URI. Paths/remotes and these IDs never enter analytics or public crash reports.

`.runnir` holds only `launches/*.yaml`: Run Workflow presets a team shares through Git. Runnir reads them and never creates, changes or deletes them; the format, limits and error handling are in the [B25 design](../superpowers/specs/2026-10-23-repository-presets-design.md). `config.yaml` and `environments.yaml` from the earlier plan are not introduced: nothing would use them.

```yaml
# .runnir/launches/deploy-staging.yaml
name: Deploy to staging
workflow: deploy.yml
ref: main
inputs:
  environment: staging
```

Secrets never go into `.runnir`. Local runs (B28, [design](../superpowers/specs/2026-10-25-local-run-secrets-design.md)) get the `secrets.X` and `vars.X` the workflow itself names. The Core finds the names in the repository scan and the run's plan; the app keeps values per workspace in Keychain (service `dev.runnir.local-run.<workspace>`, account `secret:NAME` or `variable:NAME`), shows a saved secret only after Touch ID or the password, fills values from a `.env` file the user picks (the Core reads it; dotenvx-encrypted values are flagged, not decrypted), and takes a value typed for one run in the Run Locally review. Values travel to the Core only when a run is confirmed and reach act through two pipes, linked as `secrets.yaml` and `vars.yaml` in the run's scratch folder; never through a file on disk, act's command line or environment, the workspace database or logs. Secret values are masked in the run's output. Removing a workspace registration forgets its values; Clear Cache keeps them. GitHub Actions secrets stay on GitHub.

A malformed or unusable preset file is listed with its problem and never used; the workspace opens normally. Opening never writes to the working tree. Local-only presets stay machine-private in `dispatch-presets.json`.

## Implemented (2026-10-23): repository presets

- The Core's repository scan reads `.runnir/launches` after `.github/workflows`: regular `.yml`/`.yaml` files directly in the folder, at most 100 of at most 64 KiB, never through a symlinked folder or file. Each file is checked (`name`, `workflow` naming a file the same scan found, optional `ref` and scalar `inputs`; any other key refuses the file) and kept in the repository snapshot; a problem becomes an entry with its reason and never fails the scan. `ListLaunchPresets` returns them.
- The app reads them with the repository's workflows (open, Refresh, `REPOSITORY_REFRESHED`). Overview › Run manually lists them under "In this repository" above the presets on this Mac, with unusable files shown; the Run Workflow menu offers both. A repository preset is applied like a Mac preset, leaves out values of inputs that look secret, and can be copied to this Mac but not changed in Runnir.

Live check on 2026-10-23 in the Debug test copy (`com.dileight.runnir.alertcheck`, `--ui-testing`, its own state folder) on a scratch working tree with an origin on GitHub, signed out: Overview › Run manually showed "In this repository · .runnir/launches" with two usable presets (a secret-looking input shown as `•••`), warning rows for a file with invalid YAML (with its line) and one naming a missing workflow, then "On this Mac" and the footnote; a preset file added on disk appeared after Refresh, in name order; nothing under `.runnir` was written. Not checked live: the Run Workflow preset menu and applying a repository preset, which need a signed-in GitHub account (covered by unit tests), and a signed build.

## Implemented (2026-10-23): runs linked to pull requests and commits

The links, superseded runs, 5000-run budget and older pages are described in the [B30 spec](../superpowers/specs/2026-10-23-run-change-links-design.md); the budgets below include them.

Live check on 2026-10-23 in the Debug test copy (`com.dileight.runnir.alertcheck`, `--ui-testing`, its own state folder), signed out, with a seeded cache (nine runs of three workflows, a merged pull request and a draft one) and a scratch working tree whose `ci.yml` had no `concurrency`: Overview and Runs showed what each run belongs to ("CI #881 · #142 after merge · main · push"), "2 superseded runs hidden · Show" and the still-running superseded run as "outdated"; By change grouped the runs under #145 and #142 with their sections, folded earlier runs and the suggestion; the inspector of a superseded run showed its pull request, commit and the newer run. "Add concurrency…" on the first visit to the Workspace opened `ci.yml` with the block before `jobs:` as one unsaved edit; Undo removed it, it did not come back on the next visit, and the file on disk was unchanged. Not checked live: the GitHub reads (pull requests, lookups, older pages), which need a signed-in account and are covered by Core tests against a fake server, and a signed build.

## Implemented (2026-10-22)

What exists in the Core and the app; the design sections below remain the target for the rest.

- Location: the app starts the Core with `--data-dir` (its support folder, or the UI-test state folder for `--ui-testing`). Without it, every workspace database is in memory and nothing is written. `OpenRepository` takes the registry's `workspace_id`, so the database follows the workspace across a relink.
- Driver and ownership: modernc.org/sqlite v1.60.1 with `CGO_ENABLED=0`; one connection per database, so the Core is the single serialized writer; a `flock` keeps another process (another copy of Runnir) out, which then runs that workspace in memory and says so. WAL with `synchronous=FULL`; `wal_checkpoint(TRUNCATE)` when the last window closes.
- Schema v1: `cache_source` (with the default branch and whether the history is complete), `sync_state`, `remote_workflows`, `runs`, `run_pull_requests`, `pull_requests`, `link_lookups`, `run_jobs`, `run_steps`, `blobs` (cache: downloadable again), `local_runs` (only on this Mac: one summary per local act run, no output) `savings` (only on this Mac: one running total per kind of saving, which outlives the local run budget) and `run_index` (only on this Mac: what is known of the runs of each repository, filled by everything the Core reads and kept after the cache drops a run or GitHub deletes it; Clear Cache keeps it, the backup of local data does not include it). Migrations use `user_version`; a `VACUUM INTO` copy precedes each one; a failed one rolls back and the workspace runs in memory; a newer schema is left untouched.
- Budgets per workspace: 5000 runs (jobs, steps and pull request links go with them; the cache is one unbroken stretch of history that scrolling extends with older pages), pull requests a run or lookup names plus the 500 most recently updated, 200 local run records, 200 dispatch history entries (like local run records they exist only on this Mac, are backed up with them and survive Clear Cache), 50,000 runs per repository in the search index (the newest stay), 100 MiB of kept logs (least recently used first), at most 3 MiB per log.
- Recovery: `local_runs` and `savings` are copied to `backups/local-data.sqlite` after every change (temporary file, fsync, rename, folder fsync). A damaged database (SQLite corrupt or not-a-database, or a failed `quick_check`) moves to `recovery/<time>/` and is never deleted by the Core; local runs and savings are restored from it and from the backup (of two totals of a kind, the one with the higher count). A missing or empty database file is rebuilt from the backup, so a backup is never replaced by an empty copy. Runs recorded as queued or running when a database opens become `interrupted`.
- Sync: one loop per workspace id, however many windows show it. A pass reads the newest 50 runs and the workflows with `If-None-Match`; a 304 is "checked, no changes". Runs missing from the page but newer than its oldest run were deleted on GitHub and leave the cache. A change of origin never shows the previous repository's data. Schedule: 20 s while a run is queued or in progress, 5 min otherwise; 30 s, 1, 2, 5 min backoff when GitHub is unreachable; `retry_after` (30 s to 1 h) when rate limited; no timer after signed out, token rejected, not visible or permission missing, until the token changes or the user refreshes. Cached data stays and is shown when access is lost.
- Jobs and logs: a finished run's jobs read after its last update are served from the cache without a request; concurrent reads of one run, and of one job log, share one request. Job logs are kept only when Settings › Storage › "Keep job logs on this Mac" is on (off by default); turning it off deletes them.
- Freshness: `GetWorkspaceActivity` never waits for GitHub and reports the source (none, saved on this Mac, confirmed in this session), whether a pass is running, the last outcome (only once a pass ran in this Core process, so a saved rejection or outage from an earlier session never looks current), and the last check, success and change times. The app signs out after a rejection only when it was checked after the token now held was handed to the Core. The app shows it as one line ("Showing saved activity · synced 2 hours ago", "Up to date · checked 1 minute ago") and refreshes on `ACTIVITY_CHANGED`.
- Clear Cache: Settings › Storage (per workspace, all, and data of removed workspaces). The Storage list reads closed workspaces' databases read-only, without locking, migrating or repairing them. Turning "Keep job logs" off stays pending until a Core confirms deleting the kept logs, so a Core that was away deletes them at its next start. Removing a registration waits for the Core to close the workspace before deleting its folder. It deletes the cache tables and kept logs only; local run history and savings stay. Removing a registration in the Manager deletes the workspace's folder.

Live check on 2026-10-22 in the Debug test copy (`com.dileight.runnir.alertcheck`, `--ui-testing`, its own state folder): saved runs showed at once with "Showing saved activity · synced 2 hours ago" while signed out; Settings › Storage listed the workspace and Clear Cache emptied it; two windows on one workspace showed the same saved activity with one open repository in the Core and the database open only in the Core; against a local fake Enterprise server the sync read once per pass whatever the window count (three passes a minute with an active run and two windows, all answered 304 after the first), a finished run showed in both windows on the next pass, and the line read "Up to date · checked just now".

Not verified: a Developer ID signed build with the database; real power loss or a crash during a write (tests cover damaged and missing files and the write order); the sync against github.com itself (the live check used a fake Enterprise server).

## SQLite Design

One logical workspace database service/single serialized writer, shared by all windows through Core. Driver selection remains open; prefer pure Go/CGO disabled and review license/maintenance before adoption. Typed models, foreign keys, migrations and indexed queries; transactions reconcile related snapshots atomically. Choose WAL/process ownership and shutdown/checkpoint strategy explicitly; no assumption of uncoordinated safe writers.

Conceptual tables: metadata; repository_state; workflows (identity/path/hash/origin); workflow_runs; run_jobs; run_steps; sync_state (scope/cursor/ETag/checkedAt/syncedAt/error); local_file_index; environments (non-secret overrides); runtime_records (historical state); blobs (relative path/size/checksum/retention). These are not final SQL schemas.

Large data goes in files, never giant DB row payloads. Validate blob paths/archive entries/symlinks, impose size/count/retention budgets and use a scoped root. Missing DB can be initialized/reindexed, but avoid losing unique overrides if an unexpected missing file indicates data loss. Corruption/migration failure must preserve backup/recovery evidence and user-authored local values before rebuilding disposable cache; never delete the entire workspace directory as a repair shortcut.

Clear Cache removes only classified disposable remote/index/blob data. It preserves .runnir, registry, window session, Keychain and user-authored overrides/presets. Removing workspace registration/data is a separate explicit operation. Define default run-history/log/artifact budgets before shipping.

## Cache-First Open And Shared Sync

Resolve ID/folder grant -> safely load optional config -> open/migrate local DB off main thread -> render cached/local summary -> local reindex + authorized GitHub sync -> incremental shared updates. DB missing/slow shows partial local UI; remote access never blocks window readiness. Distinguish initial loading, cached, refreshing, offline, error, up-to-date and checked-but-unchanged with last attempted/successful sync times.

One SyncCoordinator per workspaceId deduplicates requests across windows. Watch workflow/config changes with debounce + fallback rescan; index/hash without execution. Use conditional requests, pagination/watermarks only where supported; reconcile status changes/deletions rather than append-only history. Apply bounded backoff/cancellation on offline/auth/rate-limit/permission failures. Native watcher/grant bridge stays Swift-owned; portable policy/query/sync remains Go-owned. Suspend idle sync by explicit lifecycle policy; no work while app terminated.

Local files are authoritative for their local index; GitHub is authoritative for remote definitions and run status. Store/show distinct origin/source hash/ref/freshness. Never overwrite a dirty editor from sync, or label local uncommitted YAML as the remote dispatch source. Remote launch requires current authorization/availability and published definitions. Cached remote data is readable offline but cannot authorize dispatch; local execution needs its own runtime and consent.

## Acceptance And Test Matrix

| ID | Required evidence |
| --- | --- |
| W01 | Repo without remote/.runnir opens; no silent writes; clones/relinks/canonical identity behave correctly |
| W02 | Safe optional YAML parse of `.runnir/launches`, limits/traversal/symlink denial and degraded opening |
| W03 | Values for a run come from the review, then Keychain; only names the plan reads are accepted (B28) |
| W04 | Secret names per workspace, missing or refused by Keychain; no values on disk, in the database, act's argv or environment, logs or diagnostics (B28) |
| W05 | SQLite migrations/transaction/concurrent-window reads and single-writer integrity; missing/corrupt DB repair preserves unique local data |
| W06 | Offline relaunch renders cache before network; shared windows issue one logical sync; checked/failed/succeeded times remain separate |
| W07 | Local changes, remote YAML and live run updates are distinguishable; auth/rate-limit/backoff/cancel handled |
| W08 | Clear Cache/retention/path extraction limits do not delete config/overrides/grants/credentials; blob traversal denied |
| W09 | Interrupted execution history is unknown/interrupted, never automatically resumed/successful |

State on 2026-10-22: W05 is covered by Core tests (migrations, single writer, damaged and missing databases keeping local runs) but not by a signed build or crash injection; W06 by Core gRPC tests (two opens of one workspace make one sync; activity survives a Core restart with GitHub unreachable; check, success and change times apart) and app unit tests, not by a live two-window run against GitHub; W08 by tests of Clear Cache keeping local runs and of blob path, symlink and size checks; W09 in part: local run records left queued or running become interrupted when the database opens, and nothing is resumed. W01, W03, W04 and W07 are unchanged. W02 is covered by Core tests of `.runnir/launches` (2026-10-23).

Unit tests cover schemas/precedence/IDs/migrations/sync reconciliation/redaction. Real integration tests cover signed scope grants, concurrent windows, file changes, offline networks, partial writes and corruption recovery. Configuration parsing alone is not a completed local executor.
