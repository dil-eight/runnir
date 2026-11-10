package mcptools

import (
	"fmt"
	"sort"
	"strings"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func (t *Tools) dispatchWorkflow(c *call) (Result, error) {
	var a struct {
		Repository *string           `json:"repository"`
		Workflow   *string           `json:"workflow"`
		Ref        *string           `json:"ref"`
		Inputs     map[string]string `json:"inputs"`
	}
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	if a.Workflow == nil || *a.Workflow == "" {
		return Result{}, refuse("Name a workflow: its path, file name or name.")
	}
	w, err := t.open(c, a.Repository, true)
	if err != nil {
		return Result{}, err
	}
	ref := w.branch
	if a.Ref != nil && *a.Ref != "" {
		ref = *a.Ref
	}
	if ref == "" {
		return Result{}, refuse("The workspace is on no branch; give ref, a branch or tag on GitHub.")
	}
	path := *a.Workflow
	if local, err := t.workflows(c.ctx, w); err == nil {
		if found, err := findWorkflow(local, *a.Workflow); err == nil {
			path = found.GetId()
		}
	}
	remote, err := t.core.ListGitHubWorkflows(c.ctx, &corev1.ListGitHubWorkflowsRequest{RepositoryId: w.id})
	if err != nil {
		return Result{}, err
	}
	if problem := gitHubProblem(remote.GetStatus()); problem != "" {
		return Result{}, refusal(problem)
	}
	ids, err := gitHubWorkflowIDs(remote.GetWorkflows(), path)
	if err != nil {
		return Result{}, err
	}
	if len(ids) != 1 {
		return Result{}, refuse("Several workflows on GitHub match %s; give its path.", *a.Workflow)
	}
	var id int64
	for found := range ids {
		id = found
	}
	names := make([]string, 0, len(a.Inputs))
	for name := range a.Inputs {
		names = append(names, name)
	}
	sort.Strings(names)
	c.note("workflow %q ref %q inputs=[%s]", path, ref, strings.Join(names, " "))
	prepared, err := t.core.PrepareWorkflowDispatch(c.ctx, &corev1.PrepareWorkflowDispatchRequest{RepositoryId: w.id, WorkflowId: id, Ref: ref, Inputs: a.Inputs})
	if err != nil {
		return Result{}, err
	}
	if problem := gitHubProblem(prepared.GetStatus()); problem != "" {
		return Result{}, refusal(problem)
	}
	if len(prepared.GetProblems()) > 0 {
		return Result{}, refusal("GitHub would not start it: " + strings.Join(prepared.GetProblems(), " "))
	}
	sent, err := t.core.ConfirmWorkflowDispatch(c.ctx, &corev1.ConfirmWorkflowDispatchRequest{DispatchId: prepared.GetDispatchId()})
	if err != nil {
		return Result{}, err
	}
	if problem := gitHubProblem(sent.GetStatus()); problem != "" {
		return Result{}, refusal(problem)
	}
	if sent.GetRejection() != "" {
		return Result{}, refusal("GitHub refused: " + sentence(sent.GetRejection()))
	}
	out := struct {
		Workspace    string `json:"workspace"`
		Workflow     string `json:"workflow"`
		Ref          string `json:"ref"`
		DispatchedAt string `json:"dispatched_at,omitempty"`
		RunID        int64  `json:"run_id,omitempty"`
		URL          string `json:"url,omitempty"`
	}{Workspace: w.name, Workflow: prepared.GetWorkflowPath(), Ref: ref, DispatchedAt: stamp(sent.GetDispatchedAt()), RunID: sent.GetRunId()}
	summary := fmt.Sprintf("GitHub accepted %s at %s.", out.Workflow, ref)
	if out.RunID > 0 {
		c.note("run %d", out.RunID)
		out.URL = t.runURL(c, w, out.RunID)
		summary = fmt.Sprintf("Started run %d of %s at %s.", out.RunID, out.Workflow, ref)
	} else {
		summary += " GitHub did not say which run it started; runnir_list_runs with refresh finds it."
	}
	return result(summary, out)
}

// runURL is a run's page on github.com; empty for another server.
func (t *Tools) runURL(c *call, w workspace, id int64) string {
	origins, err := t.core.GetGitHubOrigins(c.ctx, &corev1.GetGitHubOriginsRequest{Paths: []string{w.path}})
	if err != nil || len(origins.GetOrigins()) == 0 || origins.GetOrigins()[0].GetGithubServerId() != "" {
		return ""
	}
	return fmt.Sprintf("https://github.com/%s/actions/runs/%d", origins.GetOrigins()[0].GetGithubRepository(), id)
}

func (t *Tools) cancelRun(c *call) (Result, error) {
	var a struct {
		Repository *string `json:"repository"`
		RunID      *int64  `json:"run_id"`
	}
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	if a.RunID == nil || *a.RunID <= 0 {
		return Result{}, refuse("Give run_id, a run's id from runnir_list_runs.")
	}
	return t.runAction(c, a.Repository, *a.RunID, corev1.RunAction_RUN_ACTION_CANCEL, 0)
}

func (t *Tools) rerunRun(c *call) (Result, error) {
	var a struct {
		Repository *string `json:"repository"`
		RunID      *int64  `json:"run_id"`
		Mode       *string `json:"mode"`
		JobID      *int64  `json:"job_id"`
	}
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	if a.RunID == nil || *a.RunID <= 0 {
		return Result{}, refuse("Give run_id, a run's id from runnir_list_runs.")
	}
	mode := "all"
	if a.Mode != nil && *a.Mode != "" {
		mode = *a.Mode
	}
	var job int64
	if a.JobID != nil {
		job = *a.JobID
	}
	switch {
	case mode == "all" && job == 0:
		return t.runAction(c, a.Repository, *a.RunID, corev1.RunAction_RUN_ACTION_RERUN, 0)
	case mode == "failed" && job == 0:
		return t.runAction(c, a.Repository, *a.RunID, corev1.RunAction_RUN_ACTION_RERUN_FAILED, 0)
	case mode == "job" && job > 0:
		return t.runAction(c, a.Repository, *a.RunID, corev1.RunAction_RUN_ACTION_RERUN_JOB, job)
	case mode == "job":
		return Result{}, refuse("mode job needs job_id, a job's id from runnir_get_run.")
	case mode != "all" && mode != "failed":
		return Result{}, refuse("mode must be all, failed or job.")
	default:
		return Result{}, refuse("job_id goes with mode job.")
	}
}

// runAction prepares a cancel or a re-run and confirms it at once: the user
// lets agents act without a click (design of 2026-11-09).
func (t *Tools) runAction(c *call, repository *string, runID int64, action corev1.RunAction, jobID int64) (Result, error) {
	w, err := t.open(c, repository, true)
	if err != nil {
		return Result{}, err
	}
	c.note("run %d", runID)
	if jobID > 0 {
		c.note("job %d", jobID)
	}
	prepared, err := t.core.PrepareRunAction(c.ctx, &corev1.PrepareRunActionRequest{RepositoryId: w.id, RunId: runID, Action: action, JobId: jobID})
	if err != nil {
		return Result{}, err
	}
	if problem := gitHubProblem(prepared.GetStatus()); problem != "" {
		return Result{}, refusal(problem)
	}
	if len(prepared.GetProblems()) > 0 {
		return Result{}, refusal(strings.Join(prepared.GetProblems(), " "))
	}
	done, err := t.core.ConfirmRunAction(c.ctx, &corev1.ConfirmRunActionRequest{ActionId: prepared.GetActionId()})
	if err != nil {
		return Result{}, err
	}
	if problem := gitHubProblem(done.GetStatus()); problem != "" {
		return Result{}, refusal(problem)
	}
	if done.GetRejection() != "" {
		return Result{}, refusal("GitHub refused: " + sentence(done.GetRejection()))
	}
	summary := map[corev1.RunAction]string{
		corev1.RunAction_RUN_ACTION_CANCEL:       "GitHub is cancelling run %d.",
		corev1.RunAction_RUN_ACTION_RERUN:        "GitHub is re-running every job of run %d.",
		corev1.RunAction_RUN_ACTION_RERUN_FAILED: "GitHub is re-running the failed jobs of run %d.",
		corev1.RunAction_RUN_ACTION_RERUN_JOB:    "GitHub is re-running a job of run %d.",
	}[action]
	out := struct {
		Workspace  string `json:"workspace"`
		RunID      int64  `json:"run_id"`
		Action     string `json:"action"`
		AcceptedAt string `json:"accepted_at,omitempty"`
		URL        string `json:"url,omitempty"`
	}{Workspace: w.name, RunID: runID, Action: lowerName(action.String(), "RUN_ACTION_"), AcceptedAt: stamp(done.GetAcceptedAt()),
		URL: prepared.GetRun().GetHtmlUrl()}
	return result(fmt.Sprintf(summary, runID)+" runnir_get_run shows how it goes.", out)
}
