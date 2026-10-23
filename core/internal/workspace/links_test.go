//go:build !windows

package workspace

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"runnir/core/internal/changes"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/store"
)

// runsPage is a runs page of ids, each a minute older than the one before,
// the first created at newest.
func runsPage(ids []int, newest time.Time) string {
	parts := make([]string, 0, len(ids))
	for i, id := range ids {
		created := newest.Add(-time.Duration(i) * time.Minute).UTC().Format(time.RFC3339)
		parts = append(parts, fmt.Sprintf(`{"id":%d,"workflow_id":3,"name":"CI","run_number":%d,"run_attempt":1,"event":"push","status":"completed","conclusion":"success","head_branch":"main","head_sha":"s%d","created_at":%q,"updated_at":%q}`,
			id, id, id, created, created))
	}
	return `{"workflow_runs":[` + strings.Join(parts, ",") + `]}`
}

// span is from down to to, both included.
func span(from, to int) []int {
	var out []int
	for id := from; id >= to; id-- {
		out = append(out, id)
	}
	return out
}

const pullsPath = "/repos/o/r/pulls"

func TestPullRequestsAreReadNextToRuns(t *testing.T) {
	fake, accounts := newFake(t)
	fake.set(func(f *fakeGitHub) {
		f.runs = `{"workflow_runs":[
			{"id":8,"workflow_id":3,"name":"CI","run_number":2,"run_attempt":1,"event":"push","status":"completed","conclusion":"success","head_branch":"main","head_sha":"m1","created_at":"2026-10-18T11:00:00Z","updated_at":"2026-10-18T11:04:00Z"},
			{"id":7,"workflow_id":3,"name":"CI","run_number":1,"run_attempt":1,"event":"pull_request","status":"completed","conclusion":"success","head_branch":"retry","head_sha":"c3","created_at":"2026-10-18T10:00:00Z","updated_at":"2026-10-18T10:04:00Z","head_repository":{"full_name":"o/r"}}]}`
		f.pulls = `[{"number":142,"title":"Add retry","state":"closed","head":{"ref":"retry","sha":"c3","repo":{"full_name":"o/r"}},"base":{"ref":"main"},"merge_commit_sha":"m1","created_at":"2026-10-18T09:00:00Z","updated_at":"2026-10-18T10:30:00Z","closed_at":"2026-10-18T10:30:00Z","merged_at":"2026-10-18T10:30:00Z"}]`
	})
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	waitRefresh(t, r)
	snap, err := r.Snapshot(context.Background(), 50)
	if err != nil || len(snap.Changes) != 1 || snap.Changes[0].ID != "pr:142" || len(snap.Changes[0].Sections) != 2 ||
		snap.Analysis.Links[8].Kind != changes.LinkAfterMerge || snap.CachedRuns != 2 || !snap.HistoryComplete {
		t.Fatalf("snapshot = %+v, %v", snap, err)
	}
	if snap.PullRequestsAccess != corev1.GithubAccess_GITHUB_ACCESS_OK {
		t.Fatalf("pull requests access = %v", snap.PullRequestsAccess)
	}
	// The default branch is read once; the list each pass (the second one 304).
	if fake.count("/repos/o/r") != 1 || fake.count(pullsPath) != 2 {
		t.Fatalf("repository reads %d, pull request reads %d", fake.count("/repos/o/r"), fake.count(pullsPath))
	}
}

