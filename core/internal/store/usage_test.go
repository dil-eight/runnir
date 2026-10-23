//go:build !windows

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
