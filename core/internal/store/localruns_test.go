//go:build !windows

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
	if err := s.RecordLocalRun(ctx, LocalRun{ExecutionID: "exec_1", Scenario: "Pull request → main",
		Workflows: []string{".github/workflows/ci.yml", ".github/workflows/core.yml"}, StartedAt: at, State: LocalQueued, ActVersion: "0.2.89", Engine: "OrbStack"}); err != nil {
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
	if got.State != LocalSucceeded || got.Scenario != "Pull request → main" || len(got.Workflows) != 2 ||
		got.Workflows[1] != ".github/workflows/core.yml" || got.Engine != "OrbStack" ||
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
