//go:build !windows

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

func TestConcurrentOpensOfOneWorkspaceShareItsDatabase(t *testing.T) {
	_, accounts := newFake(t)
	m := newRuntimes(t, t.TempDir())
	resolve := fixedResolver(accounts, "o", "r")
	results := make(chan *Runtime, 8)
	for i := 0; i < 8; i++ {
		go func() {
			rt, err := m.Attach(wsA, "repo_1", resolve)
			if err != nil {
				t.Error(err)
			}
			results <- rt
		}()
	}
	first := <-results
	for i := 1; i < 8; i++ {
		if rt := <-results; rt != first {
			t.Fatal("two runtimes for one workspace")
		}
	}
	if r := first.Store().Report(); r.State != store.Persistent {
		t.Fatalf("store = %+v", r)
	}
}

func TestStorageReadsNeverPushAnOpenIntoMemory(t *testing.T) {
	_, accounts := newFake(t)
	data := t.TempDir()
	m := newRuntimes(t, data)
	closed, _ := store.Open(store.WorkspaceDir(data, "5ce88ff0-5c16-43b3-8f20-8e33e852b019"), store.Options{})
	_ = closed.Close()
	stop := make(chan struct{})
	reading := make(chan struct{})
	go func() {
		defer close(reading)
		for {
			select {
			case <-stop:
				return
			default:
				_, _ = m.Usage(context.Background(), []string{wsA})
			}
		}
	}()
	time.Sleep(20 * time.Millisecond)
	rt, err := m.Attach(wsA, "repo_1", fixedResolver(accounts, "o", "r"))
	close(stop)
	<-reading
	if err != nil || rt.Store().Report().State != store.Persistent {
		t.Fatalf("report = %+v, %v", rt.Store().Report(), err)
	}
}

func TestARelinkDuringALocalRunKeepsItsHistory(t *testing.T) {
	_, accounts := newFake(t)
	m := newRuntimes(t, t.TempDir())
	r, _ := m.Attach(wsA, "repo_1", fixedResolver(accounts, "o", "r"))
	m.RecordLocalRun("repo_1", store.LocalRun{ExecutionID: "exec_1", StartedAt: time.Now(), State: store.LocalQueued})
	// The folder is relinked while the run goes on.
	if _, err := m.Attach(wsA, "repo_9", fixedResolver(accounts, "o", "r")); err != nil {
		t.Fatal(err)
	}
	m.Detach("repo_1")
	m.ObserveExecution(events.Event{ExecutionID: "exec_1", ExecutionState: corev1.ExecutionState_EXECUTION_STATE_SUCCEEDED, At: time.Now()})
	m.recorder.flush()
	runs, _ := r.Store().LocalRuns(context.Background(), 10)
	if len(runs) != 1 || runs[0].State != store.LocalSucceeded {
		t.Fatalf("runs = %+v", runs)
	}
}

func TestDetachForgetsItsLocalRuns(t *testing.T) {
	_, accounts := newFake(t)
	m := newRuntimes(t, t.TempDir())
	_, _ = m.Attach(wsA, "repo_1", fixedResolver(accounts, "o", "r"))
	m.RecordLocalRun("repo_1", store.LocalRun{ExecutionID: "exec_1", StartedAt: time.Now(), State: store.LocalRunning})
	m.Detach("repo_1")
	m.mu.Lock()
	left := len(m.local)
	m.mu.Unlock()
	if left != 0 {
		t.Fatalf("%d local runs still tracked", left)
	}
}
