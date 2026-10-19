package github

import (
	"context"
	"fmt"
	"net/http"
)

// CancelRun asks GitHub to cancel a run. GitHub accepts it (202) and cancels
// asynchronously; a finished run is refused with *RejectedError.
func (c *Client) CancelRun(ctx context.Context, owner, name string, runID int64) error {
	return c.post(ctx, repoPath(owner, name, fmt.Sprintf("/actions/runs/%d/cancel", runID)), runID)
}

// RerunRun starts a new attempt of a finished run: every job, or with
// failedOnly the failed and cancelled jobs and what depends on them. Neither
// call is retried here, so a lost answer cannot start two attempts.
func (c *Client) RerunRun(ctx context.Context, owner, name string, runID int64, failedOnly bool) error {
	suffix := "/rerun"
	if failedOnly {
		suffix = "/rerun-failed-jobs"
	}
	return c.post(ctx, repoPath(owner, name, fmt.Sprintf("/actions/runs/%d%s", runID, suffix)), runID)
}

func (c *Client) post(ctx context.Context, path string, runID int64) error {
	if runID <= 0 {
		return ErrInvalid
	}
	_, _, err := c.send(ctx, http.MethodPost, path, nil, []byte("{}"), "application/vnd.github+json")
	return err
}
