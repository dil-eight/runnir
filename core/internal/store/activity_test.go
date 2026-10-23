//go:build !windows

package store

import (
	"context"
	"testing"
	"time"

	"runnir/core/internal/github"
)

var source = Source{ServerID: "", Repository: "o/r"}

func run(id int64, minute int, status string) github.Run {
	at := fixedNow().Add(time.Duration(minute) * time.Minute)
	return github.Run{ID: id, WorkflowID: 3, Name: "CI", RunNumber: id, RunAttempt: 1, Event: "push", Status: status,
		Branch: "main", HeadSHA: "abc", Actor: "octocat", CreatedAt: at, UpdatedAt: at}
}

func pass(at int, runs []github.Run, complete bool) Pass {
	return Pass{Source: source, At: fixedNow().Add(time.Duration(at) * time.Minute), OK: true, Access: 1,
		Runs:      &RunsUpdate{Runs: runs, Complete: complete, ETag: `"r"`},
		Workflows: &WorkflowsUpdate{Workflows: []github.Workflow{{ID: 3, Name: "CI", Path: ".github/workflows/ci.yml", State: "active"}}, ETag: `"w"`}}
}

func TestAPassIsStoredAndReadBackNewestFirst(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	changed, err := s.ApplySync(ctx, pass(0, []github.Run{run(2, 2, "completed"), run(1, 1, "completed")}, true))
	if err != nil || !changed {
		t.Fatalf("apply = %v, %v", changed, err)
	}
	a, err := s.Activity(ctx, 50)
	if err != nil || !a.HasSource || a.Source != source || len(a.Runs) != 2 || a.Runs[0].ID != 2 || len(a.Workflows) != 1 {
		t.Fatalf("activity = %+v, %v", a, err)
	}
	if !a.SyncedAt.Equal(fixedNow()) || !a.ChangedAt.Equal(fixedNow()) || !a.CheckedAt.Equal(fixedNow()) || a.Access != 1 {
		t.Fatalf("freshness = %+v", a)
	}
	if a.Runs[0].Actor != "octocat" || !a.Runs[0].CreatedAt.Equal(fixedNow().Add(2*time.Minute)) {
		t.Fatalf("run = %+v", a.Runs[0])
	}
	runsTag, workflowsTag, _ := s.ETags(ctx, source)
	if runsTag != `"r"` || workflowsTag != `"w"` {
		t.Fatalf("etags = %q %q", runsTag, workflowsTag)
	}
	if r, w, _ := s.ETags(ctx, Source{Repository: "other/repo"}); r != "" || w != "" {
		t.Fatal("etags leaked to another repository")
	}
}

func TestNotModifiedAndUnchangedPassesKeepChangedAt(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{run(1, 1, "completed")}, true))
	changed, _ := s.ApplySync(ctx, Pass{Source: source, At: fixedNow().Add(time.Minute), OK: true, Access: 1,
		Runs: &RunsUpdate{NotModified: true, ETag: `"r"`}, Workflows: &WorkflowsUpdate{NotModified: true, ETag: `"w"`}})
	if changed {
		t.Fatal("304 changed data")
	}
	changed, _ = s.ApplySync(ctx, pass(2, []github.Run{run(1, 1, "completed")}, true))
	if changed {
		t.Fatal("identical data counted as a change")
	}
	a, _ := s.Activity(ctx, 50)
	if !a.SyncedAt.Equal(fixedNow().Add(2*time.Minute)) || !a.ChangedAt.Equal(fixedNow()) {
		t.Fatalf("synced %v changed %v", a.SyncedAt, a.ChangedAt)
	}
}

func TestAFailedPassKeepsDataAndRecordsTheAttempt(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{run(1, 1, "completed")}, true))
	retry := fixedNow().Add(time.Hour)
	_, _ = s.ApplySync(ctx, Pass{Source: source, At: fixedNow().Add(time.Minute), Access: 7, RetryAfter: retry})
	a, _ := s.Activity(ctx, 50)
	if len(a.Runs) != 1 || a.Access != 7 || !a.RetryAfter.Equal(retry) || !a.CheckedAt.Equal(fixedNow().Add(time.Minute)) || !a.SyncedAt.Equal(fixedNow()) {
		t.Fatalf("activity = %+v", a)
	}
}

func TestRunsDeletedOnGitHubLeaveTheCache(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{run(5, 5, "completed"), run(4, 4, "completed"), run(3, 3, "completed"), run(1, 1, "completed")}, false))
	// Run 4 was deleted: newer than the page's oldest (3) but missing.
	// Run 1 is older than the page: it stays.
	changed, _ := s.ApplySync(ctx, pass(1, []github.Run{run(6, 6, "queued"), run(5, 5, "completed"), run(3, 3, "completed")}, false))
	a, _ := s.Activity(ctx, 50)
	ids := []int64{}
	for _, r := range a.Runs {
		ids = append(ids, r.ID)
	}
	if !changed || len(ids) != 4 || ids[0] != 6 || ids[1] != 5 || ids[2] != 3 || ids[3] != 1 {
		t.Fatalf("ids = %v", ids)
	}
	// A complete page is every run: anything else is gone.
	_, _ = s.ApplySync(ctx, pass(2, []github.Run{run(6, 6, "completed")}, true))
	if a, _ := s.Activity(ctx, 50); len(a.Runs) != 1 {
		t.Fatalf("complete page kept %d runs", len(a.Runs))
	}
}

func TestOnlyTheNewest200RunsAreKept(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	for batch := 0; batch < 5; batch++ {
		var page []github.Run
		for i := 49; i >= 0; i-- {
			id := int64(batch*50 + i + 1)
			page = append(page, run(id, int(id), "completed"))
		}
		_, _ = s.ApplySync(ctx, pass(batch, page, false))
	}
	a, _ := s.Activity(ctx, 1000)
	if len(a.Runs) != maxRuns || a.Runs[0].ID != 250 || a.Runs[maxRuns-1].ID != 51 {
		t.Fatalf("kept %d, newest %d, oldest %d", len(a.Runs), a.Runs[0].ID, a.Runs[len(a.Runs)-1].ID)
	}
}

func TestAnotherRepositoryReplacesTheCache(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{run(1, 1, "completed")}, true))
	other := Source{Repository: "o/other"}
	// A failed pass for the new repository changes nothing cached.
	_, _ = s.ApplySync(ctx, Pass{Source: other, At: fixedNow().Add(time.Minute), Access: 7})
	if a, _ := s.Activity(ctx, 50); a.Source != source || len(a.Runs) != 1 {
		t.Fatalf("after failure = %+v", a)
	}
	next := pass(2, []github.Run{run(9, 9, "completed")}, true)
	next.Source = other
	_, _ = s.ApplySync(ctx, next)
	a, _ := s.Activity(ctx, 50)
	if a.Source != other || len(a.Runs) != 1 || a.Runs[0].ID != 9 {
		t.Fatalf("after switch = %+v", a)
	}
}
