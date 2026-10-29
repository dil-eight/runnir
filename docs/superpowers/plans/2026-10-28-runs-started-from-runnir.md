# Runs Started From Runnir (B46) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Runs that Runnir started on this Mac are marked in the runs list and the run inspector, and the status filter menu can narrow the list to them.

**Architecture:**
- **The Core keeps its own record.** A new local table, `runnir_starts`, gets one row per attempt Runnir started:
  - a dispatch, as attempt 1, once its run is known;
  - each re-run GitHub accepted, as the attempt after the one reviewed.
- **The Core sends the record with the runs.** Every run the runs list gets carries the attempts in `WorkflowRun.runnir_starts`.
- **The app only draws.** It shows the words in the row and beside the attempt, and adds a From Runnir item to the filter, which combines with the statuses (B42) by AND.

**Tech Stack:**
- Go 1.27: pure Go, `CGO_ENABLED=0`, SQLite through the existing store.
- protobuf/gRPC: buf, swift-protobuf, grpc-swift-protobuf.
- Swift 6, SwiftUI, Swift Testing.

## Global Constraints

- **Sources.**
  - Spec: `docs/superpowers/specs/2026-10-28-runs-started-from-runnir-design.md`.
  - Pen: `docs/design/runnir.pen`, journey D, Row — Runs started from Runnir (B46). Option C is the chosen one.
- **Local only.** Nothing is sent to GitHub and no GitHub request is added. Marks are known on this Mac only.
- **No backward compatibility.** The contract and the schema change in place, with no versions, aliases or migrations (AGENTS.md, before the first release tag). Add the table to `schemaV1`: a database from an earlier build is set aside and its local data is carried over, which already works.
- **Nothing else added.** No new dependencies in Go or Swift, no telemetry, no credentials on disk.
- **No new Swift files.** The Xcode project has no synchronized folders, so a new file would need hand edits to `project.pbxproj`. Put app code and app tests in the existing files named below.
- **Text.** UI text is in English. Exact strings:
  - row prefix: "From Runnir · " (U+00B7);
  - inspector words: " · from Runnir", " · re-run from Runnir", " · attempt N from Runnir";
  - help: "Attempt N was started from Runnir on this Mac, <age>." / "re-ran every job" / "re-ran the failed jobs" / "re-ran one job";
  - attempts Runnir did not start: "Attempt 1 was not started from this Mac." / "Attempts 1 and 3 were not started from this Mac.";
  - last line of the help: "Only this Mac knows: GitHub keeps no mark on runs, so other Macs and github.com do not show it."
- **No AI attribution.** None in commits, code, docs or PRs: no `Co-Authored-By`, no "Generated with".
- **Go for Xcode.** Xcode builds need Go 1.27.3 on the PATH. Run this before `xcodebuild`:
  `export PATH="$HOME/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.27.3.darwin-arm64/bin:$PATH"`
- **Contract plugins.** Contract generation needs the Swift plugins on the PATH. Run this, then `scripts/generate-contracts.sh` from the repository root:
  `export PATH="$HOME/go/bin:/private/tmp/claude-502/-Users-dilbarov-projects-runnir/90db4574-3499-4323-929d-0cc810dcb80e/scratchpad/protoc-plugins/swift-protobuf/.build/out/Products/Release:/private/tmp/claude-502/-Users-dilbarov-projects-runnir/90db4574-3499-4323-929d-0cc810dcb80e/scratchpad/protoc-plugins/grpc-swift-protobuf/.build/out/Products/Release:$PATH"`
  If that folder is gone, build the plugins as the script's header says.

## File Structure

**Core**

- `core/internal/store/starts.go` (new): `RunStart`, the kinds, `RecordStart`, `RunStarts`, `dispatchStarted`, `scanStarts`.
- `core/internal/store/schema.go`: the `runnir_starts` table.
- `core/internal/store/dispatches.go`: a dispatch with its run, given or linked later, records attempt 1 in the same transaction.
- `core/internal/store/localruns.go`: `localChanged` keeps the newest `maxRunStarts`.
- `core/internal/store/recovery.go`: backup, salvage and restore of `runnir_starts`.
- `core/internal/store/starts_test.go` (new): store tests.

**Contract**

- `contracts/grpc/runnir/core/v1/runnir_core.proto`: `WorkflowRun.runnir_starts`, `RunnirStart`, `RunnirStartKind`. Generated code is in `core/internal/gen/...` and `apps/macos/Runnir/IPC/Generated/...`.

**Core server**

- `core/internal/workspace/search.go`: `Runtime.RunStarts`.
- `core/internal/server/starts.go` (new): `startKind`, `recordRerun`, `addStarts`, `withStarts`.
- `core/internal/server/runs.go`: `runAction.Attempt`; `ConfirmRunAction` records a re-run.
- `core/internal/server/workspace.go`, `core/internal/server/search.go`: the runs of the activity, `SearchRuns` and `SearchRunsOnGitHub` carry the starts.
- `core/internal/server/starts_test.go` (new): server tests.

**App**

- `apps/macos/Runnir/IPC/CoreGitHubModels.swift`: `CoreRunnirStart`, `CoreWorkflowRun.runnirStarts`, `startedFromRunnir`.
- `apps/macos/Runnir/IPC/GRPCCoreService.swift`: the mapping.
- `apps/macos/Runnir/Features/Desktop/RunChanges.swift`: the words and the help (`RunPresentation`).
- `apps/macos/Runnir/Features/Desktop/GitHubActivityViews.swift`: `RunRow`, and the runs list's filter state.
- `apps/macos/Runnir/Features/Desktop/RunChangeViews.swift`: `RunChangeRow`.
- `apps/macos/Runnir/Features/Desktop/RunInspectorView.swift`: the words beside the attempt.
- `apps/macos/Runnir/Features/Desktop/RunStatusFilter.swift`: `RunFilter`, `RunnirMark`, the From Runnir item and its chip.
- `apps/macos/Runnir/Features/Desktop/RunSearch.swift`: `list` and `changes` take a `RunFilter`.
- Tests: `RunnirTests/RunLinkMappingTests.swift`, `RunChangesTests.swift`, `RunStatusFilterTests.swift`, `RunSearchTests.swift`.

**Docs**

- the spec's status;
- `docs/product/mvp-implementation-checklist.md`;
- `docs/architecture/grpc-api.md`;
- `docs/design/screens-and-states.md`.

---

### Task 1: The Core Keeps The Attempts Runnir Started

**Files:**
- Create: `core/internal/store/starts.go`
- Create: `core/internal/store/starts_test.go`
- Modify: `core/internal/store/schema.go` (after `CREATE INDEX dispatch_history_workflow ...`)
- Modify: `core/internal/store/dispatches.go` (`RecordDispatch`, `LinkDispatchRun`)
- Modify: `core/internal/store/localruns.go` (`localChanged`)
- Modify: `core/internal/store/recovery.go` (`localData`, `writeLocalBackup`, `scanLocal`, `restoreLocal`)

**Interfaces:**
- Produces:
  - `type RunStart struct { Source Source; RunID, Attempt int64; Kind string; SentAt time.Time }`
  - constants `StartDispatch = "dispatch"`, `StartRerun = "rerun"`, `StartRerunFailed = "rerun_failed"`, `StartRerunJob = "rerun_job"`
  - `func (s *Store) RecordStart(ctx context.Context, r RunStart) error`
  - `func (s *Store) RunStarts(ctx context.Context, source Source) (map[int64][]RunStart, error)`: by run, oldest attempt first.
  - `var maxRunStarts = 5000`
- `RecordDispatch` with `RunID > 0`, and a `LinkDispatchRun` that sets the run, also record `{Attempt: 1, Kind: StartDispatch, SentAt: <the dispatch's sent_at>}`.

- [ ] **Step 1: Write the failing store tests**

Create `core/internal/store/starts_test.go`:

