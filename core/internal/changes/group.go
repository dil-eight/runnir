package changes

import (
	"fmt"
	"time"

	"runnir/core/internal/github"
)

type SectionKind int

const (
	SectionAfterMerge SectionKind = iota + 1
	SectionLatestCommit
	SectionCommit
)

// Section is a change's runs on one commit.
type Section struct {
	Kind        SectionKind
	HeadSHA     string
	Branch      string
	CommitTitle string
	// RunIDs: the newest run of each workflow and event, newest first.
	RunIDs []int64
	// RepeatRunIDs: the other runs of those workflows and events here.
	RepeatRunIDs []int64
}

// PullRequest is what a change shows of its pull request.
type PullRequest struct {
	Number int64
	Title  string
	// "open", "closed" or "merged"; "" when it was not read yet.
	State      string
	Draft      bool
	Author     string
	HTMLURL    string
	HeadBranch string
	BaseBranch string
	MergedAt   time.Time
}

// Change is a pull request with every run linked to it, or a commit with
// the runs that have no link.
type Change struct {
	ID          string
	PullRequest *PullRequest
	// Status of the first section with runs, summed up like the menu bar's.
	Status   github.CIState
	LatestAt time.Time
	// After merge, then the latest commit; a commit has one section.
	Sections []Section
	// Runs on older commits of the pull request, newest first.
	OlderRunIDs  []int64
	OlderCommits int
}

// Group builds the changes of window (newest first), the runs a caller
// shows, newest change first.
func Group(in Input, a Analysis, window []github.Run) []Change {
	ix := newIndex(in.PullRequests)
	byID := make(map[int64]github.Run, len(window))
	var order []string
	members := map[string][]github.Run{}
	for _, r := range window {
		byID[r.ID] = r
		id := "commit:" + r.HeadSHA
		if link := a.Links[r.ID]; link.Kind != LinkNone {
			id = fmt.Sprintf("pr:%d", link.PullRequest)
		}
		if _, seen := members[id]; !seen {
			order = append(order, id)
		}
		members[id] = append(members[id], r)
	}
	out := make([]Change, 0, len(order))
	for _, id := range order {
		runs := members[id]
		change := Change{ID: id, LatestAt: runs[0].CreatedAt}
		if link := a.Links[runs[0].ID]; link.Kind != LinkNone {
			change.PullRequest = pullRequest(ix, in, link.PullRequest, runs)
			change.Sections, change.OlderRunIDs, change.OlderCommits = pullSections(runs, a, ix.byNumber[link.PullRequest])
		} else {
			change.Sections = []Section{section(SectionCommit, runs)}
		}
		change.Status = github.CINone
		for _, s := range change.Sections {
			if len(s.RunIDs) == 0 {
				continue
			}
			shown := make([]github.Run, 0, len(s.RunIDs))
			for _, runID := range s.RunIDs {
				shown = append(shown, byID[runID])
			}
			change.Status = github.SummarizeRuns(shown).State
			break
		}
		out = append(out, change)
	}
	return out
}

func pullSections(runs []github.Run, a Analysis, pr github.RepositoryPullRequest) ([]Section, []int64, int) {
	var merged, onPull []github.Run
	for _, r := range runs {
		if a.Links[r.ID].Kind == LinkAfterMerge {
			merged = append(merged, r)
		} else {
			onPull = append(onPull, r)
		}
	}
	var sections []Section
	if len(merged) > 0 {
		sections = append(sections, section(SectionAfterMerge, merged))
	}
	if len(onPull) == 0 {
		return sections, nil, 0
	}
	latest := onPull[0].HeadSHA
	for _, r := range onPull {
		if pr.HeadSHA != "" && r.HeadSHA == pr.HeadSHA {
			latest = pr.HeadSHA
			break
		}
	}
	var current []github.Run
	var older []int64
	commits := map[string]bool{}
	for _, r := range onPull {
		if r.HeadSHA == latest {
			current = append(current, r)
			continue
		}
		older = append(older, r.ID)
		commits[r.HeadSHA] = true
	}
	return append(sections, section(SectionLatestCommit, current)), older, len(commits)
}

func section(kind SectionKind, runs []github.Run) Section {
	s := Section{Kind: kind, HeadSHA: runs[0].HeadSHA, Branch: runs[0].Branch, CommitTitle: runs[0].CommitTitle}
	seen := map[string]bool{}
	for _, r := range runs {
		key := fmt.Sprintf("%d/%s", r.WorkflowID, r.Event)
		if seen[key] {
			s.RepeatRunIDs = append(s.RepeatRunIDs, r.ID)
			continue
		}
		seen[key] = true
		s.RunIDs = append(s.RunIDs, r.ID)
	}
	return s
}

func pullRequest(ix index, in Input, number int64, runs []github.Run) *PullRequest {
	if p, ok := ix.byNumber[number]; ok {
		state := p.State
		if !p.MergedAt.IsZero() {
			state = "merged"
		}
		return &PullRequest{Number: number, Title: p.Title, State: state, Draft: p.Draft, Author: p.Author, HTMLURL: p.HTMLURL,
			HeadBranch: p.HeadRef, BaseBranch: p.BaseRef, MergedAt: p.MergedAt}
	}
	out := &PullRequest{Number: number}
	if in.RepositoryURL != "" {
		out.HTMLURL = fmt.Sprintf("%s/pull/%d", in.RepositoryURL, number)
	}
	for _, r := range runs {
		if r.Event == "pull_request" && r.DisplayTitle != "" {
			out.Title, out.HeadBranch = r.DisplayTitle, r.Branch
			break
		}
	}
	return out
}
