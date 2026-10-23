//go:build !windows

package store

import (
	"context"
	"fmt"
	"testing"
	"time"

	"runnir/core/internal/github"
)

func pull(number int64, updated int) github.RepositoryPullRequest {
	at := fixedNow().Add(time.Duration(updated) * time.Minute)
	return github.RepositoryPullRequest{Number: number, Title: fmt.Sprintf("PR %d", number), State: "open",
		HeadRef: "b", HeadSHA: "s", HeadRepository: "o/r", BaseRef: "main", CreatedAt: at, UpdatedAt: at}
}

func TestPullRequestsAreStoredWithTheirETagAndAccess(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	p := pass(0, []github.Run{run(1, 1, "completed")}, true)
	merged := pull(142, 5)
	merged.State, merged.MergeCommitSHA, merged.MergedAt, merged.Draft = "closed", "m1", fixedNow(), true
	p.PullRequests = &PullRequestsUpdate{PullRequests: []github.RepositoryPullRequest{merged, pull(145, 3)}, ETag: `"p"`, Access: 1}
	if changed, err := s.ApplySync(ctx, p); err != nil || !changed {
		t.Fatalf("apply = %v, %v", changed, err)
	}
	a, _ := s.Activity(ctx, 50)
	if len(a.PullRequests) != 2 || a.PullRequests[0].Number != 142 || a.PullRequests[0].MergeCommitSHA != "m1" ||
		!a.PullRequests[0].Draft || !a.PullRequests[0].MergedAt.Equal(fixedNow()) || a.PullRequestsAccess != 1 {
		t.Fatalf("pulls = %+v, access %d", a.PullRequests, a.PullRequestsAccess)
	}
	if tags, _ := s.ETags(ctx, source); tags.Pulls != `"p"` {
		t.Fatalf("tags = %+v", tags)
	}
	// The same list again is no change.
	again := pass(1, []github.Run{run(1, 1, "completed")}, true)
	again.PullRequests = &PullRequestsUpdate{PullRequests: []github.RepositoryPullRequest{merged, pull(145, 3)}, ETag: `"p"`, Access: 1}
	if changed, _ := s.ApplySync(ctx, again); changed {
		t.Fatal("identical pull requests counted as a change")
	}
	// A refusal keeps what was read and records why.
	refused := pass(2, []github.Run{run(1, 1, "completed")}, true)
	refused.PullRequests = &PullRequestsUpdate{Refused: true, ETag: `"p"`, Access: 8}
	_, _ = s.ApplySync(ctx, refused)
	if a, _ := s.Activity(ctx, 50); len(a.PullRequests) != 2 || a.PullRequestsAccess != 8 {
		t.Fatalf("after refusal = %+v, access %d", a.PullRequests, a.PullRequestsAccess)
	}
}

func TestLookupsAreKeptWhileARunNeedsThem(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	linked := run(1, 1, "completed")
	linked.PullRequests, linked.HeadSHA = []int64{142}, "m1"
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{linked}, true))
	merged := pull(142, 1)
	merged.MergeCommitSHA = "m1"
	changed, err := s.ApplyLookups(ctx, LookupsUpdate{Source: source, At: fixedNow(), Lookups: []Lookup{
		{Key: "pr:142", Numbers: []int64{142}, PullRequests: []github.RepositoryPullRequest{merged}},
		{Key: "commit:m1", Numbers: []int64{142}},
		{Key: "commit:gone"},
	}})
	if err != nil || !changed {
		t.Fatalf("lookups = %v, %v", changed, err)
	}
	a, _ := s.Activity(ctx, 50)
	if len(a.PullRequests) != 1 || len(a.Lookups["pr:142"]) != 1 || len(a.Lookups["commit:m1"]) != 1 {
		t.Fatalf("activity = %+v", a)
	}
	// No cached run is on "gone": its lookup is not kept.
	if _, ok := a.Lookups["commit:gone"]; ok {
		t.Fatal("a lookup no run needs was kept")
	}
	if changed, _ := s.ApplyLookups(ctx, LookupsUpdate{Source: Source{Repository: "o/other"}, Lookups: []Lookup{{Key: "pr:1"}}}); changed {
		t.Fatal("lookups for another repository were stored")
	}
	// A refusal is kept as the pull requests' access.
	_, _ = s.ApplyLookups(ctx, LookupsUpdate{Source: source, At: fixedNow(), Access: 8})
	if a, _ := s.Activity(ctx, 50); a.PullRequestsAccess != 8 {
		t.Fatalf("access = %d", a.PullRequestsAccess)
	}
	if err := s.ClearCache(ctx); err != nil {
		t.Fatal(err)
	}
	if a, _ := s.Activity(ctx, 50); len(a.PullRequests) != 0 || len(a.Lookups) != 0 {
		t.Fatalf("after Clear Cache = %+v", a)
	}
}

func TestOnlyNamedAndRecentPullRequestsAreKept(t *testing.T) {
	old := maxPullRequests
	maxPullRequests = 2
	t.Cleanup(func() { maxPullRequests = old })
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	linked := run(1, 1, "completed")
	linked.PullRequests = []int64{1}
	p := pass(0, []github.Run{linked}, true)
	p.PullRequests = &PullRequestsUpdate{PullRequests: []github.RepositoryPullRequest{pull(4, 4), pull(3, 3), pull(2, 2), pull(1, 1)}, Access: 1}
	_, _ = s.ApplySync(ctx, p)
	a, _ := s.Activity(ctx, 50)
	got := []int64{}
	for _, pr := range a.PullRequests {
		got = append(got, pr.Number)
	}
	// 4 and 3 are the newest; 1 is named by a run; 2 goes.
	if fmt.Sprint(got) != "[4 3 1]" {
		t.Fatalf("kept %v", got)
	}
}

func TestOlderRunsFillTheHistory(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{run(10, 10, "completed"), run(9, 9, "completed")}, false))
	h, ok, _ := s.History(ctx, source)
	if !ok || h.Count != 2 || !h.Oldest.Equal(fixedNow().Add(9*time.Minute)) || h.Complete {
		t.Fatalf("history = %+v, %v", h, ok)
	}
	// Run 9 comes again (same time bound); 8 and 6 are new.
	added, err := s.AddOlderRuns(ctx, source, h.Oldest, []github.Run{run(9, 9, "completed"), run(8, 8, "completed"), run(6, 6, "completed")}, true)
	if err != nil || added != 2 {
		t.Fatalf("added = %d, %v", added, err)
	}
	if h, _, _ = s.History(ctx, source); h.Count != 4 || !h.Complete {
		t.Fatalf("history = %+v", h)
	}
	// Run 8 was deleted on GitHub: a page that lacks it removes it.
	_, _ = s.AddOlderRuns(ctx, source, fixedNow().Add(9*time.Minute), []github.Run{run(9, 9, "completed"), run(6, 6, "completed")}, true)
	if h, _, _ = s.History(ctx, source); h.Count != 3 {
		t.Fatalf("history = %+v", h)
	}
	if added, _ := s.AddOlderRuns(ctx, Source{Repository: "o/other"}, h.Oldest, []github.Run{run(1, 1, "completed")}, false); added != 0 {
		t.Fatal("older runs of another repository were stored")
	}
	if _, ok, _ := s.History(ctx, Source{Repository: "o/other"}); ok {
		t.Fatal("history of another repository")
	}
}
