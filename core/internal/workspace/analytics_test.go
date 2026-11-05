//go:build !windows

package workspace

import (
	"context"
	"net/http"
	"sync"
	"testing"
	"time"

	"runnir/core/internal/analytics"
	"runnir/core/internal/events"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/localrun"
	"runnir/core/internal/store"
)

var t0 = time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)

func job(name string, state localrun.JobState, seconds int) localrun.JobStatus {
	return localrun.JobStatus{ID: name, Name: name, State: state, StartedAt: t0, FinishedAt: t0.Add(time.Duration(seconds) * time.Second)}
}

var (
	localRunFailed    = analytics.UsageCounter(corev1.UsageEvent_USAGE_EVENT_ASYNC_LOCAL_RUN_FAILED)
	localRunCancelled = analytics.UsageCounter(corev1.UsageEvent_USAGE_EVENT_ASYNC_LOCAL_RUN_CANCELLED)
	localRunSucceeded = analytics.UsageCounter(corev1.UsageEvent_USAGE_EVENT_ASYNC_LOCAL_RUN_SUCCEEDED)
)

func TestLocalRunCountsCompareWithGitHub(t *testing.T) {
	st, err := store.Open(t.TempDir(), store.Options{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ctx := context.Background()
	gh := github.Run{ID: 7, WorkflowID: 3, Name: "CI", RunNumber: 1, RunAttempt: 1, Event: "push", Status: "completed",
		Conclusion: "success", Branch: "main", HeadSHA: "abc", CreatedAt: t0.Add(-time.Hour), UpdatedAt: t0.Add(-time.Hour + 10*time.Minute)}
	if _, err := st.ApplySync(ctx, store.Pass{Source: store.Source{Repository: "o/r"}, At: t0, OK: true, Access: 1,
		Runs:      &store.RunsUpdate{Runs: []github.Run{gh}, Complete: true},
		Workflows: &store.WorkflowsUpdate{Workflows: []github.Workflow{{ID: 3, Name: "CI", Path: ".github/workflows/ci.yml", State: "active"}}}}); err != nil {
		t.Fatal(err)
	}
	if err := st.PutJobs(ctx, 7, 1, t0, []github.Job{{ID: 70, Name: "lint", Status: "completed", Conclusion: "success",
		StartedAt: t0.Add(-time.Hour), CompletedAt: t0.Add(-time.Hour + 4*time.Minute + time.Second)}}); err != nil {
		t.Fatal(err)
	}

	summary := localrun.Summary{WorkflowID: ".github/workflows/ci.yml", WholeWorkflow: true, StartedAt: t0, FinishedAt: t0.Add(150 * time.Second),
		Jobs: []localrun.JobStatus{job("lint", localrun.JobSucceeded, 61), job("test", localrun.JobFailed, 120),
			job("deploy", localrun.JobCancelled, 5), {ID: "macos", Name: "macos", State: localrun.JobUnsupported}}}
	got := localRunCounts(ctx, st, summary, store.LocalFailed, true, 4)
	want := analytics.Counts{
		localRunFailed:      1,
		analytics.LocalRuns: 1, analytics.LocalBilledMinutes: 4,
		// ci.yml has no workflow_dispatch here: GitHub could not start it by hand.
		analytics.LocalRunsWithoutDispatch: 1, analytics.LocalBilledMinutesWithoutDispatch: 4,
		analytics.LocalJobsSucceeded: 1, analytics.LocalJobsFailed: 1, analytics.LocalJobsCancelled: 1,
		analytics.LocalJobSeconds: 186,
		// lint: 4m 1s on GitHub → 5; locally 1m 1s → 2.
		analytics.GHRefJobsMatched: 1, analytics.GHRefBilledMinutes: 5, analytics.LocalBilledMinutesMatched: 2,
		analytics.LocalRunsCompleted: 1, analytics.LocalRunWallSeconds: 150,
		analytics.GHRefRunsMatched: 1, analytics.GHRefRunWallSeconds: 600,
	}
	if len(got) != len(want) {
		t.Fatalf("counts = %+v, want %+v", got, want)
	}
	for name, value := range want {
		if got[name] != value {
			t.Fatalf("%s = %d, want %d (all: %+v)", name, got[name], value, got)
		}
	}
	// A workflow GitHub can start by hand has no without-dispatch counts.
	summary.Dispatchable = true
	if got := localRunCounts(ctx, st, summary, store.LocalFailed, true, 4); got[analytics.LocalRunsWithoutDispatch] != 0 ||
		got[analytics.LocalBilledMinutesWithoutDispatch] != 0 || got[analytics.LocalBilledMinutes] != 4 {
		t.Fatalf("dispatchable = %+v", got)
	}
	// One job of a workflow, cancelled, nothing saved: only its jobs and its end count.
	one := localrun.Summary{WorkflowID: ".github/workflows/ci.yml", Jobs: []localrun.JobStatus{job("lint", localrun.JobCancelled, 3)}}
	if got := localRunCounts(ctx, st, one, store.LocalCancelled, false, 0); len(got) != 3 ||
		got[analytics.LocalJobsCancelled] != 1 || got[localRunCancelled] != 1 {
		t.Fatalf("one cancelled job = %+v", got)
	}
	// An interrupted run is no usage event.
	if got := localRunCounts(ctx, st, one, store.LocalInterrupted, false, 0); got[localRunCancelled] != 0 {
		t.Fatalf("interrupted = %+v", got)
	}
}

func TestFinishedLocalRunsAreCountedForAnalytics(t *testing.T) {
	_, accounts := newFake(t)
	var mu sync.Mutex
	var counted []analytics.Counts
	m := New(Options{DataDir: t.TempDir(), Intervals: testIntervals(),
		BilledMinutes: func(string) int64 { return 2 },
		RunSummary: func(id string) (localrun.Summary, bool) {
			return localrun.Summary{WorkflowID: ".github/workflows/x.yml", Jobs: []localrun.JobStatus{job("a", localrun.JobSucceeded, 70)}}, id == "exec_1"
		},
		Analytics: func(_ time.Time, c analytics.Counts) { mu.Lock(); counted = append(counted, c); mu.Unlock() }})
	t.Cleanup(m.Shutdown)
	if _, err := m.Attach(wsA, "repo_1", fixedResolver(accounts, "o", "r")); err != nil {
		t.Fatal(err)
	}
	m.RecordLocalRun("repo_1", store.LocalRun{ExecutionID: "exec_1", StartedAt: t0, State: store.LocalQueued})
	m.ObserveExecution(events.Event{ExecutionID: "exec_1", ExecutionState: corev1.ExecutionState_EXECUTION_STATE_SUCCEEDED, At: t0})
	m.ObserveExecution(events.Event{ExecutionID: "exec_1", ExecutionState: corev1.ExecutionState_EXECUTION_STATE_SUCCEEDED, At: t0})
	m.recorder.flush()
	mu.Lock()
	defer mu.Unlock()
	if len(counted) != 1 || counted[0][analytics.LocalRuns] != 1 || counted[0][analytics.LocalBilledMinutes] != 2 ||
		counted[0][analytics.LocalJobsSucceeded] != 1 || counted[0][analytics.LocalJobSeconds] != 70 || counted[0][localRunSucceeded] != 1 {
		t.Fatalf("counted = %+v, want one run once", counted)
	}
}

func TestFailedPassesAreCountedOncePerOutcome(t *testing.T) {
	fake, accounts := newFake(t)
	var mu sync.Mutex
	counted := analytics.Counts{}
	r := startRuntimeWith(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil, func(c *config) {
		c.analytics = func(_ time.Time, counts analytics.Counts) {
			mu.Lock()
			defer mu.Unlock()
			for name, value := range counts {
				counted[name] += value
			}
		}
	})
	waitRefresh(t, r)
	fake.set(func(f *fakeGitHub) { f.status = http.StatusServiceUnavailable })
	waitRefresh(t, r)
	waitRefresh(t, r)
	fake.set(func(f *fakeGitHub) { f.status = http.StatusUnauthorized })
	waitRefresh(t, r)
	mu.Lock()
	defer mu.Unlock()
	failed := analytics.UsageCounter(corev1.UsageEvent_USAGE_EVENT_ASYNC_GITHUB_SYNC_FAILED)
	rejected := analytics.UsageCounter(corev1.UsageEvent_USAGE_EVENT_ASYNC_GITHUB_TOKEN_REJECTED)
	if counted[failed] != 1 || counted[rejected] != 1 || len(counted) != 2 {
		t.Fatalf("counted = %+v, want one failure and one rejection", counted)
	}
}
