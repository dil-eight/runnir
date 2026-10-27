# Local Run Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user change a local run's CPUs, memory and timeout for a workspace from the Run Locally review, with the Core capping them at the engine and warning about overload.

**Architecture:** The Core owns the rules (`localrun/limits.go`: ceilings, steps, warnings) and the workspace's saved limits (a one-row local table). `PrepareLocalRun` takes asked limits or a reset; the plan carries the chosen limits, the ceilings, whether they are the workspace's own, an info note and warnings; confirming a run saves (or forgets) the workspace's limits. The app shows the Limits row with Change… and a panel of steppers that prepares the run again.

**Tech Stack:** Go (Core, modernc SQLite, gRPC), protobuf (`scripts/generate-contracts.sh`), Swift 6 / SwiftUI (app).

## Global Constraints

- Spec: `docs/superpowers/specs/2026-10-27-local-run-limits-design.md`.
- Defaults stay 4 CPUs, 8 GB, 30 min, capped at the engine.
- Bounds: CPUs 1…engine CPUs; memory 1 GB…engine memory in steps of 512 MiB; timeout 5 min…6 h in steps of 5 min.
- Warnings never block a run.
- No backward compatibility before the first release (AGENTS.md): the schema is edited in place, no migration.
- No AI attribution in commits (AGENTS.md).
- Checks: `go test ./... && go vet ./... && go build ./...` in `core/`; `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests` and `build`.

---

### Task 1: Limit rules in `localrun`

**Files:**
- Create: `core/internal/localrun/limits.go`
- Modify: `core/internal/localrun/plan.go` (drop `LimitsFor`, add plan fields, `NewPlan` takes the chosen limits)
- Test: `core/internal/localrun/limits_test.go`

**Interfaces:**
- Produces:
  - `type Ceiling struct { CPUs int; MemoryBytes uint64; Timeout time.Duration }` (zero CPUs/memory: the engine did not say)
  - `func CeilingFor(engine tools.Engine) Ceiling`
  - `func Choose(asked *Limits, ceiling Ceiling) Limits` (nil asked: the defaults)
  - `func Warnings(limits Limits, ceiling Ceiling, asked bool) []string`
  - `func Note(ceiling Ceiling, engineName string, asked bool) string`
  - `Plan` gets `Ceiling Ceiling`, `OwnLimits bool`, `LimitWarnings []string`, `LimitNote string`
  - `NewPlan(request, report, useInstalledAct, imagePresent, limits Limits)` keeps its other behaviour; the caller computes limits.

- [ ] **Step 1: Write the failing tests** (`limits_test.go`)

