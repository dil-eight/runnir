// Package workspace runs one shared runtime per workspace in the Core: its
// database, one GitHub sync loop, shared job and log reads and the history
// of local runs, however many windows show the workspace.
package workspace

import (
	"context"
	"errors"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
)

// Access maps a GitHub client error to the status the app sees and forgets
// the token GitHub rejected. A cancelled call returns its context error
// instead, for the caller to end the call with.
func Access(account *github.Account, err error) (corev1.GithubAccess, time.Time, error) {
	var rateLimit *github.RateLimitError
	switch {
	case err == nil, errors.Is(err, github.ErrNotModified):
		return corev1.GithubAccess_GITHUB_ACCESS_OK, time.Time{}, nil
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return corev1.GithubAccess_GITHUB_ACCESS_UNSPECIFIED, time.Time{}, err
	case errors.Is(err, github.ErrNoCredential):
		return corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT, time.Time{}, nil
	case errors.Is(err, github.ErrUnauthorized):
		account.Credential.Clear()
		return corev1.GithubAccess_GITHUB_ACCESS_TOKEN_REJECTED, time.Time{}, nil
	case errors.Is(err, github.ErrNotVisible):
		return corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE, time.Time{}, nil
	case errors.Is(err, github.ErrPermissionMissing):
		return corev1.GithubAccess_GITHUB_ACCESS_PERMISSION_MISSING, time.Time{}, nil
	case errors.As(err, &rateLimit):
		return corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED, rateLimit.Reset, nil
	default:
		return corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE, time.Time{}, nil
	}
}