```go
//go:build !windows

package store

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func recordStart(t *testing.T, s *Store, r RunStart) {
	t.Helper()
	if err := s.RecordStart(context.Background(), r); err != nil {
		t.Fatal(err)
	}
}

func TestAStartIsKeptOncePerAttempt(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	at := fixedNow()
	recordStart(t, s, RunStart{Source: testSource, RunID: 21, Attempt: 2, Kind: StartRerunFailed, SentAt: at})
	// The first record of an attempt stands.
	recordStart(t, s, RunStart{Source: testSource, RunID: 21, Attempt: 2, Kind: StartRerun, SentAt: at.Add(time.Minute)})
	recordStart(t, s, RunStart{Source: testSource, RunID: 21, Attempt: 1, Kind: StartDispatch, SentAt: at.Add(-time.Hour)})
	recordStart(t, s, RunStart{Source: testSource, RunID: 30, Attempt: 3, Kind: StartRerunJob, SentAt: at})

	got, err := s.RunStarts(ctx, testSource)
	if err != nil {
		t.Fatal(err)
	}
	run := got[21]
	if len(run) != 2 || run[0].Attempt != 1 || run[0].Kind != StartDispatch || run[1].Attempt != 2 || run[1].Kind != StartRerunFailed ||
		!run[1].SentAt.Equal(at) || run[1].Source != testSource {
		t.Fatalf("run 21 = %+v", run)
	}
	if len(got[30]) != 1 || got[30][0].Kind != StartRerunJob {
		t.Fatalf("run 30 = %+v", got[30])
	}
	if err := s.RecordStart(ctx, RunStart{Source: testSource, RunID: 21}); err == nil {
		t.Fatal("attempt 0 is not an attempt")
	}
}

func TestStartsBelongToTheRepositoryTheyWereSentTo(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	recordStart(t, s, RunStart{Source: testSource, RunID: 21, Attempt: 1, Kind: StartDispatch, SentAt: fixedNow()})
	other := Source{ServerID: "ghe", Repository: "o/r"}
	recordStart(t, s, RunStart{Source: other, RunID: 21, Attempt: 2, Kind: StartRerun, SentAt: fixedNow()})
	if got, _ := s.RunStarts(ctx, testSource); len(got[21]) != 1 || got[21][0].Attempt != 1 {
		t.Fatalf("this repository = %+v", got)
	}
	if got, _ := s.RunStarts(ctx, other); len(got[21]) != 1 || got[21][0].Attempt != 2 {
		t.Fatalf("the other server = %+v", got)
	}
}

func TestADispatchIsAStartOnceItsRunIsKnown(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	at := fixedNow()
	if _, err := s.RecordDispatch(ctx, DispatchRecord{Source: testSource, WorkflowPath: ".github/workflows/deploy.yml", Ref: "main", SentAt: at, RunID: 4242}); err != nil {
		t.Fatal(err)
	}
	waiting := recordDispatch(t, s, ".github/workflows/deploy.yml", "dev", nil, at.Add(time.Minute))
	got, _ := s.RunStarts(ctx, testSource)
	if len(got) != 1 || len(got[4242]) != 1 || got[4242][0].Attempt != 1 || got[4242][0].Kind != StartDispatch || !got[4242][0].SentAt.Equal(at) {
		t.Fatalf("a dispatch GitHub named the run of = %+v", got)
	}

	// The app finds the run of the other one; a later guess changes nothing.
	if err := s.LinkDispatchRun(ctx, waiting, 5555); err != nil {
		t.Fatal(err)
	}
	if err := s.LinkDispatchRun(ctx, waiting, 6666); err != nil {
		t.Fatal(err)
	}
	got, _ = s.RunStarts(ctx, testSource)
	if len(got[5555]) != 1 || !got[5555][0].SentAt.Equal(at.Add(time.Minute)) || len(got[6666]) != 0 {
		t.Fatalf("after the link = %+v", got)
	}

	// Clear history and Clear Cache keep them.
	if _, err := s.ClearDispatchHistory(ctx, testSource); err != nil {
		t.Fatal(err)
	}
	if err := s.ClearCache(ctx); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.RunStarts(ctx, testSource); len(got) != 2 {
		t.Fatalf("after clearing = %+v", got)
	}
}

func TestOnlyTheNewestStartsAreKept(t *testing.T) {
	defer func(n int) { maxRunStarts = n }(maxRunStarts)
	maxRunStarts = 3
	s := openTest(t, t.TempDir())
	for i := int64(1); i <= 5; i++ {
		recordStart(t, s, RunStart{Source: testSource, RunID: i, Attempt: 2, Kind: StartRerun, SentAt: fixedNow().Add(time.Duration(i) * time.Minute)})
	}
	got, _ := s.RunStarts(context.Background(), testSource)
	if len(got) != 3 || got[1] != nil || got[2] != nil || got[5] == nil {
		t.Fatalf("kept = %+v", got)
	}
}

func TestStartsAreRestoredWithTheDatabase(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	recordStart(t, s, RunStart{Source: testSource, RunID: 21, Attempt: 2, Kind: StartRerunFailed, SentAt: fixedNow()})
	_ = s.Close()
	for _, name := range []string{"state.sqlite", "state.sqlite-wal", "state.sqlite-shm"} {
		_ = os.Remove(filepath.Join(dir, name))
	}
	again := openTest(t, dir)
	if got, _ := again.RunStarts(context.Background(), testSource); len(got[21]) != 1 || got[21][0].Kind != StartRerunFailed {
		t.Fatalf("restored = %+v", got)
	}
}

func TestSalvagedStartsAreMergedWithTheBackup(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	recordStart(t, s, RunStart{Source: testSource, RunID: 21, Attempt: 2, Kind: StartRerunFailed, SentAt: fixedNow()})
	// The damaged file had a start the backup lacks.
	if _, err := s.restoreLocal(ctx, localData{starts: []RunStart{
		{Source: testSource, RunID: 30, Attempt: 1, Kind: StartDispatch, SentAt: fixedNow().Add(time.Hour)},
	}}); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.RunStarts(ctx, testSource); len(got[21]) != 1 || len(got[30]) != 1 {
		t.Fatalf("merged = %+v", got)
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd core && go test ./internal/store/ -run 'Start' -count=1`
Expected: FAIL to compile, with `undefined: RunStart`, `undefined: StartDispatch` and `unknown field starts in struct literal of type localData`.

- [ ] **Step 3: Add the table**

In `core/internal/store/schema.go`, right after `CREATE INDEX dispatch_history_workflow ON dispatch_history (repository, workflow_path, sent_at DESC);`, add:

```sql
-- local: the attempts of runs Runnir started on this Mac, so the runs list
-- can mark them (B46): a dispatch once its run is known (attempt 1) and each
-- re-run GitHub accepted. kind is dispatch, rerun, rerun_failed or
-- rerun_job. server_id and repository work as in dispatch_history. The
-- newest 5000 stay; Clear Cache and Clear history keep them.
CREATE TABLE runnir_starts (
	server_id TEXT NOT NULL,
	repository TEXT NOT NULL,
	run_id INTEGER NOT NULL,
	attempt INTEGER NOT NULL,
	kind TEXT NOT NULL,
	sent_at INTEGER NOT NULL,
	PRIMARY KEY (server_id, repository, run_id, attempt)
);
CREATE INDEX runnir_starts_sent ON runnir_starts (sent_at DESC);
```

- [ ] **Step 4: Add `starts.go`**

Create `core/internal/store/starts.go`:

```go
package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// maxRunStarts bounds the attempts kept. A variable so tests can lower it.
var maxRunStarts = 5000

const startColumns = "server_id, repository, run_id, attempt, kind, sent_at"

// The kinds of RunStart.
const (
	StartDispatch    = "dispatch"
	StartRerun       = "rerun"
	StartRerunFailed = "rerun_failed"
	StartRerunJob    = "rerun_job"
)

// RunStart is an attempt of a run that Runnir started from this Mac: a
// dispatch starts attempt 1 of its run, a re-run GitHub accepted the next
// attempt. GitHub keeps no mark of it, so only this Mac knows.
type RunStart struct {
	Source  Source
	RunID   int64
	Attempt int64
	Kind    string
	SentAt  time.Time
}

// RecordStart keeps an attempt Runnir started. The first record of an
// attempt stands; only the newest maxRunStarts are kept.
func (s *Store) RecordStart(ctx context.Context, r RunStart) error {
	if r.RunID <= 0 || r.Attempt <= 0 {
		return errors.New("a run and an attempt are required")
	}
	result, err := s.db.ExecContext(ctx, "INSERT OR IGNORE INTO runnir_starts ("+startColumns+") VALUES (?, ?, ?, ?, ?, ?)",
		r.Source.ServerID, r.Source.Repository, r.RunID, r.Attempt, r.Kind, millis(r.SentAt))
	if err != nil {
		return err
	}
	if added, _ := result.RowsAffected(); added == 0 {
		return nil
	}
	return s.localChanged(ctx)
}

// RunStarts lists the attempts Runnir started of one repository's runs, by
// run, oldest attempt first.
func (s *Store) RunStarts(ctx context.Context, source Source) (map[int64][]RunStart, error) {
	starts, err := scanStarts(ctx, s.db, "SELECT "+startColumns+" FROM runnir_starts WHERE server_id = ? AND repository = ? ORDER BY run_id, attempt",
		source.ServerID, source.Repository)
	out := make(map[int64][]RunStart, len(starts))
	for _, r := range starts {
		out[r.RunID] = append(out[r.RunID], r)
	}
	return out, err
}

// dispatchStarted records the run of dispatch id as its attempt 1 that
// Runnir started, once the dispatch has its run.
func dispatchStarted(ctx context.Context, tx *sql.Tx, id int64) error {
	_, err := tx.ExecContext(ctx, `
INSERT OR IGNORE INTO runnir_starts (`+startColumns+`)
SELECT server_id, repository, run_id, 1, ?, sent_at FROM dispatch_history WHERE id = ? AND run_id > 0`, StartDispatch, id)
	return err
}

// scanStarts keeps the rows read before an error, like scanLocalRuns.
func scanStarts(ctx context.Context, db *sql.DB, query string, args ...any) ([]RunStart, error) {
	rows, err := db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []RunStart
	for rows.Next() {
		var r RunStart
		var sent int64
		if err := rows.Scan(&r.Source.ServerID, &r.Source.Repository, &r.RunID, &r.Attempt, &r.Kind, &sent); err != nil {
			return out, err
		}
		r.SentAt = fromMillis(sent)
		out = append(out, r)
	}
	return out, rows.Err()
}
```

- [ ] **Step 5: Record attempt 1 of a dispatch with its run**

In `core/internal/store/dispatches.go`, replace the body of `RecordDispatch` after the two `json.Marshal` blocks, and the body of `LinkDispatchRun` after its `runID` check:

```go
// RecordDispatch adds an accepted dispatch, with its run when GitHub named
// it, and returns its id. A dispatch with its run is also attempt 1 Runnir
// started. Only the newest maxDispatchRecords are kept.
func (s *Store) RecordDispatch(ctx context.Context, r DispatchRecord) (int64, error) {
	inputs, err := json.Marshal(nonNilInputs(r.Inputs))
	if err != nil {
		return 0, err
	}
	omitted, err := json.Marshal(nonNilNames(r.Omitted))
	if err != nil {
		return 0, err
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, `
INSERT INTO dispatch_history (workflow_path, ref, inputs, omitted, sent_at, run_id, server_id, repository) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
		r.WorkflowPath, r.Ref, string(inputs), string(omitted), millis(r.SentAt), max(r.RunID, 0), r.Source.ServerID, r.Source.Repository)
	if err != nil {
		return 0, err
	}
	id, err := result.LastInsertId()
	if err != nil {
		return 0, err
	}
	if err := dispatchStarted(ctx, tx, id); err != nil {
		return 0, err
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return id, s.localChanged(ctx)
}