```go
package localrun

import (
	"strings"
	"testing"
	"time"

	"runnir/core/internal/tools"
)

const gib = 1 << 30

func TestChooseKeepsWithinTheEngineAndTheSteps(t *testing.T) {
	ceiling := CeilingFor(tools.Engine{CPUs: 8, MemoryBytes: 6 * gib})
	if ceiling.Timeout != MaxTimeout {
		t.Fatalf("ceiling = %+v", ceiling)
	}
	if got := Choose(nil, ceiling); got != (Limits{CPUs: 4, MemoryBytes: 6 * gib, Timeout: 30 * time.Minute}) {
		t.Fatalf("defaults = %+v", got)
	}
	asked := &Limits{CPUs: 12, MemoryBytes: 1<<30 + 100, Timeout: 7 * time.Hour}
	if got := Choose(asked, ceiling); got != (Limits{CPUs: 8, MemoryBytes: gib, Timeout: MaxTimeout}) {
		t.Fatalf("capped and stepped = %+v", got)
	}
	if got := Choose(&Limits{CPUs: 0, MemoryBytes: 0, Timeout: time.Minute}, ceiling); got != (Limits{CPUs: 1, MemoryBytes: MinMemoryBytes, Timeout: MinTimeout}) {
		t.Fatalf("floors = %+v", got)
	}
	if got := Choose(&Limits{CPUs: 6, MemoryBytes: 3*gib + 700<<20, Timeout: 42 * time.Minute}, ceiling); got != (Limits{CPUs: 6, MemoryBytes: 3*gib + 512<<20, Timeout: 40 * time.Minute}) {
		t.Fatalf("rounded down to a step = %+v", got)
	}
	unknown := CeilingFor(tools.Engine{})
	if got := Choose(&Limits{CPUs: 16, MemoryBytes: 32 * gib, Timeout: time.Hour}, unknown); got.CPUs != 16 || got.MemoryBytes != 32*gib {
		t.Fatalf("an engine that did not say caps nothing: %+v", got)
	}
}

func TestWarningsAndTheNote(t *testing.T) {
	ceiling := CeilingFor(tools.Engine{CPUs: 8, MemoryBytes: 6 * gib})
	all := Warnings(Limits{CPUs: 8, MemoryBytes: 6 * gib, Timeout: time.Hour}, ceiling, true)
	if len(all) != 2 || !strings.Contains(all[0], "Every CPU") || !strings.Contains(all[1], "exit 137") {
		t.Fatalf("overload = %q", all)
	}
	if low := Warnings(Limits{CPUs: 2, MemoryBytes: 1536 << 20, Timeout: time.Hour}, ceiling, true); len(low) != 1 || !strings.Contains(low[0], "Under 2 GB") {
		t.Fatalf("low memory = %q", low)
	}
	// Defaults capped at a small engine get the note, not a warning about memory.
	if w := Warnings(Choose(nil, ceiling), ceiling, false); len(w) != 0 {
		t.Fatalf("defaults warned: %q", w)
	}
	if note := Note(ceiling, "OrbStack", false); !strings.Contains(note, "OrbStack has 6 GB") {
		t.Fatalf("note = %q", note)
	}
	if note := Note(CeilingFor(tools.Engine{}), "OrbStack", false); !strings.Contains(note, "does not answer") {
		t.Fatalf("unknown engine note = %q", note)
	}
	if note := Note(CeilingFor(tools.Engine{CPUs: 8, MemoryBytes: 16 * gib}), "OrbStack", false); note != "" {
		t.Fatalf("a big engine needs no note: %q", note)
	}
}
```

- [ ] **Step 2: Run to see them fail:** `go test ./internal/localrun -run 'Choose|Warnings' -count=1` → undefined: CeilingFor.

- [ ] **Step 3: Implement `limits.go`**

