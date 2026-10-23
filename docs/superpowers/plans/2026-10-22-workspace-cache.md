# Workspace Cache, Shared Runtime And Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep each workspace's GitHub Actions activity in a per-workspace SQLite database in the Go Core, render it before any network call, and run exactly one sync per workspace however many windows show it.

**Architecture:** A new `internal/store` package owns one SQLite database per workspace (modernc.org/sqlite, one serialized connection, a flock against other processes, migrations, backup and recovery, blobs). A new `internal/workspace` package keeps one `Runtime` per workspace id with its store, a sync goroutine (ETag reads, backoff, events), shared jobs and log reads, and local run history. The gRPC server binds repository contexts to workspace ids and exposes cache-first reads; the Swift `CoreHub` drops its polling and renders snapshots, refreshing on `ACTIVITY_CHANGED`.

**Tech Stack:** Go 1.27.3 (`CGO_ENABLED=0`), modernc.org/sqlite v1.60.1, golang.org/x/sync/singleflight, protobuf + buf, grpc-go; Swift 6, SwiftUI, Observation, Swift Testing, grpc-swift generated client.

Spec: [docs/superpowers/specs/2026-10-22-workspace-cache-design.md](../specs/2026-10-22-workspace-cache-design.md).

## Global Constraints

- Go commands: prefix with `PATH="$HOME/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.27.3.darwin-arm64/bin:$PATH"` (system Go is 1.27.2) and run from `core/`.
- Contract generation: `PATH="<scratchpad>/bin:$HOME/go/bin:$PATH" scripts/generate-contracts.sh`, where `<scratchpad>/bin` holds protoc-gen-swift 1.39.0 and protoc-gen-grpc-swift-2 2.5.0.
- Only new module: `modernc.org/sqlite v1.60.1` (and what it pulls in); `golang.org/x/sync` moves from indirect to direct. No CGO.
- Workspace id: the registry UUID; the Core accepts `8-4-4-4-12` hex in any case and uses it lowercased.
- Layout: `<data-dir>/repositories/<workspaceId>/{state.sqlite,lock,blobs/,backups/,recovery/<stamp>/}`; directories 0700, files 0600; never follow a symlink there.
- Without `--data-dir` the Core writes nothing to disk (every store in memory).
- Budgets per workspace: 200 runs (jobs and steps cascade), 200 local run records, 100 MiB of kept logs, one blob at most 3 MiB, three pre-migration copies.
- Sync: 50 runs per read; 20 s while a run is queued, in progress, waiting, requested or pending; 5 min otherwise; backoff 30 s, 1 min, 2 min, 5 min on `UNAVAILABLE`; `retry_after` clamped to 30 s–1 h; no timer after `NO_REMOTE`, `SIGNED_OUT`, `TOKEN_REJECTED`, `NOT_VISIBLE`, `PERMISSION_MISSING`; cached jobs reused for 10 s.
- `keep_job_logs` starts false in every Core process; the app sends it at Core start and when it changes.
- No telemetry, no credentials on disk or in notes, no AI attribution in commits, code or docs. UI text in English.
- Before handing off: from `core/` `go test ./...`, `go vet ./...`, `CGO_ENABLED=0 go build ./...`; then `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build` and `... test -only-testing:RunnirTests` (xcodebuild also with the Go 1.27.3 PATH, because the build bundles the Core).

## Spec Adjustments Made While Planning

- `RepositoryResponse` does not gain a storage field: Settings › Storage reads `GetStorageUsage`, nothing else needs it.
- `SetStoragePreferencesRequest` has `keep_job_logs` and `delete_kept_logs`: the app sets `delete_kept_logs` only when the user turns the toggle off, so pushing `false` at every launch never walks every workspace.
- The spec's "named by SHA-256" for blobs: the name is the SHA-256 of the job id and the content, so two jobs with identical logs never share a file; the content checksum is stored separately.

## File Map

Core (Go):
- `core/go.mod`, `core/go.sum` — driver (Task 1).
- `core/internal/store/store.go` — `Open`, `Close`, pragmas, memory fallback, `Report` (Task 1).
- `core/internal/store/schema.go` — migrations (Task 1).
- `core/internal/store/lock_unix.go`, `lock_windows.go` — flock (Task 1).
- `core/internal/store/dirs.go` — workspace ids, directories, delete (Task 1).
- `core/internal/store/localruns.go` — local run history (Task 2).
- `core/internal/store/recovery.go` — backups, quarantine, salvage, restore (Task 2).
- `core/internal/store/activity.go` — runs, workflows, sync state, source (Task 3).
- `core/internal/store/jobs.go` — jobs cache (Task 3).
- `core/internal/store/usage.go` — usage and Clear Cache (Task 3).
- `core/internal/store/blobs.go` — kept logs (Task 4).
- `core/internal/github/client.go` — conditional reads (Task 5).
- `core/internal/workspace/access.go` — error to status mapping (Task 6).
- `core/internal/workspace/runtime.go`, `schedule.go` — runtime and sync loop (Task 6).
- `core/internal/workspace/jobs.go`, `logs.go` — shared reads (Task 7).
- `core/internal/workspace/runtimes.go`, `recorder.go` — registry, storage operations, local run history (Task 7).
- `contracts/grpc/runnir/core/v1/runnir_core.proto` and generated Go/Swift (Task 8).
- `core/internal/server/{server,service,github,runs,localruns}.go`, new `workspace.go`; `core/cmd/runnir/main.go` (Task 9).

App (Swift):
- `apps/macos/Runnir/IPC/CoreService.swift`, new `CoreWorkspaceModels.swift`, `GRPCCoreService.swift`, `ProcessCoreLauncher.swift`, `CoreProcessSupervisor.swift` (Task 10).
- `apps/macos/Runnir/IPC/CoreHub.swift` (Task 11).
- New `apps/macos/Runnir/Features/Desktop/ActivityFreshness.swift`; `GitHubActivityViews.swift`, `OverviewViews.swift`, `DesktopViews.swift` (Task 12).
- New `apps/macos/Runnir/Features/Settings/StorageSettings.swift`; `SettingsOverlay.swift`; `apps/macos/Runnir/App/Desktop/DesktopCoordinator.swift` (Task 12).
- Tests: `apps/macos/RunnirTests/CoreHubTests.swift`, `CoreProcessSupervisorTests.swift`, new `WorkspaceCacheTests.swift` (Tasks 10–12).

Docs: new `docs/decisions/0007-workspace-sqlite.md` (Task 1), ADR 0003, `docs/architecture/{workspace-persistence,grpc-api,desktop-lifecycle}.md`, `docs/product/mvp-implementation-checklist.md`, `README.md` (Task 13).

---

### Task 1: Driver, store skeleton, migrations, lock, ADR 0007

**Files:**
- Modify: `core/go.mod`, `core/go.sum`
- Create: `core/internal/store/store.go`, `schema.go`, `lock_unix.go`, `lock_windows.go`, `dirs.go`
- Test: `core/internal/store/store_test.go`, `dirs_test.go`
- Create: `docs/decisions/0007-workspace-sqlite.md`

**Interfaces:**
- Produces:
  - `type State int` with `Persistent`, `MemoryOnly`; `type Report struct{ State State; Note string }`
  - `type Options struct{ Now func() time.Time }`
  - `func Open(dir string, options Options) (*Store, error)`; `(*Store).Close() error`; `(*Store).Report() Report`; `(*Store).Dir() string`
  - `var migrations []string` (package variable, tests may extend it)
  - `func NormalizeWorkspaceID(id string) (string, bool)`, `func WorkspaceDir(dataDir, id string) string`, `func Workspaces(dataDir string) ([]string, error)`, `func DeleteWorkspace(dataDir, id string) error`

- [ ] **Step 1: Add the driver**

```bash
cd core && go get modernc.org/sqlite@v1.60.1 && go mod tidy
```

Expected: `go.mod` lists `modernc.org/sqlite v1.60.1`. (`go mod tidy` drops it again until a file imports it, so run tidy again after Step 4.)

- [ ] **Step 2: Write the failing tests**

`core/internal/store/store_test.go`:

```go
package store

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func fixedNow() time.Time { return time.Date(2026, 10, 22, 12, 0, 0, 0, time.UTC) }

func openTest(t *testing.T, dir string) *Store {
	t.Helper()
	s, err := Open(dir, Options{Now: fixedNow})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func TestANewStoreIsCreatedPrivateAndReopened(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ws")
	s := openTest(t, dir)
	if r := s.Report(); r.State != Persistent || r.Note != "" {
		t.Fatalf("report = %+v", r)
	}
	if v, err := s.userVersion(); err != nil || v != len(migrations) {
		t.Fatalf("version = %d, %v", v, err)
	}
	info, err := os.Stat(dir)
	if err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("dir mode = %v, %v", info.Mode(), err)
	}
	if info, err := os.Stat(filepath.Join(dir, "state.sqlite")); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("db mode = %v, %v", info, err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	again := openTest(t, dir)
	if again.Report().State != Persistent {
		t.Fatalf("reopen = %+v", again.Report())
	}
}

func TestEmptyDirMeansMemory(t *testing.T) {
	s := openTest(t, "")
	if s.Report().State != MemoryOnly || s.Report().Note != "" || s.Dir() != "" {
		t.Fatalf("report = %+v", s.Report())
	}
	if v, err := s.userVersion(); err != nil || v != len(migrations) {
		t.Fatalf("memory schema = %d, %v", v, err)
	}
}

func TestASecondOpenerFallsBackToMemory(t *testing.T) {
	dir := t.TempDir()
	openTest(t, dir)
	second := openTest(t, dir)
	if r := second.Report(); r.State != MemoryOnly || r.Note != "In use by another copy of Runnir." {
		t.Fatalf("second = %+v", r)
	}
}

func TestANewerSchemaIsLeftUntouched(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	if _, err := s.db.Exec("PRAGMA user_version = 99"); err != nil {
		t.Fatal(err)
	}
	_ = s.Close()
	before, _ := os.ReadFile(filepath.Join(dir, "state.sqlite"))
	again := openTest(t, dir)
	if r := again.Report(); r.State != MemoryOnly || r.Note != "Made by a newer version of Runnir (schema 99)." {
		t.Fatalf("report = %+v", r)
	}
	_ = again.Close()
	after, _ := os.ReadFile(filepath.Join(dir, "state.sqlite"))
	if string(before) != string(after) {
		t.Fatal("the newer database was changed")
	}
}

func TestASymlinkedDatabaseIsRefused(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(t.TempDir(), "elsewhere.sqlite")
	_ = os.WriteFile(target, nil, 0o600)
	if err := os.Symlink(target, filepath.Join(dir, "state.sqlite")); err != nil {
		t.Fatal(err)
	}
	s := openTest(t, dir)
	if r := s.Report(); r.State != MemoryOnly || r.Note != "The workspace database is not a regular file." {
		t.Fatalf("report = %+v", r)
	}
}
```

`core/internal/store/dirs_test.go`:

```go
package store

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWorkspaceIDsAreNormalized(t *testing.T) {
	id, ok := NormalizeWorkspaceID("5CE88FF0-5C16-43B3-8F20-8E33E852B019")
	if !ok || id != "5ce88ff0-5c16-43b3-8f20-8e33e852b019" {
		t.Fatalf("id = %q, %v", id, ok)
	}
	for _, bad := range []string{"", "..", "5ce88ff0", "5ce88ff0-5c16-43b3-8f20-8e33e852b01g", "../5ce88ff0-5c16-43b3-8f20-8e33e852b019"} {
		if _, ok := NormalizeWorkspaceID(bad); ok {
			t.Fatalf("%q accepted", bad)
		}
	}
}

func TestWorkspacesListsOnlyWorkspaceDirectories(t *testing.T) {
	data := t.TempDir()
	id := "5ce88ff0-5c16-43b3-8f20-8e33e852b019"
	_ = os.MkdirAll(WorkspaceDir(data, id), 0o700)
	_ = os.MkdirAll(filepath.Join(data, "repositories", "not-an-id"), 0o700)
	_ = os.WriteFile(filepath.Join(data, "repositories", "6ce88ff0-5c16-43b3-8f20-8e33e852b019"), nil, 0o600)
	ids, err := Workspaces(data)
	if err != nil || len(ids) != 1 || ids[0] != id {
		t.Fatalf("ids = %v, %v", ids, err)
	}
	if ids, err := Workspaces(filepath.Join(data, "missing")); err != nil || len(ids) != 0 {
		t.Fatalf("missing = %v, %v", ids, err)
	}
}

func TestDeleteWorkspaceRemovesOnlyItsDirectory(t *testing.T) {
	data := t.TempDir()
	id := "5ce88ff0-5c16-43b3-8f20-8e33e852b019"
	outside := filepath.Join(t.TempDir(), "keep.txt")
	_ = os.WriteFile(outside, []byte("x"), 0o600)
	dir := WorkspaceDir(data, id)
	_ = os.MkdirAll(dir, 0o700)
	_ = os.Symlink(outside, filepath.Join(dir, "link"))
	if err := DeleteWorkspace(data, id); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(dir); !os.IsNotExist(err) {
		t.Fatal("directory kept")
	}
	if _, err := os.Stat(outside); err != nil {
		t.Fatal("followed a symlink")
	}
	if err := DeleteWorkspace(data, id); err != nil {
		t.Fatal("deleting a missing workspace must succeed")
	}
	if err := DeleteWorkspace(data, "../x"); err == nil {
		t.Fatal("invalid id accepted")
	}
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `go test ./internal/store/`
Expected: FAIL to build (`undefined: Open`).

- [ ] **Step 4: Implement**

`core/internal/store/lock_unix.go`:

```go
//go:build !windows

package store

import (
	"errors"
	"os"
	"syscall"
)

var errLocked = errors.New("locked by another process")

type fileLock struct{ file *os.File }

// acquireLock takes an advisory, non-blocking exclusive lock; the OS drops
// it when the process dies.
func acquireLock(path string) (*fileLock, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, errLocked
		}
		return nil, err
	}
	return &fileLock{file: file}, nil
}

func (l *fileLock) release() { _ = l.file.Close() }
```

`core/internal/store/lock_windows.go`:

```go
//go:build windows

package store

import "errors"

var errLocked = errors.New("locked by another process")

type fileLock struct{}

// Workspace databases are a macOS feature; other platforms keep memory stores.
func acquireLock(string) (*fileLock, error) { return nil, errors.New("not supported on this platform") }

func (l *fileLock) release() {}
```

`core/internal/store/schema.go`:

```go
package store

// migrations[i] moves a database from schema i to i+1. Each runs in one
// transaction with the new user_version. Never edit a released entry; add
// one.
var migrations = []string{schemaV1}

const schemaV1 = `
CREATE TABLE cache_source (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	server_id TEXT NOT NULL,
	repository TEXT NOT NULL
);
CREATE TABLE sync_state (
	scope TEXT PRIMARY KEY,
	etag TEXT NOT NULL DEFAULT '',
	checked_at INTEGER NOT NULL DEFAULT 0,
	synced_at INTEGER NOT NULL DEFAULT 0,
	changed_at INTEGER NOT NULL DEFAULT 0,
	access INTEGER NOT NULL DEFAULT 0,
	retry_after INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE remote_workflows (
	id INTEGER PRIMARY KEY,
	position INTEGER NOT NULL,
	name TEXT NOT NULL,
	path TEXT NOT NULL,
	state TEXT NOT NULL,
	html_url TEXT NOT NULL
);
CREATE TABLE runs (
	id INTEGER PRIMARY KEY,
	workflow_id INTEGER NOT NULL,
	name TEXT NOT NULL,
	display_title TEXT NOT NULL,
	run_number INTEGER NOT NULL,
	run_attempt INTEGER NOT NULL,
	event TEXT NOT NULL,
	status TEXT NOT NULL,
	conclusion TEXT NOT NULL,
	branch TEXT NOT NULL,
	head_sha TEXT NOT NULL,
	actor TEXT NOT NULL,
	html_url TEXT NOT NULL,
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL
);
CREATE INDEX runs_created ON runs (created_at DESC, id DESC);
CREATE INDEX runs_workflow ON runs (workflow_id);
CREATE TABLE run_jobs (
	id INTEGER PRIMARY KEY,
	run_id INTEGER NOT NULL REFERENCES runs (id) ON DELETE CASCADE,
	attempt INTEGER NOT NULL,
	position INTEGER NOT NULL,
	name TEXT NOT NULL,
	status TEXT NOT NULL,
	conclusion TEXT NOT NULL,
	html_url TEXT NOT NULL,
	started_at INTEGER NOT NULL,
	completed_at INTEGER NOT NULL,
	fetched_at INTEGER NOT NULL
);
CREATE INDEX run_jobs_run ON run_jobs (run_id);
CREATE TABLE run_steps (
	job_id INTEGER NOT NULL REFERENCES run_jobs (id) ON DELETE CASCADE,
	number INTEGER NOT NULL,
	name TEXT NOT NULL,
	status TEXT NOT NULL,
	conclusion TEXT NOT NULL,
	started_at INTEGER NOT NULL,
	completed_at INTEGER NOT NULL,
	PRIMARY KEY (job_id, number)
);
CREATE TABLE blobs (
	job_id INTEGER PRIMARY KEY,
	name TEXT NOT NULL UNIQUE,
	size INTEGER NOT NULL,
	sha256 TEXT NOT NULL,
	dropped_lines INTEGER NOT NULL,
	truncated INTEGER NOT NULL,
	stopped_early INTEGER NOT NULL,
	created_at INTEGER NOT NULL,
	last_used_at INTEGER NOT NULL
);
CREATE INDEX blobs_used ON blobs (last_used_at);
CREATE TABLE local_runs (
	execution_id TEXT PRIMARY KEY,
	workflow_path TEXT NOT NULL DEFAULT '',
	job_id TEXT NOT NULL DEFAULT '',
	event TEXT NOT NULL DEFAULT '',
	started_at INTEGER NOT NULL DEFAULT 0,
	finished_at INTEGER NOT NULL DEFAULT 0,
	state TEXT NOT NULL,
	message TEXT NOT NULL DEFAULT '',
	act_version TEXT NOT NULL DEFAULT '',
	engine TEXT NOT NULL DEFAULT ''
);
CREATE INDEX local_runs_started ON local_runs (started_at DESC);
`
```

`core/internal/store/store.go`:

```go
// Package store keeps one workspace's data in SQLite: GitHub activity that
// can be downloaded again (the cache) and records that exist only on this
// Mac (local run history). A Store is one database behind one connection,
// so all of its reads and writes are serialized; a file lock keeps other
// processes out of the same directory.
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"modernc.org/sqlite"
)

const (
	databaseName    = "state.sqlite"
	lockName        = "lock"
	blobsDir        = "blobs"
	backupsDir      = "backups"
	recoveryDir     = "recovery"
	localBackupName = "local-data.sqlite"
	// pragmas apply to every connection: one serialized writer, WAL, full
	// fsync on commit, and immediate write transactions.
	pragmas = "_busy_timeout=5000&_foreign_keys=1&_journal_mode=WAL&_synchronous=FULL&_txlock=immediate"
)

// State says where a store keeps its data.
type State int

const (
	// Persistent stores live in their workspace directory.
	Persistent State = iota + 1
	// MemoryOnly stores live in this process only; Report.Note says why.
	MemoryOnly
)

// Report says how a store was opened. Note never holds a credential.
type Report struct {
	State State
	Note  string
}

type Options struct {
	// Now is the clock for recorded times; nil is time.Now.
	Now func() time.Time
}

// Store is safe for concurrent use; database/sql serializes callers on its
// single connection.
type Store struct {
	db     *sql.DB
	dir    string // "" for a memory store
	lock   *fileLock
	now    func() time.Time
	report Report

	closeOnce sync.Once
	closeErr  error
}

// Open opens the workspace database in dir, creating dir and the database
// when needed. A problem that keeps the file from being used never fails
// the open: the store then lives in memory and Report says why. dir "" asks
// for a memory store. The error is set only when not even a memory database
// can be made.
func Open(dir string, options Options) (*Store, error) {
	now := options.Now
	if now == nil {
		now = time.Now
	}
	if dir == "" {
		return openMemory(now, Report{State: MemoryOnly})
	}
	s, note := openDisk(dir, now)
	if s != nil {
		return s, nil
	}
	return openMemory(now, Report{State: MemoryOnly, Note: note})
}

func openMemory(now func() time.Time, report Report) (*Store, error) {
	db, err := openDSN("file::memory:?_busy_timeout=5000&_foreign_keys=1")
	if err != nil {
		return nil, err
	}
	s := &Store{db: db, now: now, report: report}
	if err := s.migrate(context.Background(), 0); err != nil {
		_ = db.Close()
		return nil, err
	}
	return s, nil
}

func openDisk(dir string, now func() time.Time) (*Store, string) {
	if err := makePrivateDir(dir); err != nil {
		return nil, "The workspace folder could not be created."
	}
	lock, err := acquireLock(filepath.Join(dir, lockName))
	if errors.Is(err, errLocked) {
		return nil, "In use by another copy of Runnir."
	}
	if err != nil {
		return nil, "The workspace folder could not be locked."
	}
	s := &Store{dir: dir, lock: lock, now: now, report: Report{State: Persistent}}
	if note, ok := s.openDatabase(context.Background()); !ok {
		if s.db != nil {
			_ = s.db.Close()
		}
		lock.release()
		return nil, note
	}
	return s, ""
}

// openDatabase opens, checks, recovers and migrates state.sqlite. Recovery
// is added in Task 2; here a damaged file only refuses the disk store.
func (s *Store) openDatabase(ctx context.Context) (string, bool) {
	path := filepath.Join(s.dir, databaseName)
	if info, err := os.Lstat(path); err == nil && !info.Mode().IsRegular() {
		return "The workspace database is not a regular file.", false
	}
	db, err := openFile(path)
	if err == nil {
		err = quickCheck(db)
	}
	if err != nil {
		if db != nil {
			_ = db.Close()
		}
		return "The workspace database could not be opened.", false
	}
	s.db = db
	_ = os.Chmod(path, 0o600)
	version, err := s.userVersion()
	if err != nil {
		return "The workspace database could not be read.", false
	}
	if version > len(migrations) {
		return fmt.Sprintf("Made by a newer version of Runnir (schema %d).", version), false
	}
	if err := s.migrate(ctx, version); err != nil {
		return "The workspace database could not be upgraded.", false
	}
	return "", true
}

// Report says how the store was opened.
func (s *Store) Report() Report { return s.report }

// Dir is the workspace directory; "" for a memory store.
func (s *Store) Dir() string { return s.dir }

// Close checkpoints the WAL, closes the database and releases the lock.
// Calling it again does nothing.
func (s *Store) Close() error {
	s.closeOnce.Do(func() {
		if s.dir != "" {
			_, _ = s.db.Exec("PRAGMA wal_checkpoint(TRUNCATE)")
		}
		s.closeErr = s.db.Close()
		if s.lock != nil {
			s.lock.release()
		}
	})
	return s.closeErr
}

func openFile(path string) (*sql.DB, error) {
	return openDSN((&url.URL{Scheme: "file", Path: path, RawQuery: pragmas}).String())
}

// openDSN opens a pool of exactly one long-lived connection, which is what
// makes the store a single serialized writer.
func openDSN(dsn string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(0)
	db.SetConnMaxIdleTime(0)
	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return db, nil
}

var errDamaged = errors.New("database is damaged")

func quickCheck(db *sql.DB) error {
	var result string
	if err := db.QueryRow("PRAGMA quick_check").Scan(&result); err != nil {
		return err
	}
	if result != "ok" {
		return errDamaged
	}
	return nil
}

// isDamaged recognizes SQLite's corrupt and not-a-database errors.
func isDamaged(err error) bool {
	if errors.Is(err, errDamaged) {
		return true
	}
	var sqliteErr *sqlite.Error
	if errors.As(err, &sqliteErr) {
		switch sqliteErr.Code() & 0xff {
		case 11, 26: // SQLITE_CORRUPT, SQLITE_NOTADB
			return true
		}
	}
	return false
}

func (s *Store) userVersion() (int, error) {
	var version int
	err := s.db.QueryRow("PRAGMA user_version").Scan(&version)
	return version, err
}

