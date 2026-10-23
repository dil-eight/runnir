# Workspace Cache, Shared Runtime And Sync (B26, B27)

Status: design approved and implemented on 2026-10-22 ([plan](../plans/2026-10-22-workspace-cache.md)). Changes made while planning: `RepositoryResponse` has no storage field (Settings › Storage reads `GetStorageUsage`); `SetStoragePreferences` also takes `delete_kept_logs`, set only when the user turns keeping logs off; a blob is named by the SHA-256 of its job id and content. Backlog: B26 / F3 and B27 / F3–F4 in the [MVP checklist](../../product/mvp-implementation-checklist.md). Context: [ADR 0003](../../decisions/0003-workspaces-sessions-offline-storage.md), [workspace persistence](../../architecture/workspace-persistence.md), [desktop lifecycle](../../architecture/desktop-lifecycle.md), [gRPC API](../../architecture/grpc-api.md).

## Goal

A workspace window shows its GitHub Actions activity (runs, workflows, jobs) from a per-workspace SQLite database in the Go Core at once, then refreshes it. One Core runtime and one sync loop serve each workspace however many windows show it, so there is one writer and no duplicate GitHub request. Data that exists only on this Mac survives corruption and migration failures. Clear Cache removes only what can be downloaded again.

## Decisions Made

| Question | Decision |
| --- | --- |
| Who schedules sync | The Go Core: one `SyncCoordinator` per workspace id. The Swift `githubPoll` timers go away; Swift reads snapshots and asks for refreshes |
| SQLite driver | `modernc.org/sqlite` v1.60.1 (2026-09-29) through `database/sql`, `CGO_ENABLED=0`. Recorded in ADR 0007 |
| Local-only data in this slice | History of local act runs (a summary per run, no output). Presets and favorites stay in Swift JSON files |
| Job logs | Blob store with metadata. Logs of completed jobs are kept only when Settings › Storage › "Keep job logs on this Mac" is on (default off); turning it off deletes kept logs |
| Clear Cache | Settings › Storage (per workspace, all, removed workspaces) and "Clear Cache…" in the workspace window; always confirmed |
| Budgets per workspace | 200 runs with their jobs and steps; 200 local run records; 100 MiB of logs. Oldest go first |
| Access lost (signed out, token rejected, not visible, permission missing) | Cached data stays and is shown with the access notice; it is no longer cleared. Sync stops until the credential changes or the user refreshes |
| Out of scope | The Manager's GitHub tab (repositories without a clone) and the menu bar pull requests stay live reads without a cache: they are not workspaces |

## Driver Choice (summary of ADR 0007)

- `modernc.org/sqlite`: SQLite's C source translated to Go; BSD-3-Clause for the Go code, public domain for SQLite. Works with `CGO_ENABLED=0` on darwin/arm64 and darwin/amd64. Plain Go code, so the signed Core needs no executable-memory entitlement under the hardened runtime ([ADR 0005](../../decisions/0005-developer-id-without-app-sandbox.md)). Widely used and maintained. Cost: a larger Core binary (measured and recorded in the ADR).
- `github.com/ncruces/go-sqlite3` (MIT) was rejected: it runs SQLite as Wasm in wazero, whose fast compiler mode writes executable memory and would need `com.apple.security.cs.allow-jit`; the interpreter avoids that but is much slower.
- v1.60.1 rather than v1.61.0, which was one day old when chosen. New transitive modules and their licenses are listed in the ADR.

## Storage Layout

The app starts the Core with `--data-dir <RunnirSupportDirectory>` (`~/Library/Application Support/Runnir`, or `RUNNIR_UI_TEST_STATE_DIRECTORY` for `--ui-testing` runs). Without the flag (CLI, Go tests) nothing is written to disk: every workspace runs on an in-memory database.

```text
<data-dir>/repositories/<workspaceId>/state.sqlite   (+ -wal, -shm)
<data-dir>/repositories/<workspaceId>/lock           flock: one writing process
<data-dir>/repositories/<workspaceId>/blobs/         kept job logs, named by SHA-256
<data-dir>/repositories/<workspaceId>/backups/       before-v<N>.sqlite, local-data.sqlite
<data-dir>/repositories/<workspaceId>/recovery/<UTC timestamp>/   damaged files, kept as evidence
```

`workspaceId` is the registry's UUID, lowercased; the Core accepts only the 8-4-4-4-12 hex form. Directories and files are created 0700 and 0600. The Core never follows a symlink in this tree.