// LinkDispatchRun says which run a dispatch started, which makes it attempt
// 1 Runnir started. The first answer is kept: a run found later by guessing
// must not replace one GitHub named.
func (s *Store) LinkDispatchRun(ctx context.Context, id, runID int64) error {
	if runID <= 0 {
		return errors.New("a run id is required")
	}
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	result, err := tx.ExecContext(ctx, "UPDATE dispatch_history SET run_id = ? WHERE id = ? AND run_id = 0", runID, id)
	if err != nil {
		return err
	}
	if changed, _ := result.RowsAffected(); changed == 0 {
		return nil
	}
	if err := dispatchStarted(ctx, tx, id); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return err
	}
	return s.localChanged(ctx)
}
```

`dispatchStarted` only inserts when `run_id > 0`, so a dispatch recorded without a run records nothing until it is linked.

- [ ] **Step 6: Keep the newest, back them up, restore them**

In `core/internal/store/localruns.go`, `localChanged`: before `return s.writeLocalBackup(ctx)`, add:

```go
	if _, err := s.db.ExecContext(ctx, `
DELETE FROM runnir_starts WHERE rowid IN (
	SELECT rowid FROM runnir_starts ORDER BY sent_at DESC, rowid DESC LIMIT -1 OFFSET ?)`, maxRunStarts); err != nil {
		return err
	}
```

In `core/internal/store/recovery.go`:

1. `localData` gets a field:

```go
type localData struct {
	runs       []LocalRun
	savings    []Saving
	dispatches []DispatchRecord
	starts     []RunStart
}
```

2. In `writeLocalBackup`, after the `dispatch_history` copy:

```go
	if copyErr == nil {
		_, copyErr = conn.ExecContext(ctx, "CREATE TABLE backup.runnir_starts AS SELECT "+startColumns+" FROM main.runnir_starts")
	}
```

3. `scanLocal` reads them too:

```go
func scanLocal(db *sql.DB) (localData, error) {
	runs, runsErr := scanLocalRuns(db, "SELECT "+localColumns+" FROM local_runs")
	savings, savingsErr := scanSavings(db, "SELECT "+savingColumns+" FROM savings")
	dispatches, dispatchesErr := scanDispatches(context.Background(), db, "SELECT "+dispatchColumns+" FROM dispatch_history")
	starts, startsErr := scanStarts(context.Background(), db, "SELECT "+startColumns+" FROM runnir_starts")
	return localData{runs: runs, savings: savings, dispatches: dispatches, starts: starts},
		errors.Join(runsErr, savingsErr, dispatchesErr, startsErr)
}
```

4. In `restoreLocal`:
   - declare `var starts []RunStart` next to `byDispatch`;
   - inside the `for _, data := range` loop, add `starts = append(starts, data.starts...)`;
   - after the `byDispatch` insert loop and before `return len(byID), tx.Commit()`, add:

```go
	for _, r := range starts {
		if _, err := tx.ExecContext(ctx, "INSERT OR IGNORE INTO runnir_starts ("+startColumns+") VALUES (?, ?, ?, ?, ?, ?)",
			r.Source.ServerID, r.Source.Repository, r.RunID, r.Attempt, r.Kind, millis(r.SentAt)); err != nil {
			_ = tx.Rollback()
			return 0, err
		}
	}