```go
package localrun

import (
	"fmt"
	"time"

	"runnir/core/internal/tools"
)

// Bounds and steps of a run's limits.
const (
	MinMemoryBytes = 1 << 30
	MemoryStep     = 512 << 20
	MinTimeout     = 5 * time.Minute
	MaxTimeout     = 6 * time.Hour
	TimeoutStep    = 5 * time.Minute
	lowMemory      = 2 << 30
)

// Ceiling is the most a run can get here: the engine's CPUs and memory (zero
// when the engine did not say) and 6 hours, GitHub's limit for one job.
type Ceiling struct {
	CPUs        int
	MemoryBytes uint64
	Timeout     time.Duration
}

func CeilingFor(engine tools.Engine) Ceiling {
	return Ceiling{CPUs: max(engine.CPUs, 0), MemoryBytes: engine.MemoryBytes, Timeout: MaxTimeout}
}

// Choose turns what was asked (nil: the defaults) into a run's limits: whole
// CPUs from 1, memory in steps of 512 MiB from 1 GB, a timeout in steps of 5
// minutes from 5 minutes, none above the ceiling.
func Choose(asked *Limits, ceiling Ceiling) Limits {
	l := Limits{CPUs: DefaultCPUs, MemoryBytes: DefaultMemoryBytes, Timeout: DefaultTimeout}
	if asked != nil {
		l = *asked
	}
	l.CPUs = max(l.CPUs, 1)
	if ceiling.CPUs > 0 {
		l.CPUs = min(l.CPUs, ceiling.CPUs)
	}
	if asked != nil {
		l.MemoryBytes = max(l.MemoryBytes/MemoryStep*MemoryStep, MinMemoryBytes)
	}
	if ceiling.MemoryBytes > 0 && l.MemoryBytes > ceiling.MemoryBytes {
		l.MemoryBytes = ceiling.MemoryBytes
	}
	l.Timeout = min(max(l.Timeout/TimeoutStep*TimeoutStep, MinTimeout), ceiling.Timeout)
	return l
}

// Warnings says what limits the person asked for risk on this engine. The
// defaults capped at a small engine get Note instead.
func Warnings(l Limits, ceiling Ceiling, asked bool) []string {
	var out []string
	if ceiling.CPUs > 1 && l.CPUs >= ceiling.CPUs {
		out = append(out, fmt.Sprintf("Every CPU of the engine (%d): the Mac and other containers slow down while the run goes on.", ceiling.CPUs))
	}
	if asked && ceiling.MemoryBytes > 0 && l.MemoryBytes*10 >= ceiling.MemoryBytes*9 {
		out = append(out, fmt.Sprintf("%s of %s memory: the engine and other containers may run out of memory, and a job can be killed (exit 137).",
			gigabytes(l.MemoryBytes), gigabytes(ceiling.MemoryBytes)))
	}
	if l.MemoryBytes < lowMemory {
		out = append(out, "Under 2 GB of memory many builds do not fit and stop with exit 137.")
	}
	return out
}

// Note is the line under the limits worth reading without opening them: an
// engine that did not say what it has, or one smaller than a default.
func Note(ceiling Ceiling, engineName string, asked bool) string {
	if engineName == "" {
		engineName = "The engine"
	}
	switch {
	case ceiling.CPUs == 0 && ceiling.MemoryBytes == 0:
		return "The container engine does not answer, so its CPUs and memory are unknown: the limits can be changed once it does."
	case !asked && ceiling.MemoryBytes > 0 && ceiling.MemoryBytes < DefaultMemoryBytes:
		return fmt.Sprintf("%s has %s, so memory is capped there. Give the engine more in its settings to raise it.", engineName, gigabytes(ceiling.MemoryBytes))
	}
	return ""
}

// gigabytes words bytes as "5.85 GB", as the app shows memory.
func gigabytes(b uint64) string {
	return fmt.Sprintf("%.3g GB", float64(b)/(1<<30))
}
```

In `plan.go`: delete `LimitsFor`; add to `Plan`:

```go
	Limits Limits
	// Ceiling is the most the engine allows; OwnLimits: the limits are the
	// workspace's, not the defaults.
	Ceiling       Ceiling
	OwnLimits     bool
	LimitWarnings []string
	LimitNote     string
```

and change `NewPlan` to take the limits the caller chose:

```go
func NewPlan(request Request, report tools.Report, useInstalledAct bool, imagePresent func(string) bool, limits Limits) (Plan, error) {
	...
	plan := Plan{WorkflowID: request.WorkflowID, JobID: request.JobID, Digest: hex.EncodeToString(digest[:]), Limits: limits}
```

Update every `NewPlan` and `LimitsFor` caller (`grep -rn "NewPlan(\|LimitsFor(" core/internal`): tests pass `Choose(nil, CeilingFor(report.Engine))`.

- [ ] **Step 4: Run:** `go test ./internal/localrun -count=1` → PASS. `gofmt -l .` empty.

- [ ] **Step 5: Commit:** `git commit -m "Core: limit rules of a local run: ceilings, steps, warnings"`.

### Task 2: The workspace's saved limits

**Files:**
- Modify: `core/internal/store/schema.go` (table), create `core/internal/store/runlimits.go`, test `core/internal/store/runlimits_test.go`
- Modify: `core/internal/workspace/runtimes.go` (two methods)

