package workspace

import (
	"context"
	"errors"
	"strings"
	"time"

	"runnir/core/internal/changes"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

const (
	// maxGapPages bounds the older pages of 100 a pass reads to reach the
	// cached runs.
	maxGapPages = 10
	// maxLookups bounds the lookup requests of one pass.
	maxLookups = 10
)

// input is the cache as the changes package reads it.
func input(a store.Activity, target Target, now time.Time) changes.Input {
	return changes.Input{
		Runs: a.Runs, PullRequests: a.PullRequests, Lookups: a.Lookups, DefaultBranch: a.DefaultBranch,
		Repository:    strings.ToLower(target.Owner + "/" + target.Name),
		RepositoryURL: "https://" + target.Account.Server.WebHost + "/" + target.Owner + "/" + target.Name,
		Now:           now,
	}
}

// fillGap reads older pages until the newest runs reach the cached ones.
// When they never do, the update starts the history again from them.
func (r *Runtime) fillGap(client *github.Client, target Target, u *store.RunsUpdate) error {
	newest, cached, err := r.cfg.store.Newest(r.ctx, target.Source())
	if err != nil || !cached {
		return err
	}
	seen := make(map[int64]bool, len(u.Runs))
	for _, run := range u.Runs {
		seen[run.ID] = true
	}
	for page := 0; ; page++ {
		oldest := u.Runs[len(u.Runs)-1].CreatedAt
		if !oldest.After(newest) {
			return nil
		}
		if page == maxGapPages {
			u.Restart = true
			return nil
		}
		more, err := client.OlderRuns(r.ctx, target.Owner, target.Name, oldest, 100)
		if err != nil {
			return err
		}
		added := 0
		for _, run := range more {
			if !seen[run.ID] {
				seen[run.ID] = true
				u.Runs = append(u.Runs, run)
				added++
			}
		}
		if len(more) < 100 {
			u.Complete = true
			return nil
		}
		if added == 0 { // GitHub keeps answering the same runs
			u.Restart = true
			return nil
		}
	}
}

// lookUp asks GitHub for at most maxLookups pull requests the cached runs
// miss, and stores the answers. A refusal stops pull request reads like a
// refused list.
func (r *Runtime) lookUp(target Target) {
	r.mu.Lock()
	refused := r.pullsRefused
	r.mu.Unlock()
	if refused {
		return
	}
	source := target.Source()
	a, err := r.cfg.store.Activity(r.ctx, store.MaxRuns)
	if err != nil || !a.HasSource || a.Source != source {
		return
	}
	in := input(a, target, r.cfg.now())
	needs := changes.Missing(in, changes.Analyze(in), maxLookups)
	if len(needs) == 0 {
		return
	}
	update := store.LookupsUpdate{Source: source, At: r.cfg.now()}
	for _, need := range needs {
		lookup, err := lookUpOne(r.ctx, target, need)
		if err != nil {
			if errors.Is(err, github.ErrPermissionMissing) {
				access, _, _ := Access(target.Account, err)
				update.Access = int32(access)
				r.refusePulls()
			}
			break
		}
		update.Lookups = append(update.Lookups, lookup)
	}
	_, _ = r.cfg.store.ApplyLookups(r.ctx, update)
}

func lookUpOne(ctx context.Context, target Target, need changes.Need) (store.Lookup, error) {
	client := target.Account.Client
	lookup := store.Lookup{Key: need.Key, Numbers: []int64{}}
	var found []github.RepositoryPullRequest
	var err error
	switch need.Kind {
	case changes.NeedPullRequest:
		var pr github.RepositoryPullRequest
		if pr, err = client.RepositoryPull(ctx, target.Owner, target.Name, need.Number); err == nil {
			found = []github.RepositoryPullRequest{pr}
		}
	case changes.NeedCommit:
		var prs []github.RepositoryPullRequest
		if prs, err = client.CommitPullRequests(ctx, target.Owner, target.Name, need.SHA); err == nil {
			// The commit is in other pull requests too (one from main, say):
			// only the one whose merge created it counts.
			for _, pr := range prs {
				if pr.MergeCommitSHA == need.SHA {
					found = append(found, pr)
				}
			}
		}
	case changes.NeedHead:
		found, err = client.HeadPullRequests(ctx, target.Owner, target.Name, need.HeadOwner, need.Branch)
	}
	var rejected *github.RejectedError
	switch {
	case errors.Is(err, github.ErrNotVisible), errors.As(err, &rejected):
		// No such pull request, or GitHub does not know the commit any
		// more: remembered as nothing found.
		return lookup, nil
	case err != nil:
		return store.Lookup{}, err
	}
	for _, pr := range found {
		lookup.Numbers = append(lookup.Numbers, pr.Number)
	}
	lookup.PullRequests = found
	return lookup, nil
}
