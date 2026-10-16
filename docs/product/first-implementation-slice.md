# First Implementation Slice: Workspace Window Lifecycle

Status: partial implementation, 2026-10-15. Native Manager/splash/windows, atomic registry/session and read-only local workflows are implemented. [Verification report](../architecture/desktop-foundation-verification.md) records tested behavior and remaining gates; the preserved [validation plan](offline-validation-slice.md) follows.

## User Outcome

Cold launch -> branded transient splash -> singleton Workspace Manager -> explicit import of an existing local working tree -> independent workspace window. Open two windows, close one manually, quit and restart: only eligible windows restore. No GitHub/network/.runnir file creation is required.

## Scope

Use Swift/AppKit-native lifecycle and scoped folder selection, stable registry workspaceId, UUID windowId, per-window UI state, serialized versioned SessionStore and one authoritative restoration mechanism. Keep existing SwiftUI feature screens/REST services and Core version IPC. Dashboard is the default tab inside a workspace. Preserve shared account state while separating window-bound selection/navigation.

Implement the minimum persistent registry/session needed for import/relink/restoration. Do not add SQLite, full config, sync or an executor just to demonstrate window behavior; their requirements and dependencies are explicit in ADR 0003. Do not claim cached run restoration until the DB slice exists.

## Required Evidence

- [ ] First launch and zero eligible windows route through splash to Manager; no artificial splash delay or remote wait.
- [ ] Manager is singleton and closes only after destination ready; picker/folder failure leaves it usable.
- [ ] Open A/B, then A twice: distinct window IDs/selections; no source window replaced by New Window.
- [ ] Reuse retains windowId and commits association only after destination ready; failure preserves source/drafts.
- [ ] Manual close removes eligibility durably; Cmd+Q snapshots remaining windows before teardown callbacks.
- [ ] Crash injection after committed close cannot resurrect a window, including backup/tombstone recovery.
- [ ] Final window close leaves no windows; repeated Dock activation opens/focuses one Manager.
- [ ] Missing/moved root offers relink without changing workspaceId or granting access silently.
- [ ] Quit-cancellation/dirty edits, display clamping and invalid-session recovery behave deterministically.
- [ ] Native build/unit checks and real AppKit ordering/signed-folder tests substantiate the implementation.

## Remaining Hardening

The implementation uses AppKit delegate-controlled windows and a combined atomic registry/session snapshot with fsync; native window restoration is disabled. Exercise crash/power-loss injection, signed folder grants, failed-write termination, missing monitors and relinking before declaring all lifecycle guarantees accepted. The product name remains Runnir; .runnir is exact and optional. See [lifecycle L01-L10](../architecture/desktop-lifecycle.md) and [ADR open decisions](../decisions/0003-workspaces-sessions-offline-storage.md).

This proposal does not authorize a broad rewrite. Later implement optional config display, SQLite/index/cache-first rendering, shared sync and environments/launches in bounded tested slices; FR-06 remains required for complete v0.1.
