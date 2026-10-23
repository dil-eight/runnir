package workspace

import (
	"context"
	"fmt"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

// CompletedJob returns a cached job that has finished, so its log can be
// read without asking GitHub for the job again. Only jobs cached for the
// repository the origin points at now are used.
func (r *Runtime) CompletedJob(ctx context.Context, jobID int64) (github.Job, bool) {
	r.mu.Lock()
	resolve := r.resolve
	r.mu.Unlock()
	target, problem := resolve()
	source, has, err := r.cfg.store.CacheSource(ctx)
	if problem != corev1.GithubAccess_GITHUB_ACCESS_OK || err != nil || !has || source != target.Source() {
		return github.Job{}, false
	}
	job, ok, err := r.cfg.store.Job(ctx, jobID)
	if err != nil || !ok || job.Status != "completed" {
		return github.Job{}, false
	}
	return job, true
}

// KeptLog returns a log kept on this Mac, while keeping logs is on.
func (r *Runtime) KeptLog(ctx context.Context, jobID int64) ([]byte, store.LogMeta, bool) {
	if !r.cfg.keepLogs() {
		return nil, store.LogMeta{}, false
	}
	data, meta, ok, err := r.cfg.store.Log(ctx, jobID)
	return data, meta, ok && err == nil
}

// KeepLog stores a completed job's log, while keeping logs is on.
func (r *Runtime) KeepLog(ctx context.Context, jobID int64, data []byte, meta store.LogMeta) {
	if r.cfg.keepLogs() {
		_ = r.cfg.store.PutLog(ctx, jobID, data, meta)
	}
}

// SharedLog runs one download per job for every caller asking at the same
// time. The download runs on the runtime's context with timeout, so a
// caller giving up does not cancel it for the others.
func (r *Runtime) SharedLog(ctx context.Context, jobID int64, timeout time.Duration, fetch func(context.Context) (github.JobLog, error)) (github.JobLog, error) {
	ch := r.flights.DoChan(fmt.Sprintf("log:%d", jobID), func() (any, error) {
		fetchCtx, cancel := context.WithTimeout(r.ctx, timeout)
		defer cancel()
		return fetch(fetchCtx)
	})
	select {
	case result := <-ch:
		if result.Err != nil {
			return github.JobLog{}, result.Err
		}
		return result.Val.(github.JobLog), nil
	case <-ctx.Done():
		return github.JobLog{}, ctx.Err()
	}
}