## Identity

`OpenRepositoryRequest` gains `workspace_id`. The Core keeps repository contexts per resolved path (unchanged) and binds each context to one workspace id; opening an already open path with a different workspace id is `FAILED_PRECONDITION`. A relink closes the old path and opens the new one with the same workspace id, so the database follows the workspace, not the path. An open without `workspace_id` gets no runtime and no activity (older clients only).

## Package `internal/store`

One `Store` per workspace database.

- `database/sql` with `MaxOpenConns(1)` and a connection that is never recycled: every read and write in the process goes through one serialized connection. Pragmas: `journal_mode=WAL`, `synchronous=FULL`, `foreign_keys=ON`, `busy_timeout=5000`.
- An exclusive non-blocking `flock` on `lock` is held while the store is open. Another process holding it (a second copy of Runnir with its own Core) makes this one fall back to an in-memory database, reported as "In use by another copy of Runnir".
- Migrations are ordered SQL embedded in the binary; `PRAGMA user_version` is the schema version; each migration runs in one transaction.
- Close runs `PRAGMA wal_checkpoint(TRUNCATE)`, closes the database and releases the lock.

Tables. "Cache" tables can be downloaded again; "local" tables exist only on this Mac.

| Table | Class | Contents |
| --- | --- | --- |
| `cache_source` | cache | One row: GitHub server id and `owner/name` the cached data belongs to |
| `sync_state` | cache | Per scope (`runs`, `workflows`): ETag, `checked_at`, `synced_at`, `changed_at`, last access result, `retry_after` |
| `remote_workflows` | cache | id, name, path, state, link |
| `runs` | cache | The `WorkflowRun` fields; indexed by `created_at DESC` and `workflow_id` |
| `run_jobs` | cache | Jobs of a run's latest attempt: run id (foreign key, cascade), attempt, job fields, `fetched_at`; indexed by run id |
| `run_steps` | cache | Steps of a job (foreign key, cascade) |
| `blobs` | cache | Kept logs: job id, relative path, size, SHA-256, truncation flags, `created_at`, `last_used_at` |
| `local_runs` | local | execution id, workflow path, job id (empty for every job), event, `started_at`, `finished_at`, state (`queued`, `running`, `succeeded`, `failed`, `cancelled`, `interrupted`), failure message, act version, engine name |

Budgets are enforced after every write: runs beyond the newest 200 are deleted (jobs and steps cascade); `local_runs` beyond the newest 200 are deleted; logs beyond 100 MiB are deleted by oldest `last_used_at`.

### Blobs

A blob file is named `<sha256>.log` directly in `blobs/`; no part of the name comes from GitHub or the user. Writing goes to a temporary file in `blobs/`, fsync, rename, then the row. Reading checks with `Lstat` that the file is a regular file inside `blobs/`, matches its recorded size, and refuses anything else (the row is then dropped). One blob is at most 3 MiB (the Core reads at most a 2 MiB log tail). Rows without files and files without rows are removed when the store opens.

### Clear Cache

One transaction deletes every cache table's rows and `sync_state`, then the blob files are removed. `local_runs`, `backups/` and `recovery/` are untouched. An open workspace then syncs again at once.

### Backup And Recovery

- Before a migration: `VACUUM INTO backups/before-v<N>.sqlite` (the version it migrates from); the newest three are kept.
- After every change to `local_runs` and on close: the local tables are copied with `ATTACH` into `backups/local-data.sqlite.tmp`, which is fsynced and renamed over `backups/local-data.sqlite`, then the directory is fsynced. Local runs are rare, so this is cheap.
- On open, after `PRAGMA quick_check`:
  - Damaged (SQLite `CORRUPT` or `NOTADB` on open, read or check): `state.sqlite`, `-wal` and `-shm` move to `recovery/<timestamp>/`, never deleted by the Core. A new database is created. `local_runs` rows are read from the damaged copy opened read-only where possible, and the rest from `backups/local-data.sqlite`. The report says what was restored.
  - Missing while `backups/local-data.sqlite` exists: a new database is created and local runs are restored from the backup; the report says so.
  - Schema newer than this Core knows: the file is not touched; the workspace runs on an in-memory database with the note "Made by a newer version of Runnir".
  - Failed migration: the transaction rolls back, the file stays as it was (with its pre-migration copy), and the workspace runs in memory with the error as the note.
  - Other errors (permission, I/O, lock): no file is moved; the workspace runs in memory with the reason.
