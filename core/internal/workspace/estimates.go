package workspace

import (
	"context"
	"slices"
	"time"

	"runnir/core/internal/analytics"
	"runnir/core/internal/changes"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

// medianDuration is the median time from creation to last update of the
// workflow's newest 20 successful runs; runs are newest first.
func medianDuration(runs []github.Run, workflowID int64) (time.Duration, bool) {
	var durations []time.Duration
	for _, r := range runs {
		if r.WorkflowID != workflowID || r.Status != "completed" || r.Conclusion != "success" || r.UpdatedAt.Before(r.CreatedAt) {
			continue
		}
		durations = append(durations, r.UpdatedAt.Sub(r.CreatedAt))
		if len(durations) == 20 {
			break
		}
	}
	if len(durations) == 0 {
		return 0, false
	}
	slices.Sort(durations)
	return durations[len(durations)/2], true
}

// estimateMinutes is what was left of a typical run when one stopped after
// ran, rounded up; never below zero.
func estimateMinutes(median, ran time.Duration) int64 {
	left := median - ran
	if left <= 0 {
		return 0
	}
	return int64((left + time.Minute - 1) / time.Minute)
}

// cancelEstimate says whether a run is superseded and, if so, the minutes
// cancelling it at now saves.
func cancelEstimate(runs []github.Run, superseded map[int64]int64, runID int64, now time.Time) (bool, int64) {
	if superseded[runID] == 0 {
		return false, 0
	}
	for _, r := range runs {
		if r.ID != runID {
			continue
		}
		if median, ok := medianDuration(runs, r.WorkflowID); ok {
			return true, estimateMinutes(median, now.Sub(r.CreatedAt))
		}
		break
	}
	return true, 0
}

type concurrencyCancel struct {
	RunID   int64
	Minutes int64
}

// concurrencyCancels finds runs the block this Mac saved cancelled: runs of
// that workflow created after the save that GitHub ended cancelled while
// superseded.
func concurrencyCancels(saves []store.ConcurrencySave, runs []github.Run, workflows []github.Workflow, superseded map[int64]int64) []concurrencyCancel {
	savedAt := map[int64]time.Time{}
	for _, w := range workflows {
		for _, save := range saves {
			if save.WorkflowPath == w.Path {
				savedAt[w.ID] = save.SavedAt
			}
		}
	}
	var out []concurrencyCancel
	for _, r := range runs {
		at, ok := savedAt[r.WorkflowID]
		if !ok || !r.CreatedAt.After(at) || r.Status != "completed" || r.Conclusion != "cancelled" || superseded[r.ID] == 0 {
			continue
		}
		var minutes int64
		if median, ok := medianDuration(runs, r.WorkflowID); ok {
			minutes = estimateMinutes(median, r.UpdatedAt.Sub(r.CreatedAt))
		}
		out = append(out, concurrencyCancel{RunID: r.ID, Minutes: minutes})
	}
	return out
}

// analyzed reads every cached run and finds the superseded ones, without
// grouping changes; false when the cache is not the current origin's.
func (r *Runtime) analyzed(ctx context.Context) (store.Activity, changes.Analysis, bool, error) {
	r.mu.Lock()
	resolve := r.resolve
	r.mu.Unlock()
	a, err := r.cfg.store.Activity(ctx, store.MaxRuns)
	if err != nil {
		return store.Activity{}, changes.Analysis{}, false, err
	}
	target, problem := resolve()
	if problem != corev1.GithubAccess_GITHUB_ACCESS_OK || !a.HasSource || a.Source != target.Source() {
		return a, changes.Analysis{}, false, nil
	}
	return a, changes.Analyze(input(a, target, r.cfg.now())), true, nil
}

// CancelEstimate is cancelEstimate over this workspace's cache.
func (r *Runtime) CancelEstimate(ctx context.Context, runID int64, now time.Time) (bool, int64, error) {
	a, analysis, ok, err := r.analyzed(ctx)
	if err != nil || !ok {
		return false, 0, err
	}
	superseded, minutes := cancelEstimate(a.Runs, analysis.SupersededBy, runID, now)
	return superseded, minutes, nil
}

// NoteConcurrencySaved remembers that this Mac saved the suggested block
// into a workflow file, so the runs it cancels are counted here only.
func (r *Runtime) NoteConcurrencySaved(ctx context.Context, workflowPath string, at time.Time) error {
	return r.cfg.store.AddConcurrencySave(ctx, workflowPath, at)
}

// countConcurrencyCancels counts, once each, runs the saved block
// cancelled. Called after a pass that reached GitHub.
func (r *Runtime) countConcurrencyCancels() {
	if r.cfg.analytics == nil {
		return
	}
	saves, err := r.cfg.store.ConcurrencySaves(r.ctx)
	if err != nil || len(saves) == 0 {
		return
	}
	a, analysis, ok, err := r.analyzed(r.ctx)
	if err != nil || !ok {
		return
	}
	found := concurrencyCancels(saves, a.Runs, a.Workflows, analysis.SupersededBy)
	if len(found) == 0 {
		return
	}
	ids := make([]int64, len(found))
	for i, f := range found {
		ids[i] = f.RunID
	}
	fresh, err := r.cfg.store.MarkCountedCancels(r.ctx, ids)
	if err != nil {
		return
	}
	counts := analytics.Counts{}
	for _, f := range found {
		if fresh[f.RunID] {
			counts[analytics.ConcurrencyCancels]++
			counts[analytics.ConcurrencyMinutesEst] += f.Minutes
		}
	}
	if len(counts) > 0 {
		r.cfg.analytics(r.cfg.now(), counts)
	}
}
