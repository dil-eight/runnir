# 0003 Workspace Sessions And Offline Persistence

Status: accepted direction, 2026-10-14; desktop foundation implemented 2026-10-15; per-workspace database and shared sync implemented 2026-10-22 ([ADR 0007](0007-workspace-sqlite.md)); portable config pending. Extends ADR 0002 without changing SwiftUI + Go or current source paths.

## Decisions

- Keep Runnir as the current product/bundle/source name. The incoming document uses Ranir; brand renaming remains unresolved. Preserve the exact portable directory spelling .runnir regardless.
- One registered local working-tree instance maps to a stable workspaceId. Each window has a separate UUID windowId; remote URL and mutable folder path are not identities.
- Swift/AppKit coordinates splash, singleton manager, windows, scoped folder grants, SessionStore and repository registry. SessionStore is the single workspace-restoration authority; native scene restoration must be coordinated/disabled for these windows to prevent duplicate restores.
- Portable Go services own repository config interpretation, effective non-secret configuration, per-workspace database/index/sync and execution domain records. Swift retains Keychain and native file-access/notification bridges. Preserve existing Swift GitHub services until tested migration; do not create a second competing sync writer during transition.
- Use per-workspace embedded SQLite under resolved Application Support, outside Git. It is now an explicit offline-query/transaction requirement, superseding the earlier optional-SQLite/light-config recommendation. Keep global settings/registry/session in versioned local files.
- Share one logical WorkspaceRuntime and SyncCoordinator per workspaceId across windows. WindowState is per window. A runtime is a service object, not necessarily a process. Prefer one app-owned Core service process for the future shared runtime, with bounded lifetime ending at app exit; it is not a permanent daemon.
- .runnir contains optional portable declarative config/environments/launch presets. Normal opening is read-only; creation/editing requires user action. Machine overrides/cache/session and credentials never belong there.
- Cache-first window rendering must not await GitHub. Remote dispatch uses published GitHub definitions; local act execution remains a separate, explicitly approved v0.1 capability.

## Lifecycle Guarantees

Manual close durably removes only that window from restore eligibility. Quit enters termination mode before Cocoa teardown, snapshots remaining windows and ignores teardown as manual close. Critical create/close/reassociation writes are serialized and durable; geometry/navigation can be debounced. Atomic replacement alone is not a specification of power-loss durability: choose/test fsync/journal/tombstone behavior before claiming the strong close guarantee.

Restore window shells independently, clamp frames to connected displays and recover missing repos/config/DB without blocking unrelated windows. No session restores live processes, command sessions or reruns workflows. Retain interrupted/unknown historical execution results without implying liveness.

## Reconciliation

DesktopCoordinator now owns AppKit windows with independent AppState/navigation. Registry and restore eligibility use a single versioned desktop-state.json transaction: validate, write/fsync a private temporary file, rename, then fsync the directory. Combining registry and session avoids a partial reassociation across two files. Manual close commits removal before allowing closure; quit preserves eligible entries before teardown. Corrupt state blocks mutations until an explicit backup-and-reset; backups are never automatically replayed. Real power-loss/crash-injection verification remains outstanding.

The version handshake remains one-shot. ADR 0004 added the persistent transport with shared repository contexts and events, keeping core.v1.version compatibility. The shared database and sync now run in the Core: one runtime per workspace id, bound to the repository contexts its windows open ([ADR 0007](0007-workspace-sqlite.md)).

Workspace startup/config phases can ship incrementally, but they do not remove FR-06's local-execution gate for a complete v0.1. Basic app use still needs no Runnir account, backend or analytics consent. Keychain remains the only implemented/approved credential storage; external credential providers mentioned in the incoming proposal are deferred.

## Open Implementation Decisions

Core DB access in a signed build (not verified yet); critical session commit/tombstone strategy; app termination callback ordering at macOS 15+; field-specific config merge rules; portable secret-reference resolver; dirty-editor behavior across same-workspace windows; any permanent product rename. (Account-wide remote browsing placement was settled on 2026-10-20: a GitHub tab in the Workspace Manager. The SQLite driver, its licenses and version, WAL/shutdown/single-writer ownership, and the sync, history and blob budgets were settled on 2026-10-22 in ADR 0007.)

See [desktop verification](../architecture/desktop-foundation-verification.md), [lifecycle](../architecture/desktop-lifecycle.md) and [persistence/config/sync](../architecture/workspace-persistence.md). The SQLite driver is modernc.org/sqlite ([ADR 0007](0007-workspace-sqlite.md)).