func (s *Store) migrate(ctx context.Context, from int) error {
	for version := from; version < len(migrations); version++ {
		tx, err := s.db.BeginTx(ctx, nil)
		if err != nil {
			return err
		}
		if _, err := tx.ExecContext(ctx, migrations[version]); err != nil {
			_ = tx.Rollback()
			return err
		}
		if _, err := tx.ExecContext(ctx, fmt.Sprintf("PRAGMA user_version = %d", version+1)); err != nil {
			_ = tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

// makePrivateDir creates dir with mode 0700 and refuses a symlink.
func makePrivateDir(dir string) error {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fmt.Errorf("%s is not a directory", filepath.Base(dir))
	}
	return os.Chmod(dir, 0o700)
}

// syncDir makes a rename in dir durable.
func syncDir(dir string) {
	if f, err := os.Open(dir); err == nil {
		_ = f.Sync()
		_ = f.Close()
	}
}

func millis(t time.Time) int64 {
	if t.IsZero() {
		return 0
	}
	return t.UnixMilli()
}

func fromMillis(ms int64) time.Time {
	if ms == 0 {
		return time.Time{}
	}
	return time.UnixMilli(ms).UTC()
}

// joinNotes joins sentences for a Report note.
func joinNotes(notes []string) string { return strings.Join(notes, " ") }
```

`core/internal/store/dirs.go`:

```go
package store

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var workspaceIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// ErrInvalidWorkspace means an id is not a workspace UUID.
var ErrInvalidWorkspace = errors.New("not a workspace id")

// NormalizeWorkspaceID lowercases a registry UUID and reports whether it is one.
func NormalizeWorkspaceID(id string) (string, bool) {
	id = strings.ToLower(id)
	return id, workspaceIDPattern.MatchString(id)
}

// WorkspaceDir is a workspace's directory under the Core's data directory.
// id must be normalized.
func WorkspaceDir(dataDir, id string) string {
	return filepath.Join(dataDir, "repositories", id)
}

// Workspaces lists the ids of workspace directories under dataDir.
func Workspaces(dataDir string) ([]string, error) {
	entries, err := os.ReadDir(filepath.Join(dataDir, "repositories"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var ids []string
	for _, entry := range entries {
		if entry.IsDir() && entry.Type()&os.ModeSymlink == 0 && workspaceIDPattern.MatchString(entry.Name()) {
			ids = append(ids, entry.Name())
		}
	}
	return ids, nil
}

// DeleteWorkspace removes a workspace's directory and everything in it,
// without following symlinks. The caller makes sure it is not open.
func DeleteWorkspace(dataDir, id string) error {
	id, ok := NormalizeWorkspaceID(id)
	if !ok {
		return ErrInvalidWorkspace
	}
	dir := WorkspaceDir(dataDir, id)
	info, err := os.Lstat(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return os.Remove(dir)
	}
	return os.RemoveAll(dir)
}
```

Then `go mod tidy` (now the import keeps the driver).

- [ ] **Step 5: Run the tests**

Run: `go test ./internal/store/ && CGO_ENABLED=0 go build ./...`
Expected: PASS; the build succeeds without CGO.

- [ ] **Step 6: Write ADR 0007**

Run `go list -m all` and read the LICENSE of every module the driver adds (module cache under `$HOME/go/pkg/mod`).

`docs/decisions/0007-workspace-sqlite.md`: title "0007 Workspace Database In The Go Core"; Status accepted 2026-10-22; Context (ADR 0003's open driver question, offline cache, hardened runtime without JIT entitlements); Decision (modernc.org/sqlite v1.60.1 via database/sql, `CGO_ENABLED=0`; one database per workspace under `<data-dir>/repositories/<workspaceId>/`; one connection per store; flock; WAL with `synchronous=FULL`; checkpoint on close; migrations by `user_version`); Alternatives (ncruces/go-sqlite3 + wazero: needs `com.apple.security.cs.allow-jit` for the compiler or a slow interpreter; mattn/go-sqlite3: needs CGO; JSON files: no queries or transactions); Licenses (each new module from `go.mod` with its license as read); Consequences (single-process ownership, memory fallback, what is not verified: signed build, power loss). The binary size before and after is measured and added in Task 13, once the Core links the store.

- [ ] **Step 7: Commit**

```bash
git add core/go.mod core/go.sum core/internal/store docs/decisions/0007-workspace-sqlite.md
git commit -m "Add a per-workspace SQLite store to the Core"
```

---

### Task 2: Local run history, backups and recovery

**Files:**
- Create: `core/internal/store/localruns.go`, `core/internal/store/recovery.go`
- Modify: `core/internal/store/store.go` (`openDatabase`, `Close`)
- Test: `core/internal/store/recovery_test.go`, `localruns_test.go`

**Interfaces:**
- Consumes: Task 1 `Store`, `openFile`, `isDamaged`, `migrations`.
- Produces:
  - `type LocalRun struct{ ExecutionID, WorkflowPath, JobID, Event string; StartedAt, FinishedAt time.Time; State, Message, ActVersion, Engine string }`
  - constants `LocalQueued = "queued"`, `LocalRunning = "running"`, `LocalSucceeded = "succeeded"`, `LocalFailed = "failed"`, `LocalCancelled = "cancelled"`, `LocalInterrupted = "interrupted"`
  - `(*Store).RecordLocalRun(ctx, LocalRun) error` — inserts, or fills details of an existing row without changing its state or times
  - `(*Store).UpdateLocalRun(ctx, executionID, state string, at time.Time, message string) error` — inserts a minimal row when missing; sets `finished_at` for terminal states
  - `(*Store).LocalRuns(ctx, limit int) ([]LocalRun, error)` — newest first
  - `const maxLocalRuns = 200`, `const keptMigrationCopies = 3`

- [ ] **Step 1: Write the failing tests**

`core/internal/store/localruns_test.go`:

```go
package store

import (
	"context"
	"fmt"
	"testing"
	"time"
)

func TestLocalRunsAreRecordedInAnyOrderAndBounded(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	at := fixedNow()
	// The execution's first event can arrive before the record.
	if err := s.UpdateLocalRun(ctx, "exec_1", LocalRunning, at, ""); err != nil {
		t.Fatal(err)
	}
	if err := s.RecordLocalRun(ctx, LocalRun{ExecutionID: "exec_1", WorkflowPath: ".github/workflows/ci.yml", JobID: "build",
		Event: "push", StartedAt: at, State: LocalQueued, ActVersion: "0.2.89", Engine: "OrbStack"}); err != nil {
		t.Fatal(err)
	}
	if err := s.UpdateLocalRun(ctx, "exec_1", LocalSucceeded, at.Add(time.Minute), ""); err != nil {
		t.Fatal(err)
	}
	runs, err := s.LocalRuns(ctx, 10)
	if err != nil || len(runs) != 1 {
		t.Fatalf("runs = %v, %v", runs, err)
	}
	got := runs[0]
	if got.State != LocalSucceeded || got.WorkflowPath != ".github/workflows/ci.yml" || got.Engine != "OrbStack" ||
		!got.FinishedAt.Equal(at.Add(time.Minute)) || !got.StartedAt.Equal(at) {
		t.Fatalf("run = %+v", got)
	}
	for i := 0; i < maxLocalRuns+5; i++ {
		_ = s.RecordLocalRun(ctx, LocalRun{ExecutionID: fmt.Sprintf("exec_%03d", i+2), StartedAt: at.Add(time.Duration(i+2) * time.Second), State: LocalSucceeded})
	}
	runs, _ = s.LocalRuns(ctx, 1000)
	if len(runs) != maxLocalRuns || runs[0].ExecutionID != fmt.Sprintf("exec_%03d", maxLocalRuns+6) {
		t.Fatalf("kept %d, newest %q", len(runs), runs[0].ExecutionID)
	}
}
```

`core/internal/store/recovery_test.go`:

```go
package store

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func record(t *testing.T, s *Store, id, state string) {
	t.Helper()
	if err := s.RecordLocalRun(context.Background(), LocalRun{ExecutionID: id, StartedAt: fixedNow(), State: state}); err != nil {
		t.Fatal(err)
	}
}

func recoveryDirs(t *testing.T, dir string) []string {
	t.Helper()
	entries, _ := os.ReadDir(filepath.Join(dir, "recovery"))
	var out []string
	for _, e := range entries {
		out = append(out, e.Name())
	}
	return out
}

func TestEveryLocalChangeIsBackedUp(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	record(t, s, "exec_1", LocalSucceeded)
	runs, err := readLocalBackup(filepath.Join(dir, "backups", "local-data.sqlite"))
	if err != nil || len(runs) != 1 || runs[0].ExecutionID != "exec_1" {
		t.Fatalf("backup = %v, %v", runs, err)
	}
	if _, err := os.Stat(filepath.Join(dir, "backups", "local-data.sqlite.tmp")); !os.IsNotExist(err) {
		t.Fatal("temporary backup left behind")
	}
}

func TestADamagedDatabaseIsKeptAsEvidenceAndLocalRunsSurvive(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	record(t, s, "exec_1", LocalSucceeded)
	record(t, s, "exec_2", LocalFailed)
	_ = s.Close()
	// Damage the header: SQLite then reports "file is not a database".
	path := filepath.Join(dir, "state.sqlite")
	data, _ := os.ReadFile(path)
	copy(data[:16], "garbage garbage!")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}

	again := openTest(t, dir)
	r := again.Report()
	if r.State != Persistent || !strings.Contains(r.Note, "damaged") || !strings.Contains(r.Note, "Restored 2 local run records") {
		t.Fatalf("report = %+v", r)
	}
	evidence := recoveryDirs(t, dir)
	if len(evidence) != 1 {
		t.Fatalf("recovery = %v", evidence)
	}
	kept, _ := os.ReadFile(filepath.Join(dir, "recovery", evidence[0], "state.sqlite"))
	if string(kept[:16]) != "garbage garbage!" {
		t.Fatal("evidence was changed")
	}
	runs, _ := again.LocalRuns(context.Background(), 10)
	if len(runs) != 2 {
		t.Fatalf("runs = %v", runs)
	}
}

func TestAMissingDatabaseIsRebuiltFromTheBackup(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	record(t, s, "exec_1", LocalSucceeded)
	_ = s.Close()
	for _, name := range []string{"state.sqlite", "state.sqlite-wal", "state.sqlite-shm"} {
		_ = os.Remove(filepath.Join(dir, name))
	}
	again := openTest(t, dir)
	if r := again.Report(); r.State != Persistent || r.Note != "The database was missing. Restored 1 local run records from the backup." {
		t.Fatalf("report = %+v", r)
	}
	if runs, _ := again.LocalRuns(context.Background(), 10); len(runs) != 1 {
		t.Fatalf("runs = %v", runs)
	}
}

func TestUnfinishedLocalRunsBecomeInterrupted(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	record(t, s, "exec_1", LocalRunning)
	record(t, s, "exec_2", LocalQueued)
	record(t, s, "exec_3", LocalSucceeded)
	_ = s.Close()
	again := openTest(t, dir)
	runs, _ := again.LocalRuns(context.Background(), 10)
	states := map[string]string{}
	for _, r := range runs {
		states[r.ExecutionID] = r.State
	}
	if states["exec_1"] != LocalInterrupted || states["exec_2"] != LocalInterrupted || states["exec_3"] != LocalSucceeded {
		t.Fatalf("states = %v", states)
	}
}

func TestAMigrationIsPrecededByACopyAndRolledBackOnFailure(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	record(t, s, "exec_1", LocalSucceeded)
	_ = s.Close()

	saved := migrations
	t.Cleanup(func() { migrations = saved })
	migrations = append(append([]string(nil), saved...), "CREATE TABLE extra (x INTEGER); INSERT INTO nowhere VALUES (1);")
	failed := openTest(t, dir)
	if r := failed.Report(); r.State != MemoryOnly || r.Note != "The workspace database could not be upgraded." {
		t.Fatalf("report = %+v", r)
	}
	_ = failed.Close()
	if _, err := os.Stat(filepath.Join(dir, "backups", "before-v1.sqlite")); err != nil {
		t.Fatal("no copy before the migration")
	}

	migrations = append(append([]string(nil), saved...), "CREATE TABLE extra (x INTEGER);")
	upgraded := openTest(t, dir)
	if v, _ := upgraded.userVersion(); v != len(saved)+1 || upgraded.Report().State != Persistent {
		t.Fatalf("version = %d, %+v", v, upgraded.Report())
	}
	if runs, _ := upgraded.LocalRuns(context.Background(), 10); len(runs) != 1 {
		t.Fatal("local runs lost in the migration")
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/store/`
Expected: FAIL to build (`undefined: LocalRun`).

- [ ] **Step 3: Implement local runs**

`core/internal/store/localruns.go`:

```go
package store

import (
	"context"
	"time"
)

// Local run states, as stored.
const (
	LocalQueued      = "queued"
	LocalRunning     = "running"
	LocalSucceeded   = "succeeded"
	LocalFailed      = "failed"
	LocalCancelled   = "cancelled"
	LocalInterrupted = "interrupted"
)

const maxLocalRuns = 200

// LocalRun is the summary of one local act run; its output is never stored.
type LocalRun struct {
	ExecutionID  string
	WorkflowPath string
	// JobID is the chosen job; empty ran every job.
	JobID      string
	Event      string
	StartedAt  time.Time
	FinishedAt time.Time
	State      string
	Message    string
	ActVersion string
	Engine     string
}

func terminal(state string) bool {
	switch state {
	case LocalSucceeded, LocalFailed, LocalCancelled, LocalInterrupted:
		return true
	}
	return false
}

// RecordLocalRun adds a run. When an event already created its row, only
// the details are filled in: the state and times events set are kept.
func (s *Store) RecordLocalRun(ctx context.Context, r LocalRun) error {
	_, err := s.db.ExecContext(ctx, `
INSERT INTO local_runs (execution_id, workflow_path, job_id, event, started_at, finished_at, state, message, act_version, engine)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (execution_id) DO UPDATE SET
	workflow_path = excluded.workflow_path, job_id = excluded.job_id, event = excluded.event,
	started_at = CASE WHEN local_runs.started_at = 0 THEN excluded.started_at ELSE local_runs.started_at END,
	act_version = excluded.act_version, engine = excluded.engine`,
		r.ExecutionID, r.WorkflowPath, r.JobID, r.Event, millis(r.StartedAt), millis(r.FinishedAt), r.State, r.Message, r.ActVersion, r.Engine)
	if err != nil {
		return err
	}
	return s.localChanged(ctx)
}

// UpdateLocalRun records a run's new state; terminal states also set when it
// finished. A run not recorded yet gets a row.
func (s *Store) UpdateLocalRun(ctx context.Context, executionID, state string, at time.Time, message string) error {
	finished := int64(0)
	if terminal(state) {
		finished = millis(at)
	}
	_, err := s.db.ExecContext(ctx, `
INSERT INTO local_runs (execution_id, started_at, finished_at, state, message) VALUES (?, ?, ?, ?, ?)
ON CONFLICT (execution_id) DO UPDATE SET
	state = excluded.state,
	finished_at = CASE WHEN excluded.finished_at = 0 THEN local_runs.finished_at ELSE excluded.finished_at END,
	message = CASE WHEN excluded.message = '' THEN local_runs.message ELSE excluded.message END`,
		executionID, millis(at), finished, state, message)
	if err != nil {
		return err
	}
	return s.localChanged(ctx)
}

// LocalRuns lists recorded runs, newest first.
func (s *Store) LocalRuns(ctx context.Context, limit int) ([]LocalRun, error) {
	rows, err := s.db.QueryContext(ctx, `
SELECT execution_id, workflow_path, job_id, event, started_at, finished_at, state, message, act_version, engine
FROM local_runs ORDER BY started_at DESC, execution_id DESC LIMIT ?`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LocalRun
	for rows.Next() {
		var r LocalRun
		var started, finished int64
		if err := rows.Scan(&r.ExecutionID, &r.WorkflowPath, &r.JobID, &r.Event, &started, &finished, &r.State, &r.Message, &r.ActVersion, &r.Engine); err != nil {
			return nil, err
		}
		r.StartedAt, r.FinishedAt = fromMillis(started), fromMillis(finished)
		out = append(out, r)
	}
	return out, rows.Err()
}

// localChanged enforces the budget and writes the backup of local data.
func (s *Store) localChanged(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, `
DELETE FROM local_runs WHERE execution_id IN (
	SELECT execution_id FROM local_runs ORDER BY started_at DESC, execution_id DESC LIMIT -1 OFFSET ?)`, maxLocalRuns); err != nil {
		return err
	}
	return s.writeLocalBackup(ctx)
}
```

- [ ] **Step 4: Implement backups and recovery**

`core/internal/store/recovery.go`:

```go
package store

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const keptMigrationCopies = 3

const localColumns = "execution_id, workflow_path, job_id, event, started_at, finished_at, state, message, act_version, engine"

// writeLocalBackup copies the local tables to backups/local-data.sqlite:
// a temporary file is written, synced and renamed, then the folder synced.
func (s *Store) writeLocalBackup(ctx context.Context) error {
	if s.dir == "" {
		return nil
	}
	dir := filepath.Join(s.dir, backupsDir)
	if err := makePrivateDir(dir); err != nil {
		return err
	}
	temporary := filepath.Join(dir, localBackupName+".tmp")
	_ = os.Remove(temporary)
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, "ATTACH DATABASE ? AS backup", temporary); err != nil {
		return err
	}
	_, copyErr := conn.ExecContext(ctx, "CREATE TABLE backup.local_runs AS SELECT "+localColumns+" FROM main.local_runs")
	_, detachErr := conn.ExecContext(context.Background(), "DETACH DATABASE backup")
	if err := errors.Join(copyErr, detachErr); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	if err := syncFile(temporary); err != nil {
		return err
	}
	if err := os.Rename(temporary, filepath.Join(dir, localBackupName)); err != nil {
		return err
	}
	syncDir(dir)
	return nil
}

func syncFile(path string) error {
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return err
	}
	_ = f.Chmod(0o600)
	syncErr := f.Sync()
	return errors.Join(syncErr, f.Close())
}

// readLocalBackup reads the local runs of a backup or of a salvage copy.
func readLocalBackup(path string) ([]LocalRun, error) {
	db, err := openDSN("file:" + filepath.ToSlash(path) + "?mode=ro&_busy_timeout=1000")
	if err != nil {
		return nil, err
	}
	defer db.Close()
	return scanLocalRuns(db, "SELECT "+localColumns+" FROM local_runs")
}

// scanLocalRuns keeps the rows read before an error: a damaged file may
// give some of them.
func scanLocalRuns(db *sql.DB, query string) ([]LocalRun, error) {
	rows, err := db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []LocalRun
	for rows.Next() {
		var r LocalRun
		var started, finished int64
		if err := rows.Scan(&r.ExecutionID, &r.WorkflowPath, &r.JobID, &r.Event, &started, &finished, &r.State, &r.Message, &r.ActVersion, &r.Engine); err != nil {
			return out, err
		}
		r.StartedAt, r.FinishedAt = fromMillis(started), fromMillis(finished)
		out = append(out, r)
	}
	return out, rows.Err()
}

// quarantine moves the database files to recovery/<stamp>/, never deleting
// them, and salvages local runs from a copy so the evidence stays as found.
func (s *Store) quarantine() (string, []LocalRun, error) {
	stamp := s.now().UTC().Format("20060102T150405.000000000Z")
	target := filepath.Join(s.dir, recoveryDir, stamp)
	if err := os.MkdirAll(target, 0o700); err != nil {
		return "", nil, err
	}
	moved := false
	for _, name := range []string{databaseName, databaseName + "-wal", databaseName + "-shm"} {
		from := filepath.Join(s.dir, name)
		if _, err := os.Lstat(from); errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err := os.Rename(from, filepath.Join(target, name)); err != nil {
			return "", nil, err
		}
		moved = true
	}
	syncDir(target)
	syncDir(s.dir)
	if !moved {
		_ = os.Remove(target)
		return "", nil, nil
	}
	return target, s.salvage(target), nil
}

func (s *Store) salvage(evidence string) []LocalRun {
	scratch, err := os.MkdirTemp(s.dir, ".salvage-")
	if err != nil {
		return nil
	}
	defer os.RemoveAll(scratch)
	for _, name := range []string{databaseName, databaseName + "-wal"} {
		if err := copyFile(filepath.Join(evidence, name), filepath.Join(scratch, name)); err != nil && name == databaseName {
			return nil
		}
	}
	db, err := openDSN("file:" + filepath.ToSlash(filepath.Join(scratch, databaseName)) + "?_busy_timeout=1000")
	if err != nil {
		return nil
	}
	defer db.Close()
	runs, _ := scanLocalRuns(db, "SELECT "+localColumns+" FROM local_runs")
	return runs
}

func copyFile(from, to string) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(to, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, in)
	return errors.Join(copyErr, out.Close())
}

// restoreLocal puts local runs back into a new database: the backup first,
// then rows salvaged from the damaged file, which are newer.
func (s *Store) restoreLocal(ctx context.Context, salvaged []LocalRun) (int, error) {
	byID := map[string]LocalRun{}
	backup, _ := readLocalBackup(filepath.Join(s.dir, backupsDir, localBackupName))
	for _, r := range backup {
		byID[r.ExecutionID] = r
	}
	for _, r := range salvaged {
		byID[r.ExecutionID] = r
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	for _, r := range byID {
		if _, err := tx.ExecContext(ctx, "INSERT OR REPLACE INTO local_runs ("+localColumns+") VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
			r.ExecutionID, r.WorkflowPath, r.JobID, r.Event, millis(r.StartedAt), millis(r.FinishedAt), r.State, r.Message, r.ActVersion, r.Engine); err != nil {
			_ = tx.Rollback()
			return 0, err
		}
	}
	return len(byID), tx.Commit()
}

// backupBeforeMigration copies the database with VACUUM INTO and keeps the
// newest keptMigrationCopies copies.
func (s *Store) backupBeforeMigration(ctx context.Context, version int) error {
	dir := filepath.Join(s.dir, backupsDir)
	if err := makePrivateDir(dir); err != nil {
		return err
	}
	target := filepath.Join(dir, fmt.Sprintf("before-v%d.sqlite", version))
	_ = os.Remove(target)
	if _, err := s.db.ExecContext(ctx, "VACUUM INTO ?", target); err != nil {
		return err
	}
	if err := syncFile(target); err != nil {
		return err
	}
	entries, _ := os.ReadDir(dir)
	var versions []int
	for _, e := range entries {
		name := e.Name()
		if v, err := strconv.Atoi(strings.TrimSuffix(strings.TrimPrefix(name, "before-v"), ".sqlite")); err == nil && strings.HasPrefix(name, "before-v") {
			versions = append(versions, v)
		}
	}
	sort.Sort(sort.Reverse(sort.IntSlice(versions)))
	for _, v := range versions[min(len(versions), keptMigrationCopies):] {
		_ = os.Remove(filepath.Join(dir, fmt.Sprintf("before-v%d.sqlite", v)))
	}
	return nil
}

func (s *Store) markInterrupted(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, "UPDATE local_runs SET state = ? WHERE state IN (?, ?)", LocalInterrupted, LocalQueued, LocalRunning)
	return err
}
```

Replace `openDatabase` in `store.go` with the recovering version:

```go
func (s *Store) openDatabase(ctx context.Context) (string, bool) {
	path := filepath.Join(s.dir, databaseName)
	info, statErr := os.Lstat(path)
	if statErr == nil && !info.Mode().IsRegular() {
		return "The workspace database is not a regular file.", false
	}
	missing := errors.Is(statErr, os.ErrNotExist)
	var notes []string
	var salvaged []LocalRun
	damaged := false
	if missing {
		// A WAL without its database cannot be applied; keep it as evidence.
		if _, err := os.Lstat(path + "-wal"); err == nil {
			if _, _, err := s.quarantine(); err != nil {
				return "Leftover database files could not be moved aside.", false
			}
		}
	} else {
		db, err := openFile(path)
		if err == nil {
			err = quickCheck(db)
		}
		switch {
		case err == nil:
			s.db = db
		case isDamaged(err):
			if db != nil {
				_ = db.Close()
			}
			evidence, rows, moveErr := s.quarantine()
			if moveErr != nil {
				return "The damaged workspace database could not be moved aside.", false
			}
			salvaged, damaged = rows, true
			notes = append(notes, fmt.Sprintf("The database was damaged; it was kept in %s and a new one was made.",
				filepath.Join(recoveryDir, filepath.Base(evidence))))
		default:
			if db != nil {
				_ = db.Close()
			}
			return "The workspace database could not be opened.", false
		}
	}
	fresh := s.db == nil
	if fresh {
		db, err := openFile(path)
		if err != nil {
			return "The workspace database could not be created.", false
		}
		s.db = db
	}
	_ = os.Chmod(path, 0o600)
	version, err := s.userVersion()
	if err != nil {
		return "The workspace database could not be read.", false
	}
	if version > len(migrations) {
		return fmt.Sprintf("Made by a newer version of Runnir (schema %d).", version), false
	}
	if version > 0 && version < len(migrations) {
		if err := s.backupBeforeMigration(ctx, version); err != nil {
			return "A copy of the workspace database could not be made before upgrading it.", false
		}
	}
	if err := s.migrate(ctx, version); err != nil {
		return "The workspace database could not be upgraded.", false
	}
	if fresh {
		restored, err := s.restoreLocal(ctx, salvaged)
		if err != nil {
			return "Local run records could not be restored.", false
		}
		switch {
		case damaged && restored > 0:
			notes = append(notes, fmt.Sprintf("Restored %d local run records.", restored))
		case missing && restored > 0:
			notes = append(notes, fmt.Sprintf("The database was missing. Restored %d local run records from the backup.", restored))
		}
	}
	if err := s.markInterrupted(ctx); err != nil {
		return "The workspace database could not be updated.", false
	}
	if err := s.writeLocalBackup(ctx); err != nil {
		notes = append(notes, "The backup of local data could not be written.")
	}
	s.report.Note = joinNotes(notes)
	return "", true
}
```

(Task 4 adds `s.cleanBlobs(ctx)` after `markInterrupted`.) Add `_ = s.writeLocalBackup(context.Background())` at the start of `Close` for disk stores, before the checkpoint.

- [ ] **Step 5: Run the tests**

Run: `go test ./internal/store/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add core/internal/store
git commit -m "Keep local run history with backups and recovery in the workspace store"
```

---

### Task 3: Activity cache, jobs cache, usage and Clear Cache

**Files:**
- Create: `core/internal/store/activity.go`, `jobs.go`, `usage.go`
- Test: `core/internal/store/activity_test.go`, `jobs_test.go`, `usage_test.go`

**Interfaces:**
- Consumes: `github.Run`, `github.Job`, `github.Step`, `github.Workflow` from `core/internal/github/client.go`.
- Produces:
  - `type Source struct{ ServerID, Repository string }` — `Repository` lowercased `owner/name`
  - `type RunsUpdate struct{ NotModified bool; Runs []github.Run; Complete bool; ETag string }`
  - `type WorkflowsUpdate struct{ NotModified bool; Workflows []github.Workflow; ETag string }`
  - `type Pass struct{ Source Source; At time.Time; OK bool; Access int32; RetryAfter time.Time; Runs *RunsUpdate; Workflows *WorkflowsUpdate }`
  - `type Activity struct{ Source Source; HasSource bool; Runs []github.Run; Workflows []github.Workflow; CheckedAt, SyncedAt, ChangedAt, RetryAfter time.Time; Access int32 }`
  - `(*Store).ApplySync(ctx, Pass) (changed bool, err error)`
  - `(*Store).Activity(ctx, limit int) (Activity, error)`
  - `(*Store).ETags(ctx, Source) (runs, workflows string, err error)`
  - `type CachedJobs struct{ Attempt int64; FetchedAt time.Time; Jobs []github.Job }`
  - `(*Store).Run(ctx, runID int64) (github.Run, bool, error)`, `(*Store).Jobs(ctx, runID int64) (CachedJobs, bool, error)`, `(*Store).PutJobs(ctx, runID, attempt int64, at time.Time, jobs []github.Job) error`, `(*Store).Job(ctx, jobID int64) (github.Job, bool, error)`
  - `type Usage struct{ DatabaseBytes, LogBytes uint64; CachedRuns, LocalRuns, RecoveryCopies int }`; `(*Store).Usage(ctx) (Usage, error)`; `(*Store).ClearCache(ctx) error`
  - `const maxRuns = 200`

- [ ] **Step 1: Write the failing tests**

`core/internal/store/activity_test.go`:

```go
package store

import (
	"context"
	"testing"
	"time"

	"runnir/core/internal/github"
)

var source = Source{ServerID: "", Repository: "o/r"}

func run(id int64, minute int, status string) github.Run {
	at := fixedNow().Add(time.Duration(minute) * time.Minute)
	return github.Run{ID: id, WorkflowID: 3, Name: "CI", RunNumber: id, RunAttempt: 1, Event: "push", Status: status,
		Branch: "main", HeadSHA: "abc", Actor: "octocat", CreatedAt: at, UpdatedAt: at}
}

func pass(at int, runs []github.Run, complete bool) Pass {
	return Pass{Source: source, At: fixedNow().Add(time.Duration(at) * time.Minute), OK: true, Access: 1,
		Runs:      &RunsUpdate{Runs: runs, Complete: complete, ETag: `"r"`},
		Workflows: &WorkflowsUpdate{Workflows: []github.Workflow{{ID: 3, Name: "CI", Path: ".github/workflows/ci.yml", State: "active"}}, ETag: `"w"`}}
}

func TestAPassIsStoredAndReadBackNewestFirst(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	changed, err := s.ApplySync(ctx, pass(0, []github.Run{run(2, 2, "completed"), run(1, 1, "completed")}, true))
	if err != nil || !changed {
		t.Fatalf("apply = %v, %v", changed, err)
	}
	a, err := s.Activity(ctx, 50)
	if err != nil || !a.HasSource || a.Source != source || len(a.Runs) != 2 || a.Runs[0].ID != 2 || len(a.Workflows) != 1 {
		t.Fatalf("activity = %+v, %v", a, err)
	}
	if !a.SyncedAt.Equal(fixedNow()) || !a.ChangedAt.Equal(fixedNow()) || !a.CheckedAt.Equal(fixedNow()) || a.Access != 1 {
		t.Fatalf("freshness = %+v", a)
	}
	if a.Runs[0].Actor != "octocat" || !a.Runs[0].CreatedAt.Equal(fixedNow().Add(2*time.Minute)) {
		t.Fatalf("run = %+v", a.Runs[0])
	}
	runsTag, workflowsTag, _ := s.ETags(ctx, source)
	if runsTag != `"r"` || workflowsTag != `"w"` {
		t.Fatalf("etags = %q %q", runsTag, workflowsTag)
	}
	if r, w, _ := s.ETags(ctx, Source{Repository: "other/repo"}); r != "" || w != "" {
		t.Fatal("etags leaked to another repository")
	}
}

func TestNotModifiedAndUnchangedPassesKeepChangedAt(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{run(1, 1, "completed")}, true))
	changed, _ := s.ApplySync(ctx, Pass{Source: source, At: fixedNow().Add(time.Minute), OK: true, Access: 1,
		Runs: &RunsUpdate{NotModified: true, ETag: `"r"`}, Workflows: &WorkflowsUpdate{NotModified: true, ETag: `"w"`}})
	if changed {
		t.Fatal("304 changed data")
	}
	changed, _ = s.ApplySync(ctx, pass(2, []github.Run{run(1, 1, "completed")}, true))
	if changed {
		t.Fatal("identical data counted as a change")
	}
	a, _ := s.Activity(ctx, 50)
	if !a.SyncedAt.Equal(fixedNow().Add(2*time.Minute)) || !a.ChangedAt.Equal(fixedNow()) {
		t.Fatalf("synced %v changed %v", a.SyncedAt, a.ChangedAt)
	}
}

func TestAFailedPassKeepsDataAndRecordsTheAttempt(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{run(1, 1, "completed")}, true))
	retry := fixedNow().Add(time.Hour)
	_, _ = s.ApplySync(ctx, Pass{Source: source, At: fixedNow().Add(time.Minute), Access: 7, RetryAfter: retry})
	a, _ := s.Activity(ctx, 50)
	if len(a.Runs) != 1 || a.Access != 7 || !a.RetryAfter.Equal(retry) || !a.CheckedAt.Equal(fixedNow().Add(time.Minute)) || !a.SyncedAt.Equal(fixedNow()) {
		t.Fatalf("activity = %+v", a)
	}
}

func TestRunsDeletedOnGitHubLeaveTheCache(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{run(5, 5, "completed"), run(4, 4, "completed"), run(3, 3, "completed"), run(1, 1, "completed")}, false))
	// Run 4 was deleted: newer than the page's oldest (3) but missing.
	// Run 1 is older than the page: it stays.
	changed, _ := s.ApplySync(ctx, pass(1, []github.Run{run(6, 6, "queued"), run(5, 5, "completed"), run(3, 3, "completed")}, false))
	a, _ := s.Activity(ctx, 50)
	ids := []int64{}
	for _, r := range a.Runs {
		ids = append(ids, r.ID)
	}
	if !changed || len(ids) != 4 || ids[0] != 6 || ids[1] != 5 || ids[2] != 3 || ids[3] != 1 {
		t.Fatalf("ids = %v", ids)
	}
	// A complete page is every run: anything else is gone.
	_, _ = s.ApplySync(ctx, pass(2, []github.Run{run(6, 6, "completed")}, true))
	if a, _ := s.Activity(ctx, 50); len(a.Runs) != 1 {
		t.Fatalf("complete page kept %d runs", len(a.Runs))
	}
}

func TestOnlyTheNewest200RunsAreKept(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	for batch := 0; batch < 5; batch++ {
		var page []github.Run
		for i := 49; i >= 0; i-- {
			id := int64(batch*50 + i + 1)
			page = append(page, run(id, int(id), "completed"))
		}
		_, _ = s.ApplySync(ctx, pass(batch, page, false))
	}
	a, _ := s.Activity(ctx, 1000)
	if len(a.Runs) != maxRuns || a.Runs[0].ID != 250 || a.Runs[maxRuns-1].ID != 51 {
		t.Fatalf("kept %d, newest %d, oldest %d", len(a.Runs), a.Runs[0].ID, a.Runs[len(a.Runs)-1].ID)
	}
}

func TestAnotherRepositoryReplacesTheCache(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{run(1, 1, "completed")}, true))
	other := Source{Repository: "o/other"}
	// A failed pass for the new repository changes nothing cached.
	_, _ = s.ApplySync(ctx, Pass{Source: other, At: fixedNow().Add(time.Minute), Access: 7})
	if a, _ := s.Activity(ctx, 50); a.Source != source || len(a.Runs) != 1 {
		t.Fatalf("after failure = %+v", a)
	}
	next := pass(2, []github.Run{run(9, 9, "completed")}, true)
	next.Source = other
	_, _ = s.ApplySync(ctx, next)
	a, _ := s.Activity(ctx, 50)
	if a.Source != other || len(a.Runs) != 1 || a.Runs[0].ID != 9 {
		t.Fatalf("after switch = %+v", a)
	}
}
```

`core/internal/store/jobs_test.go`:

```go
package store

import (
	"context"
	"testing"
	"time"

	"runnir/core/internal/github"
)

func TestJobsOfACachedRunAreStoredWithTheirSteps(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{run(7, 1, "completed")}, true))
	jobs := []github.Job{{ID: 11, Name: "build", Status: "completed", Conclusion: "success", StartedAt: fixedNow(), CompletedAt: fixedNow().Add(time.Minute),
		Steps: []github.Step{{Number: 1, Name: "Checkout", Status: "completed", Conclusion: "success", StartedAt: fixedNow()}}}}
	if err := s.PutJobs(ctx, 7, 1, fixedNow(), jobs); err != nil {
		t.Fatal(err)
	}
	cached, ok, err := s.Jobs(ctx, 7)
	if err != nil || !ok || cached.Attempt != 1 || !cached.FetchedAt.Equal(fixedNow()) || len(cached.Jobs) != 1 || len(cached.Jobs[0].Steps) != 1 {
		t.Fatalf("jobs = %+v, %v, %v", cached, ok, err)
	}
	job, ok, _ := s.Job(ctx, 11)
	if !ok || job.Steps[0].Name != "Checkout" || !job.CompletedAt.Equal(fixedNow().Add(time.Minute)) {
		t.Fatalf("job = %+v", job)
	}
	// Replacing keeps only the new attempt's jobs.
	_ = s.PutJobs(ctx, 7, 2, fixedNow(), []github.Job{{ID: 12, Name: "build", Status: "queued"}})
	cached, _, _ = s.Jobs(ctx, 7)
	if cached.Attempt != 2 || len(cached.Jobs) != 1 || cached.Jobs[0].ID != 12 {
		t.Fatalf("replaced = %+v", cached)
	}
	// Jobs of a run that is not cached are not stored.
	_ = s.PutJobs(ctx, 99, 1, fixedNow(), jobs)
	if _, ok, _ := s.Jobs(ctx, 99); ok {
		t.Fatal("stored jobs of an unknown run")
	}
	// Runs leaving the cache take their jobs and steps along.
	_, _ = s.ApplySync(ctx, pass(1, []github.Run{run(8, 2, "completed")}, true))
	if _, ok, _ := s.Job(ctx, 12); ok {
		t.Fatal("jobs of a deleted run remain")
	}
}
```

`core/internal/store/usage_test.go`:

```go
package store

