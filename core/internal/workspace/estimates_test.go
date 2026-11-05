package workspace

import (
	"testing"
	"time"

	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

func ghRun(id, workflow int64, conclusion string, created time.Time, minutes int) github.Run {
	return github.Run{ID: id, WorkflowID: workflow, Status: "completed", Conclusion: conclusion,
		CreatedAt: created, UpdatedAt: created.Add(time.Duration(minutes) * time.Minute)}
}

func TestCancelEstimatesUseTheMedianSuccessfulRun(t *testing.T) {
	base := time.Date(2026, 10, 25, 10, 0, 0, 0, time.UTC)
	runs := []github.Run{
		{ID: 9, WorkflowID: 3, Status: "in_progress", CreatedAt: base.Add(3 * time.Hour)},
		ghRun(6, 3, "success", base.Add(2*time.Hour), 10),
		ghRun(5, 3, "failure", base.Add(time.Hour), 2),
		ghRun(4, 3, "success", base, 6),
		ghRun(3, 3, "success", base.Add(-time.Hour), 8),
		ghRun(2, 4, "success", base, 60),
	}
	if median, ok := medianDuration(runs, 3); !ok || median != 8*time.Minute {
		t.Fatalf("median = %v, %v", median, ok)
	}
	if _, ok := medianDuration(runs, 99); ok {
		t.Fatal("a median for a workflow without runs")
	}
	if estimateMinutes(8*time.Minute, 2*time.Minute+time.Second) != 6 || estimateMinutes(8*time.Minute, 9*time.Minute) != 0 {
		t.Fatal("estimates do not round up or go below zero")
	}
	superseded := map[int64]int64{9: 10}
	if ok, minutes := cancelEstimate(runs, superseded, 9, base.Add(3*time.Hour+3*time.Minute)); !ok || minutes != 5 {
		t.Fatalf("superseded cancel = %v, %d", ok, minutes)
	}
	if ok, _ := cancelEstimate(runs, superseded, 6, base); ok {
		t.Fatal("a run that is not superseded counted")
	}
}

func TestConcurrencyCancelsCountRunsAfterTheSaveOnly(t *testing.T) {
	saved := time.Date(2026, 10, 25, 10, 0, 0, 0, time.UTC)
	cancelled := func(id int64, created time.Time, minutes int) github.Run {
		return ghRun(id, 3, "cancelled", created, minutes)
	}
	runs := []github.Run{
		cancelled(20, saved.Add(time.Hour), 3),   // after the save, superseded: counted, 10-3 = 7
		cancelled(21, saved.Add(2*time.Hour), 1), // after the save, not superseded: not counted
		cancelled(19, saved.Add(-time.Hour), 1),  // before the save: not counted
		ghRun(18, 3, "success", saved.Add(-2*time.Hour), 10),
		{ID: 30, WorkflowID: 4, Status: "completed", Conclusion: "cancelled", CreatedAt: saved.Add(time.Hour)}, // another workflow
	}
	workflows := []github.Workflow{{ID: 3, Path: ".github/workflows/ci.yml"}, {ID: 4, Path: ".github/workflows/other.yml"}}
	saves := []store.ConcurrencySave{{WorkflowPath: ".github/workflows/ci.yml", SavedAt: saved}}
	superseded := map[int64]int64{20: 22, 19: 20, 30: 31}
	got := concurrencyCancels(saves, runs, workflows, superseded)
	if len(got) != 1 || got[0].RunID != 20 || got[0].Minutes != 7 {
		t.Fatalf("cancels = %+v", got)
	}
}
