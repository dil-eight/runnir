package changes

import (
	"fmt"
	"strings"

	"runnir/core/internal/github"
)

type NeedKind int

const (
	// A pull request a run names that was not read.
	NeedPullRequest NeedKind = iota + 1
	// The pull request merged into a commit on the default branch.
	NeedCommit
	// The pull request of a run from a fork.
	NeedHead
)

// Need is one lookup the runs need; Key is what its answer is kept under.
type Need struct {
	Kind      NeedKind
	Key       string
	Number    int64
	SHA       string
	HeadOwner string
	Branch    string
}

// Missing lists up to max lookups, newest run first, that were not asked
// before.
func Missing(in Input, a Analysis, max int) []Need {
	ix := newIndex(in.PullRequests)
	var out []Need
	seen := map[string]bool{}
	add := func(need Need) {
		if _, asked := in.Lookups[need.Key]; asked || seen[need.Key] || len(out) >= max {
			return
		}
		seen[need.Key] = true
		out = append(out, need)
	}
	for _, r := range in.Runs {
		if len(out) >= max {
			break
		}
		for _, number := range r.PullRequests {
			if _, read := ix.byNumber[number]; !read {
				add(Need{Kind: NeedPullRequest, Key: fmt.Sprintf("pr:%d", number), Number: number})
			}
		}
		if a.Links[r.ID].Kind != LinkNone {
			continue
		}
		switch {
		case !isPullRequestEvent(r.Event) && in.DefaultBranch != "" && r.Branch == in.DefaultBranch && r.HeadSHA != "":
			add(Need{Kind: NeedCommit, Key: "commit:" + r.HeadSHA, SHA: r.HeadSHA})
		case r.Event == "pull_request" && github.OtherRepository(r.HeadRepository, in.Repository) && r.Branch != "":
			owner, _, _ := strings.Cut(r.HeadRepository, "/")
			add(Need{Kind: NeedHead, Key: headKey(r.HeadRepository, r.Branch), HeadOwner: owner, Branch: r.Branch})
		}
	}
	return out
}