import (
	"context"
	"testing"

	"runnir/core/internal/github"
)

func TestClearCacheKeepsLocalRuns(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{run(1, 1, "completed"), run(2, 2, "completed")}, true))
	record(t, s, "exec_1", LocalSucceeded)
	u, err := s.Usage(ctx)
	if err != nil || u.CachedRuns != 2 || u.LocalRuns != 1 || u.DatabaseBytes == 0 {
		t.Fatalf("usage = %+v, %v", u, err)
	}
	if err := s.ClearCache(ctx); err != nil {
		t.Fatal(err)
	}
	a, _ := s.Activity(ctx, 50)
	if a.HasSource || len(a.Runs) != 0 || len(a.Workflows) != 0 || !a.SyncedAt.IsZero() {
		t.Fatalf("after clear = %+v", a)
	}
	if r, w, _ := s.ETags(ctx, source); r != "" || w != "" {
		t.Fatal("etags survived")
	}
	if u, _ := s.Usage(ctx); u.CachedRuns != 0 || u.LocalRuns != 1 {
		t.Fatalf("usage after clear = %+v", u)
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/store/`
Expected: FAIL to build (`undefined: Pass`).

- [ ] **Step 3: Implement**

`core/internal/store/activity.go`:

```go
package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"runnir/core/internal/github"
)

const maxRuns = 200

// Source is the GitHub repository cached activity belongs to.
type Source struct {
	ServerID   string // "" is github.com
	Repository string // "owner/name", lowercased
}

// RunsUpdate is one read of the newest runs.
type RunsUpdate struct {
	NotModified bool
	Runs        []github.Run // newest first; empty when NotModified
	// Complete means the page held every run of the repository, so any
	// cached run missing from it was deleted.
	Complete bool
	ETag     string
}

// WorkflowsUpdate is one read of the repository's workflows.
type WorkflowsUpdate struct {
	NotModified bool
	Workflows   []github.Workflow
	ETag        string
}

// Pass is what one sync pass learned. Access is the caller's status code
// for the pass; the store keeps it without interpreting it. OK means every
// read got an answer (data or not modified).
type Pass struct {
	Source     Source
	At         time.Time
	OK         bool
	Access     int32
	RetryAfter time.Time
	Runs       *RunsUpdate
	Workflows  *WorkflowsUpdate
}

// Activity is the cached activity and what the last passes said.
type Activity struct {
	Source    Source
	HasSource bool
	Runs      []github.Run
	Workflows []github.Workflow
	CheckedAt time.Time
	SyncedAt  time.Time
	ChangedAt time.Time
	// Access and RetryAfter are the last pass's; Access is 0 before one.
	Access     int32
	RetryAfter time.Time
}

const (
	scopeActivity  = "activity"
	scopeRuns      = "runs"
	scopeWorkflows = "workflows"
)

// ApplySync stores a pass in one transaction and reports whether cached
// rows changed. Data for another repository than the cached one replaces
// the cache; a pass without data never does.
func (s *Store) ApplySync(ctx context.Context, p Pass) (bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	changed := false
	hasData := (p.Runs != nil && !p.Runs.NotModified) || (p.Workflows != nil && !p.Workflows.NotModified)
	if hasData {
		current, has, err := readSource(ctx, tx)
		if err != nil {
			return false, err
		}
		if !has || current != p.Source {
			if err := clearCache(ctx, tx); err != nil {
				return false, err
			}
			if _, err := tx.ExecContext(ctx, "INSERT INTO cache_source (id, server_id, repository) VALUES (1, ?, ?)", p.Source.ServerID, p.Source.Repository); err != nil {
				return false, err
			}
			changed = true
		}
	}
	if p.Runs != nil {
		if !p.Runs.NotModified {
			c, err := applyRuns(ctx, tx, p.Runs.Runs, p.Runs.Complete)
			if err != nil {
				return false, err
			}
			changed = changed || c
		}
		if err := setETag(ctx, tx, scopeRuns, p.Runs.ETag); err != nil {
			return false, err
		}
	}
	if p.Workflows != nil {
		if !p.Workflows.NotModified {
			c, err := applyWorkflows(ctx, tx, p.Workflows.Workflows)
			if err != nil {
				return false, err
			}
			changed = changed || c
		}
		if err := setETag(ctx, tx, scopeWorkflows, p.Workflows.ETag); err != nil {
			return false, err
		}
	}
	at := millis(p.At)
	if _, err := tx.ExecContext(ctx, `
INSERT INTO sync_state (scope, checked_at, synced_at, changed_at, access, retry_after) VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT (scope) DO UPDATE SET
	checked_at = excluded.checked_at,
	synced_at = CASE WHEN ? THEN excluded.checked_at ELSE sync_state.synced_at END,
	changed_at = CASE WHEN ? THEN excluded.checked_at ELSE sync_state.changed_at END,
	access = excluded.access, retry_after = excluded.retry_after`,
		scopeActivity, at, okMillis(p.OK, at), okMillis(changed, at), p.Access, millis(p.RetryAfter), p.OK, changed); err != nil {
		return false, err
	}
	return changed, tx.Commit()
}

func okMillis(ok bool, at int64) int64 {
	if ok {
		return at
	}
	return 0
}

func readSource(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}) (Source, bool, error) {
	var src Source
	err := q.QueryRowContext(ctx, "SELECT server_id, repository FROM cache_source WHERE id = 1").Scan(&src.ServerID, &src.Repository)
	if errors.Is(err, sql.ErrNoRows) {
		return Source{}, false, nil
	}
	return src, err == nil, err
}

func setETag(ctx context.Context, tx *sql.Tx, scope, etag string) error {
	_, err := tx.ExecContext(ctx, `INSERT INTO sync_state (scope, etag) VALUES (?, ?)
ON CONFLICT (scope) DO UPDATE SET etag = excluded.etag`, scope, etag)
	return err
}

func idsJSON[T any](items []T, id func(T) int64) string {
	ids := make([]int64, 0, len(items))
	for _, item := range items {
		ids = append(ids, id(item))
	}
	data, _ := json.Marshal(ids)
	return string(data)
}

func applyRuns(ctx context.Context, tx *sql.Tx, runs []github.Run, complete bool) (bool, error) {
	changed := false
	for _, r := range runs {
		result, err := tx.ExecContext(ctx, `
INSERT INTO runs (id, workflow_id, name, display_title, run_number, run_attempt, event, status, conclusion, branch, head_sha, actor, html_url, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (id) DO UPDATE SET
	workflow_id = excluded.workflow_id, name = excluded.name, display_title = excluded.display_title,
	run_number = excluded.run_number, run_attempt = excluded.run_attempt, event = excluded.event,
	status = excluded.status, conclusion = excluded.conclusion, branch = excluded.branch,
	head_sha = excluded.head_sha, actor = excluded.actor, html_url = excluded.html_url,
	created_at = excluded.created_at, updated_at = excluded.updated_at
WHERE (runs.workflow_id, runs.name, runs.display_title, runs.run_number, runs.run_attempt, runs.event, runs.status,
	runs.conclusion, runs.branch, runs.head_sha, runs.actor, runs.html_url, runs.created_at, runs.updated_at)
	<> (excluded.workflow_id, excluded.name, excluded.display_title, excluded.run_number, excluded.run_attempt, excluded.event,
	excluded.status, excluded.conclusion, excluded.branch, excluded.head_sha, excluded.actor, excluded.html_url,
	excluded.created_at, excluded.updated_at)`,
			r.ID, r.WorkflowID, r.Name, r.DisplayTitle, r.RunNumber, r.RunAttempt, r.Event, r.Status, r.Conclusion,
			r.Branch, r.HeadSHA, r.Actor, r.HTMLURL, millis(r.CreatedAt), millis(r.UpdatedAt))
		if err != nil {
			return false, err
		}
		if n, _ := result.RowsAffected(); n > 0 {
			changed = true
		}
	}
	ids := idsJSON(runs, func(r github.Run) int64 { return r.ID })
	var result sql.Result
	var err error
	switch {
	case complete:
		result, err = tx.ExecContext(ctx, "DELETE FROM runs WHERE id NOT IN (SELECT value FROM json_each(?))", ids)
	case len(runs) > 0:
		oldest := runs[0].CreatedAt
		for _, r := range runs {
			if r.CreatedAt.Before(oldest) {
				oldest = r.CreatedAt
			}
		}
		result, err = tx.ExecContext(ctx, "DELETE FROM runs WHERE created_at > ? AND id NOT IN (SELECT value FROM json_each(?))", millis(oldest), ids)
	}
	if err != nil {
		return false, err
	}
	if result != nil {
		if n, _ := result.RowsAffected(); n > 0 {
			changed = true
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM runs WHERE id IN (
	SELECT id FROM runs ORDER BY created_at DESC, id DESC LIMIT -1 OFFSET ?)`, maxRuns); err != nil {
		return false, err
	}
	return changed, nil
}

func applyWorkflows(ctx context.Context, tx *sql.Tx, workflows []github.Workflow) (bool, error) {
	changed := false
	for i, w := range workflows {
		result, err := tx.ExecContext(ctx, `
INSERT INTO remote_workflows (id, position, name, path, state, html_url) VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT (id) DO UPDATE SET position = excluded.position, name = excluded.name, path = excluded.path,
	state = excluded.state, html_url = excluded.html_url
WHERE (remote_workflows.position, remote_workflows.name, remote_workflows.path, remote_workflows.state, remote_workflows.html_url)
	<> (excluded.position, excluded.name, excluded.path, excluded.state, excluded.html_url)`,
			w.ID, i, w.Name, w.Path, w.State, w.HTMLURL)
		if err != nil {
			return false, err
		}
		if n, _ := result.RowsAffected(); n > 0 {
			changed = true
		}
	}
	result, err := tx.ExecContext(ctx, "DELETE FROM remote_workflows WHERE id NOT IN (SELECT value FROM json_each(?))",
		idsJSON(workflows, func(w github.Workflow) int64 { return w.ID }))
	if err != nil {
		return false, err
	}
	if n, _ := result.RowsAffected(); n > 0 {
		changed = true
	}
	return changed, nil
}

// Activity reads the cached activity: up to limit newest runs.
func (s *Store) Activity(ctx context.Context, limit int) (Activity, error) {
	var a Activity
	var err error
	if a.Source, a.HasSource, err = readSource(ctx, s.db); err != nil {
		return Activity{}, err
	}
	if a.Runs, err = s.runs(ctx, "ORDER BY created_at DESC, id DESC LIMIT ?", limit); err != nil {
		return Activity{}, err
	}
	rows, err := s.db.QueryContext(ctx, "SELECT id, name, path, state, html_url FROM remote_workflows ORDER BY position, id")
	if err != nil {
		return Activity{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var w github.Workflow
		if err := rows.Scan(&w.ID, &w.Name, &w.Path, &w.State, &w.HTMLURL); err != nil {
			return Activity{}, err
		}
		a.Workflows = append(a.Workflows, w)
	}
	if err := rows.Err(); err != nil {
		return Activity{}, err
	}
	var checked, synced, changed, retry int64
	err = s.db.QueryRowContext(ctx, "SELECT checked_at, synced_at, changed_at, access, retry_after FROM sync_state WHERE scope = ?", scopeActivity).
		Scan(&checked, &synced, &changed, &a.Access, &retry)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return Activity{}, err
	}
	a.CheckedAt, a.SyncedAt, a.ChangedAt, a.RetryAfter = fromMillis(checked), fromMillis(synced), fromMillis(changed), fromMillis(retry)
	return a, nil
}

const runColumns = "id, workflow_id, name, display_title, run_number, run_attempt, event, status, conclusion, branch, head_sha, actor, html_url, created_at, updated_at"

func (s *Store) runs(ctx context.Context, tail string, args ...any) ([]github.Run, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT "+runColumns+" FROM runs "+tail, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []github.Run
	for rows.Next() {
		var r github.Run
		var created, updated int64
		if err := rows.Scan(&r.ID, &r.WorkflowID, &r.Name, &r.DisplayTitle, &r.RunNumber, &r.RunAttempt, &r.Event, &r.Status,
			&r.Conclusion, &r.Branch, &r.HeadSHA, &r.Actor, &r.HTMLURL, &created, &updated); err != nil {
			return nil, err
		}
		r.CreatedAt, r.UpdatedAt = fromMillis(created), fromMillis(updated)
		out = append(out, r)
	}
	return out, rows.Err()
}

// ETags returns the stored ETags when the cache holds this repository's
// data, otherwise empty strings, so another repository's never match.
func (s *Store) ETags(ctx context.Context, src Source) (string, string, error) {
	current, has, err := readSource(ctx, s.db)
	if err != nil || !has || current != src {
		return "", "", err
	}
	tags := map[string]string{}
	rows, err := s.db.QueryContext(ctx, "SELECT scope, etag FROM sync_state WHERE scope IN (?, ?)", scopeRuns, scopeWorkflows)
	if err != nil {
		return "", "", err
	}
	defer rows.Close()
	for rows.Next() {
		var scope, etag string
		if err := rows.Scan(&scope, &etag); err != nil {
			return "", "", err
		}
		tags[scope] = etag
	}
	return tags[scopeRuns], tags[scopeWorkflows], rows.Err()
}

func clearCache(ctx context.Context, tx *sql.Tx) error {
	for _, statement := range []string{"DELETE FROM runs", "DELETE FROM remote_workflows", "DELETE FROM sync_state", "DELETE FROM cache_source"} {
		if _, err := tx.ExecContext(ctx, statement); err != nil {
			return err
		}
	}
	return nil
}
```

`core/internal/store/jobs.go`:

```go
package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"runnir/core/internal/github"
)

// CachedJobs are a run's jobs as last read, for one attempt.
type CachedJobs struct {
	Attempt   int64
	FetchedAt time.Time
	Jobs      []github.Job
}

// Run returns a cached run.
func (s *Store) Run(ctx context.Context, runID int64) (github.Run, bool, error) {
	runs, err := s.runs(ctx, "WHERE id = ?", runID)
	if err != nil || len(runs) == 0 {
		return github.Run{}, false, err
	}
	return runs[0], true, nil
}

// PutJobs replaces a cached run's jobs. Jobs of a run that is not cached
// are not stored: they would have nothing to belong to.
func (s *Store) PutJobs(ctx context.Context, runID, attempt int64, at time.Time, jobs []github.Job) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	var exists int
	if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM runs WHERE id = ?", runID).Scan(&exists); err != nil || exists == 0 {
		return err
	}
	if _, err := tx.ExecContext(ctx, "DELETE FROM run_jobs WHERE run_id = ?", runID); err != nil {
		return err
	}
	for i, j := range jobs {
		if _, err := tx.ExecContext(ctx, `INSERT OR REPLACE INTO run_jobs
(id, run_id, attempt, position, name, status, conclusion, html_url, started_at, completed_at, fetched_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			j.ID, runID, attempt, i, j.Name, j.Status, j.Conclusion, j.HTMLURL, millis(j.StartedAt), millis(j.CompletedAt), millis(at)); err != nil {
			return err
		}
		for _, step := range j.Steps {
			if _, err := tx.ExecContext(ctx, `INSERT OR REPLACE INTO run_steps
(job_id, number, name, status, conclusion, started_at, completed_at) VALUES (?, ?, ?, ?, ?, ?, ?)`,
				j.ID, step.Number, step.Name, step.Status, step.Conclusion, millis(step.StartedAt), millis(step.CompletedAt)); err != nil {
				return err
			}
		}
	}
	return tx.Commit()
}

// Jobs returns a run's cached jobs.
func (s *Store) Jobs(ctx context.Context, runID int64) (CachedJobs, bool, error) {
	jobs, attempt, fetched, err := s.jobs(ctx, "WHERE run_id = ? ORDER BY position", runID)
	if err != nil || len(jobs) == 0 {
		return CachedJobs{}, false, err
	}
	return CachedJobs{Attempt: attempt, FetchedAt: fetched, Jobs: jobs}, true, nil
}

// Job returns one cached job with its steps.
func (s *Store) Job(ctx context.Context, jobID int64) (github.Job, bool, error) {
	jobs, _, _, err := s.jobs(ctx, "WHERE id = ?", jobID)
	if err != nil || len(jobs) == 0 {
		return github.Job{}, false, err
	}
	return jobs[0], true, nil
}

// jobs reads jobs and their steps; attempt and fetched are the first job's,
// which every job of a run shares.
func (s *Store) jobs(ctx context.Context, tail string, args ...any) ([]github.Job, int64, time.Time, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT id, attempt, name, status, conclusion, html_url, started_at, completed_at, fetched_at FROM run_jobs "+tail, args...)
	if err != nil {
		return nil, 0, time.Time{}, err
	}
	var jobs []github.Job
	var attempt, fetched int64
	for rows.Next() {
		var j github.Job
		var started, completed int64
		if err := rows.Scan(&j.ID, &attempt, &j.Name, &j.Status, &j.Conclusion, &j.HTMLURL, &started, &completed, &fetched); err != nil {
			rows.Close()
			return nil, 0, time.Time{}, err
		}
		j.StartedAt, j.CompletedAt = fromMillis(started), fromMillis(completed)
		jobs = append(jobs, j)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return nil, 0, time.Time{}, err
	}
	for i := range jobs {
		steps, err := s.db.QueryContext(ctx, "SELECT number, name, status, conclusion, started_at, completed_at FROM run_steps WHERE job_id = ? ORDER BY number", jobs[i].ID)
		if err != nil {
			return nil, 0, time.Time{}, err
		}
		for steps.Next() {
			var step github.Step
			var started, completed int64
			if err := steps.Scan(&step.Number, &step.Name, &step.Status, &step.Conclusion, &started, &completed); err != nil {
				steps.Close()
				return nil, 0, time.Time{}, err
			}
			step.StartedAt, step.CompletedAt = fromMillis(started), fromMillis(completed)
			jobs[i].Steps = append(jobs[i].Steps, step)
		}
		steps.Close()
		if err := steps.Err(); err != nil && !errors.Is(err, sql.ErrNoRows) {
			return nil, 0, time.Time{}, err
		}
	}
	return jobs, attempt, fromMillis(fetched), nil
}
```

`core/internal/store/usage.go`:

```go
package store

import (
	"context"
	"os"
	"path/filepath"
)

// Usage is what a workspace keeps on this Mac.
type Usage struct {
	DatabaseBytes  uint64 // state.sqlite and its WAL; the in-memory size for a memory store
	LogBytes       uint64
	CachedRuns     int
	LocalRuns      int
	RecoveryCopies int
}

func (s *Store) Usage(ctx context.Context) (Usage, error) {
	var u Usage
	var logBytes int64
	if err := s.db.QueryRowContext(ctx, `SELECT (SELECT COUNT(*) FROM runs), (SELECT COUNT(*) FROM local_runs),
	(SELECT COALESCE(SUM(size), 0) FROM blobs)`).Scan(&u.CachedRuns, &u.LocalRuns, &logBytes); err != nil {
		return Usage{}, err
	}
	u.LogBytes = uint64(logBytes)
	if s.dir == "" {
		var pages, size int64
		_ = s.db.QueryRowContext(ctx, "PRAGMA page_count").Scan(&pages)
		_ = s.db.QueryRowContext(ctx, "PRAGMA page_size").Scan(&size)
		u.DatabaseBytes = uint64(pages * size)
		return u, nil
	}
	for _, name := range []string{databaseName, databaseName + "-wal"} {
		if info, err := os.Lstat(filepath.Join(s.dir, name)); err == nil {
			u.DatabaseBytes += uint64(info.Size())
		}
	}
	if entries, err := os.ReadDir(filepath.Join(s.dir, recoveryDir)); err == nil {
		for _, e := range entries {
			if e.IsDir() {
				u.RecoveryCopies++
			}
		}
	}
	return u, nil
}

// ClearCache deletes everything that can be downloaded again: runs, jobs,
// steps, workflows, sync state and kept logs. Local runs, backups and
// recovery copies stay.
func (s *Store) ClearCache(ctx context.Context) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if err := clearCache(ctx, tx); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return s.DeleteLogs(ctx)
}
```

(`DeleteLogs` comes in Task 4; until then add a stub in `usage.go`: `func (s *Store) DeleteLogs(context.Context) error { return nil }`, removed in Task 4.)

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/store/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/store
git commit -m "Cache runs, workflows and jobs in the workspace store"
```

---

### Task 4: Kept job logs (blobs)

**Files:**
- Create: `core/internal/store/blobs.go`
- Modify: `core/internal/store/usage.go` (remove the `DeleteLogs` stub), `core/internal/store/store.go` (`cleanBlobs` in `openDatabase`)
- Test: `core/internal/store/blobs_test.go`

**Interfaces:**
- Produces:
  - `type LogMeta struct{ DroppedLines int; Truncated, StoppedEarly bool }`
  - `(*Store).PutLog(ctx, jobID int64, data []byte, meta LogMeta) error` — no-op for a memory store; `ErrBlobTooLarge` over 3 MiB
  - `(*Store).Log(ctx, jobID int64) ([]byte, LogMeta, bool, error)` — touches `last_used_at`; drops an invalid entry and reports not found
  - `(*Store).DeleteLogs(ctx) error`
  - `func DeleteKeptLogs(dataDir, id string) error` — closed workspaces; rows go when the store opens next
  - `const maxBlobBytes = 3 << 20`, `const logBudget = 100 << 20` (package variables `logBudgetBytes` for tests)

- [ ] **Step 1: Write the failing tests**

`core/internal/store/blobs_test.go`:

```go
package store

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestALogIsKeptAndReadBack(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	ctx := context.Background()
	data := []byte("line one\nline two\n")
	if err := s.PutLog(ctx, 11, data, LogMeta{DroppedLines: 3, Truncated: true}); err != nil {
		t.Fatal(err)
	}
	got, meta, ok, err := s.Log(ctx, 11)
	if err != nil || !ok || !bytes.Equal(got, data) || meta.DroppedLines != 3 || !meta.Truncated {
		t.Fatalf("log = %q %+v %v %v", got, meta, ok, err)
	}
	entries, _ := os.ReadDir(filepath.Join(dir, "blobs"))
	if len(entries) != 1 || len(entries[0].Name()) != 64+len(".log") {
		t.Fatalf("blobs = %v", entries)
	}
	info, _ := os.Stat(filepath.Join(dir, "blobs", entries[0].Name()))
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", info.Mode())
	}
	if u, _ := s.Usage(ctx); u.LogBytes != uint64(len(data)) {
		t.Fatalf("usage = %+v", u)
	}
}

func TestAChangedOrReplacedBlobIsNotTrusted(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	ctx := context.Background()
	_ = s.PutLog(ctx, 11, []byte("original"), LogMeta{})
	entries, _ := os.ReadDir(filepath.Join(dir, "blobs"))
	path := filepath.Join(dir, "blobs", entries[0].Name())
	_ = os.WriteFile(path, []byte("tampered"), 0o600)
	if _, _, ok, _ := s.Log(ctx, 11); ok {
		t.Fatal("tampered blob served")
	}
	_ = s.PutLog(ctx, 12, []byte("second"), LogMeta{})
	entries, _ = os.ReadDir(filepath.Join(dir, "blobs"))
	path = filepath.Join(dir, "blobs", entries[0].Name())
	outside := filepath.Join(t.TempDir(), "secret")
	_ = os.WriteFile(outside, []byte("second"), 0o600)
	_ = os.Remove(path)
	_ = os.Symlink(outside, path)
	if _, _, ok, _ := s.Log(ctx, 12); ok {
		t.Fatal("symlinked blob served")
	}
}

func TestLogsStayWithinTheBudgetOldestUseFirst(t *testing.T) {
	saved := logBudgetBytes
	logBudgetBytes = 25
	t.Cleanup(func() { logBudgetBytes = saved })
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	_ = s.PutLog(ctx, 1, bytes.Repeat([]byte("a"), 10), LogMeta{})
	_ = s.PutLog(ctx, 2, bytes.Repeat([]byte("b"), 10), LogMeta{})
	_, _, _, _ = s.Log(ctx, 1) // 1 is now used more recently than 2
	_ = s.PutLog(ctx, 3, bytes.Repeat([]byte("c"), 10), LogMeta{})
	if _, _, ok, _ := s.Log(ctx, 2); ok {
		t.Fatal("least recently used log kept")
	}
	if _, _, ok, _ := s.Log(ctx, 1); !ok {
		t.Fatal("recently used log dropped")
	}
	if err := s.PutLog(ctx, 4, make([]byte, maxBlobBytes+1), LogMeta{}); err != ErrBlobTooLarge {
		t.Fatalf("oversize = %v", err)
	}
}

func TestOrphansAreCleanedAndLogsDeleted(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	ctx := context.Background()
	_ = s.PutLog(ctx, 1, []byte("kept"), LogMeta{})
	stray := filepath.Join(dir, "blobs", "stray.tmp")
	_ = os.WriteFile(stray, []byte("x"), 0o600)
	_ = s.Close()
	again := openTest(t, dir)
	if _, err := os.Stat(stray); !os.IsNotExist(err) {
		t.Fatal("stray file kept")
	}
	if _, _, ok, _ := again.Log(ctx, 1); !ok {
		t.Fatal("valid blob removed")
	}
	if err := again.DeleteLogs(ctx); err != nil {
		t.Fatal(err)
	}
	if entries, _ := os.ReadDir(filepath.Join(dir, "blobs")); len(entries) != 0 {
		t.Fatalf("left %v", entries)
	}
	if _, _, ok, _ := again.Log(ctx, 1); ok {
		t.Fatal("deleted log served")
	}
}

func TestMemoryStoresKeepNoLogs(t *testing.T) {
	s := openTest(t, "")
	ctx := context.Background()
	if err := s.PutLog(ctx, 1, []byte("x"), LogMeta{}); err != nil {
		t.Fatal(err)
	}
	if _, _, ok, _ := s.Log(ctx, 1); ok {
		t.Fatal("memory store kept a log")
	}
}

func TestKeptLogsOfAClosedWorkspaceAreDeleted(t *testing.T) {
	data := t.TempDir()
	id := "5ce88ff0-5c16-43b3-8f20-8e33e852b019"
	s := openTest(t, WorkspaceDir(data, id))
	_ = s.PutLog(context.Background(), 1, []byte("x"), LogMeta{})
	_ = s.Close()
	if err := DeleteKeptLogs(data, id); err != nil {
		t.Fatal(err)
	}
	if entries, _ := os.ReadDir(filepath.Join(WorkspaceDir(data, id), "blobs")); len(entries) != 0 {
		t.Fatalf("left %v", entries)
	}
	again := openTest(t, WorkspaceDir(data, id))
	if u, _ := again.Usage(context.Background()); u.LogBytes != 0 {
		t.Fatalf("rows kept: %+v", u)
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/store/ -run 'Log|Blob|Orphan'`
Expected: FAIL to build (`undefined: LogMeta`).

- [ ] **Step 3: Implement**

`core/internal/store/blobs.go`:

```go
package store

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
)

const maxBlobBytes = 3 << 20

// logBudgetBytes bounds a workspace's kept logs; a variable for tests.
var logBudgetBytes int64 = 100 << 20

var ErrBlobTooLarge = errors.New("log is too large to keep")

var blobNamePattern = regexp.MustCompile(`^[0-9a-f]{64}\.log$`)

// LogMeta is what a kept log needs besides its text.
type LogMeta struct {
	DroppedLines int
	Truncated    bool
	StoppedEarly bool
}

func (s *Store) blobDir() string { return filepath.Join(s.dir, blobsDir) }

// PutLog keeps a completed job's log. The file is named by the SHA-256 of
// the job id and the content, written to a temporary file, synced and
// renamed; then the row is written and the budget enforced.
func (s *Store) PutLog(ctx context.Context, jobID int64, data []byte, meta LogMeta) error {
	if s.dir == "" {
		return nil
	}
	if len(data) > maxBlobBytes {
		return ErrBlobTooLarge
	}
	dir := s.blobDir()
	if err := makePrivateDir(dir); err != nil {
		return err
	}
	content := sha256.Sum256(data)
	nameSum := sha256.Sum256(append([]byte(fmt.Sprintf("%d\n", jobID)), data...))
	name := hex.EncodeToString(nameSum[:]) + ".log"
	temporary, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	_, writeErr := temporary.Write(data)
	syncErr := temporary.Sync()
	closeErr := temporary.Close()
	if err := errors.Join(writeErr, syncErr, closeErr, os.Chmod(temporary.Name(), 0o600)); err != nil {
		_ = os.Remove(temporary.Name())
		return err
	}
	if err := os.Rename(temporary.Name(), filepath.Join(dir, name)); err != nil {
		_ = os.Remove(temporary.Name())
		return err
	}
	syncDir(dir)

	var previous string
	_ = s.db.QueryRowContext(ctx, "SELECT name FROM blobs WHERE job_id = ?", jobID).Scan(&previous)
	now := millis(s.now())
	if _, err := s.db.ExecContext(ctx, `INSERT OR REPLACE INTO blobs
(job_id, name, size, sha256, dropped_lines, truncated, stopped_early, created_at, last_used_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		jobID, name, len(data), hex.EncodeToString(content[:]), meta.DroppedLines, meta.Truncated, meta.StoppedEarly, now, now); err != nil {
		return err
	}
	if previous != "" && previous != name {
		s.removeBlobFile(previous)
	}
	return s.enforceLogBudget(ctx)
}

func (s *Store) enforceLogBudget(ctx context.Context) error {
	rows, err := s.db.QueryContext(ctx, "SELECT job_id, name, size FROM blobs ORDER BY last_used_at DESC, job_id DESC")
	if err != nil {
		return err
	}
	type entry struct {
		job  int64
		name string
	}
	var total int64
	var drop []entry
	for rows.Next() {
		var e entry
		var size int64
		if err := rows.Scan(&e.job, &e.name, &size); err != nil {
			rows.Close()
			return err
		}
		total += size
		if total > logBudgetBytes {
			drop = append(drop, e)
		}
	}
	rows.Close()
	for _, e := range drop {
		if _, err := s.db.ExecContext(ctx, "DELETE FROM blobs WHERE job_id = ?", e.job); err != nil {
			return err
		}
		s.removeBlobFile(e.name)
	}
	return rows.Err()
}