**Interfaces:**
- Produces:
  - `type RunLimits struct { CPUs int; MemoryBytes uint64; Timeout time.Duration }` in `store`
  - `func (s *Store) RunLimits(ctx) (RunLimits, bool, error)`
  - `func (s *Store) SetRunLimits(ctx, l *RunLimits) error` (nil forgets)
  - `func (m *Runtimes) LocalRunLimits(ctx, repositoryID string) (store.RunLimits, bool)`
  - `func (m *Runtimes) SetLocalRunLimits(ctx, repositoryID string, l *store.RunLimits) error`

- [ ] **Step 1: Test** (`runlimits_test.go`): open a memory store, `RunLimits` is absent; set `{6, 4 GiB, 1 h}`, read it back; `ClearCache` keeps it; `SetRunLimits(nil)` forgets it.

```go
func TestRunLimitsAreKeptUntilForgotten(t *testing.T) {
	s, _ := Open("", Options{})
	defer s.Close()
	ctx := context.Background()
	if _, ok, err := s.RunLimits(ctx); ok || err != nil {
		t.Fatalf("a new store has none: %v %v", ok, err)
	}
	want := RunLimits{CPUs: 6, MemoryBytes: 4 << 30, Timeout: time.Hour}
	if err := s.SetRunLimits(ctx, &want); err != nil {
		t.Fatal(err)
	}
	if err := s.ClearCache(ctx); err != nil {
		t.Fatal(err)
	}
	if got, ok, _ := s.RunLimits(ctx); !ok || got != want {
		t.Fatalf("after Clear Cache = %+v %v", got, ok)
	}
	if err := s.SetRunLimits(ctx, nil); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := s.RunLimits(ctx); ok {
		t.Fatal("forgotten limits came back")
	}
}
```

- [ ] **Step 2: Run:** `go test ./internal/store -run RunLimits` → fails (undefined).

- [ ] **Step 3: Implement.** Schema, after `savings`:

```sql
-- local: the limits the person chose for this workspace's local runs, one
-- row; none means the defaults. Clear Cache keeps it; it is a preference, so
-- it is not in the backup of local data.
CREATE TABLE local_run_limits (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	cpus INTEGER NOT NULL,
	memory_bytes INTEGER NOT NULL,
	timeout_seconds INTEGER NOT NULL
);
```

`runlimits.go`:

```go
package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

type RunLimits struct {
	CPUs        int
	MemoryBytes uint64
	Timeout     time.Duration
}

func (s *Store) RunLimits(ctx context.Context) (RunLimits, bool, error) {
	var l RunLimits
	var memory, seconds int64
	err := s.db.QueryRowContext(ctx, "SELECT cpus, memory_bytes, timeout_seconds FROM local_run_limits WHERE id = 1").Scan(&l.CPUs, &memory, &seconds)
	if errors.Is(err, sql.ErrNoRows) {
		return RunLimits{}, false, nil
	}
	if err != nil {
		return RunLimits{}, false, err
	}
	l.MemoryBytes, l.Timeout = uint64(memory), time.Duration(seconds)*time.Second
	return l, true, nil
}

// SetRunLimits keeps the workspace's limits; nil forgets them.
func (s *Store) SetRunLimits(ctx context.Context, l *RunLimits) error {
	if l == nil {
		_, err := s.db.ExecContext(ctx, "DELETE FROM local_run_limits")
		return err
	}
	_, err := s.db.ExecContext(ctx, `INSERT INTO local_run_limits (id, cpus, memory_bytes, timeout_seconds) VALUES (1, ?, ?, ?)
ON CONFLICT (id) DO UPDATE SET cpus = excluded.cpus, memory_bytes = excluded.memory_bytes, timeout_seconds = excluded.timeout_seconds`,
		l.CPUs, int64(l.MemoryBytes), int64(l.Timeout/time.Second))
	return err
}
```

`runtimes.go`:

