//go:build !windows

package store

import (
	"context"
	"testing"
	"time"
)

func TestConcurrencySavesKeepTheFirstAndCancelsAreCountedOnce(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	first := fixedNow()
	if err := s.AddConcurrencySave(ctx, ".github/workflows/ci.yml", first); err != nil {
		t.Fatal(err)
	}
	if err := s.AddConcurrencySave(ctx, ".github/workflows/ci.yml", first.Add(time.Hour)); err != nil {
		t.Fatal(err)
	}
	saves, err := s.ConcurrencySaves(ctx)
	if err != nil || len(saves) != 1 || !saves[0].SavedAt.Equal(first) {
		t.Fatalf("saves = %+v, %v", saves, err)
	}
	fresh, err := s.MarkCountedCancels(ctx, []int64{7, 8})
	if err != nil || !fresh[7] || !fresh[8] {
		t.Fatalf("first mark = %+v, %v", fresh, err)
	}
	fresh, _ = s.MarkCountedCancels(ctx, []int64{8, 9})
	if fresh[8] || !fresh[9] {
		t.Fatalf("second mark = %+v, want only 9 new", fresh)
	}
	// Clear Cache keeps both: they are this Mac's, not GitHub's.
	if err := s.ClearCache(ctx); err != nil {
		t.Fatal(err)
	}
	if saves, _ := s.ConcurrencySaves(ctx); len(saves) != 1 {
		t.Fatal("Clear Cache removed a concurrency save")
	}
	if fresh, _ := s.MarkCountedCancels(ctx, []int64{7}); fresh[7] {
		t.Fatal("Clear Cache forgot a counted cancel")
	}
}