// Log returns a kept log. A row whose file is missing, not a regular file,
// or no longer matches its size and checksum is dropped and not served.
func (s *Store) Log(ctx context.Context, jobID int64) ([]byte, LogMeta, bool, error) {
	if s.dir == "" {
		return nil, LogMeta{}, false, nil
	}
	var name, sum string
	var size int64
	var meta LogMeta
	err := s.db.QueryRowContext(ctx, "SELECT name, size, sha256, dropped_lines, truncated, stopped_early FROM blobs WHERE job_id = ?", jobID).
		Scan(&name, &size, &sum, &meta.DroppedLines, &meta.Truncated, &meta.StoppedEarly)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, LogMeta{}, false, nil
	}
	if err != nil {
		return nil, LogMeta{}, false, err
	}
	data, ok := s.readBlob(name, size, sum)
	if !ok {
		_, _ = s.db.ExecContext(ctx, "DELETE FROM blobs WHERE job_id = ?", jobID)
		s.removeBlobFile(name)
		return nil, LogMeta{}, false, nil
	}
	_, _ = s.db.ExecContext(ctx, "UPDATE blobs SET last_used_at = ? WHERE job_id = ?", millis(s.now()), jobID)
	return data, meta, true, nil
}

func (s *Store) readBlob(name string, size int64, sum string) ([]byte, bool) {
	if !blobNamePattern.MatchString(name) || size > maxBlobBytes {
		return nil, false
	}
	path := filepath.Join(s.blobDir(), name)
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() != size {
		return nil, false
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, false
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxBlobBytes+1))
	if err != nil || int64(len(data)) != size {
		return nil, false
	}
	actual := sha256.Sum256(data)
	return data, hex.EncodeToString(actual[:]) == sum
}

// removeBlobFile removes a file in blobs/ by name; anything that is not a
// plain name of that folder is ignored.
func (s *Store) removeBlobFile(name string) {
	if name == "" || filepath.Base(name) != name || name == "." || name == ".." {
		return
	}
	_ = os.Remove(filepath.Join(s.blobDir(), name))
}

// DeleteLogs removes every kept log.
func (s *Store) DeleteLogs(ctx context.Context) error {
	if _, err := s.db.ExecContext(ctx, "DELETE FROM blobs"); err != nil {
		return err
	}
	if s.dir == "" {
		return nil
	}
	entries, err := os.ReadDir(s.blobDir())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	for _, e := range entries {
		s.removeBlobFile(e.Name())
	}
	return err
}

// cleanBlobs drops rows whose files are gone and files without rows.
func (s *Store) cleanBlobs(ctx context.Context) error {
	if s.dir == "" {
		return nil
	}
	rows, err := s.db.QueryContext(ctx, "SELECT job_id, name, size FROM blobs")
	if err != nil {
		return err
	}
	known := map[string]bool{}
	var missing []int64
	for rows.Next() {
		var job, size int64
		var name string
		if err := rows.Scan(&job, &name, &size); err != nil {
			rows.Close()
			return err
		}
		info, statErr := os.Lstat(filepath.Join(s.blobDir(), name))
		if !blobNamePattern.MatchString(name) || statErr != nil || !info.Mode().IsRegular() || info.Size() != size {
			missing = append(missing, job)
			continue
		}
		known[name] = true
	}
	rows.Close()
	for _, job := range missing {
		if _, err := s.db.ExecContext(ctx, "DELETE FROM blobs WHERE job_id = ?", job); err != nil {
			return err
		}
	}
	entries, err := os.ReadDir(s.blobDir())
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	for _, e := range entries {
		if !known[e.Name()] {
			s.removeBlobFile(e.Name())
		}
	}
	return err
}

