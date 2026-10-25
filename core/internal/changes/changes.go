// Package changes links GitHub Actions runs to the pull requests and
// commits they ran for, finds runs a newer push replaced and how long they
// kept going, groups runs into changes, and says where a concurrency block
// would help. Pure functions over cached data; no I/O.
package changes

import (
	"sort"
	"time"

	"runnir/core/internal/github"
)

// Input is a workspace's cached activity.
type Input struct {
	// Runs newest first; Run.PullRequests holds the cached links.
	Runs         []github.Run
	PullRequests []github.RepositoryPullRequest
	// Lookup answers by key: "pr:<n>", "commit:<sha>", "head:<owner/name>:<branch>".
	Lookups       map[string][]int64
	DefaultBranch string
	// Lowercased "owner/name" of the repository.
	Repository string
	// The repository's web address, for links to pull requests not read yet.
	RepositoryURL string
	Now           time.Time
}

type LinkKind int

const (
	LinkNone LinkKind = iota
	// The run ran on a commit of the pull request, before its merge.
	LinkPullRequest
	// The run ran on the commit the pull request's merge created.
	LinkAfterMerge
)

type Link struct {
	Kind        LinkKind
	PullRequest int64
}

// Overlap is how long superseded runs of one workflow kept going after the
// next run on a newer commit started. Wall-clock time, not runner minutes.
type Overlap struct {
	RunIDs       []int64
	Duration     time.Duration
	PullRequests []int64
}

// Analysis is what Analyze finds over every cached run.
type Analysis struct {
	Links map[int64]Link
	// SupersededBy maps a run to the newest run of the same workflow and
	// event on a newer commit of its pull request.
	SupersededBy map[int64]int64
	// Overlaps by workflow id.
	Overlaps map[int64]Overlap
}

// Analyze links every run, finds superseded runs and measures their overlap.
func Analyze(in Input) Analysis {
	ix := newIndex(in.PullRequests)
	a := Analysis{Links: map[int64]Link{}, SupersededBy: map[int64]int64{}, Overlaps: map[int64]Overlap{}}
	type key struct {
		pull, workflow int64
		event          string
	}
	groups := map[key][]github.Run{}
	for _, r := range in.Runs {
		link := ix.link(r, in)
		a.Links[r.ID] = link
		if link.Kind == LinkPullRequest && (r.Event == "pull_request" || r.Event == "push") {
			k := key{link.PullRequest, r.WorkflowID, r.Event}
			groups[k] = append(groups[k], r)
		}
	}
	for k, runs := range groups {
		sort.SliceStable(runs, func(i, j int) bool {
			if runs[i].CreatedAt.Equal(runs[j].CreatedAt) {
				return runs[i].ID < runs[j].ID
			}
			return runs[i].CreatedAt.Before(runs[j].CreatedAt)
		})
		for i, r := range runs {
			var next, newest *github.Run
			for j := i + 1; j < len(runs); j++ {
				if runs[j].HeadSHA == r.HeadSHA {
					continue
				}
				if next == nil {
					next = &runs[j]
				}
				newest = &runs[j]
			}
			if newest == nil {
				continue
			}
			a.SupersededBy[r.ID] = newest.ID
			// A cancelled run stopped in time; a re-run of an old commit was
			// started on purpose.
			if r.Conclusion == "cancelled" || r.RunAttempt > 1 {
				continue
			}
			end := r.UpdatedAt
			if r.Status != "completed" {
				end = in.Now
			}
			if d := end.Sub(next.CreatedAt); d > 0 {
				o := a.Overlaps[k.workflow]
				o.RunIDs = append(o.RunIDs, r.ID)
				o.Duration += d
				if !contains(o.PullRequests, k.pull) {
					o.PullRequests = append(o.PullRequests, k.pull)
				}
				a.Overlaps[k.workflow] = o
			}
		}
	}
	for workflow, o := range a.Overlaps {
		sort.Slice(o.RunIDs, func(i, j int) bool { return o.RunIDs[i] < o.RunIDs[j] })
		sort.Slice(o.PullRequests, func(i, j int) bool { return o.PullRequests[i] < o.PullRequests[j] })
		a.Overlaps[workflow] = o
	}
	return a
}

func contains(list []int64, value int64) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}
