package changes

import (
	"reflect"
	"testing"
	"time"

	"runnir/core/internal/github"
)

func TestTheExampleIsLinkedToItsPullRequest(t *testing.T) {
	a := Analyze(example())
	want := map[int64]Link{1: {LinkPullRequest, 142}, 2: {LinkPullRequest, 142}, 3: {LinkPullRequest, 142},
		4: {LinkAfterMerge, 142}, 5: {LinkAfterMerge, 142}}
	if !reflect.DeepEqual(a.Links, want) {
		t.Fatalf("links = %v", a.Links)
	}
	if !reflect.DeepEqual(a.SupersededBy, map[int64]int64{1: 3, 2: 3}) {
		t.Fatalf("superseded = %v", a.SupersededBy)
	}
	// Run 1 kept going 10 minutes after run 2 started, run 2 five minutes after run 3.
	o := a.Overlaps[1]
	if !reflect.DeepEqual(o.RunIDs, []int64{1, 2}) || o.Duration != 15*time.Minute || !reflect.DeepEqual(o.PullRequests, []int64{142}) {
		t.Fatalf("overlap = %+v", o)
	}
	if _, ok := a.Overlaps[2]; ok {
		t.Fatal("Deploy has no overlap")
	}
}

func TestAReleasePullRequestFromMainNeverTakesPushesToMain(t *testing.T) {
	release := github.RepositoryPullRequest{Number: 200, State: "open", HeadRef: "main", HeadSHA: "a2", HeadRepository: "o/r",
		BaseRef: "release", CreatedAt: at(0), UpdatedAt: at(20)}
	in := Input{Runs: newestFirst(mk(1, 1, "push", "main", "a1", 5, lists(200)), mk(2, 1, "push", "main", "a2", 15, lists(200))),
		PullRequests: []github.RepositoryPullRequest{release}, DefaultBranch: "main", Repository: "o/r"}
	a := Analyze(in)
	if a.Links[1].Kind != LinkNone || a.Links[2].Kind != LinkNone || len(a.SupersededBy) != 0 {
		t.Fatalf("analysis = %+v", a)
	}
}

func TestPullRequestTargetRunsAreNeverAfterMerge(t *testing.T) {
	in := example()
	// pull_request_target runs on the base branch's commit, here the merge of #142.
	in.Runs = []github.Run{mk(9, 3, "pull_request_target", "main", "m1", 80, lists(145))}
	if got := Analyze(in).Links[9]; got != (Link{LinkPullRequest, 145}) {
		t.Fatalf("link = %+v", got)
	}
}

func TestAForksRunIsLinkedThroughItsLookupOrItsPullRequest(t *testing.T) {
	run := mk(1, 1, "pull_request", "patch-1", "f1", 1, fromRepository("fork/r"))
	in := Input{Runs: []github.Run{run}, DefaultBranch: "main", Repository: "o/r"}
	if got := Analyze(in).Links[1]; got.Kind != LinkNone {
		t.Fatalf("without data = %+v", got)
	}
	in.Lookups = map[string][]int64{"head:fork/r:patch-1": {150}}
	if got := Analyze(in).Links[1]; got != (Link{LinkPullRequest, 150}) {
		t.Fatalf("by lookup = %+v", got)
	}
	in.Lookups = nil
	in.PullRequests = []github.RepositoryPullRequest{{Number: 150, State: "open", HeadRef: "patch-1", HeadSHA: "f2",
		HeadRepository: "fork/r", BaseRef: "main", CreatedAt: at(0), UpdatedAt: at(5)}}
	if got := Analyze(in).Links[1]; got != (Link{LinkPullRequest, 150}) {
		t.Fatalf("by branch = %+v", got)
	}
}

func TestRunsOnOneCommitAreNotSuperseded(t *testing.T) {
	in := example()
	in.Runs = newestFirst(mk(1, 1, "pull_request", "retry", "c3", 1, lists(142)), mk(2, 1, "pull_request", "retry", "c3", 2, lists(142)))
	if a := Analyze(in); len(a.SupersededBy) != 0 || len(a.Overlaps) != 0 {
		t.Fatalf("analysis = %+v", a)
	}
}

func TestOverlapSkipsCancelledAndReRunRunsAndCountsRunningOnesToNow(t *testing.T) {
	in := example()
	in.Runs = newestFirst(
		mk(1, 1, "pull_request", "retry", "c1", 1, lists(142), concluded("cancelled"), endsAt(30)),
		mk(2, 1, "pull_request", "retry", "c2", 10, lists(142), attempt(2), endsAt(40)),
		mk(3, 1, "pull_request", "retry", "c3", 20, lists(142), stillRunning()),
		mk(4, 1, "pull_request", "retry", "c4", 30, lists(142)),
	)
	in.Now = at(45)
	a := Analyze(in)
	if a.SupersededBy[1] != 4 || a.SupersededBy[2] != 4 || a.SupersededBy[3] != 4 {
		t.Fatalf("superseded = %v", a.SupersededBy)
	}
	// 1 was cancelled and 2 is a re-run: no overlap. 3 still runs since 4 started at 30.
	if o := a.Overlaps[1]; !reflect.DeepEqual(o.RunIDs, []int64{3}) || o.Duration != 15*time.Minute {
		t.Fatalf("overlap = %+v", o)
	}
}

func TestTheMostRecentlyUpdatedPullRequestWins(t *testing.T) {
	older := github.RepositoryPullRequest{Number: 142, UpdatedAt: at(1)}
	newer := github.RepositoryPullRequest{Number: 145, UpdatedAt: at(2)}
	in := Input{Runs: []github.Run{mk(1, 1, "push", "shared", "x1", 3, lists(142, 145))},
		PullRequests: []github.RepositoryPullRequest{older, newer}, DefaultBranch: "main", Repository: "o/r"}
	if got := Analyze(in).Links[1]; got != (Link{LinkPullRequest, 145}) {
		t.Fatalf("link = %+v", got)
	}
}
