# Repository Configuration, SQLite And Synchronization

Status: target design, updated 2026-10-15. Swift now persists the local registry and window session together in Application Support/Runnir/desktop-state.json; the layout below remains a future subsystem plan. No .runnir loader, SQLite, sync or environment subsystem exists in Core. See [ADR 0003](../decisions/0003-workspaces-sessions-offline-storage.md).

## Storage Ownership

```text
<repo>/.github/workflows/*.yml|*.yaml   # user-authored local workflow source
<repo>/.runnir/config.yaml             # optional portable non-secret defaults
<repo>/.runnir/environments.yaml       # optional non-secret env definitions/references
<repo>/.runnir/launches/*.yaml          # optional portable launch presets

<ApplicationSupport>/Runnir/settings.json
<ApplicationSupport>/Runnir/session.json
<ApplicationSupport>/Runnir/repositories.json
<ApplicationSupport>/Runnir/repositories/<workspaceId>/state.sqlite
<ApplicationSupport>/Runnir/repositories/<workspaceId>/snapshots/
<ApplicationSupport>/Runnir/repositories/<workspaceId>/artifacts/
<ApplicationSupport>/Runnir/repositories/<workspaceId>/runtime/
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

## Portable Configuration Examples

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

Examples are proposed schema v1, not an implemented parser or current IPC contract. Use bounded safe YAML parsing, explicit keys/types/enums and unsupported-version errors; no dynamic evaluation or plugin DSL. Reject traversal/absolute workflow paths and out-of-scope symlink resolution.

config.yaml:

```yaml
version: 1
repository:
  provider: github
defaults:
  environment: local
  ref: main
sync:
  workflows: true
  runs: true
```

environments.yaml:

```yaml
version: 1
environments:
  local:
    variables:
      NODE_ENV: development
  staging:
    variables:
      NODE_ENV: staging
    secrets:
      API_TOKEN: keychain://runnir/staging/api-token
```

launches/deploy-staging.yaml:

```yaml
version: 1
name: Deploy Staging
workflow: deploy.yml
execution:
  target: github
defaults:
  ref: main
  inputs:
    environment: staging
safety:
  confirmationRequired: true
```

Only github/local targets are allowed; local remains unavailable until an executor is implemented and never falls back to remote. workflow references a known file under .github/workflows, not arbitrary paths/commands. The selected ref is a preference, not proof of current branch/default or remote availability. Validate current workflow inputs/permissions at execution.

keychain:// is an illustrative reference, not an existing/universal URI API. Define ownership, lookup/access prompts, repository trust, missing-secret behavior and scope before resolving it. Repository content cannot cause arbitrary Keychain reads or automatic environment injection. GitHub Actions secrets remain GitHub-managed; a local reference is not permission to upload a Keychain secret to GitHub. Portable config contains no credentials, private keys or machine-specific absolute paths.

Precedence for permitted non-secret values, highest first: explicit per-launch UI override -> machine-local workspace override -> launch preset -> selected environment -> repository defaults -> app defaults. Define merging per field, including absent versus null/false, input-map replacement, removal and invalid values; no arbitrary deep merge. Show effective values and their origins. Security/approval policy is enforced outside this hierarchy; confirmationRequired:false cannot bypass it. Effective secrets exist transiently only when explicitly authorized, never in previews, snapshots/DB/debug dumps or persisted environment maps.

Malformed/missing/unsupported config yields filename/diagnostic and a usable workspace in degraded/default mode. Normal open remains read-only. Valid optional config may be edited/generated only through explicit reviewed user action, with unsaved/external-change handling like workflow files. Local-only presets remain supported as machine-private overrides; portable presets are a separate user-chosen storage mode.

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
| W02 | Safe optional YAML parse, future-version error, limits/traversal/unsafe input denial and degraded opening |
| W03 | Field precedence/effective-value origins tested; repository safety flag cannot bypass app policy |
| W04 | Secret reference scoped/missing/denied; no values in portable/local persistence or diagnostics |
| W05 | SQLite migrations/transaction/concurrent-window reads and single-writer integrity; missing/corrupt DB repair preserves unique local data |
| W06 | Offline relaunch renders cache before network; shared windows issue one logical sync; checked/failed/succeeded times remain separate |
| W07 | Local changes, remote YAML and live run updates are distinguishable; auth/rate-limit/backoff/cancel handled |
| W08 | Clear Cache/retention/path extraction limits do not delete config/overrides/grants/credentials; blob traversal denied |
| W09 | Interrupted execution history is unknown/interrupted, never automatically resumed/successful |

Unit tests cover schemas/precedence/IDs/migrations/sync reconciliation/redaction. Real integration tests cover signed scope grants, concurrent windows, file changes, offline networks, partial writes and corruption recovery. Configuration parsing alone is not a completed local executor.
