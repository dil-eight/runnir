//go:build !windows

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
