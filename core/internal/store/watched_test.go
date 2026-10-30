//go:build !windows

package store

import (
	"context"
	"testing"
	"time"

	"runnir/core/internal/github"
)

func TestWatchedRunsAreAnActorsNewestSavedRuns(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	if w, err := s.WatchedRuns(ctx, "ana", 50); err != nil || w.HasSource {
		t.Fatalf("empty = %+v, %v", w, err)
	}
	at := fixedNow()
	_, err := s.ApplySync(ctx, Pass{Source: testSource, At: at, OK: true, Runs: &RunsUpdate{Runs: []github.Run{
		{ID: 3, Actor: "Ana", Status: "in_progress", CreatedAt: at},
		{ID: 2, Actor: "bo", Status: "completed", Conclusion: "failure", CreatedAt: at.Add(-time.Minute)},
		{ID: 1, Actor: "ana", Status: "completed", Conclusion: "failure", CreatedAt: at.Add(-2 * time.Minute)},
	}}})
	if err != nil {
		t.Fatal(err)
	}
	w, err := s.WatchedRuns(ctx, "ANA", 50)
	if err != nil || !w.HasSource || w.Source != testSource || !w.SyncedAt.Equal(at) || len(w.Runs) != 2 || w.Runs[0].ID != 3 || w.Runs[1].ID != 1 {
		t.Fatalf("watched = %+v, %v", w, err)
	}
	if w, _ := s.WatchedRuns(ctx, "ana", 1); len(w.Runs) != 1 {
		t.Fatalf("limit = %+v", w.Runs)
	}
}