```

A backup made by an earlier build has no `runnir_starts`. `scanStarts` then returns an error that `restoreLocal` already ignores (`backup, _ :=`), and the other tables are still read.

- [ ] **Step 7: Run the store tests**

Run: `cd core && go test ./internal/store/ -count=1`
Expected: PASS, including the six new tests and the existing dispatch tests.

- [ ] **Step 8: Commit**

```bash
git add core/internal/store
git commit -m "Core: the workspace keeps the attempts Runnir started, a dispatch once its run is known (B46)"
```

---

### Task 2: The Run Message Carries Them

**Files:**
- Modify: `contracts/grpc/runnir/core/v1/runnir_core.proto` (end of `message WorkflowRun`)
- Regenerate: `core/internal/gen/runnir/core/v1/*`, `apps/macos/Runnir/IPC/Generated/runnir/core/v1/*`

**Interfaces:**
- Produces:
  - Go: `corev1.WorkflowRun.RunnirStarts []*corev1.RunnirStart`; `corev1.RunnirStart{Attempt int64, Kind corev1.RunnirStartKind, SentAt *timestamppb.Timestamp}`; constants `corev1.RunnirStartKind_RUNNIR_START_KIND_DISPATCH`, `_RERUN`, `_RERUN_FAILED`, `_RERUN_JOB`.
  - Swift: `Runnir_Core_V1_WorkflowRun.runnirStarts`; `Runnir_Core_V1_RunnirStart` (`attempt`, `kind`, `sentAt`); `Runnir_Core_V1_RunnirStartKind` cases `.unspecified`, `.dispatch`, `.rerun`, `.rerunFailed`, `.rerunJob`.

- [ ] **Step 1: Change the contract**

In `runnir_core.proto`, replace:

```proto
  RunStatusGroup status_group = 20;
}

// The six statuses runs are searched and filtered by.
```

with:

```proto
  RunStatusGroup status_group = 20;
  // The attempts Runnir started on this Mac, oldest first, up to
  // run_attempt (B46). Set in workspace activity, SearchRuns and
  // SearchRunsOnGitHub; empty elsewhere.
  repeated RunnirStart runnir_starts = 21;
}

// An attempt of a run that Runnir started on this Mac. GitHub keeps no mark
// of it, so other Macs and github.com do not know.
message RunnirStart {
  int64 attempt = 1;
  RunnirStartKind kind = 2;
  google.protobuf.Timestamp sent_at = 3;
}

enum RunnirStartKind {
  RUNNIR_START_KIND_UNSPECIFIED = 0;
  // A workflow dispatch: attempt 1 of the run it started.
  RUNNIR_START_KIND_DISPATCH = 1;
  // Re-run all jobs.
  RUNNIR_START_KIND_RERUN = 2;
  // Re-run failed jobs.
  RUNNIR_START_KIND_RERUN_FAILED = 3;
  // Re-run one job.
  RUNNIR_START_KIND_RERUN_JOB = 4;
}

// The six statuses runs are searched and filtered by.
```

- [ ] **Step 2: Regenerate**

Run from the repository root, with the plugin PATH from Global Constraints: `scripts/generate-contracts.sh`
Expected: `buf lint` passes. `git status` shows changes only in the proto, `core/internal/gen/runnir/core/v1/` and `apps/macos/Runnir/IPC/Generated/runnir/core/v1/`.

- [ ] **Step 3: Check both sides compile**

Run: `cd core && go build ./... && go vet ./...`
Expected: no output.

- [ ] **Step 4: Commit**

```bash
git add contracts core/internal/gen apps/macos/Runnir/IPC/Generated
git commit -m "Core: a run message carries the attempts Runnir started (B46)"
```

---

### Task 3: The Core Records Re-runs And Sends The Starts

**Files:**
- Create: `core/internal/server/starts.go`
- Create: `core/internal/server/starts_test.go`
- Modify: `core/internal/server/runs.go` (`runAction`, `PrepareRunAction`, `ConfirmRunAction`)
- Modify: `core/internal/workspace/search.go` (next to `searchSource`)
- Modify: `core/internal/server/workspace.go` (`snapshotMessage`)
- Modify: `core/internal/server/search.go` (`SearchRuns`, `SearchRunsOnGitHub`)

**Interfaces:**
- Consumes: `store.RunStart`, `store.Start*`, `(*store.Store).RecordStart`, `(*store.Store).RunStarts` (Task 1); `corev1.RunnirStart`, `corev1.RunnirStartKind_*` (Task 2).
- Produces:
  - `func (r *workspace.Runtime) RunStarts(ctx context.Context) map[int64][]store.RunStart`
  - `func startKind(action corev1.RunAction) (string, bool)`
  - `func withStarts(runs []*corev1.WorkflowRun, starts map[int64][]store.RunStart)`
  - `func addStarts(ctx context.Context, rt *workspace.Runtime, runs []*corev1.WorkflowRun)`

- [ ] **Step 1: Write the failing server tests**

Create `core/internal/server/starts_test.go`. It reuses `deployWorkflow` (dispatch_test.go), `sendDispatch` (dispatch_history_test.go), `workspaceRig`, `testWorkspace` (workspace_test.go) and `linkedRepository` (github_test.go):

```go
//go:build !windows

package server

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/store"
)

// startsGitHub serves o/r with two runs of Deploy:
//   - 21, failed, in its attempt `attempt`;
//   - 22, which a dispatch starts.
//
// It accepts the dispatch, naming run 22, and re-runs of run 21. Each
// re-run starts the next attempt; refuse makes GitHub refuse them. gone
// stops serving run 21, as when GitHub deletes it.
type startsGitHub struct {
	mu           sync.Mutex
	attempt      int64
	refuse, gone bool
}

var startsCreated = time.Date(2026, 10, 28, 10, 0, 0, 0, time.UTC)

func (f *startsGitHub) set(change func()) {
	f.mu.Lock()
	defer f.mu.Unlock()
	change()
}

func (f *startsGitHub) server(t *testing.T) *httptest.Server {
	t.Helper()
	run := func(id, attempt int64) string {
		stamp := startsCreated.Format(time.RFC3339)
		return fmt.Sprintf(`{"id":%d,"workflow_id":7,"name":"Deploy","display_title":"Deploy %d","run_number":%d,"run_attempt":%d,"event":"workflow_dispatch",
"status":"completed","conclusion":"failure","head_branch":"main","head_sha":"abc","created_at":%q,"updated_at":%q}`, id, id, id, attempt, stamp, stamp)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		switch {
		case r.URL.Path == "/repos/o/r":
			_, _ = w.Write([]byte(`{"full_name":"o/r","default_branch":"main"}`))
		case r.URL.Path == "/repos/o/r/pulls":
			_, _ = w.Write([]byte(`[]`))
		case r.URL.Path == "/repos/o/r/actions/workflows":
			_, _ = w.Write([]byte(`{"total_count":1,"workflows":[{"id":7,"name":"Deploy","path":".github/workflows/deploy.yml","state":"active"}]}`))
		case r.URL.Path == "/repos/o/r/actions/workflows/7":
			_, _ = w.Write([]byte(`{"id":7,"path":".github/workflows/deploy.yml"}`))
		case r.URL.Path == "/repos/o/r/contents/.github/workflows/deploy.yml":
			_, _ = w.Write([]byte(deployWorkflow))
		case r.URL.Path == "/repos/o/r/actions/workflows/7/dispatches" && r.Method == http.MethodPost:
			_, _ = w.Write([]byte(`{"workflow_run_id":22}`))
		case r.URL.Path == "/repos/o/r/actions/runs":
			items := []string{run(22, 1)}
			if !f.gone {
				items = append(items, run(21, f.attempt))
			}
			_, _ = w.Write([]byte(`{"total_count":` + strconv.Itoa(len(items)) + `,"workflow_runs":[` + strings.Join(items, ",") + `]}`))
		case r.URL.Path == "/repos/o/r/actions/runs/21" && r.Method == http.MethodGet && !f.gone:
			_, _ = w.Write([]byte(run(21, f.attempt)))
		case r.URL.Path == "/repos/o/r/actions/jobs/11" && r.Method == http.MethodGet:
			_, _ = w.Write([]byte(`{"id":11,"run_id":21,"name":"build","status":"completed","conclusion":"failure","steps":[]}`))
		case r.Method == http.MethodPost && (r.URL.Path == "/repos/o/r/actions/runs/21/rerun" ||
			r.URL.Path == "/repos/o/r/actions/runs/21/rerun-failed-jobs" || r.URL.Path == "/repos/o/r/actions/jobs/11/rerun"):
			if f.refuse {
				w.WriteHeader(http.StatusForbidden)
				_, _ = w.Write([]byte(`{"message":"Unable to re-run this workflow run because it was created over a month ago"}`))
				return
			}
			f.attempt++
			w.WriteHeader(http.StatusCreated)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)
	return server
}

// startsText is "1:RUNNIR_START_KIND_DISPATCH 2:…", the starts of a run.
func startsText(run *corev1.WorkflowRun) string {
	var parts []string
	for _, s := range run.GetRunnirStarts() {
		parts = append(parts, fmt.Sprintf("%d:%s", s.GetAttempt(), s.GetKind()))
	}
	return strings.Join(parts, " ")
}

func TestAttemptsRunnirStartedAreMarkedOnTheRunsOfTheWorkspace(t *testing.T) {
	fake := &startsGitHub{attempt: 1}
	server := fake.server(t)
	client, stop, ctx := workspaceRig(t, t.TempDir(), server.URL)
	defer stop()
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.com:o/r.git"), WorkspaceId: testWorkspace})
	if err != nil {
		t.Fatal(err)
	}
	id := opened.Repository.Id
	refresh := func() {
		t.Helper()
		if _, err := client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: id, Wait: true}); err != nil {
			t.Fatal(err)
		}
	}
	act := func(action corev1.RunAction, jobID int64) *corev1.ConfirmRunActionResponse {
		t.Helper()
		prepared, err := client.PrepareRunAction(ctx, &corev1.PrepareRunActionRequest{RepositoryId: id, RunId: 21, Action: action, JobId: jobID})
		if err != nil || prepared.ActionId == "" {
			t.Fatalf("prepare %v = %v, %v", action, prepared, err)
		}
		confirmed, err := client.ConfirmRunAction(ctx, &corev1.ConfirmRunActionRequest{ActionId: prepared.ActionId})
		if err != nil {
			t.Fatal(err)
		}
		return confirmed
	}
	refresh()

	if sent := sendDispatch(t, client, ctx, id, "main", map[string]string{"environment": "staging"}); sent.RunId != 22 {
		t.Fatalf("dispatch = %v", sent)
	}
	act(corev1.RunAction_RUN_ACTION_RERUN_FAILED, 0) // attempt 1 reviewed: attempt 2 is Runnir's
	act(corev1.RunAction_RUN_ACTION_RERUN_JOB, 11)   // attempt 2 reviewed: attempt 3 is Runnir's
	fake.set(func() { fake.refuse = true })
	if refused := act(corev1.RunAction_RUN_ACTION_RERUN, 0); refused.Rejection == "" {
		t.Fatalf("refused = %v", refused)
	}
	refresh()

	want := map[int64]string{
		22: "1:RUNNIR_START_KIND_DISPATCH",
		21: "2:RUNNIR_START_KIND_RERUN_FAILED 3:RUNNIR_START_KIND_RERUN_JOB",
	}
	activity, err := client.GetWorkspaceActivity(ctx, &corev1.GetWorkspaceActivityRequest{RepositoryId: id})
	if err != nil || len(activity.Runs) != 2 {
		t.Fatalf("activity = %v, %v", activity, err)
	}
	for _, run := range activity.Runs {
		if got := startsText(run); got != want[run.Id] {
			t.Fatalf("activity run %d = %q, want %q", run.Id, got, want[run.Id])
		}
	}

	deep, err := client.SearchRunsOnGitHub(ctx, &corev1.SearchRunsOnGitHubRequest{RepositoryId: id, Query: "deploy"})
	if err != nil || len(deep.Runs) != 2 {
		t.Fatalf("deep search = %v, %v", deep, err)
	}
	for _, run := range deep.Runs {
		if got := startsText(run); got != want[run.Id] {
			t.Fatalf("found on GitHub %d = %q, want %q", run.Id, got, want[run.Id])
		}
	}

	// GitHub deletes run 21: the cache drops it and the search index keeps it, with its marks.
	fake.set(func() { fake.gone = true })
	refresh()
	indexed, err := client.SearchRuns(ctx, &corev1.SearchRunsRequest{RepositoryId: id, Query: "deploy 21"})
	if err != nil || len(indexed.IndexedRuns) != 1 || startsText(indexed.IndexedRuns[0]) != want[21] {
		t.Fatalf("indexed = %v, %v", indexed, err)
	}
}

func TestRunsCarryTheAttemptsRunnirStartedUpToTheirOwn(t *testing.T) {
	at := time.Date(2026, 10, 28, 10, 0, 0, 0, time.UTC)
	runs := []*corev1.WorkflowRun{{Id: 21, RunAttempt: 2}, {Id: 22}, {Id: 23, RunAttempt: 1}}
	withStarts(runs, map[int64][]store.RunStart{
		21: {
			{RunID: 21, Attempt: 1, Kind: store.StartDispatch, SentAt: at},
			{RunID: 21, Attempt: 2, Kind: store.StartRerunFailed, SentAt: at},
			// Recorded before GitHub reports attempt 3: it waits.
			{RunID: 21, Attempt: 3, Kind: store.StartRerun, SentAt: at},
		},
		22: {{RunID: 22, Attempt: 1, Kind: store.StartDispatch, SentAt: at}},
	})
	if got := startsText(runs[0]); got != "1:RUNNIR_START_KIND_DISPATCH 2:RUNNIR_START_KIND_RERUN_FAILED" ||
		!runs[0].GetRunnirStarts()[1].GetSentAt().AsTime().Equal(at) {
		t.Fatalf("run 21 = %v", runs[0].GetRunnirStarts())
	}
	// A run that does not say its attempt is in its first.
	if got := startsText(runs[1]); got != "1:RUNNIR_START_KIND_DISPATCH" {
		t.Fatalf("run 22 = %q", got)
	}
	if len(runs[2].GetRunnirStarts()) != 0 {
		t.Fatalf("run 23 = %v", runs[2].GetRunnirStarts())
	}
}

func TestOnlyReRunsStartAnAttempt(t *testing.T) {
	for action, want := range map[corev1.RunAction]string{
		corev1.RunAction_RUN_ACTION_RERUN: store.StartRerun, corev1.RunAction_RUN_ACTION_RERUN_FAILED: store.StartRerunFailed,
		corev1.RunAction_RUN_ACTION_RERUN_JOB: store.StartRerunJob, corev1.RunAction_RUN_ACTION_CANCEL: "",
		corev1.RunAction_RUN_ACTION_APPROVE_DEPLOYMENTS: "",
	} {
		if kind, ok := startKind(action); kind != want || ok != (want != "") {
			t.Fatalf("%v = %q, %v", action, kind, ok)
		}
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd core && go test ./internal/server/ -run 'Runnir|ReRunsStart|UpToTheirOwn' -count=1`
Expected: FAIL to compile, with `undefined: withStarts` and `undefined: startKind`.

- [ ] **Step 3: Read the starts for a workspace**

In `core/internal/workspace/search.go`, after `searchSource`, add:

```go
// RunStarts are the attempts Runnir started of the runs of the repository
// the workspace shows (B46), by run. A read that fails gives none: the runs
// are shown unmarked rather than not at all.
func (r *Runtime) RunStarts(ctx context.Context) map[int64][]store.RunStart {
	source, ok := r.searchSource(ctx)
	if !ok {
		return nil
	}
	starts, _ := r.cfg.store.RunStarts(ctx, source)
	return starts
}
```

- [ ] **Step 4: Add `starts.go` to the server**

Create `core/internal/server/starts.go`:

```go
package server

import (
	"context"
	"strings"
	"time"

	"google.golang.org/protobuf/types/known/timestamppb"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/store"
	"runnir/core/internal/workspace"
)

// startKind is the kind of start a confirmed run action records: a re-run
// starts the run's next attempt. Cancel and approve start none.
func startKind(action corev1.RunAction) (string, bool) {
	switch action {
	case corev1.RunAction_RUN_ACTION_RERUN:
		return store.StartRerun, true
	case corev1.RunAction_RUN_ACTION_RERUN_FAILED:
		return store.StartRerunFailed, true
	case corev1.RunAction_RUN_ACTION_RERUN_JOB:
		return store.StartRerunJob, true
	}
	return "", false
}

// recordRerun keeps a re-run GitHub accepted as the attempt after the one
// reviewed, in the repository's workspace; without one nothing is kept.
// GitHub refuses to re-run a run that is not finished, so the attempt is
// wrong only when another re-run starts and finishes between review and
// confirmation.
func (s *service) recordRerun(ctx context.Context, prepared runAction, sentAt time.Time) {
	kind, ok := startKind(prepared.Action)
	if !ok {
		return
	}
	rt, ok := s.workspaces.ForRepository(prepared.RepositoryID)
	if !ok {
		return
	}
	_ = rt.Store().RecordStart(ctx, store.RunStart{
		Source: store.Source{ServerID: prepared.ServerID, Repository: strings.ToLower(prepared.Owner + "/" + prepared.Name)},
		RunID:  prepared.RunID, Attempt: prepared.Attempt + 1, Kind: kind, SentAt: sentAt,
	})
}

// addStarts adds the attempts Runnir started to the messages of a
// workspace's runs (B46).
func addStarts(ctx context.Context, rt *workspace.Runtime, runs []*corev1.WorkflowRun) {
	if len(runs) == 0 {
		return
	}
	withStarts(runs, rt.RunStarts(ctx))
}

// withStarts adds to each run the attempts Runnir started, oldest first, up
// to the run's attempt: one recorded before GitHub reports it waits.
func withStarts(runs []*corev1.WorkflowRun, starts map[int64][]store.RunStart) {
	kinds := map[string]corev1.RunnirStartKind{
		store.StartDispatch: corev1.RunnirStartKind_RUNNIR_START_KIND_DISPATCH, store.StartRerun: corev1.RunnirStartKind_RUNNIR_START_KIND_RERUN,
		store.StartRerunFailed: corev1.RunnirStartKind_RUNNIR_START_KIND_RERUN_FAILED, store.StartRerunJob: corev1.RunnirStartKind_RUNNIR_START_KIND_RERUN_JOB,
	}
	for _, run := range runs {
		for _, start := range starts[run.GetId()] {
			if start.Attempt <= max(run.GetRunAttempt(), 1) {
				run.RunnirStarts = append(run.RunnirStarts, &corev1.RunnirStart{Attempt: start.Attempt, Kind: kinds[start.Kind], SentAt: timestamppb.New(start.SentAt)})
			}
		}
	}
}
```

- [ ] **Step 5: Keep the reviewed attempt and record the re-run**

In `core/internal/server/runs.go`:

1. Add a field to `runAction`, after `RunID int64`:

```go
	// Attempt is the run's attempt when it was reviewed, 1 when GitHub gives
	// none; a re-run starts the next one.
	Attempt int64
```

2. In `PrepareRunAction`, the `s.runActions.Prepare(runAction{...})` literal gets `Attempt: max(run.RunAttempt, 1),` after `RunID: run.ID,`.

3. In `ConfirmRunAction`, replace:

```go
	if sendErr == nil {
		out.AcceptedAt = timestamppb.New(acceptedAt)
	}
```

with:

```go
	if sendErr == nil {
		out.AcceptedAt = timestamppb.New(acceptedAt)
		s.recordRerun(ctx, prepared, acceptedAt)
	}
```

- [ ] **Step 6: Send the starts where the runs list gets its runs**

In `core/internal/server/workspace.go`, `snapshotMessage`, after the `for _, r := range snap.Runs { ... }` loop, add:

```go
	addStarts(ctx, rt, out.Runs)
```

In `core/internal/server/search.go`:
- `SearchRuns`: after the `for _, run := range found.Indexed { ... }` loop, add `addStarts(ctx, rt, out.IndexedRuns)`.
- `SearchRunsOnGitHub`: after the `for _, run := range step.Runs { ... }` loop, add `addStarts(ctx, rt, out.Runs)`.

Global search (`SearchWorkspaces`), the Overview's lanes (`flow.go`), `ListWorkflowRuns` and `PrepareRunAction` stay without starts.

- [ ] **Step 7: Run the server tests**

Run: `cd core && go test ./internal/server/ -run 'Runnir|ReRunsStart|UpToTheirOwn' -count=1 -v`
Expected: PASS for the three tests.

If the indexed check fails because the cache still holds run 21 after `gone`, read how the sync drops runs GitHub no longer serves (`TestSearchFindsRunsBeyondTheCacheAndKeepsWhatGitHubDeleted` does the same) before changing the test.

- [ ] **Step 8: Run the whole Core**

Run: `cd core && go test ./... -count=1 && go vet ./... && go build ./...`
Expected: all packages `ok`, no vet output.

- [ ] **Step 9: Commit**

```bash
git add core/internal/server core/internal/workspace
git commit -m "Core: re-runs GitHub accepted are kept by attempt, and the runs list's runs carry the attempts Runnir started (B46)"
```

---

### Task 4: The App Reads The Starts

**Files:**
- Modify: `apps/macos/Runnir/IPC/CoreGitHubModels.swift` (`CoreWorkflowRun`, new `CoreRunnirStart` above it)
- Modify: `apps/macos/Runnir/IPC/GRPCCoreService.swift` (`static func map(_ run: Runnir_Core_V1_WorkflowRun)`)
- Test: `apps/macos/RunnirTests/RunLinkMappingTests.swift`

**Interfaces:**
- Consumes: the Swift generated types from Task 2.
- Produces:
  - `struct CoreRunnirStart: Equatable, Sendable { enum Kind { case dispatch, rerun, rerunFailed, rerunJob }; let attempt: Int64; let kind: Kind; let sentAt: Date }`
  - `CoreWorkflowRun.runnirStarts: [CoreRunnirStart]` (default `[]`) and `CoreWorkflowRun.startedFromRunnir: Bool`
  - `static func GRPCCoreService.map(_ start: Runnir_Core_V1_RunnirStart) -> CoreRunnirStart?`

- [ ] **Step 1: Write the failing mapping test**

Add to `RunLinkMappingTests` in `apps/macos/RunnirTests/RunLinkMappingTests.swift`:

```swift
    @Test func runsCarryTheAttemptsRunnirStarted() {
        let message = Runnir_Core_V1_WorkflowRun.with {
            $0.id = 21; $0.runAttempt = 2
            $0.runnirStarts = [
                .with { $0.attempt = 1; $0.kind = .dispatch; $0.sentAt.seconds = 1_000 },
                .with { $0.attempt = 2; $0.kind = .rerunFailed; $0.sentAt.seconds = 2_000 },
                .with { $0.attempt = 3; $0.kind = .unspecified },
            ]
        }
        let run = GRPCCoreService.map(message)
        #expect(run.runnirStarts == [CoreRunnirStart(attempt: 1, kind: .dispatch, sentAt: Date(timeIntervalSince1970: 1_000)),
                                     CoreRunnirStart(attempt: 2, kind: .rerunFailed, sentAt: Date(timeIntervalSince1970: 2_000))],
                "a kind this app does not know is left out")
        #expect(run.startedFromRunnir)
        #expect(!GRPCCoreService.map(Runnir_Core_V1_WorkflowRun.with { $0.id = 9 }).startedFromRunnir)
    }
```

- [ ] **Step 2: Add the model**

In `CoreGitHubModels.swift`, above `struct CoreWorkflowRun`:

```swift
/// An attempt of a run that Runnir started on this Mac (B46): a dispatch
/// starts attempt 1, a re-run the next attempt. GitHub keeps no mark of it.
struct CoreRunnirStart: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case dispatch, rerun, rerunFailed, rerunJob }

    let attempt: Int64
    let kind: Kind
    let sentAt: Date
}
```

In `CoreWorkflowRun`, after `var statusGroup: CoreRunStatusGroup?`:

```swift
    /// The attempts Runnir started on this Mac, oldest first, up to
    /// `runAttempt`; only this Mac knows them.
    var runnirStarts: [CoreRunnirStart] = []
```

And after `var isOutdated: Bool { ... }`:

```swift
    /// Runnir started an attempt of this run on this Mac.
    var startedFromRunnir: Bool { !runnirStarts.isEmpty }
```

- [ ] **Step 3: Map it**

In `GRPCCoreService.swift`, `static func map(_ run: Runnir_Core_V1_WorkflowRun)`, change the end of the initializer call:

```swift
            statusGroup: Self.map(run.statusGroup),
            runnirStarts: run.runnirStarts.compactMap(Self.map)
        )
    }

    /// nil for a kind this app does not know.
    static func map(_ start: Runnir_Core_V1_RunnirStart) -> CoreRunnirStart? {
        let kind: CoreRunnirStart.Kind
        switch start.kind {
        case .dispatch: kind = .dispatch
        case .rerun: kind = .rerun
        case .rerunFailed: kind = .rerunFailed
        case .rerunJob: kind = .rerunJob
        case .unspecified, .UNRECOGNIZED: return nil
        }
        return CoreRunnirStart(attempt: max(1, start.attempt), kind: kind, sentAt: start.sentAt.date)
    }
```

- [ ] **Step 4: Run the test**

Run (with the Go PATH from Global Constraints): `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/RunLinkMappingTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Runnir/IPC/CoreGitHubModels.swift apps/macos/Runnir/IPC/GRPCCoreService.swift apps/macos/RunnirTests/RunLinkMappingTests.swift
git commit -m "App: runs carry the attempts Runnir started (B46)"
```

---

### Task 5: The Row And The Inspector Say It

**Files:**
- Modify: `apps/macos/Runnir/Features/Desktop/RunChanges.swift` (`rowHelp`, and a new section at the end of the file)
- Modify: `apps/macos/Runnir/Features/Desktop/GitHubActivityViews.swift` (`RunRow`, the detail line)
- Modify: `apps/macos/Runnir/Features/Desktop/RunChangeViews.swift` (`RunChangeRow`)
- Modify: `apps/macos/Runnir/Features/Desktop/RunInspectorView.swift` (`summary`)
- Test: `apps/macos/RunnirTests/RunChangesTests.swift`

**Interfaces:**
- Consumes: `CoreRunnirStart`, `CoreWorkflowRun.runnirStarts`, `startedFromRunnir` (Task 4).
- Produces:
  - `RunPresentation.fromRunnir: String` (`"From Runnir · "`)
  - `RunPresentation.onlyThisMacKnows: String`
  - `RunPresentation.runnirAttempt(_ run: CoreWorkflowRun) -> String?`
  - `RunPresentation.runnirHelp(_ run: CoreWorkflowRun, now: Date = Date()) -> String?`

- [ ] **Step 1: Write the failing presentation tests**

Add to `RunChangesTests` in `apps/macos/RunnirTests/RunChangesTests.swift`:

```swift
    private let sent = Date(timeIntervalSince1970: 1_000_000)

    private func started(_ starts: [CoreRunnirStart], attempt: Int64) -> CoreWorkflowRun {
        var marked = run(21)
        marked.runAttempt = attempt
        marked.runnirStarts = starts
        return marked
    }

    @Test func aRunRunnirStartedSaysSoBeforeItsDetailAndInItsHelp() {
        let dispatched = started([CoreRunnirStart(attempt: 1, kind: .dispatch, sentAt: sent)], attempt: 1)
        #expect(dispatched.startedFromRunnir && !run(1).startedFromRunnir)
        #expect(RunPresentation.fromRunnir == "From Runnir \u{00B7} ")
        let help = RunPresentation.rowHelp(dispatched, pullRequest: nil)
        #expect(help.hasPrefix("Commit a1b2c3d Bump retry count\nAttempt 1 was started from Runnir on this Mac, "))
        #expect(help.hasSuffix("\n" + RunPresentation.onlyThisMacKnows))
        #expect(RunPresentation.rowHelp(run(1), pullRequest: nil) == "Commit a1b2c3d Bump retry count", "a run Runnir did not start keeps its help")
    }

    @Test func theInspectorSaysWhichAttemptRunnirStarted() {
        let dispatch = CoreRunnirStart(attempt: 1, kind: .dispatch, sentAt: sent)
        let rerun = CoreRunnirStart(attempt: 2, kind: .rerunFailed, sentAt: sent)
        #expect(RunPresentation.runnirAttempt(started([dispatch], attempt: 1)) == " \u{00B7} from Runnir")
        #expect(RunPresentation.runnirAttempt(started([rerun], attempt: 2)) == " \u{00B7} re-run from Runnir")
        #expect(RunPresentation.runnirAttempt(started([dispatch, rerun], attempt: 3)) == " \u{00B7} attempt 2 from Runnir", "the newest earlier attempt")
        #expect(RunPresentation.runnirAttempt(run(1)) == nil)
    }

    @Test func theHelpNamesEachAttemptAndThatOnlyThisMacKnows() throws {
        let rerun = CoreRunnirStart(attempt: 2, kind: .rerunFailed, sentAt: sent)
        let one = try #require(RunPresentation.runnirHelp(started([rerun], attempt: 2), now: sent.addingTimeInterval(12 * 60)))
        #expect(one.hasPrefix("Attempt 2 re-ran the failed jobs from Runnir on this Mac, "))
        #expect(one.contains(" Attempt 1 was not started from this Mac.\n"))
        #expect(one.hasSuffix(RunPresentation.onlyThisMacKnows))
        let many = try #require(RunPresentation.runnirHelp(started([CoreRunnirStart(attempt: 2, kind: .rerun, sentAt: sent),
                                                                    CoreRunnirStart(attempt: 4, kind: .rerunJob, sentAt: sent)], attempt: 4), now: sent))
        #expect(many.contains("Attempt 2 re-ran every job from Runnir on this Mac, "))
        #expect(many.contains("Attempt 4 re-ran one job from Runnir on this Mac, "))
        #expect(many.contains("Attempts 1 and 3 were not started from this Mac."))
        #expect(RunPresentation.runnirHelp(run(1)) == nil)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/RunChangesTests`
Expected: build FAILS with `type 'RunPresentation' has no member 'fromRunnir'`.

- [ ] **Step 3: Add the words and the help**

At the end of `apps/macos/Runnir/Features/Desktop/RunChanges.swift`:

```swift
// MARK: Runs started from Runnir (B46)

extension RunPresentation {
    /// The words before the detail line of a run Runnir started.
    static let fromRunnir = "From Runnir \u{00B7} "
    static let onlyThisMacKnows = "Only this Mac knows: GitHub keeps no mark on runs, so other Macs and github.com do not show it."

    /// The words beside the attempt in the inspector: how Runnir started the
    /// run's latest attempt, or the newest earlier attempt it started; nil
    /// when it started none.
    static func runnirAttempt(_ run: CoreWorkflowRun) -> String? {
        if let latest = run.runnirStarts.first(where: { $0.attempt == run.runAttempt }) {
            return latest.kind == .dispatch ? " \u{00B7} from Runnir" : " \u{00B7} re-run from Runnir"
        }
        guard let earlier = run.runnirStarts.filter({ $0.attempt < run.runAttempt }).map(\.attempt).max() else { return nil }
        return " \u{00B7} attempt \(earlier) from Runnir"
    }

    /// The help of those words and of the row: each attempt Runnir started,
    /// the attempts it did not, and that only this Mac knows; nil when it
    /// started none.
    static func runnirHelp(_ run: CoreWorkflowRun, now: Date = Date()) -> String? {
        let starts = run.runnirStarts.filter { $0.attempt <= run.runAttempt }.sorted { $0.attempt < $1.attempt }
        guard !starts.isEmpty else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .named
        var sentences = starts.map { start in
            "Attempt \(start.attempt) \(start.kind.sentence) from Runnir on this Mac, \(formatter.localizedString(for: start.sentAt, relativeTo: now))."
        }
        let started = Set(starts.map(\.attempt))
        let others = (1...max(run.runAttempt, 1)).filter { !started.contains($0) }
        if let last = others.last {
            sentences.append(others.count == 1
                ? "Attempt \(last) was not started from this Mac."
                : "Attempts \(others.dropLast().map(String.init).joined(separator: ", ")) and \(last) were not started from this Mac.")
        }
        return sentences.joined(separator: " ") + "\n" + onlyThisMacKnows
    }
}

private extension CoreRunnirStart.Kind {
    /// What the attempt did, for the help.
    var sentence: String {
        switch self {
        case .dispatch: "was started"
        case .rerun: "re-ran every job"
        case .rerunFailed: "re-ran the failed jobs"
        case .rerunJob: "re-ran one job"
        }
    }
}
```

In `rowHelp` (same file), before `return lines.joined(separator: "\n")`:

```swift
        if let runnir = runnirHelp(run) { lines.append(runnir) }
```

- [ ] **Step 4: Draw them**

In `RunRow` (`GitHubActivityViews.swift`), replace:

```swift
                Text(RunPresentation.detail(run)).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
```

with:

```swift
                HStack(spacing: 0) {
                    if run.startedFromRunnir {
                        Text(RunPresentation.fromRunnir).foregroundStyle(RunnirTheme.primary).fixedSize()
                            .accessibilityLabel("started from Runnir")
                    }
                    Text(RunPresentation.detail(run)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
                .font(.system(size: 11)).lineLimit(1)
```

In `RunChangeRow` (`RunChangeViews.swift`), before `Text("\(run.name) #\(run.runNumber)")`:

```swift
            if run.startedFromRunnir {
                Text("From Runnir").font(.system(size: 11)).foregroundStyle(RunnirTheme.primary).lineLimit(1).fixedSize()
                    .accessibilityLabel("started from Runnir")
            }
```

`RunChangeRow` already adds `rowHelp`, which now carries the Runnir help.

In `RunInspectorView.swift`, `summary`, replace `Text("Attempt \(run.runAttempt)")` with `attempt`, and add next to `summary`:

```swift
    /// "Attempt 2", and which attempt Runnir started beside it (B46).
    @ViewBuilder private var attempt: some View {
        if let words = RunPresentation.runnirAttempt(run) {
            HStack(spacing: 0) {
                Text("Attempt \(run.runAttempt)")
                Text(words).foregroundStyle(RunnirTheme.primary)
            }
            .help(RunPresentation.runnirHelp(run) ?? "")
        } else {
            Text("Attempt \(run.runAttempt)")
        }
    }
```

- [ ] **Step 5: Run the tests**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/RunChangesTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Runnir/Features/Desktop/RunChanges.swift apps/macos/Runnir/Features/Desktop/GitHubActivityViews.swift \
  apps/macos/Runnir/Features/Desktop/RunChangeViews.swift apps/macos/Runnir/Features/Desktop/RunInspectorView.swift \
  apps/macos/RunnirTests/RunChangesTests.swift
git commit -m "App: a run Runnir started says so in its row and beside its attempt, with help that only this Mac knows (B46)"
```

---

### Task 6: From Runnir In The Status Filter

**Files:**
- Modify: `apps/macos/Runnir/Features/Desktop/RunStatusFilter.swift`
- Modify: `apps/macos/Runnir/Features/Desktop/RunSearch.swift` (`list`, `changes`)
- Modify: `apps/macos/Runnir/Features/Desktop/GitHubActivityViews.swift` (filter state, header, `searchNote`, `listRows`, `changeBlocks`, `beyondSaved`)
- Test: `apps/macos/RunnirTests/RunStatusFilterTests.swift`, `apps/macos/RunnirTests/RunSearchTests.swift`

**Interfaces:**
- Consumes: `CoreWorkflowRun.startedFromRunnir` (Task 4).
- Produces:
  - `struct RunFilter: Equatable, Sendable { var statuses: Set<RunStatusFilter> = []; var fromRunnir = false; var isEmpty: Bool; var count: Int; func matches(_:) -> Bool; func apply(_:) -> [CoreWorkflowRun]; static func fromRunnirCount(_:) -> Int }`
  - `struct RunnirMark: View`
  - `RunPresentation.list(_:branch:matching:filter:showingSuperseded:)` and `RunPresentation.changes(_:runs:branch:matching:filter:)`, where `filter: RunFilter = RunFilter()` replaces `statuses:`.
  - `StatusFilterButton(filter:counts:fromRunnirCount:query:)`, `StatusFilterMenu(filter:counts:fromRunnirCount:query:)`, `StatusChips(filter:)`.
- Removes `RunStatusFilter.filter(_:statuses:)`; `RunFilter.apply` takes its place.

- [ ] **Step 1: Write the failing tests and move the existing ones to `RunFilter`**

In `apps/macos/RunnirTests/RunStatusFilterTests.swift`:

1. Replace the `run` helper:

```swift
    /// A run as the Core sends it: its status group set by the Core. Status
    /// and conclusion say nothing to the filter, so they are left alike.
    private func run(_ id: Int64, title: String = "Fix build", branch: String = "main",
                     group: CoreRunStatusGroup? = .succeeded, fromRunnir: Bool = false) -> CoreWorkflowRun {
        CoreWorkflowRun(id: id, workflowID: 3, name: "CI", displayTitle: title, runNumber: id, event: "push", status: "completed",
                        conclusion: "success", branch: branch, headSHA: "a3f9c21ffee0", actor: "eugene", htmlURL: nil, createdAt: nil,
                        updatedAt: nil, commitTitle: "", link: .none, supersededBy: nil, statusGroup: group,
                        runnirStarts: fromRunnir ? [CoreRunnirStart(attempt: 1, kind: .dispatch, sentAt: Date(timeIntervalSince1970: 0))] : [])
    }
```

2. Replace the uses of `RunStatusFilter.filter`:
   - `RunStatusFilter.filter([unknown, run(1)], statuses: [.succeeded])` → `RunFilter(statuses: [.succeeded]).apply([unknown, run(1)])`
   - `RunStatusFilter.filter([unknown], statuses: [])` → `RunFilter().apply([unknown])`
   - `RunStatusFilter.filter(runs, statuses: [])` → `RunFilter().apply(runs)`
   - `RunStatusFilter.filter(runs, statuses: [.failed])` → `RunFilter(statuses: [.failed]).apply(runs)`
   - `RunStatusFilter.filter(runs, statuses: [.failed, .running])` → `RunFilter(statuses: [.failed, .running]).apply(runs)`

3. Replace every `statuses: [.failed]` and `statuses: []` argument of `RunPresentation.list` with `filter: RunFilter(statuses: [.failed])` and `filter: RunFilter()`. There are five, in `theStatusFilterCombinesWithTheFoundRunsAndTheBranch` and `aStatusFilterShowsSupersededRunsLikeASearchDoes`.

4. Add:

```swift
    @Test func fromRunnirNarrowsTheTickedStatusesWithAnd() {
        let runs = [run(1, fromRunnir: true), run(2, group: .failed, fromRunnir: true), run(3, group: .failed)]
        #expect(RunFilter(fromRunnir: true).apply(runs).map(\.id) == [1, 2])
        #expect(RunFilter(statuses: [.failed], fromRunnir: true).apply(runs).map(\.id) == [2])
        #expect(RunFilter(statuses: [.failed, .succeeded], fromRunnir: true).apply(runs).map(\.id) == [1, 2], "statuses still combine with OR")
        #expect(RunFilter(statuses: [.failed], fromRunnir: true).count == 2)
        #expect(RunFilter().isEmpty && !RunFilter(fromRunnir: true).isEmpty)
    }

    @Test func theFromRunnirCountFollowsTheFoundRunsAndTheBranchWhateverIsTicked() {
        let runs = [run(1, fromRunnir: true), run(2, branch: "dev", fromRunnir: true), run(3)]
        #expect(RunFilter.fromRunnirCount(RunPresentation.matching(runs, branch: nil, ids: nil)) == 2)
        #expect(RunFilter.fromRunnirCount(RunPresentation.matching(runs, branch: "main", ids: nil)) == 1)
        #expect(RunFilter.fromRunnirCount(RunPresentation.matching(runs, branch: nil, ids: [2, 3])) == 1)
    }

    @Test func fromRunnirWorksInTheListAndByChange() {
        let runs = [run(1, fromRunnir: true), run(2, group: .failed)]
        #expect(RunPresentation.list(runs, branch: nil, filter: RunFilter(fromRunnir: true), showingSuperseded: false).map(\.id) == [1])
        func change(_ id: String, _ runIDs: [Int64]) -> CoreRunChange {
            CoreRunChange(id: id, pullRequest: nil, status: .passed, latestAt: nil,
                          sections: [CoreRunChangeSection(kind: .commit, headSHA: "3c4d5e6f", branch: "main", commitTitle: "Bump Go", runIDs: runIDs, repeatRunIDs: [])],
                          olderRunIDs: [], olderCommits: 0)
        }
        let byID = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
        let changes = [change("commit:a", [1]), change("commit:b", [2])]
        #expect(RunPresentation.changes(changes, runs: byID, branch: nil, filter: RunFilter(fromRunnir: true)).map(\.id) == ["commit:a"])
        #expect(RunPresentation.changes(changes, runs: byID, branch: nil, filter: RunFilter(statuses: [.failed], fromRunnir: true)).isEmpty,
                "one run has to pass the statuses and From Runnir together")
    }
```

In `apps/macos/RunnirTests/RunSearchTests.swift`, `aChangeMatchesWhenOneOfItsRunsWasFound`, replace the `ids` helper:

```swift
        func ids(_ found: Set<Int64>?, branch: String? = nil, statuses: Set<RunStatusFilter> = []) -> [String] {
            RunPresentation.changes([withPull, commit], runs: runs, branch: branch, matching: found, filter: RunFilter(statuses: statuses)).map(\.id)
        }
```

- [ ] **Step 2: Run them to see them fail**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/RunStatusFilterTests -only-testing:RunnirTests/RunSearchTests`
Expected: build FAILS with `cannot find 'RunFilter' in scope`.

- [ ] **Step 3: Add `RunFilter` and `RunnirMark`, remove `RunStatusFilter.filter`**

In `RunStatusFilter.swift`:
- delete `static func filter(_ runs: [CoreWorkflowRun], statuses: Set<RunStatusFilter>) -> [CoreWorkflowRun]` and its doc comment;
- after the `RunStatusFilter` enum, before `// MARK: Views`, add:

```swift
/// What the runs list is narrowed to besides the query and the branch: the
/// ticked statuses (any of them) and, with From Runnir ticked, only the runs
/// Runnir started on this Mac (B46). Kept per window while the app runs.
struct RunFilter: Equatable, Sendable {
    var statuses: Set<RunStatusFilter> = []
    var fromRunnir = false

    var isEmpty: Bool { statuses.isEmpty && !fromRunnir }
    /// How many items of the menu are ticked.
    var count: Int { statuses.count + (fromRunnir ? 1 : 0) }

    /// Whether the run passes: one of the statuses (any for none) and, with
    /// From Runnir ticked, an attempt Runnir started.
    func matches(_ run: CoreWorkflowRun) -> Bool {
        (statuses.isEmpty || RunStatusFilter.matches(run, statuses)) && (!fromRunnir || run.startedFromRunnir)
    }

    /// The runs that pass; all of them for an empty filter.
    func apply(_ runs: [CoreWorkflowRun]) -> [CoreWorkflowRun] {
        isEmpty ? runs : runs.filter(matches)
    }

    /// How many of `runs` Runnir started, for the From Runnir item.
    static func fromRunnirCount(_ runs: [CoreWorkflowRun]) -> Int {
        runs.count(where: \.startedFromRunnir)
    }
}

/// The Runnir mark, the menu bar icon's image, tinted like text.
struct RunnirMark: View {
    var size: CGFloat = 12

    var body: some View {
        Image("MenuBarIcon").renderingMode(.template).resizable().scaledToFit().frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
```

- [ ] **Step 4: Put From Runnir in the menu and the chips**

In `RunStatusFilter.swift`, change the views:

1. `StatusFilterButton`:
   - replace `@Binding var statuses: Set<RunStatusFilter>` with `@Binding var filter: RunFilter`;
   - add `/// Runs Runnir started among them.` and `let fromRunnirCount: Int` after `counts`;
   - `active` becomes `!filter.isEmpty`;
   - `.accessibilityValue(active ? "\(filter.count) selected" : "none")`;
   - the popover content is `StatusFilterMenu(filter: $filter, counts: counts, fromRunnirCount: fromRunnirCount, query: query)`.

2. `StatusFilterMenu`: replace its stored properties and `body`, and replace `row(_:)` with these three functions:

```swift
struct StatusFilterMenu: View {
    @Binding var filter: RunFilter
    let counts: [RunStatusFilter: Int]
    let fromRunnirCount: Int
    let query: String

    private var typed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel(title: "STATUS")
                Spacer(minLength: 8)
                if !typed.isEmpty {
                    Text("matching \u{201C}\(typed)\u{201D}").font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground).lineLimit(1)
                }
            }.padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
            ForEach(RunStatusFilter.allCases) { status in row(status) }
            DesignDivider().padding(.vertical, 4)
            option(label: "From Runnir", on: filter.fromRunnir, count: fromRunnirCount) {
                RunnirMark(size: 12)
            } toggle: { filter.fromRunnir.toggle() }
            .help("Runs started from Runnir on this Mac; GitHub keeps no mark of them")
            DesignDivider().padding(.vertical, 4)
            HStack {
                Text("\(filter.count) selected").font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground)
                Spacer()
                Button("Clear all") { filter = RunFilter() }.buttonStyle(.link).pointerStyle(.link).font(.system(size: 11)).disabled(filter.isEmpty)
            }.padding(.horizontal, 8).padding(.bottom, 6)
        }
        .padding(6).frame(width: 240)
    }

    private func row(_ status: RunStatusFilter) -> some View {
        option(label: status.label, on: filter.statuses.contains(status), count: counts[status] ?? 0) {
            Image(systemName: status.symbol).font(.system(size: 12)).foregroundStyle(status.tint)
        } toggle: {
            if filter.statuses.contains(status) { filter.statuses.remove(status) } else { filter.statuses.insert(status) }
        }
    }

    private func option<Icon: View>(label: String, on: Bool, count: Int, @ViewBuilder icon: () -> Icon,
                                    toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: on ? "checkmark.square.fill" : "square").font(.system(size: 14))
                    .foregroundStyle(on ? RunnirTheme.primary : RunnirTheme.mutedForeground)
                icon().frame(width: 16)
                Text(label).font(.system(size: 12))
                Spacer(minLength: 8)
                Text("\(count)").font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground)
            }
            .padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
            .background(on ? RunnirTheme.selected : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            // An item nothing matches stays selectable, and a ticked one keeps its chip.
            .opacity(count == 0 && !on ? 0.5 : 1)
        }
        .buttonStyle(.hit)
        .accessibilityLabel("\(label), \(count) \(count == 1 ? "run" : "runs")")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
```

3. `StatusChips`:

```swift
/// The chosen statuses and From Runnir under the search field: each can be
/// removed on its own, and Clear all removes them all (the typed query stays).
struct StatusChips: View {
    @Binding var filter: RunFilter

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(RunStatusFilter.allCases.filter(filter.statuses.contains)) { status in
                        chip(status.label) {
                            Image(systemName: status.symbol).font(.system(size: 10)).foregroundStyle(status.tint)
                        } remove: { filter.statuses.remove(status) }
                    }
                    if filter.fromRunnir {
                        chip("From Runnir") { RunnirMark(size: 10) } remove: { filter.fromRunnir = false }
                    }
                }
            }
            Button("Clear all") { filter = RunFilter() }.buttonStyle(.link).pointerStyle(.link).font(.system(size: 11)).fixedSize()
        }
    }

    private func chip<Icon: View>(_ label: String, @ViewBuilder icon: () -> Icon, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            icon()
            Text(label).font(.system(size: 11))
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.hit).foregroundStyle(RunnirTheme.secondaryForeground)
                .help("Remove the \(label) filter").accessibilityLabel("Remove the \(label) filter")
        }
        .padding(.leading, 8).padding(.trailing, 6).padding(.vertical, 3)
        .background(RunnirTheme.selected, in: Capsule()).overlay(Capsule().stroke(RunnirTheme.border))
        .fixedSize()
    }
}
```

- [ ] **Step 5: The list and the changes take the filter**

In `RunSearch.swift`, replace `list` and the filtering `changes` overload:

```swift
    /// The runs the list shows: those on `branch` (all for nil), among the ids
    /// the Core found for the query (all for nil) and passing `filter`.
    /// Without a query or a filter, completed superseded runs stay hidden
    /// unless asked for; a search shows every match, because hiding one would
    /// make a run that exists look missing.
    static func list(_ runs: [CoreWorkflowRun], branch: String?, matching ids: Set<Int64>? = nil, filter: RunFilter = RunFilter(),
                     showingSuperseded: Bool) -> [CoreWorkflowRun] {
        let onBranch = branch.map { branch in runs.filter { $0.branch == branch } } ?? runs
        guard ids != nil || !filter.isEmpty else { return visible(onBranch, showingSuperseded: showingSuperseded) }
        return filter.apply(onBranch.filter { ids?.contains($0.id) ?? true })
    }
```

```swift
    /// The changes with a run on `branch` (all for nil) that have a run among
    /// the ids found and a run passing `filter`.
    static func changes(_ changes: [CoreRunChange], runs: [Int64: CoreWorkflowRun], branch: String?, matching ids: Set<Int64>? = nil,
                        filter: RunFilter = RunFilter()) -> [CoreRunChange] {
        let onBranch = Self.changes(changes, runs: runs, branch: branch)
        guard ids != nil || !filter.isEmpty else { return onBranch }
        return onBranch.filter { change in
            let members = (change.sections.flatMap { $0.runIDs + $0.repeatRunIDs } + change.olderRunIDs)
            let found = ids.map { ids in members.contains { ids.contains($0) } } ?? true
            let passes = filter.isEmpty || members.compactMap { runs[$0] }.contains(where: filter.matches)
            return found && passes
        }
    }
```

- [ ] **Step 6: The runs list keeps a `RunFilter`**

In `GitHubActivityViews.swift` (the runs list view):
- `@State private var statuses: Set<RunStatusFilter> = []` → `@State private var filter = RunFilter()`.
- `narrowing`: `searching || !filter.isEmpty`. Update the comment: "A search or a filter narrows the list to the saved runs, all of them."
- After `statusCounts`, add:

```swift
    /// Runs Runnir started that match the typed query and the branch filter.
    private var fromRunnirCount: Int {
        RunFilter.fromRunnirCount(RunPresentation.matching(session.runs, branch: branch, ids: matchingIDs))
    }
```

- `beyondSaved`: the last line becomes `return filter.apply(onBranch)`, and its comment says "narrowed by the branch and the filter".
- `header`:

```swift
                StatusFilterButton(filter: $filter, counts: statusCounts, fromRunnirCount: fromRunnirCount, query: query)
            }
            if !filter.isEmpty { StatusChips(filter: $filter) }
```

- `searchNote`:

```swift
                if searching {
                    Text("No \(noun) match \u{201C}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}\(filter.isEmpty ? "" : " and the chosen filters").")
                } else {
                    Text("No \(noun) match the chosen filters.")
                }
```

  and `if !filter.isEmpty { Button("Clear filters") { filter = RunFilter() }.buttonStyle(.link).pointerStyle(.link) }`.
- `listRows`: `RunPresentation.list(session.runs, branch: branch, matching: matchingIDs, filter: filter, showingSuperseded: showingSuperseded)`.
- `changeBlocks`: `RunPresentation.changes(session.changes, runs: runsByID, branch: branch, matching: matchingIDs, filter: filter)`.

Run `grep -n "statuses" apps/macos/Runnir/Features/Desktop/GitHubActivityViews.swift`. Expected: no output.

- [ ] **Step 7: Run the tests**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/RunStatusFilterTests -only-testing:RunnirTests/RunSearchTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add apps/macos/Runnir/Features/Desktop/RunStatusFilter.swift apps/macos/Runnir/Features/Desktop/RunSearch.swift \
  apps/macos/Runnir/Features/Desktop/GitHubActivityViews.swift apps/macos/RunnirTests/RunStatusFilterTests.swift \
  apps/macos/RunnirTests/RunSearchTests.swift
git commit -m "App: From Runnir in the status filter menu, with its count and chip (B46)"
```

---

### Task 7: Docs And The Whole Check

**Files:**
- Modify: `docs/superpowers/specs/2026-10-28-runs-started-from-runnir-design.md` (Status line)
- Modify: `docs/product/mvp-implementation-checklist.md` (Progress table)
- Modify: `docs/architecture/grpc-api.md`
- Modify: `docs/design/screens-and-states.md`

- [ ] **Step 1: The spec says it is built**

Replace the Status line with:

```markdown
Status: built (the Core's record of the attempts Runnir started, `WorkflowRun.runnir_starts`, the words in the row and beside the attempt, From Runnir in the status filter), drawn in `runnir.pen` (journey D, Row — Runs started from Runnir (B46)). Option C was chosen: words at the start of the row's detail line and beside the attempt. A tag after the title (A) and the Runnir mark before it (B) were not chosen. Builds on the dispatch history (B34), the run actions (B13), the status filter (B42) and the search beyond the cache (B40). Not tried against GitHub.
```

- [ ] **Step 2: The checklist's Progress table**

In `docs/product/mvp-implementation-checklist.md`, after the `| B40 |` row of the Progress table (the one under `## Progress`), add:

```markdown
| B46 | Runs started from Runnir are marked ([spec](../superpowers/specs/2026-10-28-runs-started-from-runnir-design.md)): the Core keeps the attempts Runnir started in the workspace database (a dispatch once its run is known, each re-run GitHub accepted by attempt; the newest 5000, backed up with the local data, kept by Clear Cache and Clear history) and the runs of the activity, `SearchRuns` and `SearchRunsOnGitHub` carry them in `runnir_starts`; a row reads "From Runnir · " before its detail line, the inspector names the attempt beside it with help that only this Mac knows, and the status filter menu has a From Runnir item with its count and chip; covered by Core and app tests | A real dispatch and re-run against GitHub |
```

- [ ] **Step 3: `grpc-api.md`**

1. In the row for `ListGitHubWorkflows`, `ListWorkflowRuns(branch, limit ≤ 100)`, `ListRunJobs(run_id)`, after the sentence ending "the Core owns that mapping.", add:

   > Runs of a workspace's activity, of `SearchRuns` and of `SearchRunsOnGitHub` also carry `runnir_starts`: the attempts Runnir started on this Mac, oldest first, up to `run_attempt`, each with its `kind` (dispatch, re-run, re-run failed jobs, re-run one job) and `sent_at`. Only this Mac knows them. Other calls leave it empty.

2. In the `ListDispatchHistory` row, after "the first answer is kept and an unknown entry is not an error", add:

   > A dispatch whose run is known, named by GitHub or linked, is also kept as attempt 1 Runnir started (B46). Clear history does not remove that.

3. In the `PrepareRunAction` → `ConfirmRunAction` row, after "so `accepted_at` means accepted, not done.", add:

   > A re-run GitHub accepted for a repository with a workspace is kept as the attempt after the one Prepare read (B46).

- [ ] **Step 4: `screens-and-states.md`**

Replace both `(designed, B46)` with `(built, B46)`.

- [ ] **Step 5: The whole check**

Run from `core/`: `go test ./... -count=1 && go vet ./... && go build ./...`
Expected: every package `ok`, no vet output.

Run from the repository root, with the plugin PATH: `scripts/generate-contracts.sh && git status --short contracts core/internal/gen apps/macos/Runnir/IPC/Generated`
Expected: no changes listed.

Run with the Go PATH: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`.

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests`
Expected: `** TEST SUCCEEDED **`, with the number of tests in the summary.

- [ ] **Step 6: Commit**

```bash
git add docs
git commit -m "Docs: B46 built, the run message's starts and where they are kept"
```
