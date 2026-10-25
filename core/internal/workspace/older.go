package workspace

import (
	"context"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/store"
)

// olderPage is how many runs LoadOlderRuns reads.
const olderPage = 100

// OlderRuns is what LoadOlderRuns did.
type OlderRuns struct {
	Access          corev1.GithubAccess
	RetryAfter      time.Time
	Added           int
	HistoryComplete bool
	// The cache holds store.MaxRuns runs; older ones stay on GitHub.
	BudgetReached bool
}

// LoadOlderRuns reads one page of runs older than the oldest cached one and
// stores it. Concurrent calls share one request.
func (r *Runtime) LoadOlderRuns(ctx context.Context) (OlderRuns, error) {
	select {
	case <-r.loopDone:
		return OlderRuns{}, ErrClosed
	default:
	}
	ch := r.flights.DoChan("older", func() (any, error) { return r.loadOlder() })
	select {
	case result := <-ch:
		if result.Err != nil {
			return OlderRuns{}, result.Err
		}
		return result.Val.(OlderRuns), nil
	case <-ctx.Done():
		return OlderRuns{}, ctx.Err()
	}
}

func (r *Runtime) loadOlder() (OlderRuns, error) {
	r.mu.Lock()
	resolve := r.resolve
	r.mu.Unlock()
	target, problem := resolve()
	if problem != corev1.GithubAccess_GITHUB_ACCESS_OK {
		return OlderRuns{Access: problem}, nil
	}
	source := target.Source()
	history, ok, err := r.cfg.store.History(r.ctx, source)
	if err != nil {
		return OlderRuns{}, err
	}
	result := OlderRuns{Access: corev1.GithubAccess_GITHUB_ACCESS_OK}
	switch {
	case !ok: // nothing cached yet: the sync pass reads the newest runs first
		return result, nil
	case history.Count >= store.MaxRuns:
		result.BudgetReached = true
		return result, nil
	case history.Complete:
		result.HistoryComplete = true
		return result, nil
	}
	fetchCtx, cancel := context.WithTimeout(r.ctx, r.cfg.intervals.FetchTimeout)
	defer cancel()
	runs, err := target.Account.Client.OlderRuns(fetchCtx, target.Owner, target.Name, history.Oldest, olderPage)
	if err != nil {
		access, retry, cancelled := Access(target.Account, err)
		if cancelled != nil {
			access = corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE
		}
		return OlderRuns{Access: access, RetryAfter: retry}, nil
	}
	complete := len(runs) < olderPage
	added, err := r.cfg.store.AddOlderRuns(r.ctx, source, history.Oldest, runs, complete)
	if err != nil {
		return OlderRuns{}, err
	}
	result.Added, result.HistoryComplete = added, complete
	result.BudgetReached = history.Count+added >= store.MaxRuns
	if added > 0 || complete {
		r.publish()
	}
	return result, nil
}
