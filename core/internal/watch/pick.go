// Package watch keeps the signed-in user's failed and running runs of the
// repositories the app watches (B39): the rule that picks them, apart from
// any I/O, and the watcher that reads them.
package watch

import (
	"sort"
	"strings"
	"time"

	"runnir/core/internal/github"
	"runnir/core/internal/runsearch"
)

// FailedFor is how long a failed run stays listed after it finished.
const FailedFor = 7 * 24 * time.Hour

// Pick returns the failed and the running runs that login started, of one
// repository. A run is running while it is not completed. A workflow on a
// branch is failed when its newest finished run is in the Failed group and
// finished within FailedFor of now: a later run that passed, was cancelled
// or was skipped, or a re-run that passed, lists nothing. A new run in
// progress does not change that, but a re-run in progress lists nothing
// until it finishes: its run is the newest, and how it ends is not known.
// Failed runs come newest first by UpdatedAt, running ones by CreatedAt.
func Pick(runs []github.Run, login string, now time.Time) (failed, running []github.Run) {
	type group struct {
		workflow int64
		branch   string
	}
	groups := map[group][]github.Run{}
	for _, r := range runs {
		if login == "" || !strings.EqualFold(r.Actor, login) {
			continue
		}
		if r.Status != "completed" {
			running = append(running, r)
		}
		key := group{r.WorkflowID, r.Branch}
		groups[key] = append(groups[key], r)
	}
	for _, list := range groups {
		sort.Slice(list, func(i, j int) bool { return later(list[i].CreatedAt, list[i].ID, list[j].CreatedAt, list[j].ID) })
		for _, r := range list {
			if r.Status != "completed" && r.RunAttempt <= 1 {
				continue
			}
			if r.Status == "completed" && runsearch.StatusOf(r.Status, r.Conclusion) == runsearch.Failed && now.Sub(r.UpdatedAt) <= FailedFor {
				failed = append(failed, r)
			}
			break
		}
	}
	sort.Slice(failed, func(i, j int) bool {
		return later(failed[i].UpdatedAt, failed[i].ID, failed[j].UpdatedAt, failed[j].ID)
	})
	sort.Slice(running, func(i, j int) bool {
		return later(running[i].CreatedAt, running[i].ID, running[j].CreatedAt, running[j].ID)
	})
	return failed, running
}

// later: a is after b, the higher id on a tie.
func later(a time.Time, idA int64, b time.Time, idB int64) bool {
	if !a.Equal(b) {
		return a.After(b)
	}
	return idA > idB
}