func TestARefusedPullRequestListKeepsThePassOKAndStopsLookups(t *testing.T) {
	fake, accounts := newFake(t)
	fake.set(func(f *fakeGitHub) {
		f.pullsStatus = http.StatusForbidden
		f.runs = `{"workflow_runs":[{"id":7,"workflow_id":3,"name":"CI","run_number":1,"run_attempt":1,"event":"pull_request","status":"completed","conclusion":"success","head_branch":"retry","head_sha":"c3","created_at":"2026-10-18T10:00:00Z","updated_at":"2026-10-18T10:04:00Z","pull_requests":[{"number":142,"base":{"repo":{"url":"https://api.github.com/repos/o/r"}}}]}]}`
	})
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	snap, _ := r.Snapshot(context.Background(), 50)
	if snap.Access != corev1.GithubAccess_GITHUB_ACCESS_OK || snap.PullRequestsAccess != corev1.GithubAccess_GITHUB_ACCESS_PERMISSION_MISSING ||
		len(snap.Runs) != 1 || fake.count(pullsPath+"/142") != 0 {
		t.Fatalf("snapshot = %+v, lookups %d", snap, fake.count(pullsPath+"/142"))
	}
	// A refresh tries again; the missing pull request is looked up once.
	fake.set(func(f *fakeGitHub) {
		f.pullsStatus = 0
		f.extra[pullsPath+"/142"] = `{"number":142,"title":"Add retry","state":"open","head":{"ref":"retry","sha":"c3","repo":{"full_name":"o/r"}},"base":{"ref":"main"}}`
	})
	waitRefresh(t, r)
	waitRefresh(t, r)
	snap, _ = r.Snapshot(context.Background(), 50)
	if snap.PullRequestsAccess != corev1.GithubAccess_GITHUB_ACCESS_OK || len(snap.Changes) != 1 ||
		snap.Changes[0].PullRequest.Title != "Add retry" || fake.count(pullsPath+"/142") != 1 {
		t.Fatalf("snapshot = %+v, lookups %d", snap, fake.count(pullsPath+"/142"))
	}
}

func TestAGapIsFilledFromOlderPages(t *testing.T) {
	fake, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r) // run 7, 2026-10-18
	newer := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	fake.set(func(f *fakeGitHub) {
		f.runs, f.etag = runsPage(span(1049, 1000), newer), `"v2"`
		// The next older page reaches run 7 and is the end of the history.
		f.older = runsPage(append(span(999, 990), 7), newer.Add(-50*time.Minute))
	})
	waitRefresh(t, r)
	snap, _ := r.Snapshot(context.Background(), 5000)
	if snap.CachedRuns != 61 || !snap.HistoryComplete || fake.count(runsPath+"?created") != 1 {
		t.Fatalf("cached %d, complete %v, older reads %d", snap.CachedRuns, snap.HistoryComplete, fake.count(runsPath+"?created"))
	}
}

func TestAGapThatNeverClosesStartsTheHistoryAgain(t *testing.T) {
	fake, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r) // run 7, 2026-10-18
	newer := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	fake.set(func(f *fakeGitHub) {
		f.runs, f.etag = runsPage(span(1049, 1000), newer), `"v2"`
		// GitHub keeps answering the same hundred runs, all newer than run 7.
		f.older = runsPage(span(1099, 1000), newer)
	})
	waitRefresh(t, r)
	snap, _ := r.Snapshot(context.Background(), 5000)
	if snap.CachedRuns != 100 || snap.HistoryComplete {
		t.Fatalf("cached %d, complete %v", snap.CachedRuns, snap.HistoryComplete)
	}
	for _, run := range snap.Runs {
		if run.ID == 7 {
			t.Fatal("the run before the gap was kept")
		}
	}
}

func TestLoadOlderRunsExtendsTheHistory(t *testing.T) {
	fake, accounts := newFake(t)
	newer := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	fake.set(func(f *fakeGitHub) {
		f.runs = runsPage(span(1049, 1000), newer)
		f.older = runsPage(span(999, 970), newer.Add(-50*time.Minute))
	})
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r) // nothing was cached, so no gap: 50 runs, history open
	ctx := context.Background()
	result, err := r.LoadOlderRuns(ctx)
	if err != nil || result.Access != corev1.GithubAccess_GITHUB_ACCESS_OK || result.Added != 30 || !result.HistoryComplete || result.BudgetReached {
		t.Fatalf("result = %+v, %v", result, err)
	}
	again, _ := r.LoadOlderRuns(ctx)
	if !again.HistoryComplete || again.Added != 0 || fake.count(runsPath+"?created") != 1 {
		t.Fatalf("again = %+v, older reads %d", again, fake.count(runsPath+"?created"))
	}
}

func TestLoadOlderRunsStopsAtTheBudget(t *testing.T) {
	old := store.MaxRuns
	store.MaxRuns = 50
	t.Cleanup(func() { store.MaxRuns = old })
	fake, accounts := newFake(t)
	fake.set(func(f *fakeGitHub) {
		f.runs = runsPage(span(1049, 1000), time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC))
	})
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	result, err := r.LoadOlderRuns(context.Background())
	if err != nil || !result.BudgetReached || fake.count(runsPath+"?created") != 0 {
		t.Fatalf("result = %+v, %v, older reads %d", result, err, fake.count(runsPath+"?created"))
	}
}
