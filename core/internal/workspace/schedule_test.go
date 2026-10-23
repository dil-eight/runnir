package workspace

import (
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
)

func TestTheNextPassIsScheduledByOutcome(t *testing.T) {
	iv := DefaultIntervals()
	now := time.Date(2026, 10, 22, 12, 0, 0, 0, time.UTC)
	cases := []struct {
		name     string
		access   corev1.GithubAccess
		active   bool
		failures int
		retry    time.Time
		want     time.Duration
		timer    bool
	}{
		{"idle", corev1.GithubAccess_GITHUB_ACCESS_OK, false, 0, time.Time{}, 5 * time.Minute, true},
		{"active", corev1.GithubAccess_GITHUB_ACCESS_OK, true, 0, time.Time{}, 20 * time.Second, true},
		{"first failure", corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE, false, 1, time.Time{}, 30 * time.Second, true},
		{"third failure", corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE, false, 3, time.Time{}, 2 * time.Minute, true},
		{"many failures", corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE, false, 9, time.Time{}, 5 * time.Minute, true},
		{"rate limit", corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED, false, 0, now.Add(10 * time.Minute), 10 * time.Minute, true},
		{"rate limit soon", corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED, false, 0, now.Add(time.Second), 30 * time.Second, true},
		{"rate limit far", corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED, false, 0, now.Add(5 * time.Hour), time.Hour, true},
		{"signed out", corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT, false, 0, time.Time{}, 0, false},
		{"rejected", corev1.GithubAccess_GITHUB_ACCESS_TOKEN_REJECTED, false, 0, time.Time{}, 0, false},
		{"not visible", corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE, false, 0, time.Time{}, 0, false},
		{"permission", corev1.GithubAccess_GITHUB_ACCESS_PERMISSION_MISSING, false, 0, time.Time{}, 0, false},
		{"no remote", corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE, false, 0, time.Time{}, 0, false},
	}
	for _, c := range cases {
		got, timer := schedule(iv, c.access, c.active, c.failures, c.retry, now)
		if got != c.want || timer != c.timer {
			t.Errorf("%s: %v %v, want %v %v", c.name, got, timer, c.want, c.timer)
		}
	}
}

func TestActiveRunsKeepTheShortInterval(t *testing.T) {
	for status, want := range map[string]bool{"queued": true, "in_progress": true, "waiting": true, "requested": true, "pending": true, "completed": false} {
		if got := isActive([]github.Run{{Status: status}}); got != want {
			t.Errorf("%s: %v", status, got)
		}
	}
}