- `local_runs` still `queued` or `running` when a store opens become `interrupted`, with `finished_at` unset. Nothing is resumed.

## Package `internal/workspace`

`Runtimes` maps workspace id to `Runtime` and repository id to workspace id. A `Runtime` owns the `Store`, the `SyncCoordinator`, the jobs and log readers, and local run history.

- Created by the first `OpenRepository` with that workspace id; closed when the repository context closes (last window, or `CloseRepository`), which stops the loop, waits for a running sync to end, and closes the store.
- `CloseRepository`, Core shutdown and `RepositoryClosed` events all go through the same close.
- Runtimes of other workspaces never block each other; each has its own lock and goroutine.

### Sync

One goroutine per runtime. A pass:

1. Resolves the GitHub target from the repository's current origin (as `githubTarget` does). No origin on a known server: status `NO_REMOTE`, no request.
2. If the target differs from `cache_source`, the cache tables are cleared in the same transaction that stores the first successful result for the new target. Until then `GetWorkspaceActivity` returns no runs or workflows, so data of another repository is never shown.
3. `GET /repos/{owner}/{name}/actions/runs?per_page=50` with `If-None-Match`, then `GET /actions/workflows`: conditional while the repository has at most 100 workflows; with more, all pages (up to 300, as today) are read each pass.
4. Writes runs, workflows and `sync_state` in one transaction. A run in the cache that is newer than the oldest run of the page but missing from the page was deleted on GitHub and is removed. Older cached runs stay until the 200 budget removes them.
5. Publishes `CORE_EVENT_TYPE_ACTIVITY_CHANGED` for the repository when data or freshness changed. A pass also publishes it when it starts (so windows can show "Refreshing").

Triggers: the runtime opening; a timer (20 seconds while any of the newest 50 cached runs is queued, in progress, waiting, requested or pending; otherwise 5 minutes); `RefreshWorkspaceActivity`; `SetGitHubCredential` or `ClearGitHubCredential` for the server of the runtime's target (also resets backoff). Requests during a pass are merged into exactly one more pass; `wait=true` returns after the pass that started after the request.

Outcomes:

| Result | Data | Next pass |
| --- | --- | --- |
| 200 | Stored; `synced_at` and `changed_at` (only if rows changed) set | Timer |
| 304 | Unchanged; `synced_at` set: "checked, no changes" | Timer |
| `UNAVAILABLE` | Kept | Backoff 30 s, 1, 2, then 5 min |
| `RATE_LIMITED` | Kept | At `retry_after`, at least 30 s and at most 1 h |
| `SIGNED_OUT`, `TOKEN_REJECTED`, `NOT_VISIBLE`, `PERMISSION_MISSING` | Kept, shown with the notice | None until a credential change or a refresh |

`TOKEN_REJECTED` still makes the Core forget the token, as today.

### Jobs

`ListRunJobs` with `repository_id` goes through the runtime:

- Served from the cache without a request when the cached run is completed and its jobs were fetched for the same attempt after the run's last `updated_at`, or when the jobs were fetched less than 10 seconds ago (two windows opening the same run).
- Otherwise one request per run at a time: concurrent calls for the same run share it. The result is stored when the run is in the cache, and returned.
- With `github_repository` (no clone) nothing changes.

### Job Logs

`GetJobLog` with `repository_id`: a kept log of a completed job is parsed from its blob without any request (steps come from the cached jobs, or one job request when they are not cached). Otherwise the log is downloaded as today; concurrent calls for the same job share one download; with "Keep job logs" on and the log `AVAILABLE`, its tail and truncation flags are stored as a blob.

### Local Run History

`ConfirmLocalRun` records the run (`queued`) once the execution is accepted. Execution events update the state, `finished_at` and failure message. Each change writes the local backup.

## gRPC Contract (additive, `runnir.core.v1`)

