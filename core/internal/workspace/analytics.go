package workspace

import (
	"context"
	"time"

	"runnir/core/internal/analytics"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/localrun"
	"runnir/core/internal/store"
)

// localRunEnds are the async usage events of a local run's end; an
// interrupted run (the Core stopped) has none.
var localRunEnds = map[string]corev1.UsageEvent{
	store.LocalSucceeded: corev1.UsageEvent_USAGE_EVENT_ASYNC_LOCAL_RUN_SUCCEEDED,
	store.LocalFailed:    corev1.UsageEvent_USAGE_EVENT_ASYNC_LOCAL_RUN_FAILED,
	store.LocalCancelled: corev1.UsageEvent_USAGE_EVENT_ASYNC_LOCAL_RUN_CANCELLED,
}

// syncFailures are the async usage events of a pass GitHub did not answer
// with the activity.
var syncFailures = map[corev1.GithubAccess]corev1.UsageEvent{
	corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE:    corev1.UsageEvent_USAGE_EVENT_ASYNC_GITHUB_SYNC_FAILED,
	corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED:   corev1.UsageEvent_USAGE_EVENT_ASYNC_GITHUB_RATE_LIMITED,
	corev1.GithubAccess_GITHUB_ACCESS_TOKEN_REJECTED: corev1.UsageEvent_USAGE_EVENT_ASYNC_GITHUB_TOKEN_REJECTED,
}

// countSyncOutcome counts a pass that reached for GitHub and failed, once
// when the outcome changes: a Mac offline for hours is one failure, not
// one per retry.
func (r *Runtime) countSyncOutcome(previous, access corev1.GithubAccess) {
	event, failed := syncFailures[access]
	if !failed || access == previous || r.cfg.analytics == nil {
		return
	}
	r.cfg.analytics(r.cfg.now(), analytics.Counts{analytics.UsageCounter(event): 1})
}

// localRunCounts are a finished local run's counters (the metrics table of
// the analytics spec): its minute counters, and its end as a usage event,
// which the ledger keeps only at Full. saved and billed are B31's: whether
// the run was added to the Saved total, and with how many minutes. Only
// names and durations are read; nothing of the repository is counted.
func localRunCounts(ctx context.Context, st *store.Store, s localrun.Summary, state string, saved bool, billed int64) analytics.Counts {
	c := analytics.Counts{}
	if end, ok := localRunEnds[state]; ok {
		c[analytics.UsageCounter(end)] = 1
	}
	if saved {
		c[analytics.LocalRuns], c[analytics.LocalBilledMinutes] = 1, billed
		if !s.Dispatchable {
			c[analytics.LocalRunsWithoutDispatch], c[analytics.LocalBilledMinutesWithoutDispatch] = 1, billed
		}
	}
	var ended []localrun.JobStatus
	var names []string
	for _, job := range s.Jobs {
		switch job.State {
		case localrun.JobSucceeded:
			c[analytics.LocalJobsSucceeded]++
		case localrun.JobFailed:
			c[analytics.LocalJobsFailed]++
		case localrun.JobCancelled:
			c[analytics.LocalJobsCancelled]++
		default:
			continue
		}
		if job.StartedAt.IsZero() || job.FinishedAt.Before(job.StartedAt) {
			continue
		}
		c[analytics.LocalJobSeconds] += int64(job.FinishedAt.Sub(job.StartedAt) / time.Second)
		if job.State != localrun.JobCancelled {
			ended = append(ended, job)
			names = append(names, job.Name)
		}
	}
	if refs, err := st.JobReferences(ctx, s.WorkflowID, names); err == nil {
		for _, job := range ended {
			if ref, ok := refs[job.Name]; ok {
				c[analytics.GHRefJobsMatched]++
				c[analytics.GHRefBilledMinutes] += localrun.BilledJobMinutes(ref)
				c[analytics.LocalBilledMinutesMatched] += localrun.BilledJobMinutes(job.FinishedAt.Sub(job.StartedAt))
			}
		}
	}
	ran := (state == store.LocalSucceeded || state == store.LocalFailed) && s.WholeWorkflow &&
		!s.StartedAt.IsZero() && !s.FinishedAt.Before(s.StartedAt)
	if ran {
		c[analytics.LocalRunsCompleted]++
		c[analytics.LocalRunWallSeconds] += int64(s.FinishedAt.Sub(s.StartedAt) / time.Second)
		if wall, ok, err := st.RunReference(ctx, s.WorkflowID); err == nil && ok {
			c[analytics.GHRefRunsMatched]++
			c[analytics.GHRefRunWallSeconds] += int64(wall / time.Second)
		}
	}
	for name, value := range c {
		if value == 0 {
			delete(c, name)
		}
	}
	return c
}
