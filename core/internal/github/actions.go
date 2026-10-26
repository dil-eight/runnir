package github

import (
	"context"
	"encoding/json"
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

// RerunJob starts a new attempt of one job of a finished run and of the jobs
// that need it. Like RerunRun it is not retried, so a lost answer cannot
// start two attempts.
func (c *Client) RerunJob(ctx context.Context, owner, name string, jobID int64) error {
	return c.post(ctx, repoPath(owner, name, fmt.Sprintf("/actions/jobs/%d/rerun", jobID)), jobID)
}

// PendingDeployment is an environment a run waits on for approval.
type PendingDeployment struct {
	EnvironmentID int64
	Environment   string
	// CanApprove: the signed-in user is one of its required reviewers.
	CanApprove bool
}

// PendingDeployments lists the environments a waiting run needs approved.
func (c *Client) PendingDeployments(ctx context.Context, owner, name string, runID int64) ([]PendingDeployment, error) {
	if runID <= 0 {
		return nil, ErrInvalid
	}
	var body []struct {
		Environment struct {
			ID   int64  `json:"id"`
			Name string `json:"name"`
		} `json:"environment"`
		CanApprove bool `json:"current_user_can_approve"`
	}
	if err := c.get(ctx, repoPath(owner, name, fmt.Sprintf("/actions/runs/%d/pending_deployments", runID)), nil, &body); err != nil {
		return nil, err
	}
	out := make([]PendingDeployment, 0, len(body))
	for _, item := range body {
		out = append(out, PendingDeployment{EnvironmentID: item.Environment.ID, Environment: item.Environment.Name, CanApprove: item.CanApprove})
	}
	return out, nil
}

// ApproveDeployments approves a waiting run's deployments to the given
// environments, once; the jobs waiting on them start.
func (c *Client) ApproveDeployments(ctx context.Context, owner, name string, runID int64, environmentIDs []int64) error {
	if runID <= 0 || len(environmentIDs) == 0 {
		return ErrInvalid
	}
	body, err := json.Marshal(map[string]any{"environment_ids": environmentIDs, "state": "approved", "comment": "Approved in Runnir"})
	if err != nil {
		return err
	}
	_, _, err = c.send(ctx, http.MethodPost, repoPath(owner, name, fmt.Sprintf("/actions/runs/%d/pending_deployments", runID)),
		nil, body, "application/vnd.github+json")
	return err
}

func (c *Client) post(ctx context.Context, path string, runID int64) error {
	if runID <= 0 {
		return ErrInvalid
	}
	_, _, err := c.send(ctx, http.MethodPost, path, nil, []byte("{}"), "application/vnd.github+json")
	return err
}
