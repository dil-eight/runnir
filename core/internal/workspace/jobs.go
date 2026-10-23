package workspace

import (
	"context"
	"fmt"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
)

// Jobs returns a run's jobs: from the cache when they cannot have changed
// since they were read (a finished run's jobs read after its last update)
// or were read moments ago; otherwise read once for every caller asking at
// the same time.
func (r *Runtime) Jobs(ctx context.Context, runID int64) ([]github.Job, corev1.GithubAccess, time.Time, error) {
	r.mu.Lock()
	resolve := r.resolve
	r.mu.Unlock()
	target, problem := resolve()
	if problem != corev1.GithubAccess_GITHUB_ACCESS_OK {
		return nil, problem, time.Time{}, nil
	}
	if jobs, ok := r.cachedJobs(ctx, runID, target); ok {
		return jobs, corev1.GithubAccess_GITHUB_ACCESS_OK, time.Time{}, nil
	}
	ch := r.flights.DoChan(fmt.Sprintf("jobs:%d", runID), func() (any, error) {
		fetchCtx, cancel := context.WithTimeout(r.ctx, r.cfg.intervals.FetchTimeout)
		defer cancel()
		jobs, err := target.Account.Client.Jobs(fetchCtx, target.Owner, target.Name, runID)
		if err != nil {
			return nil, err
		}
		if run, known, _ := r.cfg.store.Run(r.ctx, runID); known {
			_ = r.cfg.store.PutJobs(r.ctx, runID, run.RunAttempt, r.cfg.now(), jobs)
		}
		return jobs, nil
	})
	select {
	case result := <-ch:
		if result.Err != nil {
			access, retry, cancelled := Access(target.Account, result.Err)
			if cancelled != nil {
				if ctx.Err() != nil {
					return nil, 0, time.Time{}, ctx.Err()
				}
				access = corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE
			}
			return nil, access, retry, nil
		}
		return result.Val.([]github.Job), corev1.GithubAccess_GITHUB_ACCESS_OK, time.Time{}, nil
	case <-ctx.Done():
		return nil, 0, time.Time{}, ctx.Err()
	}
}

func (r *Runtime) cachedJobs(ctx context.Context, runID int64, target Target) ([]github.Job, bool) {
	source, has, err := r.cfg.store.CacheSource(ctx)
	if err != nil || !has || source != target.Source() {
		return nil, false
	}
	cached, ok, err := r.cfg.store.Jobs(ctx, runID)
	if err != nil || !ok {
		return nil, false
	}
	if r.cfg.now().Sub(cached.FetchedAt) < r.cfg.intervals.JobsReuse {
		return cached.Jobs, true
	}
	run, known, err := r.cfg.store.Run(ctx, runID)
	if err != nil || !known {
		return nil, false
	}
	if run.Status == "completed" && cached.Attempt == run.RunAttempt && !cached.FetchedAt.Before(run.UpdatedAt) {
		return cached.Jobs, true
	}
	return nil, false
}