```proto
rpc GetWorkspaceActivity(GetWorkspaceActivityRequest) returns (WorkspaceActivity);
rpc RefreshWorkspaceActivity(RefreshWorkspaceActivityRequest) returns (WorkspaceActivity);
rpc GetStorageUsage(GetStorageUsageRequest) returns (GetStorageUsageResponse);
rpc ClearWorkspaceCache(ClearWorkspaceCacheRequest) returns (ClearWorkspaceCacheResponse);
rpc DeleteWorkspaceData(DeleteWorkspaceDataRequest) returns (DeleteWorkspaceDataResponse);
rpc SetStoragePreferences(SetStoragePreferencesRequest) returns (SetStoragePreferencesResponse);

message OpenRepositoryRequest { string path = 1; string workspace_id = 2; }
message RepositoryResponse { Repository repository = 1; WorkspaceStorage storage = 2; }

message GetWorkspaceActivityRequest { string repository_id = 1; uint32 limit = 2; }  // 0 → 50, at most 200
message RefreshWorkspaceActivityRequest { string repository_id = 1; bool wait = 2; uint32 limit = 3; }
message WorkspaceActivity {
  repeated WorkflowRun runs = 1;          // newest first
  repeated GitHubWorkflow workflows = 2;
  ActivityFreshness freshness = 3;
}
enum ActivitySource {
  ACTIVITY_SOURCE_UNSPECIFIED = 0;
  ACTIVITY_SOURCE_NONE = 1;   // nothing cached for the current origin
  ACTIVITY_SOURCE_CACHE = 2;  // read from disk; no successful pass in this Core process yet
  ACTIVITY_SOURCE_LIVE = 3;   // confirmed by a pass in this Core process
}
message ActivityFreshness {
  ActivitySource source = 1;
  bool syncing = 2;
  GitHubStatus status = 3;                     // of the last pass; unset before the first
  google.protobuf.Timestamp checked_at = 4;    // last pass ended
  google.protobuf.Timestamp synced_at = 5;     // last 200 or 304
  google.protobuf.Timestamp changed_at = 6;    // data last changed
}

enum StorageState {
  STORAGE_STATE_UNSPECIFIED = 0;
  STORAGE_STATE_PERSISTENT = 1;
  STORAGE_STATE_MEMORY_ONLY = 2;   // note says why
  STORAGE_STATE_ABSENT = 3;        // nothing on disk
}
message WorkspaceStorage {
  string workspace_id = 1;
  StorageState state = 2;
  string note = 3;              // memory-only reason or what recovery did; never a credential
  bool open = 4;
  uint64 database_bytes = 5;    // state.sqlite plus WAL
  uint64 log_bytes = 6;
  uint32 cached_runs = 7;
  uint32 local_runs = 8;
  uint32 recovery_copies = 9;
}
message GetStorageUsageRequest { repeated string workspace_ids = 1; }      // empty: every workspace on disk
message GetStorageUsageResponse { repeated WorkspaceStorage workspaces = 1; bool keep_job_logs = 2; }
message ClearWorkspaceCacheRequest { repeated string workspace_ids = 1; }  // empty: every workspace on disk
message ClearWorkspaceCacheResponse { repeated WorkspaceStorage workspaces = 1; }
message DeleteWorkspaceDataRequest { string workspace_id = 1; }
message DeleteWorkspaceDataResponse {}
message SetStoragePreferencesRequest { bool keep_job_logs = 1; }
message SetStoragePreferencesResponse {}

// CoreEventType
CORE_EVENT_TYPE_ACTIVITY_CHANGED = 10;
```

Errors: unknown repository `NOT_FOUND`; activity of a repository opened without `workspace_id` `FAILED_PRECONDITION`; malformed workspace id `INVALID_ARGUMENT`; `DeleteWorkspaceData` of an open workspace `FAILED_PRECONDITION`; limit over 200 `INVALID_ARGUMENT`. `ListWorkflowRuns` and `ListGitHubWorkflows` keep their live behavior. `protocol_version` stays 1. `SetStoragePreferences` with `keep_job_logs=false` deletes kept logs of every workspace on disk. The Core starts with `keep_job_logs=false` until the app says otherwise.

## App (Swift)

- `ProcessCoreLauncher` passes `--data-dir` with `RunnirSupportDirectory.url()`.
- `CoreServicing` gains the new calls; `openRepository(path:workspaceID:)`.
- `CoreHub`:
  - Opening: `openRepository`, `listWorkflows`, then `getWorkspaceActivity` and apply; nothing waits for GitHub.
  - `ACTIVITY_CHANGED` for a session's Core id re-reads its activity; one read per session at a time, later ones merged.
  - `loadGitHubActivity(workspaceID:)` becomes `refreshWorkspaceActivity(wait: true)` and apply, so Reload, run lookup after a dispatch and following a cancel or re-run keep working.
  - `githubAccess`, `isLoadingGitHub` and `githubLoadedAt` come from the freshness (`status.access`, `syncing`, `synced_at`); new `activitySource`, `checkedAt`, `changedAt`. Access problems no longer clear `runs` or `remoteWorkflows`.
  - The `githubPoll` timers, `githubPollInterval` and `githubIdlePollInterval` are removed. A credential push no longer triggers a load: the Core syncs.
  - New: `storageUsage(ids:)`, `clearCache(ids:)`, `deleteWorkspaceData(id:)`, `setKeepJobLogs(_:)`, sent at Core start and on change.