```go
// LocalRunLimits are the limits kept for the workspace of a repository.
func (m *Runtimes) LocalRunLimits(ctx context.Context, repositoryID string) (store.RunLimits, bool) {
	rt, ok := m.ForRepository(repositoryID)
	if !ok {
		return store.RunLimits{}, false
	}
	l, found, err := rt.cfg.store.RunLimits(ctx)
	return l, found && err == nil
}

// SetLocalRunLimits keeps (nil: forgets) the workspace's limits; a
// repository opened without a workspace keeps none.
func (m *Runtimes) SetLocalRunLimits(ctx context.Context, repositoryID string, l *store.RunLimits) error {
	rt, ok := m.ForRepository(repositoryID)
	if !ok {
		return nil
	}
	return rt.cfg.store.SetRunLimits(ctx, l)
}
```

- [ ] **Step 4: Run:** `go test ./internal/store ./internal/workspace -count=1` → PASS.
- [ ] **Step 5: Commit:** `git commit -m "Core: a workspace keeps the limits of its local runs"`.

### Task 3: Contract and server

**Files:**
- Modify: `contracts/grpc/runnir/core/v1/runnir_core.proto`, regenerate (`scripts/generate-contracts.sh` with the plugin PATH)
- Modify: `core/internal/server/localruns.go`
- Test: `core/internal/server/localruns_test.go`

**Interfaces:**
- Proto:

```proto
message LocalRunLimits {
  uint32 cpus = 1;
  uint64 memory_bytes = 2;
  uint32 timeout_seconds = 3;
}
// PrepareLocalRunRequest
  // Unset: the workspace's limits, else the defaults. Capped at the engine.
  LocalRunLimits limits = 6;
  // Plan with the defaults; confirming the run forgets the workspace's limits.
  bool reset_limits = 7;
// LocalRunPlan
  // The most the engine allows (0: it did not say) and 6 h.
  uint32 max_cpus = 20;
  uint64 max_memory_bytes = 21;
  uint32 max_timeout_seconds = 22;
  // The limits are the workspace's own, not the defaults.
  bool own_limits = 23;
  // What these limits risk; they never block the run.
  repeated string limit_warnings = 24;
  // A line worth reading without opening the limits (a small or silent engine).
  string limit_note = 25;
```

- Server, in `PrepareLocalRun` before `NewPlan`:

```go
	ceiling := localrun.CeilingFor(report.Engine)
	var asked *localrun.Limits
	own := false
	switch {
	case request.GetResetLimits():
	case request.GetLimits() != nil:
		l := request.GetLimits()
		asked = &localrun.Limits{CPUs: int(l.GetCpus()), MemoryBytes: l.GetMemoryBytes(), Timeout: time.Duration(l.GetTimeoutSeconds()) * time.Second}
		own = true
	default:
		if saved, ok := s.workspaces.LocalRunLimits(ctx, info.ID); ok {
			asked = &localrun.Limits{CPUs: saved.CPUs, MemoryBytes: saved.MemoryBytes, Timeout: saved.Timeout}
			own = true
		}
	}
	limits := localrun.Choose(asked, ceiling)
	plan, err := localrun.NewPlan(..., limits)
	...
	plan.Ceiling, plan.OwnLimits = ceiling, own
	plan.LimitWarnings = localrun.Warnings(limits, ceiling, own)
	plan.LimitNote = localrun.Note(ceiling, report.Engine.Name, own)
```

  `planMessage` maps the new fields. In `ConfirmLocalRun`, after the run is recorded:

```go
	// The limits of a confirmed run are the workspace's from now on; a run
	// with the defaults forgets them.
	var keep *store.RunLimits
	if p := approved.Spec.Plan; p.OwnLimits {
		keep = &store.RunLimits{CPUs: p.Limits.CPUs, MemoryBytes: p.Limits.MemoryBytes, Timeout: p.Limits.Timeout}
	}
	_ = s.workspaces.SetLocalRunLimits(context.Background(), info.ID, keep)
```

