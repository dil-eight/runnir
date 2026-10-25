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

// lowerBudget makes the run budget n for one test.
func lowerBudget(t *testing.T, n int) {
	t.Helper()
	old := MaxRuns
	MaxRuns = n
	t.Cleanup(func() { MaxRuns = old })
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
	tags, _ := s.ETags(ctx, source)
	if tags.Runs != `"r"` || tags.Workflows != `"w"` {
		t.Fatalf("etags = %+v", tags)
	}
	if tags, _ := s.ETags(ctx, Source{Repository: "other/repo"}); tags != (Tags{}) {
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

func TestOnlyTheNewestRunsAreKept(t *testing.T) {
	lowerBudget(t, 200)
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
	if len(a.Runs) != 200 || a.CachedRuns != 200 || a.Runs[0].ID != 250 || a.Runs[199].ID != 51 || a.HistoryComplete {
		t.Fatalf("kept %d (%d), newest %d, oldest %d, complete %v", len(a.Runs), a.CachedRuns, a.Runs[0].ID, a.Runs[len(a.Runs)-1].ID, a.HistoryComplete)
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

func TestRunsKeepTheirCommitAndPullRequestLinks(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	linked := run(1, 1, "completed")
	linked.HeadRepository, linked.CommitTitle, linked.PullRequests = "o/r", "Add retry", []int64{142}
	if changed, err := s.ApplySync(ctx, pass(0, []github.Run{linked}, true)); err != nil || !changed {
		t.Fatalf("apply = %v, %v", changed, err)
	}
	// GitHub may later list no pull request on the run: the link stays.
	linked.PullRequests = nil
	if changed, _ := s.ApplySync(ctx, pass(1, []github.Run{linked}, true)); changed {
		t.Fatal("an empty pull request list counted as a change")
	}
	a, _ := s.Activity(ctx, 50)
	got := a.Runs[0]
	if got.HeadRepository != "o/r" || got.CommitTitle != "Add retry" || len(got.PullRequests) != 1 || got.PullRequests[0] != 142 {
		t.Fatalf("run = %+v", got)
	}
	linked.PullRequests = []int64{150}
	if changed, _ := s.ApplySync(ctx, pass(2, []github.Run{linked}, true)); !changed {
		t.Fatal("a new link is a change")
	}
	if a, _ := s.Activity(ctx, 50); len(a.Runs[0].PullRequests) != 2 {
		t.Fatalf("links = %v", a.Runs[0].PullRequests)
	}
}

func TestTheDefaultBranchAndTheHistoryAreKept(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	p := pass(0, []github.Run{run(2, 2, "completed"), run(1, 1, "completed")}, true)
	p.DefaultBranch = "main"
	_, _ = s.ApplySync(ctx, p)
	a, _ := s.Activity(ctx, 1)
	if a.DefaultBranch != "main" || !a.HistoryComplete || a.CachedRuns != 2 || len(a.Runs) != 1 {
		t.Fatalf("activity = %+v", a)
	}
	if newest, ok, _ := s.Newest(ctx, source); !ok || !newest.Equal(fixedNow().Add(2*time.Minute)) {
		t.Fatalf("newest = %v %v", newest, ok)
	}
	if _, ok, _ := s.Newest(ctx, Source{Repository: "o/other"}); ok {
		t.Fatal("newest of another repository")
	}
	// A page that never reached the cache: older runs go and the history
	// is no longer complete; the default branch stays.
	restart := pass(1, []github.Run{run(9, 9, "completed"), run(8, 8, "completed")}, false)
	restart.Runs.Restart = true
	_, _ = s.ApplySync(ctx, restart)
	a, _ = s.Activity(ctx, 50)
	if a.CachedRuns != 2 || a.Runs[1].ID != 8 || a.HistoryComplete || a.DefaultBranch != "main" {
		t.Fatalf("after restart = %+v", a)
	}
}