// DeleteKeptLogs removes the kept log files of a workspace that is not
// open; its rows are dropped when its store opens next.
func DeleteKeptLogs(dataDir, id string) error {
	id, ok := NormalizeWorkspaceID(id)
	if !ok {
		return ErrInvalidWorkspace
	}
	dir := filepath.Join(WorkspaceDir(dataDir, id), blobsDir)
	info, err := os.Lstat(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || !info.IsDir() {
		return err
	}
	entries, err := os.ReadDir(dir)
	for _, e := range entries {
		if filepath.Base(e.Name()) == e.Name() {
			_ = os.Remove(filepath.Join(dir, e.Name()))
		}
	}
	return err
}
```

In `openDatabase`, after `markInterrupted`: `if err := s.cleanBlobs(ctx); err != nil { return "The workspace database could not be updated.", false }`. Delete the stub from `usage.go`.

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/store/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/store
git commit -m "Keep job logs as checked blobs within a budget"
```

---

### Task 5: Conditional GitHub reads

**Files:**
- Modify: `core/internal/github/client.go`
- Test: `core/internal/github/client_test.go`

**Interfaces:**
- Produces:
  - `var ErrNotModified = errors.New("not modified")`
  - `func (c *Client) RunsIfChanged(ctx, owner, name string, limit int, etag string) ([]Run, string, error)`
  - `func (c *Client) WorkflowsIfChanged(ctx, owner, name, etag string) ([]Workflow, string, error)` — conditional only while the first page holds every workflow; otherwise all pages and an empty ETag

- [ ] **Step 1: Write the failing test** (append to `client_test.go`)

```go
func TestConditionalReadsUseETags(t *testing.T) {
	var runsSeen, workflowsSeen []string
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/o/r/actions/runs":
			runsSeen = append(runsSeen, r.Header.Get("If-None-Match"))
			if r.Header.Get("If-None-Match") == `"runs-1"` {
				w.WriteHeader(http.StatusNotModified)
				return
			}
			w.Header().Set("ETag", `"runs-1"`)
			_, _ = w.Write([]byte(`{"workflow_runs":[{"id":7,"status":"completed","created_at":"2026-10-18T10:00:00Z","updated_at":"2026-10-18T10:00:00Z"}]}`))
		case "/repos/o/r/actions/workflows":
			workflowsSeen = append(workflowsSeen, r.Header.Get("If-None-Match"))
			if r.Header.Get("If-None-Match") == `"wf-1"` {
				w.WriteHeader(http.StatusNotModified)
				return
			}
			w.Header().Set("ETag", `"wf-1"`)
			_, _ = w.Write([]byte(`{"total_count":1,"workflows":[{"id":3,"name":"CI","path":".github/workflows/ci.yml","state":"active"}]}`))
		}
	})
	ctx := context.Background()

	runs, tag, err := client.RunsIfChanged(ctx, "o", "r", 50, "")
	if err != nil || len(runs) != 1 || tag != `"runs-1"` {
		t.Fatalf("first = %v %q %v", runs, tag, err)
	}
	if _, _, err := client.RunsIfChanged(ctx, "o", "r", 50, tag); !errors.Is(err, ErrNotModified) {
		t.Fatalf("second = %v", err)
	}
	workflows, wtag, err := client.WorkflowsIfChanged(ctx, "o", "r", "")
	if err != nil || len(workflows) != 1 || wtag != `"wf-1"` {
		t.Fatalf("workflows = %v %q %v", workflows, wtag, err)
	}
	if _, _, err := client.WorkflowsIfChanged(ctx, "o", "r", wtag); !errors.Is(err, ErrNotModified) {
		t.Fatalf("workflows again = %v", err)
	}
	if len(runsSeen) != 2 || runsSeen[0] != "" || runsSeen[1] != `"runs-1"` || workflowsSeen[1] != `"wf-1"` {
		t.Fatalf("headers = %v %v", runsSeen, workflowsSeen)
	}
}
```

`fakeGitHub` is the helper at the top of `client_test.go`: it starts the server and returns a client holding a token.

- [ ] **Step 2: Run it to see it fail**

Run: `go test ./internal/github/ -run Conditional`
Expected: FAIL to build (`client.RunsIfChanged undefined`).

- [ ] **Step 3: Implement** in `client.go`:

```go
// ErrNotModified is a conditional read's answer when nothing changed (HTTP
// 304). GitHub does not count it against the rate limit.
var ErrNotModified = errors.New("not modified")
```

Split `exchange` so headers can be added, and map 304:

```go
func (c *Client) exchange(ctx context.Context, method, path string, query url.Values, body []byte, accept string) ([]byte, int, http.Header, error) {
	return c.exchangeWith(ctx, method, path, query, body, accept, nil)
}

// exchangeWith is exchange with extra request headers, such as If-None-Match.
func (c *Client) exchangeWith(ctx context.Context, method, path string, query url.Values, body []byte, accept string, extra http.Header) ([]byte, int, http.Header, error) {
	// ... the former body of exchange, plus, after the standard headers:
	for name, values := range extra {
		for _, value := range values {
			request.Header.Add(name, value)
		}
	}
	// ... and in the status switch, before `default`:
	case status == http.StatusNotModified:
		return nil, status, response.Header, ErrNotModified
}

// getConditional reads JSON with If-None-Match and returns the new ETag.
func (c *Client) getConditional(ctx context.Context, path string, query url.Values, etag string, out any) (string, error) {
	var extra http.Header
	if etag != "" {
		extra = http.Header{"If-None-Match": {etag}}
	}
	data, _, header, err := c.exchangeWith(ctx, http.MethodGet, path, query, nil, "application/vnd.github+json", extra)
	if err != nil {
		return "", err
	}
	if err := json.Unmarshal(data, out); err != nil {
		return "", ErrInvalid
	}
	return header.Get("ETag"), nil
}

// RunsIfChanged reads the newest runs like Runs; with etag set GitHub
// answers ErrNotModified when they did not change. It returns the new ETag.
func (c *Client) RunsIfChanged(ctx context.Context, owner, name string, limit int, etag string) ([]Run, string, error) {
	if limit <= 0 || limit > maxRuns {
		limit = maxRuns
	}
	var body struct {
		WorkflowRuns []runJSON `json:"workflow_runs"`
	}
	tag, err := c.getConditional(ctx, repoPath(owner, name, "/actions/runs"), url.Values{"per_page": {strconv.Itoa(limit)}}, etag, &body)
	if err != nil {
		return nil, "", err
	}
	runs := make([]Run, 0, len(body.WorkflowRuns))
	for _, r := range body.WorkflowRuns {
		runs = append(runs, r.run())
	}
	return runs, tag, nil
}

type workflowsPage struct {
	TotalCount int `json:"total_count"`
	Workflows  []struct {
		ID      int64  `json:"id"`
		Name    string `json:"name"`
		Path    string `json:"path"`
		State   string `json:"state"`
		HTMLURL string `json:"html_url"`
	} `json:"workflows"`
}

func (p workflowsPage) list() []Workflow {
	out := make([]Workflow, 0, len(p.Workflows))
	for _, w := range p.Workflows {
		out = append(out, Workflow{ID: w.ID, Name: w.Name, Path: w.Path, State: w.State, HTMLURL: w.HTMLURL})
	}
	return out
}

// WorkflowsIfChanged reads the workflows like Workflows. The read is
// conditional only while the first page holds them all; for a repository
// with more than 100 the rest are read every time and the ETag is empty.
func (c *Client) WorkflowsIfChanged(ctx context.Context, owner, name, etag string) ([]Workflow, string, error) {
	var first workflowsPage
	path := repoPath(owner, name, "/actions/workflows")
	tag, err := c.getConditional(ctx, path, url.Values{"per_page": {"100"}, "page": {"1"}}, etag, &first)
	if err != nil {
		return nil, "", err
	}
	out := first.list()
	if len(first.Workflows) < 100 || len(out) >= first.TotalCount {
		return out, tag, nil
	}
	for page := 2; page <= 3; page++ {
		var next workflowsPage
		if err := c.get(ctx, path, url.Values{"per_page": {"100"}, "page": {strconv.Itoa(page)}}, &next); err != nil {
			return nil, "", err
		}
		out = append(out, next.list()...)
		if len(next.Workflows) < 100 || len(out) >= first.TotalCount {
			break
		}
	}
	return out, "", nil
}
```

Rewrite `Workflows` to use `workflowsPage` (same behavior) so the struct is defined once.

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/github/`
Expected: PASS (existing tests unchanged).

- [ ] **Step 5: Commit**

```bash
git add core/internal/github
git commit -m "Read runs and workflows conditionally with ETags"
```

---

### Task 6: gRPC contract

**Files:**
- Modify: `contracts/grpc/runnir/core/v1/runnir_core.proto`
- Regenerate: `core/internal/gen/runnir/core/v1/*.go`, `apps/macos/Runnir/IPC/Generated/runnir/core/v1/*.swift`

**Interfaces:**
- Produces (Go names): `corev1.CoreEventType_CORE_EVENT_TYPE_ACTIVITY_CHANGED`, `corev1.ActivitySource_ACTIVITY_SOURCE_{NONE,CACHE,LIVE}`, `corev1.StorageState_STORAGE_STATE_{PERSISTENT,MEMORY_ONLY,ABSENT}`, messages `GetWorkspaceActivityRequest`, `RefreshWorkspaceActivityRequest`, `WorkspaceActivity`, `ActivityFreshness`, `WorkspaceStorage`, `GetStorageUsageRequest/Response`, `ClearWorkspaceCacheRequest/Response`, `DeleteWorkspaceDataRequest/Response`, `SetStoragePreferencesRequest/Response`; field `OpenRepositoryRequest.WorkspaceId`.
- Swift names: `Runnir_Core_V1_WorkspaceActivity`, `.activityChanged`, etc.

- [ ] **Step 1: Edit the proto**

In `service RunnirCore`, after `RefreshRepository`:

```proto
  // A workspace's GitHub activity as cached on this Mac: the newest runs,
  // the workflows and how fresh they are. Never waits for GitHub. Needs a
  // repository opened with a workspace_id (FAILED_PRECONDITION otherwise).
  rpc GetWorkspaceActivity(GetWorkspaceActivityRequest) returns (WorkspaceActivity);
  // Asks the workspace's sync for a pass; requests during a pass are merged
  // into one more. With wait, answers after a pass that started after the
  // request ended.
  rpc RefreshWorkspaceActivity(RefreshWorkspaceActivityRequest) returns (WorkspaceActivity);
  // What workspaces keep on this Mac, by id; empty ids: every workspace with
  // data and every open one.
  rpc GetStorageUsage(GetStorageUsageRequest) returns (GetStorageUsageResponse);
  // Deletes what can be downloaded again (runs, jobs, workflows, kept
  // logs); local run history, backups and recovery copies stay.
  rpc ClearWorkspaceCache(ClearWorkspaceCacheRequest) returns (ClearWorkspaceCacheResponse);
  // Deletes a workspace's whole folder; refused while it is open.
  rpc DeleteWorkspaceData(DeleteWorkspaceDataRequest) returns (DeleteWorkspaceDataResponse);
  // Whether completed jobs' logs are kept on this Mac. Off in every new Core.
  rpc SetStoragePreferences(SetStoragePreferencesRequest) returns (SetStoragePreferencesResponse);
```

Change `OpenRepositoryRequest`:

```proto
message OpenRepositoryRequest {
  // Absolute path of a working tree already granted to the app.
  string path = 1;
  // The registry's UUID of the workspace; gives the repository its
  // database and sync. Empty opens without them.
  string workspace_id = 2;
}
```

Add `CORE_EVENT_TYPE_ACTIVITY_CHANGED = 10;` to `CoreEventType` with the comment `// A workspace's cached activity or its freshness changed; read it again.`

Append the messages:

```proto
message GetWorkspaceActivityRequest {
  string repository_id = 1;
  // Runs to return, newest first: 1 to 200; 0 means 50.
  uint32 limit = 2;
}

message RefreshWorkspaceActivityRequest {
  string repository_id = 1;
  bool wait = 2;
  uint32 limit = 3;
}

message WorkspaceActivity {
  repeated WorkflowRun runs = 1;
  repeated GitHubWorkflow workflows = 2;
  ActivityFreshness freshness = 3;
}

enum ActivitySource {
  ACTIVITY_SOURCE_UNSPECIFIED = 0;
  // Nothing is cached for the repository the origin points at now.
  ACTIVITY_SOURCE_NONE = 1;
  // Read from this Mac; no pass reached GitHub since the Core started.
  ACTIVITY_SOURCE_CACHE = 2;
  // A pass reached GitHub since the Core started.
  ACTIVITY_SOURCE_LIVE = 3;
}

message ActivityFreshness {
  ActivitySource source = 1;
  bool syncing = 2;
  // The last pass's outcome; unset before the first one.
  GitHubStatus status = 3;
  // When the last pass ended.
  google.protobuf.Timestamp checked_at = 4;
  // When a pass last got answers (new data or not modified).
  google.protobuf.Timestamp synced_at = 5;
  // When the cached data last changed.
  google.protobuf.Timestamp changed_at = 6;
}

enum StorageState {
  STORAGE_STATE_UNSPECIFIED = 0;
  STORAGE_STATE_PERSISTENT = 1;
  // Kept in memory for now; note says why.
  STORAGE_STATE_MEMORY_ONLY = 2;
  // Nothing on this Mac.
  STORAGE_STATE_ABSENT = 3;
}

message WorkspaceStorage {
  // Lowercase UUID.
  string workspace_id = 1;
  StorageState state = 2;
  // Why it is in memory, or what recovery did. Never a credential.
  string note = 3;
  bool open = 4;
  // The database and its write-ahead log.
  uint64 database_bytes = 5;
  uint64 log_bytes = 6;
  uint32 cached_runs = 7;
  uint32 local_runs = 8;
  uint32 recovery_copies = 9;
}

message GetStorageUsageRequest {
  repeated string workspace_ids = 1;
}

message GetStorageUsageResponse {
  repeated WorkspaceStorage workspaces = 1;
  bool keep_job_logs = 2;
}

message ClearWorkspaceCacheRequest {
  // Empty: every workspace.
  repeated string workspace_ids = 1;
}

message ClearWorkspaceCacheResponse {
  repeated WorkspaceStorage workspaces = 1;
}

message DeleteWorkspaceDataRequest {
  string workspace_id = 1;
}

message DeleteWorkspaceDataResponse {}

message SetStoragePreferencesRequest {
  bool keep_job_logs = 1;
  // With keep_job_logs off: also delete the logs kept so far.
  bool delete_kept_logs = 2;
}

message SetStoragePreferencesResponse {}
```

- [ ] **Step 2: Regenerate and check**

```bash
PATH="/private/tmp/claude-502/-Users-dilbarov-projects-runnir/8b77c317-bb0f-4661-a151-57252fe15eba/scratchpad/bin:$HOME/go/bin:$PATH" scripts/generate-contracts.sh
buf breaking --against '.git#branch=origin/main'
cd core && go build ./...
```

Expected: lint passes, no breaking changes, Go builds (the server embeds `UnimplementedRunnirCoreServer`, so new calls answer `UNIMPLEMENTED` until Task 9).

- [ ] **Step 3: Commit**

```bash
git add contracts core/internal/gen apps/macos/Runnir/IPC/Generated
git commit -m "Add workspace activity and storage calls to the Core contract"
```

---

### Task 7: Workspace runtime and sync loop

**Files:**
- Create: `core/internal/workspace/access.go`, `runtime.go`, `schedule.go`
- Modify: `core/internal/store/activity.go` (add `CacheSource`)
- Test: `core/internal/workspace/runtime_test.go`, `schedule_test.go`, `helpers_test.go`

**Interfaces:**
- Consumes: `store.Open`, `store.Pass`, `store.RunsUpdate`, `store.WorkflowsUpdate`, `(*store.Store).ApplySync/Activity/ETags/ClearCache`; `github.Account`, `(*github.Client).RunsIfChanged/WorkflowsIfChanged`, `github.ErrNotModified`; `events.Event`; `corev1.GithubAccess_*`, `corev1.CoreEventType_CORE_EVENT_TYPE_ACTIVITY_CHANGED`.
- Produces:
  - `func Access(account *github.Account, err error) (corev1.GithubAccess, time.Time, error)` — `err` is the context error when the call was cancelled
  - `type Target struct{ Account *github.Account; Owner, Name string }`; `func (Target) Source() store.Source`
  - `type Resolver func() (Target, corev1.GithubAccess)` — `GITHUB_ACCESS_OK` with a target, otherwise the reason there is none
  - `type Intervals struct{ Active, Idle time.Duration; Backoff []time.Duration; RateLimitMin, RateLimitMax, JobsReuse, FetchTimeout time.Duration }`; `func DefaultIntervals() Intervals`
  - `type Provenance int` with `NoData`, `Cached`, `Live`
  - `type Snapshot struct{ Runs []github.Run; Workflows []github.Workflow; Provenance Provenance; Syncing bool; Access corev1.GithubAccess; RetryAfter, CheckedAt, SyncedAt, ChangedAt time.Time }`
  - `type Runtime`; `(*Runtime).Snapshot(ctx, limit) (Snapshot, error)`, `Refresh(ctx, wait bool) error`, `ClearCache(ctx) error`, `Close()`, `RepositoryID() string`, `WorkspaceID() string`, `Store() *store.Store`
  - `var ErrClosed`
  - `(*store.Store).CacheSource(ctx) (store.Source, bool, error)`
  - unexported, used by Task 8: `newRuntime(workspaceID, repositoryID string, resolve Resolver, cfg config) *Runtime`, `(*Runtime).start()`, `rebind(repositoryID string, resolve Resolver)`, `credentialChanged(serverID string)`; `type config struct{ store *store.Store; publish func(events.Event); now func() time.Time; intervals Intervals; keepLogs func() bool }`

- [ ] **Step 1: Write the failing tests**

`core/internal/workspace/helpers_test.go`:

```go
package workspace

import (
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/events"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

// fakeGitHub serves o/r: runs with an ETag, workflows, jobs and logs, and
// counts requests per path. gate, when set, blocks runs reads until closed.
type fakeGitHub struct {
	mu       sync.Mutex
	runs     string // JSON body for /actions/runs
	etag     string
	status   int // non-zero: answer every request with it
	gate     chan struct{}
	requests map[string]int
}

func newFake(t *testing.T) (*fakeGitHub, *github.Accounts) {
	t.Helper()
	f := &fakeGitHub{etag: `"v1"`, requests: map[string]int{},
		runs: `{"workflow_runs":[{"id":7,"workflow_id":3,"name":"CI","run_number":1,"run_attempt":1,"status":"completed","conclusion":"success","created_at":"2026-10-18T10:00:00Z","updated_at":"2026-10-18T10:04:00Z"}]}`}
	server := httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(server.Close)
	accounts := github.NewAccounts(server.URL, "test")
	if _, err := accounts.Set(github.Server{}, "ghu_test"); err != nil {
		t.Fatal(err)
	}
	return f, accounts
}

func (f *fakeGitHub) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.requests[r.URL.Path]++
	status, body, etag, gate := f.status, f.runs, f.etag, f.gate
	f.mu.Unlock()
	if status != 0 {
		w.WriteHeader(status)
		return
	}
	switch r.URL.Path {
	case "/repos/o/r/actions/runs":
		if gate != nil {
			<-gate
		}
		if r.Header.Get("If-None-Match") == etag {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", etag)
		_, _ = w.Write([]byte(body))
	case "/repos/o/r/actions/workflows":
		_, _ = w.Write([]byte(`{"total_count":1,"workflows":[{"id":3,"name":"CI","path":".github/workflows/ci.yml","state":"active"}]}`))
	case "/repos/o/r/actions/runs/7/jobs":
		_, _ = w.Write([]byte(`{"jobs":[{"id":11,"name":"build","status":"completed","conclusion":"success","steps":[{"number":1,"name":"Checkout","status":"completed","conclusion":"success"}]}]}`))
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func (f *fakeGitHub) count(path string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.requests[path]
}

func (f *fakeGitHub) set(change func(*fakeGitHub)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	change(f)
}

func fixedResolver(accounts *github.Accounts, owner, name string) Resolver {
	return func() (Target, corev1.GithubAccess) {
		account, _ := accounts.Get("")
		return Target{Account: account, Owner: owner, Name: name}, corev1.GithubAccess_GITHUB_ACCESS_OK
	}
}

// eventLog collects published events.
type eventLog struct {
	mu     sync.Mutex
	events []events.Event
	count  atomic.Int64
}

func (l *eventLog) publish(e events.Event) {
	l.mu.Lock()
	l.events = append(l.events, e)
	l.mu.Unlock()
	l.count.Add(1)
}

func testIntervals() Intervals {
	iv := DefaultIntervals()
	iv.Active, iv.Idle = time.Hour, time.Hour // no timer passes during a test
	return iv
}

func startRuntime(t *testing.T, dir string, resolve Resolver, log *eventLog) *Runtime {
	t.Helper()
	st, err := store.Open(dir, store.Options{})
	if err != nil {
		t.Fatal(err)
	}
	publish := func(events.Event) {}
	if log != nil {
		publish = log.publish
	}
	r := newRuntime("5ce88ff0-5c16-43b3-8f20-8e33e852b019", "repo_1", resolve,
		config{store: st, publish: publish, now: time.Now, intervals: testIntervals(), keepLogs: func() bool { return false }})
	r.start()
	t.Cleanup(func() { r.Close(); _ = st.Close() })
	return r
}
```

`core/internal/workspace/runtime_test.go`:

```go
package workspace

import (
	"context"
	"net/http"
	"sync"
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

const runsPath = "/repos/o/r/actions/runs"

func waitRefresh(t *testing.T, r *Runtime) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := r.Refresh(ctx, true); err != nil {
		t.Fatal(err)
	}
}

func TestTheFirstPassStoresActivityAndMakesItLive(t *testing.T) {
	_, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	snap, err := r.Snapshot(context.Background(), 50)
	if err != nil || snap.Provenance != Live || len(snap.Runs) != 1 || len(snap.Workflows) != 1 ||
		snap.Access != corev1.GithubAccess_GITHUB_ACCESS_OK || snap.SyncedAt.IsZero() {
		t.Fatalf("snapshot = %+v, %v", snap, err)
	}
}

func TestConcurrentRefreshesShareOnePass(t *testing.T) {
	fake, accounts := newFake(t)
	gate := make(chan struct{})
	fake.set(func(f *fakeGitHub) { f.gate = gate })
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	// The opening pass is held at the gate; five windows ask meanwhile.
	deadline := time.Now().Add(5 * time.Second)
	for fake.count(runsPath) == 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); waitRefresh(t, r) }()
	}
	time.Sleep(50 * time.Millisecond)
	close(gate)
	wg.Wait()
	if n := fake.count(runsPath); n != 2 {
		t.Fatalf("runs requests = %d, want the opening pass and one merged pass", n)
	}
}

func TestANotModifiedPassKeepsChangedAt(t *testing.T) {
	_, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	first, _ := r.Snapshot(context.Background(), 50)
	time.Sleep(5 * time.Millisecond)
	waitRefresh(t, r)
	second, _ := r.Snapshot(context.Background(), 50)
	if !second.ChangedAt.Equal(first.ChangedAt) || !second.SyncedAt.After(first.SyncedAt) || len(second.Runs) != 1 {
		t.Fatalf("first %+v second %+v", first, second)
	}
}

func TestLosingAccessKeepsTheCache(t *testing.T) {
	fake, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	fake.set(func(f *fakeGitHub) { f.status = http.StatusUnauthorized })
	waitRefresh(t, r)
	snap, _ := r.Snapshot(context.Background(), 50)
	if snap.Access != corev1.GithubAccess_GITHUB_ACCESS_TOKEN_REJECTED || len(snap.Runs) != 1 || snap.Provenance != Live {
		t.Fatalf("snapshot = %+v", snap)
	}
	account, _ := accounts.Get("")
	if _, ok := account.Credential.Token(); ok {
		t.Fatal("rejected token kept")
	}
}

func TestCachedActivityIsServedBeforeAnyPass(t *testing.T) {
	dir := t.TempDir()
	fake, accounts := newFake(t)
	first := startRuntime(t, dir, fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, first)
	first.Close()
	_ = first.Store().Close()

	gate := make(chan struct{})
	t.Cleanup(func() { close(gate) })
	fake.set(func(f *fakeGitHub) { f.gate = gate })
	second := startRuntime(t, dir, fixedResolver(accounts, "o", "r"), nil)
	snap, err := second.Snapshot(context.Background(), 50)
	if err != nil || snap.Provenance != Cached || len(snap.Runs) != 1 || !snap.Syncing && snap.CheckedAt.IsZero() {
		t.Fatalf("snapshot = %+v, %v", snap, err)
	}
}

func TestAnotherOriginNeverShowsTheOldRepository(t *testing.T) {
	fake, accounts := newFake(t)
	var mu sync.Mutex
	name := "r"
	resolve := func() (Target, corev1.GithubAccess) {
		mu.Lock()
		defer mu.Unlock()
		account, _ := accounts.Get("")
		return Target{Account: account, Owner: "o", Name: name}, corev1.GithubAccess_GITHUB_ACCESS_OK
	}
	r := startRuntime(t, t.TempDir(), resolve, nil)
	waitRefresh(t, r)
	mu.Lock()
	name = "other" // the fake answers 404 for it
	mu.Unlock()
	waitRefresh(t, r)
	snap, _ := r.Snapshot(context.Background(), 50)
	if snap.Provenance != NoData || len(snap.Runs) != 0 || snap.Access != corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE {
		t.Fatalf("snapshot = %+v", snap)
	}
	_ = fake
}

func TestNoRemoteMeansNoRequests(t *testing.T) {
	fake, _ := newFake(t)
	r := startRuntime(t, t.TempDir(), func() (Target, corev1.GithubAccess) {
		return Target{}, corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE
	}, nil)
	waitRefresh(t, r)
	snap, _ := r.Snapshot(context.Background(), 50)
	if snap.Access != corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE || fake.count(runsPath) != 0 {
		t.Fatalf("snapshot = %+v, requests %d", snap, fake.count(runsPath))
	}
}

func TestACredentialChangeStartsAPass(t *testing.T) {
	fake, accounts := newFake(t)
	accounts.Clear("") // signed out
	log := &eventLog{}
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), log)
	waitRefresh(t, r)
	if snap, _ := r.Snapshot(context.Background(), 50); snap.Access != corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT {
		t.Fatalf("signed out = %+v", snap)
	}
	_, _ = accounts.Set(github.Server{}, "ghu_test")
	before := log.count.Load()
	r.credentialChanged("")
	deadline := time.Now().Add(5 * time.Second)
	for fake.count(runsPath) == 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if fake.count(runsPath) != 1 || log.count.Load() <= before {
		t.Fatalf("requests %d, events %d -> %d", fake.count(runsPath), before, log.count.Load())
	}
}

func TestEveryPassAnnouncesItselfForItsRepository(t *testing.T) {
	_, accounts := newFake(t)
	log := &eventLog{}
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), log)
	waitRefresh(t, r)
	log.mu.Lock()
	defer log.mu.Unlock()
	if len(log.events) < 2 {
		t.Fatalf("events = %v", log.events)
	}
	for _, e := range log.events {
		if e.Type != corev1.CoreEventType_CORE_EVENT_TYPE_ACTIVITY_CHANGED || e.RepositoryID != "repo_1" {
			t.Fatalf("event = %+v", e)
		}
	}
}

func TestClosingStopsTheLoop(t *testing.T) {
	_, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	r.Close()
	if err := r.Refresh(context.Background(), true); err != ErrClosed {
		t.Fatalf("refresh after close = %v", err)
	}
}

func TestClearCacheEmptiesAndSyncsAgain(t *testing.T) {
	fake, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	if err := r.ClearCache(context.Background()); err != nil {
		t.Fatal(err)
	}
	waitRefresh(t, r)
	snap, _ := r.Snapshot(context.Background(), 50)
	if len(snap.Runs) != 1 || fake.count(runsPath) < 2 {
		t.Fatalf("snapshot = %+v", snap)
	}
	_ = store.Source{}
}
```

`core/internal/workspace/schedule_test.go`:

```go
package workspace

import (
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
)

func TestTheNextPassIsScheduledByOutcome(t *testing.T) {
	iv := DefaultIntervals()
	now := time.Date(2026, 10, 22, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		name     string
		access   corev1.GithubAccess
		active   bool
		failures int
		retry    time.Time
		want     time.Duration
		timer    bool
	}{
		{"idle", corev1.GithubAccess_GITHUB_ACCESS_OK, false, 0, time.Time{}, 5 * time.Minute, true},
		{"active", corev1.GithubAccess_GITHUB_ACCESS_OK, true, 0, time.Time{}, 20 * time.Second, true},
		{"first failure", corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE, false, 1, time.Time{}, 30 * time.Second, true},
		{"third failure", corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE, false, 3, time.Time{}, 2 * time.Minute, true},
		{"many failures", corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE, false, 9, time.Time{}, 5 * time.Minute, true},
		{"rate limit", corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED, false, 0, now.Add(10 * time.Minute), 10 * time.Minute, true},
		{"rate limit soon", corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED, false, 0, now.Add(time.Second), 30 * time.Second, true},
		{"rate limit far", corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED, false, 0, now.Add(5 * time.Hour), time.Hour, true},
		{"signed out", corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT, false, 0, time.Time{}, 0, false},
		{"rejected", corev1.GithubAccess_GITHUB_ACCESS_TOKEN_REJECTED, false, 0, time.Time{}, 0, false},
		{"not visible", corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE, false, 0, time.Time{}, 0, false},
		{"permission", corev1.GithubAccess_GITHUB_ACCESS_PERMISSION_MISSING, false, 0, time.Time{}, 0, false},
		{"no remote", corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE, false, 0, time.Time{}, 0, false},
	}
	for _, c := range cases {
		got, timer := schedule(iv, c.access, c.active, c.failures, c.retry, now)
		if got != c.want || timer != c.timer {
			t.Errorf("%s: %v %v, want %v %v", c.name, got, timer, c.want, c.timer)
		}
	}
}

func TestActiveRunsKeepTheShortInterval(t *testing.T) {
	for status, want := range map[string]bool{"queued": true, "in_progress": true, "waiting": true, "requested": true, "pending": true, "completed": false} {
		if got := isActive([]github.Run{{Status: status}}); got != want {
			t.Errorf("%s: %v", status, got)
		}
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/workspace/`
Expected: FAIL to build (package has no non-test files).

- [ ] **Step 3: Implement**

Add to `core/internal/store/activity.go`:

```go
// CacheSource returns the repository the cached activity belongs to.
func (s *Store) CacheSource(ctx context.Context) (Source, bool, error) { return readSource(ctx, s.db) }
```

`core/internal/workspace/access.go`:

```go
// Package workspace runs one shared runtime per workspace in the Core: its
// database, one GitHub sync loop, shared job and log reads and the history
// of local runs, however many windows show the workspace.
package workspace

import (
	"context"
	"errors"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
)

// Access maps a GitHub client error to the status the app sees and forgets
// the token GitHub rejected. A cancelled call returns its context error
// instead, for the caller to end the call with.
func Access(account *github.Account, err error) (corev1.GithubAccess, time.Time, error) {
	var rateLimit *github.RateLimitError
	switch {
	case err == nil, errors.Is(err, github.ErrNotModified):
		return corev1.GithubAccess_GITHUB_ACCESS_OK, time.Time{}, nil
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return corev1.GithubAccess_GITHUB_ACCESS_UNSPECIFIED, time.Time{}, err
	case errors.Is(err, github.ErrNoCredential):
		return corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT, time.Time{}, nil
	case errors.Is(err, github.ErrUnauthorized):
		account.Credential.Clear()
		return corev1.GithubAccess_GITHUB_ACCESS_TOKEN_REJECTED, time.Time{}, nil
	case errors.Is(err, github.ErrNotVisible):
		return corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE, time.Time{}, nil
	case errors.Is(err, github.ErrPermissionMissing):
		return corev1.GithubAccess_GITHUB_ACCESS_PERMISSION_MISSING, time.Time{}, nil
	case errors.As(err, &rateLimit):
		return corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED, rateLimit.Reset, nil
	default:
		return corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE, time.Time{}, nil
	}
}
```

`core/internal/workspace/schedule.go`:

```go
package workspace

import (
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
)

// Intervals tune the sync; DefaultIntervals is what the Core uses.
type Intervals struct {
	Active, Idle               time.Duration
	Backoff                    []time.Duration
	RateLimitMin, RateLimitMax time.Duration
	// JobsReuse is how long jobs just read are served again without a
	// request, so windows opening the same run share one read.
	JobsReuse time.Duration
	// FetchTimeout bounds a shared jobs or log download.
	FetchTimeout time.Duration
}

func DefaultIntervals() Intervals {
	return Intervals{
		Active: 20 * time.Second, Idle: 5 * time.Minute,
		Backoff:      []time.Duration{30 * time.Second, time.Minute, 2 * time.Minute, 5 * time.Minute},
		RateLimitMin: 30 * time.Second, RateLimitMax: time.Hour,
		JobsReuse: 10 * time.Second, FetchTimeout: 2 * time.Minute,
	}
}

// schedule says how long after a pass the next one runs, or false for no
// timer: then only a refresh or a credential change starts one. failures
// counts consecutive UNAVAILABLE passes.
func schedule(iv Intervals, access corev1.GithubAccess, active bool, failures int, retryAfter, now time.Time) (time.Duration, bool) {
	switch access {
	case corev1.GithubAccess_GITHUB_ACCESS_OK:
		if active {
			return iv.Active, true
		}
		return iv.Idle, true
	case corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE:
		i := min(max(failures-1, 0), len(iv.Backoff)-1)
		return iv.Backoff[i], true
	case corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED:
		return min(max(retryAfter.Sub(now), iv.RateLimitMin), iv.RateLimitMax), true
	default:
		return 0, false
	}
}

// isActive reports a run GitHub has not finished.
func isActive(runs []github.Run) bool {
	for _, r := range runs {
		switch r.Status {
		case "queued", "in_progress", "waiting", "requested", "pending":
			return true
		}
	}
	return false
}
```

`core/internal/workspace/runtime.go`:

```go
package workspace

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"

	"runnir/core/internal/events"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

// pageSize is how many of the newest runs one pass reads.
const pageSize = 50

// ErrClosed is returned by a runtime whose workspace was closed.
var ErrClosed = errors.New("workspace runtime closed")

// Target is the GitHub repository a workspace's activity comes from.
type Target struct {
	Account     *github.Account
	Owner, Name string
}

// Source names the target for the cache: server id and lowercased owner/name.
func (t Target) Source() store.Source {
	return store.Source{ServerID: t.Account.Server.ID, Repository: strings.ToLower(t.Owner + "/" + t.Name)}
}

// Resolver returns the repository's current target with OK, or the status
// that says why there is none (NO_REMOTE).
type Resolver func() (Target, corev1.GithubAccess)

// Provenance says where a snapshot's data comes from.
type Provenance int

const (
	// NoData: nothing cached for the repository the origin points at now.
	NoData Provenance = iota
	// Cached: read from disk; no pass reached GitHub in this process yet.
	Cached
	// Live: a pass reached GitHub in this process.
	Live
)

// Snapshot is a workspace's activity as the app shows it.
type Snapshot struct {
	Runs       []github.Run
	Workflows  []github.Workflow
	Provenance Provenance
	Syncing    bool
	// Access is the last pass's outcome, or why there is no target;
	// UNSPECIFIED before the first pass.
	Access     corev1.GithubAccess
	RetryAfter time.Time
	CheckedAt  time.Time
	SyncedAt   time.Time
	ChangedAt  time.Time
}

type config struct {
	store     *store.Store
	publish   func(events.Event)
	now       func() time.Time
	intervals Intervals
	keepLogs  func() bool
}

// Runtime is one workspace's shared service: one sync loop and one store,
// whatever number of windows show the workspace.
type Runtime struct {
	workspaceID string
	cfg         config
	ctx         context.Context
	cancel      context.CancelFunc
	wake        chan struct{}
	loopDone    chan struct{}
	flights     singleflight.Group

	mu           sync.Mutex
	repositoryID string
	resolve      Resolver
	started      uint64
	finished     uint64
	passDone     chan struct{}
	syncing      bool
	live         bool
	active       bool
	failures     int
	lastAccess   corev1.GithubAccess
	lastRetry    time.Time
	lastServer   string
	hasServer    bool
}

func newRuntime(workspaceID, repositoryID string, resolve Resolver, cfg config) *Runtime {
	ctx, cancel := context.WithCancel(context.Background())
	return &Runtime{
		workspaceID: workspaceID, cfg: cfg, ctx: ctx, cancel: cancel,
		wake: make(chan struct{}, 1), loopDone: make(chan struct{}),
		repositoryID: repositoryID, resolve: resolve, passDone: make(chan struct{}),
	}
}

func (r *Runtime) start() { go r.loop() }

func (r *Runtime) WorkspaceID() string { return r.workspaceID }

func (r *Runtime) Store() *store.Store { return r.cfg.store }

func (r *Runtime) RepositoryID() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.repositoryID
}

// rebind moves the runtime to another repository context of the same
// workspace (a relinked folder) and syncs again, the origin may differ.
func (r *Runtime) rebind(repositoryID string, resolve Resolver) {
	r.mu.Lock()
	r.repositoryID, r.resolve = repositoryID, resolve
	r.mu.Unlock()
	_ = r.Refresh(context.Background(), false)
}

// Close stops the loop and waits for a running pass to end. The store is
// closed by its owner.
func (r *Runtime) Close() {
	r.cancel()
	<-r.loopDone
}

func (r *Runtime) loop() {
	defer close(r.loopDone)
	timer := time.NewTimer(0)
	defer timer.Stop()
	for {
		select {
		case <-r.ctx.Done():
			return
		case <-timer.C:
		case <-r.wake:
		}
		timer.Stop()
		r.pass()
		if r.ctx.Err() != nil {
			return
		}
		r.mu.Lock()
		delay, ok := schedule(r.cfg.intervals, r.lastAccess, r.active, r.failures, r.lastRetry, r.cfg.now())
		r.mu.Unlock()
		if ok {
			timer.Reset(delay)
		}
	}
}

// Refresh asks for a pass. Requests during a pass are merged into exactly
// one more. With wait it returns once a pass that started after the request
// has ended.
func (r *Runtime) Refresh(ctx context.Context, wait bool) error {
	select {
	case <-r.loopDone:
		return ErrClosed
	default:
	}
	r.mu.Lock()
	target := r.started + 1
	r.mu.Unlock()
	select {
	case r.wake <- struct{}{}:
	default:
	}
	if !wait {
		return nil
	}
	for {
		r.mu.Lock()
		finished, done := r.finished, r.passDone
		r.mu.Unlock()
		if finished >= target {
			return nil
		}
		select {
		case <-done:
		case <-ctx.Done():
			return ctx.Err()
		case <-r.loopDone:
			return ErrClosed
		}
	}
}

func (r *Runtime) pass() {
	r.mu.Lock()
	r.started++
	r.syncing = true
	resolve := r.resolve
	r.mu.Unlock()
	r.publish()

	p, server, hasServer := r.read(resolve)
	if r.ctx.Err() == nil {
		_, _ = r.cfg.store.ApplySync(r.ctx, p)
	}
	active := false
	if a, err := r.cfg.store.Activity(r.ctx, pageSize); err == nil {
		active = isActive(a.Runs)
	}

	r.mu.Lock()
	r.syncing = false
	r.finished++
	r.lastAccess, r.lastRetry = corev1.GithubAccess(p.Access), p.RetryAfter
	r.lastServer, r.hasServer = server, hasServer
	r.active = active
	switch {
	case p.OK:
		r.live, r.failures = true, 0
	case r.lastAccess == corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE:
		r.failures++
	default:
		r.failures = 0
	}
	close(r.passDone)
	r.passDone = make(chan struct{})
	r.mu.Unlock()
	r.publish()
}

// read asks GitHub for the newest runs and the workflows, conditionally.
func (r *Runtime) read(resolve Resolver) (store.Pass, string, bool) {
	target, problem := resolve()
	if problem != corev1.GithubAccess_GITHUB_ACCESS_OK {
		return store.Pass{At: r.cfg.now(), Access: int32(problem)}, "", false
	}
	source := target.Source()
	p := store.Pass{Source: source}
	runsTag, workflowsTag, _ := r.cfg.store.ETags(r.ctx, source)
	client := target.Account.Client
	runs, tag, err := client.RunsIfChanged(r.ctx, target.Owner, target.Name, pageSize, runsTag)
	switch {
	case errors.Is(err, github.ErrNotModified):
		p.Runs = &store.RunsUpdate{NotModified: true, ETag: runsTag}
	case err != nil:
		return r.failed(p, target, err), source.ServerID, true
	default:
		p.Runs = &store.RunsUpdate{Runs: runs, Complete: len(runs) < pageSize, ETag: tag}
	}
	workflows, workflowsTagNow, err := client.WorkflowsIfChanged(r.ctx, target.Owner, target.Name, workflowsTag)
	switch {
	case errors.Is(err, github.ErrNotModified):
		p.Workflows = &store.WorkflowsUpdate{NotModified: true, ETag: workflowsTag}
	case err != nil:
		return r.failed(p, target, err), source.ServerID, true
	default:
		p.Workflows = &store.WorkflowsUpdate{Workflows: workflows, ETag: workflowsTagNow}
	}
	p.At, p.OK, p.Access = r.cfg.now(), true, int32(corev1.GithubAccess_GITHUB_ACCESS_OK)
	return p, source.ServerID, true
}

func (r *Runtime) failed(p store.Pass, target Target, err error) store.Pass {
	access, retry, _ := Access(target.Account, err)
	if access == corev1.GithubAccess_GITHUB_ACCESS_UNSPECIFIED {
		access = corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE // cancelled: the runtime is closing
	}
	p.At, p.Access, p.RetryAfter = r.cfg.now(), int32(access), retry
	return p
}

func (r *Runtime) publish() {
	if r.cfg.publish == nil {
		return
	}
	r.cfg.publish(events.Event{Type: corev1.CoreEventType_CORE_EVENT_TYPE_ACTIVITY_CHANGED, RepositoryID: r.RepositoryID()})
}

// Snapshot reads the cached activity without waiting for GitHub. Data of
// another repository than the origin's current one is never returned.
func (r *Runtime) Snapshot(ctx context.Context, limit int) (Snapshot, error) {
	r.mu.Lock()
	resolve, syncing, live := r.resolve, r.syncing, r.live
	r.mu.Unlock()
	a, err := r.cfg.store.Activity(ctx, limit)
	if err != nil {
		return Snapshot{}, err
	}
	snap := Snapshot{Syncing: syncing, Access: corev1.GithubAccess(a.Access), RetryAfter: a.RetryAfter, CheckedAt: a.CheckedAt}
	target, problem := resolve()
	if problem != corev1.GithubAccess_GITHUB_ACCESS_OK {
		snap.Access = problem
		return snap, nil
	}
	if !a.HasSource || a.Source != target.Source() {
		return snap, nil
	}
	snap.Runs, snap.Workflows, snap.SyncedAt, snap.ChangedAt = a.Runs, a.Workflows, a.SyncedAt, a.ChangedAt
	switch {
	case live:
		snap.Provenance = Live
	case len(a.Runs) > 0 || len(a.Workflows) > 0 || !a.SyncedAt.IsZero():
		snap.Provenance = Cached
	}
	return snap, nil
}

// ClearCache empties the workspace's cache and syncs again.
func (r *Runtime) ClearCache(ctx context.Context) error {
	if err := r.cfg.store.ClearCache(ctx); err != nil {
		return err
	}
	r.mu.Lock()
	r.live = false
	r.mu.Unlock()
	r.publish()
	return r.Refresh(ctx, false)
}

// credentialChanged starts a pass when the token of the server the last
// pass used changed, or when the last pass had no server (a new server may
// now match the origin), with backoff reset.
func (r *Runtime) credentialChanged(serverID string) {
	r.mu.Lock()
	match := !r.hasServer || r.lastServer == serverID
	if match {
		r.failures = 0
	}
	r.mu.Unlock()
	if match {
		_ = r.Refresh(context.Background(), false)
	}
}
```

Run `go mod tidy` so `golang.org/x/sync` becomes a direct requirement.

- [ ] **Step 4: Run the tests**

Run: `go test -race ./internal/workspace/ ./internal/store/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/go.mod core/go.sum core/internal/workspace core/internal/store
git commit -m "Run one sync loop per workspace in the Core"
```

---

### Task 8: Shared jobs and logs, local run history, the runtime registry

**Files:**
- Create: `core/internal/workspace/jobs.go`, `logs.go`, `runtimes.go`, `recorder.go`
- Test: `core/internal/workspace/jobs_test.go`, `runtimes_test.go`

**Interfaces:**
- Consumes: Task 7's `Runtime`, `config`, `newRuntime`, `rebind`, `credentialChanged`; `store.*`.
- Produces:
  - `(*Runtime).Jobs(ctx, runID int64) ([]github.Job, corev1.GithubAccess, time.Time, error)`
  - `(*Runtime).CompletedJob(ctx, jobID int64) (github.Job, bool)` — a cached job that has finished
  - `(*Runtime).KeptLog(ctx, jobID int64) ([]byte, store.LogMeta, bool)` — only while keeping logs is on
  - `(*Runtime).KeepLog(ctx, jobID int64, data []byte, meta store.LogMeta)` — only while keeping logs is on
  - `(*Runtime).SharedLog(ctx, jobID int64, timeout time.Duration, fetch func(context.Context) (github.JobLog, error)) (github.JobLog, error)`
  - `type Options struct{ DataDir string; Publish func(events.Event); Now func() time.Time; Intervals Intervals }`
  - `func New(Options) *Runtimes`
  - `(*Runtimes).Attach(workspaceID, repositoryID string, resolve Resolver) (*Runtime, error)` — `store.ErrInvalidWorkspace`, `ErrMismatch`
  - `(*Runtimes).ForRepository(repositoryID string) (*Runtime, bool)`, `Detach(repositoryID string)`, `CredentialChanged(serverID string)`
  - `(*Runtimes).KeepLogs() bool`, `SetKeepLogs(keep, deleteKept bool) error`
  - `type Usage struct{ WorkspaceID string; State store.State; Note string; Open bool; store.Usage }` (State 0: nothing on disk)
  - `(*Runtimes).Usage(ctx, ids []string) ([]Usage, error)`, `ClearCache(ctx, ids []string) ([]Usage, error)`, `Delete(id string) error` (`ErrOpen`)
  - `(*Runtimes).RecordLocalRun(repositoryID string, run store.LocalRun)`, `LocalRunNotStarted(executionID, message string)`, `ObserveExecution(events.Event)`, `Shutdown()`

- [ ] **Step 1: Write the failing tests**

`core/internal/workspace/jobs_test.go`:

```go
package workspace

import (
	"context"
	"sync"
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

const jobsPath = "/repos/o/r/actions/runs/7/jobs"

func TestJobsOfAFinishedRunAreReadOnce(t *testing.T) {
	fake, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	r.cfg.intervals.JobsReuse = 0 // only the finished-run rule applies
	for i := 0; i < 3; i++ {
		jobs, access, _, err := r.Jobs(context.Background(), 7)
		if err != nil || access != corev1.GithubAccess_GITHUB_ACCESS_OK || len(jobs) != 1 || len(jobs[0].Steps) != 1 {
			t.Fatalf("jobs = %v %v %v", jobs, access, err)
		}
	}
	if n := fake.count(jobsPath); n != 1 {
		t.Fatalf("jobs requests = %d", n)
	}
}

func TestConcurrentJobReadsShareOneRequest(t *testing.T) {
	fake, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if jobs, _, _, err := r.Jobs(context.Background(), 7); err != nil || len(jobs) != 1 {
				t.Errorf("jobs = %v %v", jobs, err)
			}
		}()
	}
	wg.Wait()
	if n := fake.count(jobsPath); n != 1 {
		t.Fatalf("jobs requests = %d", n)
	}
}

func TestKeptLogsFollowTheSetting(t *testing.T) {
	_, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	keep := false
	r.cfg.keepLogs = func() bool { return keep }
	ctx := context.Background()
	r.KeepLog(ctx, 11, []byte("log"), store.LogMeta{})
	if _, _, ok := r.KeptLog(ctx, 11); ok {
		t.Fatal("kept with the setting off")
	}
	keep = true
	r.KeepLog(ctx, 11, []byte("log"), store.LogMeta{})
	if data, _, ok := r.KeptLog(ctx, 11); !ok || string(data) != "log" {
		t.Fatalf("kept = %q %v", data, ok)
	}
	keep = false
	if _, _, ok := r.KeptLog(ctx, 11); ok {
		t.Fatal("served with the setting off")
	}
}

func TestLogDownloadsAreShared(t *testing.T) {
	_, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	var mu sync.Mutex
	calls := 0
	release := make(chan struct{})
	fetch := func(context.Context) (github.JobLog, error) {
		mu.Lock()
		calls++
		mu.Unlock()
		<-release
		return github.JobLog{Data: []byte("x")}, nil
	}
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if log, err := r.SharedLog(context.Background(), 11, time.Minute, fetch); err != nil || string(log.Data) != "x" {
				t.Errorf("log = %v %v", log, err)
			}
		}()
	}
	time.Sleep(50 * time.Millisecond)
	close(release)
	wg.Wait()
	if calls != 1 {
		t.Fatalf("downloads = %d", calls)
	}
}
```

`core/internal/workspace/runtimes_test.go`:

```go
package workspace

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"runnir/core/internal/events"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/store"
)

const wsA = "5CE88FF0-5C16-43B3-8F20-8E33E852B019"
const wsB = "6ce88ff0-5c16-43b3-8f20-8e33e852b019"

func newRuntimes(t *testing.T, data string) *Runtimes {
	t.Helper()
	m := New(Options{DataDir: data, Intervals: testIntervals()})
	t.Cleanup(m.Shutdown)
	return m
}

func TestOneRuntimePerWorkspace(t *testing.T) {
	_, accounts := newFake(t)
	m := newRuntimes(t, t.TempDir())
	resolve := fixedResolver(accounts, "o", "r")
	a, err := m.Attach(wsA, "repo_1", resolve)
	if err != nil {
		t.Fatal(err)
	}
	again, _ := m.Attach(wsA, "repo_1", resolve)
	if a != again || a.WorkspaceID() != "5ce88ff0-5c16-43b3-8f20-8e33e852b019" {
		t.Fatal("a second window got a second runtime")
	}
	if _, err := m.Attach(wsB, "repo_1", resolve); !errors.Is(err, ErrMismatch) {
		t.Fatalf("other workspace on the same repository = %v", err)
	}
	if _, err := m.Attach("../x", "repo_2", resolve); !errors.Is(err, store.ErrInvalidWorkspace) {
		t.Fatalf("bad id = %v", err)
	}
	// A relinked folder opens as another repository context.
	moved, _ := m.Attach(wsA, "repo_9", resolve)
	if moved != a || a.RepositoryID() != "repo_9" {
		t.Fatal("relink did not move the runtime")
	}
	if _, ok := m.ForRepository("repo_1"); ok {
		t.Fatal("old repository still bound")
	}
	m.Detach("repo_1") // the old context closing later changes nothing
	if _, ok := m.ForRepository("repo_9"); !ok {
		t.Fatal("runtime lost")
	}
	m.Detach("repo_9")
	if _, ok := m.ForRepository("repo_9"); ok {
		t.Fatal("runtime kept after detach")
	}
}

func TestStorageOfOpenAndClosedWorkspaces(t *testing.T) {
	_, accounts := newFake(t)
	data := t.TempDir()
	m := newRuntimes(t, data)
	r, _ := m.Attach(wsA, "repo_1", fixedResolver(accounts, "o", "r"))
	waitRefresh(t, r)
	closedID := "7ce88ff0-5c16-43b3-8f20-8e33e852b019"
	closed, _ := store.Open(store.WorkspaceDir(data, closedID), store.Options{})
	_ = closed.RecordLocalRun(context.Background(), store.LocalRun{ExecutionID: "exec_1", State: store.LocalSucceeded})
	_ = closed.Close()

	usage, err := m.Usage(context.Background(), nil)
	if err != nil || len(usage) != 2 {
		t.Fatalf("usage = %+v, %v", usage, err)
	}
	byID := map[string]Usage{}
	for _, u := range usage {
		byID[u.WorkspaceID] = u
	}
	open := byID["5ce88ff0-5c16-43b3-8f20-8e33e852b019"]
	if !open.Open || open.CachedRuns != 1 || open.State != store.Persistent {
		t.Fatalf("open = %+v", open)
	}
	if c := byID[closedID]; c.Open || c.LocalRuns != 1 {
		t.Fatalf("closed = %+v", c)
	}
	absent, _ := m.Usage(context.Background(), []string{wsB})
	if len(absent) != 1 || absent[0].State != 0 {
		t.Fatalf("absent = %+v", absent)
	}

	cleared, err := m.ClearCache(context.Background(), nil)
	if err != nil || len(cleared) != 2 {
		t.Fatalf("cleared = %+v, %v", cleared, err)
	}
	if err := m.Delete(wsA); !errors.Is(err, ErrOpen) {
		t.Fatalf("delete open = %v", err)
	}
	if err := m.Delete(closedID); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(store.WorkspaceDir(data, closedID)); !os.IsNotExist(err) {
		t.Fatal("closed workspace kept")
	}
}

func TestTurningLogsOffDeletesKeptLogsEverywhere(t *testing.T) {
	_, accounts := newFake(t)
	data := t.TempDir()
	m := newRuntimes(t, data)
	_ = m.SetKeepLogs(true, false)
	r, _ := m.Attach(wsA, "repo_1", fixedResolver(accounts, "o", "r"))
	r.KeepLog(context.Background(), 11, []byte("open"), store.LogMeta{})
	closedID := "7ce88ff0-5c16-43b3-8f20-8e33e852b019"
	closed, _ := store.Open(store.WorkspaceDir(data, closedID), store.Options{})
	_ = closed.PutLog(context.Background(), 12, []byte("closed"), store.LogMeta{})
	_ = closed.Close()

	if err := m.SetKeepLogs(false, true); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"5ce88ff0-5c16-43b3-8f20-8e33e852b019", closedID} {
		if entries, _ := os.ReadDir(filepath.Join(store.WorkspaceDir(data, id), "blobs")); len(entries) != 0 {
			t.Fatalf("%s kept %v", id, entries)
		}
	}
	if m.KeepLogs() {
		t.Fatal("setting not stored")
	}
}

func TestLocalRunsAreRecordedFromExecutionEvents(t *testing.T) {
	_, accounts := newFake(t)
	m := newRuntimes(t, t.TempDir())
	r, _ := m.Attach(wsA, "repo_1", fixedResolver(accounts, "o", "r"))
	at := time.Date(2026, 10, 22, 12, 0, 0, 0, time.UTC)
	m.RecordLocalRun("repo_1", store.LocalRun{ExecutionID: "exec_1", WorkflowPath: ".github/workflows/ci.yml", StartedAt: at, State: store.LocalQueued})
	m.ObserveExecution(events.Event{Type: corev1.CoreEventType_CORE_EVENT_TYPE_WORKFLOW_STARTED, RepositoryID: "repo_1", ExecutionID: "exec_1",
		ExecutionState: corev1.ExecutionState_EXECUTION_STATE_RUNNING, At: at})
	m.ObserveExecution(events.Event{Type: corev1.CoreEventType_CORE_EVENT_TYPE_WORKFLOW_FAILED, RepositoryID: "repo_1", ExecutionID: "exec_1",
		ExecutionState: corev1.ExecutionState_EXECUTION_STATE_FAILED, Message: "act exited with 1", At: at.Add(time.Minute)})
	// Executions that were not recorded as local runs are ignored.
	m.ObserveExecution(events.Event{RepositoryID: "repo_1", ExecutionID: "exec_other", ExecutionState: corev1.ExecutionState_EXECUTION_STATE_FAILED})
	m.recorder.flush()
	runs, _ := r.Store().LocalRuns(context.Background(), 10)
	if len(runs) != 1 || runs[0].State != store.LocalFailed || runs[0].Message != "act exited with 1" || !runs[0].FinishedAt.Equal(at.Add(time.Minute)) {
		t.Fatalf("runs = %+v", runs)
	}
}

func TestWithoutADataDirNothingIsWritten(t *testing.T) {
	_, accounts := newFake(t)
	m := newRuntimes(t, "")
	r, err := m.Attach(wsA, "repo_1", fixedResolver(accounts, "o", "r"))
	if err != nil || r.Store().Report().State != store.MemoryOnly || r.Store().Dir() != "" {
		t.Fatalf("report = %+v, %v", r.Store().Report(), err)
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/workspace/`
Expected: FAIL to build (`r.Jobs undefined`, `New undefined`).

- [ ] **Step 3: Implement**

`core/internal/workspace/jobs.go`:

```go
package workspace

import (
	"context"
	"fmt"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
)

// Jobs returns a run's jobs: from the cache when they cannot have changed
// since they were read (a finished run's jobs read after its last update)
// or were read moments ago; otherwise read once for every caller asking at
// the same time.
func (r *Runtime) Jobs(ctx context.Context, runID int64) ([]github.Job, corev1.GithubAccess, time.Time, error) {
	r.mu.Lock()
	resolve := r.resolve
	r.mu.Unlock()
	target, problem := resolve()
	if problem != corev1.GithubAccess_GITHUB_ACCESS_OK {
		return nil, problem, time.Time{}, nil
	}
	if jobs, ok := r.cachedJobs(ctx, runID, target); ok {
		return jobs, corev1.GithubAccess_GITHUB_ACCESS_OK, time.Time{}, nil
	}
	ch := r.flights.DoChan(fmt.Sprintf("jobs:%d", runID), func() (any, error) {
		fetchCtx, cancel := context.WithTimeout(r.ctx, r.cfg.intervals.FetchTimeout)
		defer cancel()
		jobs, err := target.Account.Client.Jobs(fetchCtx, target.Owner, target.Name, runID)
		if err != nil {
			return nil, err
		}
		if run, known, _ := r.cfg.store.Run(r.ctx, runID); known {
			_ = r.cfg.store.PutJobs(r.ctx, runID, run.RunAttempt, r.cfg.now(), jobs)
		}
		return jobs, nil
	})
	select {
	case result := <-ch:
		if result.Err != nil {
			access, retry, cancelled := Access(target.Account, result.Err)
			if cancelled != nil {
				if ctx.Err() != nil {
					return nil, 0, time.Time{}, ctx.Err()
				}
				access = corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE
			}
			return nil, access, retry, nil
		}
		return result.Val.([]github.Job), corev1.GithubAccess_GITHUB_ACCESS_OK, time.Time{}, nil
	case <-ctx.Done():
		return nil, 0, time.Time{}, ctx.Err()
	}
}

func (r *Runtime) cachedJobs(ctx context.Context, runID int64, target Target) ([]github.Job, bool) {
	source, has, err := r.cfg.store.CacheSource(ctx)
	if err != nil || !has || source != target.Source() {
		return nil, false
	}
	cached, ok, err := r.cfg.store.Jobs(ctx, runID)
	if err != nil || !ok {
		return nil, false
	}
	if r.cfg.now().Sub(cached.FetchedAt) < r.cfg.intervals.JobsReuse {
		return cached.Jobs, true
	}
	run, known, err := r.cfg.store.Run(ctx, runID)
	if err != nil || !known {
		return nil, false
	}
	if run.Status == "completed" && cached.Attempt == run.RunAttempt && !cached.FetchedAt.Before(run.UpdatedAt) {
		return cached.Jobs, true
	}
	return nil, false
}
```

`core/internal/workspace/logs.go`:

```go
package workspace

import (
	"context"
	"fmt"
	"time"

	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

// CompletedJob returns a cached job that has finished, so its log can be
// read without asking GitHub for the job again.
func (r *Runtime) CompletedJob(ctx context.Context, jobID int64) (github.Job, bool) {
	job, ok, err := r.cfg.store.Job(ctx, jobID)
	if err != nil || !ok || job.Status != "completed" {
		return github.Job{}, false
	}
	return job, true
}

// KeptLog returns a log kept on this Mac, while keeping logs is on.
func (r *Runtime) KeptLog(ctx context.Context, jobID int64) ([]byte, store.LogMeta, bool) {
	if !r.cfg.keepLogs() {
		return nil, store.LogMeta{}, false
	}
	data, meta, ok, err := r.cfg.store.Log(ctx, jobID)
	return data, meta, ok && err == nil
}

// KeepLog stores a completed job's log, while keeping logs is on.
func (r *Runtime) KeepLog(ctx context.Context, jobID int64, data []byte, meta store.LogMeta) {
	if r.cfg.keepLogs() {
		_ = r.cfg.store.PutLog(ctx, jobID, data, meta)
	}
}

// SharedLog runs one download per job for every caller asking at the same
// time. The download runs on the runtime's context with timeout, so a
// caller giving up does not cancel it for the others.
func (r *Runtime) SharedLog(ctx context.Context, jobID int64, timeout time.Duration, fetch func(context.Context) (github.JobLog, error)) (github.JobLog, error) {
	ch := r.flights.DoChan(fmt.Sprintf("log:%d", jobID), func() (any, error) {
		fetchCtx, cancel := context.WithTimeout(r.ctx, timeout)
		defer cancel()
		return fetch(fetchCtx)
	})
	select {
	case result := <-ch:
		if result.Err != nil {
			return github.JobLog{}, result.Err
		}
		return result.Val.(github.JobLog), nil
	case <-ctx.Done():
		return github.JobLog{}, ctx.Err()
	}
}
```

`core/internal/workspace/recorder.go`:

```go
package workspace

import "sync"

// recorder runs local-history writes in order on one goroutine, so event
// callbacks that must not block only queue work.
type recorder struct {
	mu     sync.Mutex
	cond   *sync.Cond
	queue  []func()
	busy   bool
	closed bool
	signal chan struct{}
	done   chan struct{}
}

func newRecorder() *recorder {
	q := &recorder{signal: make(chan struct{}, 1), done: make(chan struct{})}
	q.cond = sync.NewCond(&q.mu)
	go q.run()
	return q
}

func (q *recorder) add(task func()) {
	q.mu.Lock()
	if q.closed {
		q.mu.Unlock()
		return
	}
	q.queue = append(q.queue, task)
	q.mu.Unlock()
	select {
	case q.signal <- struct{}{}:
	default:
	}
}

func (q *recorder) run() {
	defer close(q.done)
	for range q.signal {
		for {
			q.mu.Lock()
			if len(q.queue) == 0 {
				q.busy = false
				q.cond.Broadcast()
				q.mu.Unlock()
				break
			}
			task := q.queue[0]
			q.queue = q.queue[1:]
			q.busy = true
			q.mu.Unlock()
			task()
		}
	}
}

// flush waits until every queued write ran.
func (q *recorder) flush() {
	q.mu.Lock()
	for len(q.queue) > 0 || q.busy {
		q.cond.Wait()
	}
	q.mu.Unlock()
}

func (q *recorder) close() {
	q.flush()
	q.mu.Lock()
	if !q.closed {
		q.closed = true
		close(q.signal)
	}
	q.mu.Unlock()
	<-q.done
}
```

Note: `flush` can return before a task queued but not yet signalled runs only if `busy` is false and the queue empty — `add` appends under the lock, so a non-empty queue keeps `flush` waiting until `run` drains it.

`core/internal/workspace/runtimes.go`:

```go
package workspace

import (
	"context"
	"errors"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"runnir/core/internal/events"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/store"
)

var (
	// ErrMismatch: the repository context is bound to another workspace.
	ErrMismatch = errors.New("the repository is open for another workspace")
	// ErrOpen: the workspace is open, so its data cannot be deleted.
	ErrOpen = errors.New("the workspace is open")
)

type Options struct {
	// DataDir holds repositories/<workspaceId>/; "" keeps every store in memory.
	DataDir   string
	Publish   func(events.Event)
	Now       func() time.Time
	Intervals Intervals
}

// Usage is what one workspace keeps; State 0 means nothing on disk.
type Usage struct {
	WorkspaceID string
	State       store.State
	Note        string
	Open        bool
	store.Usage
}

// Runtimes holds one Runtime per open workspace. Safe for concurrent use.
type Runtimes struct {
	opts     Options
	now      func() time.Time
	keepLogs atomic.Bool
	recorder *recorder

	mu           sync.Mutex
	byWorkspace  map[string]*Runtime
	byRepository map[string]string
	// local maps execution ids recorded as local runs to their repository.
	local map[string]string
}

func New(opts Options) *Runtimes {
	if opts.Intervals.Active == 0 {
		opts.Intervals = DefaultIntervals()
	}
	now := opts.Now
	if now == nil {
		now = time.Now
	}
	return &Runtimes{opts: opts, now: now, recorder: newRecorder(),
		byWorkspace: map[string]*Runtime{}, byRepository: map[string]string{}, local: map[string]string{}}
}

// Attach binds an open repository context to its workspace, starting the
// workspace's runtime on first use. Another context of the same workspace
// (a relinked folder) takes the runtime over.
func (m *Runtimes) Attach(workspaceID, repositoryID string, resolve Resolver) (*Runtime, error) {
	id, ok := store.NormalizeWorkspaceID(workspaceID)
	if !ok {
		return nil, store.ErrInvalidWorkspace
	}
	for {
		m.mu.Lock()
		if other, bound := m.byRepository[repositoryID]; bound && other != id {
			m.mu.Unlock()
			return nil, ErrMismatch
		}
		if rt, ok := m.byWorkspace[id]; ok {
			if previous := rt.RepositoryID(); previous != repositoryID {
				delete(m.byRepository, previous)
				m.byRepository[repositoryID] = id
				m.mu.Unlock()
				rt.rebind(repositoryID, resolve)
				return rt, nil
			}
			m.mu.Unlock()
			return rt, nil
		}
		m.mu.Unlock()

		// Opening may migrate or recover; other workspaces are not held up.
		st, err := store.Open(m.dir(id), store.Options{Now: m.now})
		if err != nil {
			return nil, err
		}
		m.mu.Lock()
		if _, raced := m.byWorkspace[id]; raced {
			m.mu.Unlock()
			_ = st.Close()
			continue
		}
		rt := newRuntime(id, repositoryID, resolve, config{store: st, publish: m.opts.Publish, now: m.now,
			intervals: m.opts.Intervals, keepLogs: m.keepLogs.Load})
		m.byWorkspace[id] = rt
		m.byRepository[repositoryID] = id
		m.mu.Unlock()
		rt.start()
		return rt, nil
	}
}

func (m *Runtimes) dir(id string) string {
	if m.opts.DataDir == "" {
		return ""
	}
	return store.WorkspaceDir(m.opts.DataDir, id)
}

func (m *Runtimes) ForRepository(repositoryID string) (*Runtime, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	rt, ok := m.byWorkspace[m.byRepository[repositoryID]]
	return rt, ok
}

// Detach closes the runtime bound to a repository context that closed:
// queued history is written, the loop stops, the store is closed.
func (m *Runtimes) Detach(repositoryID string) {
	m.mu.Lock()
	id, ok := m.byRepository[repositoryID]
	if !ok {
		m.mu.Unlock()
		return
	}
	rt := m.byWorkspace[id]
	delete(m.byRepository, repositoryID)
	delete(m.byWorkspace, id)
	m.mu.Unlock()
	m.recorder.flush()
	rt.Close()
	_ = rt.cfg.store.Close()
}

func (m *Runtimes) all() []*Runtime {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]*Runtime, 0, len(m.byWorkspace))
	for _, rt := range m.byWorkspace {
		out = append(out, rt)
	}
	return out
}

func (m *Runtimes) open(id string) *Runtime {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.byWorkspace[id]
}

// CredentialChanged lets the runtimes that use the server sync again.
func (m *Runtimes) CredentialChanged(serverID string) {
	for _, rt := range m.all() {
		rt.credentialChanged(serverID)
	}
}

func (m *Runtimes) KeepLogs() bool { return m.keepLogs.Load() }

// SetKeepLogs turns keeping completed jobs' logs on or off; deleteKept with
// off also deletes what every workspace kept so far.
func (m *Runtimes) SetKeepLogs(keep, deleteKept bool) error {
	m.keepLogs.Store(keep)
	if keep || !deleteKept {
		return nil
	}
	var errs []error
	open := map[string]bool{}
	for _, rt := range m.all() {
		open[rt.WorkspaceID()] = true
		errs = append(errs, rt.cfg.store.DeleteLogs(context.Background()))
	}
	if m.opts.DataDir != "" {
		ids, err := store.Workspaces(m.opts.DataDir)
		errs = append(errs, err)
		for _, id := range ids {
			if !open[id] {
				errs = append(errs, store.DeleteKeptLogs(m.opts.DataDir, id))
			}
		}
	}
	return errors.Join(errs...)
}

// ids normalizes requested ids; none means every workspace on disk and
// every open one.
func (m *Runtimes) ids(requested []string) ([]string, error) {
	if len(requested) > 0 {
		out := make([]string, 0, len(requested))
		for _, raw := range requested {
			id, ok := store.NormalizeWorkspaceID(raw)
			if !ok {
				return nil, store.ErrInvalidWorkspace
			}
			out = append(out, id)
		}
		return out, nil
	}
	seen := map[string]bool{}
	var out []string
	if m.opts.DataDir != "" {
		onDisk, err := store.Workspaces(m.opts.DataDir)
		if err != nil {
			return nil, err
		}
		for _, id := range onDisk {
			seen[id] = true
			out = append(out, id)
		}
	}
	for _, rt := range m.all() {
		if !seen[rt.WorkspaceID()] {
			out = append(out, rt.WorkspaceID())
		}
	}
	return out, nil
}

func (m *Runtimes) Usage(ctx context.Context, requested []string) ([]Usage, error) {
	ids, err := m.ids(requested)
	if err != nil {
		return nil, err
	}
	out := make([]Usage, 0, len(ids))
	for _, id := range ids {
		u, err := m.usage(ctx, id)
		if err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, nil
}

func (m *Runtimes) usage(ctx context.Context, id string) (Usage, error) {
	if rt := m.open(id); rt != nil {
		su, err := rt.cfg.store.Usage(ctx)
		report := rt.cfg.store.Report()
		return Usage{WorkspaceID: id, State: report.State, Note: report.Note, Open: true, Usage: su}, err
	}
	st, ok, err := m.openClosed(id)
	if err != nil || !ok {
		return Usage{WorkspaceID: id}, err
	}
	defer st.Close()
	su, err := st.Usage(ctx)
	report := st.Report()
	return Usage{WorkspaceID: id, State: report.State, Note: report.Note, Usage: su}, err
}

// openClosed opens the store of a workspace that is not open, if it has a
// directory.
func (m *Runtimes) openClosed(id string) (*store.Store, bool, error) {
	if m.opts.DataDir == "" {
		return nil, false, nil
	}
	if _, err := os.Lstat(m.dir(id)); errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	st, err := store.Open(m.dir(id), store.Options{Now: m.now})
	return st, err == nil, err
}

// ClearCache clears the cache of each workspace (all when none are named)
// and returns their usage afterwards.
func (m *Runtimes) ClearCache(ctx context.Context, requested []string) ([]Usage, error) {
	ids, err := m.ids(requested)
	if err != nil {
		return nil, err
	}
	for _, id := range ids {
		if rt := m.open(id); rt != nil {
			if err := rt.ClearCache(ctx); err != nil {
				return nil, err
			}
			continue
		}
		st, ok, err := m.openClosed(id)
		if err != nil {
			return nil, err
		}
		if ok {
			clearErr := st.ClearCache(ctx)
			_ = st.Close()
			if clearErr != nil {
				return nil, clearErr
			}
		}
	}
	return m.Usage(ctx, ids)
}

// Delete removes a workspace's whole directory; refused while it is open.
func (m *Runtimes) Delete(raw string) error {
	id, ok := store.NormalizeWorkspaceID(raw)
	if !ok {
		return store.ErrInvalidWorkspace
	}
	if m.open(id) != nil {
		return ErrOpen
	}
	if m.opts.DataDir == "" {
		return nil
	}
	return store.DeleteWorkspace(m.opts.DataDir, id)
}

// RecordLocalRun queues a local run's record. Call it before the execution
// starts, so its events are written after it.
func (m *Runtimes) RecordLocalRun(repositoryID string, run store.LocalRun) {
	m.mu.Lock()
	rt, ok := m.byWorkspace[m.byRepository[repositoryID]]
	if ok {
		m.local[run.ExecutionID] = repositoryID
	}
	m.mu.Unlock()
	if !ok {
		return
	}
	m.recorder.add(func() { _ = rt.cfg.store.RecordLocalRun(context.Background(), run) })
}

// LocalRunNotStarted marks a recorded run that could not start as failed.
func (m *Runtimes) LocalRunNotStarted(executionID, message string) {
	m.ObserveExecution(events.Event{ExecutionID: executionID, ExecutionState: corev1.ExecutionState_EXECUTION_STATE_FAILED,
		Message: message, At: m.now()})
}

// ObserveExecution writes a recorded local run's state change. It only
// queues work: it is called from the execution coordinator's callback.
func (m *Runtimes) ObserveExecution(e events.Event) {
	if e.ExecutionID == "" {
		return
	}
	state, ok := localState(e.ExecutionState)
	if !ok {
		return
	}
	m.mu.Lock()
	repositoryID, known := m.local[e.ExecutionID]
	var rt *Runtime
	if known {
		rt = m.byWorkspace[m.byRepository[repositoryID]]
		if state != store.LocalQueued && state != store.LocalRunning {
			delete(m.local, e.ExecutionID)
		}
	}
	m.mu.Unlock()
	if rt == nil {
		return
	}
	at := e.At
	if at.IsZero() {
		at = m.now()
	}
	m.recorder.add(func() { _ = rt.cfg.store.UpdateLocalRun(context.Background(), e.ExecutionID, state, at, e.Message) })
}

func localState(state corev1.ExecutionState) (string, bool) {
	switch state {
	case corev1.ExecutionState_EXECUTION_STATE_QUEUED:
		return store.LocalQueued, true
	case corev1.ExecutionState_EXECUTION_STATE_RUNNING:
		return store.LocalRunning, true
	case corev1.ExecutionState_EXECUTION_STATE_SUCCEEDED:
		return store.LocalSucceeded, true
	case corev1.ExecutionState_EXECUTION_STATE_FAILED:
		return store.LocalFailed, true
	case corev1.ExecutionState_EXECUTION_STATE_CANCELLED:
		return store.LocalCancelled, true
	}
	return "", false
}

// Shutdown closes every runtime after the queued history is written.
func (m *Runtimes) Shutdown() {
	m.mu.Lock()
	repositories := make([]string, 0, len(m.byRepository))
	for repositoryID := range m.byRepository {
		repositories = append(repositories, repositoryID)
	}
	m.mu.Unlock()
	for _, repositoryID := range repositories {
		m.Detach(repositoryID)
	}
	m.recorder.close()
}
```

- [ ] **Step 4: Run the tests**

Run: `go test -race ./internal/workspace/ ./internal/store/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/workspace
git commit -m "Share jobs and log reads per workspace and record local runs"
```

---

### Task 9: Server and CLI wiring

**Files:**
- Modify: `core/internal/server/server.go` (Options.DataDir, wiring), `service.go` (field, OpenRepository, RefreshRepository, credentials), `github.go` (`githubStatus` via `workspace.Access`, `ListRunJobs`), `runs.go` (`GetJobLog`), `localruns.go` (`ConfirmLocalRun`)
- Create: `core/internal/server/workspace.go`
- Modify: `core/cmd/runnir/main.go`, `core/cmd/runnir/main_test.go`
- Test: `core/internal/server/workspace_test.go`

**Interfaces:**
- Consumes: everything from Tasks 1–8; generated messages from Task 6.
- Produces: the six RPCs; `Options.DataDir`; `runnir serve --data-dir PATH`.

- [ ] **Step 1: Write the failing tests**

`core/internal/server/workspace_test.go`:

```go
//go:build !windows

package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

const testWorkspace = "5CE88FF0-5C16-43B3-8F20-8E33E852B019"

type countingGitHub struct {
	runs, jobs atomic.Int64
}

func (c *countingGitHub) server(t *testing.T) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/o/r/actions/runs":
			c.runs.Add(1)
			if r.Header.Get("If-None-Match") == `"v1"` {
				w.WriteHeader(http.StatusNotModified)
				return
			}
			w.Header().Set("ETag", `"v1"`)
			_, _ = w.Write([]byte(`{"workflow_runs":[{"id":7,"workflow_id":3,"name":"CI","run_number":12,"run_attempt":1,"event":"push","status":"completed","conclusion":"success","head_branch":"main","created_at":"2026-10-18T10:00:00Z","updated_at":"2026-10-18T10:04:00Z"}]}`))
		case "/repos/o/r/actions/workflows":
			_, _ = w.Write([]byte(`{"total_count":1,"workflows":[{"id":3,"name":"CI","path":".github/workflows/ci.yml","state":"active"}]}`))
		case "/repos/o/r/actions/runs/7/jobs":
			c.jobs.Add(1)
			_, _ = w.Write([]byte(`{"jobs":[{"id":1,"name":"build","status":"completed","conclusion":"success","steps":[]}]}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)
	return server
}

func workspaceRig(t *testing.T, data, githubURL string) (corev1.RunnirCoreClient, func() error, context.Context) {
	t.Helper()
	path := socketPath(t)
	stop := startWith(t, path, Options{GitHubBaseURL: githubURL, DataDir: data})
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	t.Cleanup(cancel)
	if _, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghu_test"}); err != nil {
		t.Fatal(err)
	}
	return client, stop, ctx
}

func TestWindowsOfOneWorkspaceShareOneSync(t *testing.T) {
	counts := &countingGitHub{}
	fake := counts.server(t)
	client, stop, ctx := workspaceRig(t, t.TempDir(), fake.URL)
	defer stop()
	repo := linkedRepository(t, "git@github.com:o/r.git")
	first, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo, WorkspaceId: testWorkspace})
	if err != nil {
		t.Fatal(err)
	}
	second, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo, WorkspaceId: testWorkspace})
	if err != nil || second.Repository.Id != first.Repository.Id {
		t.Fatalf("second window = %v, %v", second, err)
	}
	id := first.Repository.Id
	activity, err := client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: id, Wait: true})
	if err != nil || len(activity.Runs) != 1 || activity.Freshness.Source != corev1.ActivitySource_ACTIVITY_SOURCE_LIVE ||
		activity.Freshness.Status.GetAccess() != corev1.GithubAccess_GITHUB_ACCESS_OK {
		t.Fatalf("activity = %v, %v", activity, err)
	}
	before := counts.runs.Load()
	var wg sync.WaitGroup
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: id, Wait: true}); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if added := counts.runs.Load() - before; added < 1 || added > 2 {
		t.Fatalf("six windows refreshing made %d runs requests", added)
	}
	for i := 0; i < 3; i++ {
		jobs, err := client.ListRunJobs(ctx, &corev1.ListRunJobsRequest{RepositoryId: id, RunId: 7})
		if err != nil || len(jobs.Jobs) != 1 {
			t.Fatalf("jobs = %v, %v", jobs, err)
		}
	}
	if counts.jobs.Load() != 1 {
		t.Fatalf("jobs requests = %d", counts.jobs.Load())
	}
}

func TestCachedActivityIsShownAfterARestartWithoutGitHub(t *testing.T) {
	counts := &countingGitHub{}
	fake := counts.server(t)
	data := t.TempDir()
	repo := linkedRepository(t, "git@github.com:o/r.git")
	client, stop, ctx := workspaceRig(t, data, fake.URL)
	opened, _ := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo, WorkspaceId: testWorkspace})
	if _, err := client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: opened.Repository.Id, Wait: true}); err != nil {
		t.Fatal(err)
	}
	if err := stop(); err != nil {
		t.Fatal(err)
	}

	offline, stopOffline, ctx := workspaceRig(t, data, "http://127.0.0.1:1")
	defer stopOffline()
	reopened, err := offline.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo, WorkspaceId: testWorkspace})
	if err != nil {
		t.Fatal(err)
	}
	activity, err := offline.GetWorkspaceActivity(ctx, &corev1.GetWorkspaceActivityRequest{RepositoryId: reopened.Repository.Id})
	if err != nil || len(activity.Runs) != 1 || len(activity.Workflows) != 1 || activity.Freshness.Source != corev1.ActivitySource_ACTIVITY_SOURCE_CACHE {
		t.Fatalf("cached = %v, %v", activity, err)
	}
	after, err := offline.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: reopened.Repository.Id, Wait: true})
	if err != nil || len(after.Runs) != 1 || after.Freshness.Status.GetAccess() != corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE {
		t.Fatalf("offline refresh = %v, %v", after, err)
	}
}

func TestStorageCallsOverGRPC(t *testing.T) {
	counts := &countingGitHub{}
	fake := counts.server(t)
	client, stop, ctx := workspaceRig(t, t.TempDir(), fake.URL)
	defer stop()
	opened, _ := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.com:o/r.git"), WorkspaceId: testWorkspace})
	id := opened.Repository.Id
	_, _ = client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: id, Wait: true})

	usage, err := client.GetStorageUsage(ctx, &corev1.GetStorageUsageRequest{})
	if err != nil || len(usage.Workspaces) != 1 || usage.Workspaces[0].CachedRuns != 1 || !usage.Workspaces[0].Open ||
		usage.Workspaces[0].State != corev1.StorageState_STORAGE_STATE_PERSISTENT || usage.Workspaces[0].WorkspaceId != "5ce88ff0-5c16-43b3-8f20-8e33e852b019" {
		t.Fatalf("usage = %v, %v", usage, err)
	}
	if _, err := client.SetStoragePreferences(ctx, &corev1.SetStoragePreferencesRequest{KeepJobLogs: true}); err != nil {
		t.Fatal(err)
	}
	if usage, _ := client.GetStorageUsage(ctx, &corev1.GetStorageUsageRequest{}); !usage.KeepJobLogs {
		t.Fatal("preference not kept")
	}
	if _, err := client.ClearWorkspaceCache(ctx, &corev1.ClearWorkspaceCacheRequest{WorkspaceIds: []string{testWorkspace}}); err != nil {
		t.Fatal(err)
	}
	_, err = client.DeleteWorkspaceData(ctx, &corev1.DeleteWorkspaceDataRequest{WorkspaceId: testWorkspace})
	if status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("delete while open = %v", err)
	}
	if _, err := client.CloseRepository(ctx, &corev1.CloseRepositoryRequest{RepositoryId: id}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.DeleteWorkspaceData(ctx, &corev1.DeleteWorkspaceDataRequest{WorkspaceId: testWorkspace}); err != nil {
		t.Fatal(err)
	}
	if usage, _ := client.GetStorageUsage(ctx, &corev1.GetStorageUsageRequest{}); len(usage.Workspaces) != 0 {
		t.Fatalf("after delete = %v", usage)
	}
}

func TestWorkspaceIDsAreChecked(t *testing.T) {
	client, stop, ctx := workspaceRig(t, t.TempDir(), "http://127.0.0.1:1")
	defer stop()
	repo := linkedRepository(t, "git@github.com:o/r.git")
	if _, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo, WorkspaceId: "../x"}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("bad id = %v", err)
	}
	plain, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.GetWorkspaceActivity(ctx, &corev1.GetWorkspaceActivityRequest{RepositoryId: plain.Repository.Id}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("no workspace = %v", err)
	}
	if _, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo, WorkspaceId: testWorkspace}); err != nil {
		t.Fatal(err)
	}
	other := "6ce88ff0-5c16-43b3-8f20-8e33e852b019"
	if _, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo, WorkspaceId: other}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("other workspace = %v", err)
	}
	if _, err := client.GetWorkspaceActivity(ctx, &corev1.GetWorkspaceActivityRequest{RepositoryId: plain.Repository.Id, Limit: 201}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("limit = %v", err)
	}
}

func TestWithoutADataDirWorkspacesStayInMemory(t *testing.T) {
	client, stop, ctx := workspaceRig(t, "", "http://127.0.0.1:1")
	defer stop()
	_, _ = client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.com:o/r.git"), WorkspaceId: testWorkspace})
	usage, err := client.GetStorageUsage(ctx, &corev1.GetStorageUsageRequest{})
	if err != nil || len(usage.Workspaces) != 1 || usage.Workspaces[0].State != corev1.StorageState_STORAGE_STATE_MEMORY_ONLY {
		t.Fatalf("usage = %v, %v", usage, err)
	}
}

func TestActivityChangesAreAnnounced(t *testing.T) {
	counts := &countingGitHub{}
	fake := counts.server(t)
	client, stop, ctx := workspaceRig(t, t.TempDir(), fake.URL)
	defer stop()
	stream, err := client.SubscribeEvents(ctx, &corev1.SubscribeEventsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	next(t, stream) // CORE_READY
	opened, _ := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.com:o/r.git"), WorkspaceId: testWorkspace})
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		e := next(t, stream)
		if e.Type == corev1.CoreEventType_CORE_EVENT_TYPE_ACTIVITY_CHANGED && e.RepositoryId == opened.Repository.Id {
			return
		}
	}
	t.Fatal("no ACTIVITY_CHANGED event")
}
```

In `core/cmd/runnir/main_test.go`, add to the usage test: `serve --socket x --data-dir relative/path` exits 2.

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/server/ -run 'Workspace|Storage|Activity|Cached|Windows'`
Expected: FAIL to build (`unknown field DataDir in struct literal`).

- [ ] **Step 3: Implement**

`server.go`: add to `Options`:

```go
	// DataDir is the app's support folder; each workspace keeps its database
	// in DataDir/repositories/<workspaceId>. Empty keeps everything in memory.
	DataDir string
```

In `RunWithOptions`, after `outputs := localrun.NewOutputs()`:

```go
	workspaces := workspace.New(workspace.Options{DataDir: options.DataDir, Publish: bus.Publish})
	// Registered before repositories.Shutdown, so it runs after it: closing
	// the repositories detaches their runtimes first.
	defer workspaces.Shutdown()
```

Change the executions callback to `func(e events.Event) { outputs.Observe(e); workspaces.ObserveExecution(e); bus.Publish(e) }` and the repositories callback to:

```go
	repositories := repository.New(scanner.New(), func(e repository.Event) {
		if e.Type == repository.RepositoryClosed {
			executions.CancelRepository(e.RepositoryID)
			workspaces.Detach(e.RepositoryID)
		}
		bus.Publish(fromRepository(e))
	})
```

and pass `workspaces: workspaces` to the `service` literal.

`service.go`: add the field `workspaces *workspace.Runtimes` (comment: "one runtime per workspace: its database and sync"). Replace `OpenRepository`:

```go
func (s *service) OpenRepository(ctx context.Context, request *corev1.OpenRepositoryRequest) (*corev1.RepositoryResponse, error) {
	workspaceID := request.GetWorkspaceId()
	if _, ok := store.NormalizeWorkspaceID(workspaceID); workspaceID != "" && !ok {
		return nil, status.Error(codes.InvalidArgument, "workspace_id must be a UUID")
	}
	info, err := s.repositories.Open(ctx, request.GetPath())
	if err != nil {
		return nil, rpcError(err)
	}
	if workspaceID != "" {
		if _, err := s.workspaces.Attach(workspaceID, info.ID, s.workspaceResolver(info.ID)); errors.Is(err, workspace.ErrMismatch) {
			return nil, status.Error(codes.FailedPrecondition, "this folder is open for another workspace")
		} else if err != nil {
			return nil, status.Error(codes.Internal, "the workspace could not be opened")
		}
	}
	return &corev1.RepositoryResponse{Repository: s.repositoryMessage(info)}, nil
}
```

In `RefreshRepository`, after a successful refresh: `if rt, ok := s.workspaces.ForRepository(info.ID); ok { _ = rt.Refresh(ctx, false) }` (the origin may have changed, and Refresh in the app means "read again"). In `SetGitHubCredential` before returning: `s.workspaces.CredentialChanged(account.Server.ID)`; in `ClearGitHubCredential`: `s.workspaces.CredentialChanged(request.GetServerId())`.

`github.go`: replace the body of `githubStatus` with the shared mapping:

```go
func (s *service) githubStatus(account *github.Account, err error) (*corev1.GitHubStatus, error) {
	access, retry, cancelled := workspace.Access(account, err)
	if cancelled != nil {
		return nil, status.FromContextError(cancelled).Err()
	}
	return statusMessage(access, retry), nil
}

// statusMessage is a GitHub outcome for the app; retry only when rate limited.
func statusMessage(access corev1.GithubAccess, retry time.Time) *corev1.GitHubStatus {
	out := &corev1.GitHubStatus{Access: access}
	if access == corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED && !retry.IsZero() {
		out.RetryAfter = timestamppb.New(retry)
	}
	return out
}
```

Extract `jobMessage(j github.Job) *corev1.RunJob` from `ListRunJobs`, and route open workspaces through their runtime at the top of `ListRunJobs`, after the run id check:

```go
	if request.GetGithubRepository() == "" {
		if _, err := s.repositories.Get(request.GetRepositoryId()); err != nil {
			return nil, rpcError(err)
		}
		if rt, ok := s.workspaces.ForRepository(request.GetRepositoryId()); ok {
			jobs, access, retry, err := rt.Jobs(ctx, request.GetRunId())
			if err != nil {
				return nil, status.FromContextError(err).Err()
			}
			out := &corev1.ListRunJobsResponse{Status: statusMessage(access, retry)}
			for _, j := range jobs {
				out.Jobs = append(out.Jobs, jobMessage(j))
			}
			return out, nil
		}
	}
```

`runs.go`: rewrite `GetJobLog`:

```go
func (s *service) GetJobLog(ctx context.Context, request *corev1.GetJobLogRequest) (*corev1.GetJobLogResponse, error) {
	jobID := request.GetJobId()
	if jobID <= 0 {
		return nil, status.Error(codes.InvalidArgument, "job_id is required")
	}
	target, problem, err := s.githubTarget(request.GetRepositoryId(), "", "")
	if err != nil || problem != nil {
		return &corev1.GetJobLogResponse{Status: problem}, err
	}
	rt, shared := s.workspaces.ForRepository(request.GetRepositoryId())
	job, cached := github.Job{}, false
	if shared {
		job, cached = rt.CompletedJob(ctx, jobID)
	}
	if !cached {
		fetched, fetchErr := target.account.Client.Job(ctx, target.owner, target.name, jobID)
		result, err := s.githubStatus(target.account, fetchErr)
		if err != nil {
			return nil, err
		}
		if fetchErr != nil {
			return &corev1.GetJobLogResponse{Status: result}, nil
		}
		job = fetched
	}
	out := &corev1.GetJobLogResponse{Status: statusMessage(corev1.GithubAccess_GITHUB_ACCESS_OK, time.Time{})}
	if job.Status != "completed" {
		out.Availability = corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_NOT_READY
		return out, nil
	}
	if shared {
		if data, meta, ok := rt.KeptLog(ctx, jobID); ok {
			fillLog(out, job, github.JobLog{Data: data, DroppedLines: meta.DroppedLines, Truncated: meta.Truncated, StoppedEarly: meta.StoppedEarly})
			return out, nil
		}
	}
	download := func(c context.Context) (github.JobLog, error) {
		return target.account.Client.JobLog(c, target.owner, target.name, jobID, 0)
	}
	var log github.JobLog
	var logErr error
	if shared {
		log, logErr = rt.SharedLog(ctx, jobID, jobLogBudget, download)
	} else {
		// Bound the whole download so the Core answers before the app gives up.
		logCtx, cancel := context.WithTimeout(ctx, jobLogBudget)
		log, logErr = download(logCtx)
		cancel()
	}
	if errors.Is(logErr, context.DeadlineExceeded) && ctx.Err() == nil {
		logErr = github.ErrUnavailable
	}
	if errors.Is(logErr, github.ErrLogUnavailable) {
		out.Availability = missingLogAvailability(job, time.Now())
		return out, nil
	}
	if out.Status, err = s.githubStatus(target.account, logErr); err != nil {
		return nil, err
	}
	if logErr != nil {
		return out, nil
	}
	if shared {
		rt.KeepLog(ctx, jobID, log.Data, store.LogMeta{DroppedLines: log.DroppedLines, Truncated: log.Truncated, StoppedEarly: log.StoppedEarly})
	}
	fillLog(out, job, log)
	return out, nil
}

// fillLog parses a log tail into the response's lines.
func fillLog(out *corev1.GetJobLogResponse, job github.Job, log github.JobLog) {
	steps := make([]joblog.Step, 0, len(job.Steps))
	for _, step := range job.Steps {
		if step.Conclusion != "skipped" {
			steps = append(steps, joblog.Step{Number: step.Number, StartedAt: step.StartedAt})
		}
	}
	// Many short lines cost more on the wire and in memory than their text:
	// cut to the last maxLogLines before parsing, which keeps the response
	// well under the client's 4 MiB message limit.
	data, skipped := joblog.Tail(log.Data, maxLogLines)
	lines := joblog.Parse(data, int64(log.DroppedLines+skipped)+1, steps)
	out.Availability = corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_AVAILABLE
	out.Truncated = log.Truncated || skipped > 0
	out.StoppedEarly = log.StoppedEarly
	for _, line := range lines {
		out.Lines = append(out.Lines, &corev1.LogLine{Number: line.Number, Text: line.Text, Kind: lineKind(line.Kind), StepNumber: line.Step})
	}
}
```

In `workspace.CompletedJob` (Task 8 file `logs.go`), also require that the cache belongs to the runtime's current target (compare `CacheSource` with `resolve()`'s `Target.Source()`), so a job of another repository is never used.

`localruns.go` (`ConfirmLocalRun`): after `id, err := execution.NewID()` succeeds and before `StartJob`, record the run; mark it when it cannot start:

```go
	s.workspaces.RecordLocalRun(info.ID, store.LocalRun{
		ExecutionID: id, WorkflowPath: approved.Workflow.ID, JobID: approved.Spec.Plan.JobID, Event: approved.Spec.Plan.Event,
		StartedAt: time.Now(), State: store.LocalQueued, ActVersion: approved.ActVersion, Engine: approved.EngineName,
	})
	// ... StartJob ...
	if err != nil {
		s.localOutputs.Remove(id)
		s.workspaces.LocalRunNotStarted(id, "The run could not start.")
		return nil, rpcError(err)
	}
```

`workspace.go` (new, in `internal/server`):

```go
package server

import (
	"context"
	"errors"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/store"
	"runnir/core/internal/workspace"
)

const (
	defaultActivityRuns = 50
	maxActivityRuns     = 200
)

// workspaceResolver gives a workspace's runtime the GitHub repository its
// open repository's origin points at now.
func (s *service) workspaceResolver(repositoryID string) workspace.Resolver {
	return func() (workspace.Target, corev1.GithubAccess) {
		target, problem, err := s.githubTarget(repositoryID, "", "")
		if err != nil {
			return workspace.Target{}, corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE
		}
		if problem != nil {
			return workspace.Target{}, problem.Access
		}
		return workspace.Target{Account: target.account, Owner: target.owner, Name: target.name}, corev1.GithubAccess_GITHUB_ACCESS_OK
	}
}

func (s *service) runtimeFor(repositoryID string) (*workspace.Runtime, error) {
	if _, err := s.repositories.Get(repositoryID); err != nil {
		return nil, rpcError(err)
	}
	rt, ok := s.workspaces.ForRepository(repositoryID)
	if !ok {
		return nil, status.Error(codes.FailedPrecondition, "the repository was opened without a workspace")
	}
	return rt, nil
}

func activityLimit(limit uint32) (int, error) {
	switch {
	case limit == 0:
		return defaultActivityRuns, nil
	case limit > maxActivityRuns:
		return 0, status.Errorf(codes.InvalidArgument, "limit must be %d or less", maxActivityRuns)
	default:
		return int(limit), nil
	}
}

func (s *service) GetWorkspaceActivity(ctx context.Context, request *corev1.GetWorkspaceActivityRequest) (*corev1.WorkspaceActivity, error) {
	limit, err := activityLimit(request.GetLimit())
	if err != nil {
		return nil, err
	}
	rt, err := s.runtimeFor(request.GetRepositoryId())
	if err != nil {
		return nil, err
	}
	return snapshotMessage(ctx, rt, limit)
}

func (s *service) RefreshWorkspaceActivity(ctx context.Context, request *corev1.RefreshWorkspaceActivityRequest) (*corev1.WorkspaceActivity, error) {
	limit, err := activityLimit(request.GetLimit())
	if err != nil {
		return nil, err
	}
	rt, err := s.runtimeFor(request.GetRepositoryId())
	if err != nil {
		return nil, err
	}
	if err := rt.Refresh(ctx, request.GetWait()); errors.Is(err, workspace.ErrClosed) {
		return nil, status.Error(codes.NotFound, "repository not found")
	} else if err != nil {
		return nil, status.FromContextError(err).Err()
	}
	return snapshotMessage(ctx, rt, limit)
}

func snapshotMessage(ctx context.Context, rt *workspace.Runtime, limit int) (*corev1.WorkspaceActivity, error) {
	snap, err := rt.Snapshot(ctx, limit)
	if err != nil {
		if ctx.Err() != nil {
			return nil, status.FromContextError(ctx.Err()).Err()
		}
		return nil, status.Error(codes.Internal, "the workspace's activity could not be read")
	}
	freshness := &corev1.ActivityFreshness{
		Source: activitySource(snap.Provenance), Syncing: snap.Syncing,
		CheckedAt: timestamp(snap.CheckedAt), SyncedAt: timestamp(snap.SyncedAt), ChangedAt: timestamp(snap.ChangedAt),
	}
	if snap.Access != corev1.GithubAccess_GITHUB_ACCESS_UNSPECIFIED {
		freshness.Status = statusMessage(snap.Access, snap.RetryAfter)
	}
	out := &corev1.WorkspaceActivity{Freshness: freshness}
	for _, r := range snap.Runs {
		out.Runs = append(out.Runs, runMessage(r))
	}
	for _, w := range snap.Workflows {
		out.Workflows = append(out.Workflows, &corev1.GitHubWorkflow{Id: w.ID, Name: w.Name, Path: w.Path, State: w.State, HtmlUrl: w.HTMLURL})
	}
	return out, nil
}

func activitySource(p workspace.Provenance) corev1.ActivitySource {
	switch p {
	case workspace.Live:
		return corev1.ActivitySource_ACTIVITY_SOURCE_LIVE
	case workspace.Cached:
		return corev1.ActivitySource_ACTIVITY_SOURCE_CACHE
	default:
		return corev1.ActivitySource_ACTIVITY_SOURCE_NONE
	}
}

func storageMessages(usage []workspace.Usage) []*corev1.WorkspaceStorage {
	out := make([]*corev1.WorkspaceStorage, 0, len(usage))
	for _, u := range usage {
		state := corev1.StorageState_STORAGE_STATE_ABSENT
		switch u.State {
		case store.Persistent:
			state = corev1.StorageState_STORAGE_STATE_PERSISTENT
		case store.MemoryOnly:
			state = corev1.StorageState_STORAGE_STATE_MEMORY_ONLY
		}
		out = append(out, &corev1.WorkspaceStorage{
			WorkspaceId: u.WorkspaceID, State: state, Note: u.Note, Open: u.Open,
			DatabaseBytes: u.DatabaseBytes, LogBytes: u.LogBytes, CachedRuns: uint32(u.CachedRuns),
			LocalRuns: uint32(u.LocalRuns), RecoveryCopies: uint32(u.RecoveryCopies),
		})
	}
	return out
}

func storageError(err error) error {
	switch {
	case errors.Is(err, store.ErrInvalidWorkspace):
		return status.Error(codes.InvalidArgument, "workspace ids must be UUIDs")
	case errors.Is(err, workspace.ErrOpen):
		return status.Error(codes.FailedPrecondition, "close the workspace's windows first")
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return status.FromContextError(err).Err()
	default:
		return status.Error(codes.Internal, "workspace data could not be changed")
	}
}

func (s *service) GetStorageUsage(ctx context.Context, request *corev1.GetStorageUsageRequest) (*corev1.GetStorageUsageResponse, error) {
	usage, err := s.workspaces.Usage(ctx, request.GetWorkspaceIds())
	if err != nil {
		return nil, storageError(err)
	}
	return &corev1.GetStorageUsageResponse{Workspaces: storageMessages(usage), KeepJobLogs: s.workspaces.KeepLogs()}, nil
}

func (s *service) ClearWorkspaceCache(ctx context.Context, request *corev1.ClearWorkspaceCacheRequest) (*corev1.ClearWorkspaceCacheResponse, error) {
	usage, err := s.workspaces.ClearCache(ctx, request.GetWorkspaceIds())
	if err != nil {
		return nil, storageError(err)
	}
	return &corev1.ClearWorkspaceCacheResponse{Workspaces: storageMessages(usage)}, nil
}

func (s *service) DeleteWorkspaceData(_ context.Context, request *corev1.DeleteWorkspaceDataRequest) (*corev1.DeleteWorkspaceDataResponse, error) {
	if err := s.workspaces.Delete(request.GetWorkspaceId()); err != nil {
		return nil, storageError(err)
	}
	return &corev1.DeleteWorkspaceDataResponse{}, nil
}

func (s *service) SetStoragePreferences(_ context.Context, request *corev1.SetStoragePreferencesRequest) (*corev1.SetStoragePreferencesResponse, error) {
	if err := s.workspaces.SetKeepLogs(request.GetKeepJobLogs(), request.GetDeleteKeptLogs()); err != nil {
		return nil, status.Error(codes.Internal, "kept logs could not all be deleted")
	}
	return &corev1.SetStoragePreferencesResponse{}, nil
}
```

`cmd/runnir/main.go` (`serve`): add `dataDir := flags.String("data-dir", "", "the app's support folder for workspace databases")`; after parsing, `if *dataDir != "" && !filepath.IsAbs(*dataDir) { usage; return 2 }`; `options := server.Options{BundledAct: bundledAct(), DataDir: *dataDir}`; usage text `runnir serve --socket PATH [--data-dir PATH] [--exit-on-stdin-eof] [--client-secret-stdin]` (also in `run`'s usage line).

- [ ] **Step 4: Run all Core checks**

Run: `go test -race ./... && go vet ./... && CGO_ENABLED=0 go build ./...`
Expected: PASS; existing GitHub tests still pass (opens without `workspace_id` keep the live path).

- [ ] **Step 5: Commit**

```bash
git add core
git commit -m "Serve cached workspace activity and storage calls from the Core"
```

---

### Task 10: Swift IPC layer

**Files:**
- Create: `apps/macos/Runnir/IPC/CoreWorkspaceModels.swift`
- Modify: `apps/macos/Runnir/IPC/CoreService.swift`, `GRPCCoreService.swift`, `ProcessCoreLauncher.swift`, `CoreProcessSupervisor.swift`
- Modify (fakes): `apps/macos/RunnirTests/CoreHubTests.swift` (`FakeCore`), `CoreProcessSupervisorTests.swift`
- Test: `apps/macos/RunnirTests/WorkspaceCacheTests.swift`

**Interfaces:**
- Produces (Swift):

```swift
enum CoreActivitySource: Equatable, Sendable { case none, cache, live }

struct CoreActivityFreshness: Equatable, Sendable {
    var source: CoreActivitySource = .none
    var syncing = false
    /// The last pass's outcome; nil before the first.
    var access: CoreGitHubAccess?
    var checkedAt: Date?
    var syncedAt: Date?
    var changedAt: Date?
}

struct CoreWorkspaceActivity: Equatable, Sendable {
    var runs: [CoreWorkflowRun]
    var workflows: [CoreGitHubWorkflow]
    var freshness: CoreActivityFreshness
}

enum CoreStorageState: Equatable, Sendable { case persistent, memoryOnly, absent }

struct CoreWorkspaceStorage: Equatable, Identifiable, Sendable {
    let workspaceID: UUID
    let state: CoreStorageState
    let note: String?
    let isOpen: Bool
    let databaseBytes: UInt64
    let logBytes: UInt64
    let cachedRuns: Int
    let localRuns: Int
    let recoveryCopies: Int
    var id: UUID { workspaceID }
}

struct CoreStorageUsage: Equatable, Sendable {
    let workspaces: [CoreWorkspaceStorage]
    let keepJobLogs: Bool
}
```

- `CoreEventKind.activityChanged`.
- `CoreServicing`: `openRepository(path:workspaceID:)` replaces `openRepository(path:)`; new `workspaceActivity(repositoryID:limit:)`, `refreshWorkspaceActivity(repositoryID:wait:limit:)`, `storageUsage(workspaceIDs:)`, `clearWorkspaceCache(workspaceIDs:)`, `deleteWorkspaceData(workspaceID:)`, `setStoragePreferences(keepJobLogs:deleteKeptLogs:)` (signatures below).
- `ProcessCoreLauncher(executableURL:logURL:dataDirectory:)`; `static func arguments(socketPath: String, dataDirectory: URL?) -> [String]`.

- [ ] **Step 1: Write the failing tests**

`apps/macos/RunnirTests/WorkspaceCacheTests.swift` (first part; Tasks 11–12 add more):

```swift
import Foundation
import Testing
@testable import Runnir

@Suite struct CoreLaunchArgumentTests {
    @Test func theDataDirectoryIsPassedToTheCore() {
        let arguments = ProcessCoreLauncher.arguments(socketPath: "/tmp/s.sock",
                                                      dataDirectory: URL(fileURLWithPath: "/Users/me/Library/Application Support/Runnir"))
        #expect(arguments == ["serve", "--socket", "/tmp/s.sock", "--exit-on-stdin-eof", "--client-secret-stdin",
                              "--data-dir", "/Users/me/Library/Application Support/Runnir"])
        #expect(!ProcessCoreLauncher.arguments(socketPath: "/tmp/s.sock", dataDirectory: nil).contains("--data-dir"))
    }
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/CoreLaunchArgumentTests`
Expected: FAIL to compile (`arguments(socketPath:dataDirectory:)` missing).

- [ ] **Step 3: Implement**

`CoreWorkspaceModels.swift`: the types above, with doc comments.

`CoreService.swift`: in `CoreEventKind` add `case activityChanged` (comment: a workspace's cached activity or its freshness changed). In `CoreServicing` replace `openRepository(path:)` with:

```swift
    /// Opens a working tree; with `workspaceID` it gets the workspace's
    /// database and sync in the Core.
    func openRepository(path: String, workspaceID: UUID?) async throws -> CoreRepository
    /// The workspace's activity as cached on this Mac; never waits for GitHub.
    func workspaceActivity(repositoryID: String, limit: Int) async throws -> CoreWorkspaceActivity
    /// Asks the workspace's sync for a pass; with `wait`, answers after it.
    func refreshWorkspaceActivity(repositoryID: String, wait: Bool, limit: Int) async throws -> CoreWorkspaceActivity
    /// What workspaces keep on this Mac; empty ids: all with data and all open.
    func storageUsage(workspaceIDs: [UUID]) async throws -> CoreStorageUsage
    /// Deletes what can be downloaded again; empty ids: every workspace.
    func clearWorkspaceCache(workspaceIDs: [UUID]) async throws -> [CoreWorkspaceStorage]
    /// Deletes a closed workspace's data folder.
    func deleteWorkspaceData(workspaceID: UUID) async throws
    func setStoragePreferences(keepJobLogs: Bool, deleteKeptLogs: Bool) async throws
```

and add `func openRepository(path: String) async throws -> CoreRepository { try await openRepository(path: path, workspaceID: nil) }` to the protocol extension.

`GRPCCoreService.swift`:

```swift
    func openRepository(path: String, workspaceID: UUID?) async throws -> CoreRepository {
        let response = try await call {
            try await client.openRepository(.with {
                $0.path = path
                $0.workspaceID = workspaceID?.uuidString.lowercased() ?? ""
            }, options: Self.options(Self.callTimeout))
        }
        return Self.map(response.repository)
    }

    func workspaceActivity(repositoryID: String, limit: Int) async throws -> CoreWorkspaceActivity {
        let response = try await call {
            try await client.getWorkspaceActivity(.with {
                $0.repositoryID = repositoryID
                $0.limit = UInt32(clamping: limit)
            }, options: Self.options(Self.callTimeout))
        }
        return Self.map(response)
    }

    func refreshWorkspaceActivity(repositoryID: String, wait: Bool, limit: Int) async throws -> CoreWorkspaceActivity {
        // A pass reads two GitHub lists with a 20-second timeout each.
        let response = try await call {
            try await client.refreshWorkspaceActivity(.with {
                $0.repositoryID = repositoryID
                $0.wait = wait
                $0.limit = UInt32(clamping: limit)
            }, options: Self.options(.seconds(90)))
        }
        return Self.map(response)
    }

    func storageUsage(workspaceIDs: [UUID]) async throws -> CoreStorageUsage {
        let response = try await call {
            try await client.getStorageUsage(.with { $0.workspaceIds = workspaceIDs.map { $0.uuidString.lowercased() } },
                                             options: Self.options(Self.callTimeout))
        }
        return CoreStorageUsage(workspaces: response.workspaces.compactMap(Self.map), keepJobLogs: response.keepJobLogs)
    }

    func clearWorkspaceCache(workspaceIDs: [UUID]) async throws -> [CoreWorkspaceStorage] {
        let response = try await call {
            try await client.clearWorkspaceCache(.with { $0.workspaceIds = workspaceIDs.map { $0.uuidString.lowercased() } },
                                                 options: Self.options(Self.callTimeout))
        }
        return response.workspaces.compactMap(Self.map)
    }

    func deleteWorkspaceData(workspaceID: UUID) async throws {
        _ = try await call {
            try await client.deleteWorkspaceData(.with { $0.workspaceID = workspaceID.uuidString.lowercased() },
                                                 options: Self.options(Self.callTimeout))
        }
    }

    func setStoragePreferences(keepJobLogs: Bool, deleteKeptLogs: Bool) async throws {
        _ = try await call {
            try await client.setStoragePreferences(.with {
                $0.keepJobLogs = keepJobLogs
                $0.deleteKeptLogs = deleteKeptLogs
            }, options: Self.options(Self.callTimeout))
        }
    }

    static func map(_ workflow: Runnir_Core_V1_GitHubWorkflow) -> CoreGitHubWorkflow {
        CoreGitHubWorkflow(id: workflow.id, name: workflow.name, path: workflow.path, state: workflow.state, htmlURL: webURL(workflow.htmlURL))
    }

    static func map(_ activity: Runnir_Core_V1_WorkspaceActivity) -> CoreWorkspaceActivity {
        let f = activity.freshness
        let source: CoreActivitySource = switch f.source {
        case .cache: .cache
        case .live: .live
        default: .none
        }
        return CoreWorkspaceActivity(
            runs: activity.runs.map(map), workflows: activity.workflows.map(map),
            freshness: CoreActivityFreshness(
                source: source, syncing: f.syncing, access: f.hasStatus ? map(f.status) : nil,
                checkedAt: f.hasCheckedAt ? f.checkedAt.date : nil, syncedAt: f.hasSyncedAt ? f.syncedAt.date : nil,
                changedAt: f.hasChangedAt ? f.changedAt.date : nil))
    }

    static func map(_ storage: Runnir_Core_V1_WorkspaceStorage) -> CoreWorkspaceStorage? {
        guard let id = UUID(uuidString: storage.workspaceID) else { return nil }
        let state: CoreStorageState = switch storage.state {
        case .persistent: .persistent
        case .memoryOnly: .memoryOnly
        default: .absent
        }
        return CoreWorkspaceStorage(workspaceID: id, state: state, note: storage.note.isEmpty ? nil : storage.note, isOpen: storage.open,
                                    databaseBytes: storage.databaseBytes, logBytes: storage.logBytes, cachedRuns: Int(storage.cachedRuns),
                                    localRuns: Int(storage.localRuns), recoveryCopies: Int(storage.recoveryCopies))
    }
```

Use `Self.map` for workflows in `listGitHubWorkflows`. Map `.activityChanged` in `map(_ event:)`. Remove the old `openRepository(path:)` implementation.

`ProcessCoreLauncher.swift`: add `var dataDirectory: URL? = nil`; build arguments with:

```swift
    /// The Core's command line; the data directory holds the workspace databases.
    static func arguments(socketPath: String, dataDirectory: URL?) -> [String] {
        var arguments = ["serve", "--socket", socketPath, "--exit-on-stdin-eof", "--client-secret-stdin"]
        if let dataDirectory { arguments += ["--data-dir", dataDirectory.path] }
        return arguments
    }
```

and `process.arguments = Self.arguments(socketPath: socketPath, dataDirectory: dataDirectory)`.

`CoreProcessSupervisor.bundled()`: `ProcessCoreLauncher(executableURL: ..., logURL: logURL, dataDirectory: try? RunnirSupportDirectory.url())`.

Fakes: in `CoreProcessSupervisorTests.swift`'s fake service and in `FakeCore`, replace `openRepository(path:)` with `openRepository(path:workspaceID:)` (FakeCore records `workspaceID` in a new `openWorkspaceIDs` list) and add the new calls. `FakeCore` activity:

```swift
    // MARK: Workspace activity

    private var activities: [String: CoreWorkspaceActivity] = [:]
    private var _activityReads: [String] = []
    private var _activityRefreshes: [(id: String, wait: Bool)] = []
    var activityReads: [String] { lock.withLock { _activityReads } }
    var activityRefreshes: [(id: String, wait: Bool)] { lock.withLock { _activityRefreshes } }
    func setActivity(_ activity: CoreWorkspaceActivity, for path: String) { lock.withLock { activities[Self.id(for: path)] = activity } }
    /// What the Core holds for a repository: the activity set, otherwise
    /// one built from the runs set with `setRuns`, as a live pass.
    private func activity(for id: String) -> CoreWorkspaceActivity {
        if let activity = activities[id] { return activity }
        let runs = runsResults[id] ?? CoreGitHubResult(access: .ok, items: [])
        let workflows = runs.access == .ok ? [CoreGitHubWorkflow(id: 1, name: "CI", path: ".github/workflows/ci.yml", state: "active", htmlURL: nil)] : []
        return CoreWorkspaceActivity(runs: runs.items, workflows: workflows,
                                     freshness: CoreActivityFreshness(source: .live, access: runs.access, checkedAt: Date(), syncedAt: Date()))
    }
    func workspaceActivity(repositoryID: String, limit: Int) async throws -> CoreWorkspaceActivity {
        lock.withLock {
            _activityReads.append(repositoryID)
            return activity(for: repositoryID)
        }
    }
    var refreshDelayActivity: Duration?
    func refreshWorkspaceActivity(repositoryID: String, wait: Bool, limit: Int) async throws -> CoreWorkspaceActivity {
        let delay = lock.withLock { () -> Duration? in
            _activityRefreshes.append((repositoryID, wait))
            _runsCalls.append(repositoryID)
            return refreshDelayActivity ?? runsDelay
        }
        if let delay { try? await Task.sleep(for: delay) }
        return lock.withLock { activity(for: repositoryID) }
    }
    var storage = CoreStorageUsage(workspaces: [], keepJobLogs: false)
    private var _clearedCaches: [[UUID]] = []
    private var _deletedData: [UUID] = []
    private var _storagePreferences: [(keep: Bool, delete: Bool)] = []
    var clearedCaches: [[UUID]] { lock.withLock { _clearedCaches } }
    var deletedData: [UUID] { lock.withLock { _deletedData } }
    var storagePreferences: [(keep: Bool, delete: Bool)] { lock.withLock { _storagePreferences } }
    func storageUsage(workspaceIDs: [UUID]) async throws -> CoreStorageUsage { lock.withLock { storage } }
    func clearWorkspaceCache(workspaceIDs: [UUID]) async throws -> [CoreWorkspaceStorage] {
        lock.withLock { _clearedCaches.append(workspaceIDs); return storage.workspaces }
    }
    func deleteWorkspaceData(workspaceID: UUID) async throws { lock.withLock { _deletedData.append(workspaceID) } }
    func setStoragePreferences(keepJobLogs: Bool, deleteKeptLogs: Bool) async throws {
        lock.withLock { _storagePreferences.append((keepJobLogs, deleteKeptLogs)) }
    }
```

(`refreshWorkspaceActivity` also appends to `_runsCalls`, so tests that count GitHub reads through `runsCalls` keep their meaning: one entry per pass asked of the Core.)

- [ ] **Step 4: Build and run the tests**

Run: `xcodebuild ... build` and `xcodebuild ... test -only-testing:RunnirTests`
Expected: builds; `CoreLaunchArgumentTests` passes; existing tests still pass (CoreHub not changed yet).

- [ ] **Step 5: Commit**

```bash
git add apps/macos
git commit -m "Add the workspace activity and storage calls to the app's Core client"
```

---

### Task 11: CoreHub renders the cache first and follows the Core's sync

**Files:**
- Modify: `apps/macos/Runnir/IPC/CoreHub.swift`
- Modify: `apps/macos/RunnirTests/CoreHubTests.swift` (tests that relied on the Swift poll)
- Test: `apps/macos/RunnirTests/WorkspaceCacheTests.swift`

**Interfaces:**
- Consumes: Task 10 types and calls.
- Produces on `RepositorySession`: `fileprivate(set) var freshness: CoreActivityFreshness`; `githubAccess`, `isLoadingGitHub`, `githubLoadedAt` become computed from it (`freshness.access`, `freshness.syncing || isReadingActivity`, `freshness.syncedAt`); `var activitySource: CoreActivitySource { freshness.source }`.
- Produces on `CoreHub`: `loadGitHubActivity(workspaceID:)` keeps its name and now asks the Core (`refreshWorkspaceActivity(wait: true)`); new `storageUsage(workspaceIDs:) async -> CoreStorageUsage?`, `clearCache(workspaceIDs:) async -> Bool`, `deleteWorkspaceData(_ id: UUID) async -> Bool`, `setKeepJobLogs(_ keep: Bool, deleteKept: Bool) async`; `@ObservationIgnored var keepJobLogs: @MainActor () -> Bool` (default reads `StorageSettings.keepJobLogsKey` from `UserDefaults.standard`); `static let activityLimit = 50`.
- Removed: `githubPoll`, `githubPollInterval`, `githubIdlePollInterval`, `scheduleGitHubPoll`, `githubReloadPending`.

- [ ] **Step 1: Write the failing tests** (append to `WorkspaceCacheTests.swift`)

```swift
@MainActor
@Suite struct CacheFirstHubTests {
    private func readyHub() async -> (CoreHub, FakeProvider) {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        await waitUntil { if case .ready = hub.status { true } else { false } }
        return (hub, provider)
    }

    private func run(_ id: Int64) -> CoreWorkflowRun {
        CoreWorkflowRun(id: id, workflowID: 1, name: "CI", displayTitle: "t", runNumber: id, event: "push", status: "completed",
                        conclusion: "success", branch: "main", headSHA: "abc", actor: nil, htmlURL: nil)
    }

    @Test func cachedActivityShowsWithoutWaitingForGitHub() async {
        let (hub, provider) = await readyHub()
        provider.core.setActivity(CoreWorkspaceActivity(runs: [run(7)], workflows: [],
            freshness: CoreActivityFreshness(source: .cache, syncing: true, syncedAt: Date(timeIntervalSinceNow: -3600))), for: "/repo/linked")
        provider.core.refreshDelayActivity = .seconds(60) // GitHub never answers
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        await waitUntil { hub.session(for: workspace)?.runs.count == 1 }
        let session = hub.session(for: workspace)
        #expect(session?.activitySource == .cache)
        #expect(session?.isLoadingGitHub == true)
        #expect(provider.core.activityRefreshes.isEmpty)
        #expect(provider.core.openWorkspaceIDs == [workspace])
    }

    @Test func twoWindowsShareOneSessionAndOneRead() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        await waitUntil { hub.session(for: workspace)?.phase == .ready && !provider.core.activityReads.isEmpty }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(provider.core.openCalls.count == 1)
        #expect(provider.core.activityReads.count == 1)
    }

    @Test func anActivityEventRereadsOnlyItsWorkspace() async {
        let (hub, provider) = await readyHub()
        let a = UUID(), b = UUID()
        hub.attach(windowID: UUID(), workspaceID: a, path: "/repo/linked")
        hub.attach(windowID: UUID(), workspaceID: b, path: "/repo/other")
        await waitUntil { provider.core.activityReads.count == 2 }
        provider.core.setActivity(CoreWorkspaceActivity(runs: [run(9)], workflows: [], freshness: CoreActivityFreshness(source: .live, access: .ok)),
                                  for: "/repo/linked")
        provider.core.push(CoreEvent(sequence: 50, kind: .activityChanged, repositoryID: FakeCore.id(for: "/repo/linked"),
                                     executionID: nil, executionState: .unspecified, message: nil, date: Date()))
        await waitUntil { hub.session(for: a)?.runs.first?.id == 9 }
        #expect(provider.core.activityReads.filter { $0 == FakeCore.id(for: "/repo/other") }.count == 1)
    }

    @Test func losingAccessKeepsTheRuns() async {
        let (hub, provider) = await readyHub()
        provider.core.setActivity(CoreWorkspaceActivity(runs: [run(7)], workflows: [],
            freshness: CoreActivityFreshness(source: .live, access: .signedOut, syncedAt: Date())), for: "/repo/linked")
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        await waitUntil { hub.session(for: workspace)?.githubAccess == .signedOut }
        #expect(hub.session(for: workspace)?.runs.count == 1)
    }

    @Test func reloadAsksTheCoreAndWaits() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        await waitUntil { hub.session(for: workspace)?.phase == .ready }
        await hub.loadGitHubActivity(workspaceID: workspace)
        #expect(provider.core.activityRefreshes.last?.wait == true)
    }

    @Test func theLogsPreferenceIsSentWhenTheCoreStarts() async {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.keepJobLogs = { true }
        hub.startMonitoring()
        provider.ready()
        await waitUntil { provider.core.storagePreferences.first?.keep == true }
        #expect(provider.core.storagePreferences.first?.delete == false)
    }
}
```

Use the `waitUntil` helper `CoreHubTests.swift` already defines (check its name in `TestSupport.swift`; if it differs, use that one).

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild ... test -only-testing:RunnirTests/CacheFirstHubTests`
Expected: FAIL to compile (`activitySource`, `keepJobLogs` missing).

- [ ] **Step 3: Implement in `CoreHub.swift`**

On `RepositorySession`, replace the stored `githubAccess`, `isLoadingGitHub`, `githubLoadedAt`, `githubPoll` and `githubReloadPending` with:

```swift
    /// How fresh `runs` and `remoteWorkflows` are, as the Core says.
    fileprivate(set) var freshness = CoreActivityFreshness()
    /// The last sync pass's outcome, or why there is none; nil before the first.
    var githubAccess: CoreGitHubAccess? { freshness.access }
    var activitySource: CoreActivitySource { freshness.source }
    var isLoadingGitHub: Bool { freshness.syncing || isReadingActivity }
    /// When GitHub last answered.
    var githubLoadedAt: Date? { freshness.syncedAt }
    fileprivate(set) var isReadingActivity = false
    /// A read was asked for while one ran; read once more after it.
    @ObservationIgnored fileprivate var activityReadPending = false
```

Replace the "GitHub activity" section:

```swift
    // MARK: GitHub activity

    static let activityLimit = 50

    /// Asks the Core's sync for a pass and shows the result. The Core merges
    /// requests from every window into one pass and schedules the next.
    func loadGitHubActivity(workspaceID: UUID) async {
        guard let session = sessions[workspaceID], let coreID = session.coreID, isReady,
              let service = try? await provider.service() else { return }
        session.isReadingActivity = true
        defer { session.isReadingActivity = false }
        guard let activity = try? await service.refreshWorkspaceActivity(repositoryID: coreID, wait: true, limit: Self.activityLimit),
              sessions[workspaceID] === session, session.coreID == coreID else { return }
        await apply(activity, to: session)
    }

    /// Reads the cached activity; one read per session at a time, a request
    /// during it reads once more afterwards.
    private func readActivity(of session: RepositorySession) async {
        guard !session.isReadingActivity else {
            session.activityReadPending = true
            return
        }
        session.isReadingActivity = true
        defer { session.isReadingActivity = false }
        repeat {
            session.activityReadPending = false
            guard let coreID = session.coreID, isReady, let service = try? await provider.service(),
                  let activity = try? await service.workspaceActivity(repositoryID: coreID, limit: Self.activityLimit),
                  sessions[session.workspaceID] === session, session.coreID == coreID else { return }
            await apply(activity, to: session)
        } while session.activityReadPending
    }

    private func apply(_ activity: CoreWorkspaceActivity, to session: RepositorySession) async {
        let previous = session.freshness.access
        session.runs = activity.runs
        session.remoteWorkflows = activity.workflows
        session.freshness = activity.freshness
        let access = activity.freshness.access
        guard access != previous else { return }
        if access == .tokenRejected { await tokenRejected(on: .workspace(session.workspaceID)) }
        // Whether an owner has to accept permissions, or the user lacks
        // access, decides what the notice asks for.
        if access == .permissionMissing { await githubRepository(workspaceID: session.workspaceID) }
    }
```

- `open(_:force:)`: call `service.openRepository(path: path, workspaceID: session.workspaceID)`; after `apply(repository, workflows:, to:)` and `session.phase = .ready`, replace `Task { await loadGitHubActivity(...) }` with `Task { await readActivity(of: session) }` (the Core syncs on its own once the workspace opens).
- `refresh(workspaceID:)`: replace the trailing `Task { await loadGitHubActivity(workspaceID: workspaceID) }` with `Task { await readActivity(of: session) }` (the Core's `RefreshRepository` already asked its sync for a pass).
- `apply(_ event:)`: add

```swift
        case .activityChanged:
            guard let session = session(forCoreID: event.repositoryID) else { return }
            Task { await readActivity(of: session) }
```

- `pushGitHubCredential()`: drop the per-session `loadGitHubActivity` after a token change (the Core syncs on credential changes); keep `refresh(workspaceID:)` when servers changed. Also push the logs preference there on the first push after the Core is ready: `try? await service.setStoragePreferences(keepJobLogs: keepJobLogs(), deleteKeptLogs: false)` — do it in `handle(.running)` next to `schedulePush()` as `Task { await self.pushStoragePreferences() }`.
- `release(windowID:from:then:)`: remove `session.githubPoll?.cancel()`.
- `loadGitHubActivity` callers in `locateDispatchedRun` and `followRunChange` stay as they are.
- `attach(...)`'s path-change branch: also reset `existing.runs = []`, `existing.remoteWorkflows = []`, `existing.freshness = CoreActivityFreshness()`.
- Storage:

```swift
    // MARK: Storage

    @ObservationIgnored var keepJobLogs: @MainActor () -> Bool = { UserDefaults.standard.bool(forKey: StorageSettings.keepJobLogsKey) }

    private func pushStoragePreferences() async {
        guard isReady, let service = try? await provider.service() else { return }
        try? await service.setStoragePreferences(keepJobLogs: keepJobLogs(), deleteKeptLogs: false)
    }

    /// Turns keeping job logs on or off; off with `deleteKept` deletes kept logs.
    func setKeepJobLogs(_ keep: Bool, deleteKept: Bool) async {
        guard isReady, let service = try? await provider.service() else { return }
        try? await service.setStoragePreferences(keepJobLogs: keep, deleteKeptLogs: deleteKept)
    }

    func storageUsage(workspaceIDs: [UUID] = []) async -> CoreStorageUsage? {
        guard isReady, let service = try? await provider.service() else { return nil }
        return try? await service.storageUsage(workspaceIDs: workspaceIDs)
    }

    /// Clears the cache of the workspaces (all when empty); open ones sync again.
    @discardableResult
    func clearCache(workspaceIDs: [UUID]) async -> Bool {
        guard isReady, let service = try? await provider.service() else { return false }
        return (try? await service.clearWorkspaceCache(workspaceIDs: workspaceIDs)) != nil
    }

    /// Deletes a closed workspace's data on this Mac.
    @discardableResult
    func deleteWorkspaceData(_ workspaceID: UUID) async -> Bool {
        guard isReady, let service = try? await provider.service() else { return false }
        do {
            try await service.deleteWorkspaceData(workspaceID: workspaceID)
            return true
        } catch {
            return false
        }
    }
```

`StorageSettings` (declared in Task 12's `StorageSettings.swift`; create the file now with just this enum so the hub compiles):

```swift
/// Settings › Storage, kept in UserDefaults.
enum StorageSettings {
    static let keepJobLogsKey = "storage.keepJobLogs"
}
```

- [ ] **Step 4: Update the old hub tests**

In `CoreHubTests.swift`: tests that set `githubPollInterval`/`githubIdlePollInterval` or expect repeated reads (`activeRunsAreReadAgainUntilTheyFinish`, `runsAreReadAgainWhileNothingIsActive`, `aLoadAskedForDuringAnotherRunsAfterIt`) describe the removed Swift poll: replace them with one test that an `.activityChanged` event re-reads the session (covered above) and delete the rest. `missingAccessClearsRunsAndARejectedTokenSignsOut` becomes `missingAccessKeepsRunsAndARejectedTokenSignsOut` (runs stay; sign-out still happens). Tests that check `runsCalls` after opening a linked repository now check `activityReads` (opening reads the cache, it does not ask GitHub). Fix every remaining compile error the same way: the meaning is "the Core's activity was read".

- [ ] **Step 5: Build and run all unit tests**

Run: `xcodebuild ... build` then `xcodebuild ... test -only-testing:RunnirTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/macos
git commit -m "Show cached activity at once and follow the Core's sync"
```

---

### Task 12: Freshness line, Settings › Storage, Clear Cache, data removal

**Files:**
- Create: `apps/macos/Runnir/Features/Desktop/ActivityFreshness.swift`
- Modify: `apps/macos/Runnir/Features/Settings/StorageSettings.swift` (from Task 11), `SettingsOverlay.swift`
- Modify: `apps/macos/Runnir/Features/Desktop/GitHubActivityViews.swift`, `OverviewViews.swift`, `DesktopViews.swift`
- Modify: `apps/macos/Runnir/App/Desktop/DesktopCoordinator.swift` (`removeRegistration`)
- Test: `apps/macos/RunnirTests/WorkspaceCacheTests.swift`

**Interfaces:**
- Produces:
  - `enum ActivityFreshnessText { static func line(_ f: CoreActivityFreshness, now: Date) -> String? }`
  - `struct ActivityFreshnessLine: View` (`init(session: RepositorySession)`)
  - `@MainActor @Observable final class StorageSettingsModel` with `init(hub: CoreHub?, workspaces: @escaping @MainActor () -> [WorkspaceRecord], defaults: UserDefaults = .standard)`, `rows: [StorageRow]`, `keepJobLogs: Bool`, `load() async`, `clear(_ ids: [UUID]) async`, `clearAll() async`, `delete(_ id: UUID) async`, `setKeepJobLogs(_ keep: Bool) async`
  - `struct StorageRow: Identifiable, Equatable { let id: UUID; let name: String; let detail: String; let storage: CoreWorkspaceStorage?; let isRegistered: Bool }`
  - `SettingsSection.storage`

- [ ] **Step 1: Write the failing tests** (append to `WorkspaceCacheTests.swift`)

```swift
@Suite struct FreshnessTextTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func eachStateHasItsLine() {
        typealias F = CoreActivityFreshness
        #expect(ActivityFreshnessText.line(F(source: .none, syncing: true), now: now) == "Loading activity…")
        #expect(ActivityFreshnessText.line(F(source: .live, syncing: true, access: .ok), now: now) == "Refreshing…")
        #expect(ActivityFreshnessText.line(F(source: .cache, syncedAt: now.addingTimeInterval(-7200)), now: now)
            == "Showing saved activity · synced 2 hours ago")
        #expect(ActivityFreshnessText.line(F(source: .live, access: .ok, checkedAt: now.addingTimeInterval(-60),
                                              syncedAt: now.addingTimeInterval(-60), changedAt: now.addingTimeInterval(-60)), now: now)
            == "Up to date · checked 1 minute ago")
        #expect(ActivityFreshnessText.line(F(source: .live, access: .ok, checkedAt: now.addingTimeInterval(-2),
                                              syncedAt: now.addingTimeInterval(-2), changedAt: now.addingTimeInterval(-3600)), now: now)
            == "No changes since 1 hour ago · checked just now")
        #expect(ActivityFreshnessText.line(F(source: .live, access: .unavailable, syncedAt: now.addingTimeInterval(-600)), now: now)
            == "Showing activity from 10 minutes ago")
        #expect(ActivityFreshnessText.line(F(), now: now) == nil)
    }
}

@MainActor
@Suite struct StorageSettingsTests {
    private func workspace(_ name: String) -> WorkspaceRecord {
        WorkspaceRecord(id: UUID(), name: name, path: "/repo/\(name)", bookmark: nil, lastOpenedAt: Date())
    }

    private func storage(_ id: UUID, runs: Int = 3) -> CoreWorkspaceStorage {
        CoreWorkspaceStorage(workspaceID: id, state: .persistent, note: nil, isOpen: false, databaseBytes: 4096,
                             logBytes: 0, cachedRuns: runs, localRuns: 1, recoveryCopies: 0)
    }

    @Test func registeredAndRemovedWorkspacesAreListed() async {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        await waitUntil { if case .ready = hub.status { true } else { false } }
        let kept = workspace("kept"), empty = workspace("empty")
        let removed = UUID()
        provider.core.storage = CoreStorageUsage(workspaces: [storage(kept.id), storage(removed)], keepJobLogs: false)
        let defaults = UserDefaults(suiteName: "storage-\(UUID())")!
        let model = StorageSettingsModel(hub: hub, workspaces: { [kept, empty] }, defaults: defaults)
        await model.load()
        #expect(model.rows.map(\.name) == ["empty", "kept", "Removed workspace"])
        #expect(model.rows.first { $0.id == empty.id }?.storage == nil)
        #expect(model.rows.first { $0.id == removed }?.isRegistered == false)

        await model.clear([kept.id])
        #expect(provider.core.clearedCaches == [[kept.id]])
        await model.clearAll()
        #expect(provider.core.clearedCaches.last == [])
        await model.delete(removed)
        #expect(provider.core.deletedData == [removed])

        await model.setKeepJobLogs(true)
        await model.setKeepJobLogs(false)
        #expect(provider.core.storagePreferences.map(\.keep) == [false, true, false]) // launch push, on, off
        #expect(provider.core.storagePreferences.last?.delete == true)
        #expect(defaults.bool(forKey: StorageSettings.keepJobLogsKey) == false)
    }
}
```

Adjust `WorkspaceRecord(...)` to its real initializer in `DesktopStateStore.swift`/`DesktopCoordinator.swift`, and `storagePreferences` expectations to whether the launch push already happened in this test (it does once the hub is ready).

Add a `DesktopStateTests`-style test, or extend an existing coordinator test, that `removeRegistration` asks the Core to delete the workspace's data (`provider.core.deletedData == [id]`); follow how the existing coordinator tests build a `DesktopCoordinator` with a `FakeProvider`.

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild ... test -only-testing:RunnirTests/FreshnessTextTests -only-testing:RunnirTests/StorageSettingsTests`
Expected: FAIL to compile.

- [ ] **Step 3: Implement**

`ActivityFreshness.swift`:

```swift
import SwiftUI

/// The one line that says how fresh a workspace's GitHub activity is.
enum ActivityFreshnessText {
    static func line(_ f: CoreActivityFreshness, now: Date) -> String? {
        if f.syncing { return f.source == .none ? "Loading activity…" : "Refreshing…" }
        switch f.source {
        case .none:
            return nil
        case .cache:
            guard let synced = f.syncedAt else { return "Showing saved activity" }
            return "Showing saved activity · synced \(relative(synced, now))"
        case .live:
            guard f.access == .ok else {
                return f.syncedAt.map { "Showing activity from \(relative($0, now))" }
            }
            let checked = f.checkedAt.map { relative($0, now) } ?? "just now"
            if let changed = f.changedAt, let synced = f.syncedAt, changed < synced {
                return "No changes since \(relative(changed, now)) · checked \(checked)"
            }
            return "Up to date · checked \(checked)"
        }
    }

    static func relative(_ date: Date, _ now: Date) -> String {
        if abs(now.timeIntervalSince(date)) < 10 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Shows `ActivityFreshnessText` for a session and keeps the times current.
struct ActivityFreshnessLine: View {
    let session: RepositorySession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let text = ActivityFreshnessText.line(session.freshness, now: context.date) {
                Text(text)
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .accessibilityIdentifier("activity-freshness")
            }
        }
    }
}
```

Views: show `ActivityFreshnessLine(session: session)` under the Overview's recent runs header (in `RecentRunsList`, above the list, only when `showsAccessNotice` or always — put it once per screen: in `RecentRunsList` and in `WorkspaceRunsView`'s header next to the reload button). In `OverviewViews.staleBanner`, keep the text; it already uses `githubLoadedAt`, now `syncedAt`.

`StorageSettings.swift` (extend the file from Task 11):

```swift
import SwiftUI

/// One workspace in Settings › Storage.
struct StorageRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    let detail: String
    /// nil: nothing saved on this Mac.
    let storage: CoreWorkspaceStorage?
    let isRegistered: Bool
}

@MainActor
@Observable
final class StorageSettingsModel {
    private(set) var rows: [StorageRow] = []
    private(set) var isLoading = false
    private(set) var keepJobLogs: Bool
    @ObservationIgnored private let hub: CoreHub?
    @ObservationIgnored private let workspaces: @MainActor () -> [WorkspaceRecord]
    @ObservationIgnored private let defaults: UserDefaults

    init(hub: CoreHub?, workspaces: @escaping @MainActor () -> [WorkspaceRecord], defaults: UserDefaults = .standard) {
        self.hub = hub
        self.workspaces = workspaces
        self.defaults = defaults
        keepJobLogs = defaults.bool(forKey: StorageSettings.keepJobLogsKey)
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        let usage = await hub?.storageUsage()
        let byID = Dictionary((usage?.workspaces ?? []).map { ($0.workspaceID, $0) }, uniquingKeysWith: { first, _ in first })
        let registered = workspaces().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        var out = registered.map { StorageRow(id: $0.id, name: $0.name, detail: $0.path, storage: byID[$0.id], isRegistered: true) }
        let known = Set(registered.map(\.id))
        for storage in usage?.workspaces ?? [] where !known.contains(storage.workspaceID) && storage.state != .absent {
            out.append(StorageRow(id: storage.workspaceID, name: "Removed workspace", detail: storage.workspaceID.uuidString,
                                  storage: storage, isRegistered: false))
        }
        rows = out
    }

    func clear(_ ids: [UUID]) async {
        await hub?.clearCache(workspaceIDs: ids)
        await load()
    }

    func clearAll() async { await clear([]) }

    func delete(_ id: UUID) async {
        await hub?.deleteWorkspaceData(id)
        await load()
    }

    func setKeepJobLogs(_ keep: Bool) async {
        keepJobLogs = keep
        defaults.set(keep, forKey: StorageSettings.keepJobLogsKey)
        await hub?.setKeepJobLogs(keep, deleteKept: !keep)
        await load()
    }

    /// "12 saved runs · 1 local run · 3 MB", or why nothing is saved.
    static func summary(_ storage: CoreWorkspaceStorage?) -> String {
        guard let storage, storage.state != .absent else { return "Nothing saved on this Mac" }
        var parts = ["\(storage.cachedRuns) saved \(storage.cachedRuns == 1 ? "run" : "runs")",
                     "\(storage.localRuns) local \(storage.localRuns == 1 ? "run" : "runs")"]
        if storage.logBytes > 0 { parts.append("logs " + ByteCountFormatter.string(fromByteCount: Int64(storage.logBytes), countStyle: .file)) }
        parts.append(ByteCountFormatter.string(fromByteCount: Int64(storage.databaseBytes), countStyle: .file))
        if storage.recoveryCopies > 0 { parts.append("\(storage.recoveryCopies) recovery \(storage.recoveryCopies == 1 ? "copy" : "copies")") }
        return parts.joined(separator: " · ")
    }
}

/// Settings › Storage: what each workspace keeps on this Mac.
struct StorageSettingsSection: View {
    @State var model: StorageSettingsModel
    @State private var confirming: Confirmation?

    private enum Confirmation: Identifiable {
        case clear(StorageRow), clearAll, delete(StorageRow), stopKeepingLogs
        var id: String {
            switch self {
            case .clear(let row): "clear-\(row.id)"
            case .clearAll: "clear-all"
            case .delete(let row): "delete-\(row.id)"
            case .stopKeepingLogs: "logs"
            }
        }
    }

    var body: some View {
        Section("Job Logs") {
            Toggle("Keep job logs on this Mac", isOn: Binding(
                get: { model.keepJobLogs },
                set: { keep in if keep { Task { await model.setKeepJobLogs(true) } } else { confirming = .stopKeepingLogs } }))
            Text("Logs of finished jobs open offline and are not downloaded again. They can contain output your workflows print; they stay in Runnir's folder on this Mac, up to 100 MB per workspace.")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
        }
        Section("Workspaces") {
            ForEach(model.rows) { row in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                        Text(StorageSettingsModel.summary(row.storage)).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                        if let note = row.storage?.note {
                            Text(note).font(.system(size: 12)).foregroundStyle(RunnirTheme.warning)
                        }
                    }
                    Spacer()
                    if row.isRegistered {
                        Button("Clear Cache…") { confirming = .clear(row) }.disabled(row.storage == nil)
                    } else {
                        Button("Delete…", role: .destructive) { confirming = .delete(row) }
                    }
                }
            }
            HStack {
                Text("Clearing keeps local run history, presets, favorites and your sign-in. Saved activity downloads again when a workspace opens.")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                Spacer()
                Button("Clear All Caches…") { confirming = .clearAll }.disabled(model.rows.allSatisfy { $0.storage == nil })
            }
        }
        .task { await model.load() }
        .confirmationDialog(title, isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            switch confirming {
            case .clear(let row): Button("Clear Cache") { Task { await model.clear([row.id]) } }
            case .clearAll: Button("Clear All Caches") { Task { await model.clearAll() } }
            case .delete(let row): Button("Delete", role: .destructive) { Task { await model.delete(row.id) } }
            case .stopKeepingLogs: Button("Stop and Delete Logs", role: .destructive) { Task { await model.setKeepJobLogs(false) } }
            case nil: EmptyView()
            }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text(message)
        }
    }

    private var title: String {
        switch confirming {
        case .clear(let row): "Clear the cache of \(row.name)?"
        case .clearAll: "Clear every workspace's cache?"
        case .delete: "Delete this removed workspace's data?"
        case .stopKeepingLogs: "Stop keeping job logs?"
        case nil: ""
        }
    }

    private var message: String {
        switch confirming {
        case .clear, .clearAll: "Saved runs, jobs, workflows and kept logs are deleted and download again. Local run history, presets, favorites and your sign-in stay."
        case .delete: "Its saved activity and local run history are deleted from this Mac. Nothing in any repository changes."
        case .stopKeepingLogs: "Logs kept so far are deleted from this Mac."
        case nil: ""
        }
    }
}
```

`SettingsOverlay.swift`: add `case storage` before `privacy` (title "Storage", symbol "internaldrive") and in `content`: `case .storage: StorageSettingsSection(model: StorageSettingsModel(hub: desktop.core, workspaces: { desktop.snapshot.workspaces }))` (use the coordinator's real accessor for registered workspaces).

`DesktopViews.swift` (workspace toolbar, non-Workspace sections): next to "Refresh", add

```swift
                Menu {
                    Button("Clear Cache…") { confirmClearCache = true }
                        .disabled(desktop.core == nil)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().help("More workspace actions")
```

with `@State private var confirmClearCache = false` and a `.confirmationDialog("Clear the cache of \(workspace.name)?", isPresented: $confirmClearCache)` offering `Button("Clear Cache") { Task { await desktop.core?.clearCache(workspaceIDs: [workspace.id]) } }` and the same message as Settings.

`DesktopCoordinator.removeRegistration`: after `favorites.removeAll(workspaceID:)`, add `if let core { Task { await core.deleteWorkspaceData(workspace.id) } }` with the comment that a Core that is not running leaves the data, which Settings › Storage then lists as a removed workspace. Update the Manager's "Remove Registration" `.help`/confirmation text, if any, to say saved activity and local run history on this Mac are deleted too.

- [ ] **Step 4: Build and run all unit tests**

Run: `xcodebuild ... build` then `xcodebuild ... test -only-testing:RunnirTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos
git commit -m "Show activity freshness and add Settings › Storage with Clear Cache"
```

---

### Task 13: Documentation, full verification, live check

**Files:**
- Modify: `docs/decisions/0007-workspace-sqlite.md` (measured sizes), `docs/decisions/0003-workspaces-sessions-offline-storage.md`, `docs/architecture/workspace-persistence.md`, `docs/architecture/grpc-api.md`, `docs/architecture/desktop-lifecycle.md`, `docs/product/mvp-implementation-checklist.md`, `README.md`

- [ ] **Step 1: Measure the Core binary** (store now linked in)

```bash
cd core
CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o "$TMPDIR/core-after" ./cmd/runnir
git show origin/main:core/go.mod >/dev/null
git worktree add "$TMPDIR/runnir-main" origin/main
(cd "$TMPDIR/runnir-main/core" && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o "$TMPDIR/core-before" ./cmd/runnir)
git worktree remove "$TMPDIR/runnir-main"
ls -l "$TMPDIR/core-before" "$TMPDIR/core-after"
go list -m all
```

Record both sizes and the difference in ADR 0007, and list the new modules from `go.mod` with their licenses (read each module's LICENSE in the module cache).

- [ ] **Step 2: Update the docs**

- ADR 0003: status line "database and shared sync implemented 2026-10-22 (ADR 0007)"; in Open Implementation Decisions, mark settled: driver/licensing/version, Core DB access ownership, WAL/shutdown/single writer, sync/history/blob budgets; keep the rest open. Replace "Shared DB/sync is not implemented" and "No SQLite dependency has been selected" with what exists.
- `workspace-persistence.md`: status "implemented in part": the actual layout (`repositories/<workspaceId>/{state.sqlite,lock,blobs,backups,recovery}`), tables, budgets, Clear Cache classes, recovery behavior, sync schedule, ETags, origin change, freshness states; the W05/W06/W08 rows: what unit and gRPC tests cover and what is not verified.
- `grpc-api.md`: `OpenRepository(path, workspace_id)`; the six calls in the table; `ACTIVITY_CHANGED`; the process section's polling sentence becomes "The Core syncs each open workspace: ..."; `serve --data-dir`.
- `desktop-lifecycle.md`: L06's "one shared runtime/sync" now implemented in the Core; still no UI automation for two windows.
- Checklist: progress rows for B26 and B27 with what exists and "Missing for acceptance": signed build, power-loss/crash injection, live GitHub check with two windows (unless done in Step 4), corrupted-database UI beyond the Storage note (B29).
- README: a short "Offline activity" line in the feature list: runs, workflows and jobs are kept per workspace in a local SQLite database and shown at launch before GitHub answers; Settings › Storage clears it; logs kept only when turned on. State plainly what is not verified.

- [ ] **Step 3: Full verification**

```bash
cd core && go test -race ./... && go vet ./... && CGO_ENABLED=0 go build ./...
cd .. && xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests
```

Expected: all pass. Paste failures verbatim into the hand-off if any remain.

- [ ] **Step 4: Live check in the test copy**

Build the Debug app, copy it as the `com.dileight.runnir.alertcheck` test copy the earlier live checks used, launch it with `--ui-testing` and `RUNNIR_UI_TEST_STATE_DIRECTORY` pointing at a fresh scratch folder (never the user's Application Support). Check, with screenshots:
1. a workspace opens and shows the freshness line;
2. after quitting and relaunching (network off, or a GitHub account not signed in), the runs from the previous launch show at once with "Showing saved activity";
3. a second window on the same workspace: `core.log` and `GetStorageUsage` show one open workspace; the Core makes one runs request per pass (count with the log or a proxy-free check: the window count does not change the pass count);
4. Settings › Storage lists the workspace; Clear Cache empties and resyncs.
If real GitHub is not reachable from the test copy, record exactly what was and was not checked in the docs and the hand-off.

- [ ] **Step 5: Commit**

```bash
git add docs README.md
git commit -m "Document the workspace database, shared sync and Storage settings"
```

---

## Self-Review Notes

- Spec coverage: storage layout, identity, store (Tasks 1–4), driver ADR (1, 13), sync and errors (7), jobs/logs (8, 9), local history (2, 8, 9), contract (6), server (9), app (10–12), docs and caveats (13).
- Type names used across tasks: `store.Pass`, `store.Activity.HasSource`, `store.CacheSource`, `workspace.Snapshot.Provenance`, `workspace.Usage`, `CoreActivityFreshness`, `CoreWorkspaceStorage.workspaceID` (UUID), `StorageSettings.keepJobLogsKey`.
