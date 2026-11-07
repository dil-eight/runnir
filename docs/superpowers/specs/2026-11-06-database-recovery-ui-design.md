# Telling The User About A Recovered Database (B29)

Status: design approved and built on 2026-11-06 on branch dilbarov/session-recovery; covered by Core and app tests, not yet seen in a running build. Backlog: B29 (a recovery UI beyond the note in Settings › Storage; B26's open item) in the [MVP checklist](../../product/mvp-implementation-checklist.md), W05 in [workspace persistence](../../architecture/workspace-persistence.md).

## Problem

When a workspace's `state.sqlite` is damaged, made by an earlier build or cannot be opened, the Core already acts on its own: it moves the files into `recovery/<stamp>/` in the workspace's folder, makes a new database and puts the local run records back from the backup; when no file can be used at all, the workspace's data lives in memory until the Core stops. Only Settings › Storage says so, as a note under the workspace and "N recovery copies" in its summary. The workspace window works as if nothing happened, so the user learns neither that saved runs are downloading again nor, worse, that nothing will be kept after quitting. Recovery copies pile up and can be neither opened nor removed from Runnir.

## Decisions

| Question | Decision |
| --- | --- |
| What a window learns | `WorkspaceActivity.storage_notice`: the store's state (persistent or memory only), the store's note (what recovery did, or why it is in memory) and the recovery folder's path when it holds a copy. Only for a store in memory or one that was recovered when it opened (set aside as damaged or from an earlier build, or missing or empty with local runs restored from the backup): another note, such as a backup that could not be written, stays in Settings › Storage. Absent in the usual case |
| Where it shows | A banner in every window of the workspace, above the content and under the Core banner, like the analytics question |
| Recovered (persistent with a note) | "Saved data of this workspace was recovered." with the Core's note under it, Show in Finder when there is a recovery folder, and a close button. Closing it hides it in every window of the workspace until the Core reports another note |
| Memory only | "Runnir cannot save this workspace's data." with the Core's note and "Runs, logs and local run history shown here are lost when Runnir quits." No close button: it stays while the store is in memory |
| Settings › Storage | A workspace with recovery copies gets Show in Finder (the recovery folder) and Delete Recovery Copies… with a confirmation; the summary keeps "N recovery copies" |
| Deleting copies | A new RPC `DeleteRecoveryCopies(workspace_ids)` removes each workspace's `recovery` folder and returns the storage of each, like `ClearWorkspaceCache`; an open workspace then stops announcing its recovery, so the banner goes away. Allowed while the workspace is open: the open database never lives in `recovery`. Backups and migration copies are not touched |
| Who knows the folder | The Core: `WorkspaceStorage.recovery_path` and `StorageNotice.recovery_path`, set only when the folder holds a copy. The app never builds the path itself |
| Not done | Restoring a copy, opening a copy, recovery of the search index or the analytics ledger, a Pen frame (the banner reuses the analytics question's layout) |

## Contract

```proto
message StorageNotice {
  StorageState state = 1;      // PERSISTENT or MEMORY_ONLY
  string note = 2;             // never a credential
  string recovery_path = 3;    // the recovery folder, when it holds a copy
}
// WorkspaceActivity
StorageNotice storage_notice = 9;
// WorkspaceStorage
string recovery_path = 11;
rpc DeleteRecoveryCopies(DeleteRecoveryCopiesRequest) returns (DeleteRecoveryCopiesResponse);
message DeleteRecoveryCopiesRequest { repeated string workspace_ids = 1; }  // empty: every workspace
message DeleteRecoveryCopiesResponse { repeated WorkspaceStorage workspaces = 1; }
```

## Code

- Core `store`: `RecoveryPath(dir)` (the folder when it holds a directory, else "") and `DeleteRecoveryCopies(dir)`; `Usage` gains `RecoveryPath`.
- Core `workspace.Runtimes.DeleteRecoveryCopies(ctx, ids)`: for each workspace, under its claim, remove the folder, then return `Usage` as `ClearCache` does.
- Core server: `snapshotMessage` fills `storage_notice` from the runtime's store report and `RecoveryPath`; the new handler maps errors like `ClearWorkspaceCache`.
- App: `CoreStorageNotice` on `CoreWorkspaceActivity` and `RepositorySession`; `recoveryPath` on `CoreWorkspaceStorage`; `CoreServicing.deleteRecoveryCopies` and `CoreHub.deleteRecoveryCopies`; `StorageNoticeBanner` in the workspace window; the dismissal kept on the session (the note dismissed), so all its windows follow; the two Settings › Storage buttons.

## Tests

- Core: `RecoveryPath` empty without copies and set after a damaged database is opened; `DeleteRecoveryCopies` removes the copies and keeps the database, the backup and migration copies; the RPC on an open and a closed workspace; `GetWorkspaceActivity` carries the notice after recovery, none for a healthy store, memory only with its note.
- App: the notice mapped from the activity onto the session; closing hides it for the session and a different note shows again; memory only cannot be closed; the Storage model's delete calls the hub and reloads.
