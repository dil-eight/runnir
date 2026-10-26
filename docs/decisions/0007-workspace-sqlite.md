# 0007 Workspace Database In The Go Core

Status: accepted, 2026-10-22. Settles the driver, ownership and budget questions [ADR 0003](0003-workspaces-sessions-offline-storage.md) left open. Design: [workspace cache spec](../superpowers/specs/2026-10-22-workspace-cache-design.md).

## Context

ADR 0003 asks for one embedded SQLite database per workspace, owned by the portable Go Core, so a window can show GitHub Actions activity before GitHub answers and several windows on one workspace share one writer and one sync. The Core is built with `CGO_ENABLED=0` and ships signed with the hardened runtime and no entitlements ([ADR 0005](0005-developer-id-without-app-sandbox.md)), so the driver must be pure Go and must not need executable memory.

## Decision

- Driver: `modernc.org/sqlite` v1.60.1 (released 2026-09-29) through `database/sql`. It is SQLite's C source translated to Go: no CGO, no executable memory, darwin/arm64 and darwin/amd64 supported. v1.61.0 was one day old when this was decided and was not taken.
- One database per workspace at `<data-dir>/repositories/<workspaceId>/state.sqlite`, where `<data-dir>` is the folder the app passes with `runnir serve --data-dir` (`~/Library/Application Support/Runnir`, or the UI-test state folder). Without `--data-dir` the Core keeps every workspace in memory and writes nothing.
- Single writer: each store is one `*sql.DB` limited to one long-lived connection, so every read and write in the process is serialized. An exclusive `flock` on `lock` next to the database keeps a second process (another copy of Runnir with its own Core) out; that process falls back to an in-memory store and says so.
- WAL with `synchronous=FULL`, foreign keys on, immediate write transactions. Closing a store runs `wal_checkpoint(TRUNCATE)`. The store opens when a workspace's first window opens and closes with its last.
- Schema versions are `PRAGMA user_version`; migrations are embedded and each runs in one transaction. A copy (`VACUUM INTO`) precedes every migration of an existing database; the newest three copies are kept.
- Data classes: cache tables (runs, jobs, steps, workflows, sync state, kept logs) can be downloaded again and Clear Cache empties them; `local_runs` and `savings` exist only on this Mac, are copied to `backups/local-data.sqlite` after every change, and survive Clear Cache and recovery.
- Large data (kept job logs) lives in files under `blobs/`, with size, checksum and last use in the database.

## Alternatives

- `github.com/ncruces/go-sqlite3` (MIT): SQLite compiled to Wasm and run by wazero. wazero's fast mode compiles to executable memory, which the hardened runtime refuses without `com.apple.security.cs.allow-jit`; its interpreter avoids that but is much slower.
- `github.com/mattn/go-sqlite3`: needs CGO.
- JSON files like the app's other state: no transactions across related rows, no indexed queries, whole-file rewrites.

## Licenses

New modules in `core/go.mod`, read from each module's license file:

| Module | License |
| --- | --- |
| modernc.org/sqlite v1.60.1 | BSD-3-Clause; SQLite itself is public domain (`LICENSE-SQLITE`) |
| modernc.org/libc v1.77.1 | BSD-3-Clause, with third-party parts listed in its `LICENSE-3RD-PARTY.md` |
| modernc.org/mathutil v1.7.1, modernc.org/memory v1.12.1 | BSD-3-Clause |
| github.com/google/uuid v1.6.0 | BSD-3-Clause |
| github.com/remyoudompheng/bigfft | BSD-3-Clause |
| github.com/dustin/go-humanize v1.0.1 | MIT |
| github.com/ncruces/go-strftime v1.0.0 | MIT |

`github.com/mattn/go-isatty` moved from v0.0.20 to v0.0.24 (MIT) by version selection. All are permissive. The app bundle does not yet ship the Core's dependency notices (only act's license is bundled today); adding them for every Core dependency is a release task, not part of this decision.

## Consequences

- The Core binary grows by about 6.6 MB per architecture (see [verification](#verification)).
- Only the Core touches workspace databases. The app reads activity and storage usage through gRPC.
- A damaged database is moved to `recovery/<time>/` and kept; local run records are restored from it or from the backup. So is one at the current schema version that lacks a table the schema creates: before the first release the schema changes in place, so an earlier development build may have made it. A database from a newer Runnir is left untouched and the workspace runs in memory.
- Not verified by this decision: a Developer ID signed and notarized build with the database, and behavior on real power loss or a crash during a write (tests cover damaged and missing files and the write order only).

## Verification

Core binary built the way the app builds it (`CGO_ENABLED=0 go build -trimpath`, no stripping), 2026-10-22:

| Architecture | Before | With the store | Difference |
| --- | ---: | ---: | ---: |
| darwin/arm64 | 21.7 MB | 28.3 MB | +6.6 MB |
| darwin/amd64 | 23.0 MB | 29.7 MB | +6.6 MB |

The universal helper in the app grows by about 13 MB.

Tests (`go test -race ./...`): migrations, a newer schema left untouched, the lock against a second opener, damaged and missing databases with local runs restored, rollback of a failed migration, Clear Cache keeping local runs, budgets, blob checks, and folders with spaces in their names.

Live check in a Debug test copy (`com.dileight.runnir.alertcheck`, `--ui-testing`, its own state folder): the app passed `--data-dir`, the Core created `repositories/<workspaceId>/state.sqlite` with `lock` and `backups/local-data.sqlite`, and quitting left no `-wal` file behind (checkpointed on close).
