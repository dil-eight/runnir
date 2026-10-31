package watch

import (
	"slices"
	"testing"
	"time"

	"runnir/core/internal/github"
)

var base = time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)

func run(id, workflow int64, branch, status, conclusion string, created time.Time) github.Run {
	return github.Run{ID: id, WorkflowID: workflow, Branch: branch, Status: status, Conclusion: conclusion, Actor: "Ana",
		RunAttempt: 1, CreatedAt: created, UpdatedAt: created.Add(5 * time.Minute)}
}

func ids(runs []github.Run) []int64 {
	out := make([]int64, len(runs))
	for i, r := range runs {
		out[i] = r.ID
	}
	return out
}

func TestTheNewestFinishedRunOfAWorkflowOnABranchDecides(t *testing.T) {
	h := time.Hour
	runs := []github.Run{
		run(1, 10, "main", "completed", "failure", base.Add(-3*h)), // fixed by 2
		run(2, 10, "main", "completed", "success", base.Add(-2*h)),
		run(3, 10, "dev", "completed", "timed_out", base.Add(-2*h)), // another branch: listed
		run(4, 11, "main", "completed", "failure", base.Add(-4*h)),  // a later run was cancelled
		run(5, 11, "main", "completed", "cancelled", base.Add(-1*h)),
		run(6, 12, "main", "completed", "startup_failure", base.Add(-1*h)), // listed
		run(7, 13, "main", "completed", "failure", base.Add(-8*24*h)),      // 8 days ago
		run(8, 14, "main", "completed", "failure", base.Add(-5*h)),         // a later run was skipped
		run(9, 14, "main", "completed", "skipped", base.Add(-4*h)),
	}
	failed, running := Pick(runs, "ana", base)
	if got := ids(failed); !slices.Equal(got, []int64{6, 3}) {
		t.Fatalf("failed = %v", got)
	}
	if len(running) != 0 {
		t.Fatalf("running = %v", ids(running))
	}
}

func TestARerunThatPassedListsNothing(t *testing.T) {
	rerun := run(1, 10, "main", "completed", "success", base.Add(-time.Hour))
	rerun.RunAttempt = 2
	if failed, _ := Pick([]github.Run{rerun}, "ana", base); len(failed) != 0 {
		t.Fatalf("failed = %v", ids(failed))
	}
}

func TestRunningIsEveryRunNotCompleted(t *testing.T) {
	m := time.Minute
	runs := []github.Run{
		run(1, 10, "main", "queued", "", base.Add(-5*m)),
		run(2, 10, "main", "in_progress", "", base.Add(-1*m)),
		run(3, 11, "main", "waiting", "", base.Add(-4*m)),
		run(4, 12, "main", "requested", "", base.Add(-3*m)),
		run(5, 13, "main", "pending", "", base.Add(-2*m)),
		run(6, 14, "main", "completed", "action_required", base.Add(-6*m)),
	}
	failed, running := Pick(runs, "ana", base)
	if got := ids(running); !slices.Equal(got, []int64{2, 5, 4, 3, 1}) {
		t.Fatalf("running = %v", got)
	}
	if len(failed) != 0 {
		t.Fatalf("failed = %v", ids(failed))
	}
}

func TestOnlyTheLoginsRunsWhateverItsCase(t *testing.T) {
	theirs := run(1, 10, "main", "completed", "failure", base.Add(-time.Hour))
	theirs.Actor = "bo"
	mine := run(2, 11, "main", "in_progress", "", base.Add(-time.Hour))
	failed, running := Pick([]github.Run{theirs, mine}, "ANA", base)
	if len(failed) != 0 || !slices.Equal(ids(running), []int64{2}) {
		t.Fatalf("failed = %v, running = %v", ids(failed), ids(running))
	}
	if failed, running := Pick([]github.Run{theirs, mine}, "", base); len(failed)+len(running) != 0 {
		t.Fatal("no login lists nothing")
	}
}

func TestFailedRunsAreNewestFirstByTheirUpdate(t *testing.T) {
	early := run(1, 10, "main", "completed", "failure", base.Add(-3*time.Hour))
	early.UpdatedAt = base.Add(-10 * time.Minute) // re-run later, failed again
	late := run(2, 11, "main", "completed", "failure", base.Add(-time.Hour))
	if failed, _ := Pick([]github.Run{late, early}, "ana", base); !slices.Equal(ids(failed), []int64{1, 2}) {
		t.Fatalf("failed = %v", ids(failed))
	}
}
