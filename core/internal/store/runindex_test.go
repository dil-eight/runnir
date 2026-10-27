//go:build !windows

package store

import (
	"context"
	"testing"

	"runnir/core/internal/github"
)

func indexed(t *testing.T, s *Store, src Source) []int64 {
	t.Helper()
	found, err := s.SearchIndex(context.Background(), src, nil, 0, func(github.Run) bool { return true })
	runs := found.Runs
	if err != nil {
		t.Fatal(err)
	}
	ids := make([]int64, len(runs))
	for i, r := range runs {
		ids[i] = r.ID
	}
	return ids
}

func TestEveryRunTheCacheStoresIsIndexed(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	if _, err := s.ApplySync(ctx, pass(0, []github.Run{run(2, 2, "completed"), run(1, 1, "completed")}, true)); err != nil {
		t.Fatal(err)
	}
	if got := indexed(t, s, source); len(got) != 2 || got[0] != 2 {
		t.Fatalf("indexed = %v", got)
	}
	// An older page extends the index as it extends the cache.
	if _, err := s.AddOlderRuns(ctx, source, fixedNow(), []github.Run{run(0, -5, "completed")}, false); err != nil {
		t.Fatal(err)
	}
	if got := indexed(t, s, source); len(got) != 3 {
		t.Fatalf("after an older page = %v", got)
	}
}

func TestARunTheCacheDroppedStaysInTheIndex(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	if _, err := s.ApplySync(ctx, pass(0, []github.Run{run(2, 2, "completed"), run(1, 1, "completed")}, true)); err != nil {
		t.Fatal(err)
	}
	// GitHub no longer lists run 1: a complete pass drops it from the cache.
	if _, err := s.ApplySync(ctx, pass(1, []github.Run{run(2, 2, "completed")}, true)); err != nil {
		t.Fatal(err)
	}
	a, err := s.Activity(ctx, MaxRuns)
	if err != nil || len(a.Runs) != 1 {
		t.Fatalf("cache = %v, %v", a.Runs, err)
	}
	skip := map[int64]bool{2: true}
	result, err := s.SearchIndex(ctx, source, skip, 0, func(github.Run) bool { return true })
	only, looked := result.Runs, result.Looked
	if err != nil || looked != 2 || len(only) != 1 || only[0].ID != 1 {
		t.Fatalf("index only = %v, looked %d, %v", only, looked, err)
	}
}

func TestClearCacheKeepsTheIndexAndClearRunIndexEmptiesIt(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	if _, err := s.ApplySync(ctx, pass(0, []github.Run{run(1, 1, "completed")}, true)); err != nil {
		t.Fatal(err)
	}
	if err := s.ClearCache(ctx); err != nil {
		t.Fatal(err)
	}
	if n, _ := s.IndexedRuns(ctx); n != 1 {
		t.Fatalf("after Clear Cache = %d", n)
	}
	if err := s.ClearRunIndex(ctx); err != nil {
		t.Fatal(err)
	}
	if n, _ := s.IndexedRuns(ctx); n != 0 {
		t.Fatalf("after clearing = %d", n)
	}
}

func TestTheIndexKeepsTheNewestRunsOfEachRepository(t *testing.T) {
	old := MaxIndexedRuns
	MaxIndexedRuns = 3
	t.Cleanup(func() { MaxIndexedRuns = old })
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	other := Source{Repository: "o/other"}
	var runs []github.Run
	for i := 1; i <= 5; i++ {
		runs = append(runs, run(int64(i), i, "completed"))
	}
	if err := s.IndexRuns(ctx, source, runs); err != nil {
		t.Fatal(err)
	}
	if err := s.IndexRuns(ctx, other, []github.Run{run(100, 1, "completed")}); err != nil {
		t.Fatal(err)
	}
	if got := indexed(t, s, source); len(got) != 3 || got[0] != 5 || got[2] != 3 {
		t.Fatalf("kept = %v", got)
	}
	if got := indexed(t, s, other); len(got) != 1 {
		t.Fatalf("the other repository = %v", got)
	}
}

func TestPullRequestNumbersAreIndexedAndNotLostByALaterReadWithoutThem(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	r := run(1, 1, "completed")
	r.PullRequests = []int64{142}
	if err := s.IndexRuns(ctx, source, []github.Run{r}); err != nil {
		t.Fatal(err)
	}
	r.PullRequests = nil
	if err := s.IndexRuns(ctx, source, []github.Run{r}); err != nil {
		t.Fatal(err)
	}
	result, _ := s.SearchIndex(ctx, source, nil, 0, func(github.Run) bool { return true })
	got := result.Runs
	if len(got) != 1 || len(got[0].PullRequests) != 1 || got[0].PullRequests[0] != 142 {
		t.Fatalf("pulls = %+v", got)
	}
}
