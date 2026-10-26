//go:build !windows

package store

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func recordDispatch(t *testing.T, s *Store, path, ref string, inputs map[string]string, at time.Time) int64 {
	t.Helper()
	id, err := s.RecordDispatch(context.Background(), DispatchRecord{WorkflowPath: path, Ref: ref, Inputs: inputs, SentAt: at})
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func TestDispatchesAreListedNewestFirstPerWorkflowWithTheirValues(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	at := fixedNow()
	deploy := ".github/workflows/deploy.yml"
	first := recordDispatch(t, s, deploy, "main", map[string]string{"environment": "staging", "dry_run": "true"}, at)
	recordDispatch(t, s, ".github/workflows/release.yml", "v1.2.0", nil, at.Add(time.Minute))
	third, err := s.RecordDispatch(ctx, DispatchRecord{WorkflowPath: deploy, Ref: "release/1.4", SentAt: at.Add(2 * time.Minute),
		Inputs: map[string]string{"environment": "production"}, Omitted: []string{"deploy_token"}})
	if err != nil {
		t.Fatal(err)
	}

	all, err := s.DispatchHistory(ctx, "", 10)
	if err != nil || len(all) != 3 || all[0].ID != third || all[2].ID != first {
		t.Fatalf("all = %+v, %v", all, err)
	}
	perWorkflow, _ := s.DispatchHistory(ctx, deploy, 10)
	if len(perWorkflow) != 2 || perWorkflow[0].Ref != "release/1.4" || perWorkflow[1].Ref != "main" {
		t.Fatalf("per workflow = %+v", perWorkflow)
	}
	if got := perWorkflow[1].Inputs; !reflect.DeepEqual(got, map[string]string{"environment": "staging", "dry_run": "true"}) {
		t.Fatalf("inputs = %v", got)
	}
	if !reflect.DeepEqual(perWorkflow[0].Omitted, []string{"deploy_token"}) || !perWorkflow[0].SentAt.Equal(at.Add(2*time.Minute)) {
		t.Fatalf("omitted or time = %+v", perWorkflow[0])
	}
	if limited, _ := s.DispatchHistory(ctx, "", 1); len(limited) != 1 || limited[0].ID != third {
		t.Fatalf("limited = %+v", limited)
	}
	// A dispatch without inputs reads back with none, not a nil that breaks callers.
	none, _ := s.DispatchHistory(ctx, ".github/workflows/release.yml", 10)
	if len(none) != 1 || len(none[0].Inputs) != 0 || len(none[0].Omitted) != 0 {
		t.Fatalf("no inputs = %+v", none)
	}
}

func TestADispatchIsLinkedToItsRunOnce(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	id := recordDispatch(t, s, ".github/workflows/deploy.yml", "main", nil, fixedNow())
	if err := s.LinkDispatchRun(ctx, id, 4242); err != nil {
		t.Fatal(err)
	}
	// A later guess must not replace the run that was found.
	if err := s.LinkDispatchRun(ctx, id, 9999); err != nil {
		t.Fatal(err)
	}
	got, _ := s.DispatchHistory(ctx, "", 10)
	if len(got) != 1 || got[0].RunID != 4242 {
		t.Fatalf("run = %+v", got)
	}
	if err := s.LinkDispatchRun(ctx, 777, 1); err != nil {
		t.Fatalf("an unknown entry is not an error: %v", err)
	}
	if err := s.LinkDispatchRun(ctx, id, 0); err == nil {
		t.Fatal("run 0 is not a run")
	}
}

func TestOnlyTheNewestDispatchesAreKept(t *testing.T) {
	s := openTest(t, t.TempDir())
	at := fixedNow()
	for i := 0; i < maxDispatchRecords+5; i++ {
		recordDispatch(t, s, ".github/workflows/deploy.yml", fmt.Sprintf("ref-%03d", i), nil, at.Add(time.Duration(i)*time.Second))
	}
	got, _ := s.DispatchHistory(context.Background(), "", 1000)
	if len(got) != maxDispatchRecords || got[0].Ref != fmt.Sprintf("ref-%03d", maxDispatchRecords+4) || got[len(got)-1].Ref != "ref-005" {
		t.Fatalf("kept %d, newest %q, oldest %q", len(got), got[0].Ref, got[len(got)-1].Ref)
	}
}

func TestClearCacheKeepsTheDispatchHistory(t *testing.T) {
	s := openTest(t, t.TempDir())
	recordDispatch(t, s, ".github/workflows/deploy.yml", "main", map[string]string{"a": "1"}, fixedNow())
	if err := s.ClearCache(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.DispatchHistory(context.Background(), "", 10); len(got) != 1 {
		t.Fatalf("history = %+v", got)
	}
}

func TestTheDispatchHistoryIsRestoredWithTheDatabase(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	id := recordDispatch(t, s, ".github/workflows/deploy.yml", "main", map[string]string{"environment": "staging"}, fixedNow())
	if err := s.LinkDispatchRun(context.Background(), id, 4242); err != nil {
		t.Fatal(err)
	}
	_ = s.Close()
	for _, name := range []string{"state.sqlite", "state.sqlite-wal", "state.sqlite-shm"} {
		_ = os.Remove(filepath.Join(dir, name))
	}
	again := openTest(t, dir)
	got, _ := again.DispatchHistory(context.Background(), "", 10)
	if len(got) != 1 || got[0].Ref != "main" || got[0].RunID != 4242 || got[0].Inputs["environment"] != "staging" {
		t.Fatalf("history = %+v", got)
	}
}

func TestSalvagedDispatchesAreMergedWithTheBackup(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	recordDispatch(t, s, ".github/workflows/deploy.yml", "main", nil, fixedNow())
	// The damaged file had a newer entry the backup lacks.
	if _, err := s.restoreLocal(ctx, localData{dispatches: []DispatchRecord{
		{ID: 50, WorkflowPath: ".github/workflows/deploy.yml", Ref: "newer", Inputs: map[string]string{"x": "1"}, SentAt: fixedNow().Add(time.Hour)},
	}}); err != nil {
		t.Fatal(err)
	}
	got, _ := s.DispatchHistory(ctx, "", 10)
	if len(got) < 2 || got[0].Ref != "newer" {
		t.Fatalf("history = %+v", got)
	}
}
