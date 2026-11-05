package analytics

import (
	"strings"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// Minute counters, counted at Basic and Full. Their meaning is in the
// metrics table of docs/superpowers/specs/2026-10-25-anonymous-analytics-design.md.
const (
	LocalRuns          = "local_runs"
	LocalBilledMinutes = "local_billed_minutes"
	// Of those, runs of a workflow GitHub cannot start without a push or a
	// pull request: it has no workflow_dispatch trigger.
	LocalRunsWithoutDispatch          = "local_runs_without_dispatch"
	LocalBilledMinutesWithoutDispatch = "local_billed_minutes_without_dispatch"
	LocalJobsSucceeded                = "local_jobs_succeeded"
	LocalJobsFailed                   = "local_jobs_failed"
	LocalJobsCancelled                = "local_jobs_cancelled"
	LocalJobSeconds                   = "local_job_seconds"
	GHRefJobsMatched                  = "gh_ref_jobs_matched"
	GHRefBilledMinutes                = "gh_ref_billed_minutes"
	LocalBilledMinutesMatched         = "local_billed_minutes_matched"
	LocalRunsCompleted                = "local_runs_completed"
	LocalRunWallSeconds               = "local_run_wall_seconds"
	GHRefRunsMatched                  = "gh_ref_runs_matched"
	GHRefRunWallSeconds               = "gh_ref_run_wall_seconds"
	SupersededCancels                 = "superseded_cancels"
	SupersededCancelMinutesEst        = "superseded_cancel_minutes_est"
	ConcurrencyInserted               = "concurrency_inserted"
	ConcurrencyCancels                = "concurrency_cancels"
	ConcurrencyMinutesEst             = "concurrency_minutes_est"
)

var minuteCounters = map[string]bool{
	LocalRuns: true, LocalBilledMinutes: true, LocalRunsWithoutDispatch: true, LocalBilledMinutesWithoutDispatch: true,
	LocalJobsSucceeded: true, LocalJobsFailed: true,
	LocalJobsCancelled: true, LocalJobSeconds: true, GHRefJobsMatched: true, GHRefBilledMinutes: true,
	LocalBilledMinutesMatched: true, LocalRunsCompleted: true, LocalRunWallSeconds: true, GHRefRunsMatched: true,
	GHRefRunWallSeconds: true, SupersededCancels: true, SupersededCancelMinutesEst: true, ConcurrencyInserted: true,
	ConcurrencyCancels: true, ConcurrencyMinutesEst: true,
}

// Counts are increments by counter name.
type Counts map[string]int64

// IsMinuteCounter reports a saved-minute counter.
func IsMinuteCounter(name string) bool { return minuteCounters[name] }

// Category is the kind of a usage event; each is one PostHog event.
type Category string

const (
	Screen  Category = "screen"
	Overlay Category = "overlay"
	Action  Category = "action"
	Async   Category = "async"
)

var categories = []Category{Screen, Overlay, Action, Async}

// areas are the product areas a usage event belongs to. A UsageEvent is
// named USAGE_EVENT_<CATEGORY>_<AREA>_<NAME>; a new area is added here.
var areas = []string{
	"overview", "workflows", "runs", "local_run", "editor", "secrets", "presets", "logs",
	"workspaces", "github", "settings", "search", "notifications", "pull_requests", "app",
}

// Usage is what a UsageEvent counts.
type Usage struct {
	Category Category
	// Area is the product area, the first part of Name.
	Area string
	// Name is "<area>.<what>", for example "settings.privacy".
	Name string
}

// Counter is the usage's counter in the ledger, "<category>:<name>".
func (u Usage) Counter() string { return string(u.Category) + ":" + u.Name }

// usages are the UsageEvent values by counter, read from their names once.
var usages = func() map[string]Usage {
	out := map[string]Usage{}
	for value := range corev1.UsageEvent_name {
		if u, ok := parseUsage(corev1.UsageEvent(value)); ok {
			out[u.Counter()] = u
		}
	}
	return out
}()

// parseUsage reads a UsageEvent's category, area and name from its proto
// name; false for UNSPECIFIED and for a name that does not follow the form.
func parseUsage(event corev1.UsageEvent) (Usage, bool) {
	name, ok := corev1.UsageEvent_name[int32(event)]
	if !ok || event == corev1.UsageEvent_USAGE_EVENT_UNSPECIFIED {
		return Usage{}, false
	}
	rest := strings.ToLower(strings.TrimPrefix(name, "USAGE_EVENT_"))
	for _, category := range categories {
		after, ok := strings.CutPrefix(rest, string(category)+"_")
		if !ok {
			continue
		}
		for _, area := range areas {
			if what, ok := strings.CutPrefix(after, area+"_"); ok && what != "" {
				return Usage{Category: category, Area: area, Name: area + "." + what}, true
			}
		}
	}
	return Usage{}, false
}

// UsageCounter is the counter of a usage event; "" for none.
func UsageCounter(event corev1.UsageEvent) string {
	u, ok := parseUsage(event)
	if !ok {
		return ""
	}
	return u.Counter()
}

// IsUsageCounter reports the counter of a UsageEvent value.
func IsUsageCounter(name string) bool {
	_, ok := usages[name]
	return ok
}

// usageOf is the usage a counter counts.
func usageOf(counter string) (Usage, bool) {
	u, ok := usages[counter]
	return u, ok
}
