//go:build !windows

package store

import (
	"context"
	"testing"
	"time"

	"runnir/core/internal/github"
)

func TestJobAndRunReferencesComeFromTheLatestCompletedRuns(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	older, newer := run(7, 1, "completed"), run(8, 10, "completed")
	older.Conclusion, newer.Conclusion = "success", "failure"
	newer.UpdatedAt = newer.CreatedAt.Add(6 * time.Minute)
	running := run(9, 20, "in_progress")
	if _, err := s.ApplySync(ctx, pass(0, []github.Run{running, newer, older}, true)); err != nil {
		t.Fatal(err)
	}
	at := fixedNow()
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(s.PutJobs(ctx, 7, 1, at, []github.Job{{ID: 70, Name: "Lint", Status: "completed", Conclusion: "success",
		StartedAt: at, CompletedAt: at.Add(5 * time.Minute)}}))
	must(s.PutJobs(ctx, 8, 1, at, []github.Job{
		{ID: 80, Name: "Lint", Status: "completed", Conclusion: "failure", StartedAt: at.Add(time.Hour), CompletedAt: at.Add(time.Hour + 2*time.Minute)},
		{ID: 81, Name: "Skipped", Status: "completed", Conclusion: "skipped", StartedAt: at, CompletedAt: at},
	}))
	refs, err := s.JobReferences(ctx, ".github/workflows/ci.yml", []string{"Lint", "Skipped", "Missing"})
	if err != nil || len(refs) != 1 || refs["Lint"] != 2*time.Minute {
		t.Fatalf("job references = %+v, %v", refs, err)
	}
	if refs, _ := s.JobReferences(ctx, ".github/workflows/other.yml", []string{"Lint"}); len(refs) != 0 {
		t.Fatalf("another workflow's jobs matched: %+v", refs)
	}
	wall, ok, err := s.RunReference(ctx, ".github/workflows/ci.yml")
	if err != nil || !ok || wall != 6*time.Minute {
		t.Fatalf("run reference = %v, %v, %v", wall, ok, err)
	}
	if _, ok, _ := s.RunReference(ctx, ".github/workflows/other.yml"); ok {
		t.Fatal("a run reference for a workflow with no runs")
	}
}
