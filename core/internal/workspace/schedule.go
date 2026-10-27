package workspace

import (
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
)

// Intervals tune the sync; DefaultIntervals is what the Core uses.
type Intervals struct {
	Active, Idle               time.Duration
	Backoff                    []time.Duration
	RateLimitMin, RateLimitMax time.Duration
	// JobsReuse is how long jobs just read are served again without a
	// request, so windows opening the same run share one read.
	JobsReuse time.Duration
	// FetchTimeout bounds a shared jobs or log download.
	FetchTimeout time.Duration
	// PullsRetry is how long after GitHub refused pull requests a pass asks
	// again, so access granted on GitHub shows without a refresh.
	PullsRetry time.Duration
}

func DefaultIntervals() Intervals {
	return Intervals{
		Active: 20 * time.Second, Idle: 5 * time.Minute,
		Backoff:      []time.Duration{30 * time.Second, time.Minute, 2 * time.Minute, 5 * time.Minute},
		RateLimitMin: 30 * time.Second, RateLimitMax: time.Hour,
		JobsReuse: 10 * time.Second, FetchTimeout: 2 * time.Minute,
		PullsRetry: 2 * time.Minute,
	}
}

// schedule says how long after a pass the next one runs, or false for no
// timer: then only a refresh or a credential change starts one. failures
// counts consecutive UNAVAILABLE passes.
func schedule(iv Intervals, access corev1.GithubAccess, active bool, failures int, retryAfter, now time.Time) (time.Duration, bool) {
	switch access {
	case corev1.GithubAccess_GITHUB_ACCESS_OK:
		if active {
			return iv.Active, true
		}
		return iv.Idle, true
	case corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE:
		i := min(max(failures-1, 0), len(iv.Backoff)-1)
		return iv.Backoff[i], true
	case corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED:
		return min(max(retryAfter.Sub(now), iv.RateLimitMin), iv.RateLimitMax), true
	default:
		return 0, false
	}
}

// isActive reports a run GitHub has not finished.
func isActive(runs []github.Run) bool {
	for _, r := range runs {
		switch r.Status {
		case "queued", "in_progress", "waiting", "requested", "pending":
			return true
		}
	}
	return false
}
