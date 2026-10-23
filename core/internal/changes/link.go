package changes

import (
	"time"

	"runnir/core/internal/github"
)

func isPullRequestEvent(event string) bool {
	return event == "pull_request" || event == "pull_request_target"
}

func headKey(repository, branch string) string { return "head:" + repository + ":" + branch }

// index holds the pull requests by what runs are matched on.
type index struct {
	byNumber   map[int64]github.RepositoryPullRequest
	mergedInto map[string][]int64 // merge commit
	byHeadSHA  map[string][]github.RepositoryPullRequest
	byBranch   map[string][]github.RepositoryPullRequest // "owner/name:ref"
}

func newIndex(pulls []github.RepositoryPullRequest) index {
	ix := index{byNumber: map[int64]github.RepositoryPullRequest{}, mergedInto: map[string][]int64{},
		byHeadSHA: map[string][]github.RepositoryPullRequest{}, byBranch: map[string][]github.RepositoryPullRequest{}}
	for _, p := range pulls {
		ix.byNumber[p.Number] = p
		if p.MergeCommitSHA != "" {
			ix.mergedInto[p.MergeCommitSHA] = append(ix.mergedInto[p.MergeCommitSHA], p.Number)
		}
		if p.HeadSHA != "" {
			ix.byHeadSHA[p.HeadSHA] = append(ix.byHeadSHA[p.HeadSHA], p)
		}
		if p.HeadRepository != "" && p.HeadRef != "" {
			key := p.HeadRepository + ":" + p.HeadRef
			ix.byBranch[key] = append(ix.byBranch[key], p)
		}
	}
	return ix
}

// best picks the most recently updated pull request of numbers; one not
// read yet ranks below those read, and among those the highest number wins.
// 0 when numbers is empty.
func (ix index) best(numbers []int64) int64 {
	var best int64
	var bestAt time.Time
	known := false
	for _, n := range numbers {
		p, ok := ix.byNumber[n]
		switch {
		case ok && (!known || p.UpdatedAt.After(bestAt) || (p.UpdatedAt.Equal(bestAt) && n > best)):
			best, bestAt, known = n, p.UpdatedAt, true
		case !ok && !known && n > best:
			best = n
		}
	}
	return best
}

// link decides a run's link; the first rule that matches wins (see the spec).
func (ix index) link(r github.Run, in Input) Link {
	if !isPullRequestEvent(r.Event) {
		// 1. After merge: the run is on the commit a merged pull request
		// created. pull_request_target runs can carry the base branch's
		// commit, so they never take this rule.
		if n := ix.best(ix.mergedInto[r.HeadSHA]); n != 0 {
			return Link{LinkAfterMerge, n}
		}
		// Otherwise a run on the default branch belongs to no pull request:
		// a push to main is not part of a release pull request from main.
		if in.DefaultBranch != "" && r.Branch == in.DefaultBranch {
			return Link{}
		}
	}
	// 2. GitHub's list on the run, and for a fork's run what its lookup found.
	candidates := append([]int64(nil), r.PullRequests...)
	if r.Event == "pull_request" {
		candidates = append(candidates, in.Lookups[headKey(r.HeadRepository, r.Branch)]...)
	}
	if n := ix.best(candidates); n != 0 {
		return Link{LinkPullRequest, n}
	}
	if r.HeadRepository == "" {
		return Link{}
	}
	// 3. The pull request's current head.
	var heads []int64
	for _, p := range ix.byHeadSHA[r.HeadSHA] {
		if p.HeadRepository == r.HeadRepository {
			heads = append(heads, p.Number)
		}
	}
	if n := ix.best(heads); n != 0 {
		return Link{LinkPullRequest, n}
	}
	// 4. The pull request's branch while it was open.
	if r.Event != "pull_request" && r.Event != "push" {
		return Link{}
	}
	var open []int64
	for _, p := range ix.byBranch[r.HeadRepository+":"+r.Branch] {
		if !r.CreatedAt.Before(p.CreatedAt) && (p.ClosedAt.IsZero() || !r.CreatedAt.After(p.ClosedAt)) {
			open = append(open, p.Number)
		}
	}
	if n := ix.best(open); n != 0 {
		return Link{LinkPullRequest, n}
	}
	return Link{}
}
