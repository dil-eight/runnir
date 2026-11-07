# Session Recovery From A Backup (B23)

Status: design approved and built on 2026-11-06 on branch dilbarov/session-recovery; covered by app unit tests, not yet checked in a running build. Backlog: B23 in the [MVP checklist](../../product/mvp-implementation-checklist.md) (durable manual close, last-known-good recovery), FR-08 in the [specification](../../product/specification.md), the SessionStore contract in [desktop lifecycle](../../architecture/desktop-lifecycle.md). No new screen: a message in the Workspace Manager.

## Problem

`desktop-state.json` holds both the registry (every workspace's path and folder bookmark) and the session (the windows to restore). It is written atomically, so a crash leaves the old or the new content, but nothing helps when the file is unreadable anyway: damaged on disk, edited by hand or cut short by a failing drive. Runnir then blocks every save until the user chooses Back Up and Reset, and the reset starts from an empty registry: every workspace has to be imported again and its folder access granted again.

The lifecycle contract asks for last-known-good recovery that never brings back a window the user closed.

## Decisions

| Question | Decision |
| --- | --- |
| Where the backup is | `desktop-state.backup.json` beside `desktop-state.json` in Runnir's support folder, 0600 like it |
| What it holds | The same snapshot as the main file. Every save writes the main file and then the backup, each atomically; a crash between the two, or a backup write that fails, leaves the backup one save behind, and the main file is read first. A failed backup write does not fail the save: the main file holds the session, and recovery takes no windows from the backup anyway |
| When it is used | Only when the main file exists and cannot be read or fails validation (not JSON, too large, an unknown version, duplicate ids, a window without its workspace, invalid geometry) |
| What comes back | The workspaces of the backup only. Windows are never restored from it, so a window closed by hand cannot come back, and no tombstones are needed |
| The unreadable file | Kept beside it as `desktop-state-unreadable-<uuid>.json`, as Back Up and Reset keeps it today |
| After recovery | The recovered snapshot (workspaces, no windows) is saved to both files at once, saving is not blocked, and the Workspace Manager opens with: "The saved session could not be read. Workspaces were restored from a backup; windows were not reopened." |
| No main file | An empty session, as today, even when a backup exists: the main file is missing only on a first launch or after someone removed it on purpose |
| Both unreadable, or no backup | As today: saving is blocked and the Manager offers Back Up and Reset. Nothing is reset silently |
| Not done | Tombstones, windows restored from the backup, several generations of backups, version migrations (AGENTS.md: none before the first release) |

## Code

`DesktopStateStore.swift`:

- `FileDesktopStateStore.backupURL` is `desktop-state.backup.json`.
- `save(_:)` validates, writes `stateURL`, then `backupURL`, both through `JSONFile.write`.
- `load()` stays strict: the main file or an error. Tests and the strict callers keep using it.
- A new `DesktopLaunchState { snapshot, restoredFromBackup }` and `loadForLaunch()` on `DesktopStateStoring`. The protocol's default calls `load()` and reports no recovery, so the test stores need no change. `FileDesktopStateStore.loadForLaunch()` falls back as above: it keeps the unreadable main file, reads the backup strictly, drops its windows, saves the result and returns it with `restoredFromBackup = true`. When the backup cannot be read either, it throws the main file's error and writes nothing.
- `preserveUnreadable()` copies `stateURL` to `desktop-state-unreadable-<uuid>.json`; both the fallback and `resetUnreadableSession` use it.

`DesktopCoordinator.loadSession()` calls `loadForLaunch()` and sets `message` to the recovery text when `restoredFromBackup` is true. With no windows in the snapshot the Manager opens, as for a session where every window was closed.

## Tests

In `DesktopStateTests`, on a temporary folder:

- After a save both files hold the same snapshot.
- A main file that is not JSON and a readable backup: the workspaces come back, no windows, the unreadable file is kept, and both files then hold the recovered snapshot.
- A main file that fails validation (a duplicate workspace id) recovers the same way.
- No main file and a backup: an empty session, the backup untouched.
- Both files unreadable: an error, neither file changed and no file written.
- A window closed by the last save stays closed after a recovery, and so does every other window.
- The coordinator shows the recovery message and is not blocked after a recovery; it is blocked, with today's message, when both files are unreadable.

The existing `unknownSchemaAndCorruptStateAreNotSilentlyReset` keeps its meaning for `load()`, and covers `loadForLaunch()` without a backup.
