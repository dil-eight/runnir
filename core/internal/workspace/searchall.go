package workspace

import (
	"context"
	"strings"
	"sync"
	"time"

	"runnir/core/internal/changes"
	"runnir/core/internal/github"
	"runnir/core/internal/runsearch"
	"runnir/core/internal/store"
)

// DefaultKindLimit and MaxKindLimit bound the hits of one kind, per workspace.
const (
	DefaultKindLimit = 8
	MaxKindLimit     = 50
)

// WorkspaceHits is what a search over this Mac's saved data found in one
// workspace.
type WorkspaceHits struct {
	WorkspaceID string
	// Open: answered from the live store; otherwise the database was read
	// from disk as it was left.
	Open bool
	// Repository is "owner/name" of the cache, "" when nothing was saved.
	Repository string
	// SavedAt is when the saved data was last read from GitHub; zero for never.
	SavedAt time.Time
	// Problem says why the workspace could not be searched, "" when it was.
	Problem string

	Runs                []github.Run
	RunsMatched         int
	PullRequests        []github.RepositoryPullRequest
	PullRequestsMatched int
	Workflows           []github.Workflow
	WorkflowsMatched    int
	LocalRuns           []store.LocalRun
	LocalRunsMatched    int
}

// SearchAll searches the saved runs, pull requests, workflows and local runs
// of the named workspaces, all of them when none are named. It reads what is
// on this Mac and sends nothing to GitHub: an open workspace answers from its
// store, a closed one from its database opened read-only, without a lock.
// The workspaces are read in parallel; results keep the order of ids.
func (m *Runtimes) SearchAll(ctx context.Context, requested []string, text string, perKind int) ([]WorkspaceHits, error) {
	ids, err := m.ids(requested)
	if err != nil {
		return nil, err
	}
	if perKind <= 0 {
		perKind = DefaultKindLimit
	}
	perKind = min(perKind, MaxKindLimit)
	q := runsearch.Parse(text)
	out := make([]WorkspaceHits, len(ids))
	if !q.Active() {
		for i, id := range ids {
			out[i] = WorkspaceHits{WorkspaceID: id}
		}
		return out, nil
	}
	var wg sync.WaitGroup
	sem := make(chan struct{}, 4)
	for i, id := range ids {
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			out[i] = m.searchWorkspace(ctx, id, q, perKind)
		}()
	}
	wg.Wait()
	return out, ctx.Err()
}

func (m *Runtimes) searchWorkspace(ctx context.Context, id string, q runsearch.Query, perKind int) WorkspaceHits {
	hits := WorkspaceHits{WorkspaceID: id}
	rt, release := m.claim(id)
	defer release()
	var st *store.Store
	if rt != nil {
		st, hits.Open = rt.cfg.store, true
	} else {
		if m.opts.DataDir == "" {
			return hits
		}
		opened, ok, err := store.OpenReadOnly(m.dir(id))
		if err != nil {
			hits.Problem = "Its saved data could not be read now; it is checked when the workspace opens."
			return hits
		}
		if !ok {
			return hits
		}
		defer opened.Close()
		st = opened
	}
	if err := searchStore(ctx, st, q, perKind, m.now(), &hits); err != nil {
		hits.Problem = "Its saved data could not be searched."
	}
	return hits
}

func searchStore(ctx context.Context, st *store.Store, q runsearch.Query, perKind int, now time.Time, hits *WorkspaceHits) error {
	a, err := st.Activity(ctx, store.MaxRuns)
	if err != nil {
		return err
	}
	hits.SavedAt = a.SyncedAt
	if a.HasSource {
		hits.Repository = a.Source.Repository
		analysis := changes.Analyze(changes.Input{
			Runs: a.Runs, PullRequests: a.PullRequests, Lookups: a.Lookups, DefaultBranch: a.DefaultBranch,
			Repository: a.Source.Repository, Now: now,
		})
		found, err := searchSaved(ctx, st, q, perKind, savedData{
			Source: a.Source, HasSource: true, Runs: a.Runs, PullRequests: a.PullRequests,
			LinkedPullRequest: func(id int64) int64 { return analysis.Links[id].PullRequest },
		})
		if err != nil {
			return err
		}
		hits.RunsMatched = len(found.CachedRuns) + len(found.Indexed)
		hits.Runs = append(append(hits.Runs, found.CachedRuns...), found.Indexed...)
		if len(hits.Runs) > perKind {
			hits.Runs = hits.Runs[:perKind]
		}
		for _, p := range a.PullRequests {
			if q.MatchFields(p.Number, p.Title, p.Author, p.HeadRef, p.BaseRef) {
				hits.PullRequestsMatched++
				if len(hits.PullRequests) < perKind {
					hits.PullRequests = append(hits.PullRequests, p)
				}
			}
		}
		for _, w := range a.Workflows {
			if q.MatchFields(0, w.Name, w.Path) {
				hits.WorkflowsMatched++
				if len(hits.Workflows) < perKind {
					hits.Workflows = append(hits.Workflows, w)
				}
			}
		}
	}
	local, err := st.LocalRuns(ctx, 200)
	if err != nil {
		return err
	}
	for _, r := range local {
		if q.MatchFields(0, r.WorkflowPath, r.JobID, r.Event, r.State, strings.TrimSpace(r.Message)) {
			hits.LocalRunsMatched++
			if len(hits.LocalRuns) < perKind {
				hits.LocalRuns = append(hits.LocalRuns, r)
			}
		}
	}
	return nil
}