- Freshness line in Overview and the Activity section, from one tested function: "Loading activity…" (none, syncing), "Showing saved activity · synced 2 hours ago" (cache), "Refreshing…", "Up to date · checked 1 minute ago", "No changes · checked just now" (304 most recently). The existing stale-data banner adds "Showing activity from <synced_at>" when the last status is not OK.
- Settings › Storage, a new tab: the "Keep job logs on this Mac" toggle (UserDefaults, default off; turning it off says it deletes kept logs), each registered workspace with saved runs, log size, database size, local run records and any note, a "Clear Cache…" button per workspace and "Clear All Caches…". Data on disk for a workspace that is no longer registered appears as "Removed workspace" with "Delete…". Every destructive action has a confirmation that says what stays.
- Workspace window: no Clear Cache action; it lives in Settings › Storage only (changed after review on 2026-10-22).
- Workspace Manager › Remove Registration: after the registry commit, `deleteWorkspaceData`. When it fails (Core not ready), the data stays and shows in Storage as "Removed workspace".

## Error Handling Summary

- Remote access never blocks a window: cached or empty activity is shown immediately; the freshness line says what is known.
- Storage problems never block a window either: the workspace runs in memory and Storage shows the note.
- Recovery never deletes evidence or local data; Clear Cache never touches local data; only Delete (explicit, removed workspaces) and Remove Registration remove a workspace's directory.

## Tests

Go (deterministic: `t.TempDir()` as data dir, `httptest` GitHub, injected clock):

- store: create and reopen; migration from every older version; newer schema left untouched and memory-only; corrupt file moved to `recovery/` with local runs restored from the damaged copy and from the backup; missing database restored from the backup; failed migration rolled back; Clear Cache keeps `local_runs` and backups; budgets (200 runs with cascade, 200 local runs, 100 MiB logs by `last_used_at`); blob traversal, symlink, size mismatch and orphan cleanup; a second opener gets the lock error; `interrupted` marking; backup file written atomically.
- workspace/sync: concurrent refreshes make one HTTP request; `wait` semantics; 304 sets `synced_at` but not `changed_at`; deletion reconciliation; origin change never shows the other repository's runs; backoff schedule and `retry_after`; access loss keeps data and stops the timer; credential change starts a pass; close stops the loop; active versus idle interval; jobs served from cache without a request, shared in-flight request, 10-second reuse; logs from blobs, not stored with the setting off, deleted when turned off.
- server (gRPC over a socket): two opens of one workspace share one runtime and one sync; activity survives a Core restart with GitHub unreachable; Clear Cache and Delete, including Delete refused while open; no files without `--data-dir`; `workspace_id` validation and mismatch.
- `go test ./...`, `go vet ./...`, `go build ./...` with `CGO_ENABLED=0`.

Swift (RunnirTests with the fake `CoreServicing`): cached activity applied before a refresh finishes; `ACTIVITY_CHANGED` re-reads only its session; two windows share one session and one read; freshness text mapping; access problems keep runs; Storage actions call the Core with the right ids; Remove Registration deletes data; launcher arguments include `--data-dir`. The app builds with `xcodebuild`.

## Documentation

- ADR 0007: driver choice, licenses, transitive modules, binary size before and after, single writer, WAL and checkpoint.
- ADR 0003: mark the driver, single-writer and budget questions settled; the rest stay open.
- `workspace-persistence.md`, `grpc-api.md`, `desktop-lifecycle.md` (shared runtime now real), the MVP checklist (B26, B27 progress rows), README.

## Not Verified By This Work (stated in the docs)

- A Developer ID signed and notarized build with the database (no signing is claimed).
- Real power loss and crash injection: tests cover damaged and missing files and the write order, not a pulled plug.
- A live check against real GitHub in the `com.dileight.runnir.alertcheck` copy, unless it is done and recorded.
- Several windows on one workspace are verified by unit and gRPC tests and, if done, the live check; not by UI automation.