- [ ] **Step 1: Test** (`localruns_test.go`): `TestLocalRunLimitsAreAskedCappedAndKept` — a workspace rig (`startWith(t, path, Options{Runner: hold, Tools: fake, DataDir: t.TempDir()})`, `OpenRepository` with `WorkspaceId: testWorkspace`); engine 8 CPUs / 16 GiB.
  1. Prepare with `Limits{Cpus: 12, MemoryBytes: 15 GiB, TimeoutSeconds: 3600}` → plan cpus 8, memory 15 GiB, own, two warnings (every CPU, memory ≥ 90%), max_cpus 8.
  2. Confirm → prepare again without limits → the same limits, `own_limits`.
  3. Prepare with `reset_limits`, confirm → prepare again → cpus 4, not own.
- [ ] **Step 2–4:** fail, implement, `go test ./... && go vet ./...` pass.
- [ ] **Step 5: Commit:** `git commit -m "Core: PrepareLocalRun takes limits for the workspace, capped at the engine, with warnings"`.

### Task 4: App model and IPC

**Files:**
- Modify: `apps/macos/Runnir/IPC/CoreLocalRunModels.swift` (plan fields, `CoreLocalRunLimits`), `IPC/CoreService.swift`, `IPC/GRPCCoreService.swift`, `IPC/CoreHub.swift`, `Features/Desktop/LocalRun.swift`
- Test: `apps/macos/RunnirTests/` local run review tests (find the suite with `grep -rln "LocalRunReviewModel" apps/macos/RunnirTests`), the FakeCore in `CoreHubTests.swift`, the stub in `CoreProcessSupervisorTests.swift`

**Interfaces:**
- `struct CoreLocalRunLimits: Equatable, Sendable { var cpus: Int; var memoryBytes: UInt64; var timeoutSeconds: Int }`
- `CoreLocalRunPlan` gets `maxCPUs`, `maxMemoryBytes`, `maxTimeoutSeconds`, `ownLimits`, `limitWarnings`, `limitNote`, and `var limits: CoreLocalRunLimits`.
- `prepareLocalRun(repositoryID:workflowID:jobID:event:useInstalledAct:limits:resetLimits:)` on the service and the hub.
- `LocalRunReviewModel`: `private(set) var askedLimits: CoreLocalRunLimits?`, `private(set) var resettingLimits = false`, `func change(limits:) async`, `func resetLimits() async` — both clear `trusted` and prepare again.
- Pure helpers in `LocalRun.swift`: `enum LimitSteps { static func cpus(_:by:max:) -> Int; static func memory(_:by:max:) -> UInt64; static func timeout(_:by:) -> Int }` with the Core's steps (1, 512 MiB from 1 GiB, 300 s from 300 s to 21600 s).

- [ ] **Step 1: Tests**: changing limits unticks the confirmation and sends them; reset sends `resetLimits`; steps stop at the bounds.
- [ ] **Step 2–4:** fail, implement, `xcodebuild … test -only-testing:RunnirTests` pass.
- [ ] **Step 5: Commit:** `git commit -m "App: the review asks the Core for limits and prepares the run again"`.

### Task 5: The Limits row and panel

**Files:**
- Modify: `apps/macos/Runnir/Features/Desktop/LocalRunViews.swift` (Limits row: text, tag, Change…; note and warnings under it; `LocalRunLimitsPanel`)
- Docs: spec status, checklist B45 built, `docs/design/screens-and-states.md` S10

- [ ] **Step 1:** Limits row as drawn: text, "set for this workspace" when `ownLimits`, Change… (disabled when `maxCPUs == 0`), the note (info) and the warnings (warning colour) under the row.
- [ ] **Step 2:** `LocalRunLimitsPanel` opened over the row (own panel: surface, border, radius 12, shadow), steppers CPUs / Memory / Timeout with the ceilings "of 8 on OrbStack", "of 5.85 GB", "up to 6 h", − / + disabled at a bound, the warnings for the edited values (computed by the Core after Done; while editing, the values only), the footnote, Reset to defaults and Done. Escape or a click outside closes it without applying.
- [ ] **Step 3:** `xcodebuild … test -only-testing:RunnirTests` and `build` pass; PointerCoverage passes.
- [ ] **Step 4:** Docs updated; commit `git commit -m "App: Change… on the Limits row of the Run Locally review (B45)"`.
