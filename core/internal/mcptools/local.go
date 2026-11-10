package mcptools

import (
	"strings"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// maxWait is the longest a call waits for a local run.
const maxWait = 240 * time.Second

func (t *Tools) listLocalRuns(c *call) (Result, error) {
	var a workspaceArgs
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	w, err := t.open(c, a.Repository, false)
	if err != nil {
		return Result{}, err
	}
	runs, err := t.core.LocalRuns(c.ctx, w.id, 20)
	if err != nil {
		return Result{}, err
	}
	type item struct {
		ExecutionID string   `json:"execution_id"`
		Scenario    string   `json:"scenario,omitempty"`
		Workflows   []string `json:"workflows"`
		State       string   `json:"state"`
		Message     string   `json:"message,omitempty"`
		StartedAt   string   `json:"started_at,omitempty"`
		FinishedAt  string   `json:"finished_at,omitempty"`
		StartedBy   string   `json:"started_by,omitempty"`
	}
	out := struct {
		Workspace string `json:"workspace"`
		Runs      []item `json:"runs"`
	}{Workspace: w.name, Runs: []item{}}
	for _, r := range runs {
		out.Runs = append(out.Runs, item{ExecutionID: r.ExecutionID, Scenario: r.Scenario, Workflows: append([]string{}, r.Workflows...),
			State: r.State, Message: r.Message, StartedAt: stampOf(r.StartedAt), FinishedAt: stampOf(r.FinishedAt), StartedBy: r.StartedBy})
	}
	return result("", out)
}

// localRun reads a run and checks it is the workspace's.
func (t *Tools) localRun(c *call, w workspace, id string, after uint64) (*corev1.GetLocalRunOutputResponse, error) {
	out, err := t.core.GetLocalRunOutput(c.ctx, &corev1.GetLocalRunOutputRequest{ExecutionId: id, AfterSequence: after})
	if err != nil {
		return nil, refuse("Runnir Core holds no local run %s now: it keeps the last 20 runs until it restarts. runnir_list_local_runs lists the workspace's runs.", id)
	}
	if out.GetRepositoryId() != w.id {
		return nil, refuse("The local run %s is not a run of %s.", id, w.name)
	}
	return out, nil
}

type localJob struct {
	Workflow   string `json:"workflow"`
	ID         string `json:"id"`
	Name       string `json:"name,omitempty"`
	State      string `json:"state"`
	Reason     string `json:"reason,omitempty"`
	StartedAt  string `json:"started_at,omitempty"`
	FinishedAt string `json:"finished_at,omitempty"`
}

type plannedLane struct {
	Workflow string   `json:"workflow"`
	Jobs     []string `json:"jobs"`
}

// ranLanes are the workflows a run's plan ticked, with their ticked jobs.
func ranLanes(plan *corev1.LocalRunPlan) []plannedLane {
	out := []plannedLane{}
	for _, lane := range plan.GetLanes() {
		var jobs []string
		for _, j := range lane.GetJobs() {
			if j.GetSelected() {
				jobs = append(jobs, j.GetId())
			}
		}
		if len(jobs) > 0 {
			out = append(out, plannedLane{Workflow: lane.GetWorkflowId(), Jobs: jobs})
		}
	}
	return out
}

func executionState(s corev1.ExecutionState) string { return lowerName(s.String(), "EXECUTION_STATE_") }

func (t *Tools) getLocalRun(c *call) (Result, error) {
	var a struct {
		Repository    *string `json:"repository"`
		ExecutionID   *string `json:"execution_id"`
		AfterSequence *uint64 `json:"after_sequence"`
		Wait          *string `json:"wait"`
		WaitSeconds   *int    `json:"wait_seconds"`
		Job           *string `json:"job"`
		Lines         *int    `json:"lines"`
	}
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	if a.ExecutionID == nil || *a.ExecutionID == "" {
		return Result{}, refuse("Give execution_id, from runnir_start_local_run or runnir_list_local_runs.")
	}
	wait := "none"
	if a.Wait != nil && *a.Wait != "" {
		wait = *a.Wait
	}
	if wait != "none" && wait != "output" && wait != "end" {
		return Result{}, refuse("wait must be none, output or end.")
	}
	var after uint64
	if a.AfterSequence != nil {
		after = *a.AfterSequence
	}
	limit := bounded(a.Lines, 200, 2000)
	waitFor := time.Duration(bounded(a.WaitSeconds, 60, int(maxWait/time.Second))) * time.Second
	w, err := t.open(c, a.Repository, false)
	if err != nil {
		return Result{}, err
	}
	c.note("run %q", *a.ExecutionID)
	deadline := time.Now().Add(waitFor)
	var out *corev1.GetLocalRunOutputResponse
	waited := false
	for {
		if out, err = t.localRun(c, w, *a.ExecutionID, after); err != nil {
			return Result{}, err
		}
		finished := out.GetPhase() == corev1.LocalRunPhase_LOCAL_RUN_PHASE_FINISHED
		if wait == "none" || finished || (wait == "output" && out.GetLastSequence() > after) {
			break
		}
		if !time.Now().Before(deadline) {
			waited = true
			break
		}
		timer := time.NewTimer(min(t.poll, time.Until(deadline)))
		select {
		case <-c.ctx.Done():
			timer.Stop()
			return Result{}, c.ctx.Err()
		case <-timer.C:
		}
	}
	type line struct {
		Sequence uint64 `json:"seq"`
		Workflow string `json:"workflow,omitempty"`
		Job      string `json:"job,omitempty"`
		Text     string `json:"text"`
		Error    bool   `json:"error,omitempty"`
	}
	result := struct {
		Workspace      string        `json:"workspace"`
		ExecutionID    string        `json:"execution_id"`
		State          string        `json:"state"`
		Phase          string        `json:"phase"`
		Finished       bool          `json:"finished"`
		StillGoing     bool          `json:"wait_ended_before_the_run,omitempty"`
		StartedBy      string        `json:"started_by,omitempty"`
		StartedAt      string        `json:"started_at,omitempty"`
		FinishedAt     string        `json:"finished_at,omitempty"`
		ExitCode       *int32        `json:"exit_code,omitempty"`
		Message        string        `json:"message,omitempty"`
		CleanupProblem string        `json:"cleanup_problem,omitempty"`
		Scenario       string        `json:"scenario,omitempty"`
		Workflows      []plannedLane `json:"workflows"`
		Jobs           []localJob    `json:"jobs"`
		Lines          []line        `json:"lines"`
		NextAfter      uint64        `json:"next_after"`
		More           bool          `json:"more,omitempty"`
		Discarded      bool          `json:"earlier_lines_dropped,omitempty"`
	}{
		Workspace: w.name, ExecutionID: out.GetExecutionId(), State: executionState(out.GetState()),
		Phase: lowerName(out.GetPhase().String(), "LOCAL_RUN_PHASE_"), Finished: out.GetPhase() == corev1.LocalRunPhase_LOCAL_RUN_PHASE_FINISHED,
		StillGoing: waited, StartedBy: out.GetStartedBy(), StartedAt: stamp(out.GetStartedAt()), FinishedAt: stamp(out.GetFinishedAt()),
		Message: out.GetMessage(), CleanupProblem: out.GetCleanupProblem(), Scenario: out.GetPlan().GetScenario().GetTitle(),
		Workflows: ranLanes(out.GetPlan()), Jobs: []localJob{}, Lines: []line{}, NextAfter: out.GetLastSequence(), Discarded: out.GetDiscarded(),
	}
	if code := out.GetExitCode(); code >= 0 {
		result.ExitCode = &code
	}
	for _, j := range out.GetJobs() {
		result.Jobs = append(result.Jobs, localJob{Workflow: j.GetWorkflowId(), ID: j.GetId(), Name: j.GetName(),
			State: lowerName(j.GetState().String(), "LOCAL_JOB_STATE_"), Reason: j.GetReason(),
			StartedAt: stamp(j.GetStartedAt()), FinishedAt: stamp(j.GetFinishedAt())})
	}
	job := ""
	if a.Job != nil {
		job = *a.Job
	}
	size := 0
	for _, l := range out.GetLines() {
		if job != "" && l.GetJobId() != job {
			continue
		}
		text := clip(l.GetText(), maxLineBytes)
		if len(result.Lines) == limit || (len(result.Lines) > 0 && size+len(text) > maxLinesBytes) {
			result.More = true
			result.NextAfter = result.Lines[len(result.Lines)-1].Sequence
			break
		}
		size += len(text)
		result.Lines = append(result.Lines, line{Sequence: l.GetSequence(), Workflow: l.GetWorkflowId(), Job: l.GetJobId(), Text: text, Error: l.GetError()})
	}
	return resultOf(result)
}

// resultOf is result without a sentence; it keeps the local variable named
// result above readable.
func resultOf(structured any) (Result, error) { return result("", structured) }

func (t *Tools) startLocalRun(c *call) (Result, error) {
	var a struct {
		Repository *string `json:"repository"`
		Scenario   *string `json:"scenario"`
		Target     *string `json:"target"`
		Workflows  []struct {
			Workflow *string  `json:"workflow"`
			Jobs     []string `json:"jobs"`
		} `json:"workflows"`
		Environment         *string `json:"environment"`
		AllowMissingValues  *bool   `json:"allow_missing_values"`
		MacosWithoutSandbox *bool   `json:"macos_without_sandbox"`
	}
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	if a.Repository == nil || strings.TrimSpace(*a.Repository) == "" {
		return Result{}, refuse("Name a repository: a registered workspace's folder or its name.")
	}
	asked, err := scenarioArg(a.Scenario, a.Target)
	if err != nil {
		return Result{}, err
	}
	start := &corev1.McpLocalRunStart{Scenario: asked}
	for _, wf := range a.Workflows {
		if wf.Workflow == nil || strings.TrimSpace(*wf.Workflow) == "" {
			return Result{}, refuse("Each entry of workflows names a workflow.")
		}
		start.Workflows = append(start.Workflows, &corev1.McpLocalRunWorkflow{Workflow: *wf.Workflow, Jobs: wf.Jobs})
	}
	if a.Environment != nil {
		start.Environment = *a.Environment
	}
	start.AllowMissingValues = a.AllowMissingValues != nil && *a.AllowMissingValues
	start.MacosWithoutSandbox = a.MacosWithoutSandbox != nil && *a.MacosWithoutSandbox
	c.note("%q", *a.Repository)
	if start.MacosWithoutSandbox {
		c.note("without the macOS sandbox")
	}
	started, err := t.app.Start(c.ctx, c.client, *a.Repository, start)
	if err != nil {
		return Result{}, err
	}
	c.note("started %q", started.GetExecutionId())
	out := struct {
		Workspace   string        `json:"workspace"`
		ExecutionID string        `json:"execution_id"`
		Scenario    string        `json:"scenario,omitempty"`
		Workflows   []plannedLane `json:"workflows"`
		Environment string        `json:"environment,omitempty"`
		Passed      []string      `json:"values_passed"`
		Empty       []string      `json:"values_empty"`
		HostJobs    []string      `json:"macos_jobs_on_this_mac,omitempty"`
		Unsandboxed bool          `json:"without_macos_sandbox,omitempty"`
		Notes       []string      `json:"notes,omitempty"`
	}{Workspace: started.GetWorkspace(), ExecutionID: started.GetExecutionId(), Environment: started.GetEnvironment(),
		Passed: append([]string{}, started.GetPassed()...), Empty: append([]string{}, started.GetEmpty()...), Workflows: []plannedLane{}}
	if run, err := t.core.GetLocalRunOutput(c.ctx, &corev1.GetLocalRunOutputRequest{ExecutionId: started.GetExecutionId(), AfterSequence: ^uint64(0)}); err == nil {
		plan := run.GetPlan()
		out.Scenario, out.Workflows, out.HostJobs, out.Unsandboxed, out.Notes =
			plan.GetScenario().GetTitle(), ranLanes(plan), plan.GetHostJobs(), plan.GetHostUnsandboxed(), plan.GetNotes()
	}
	return result("Started local run "+out.ExecutionID+" in "+out.Workspace+". Follow it with runnir_get_local_run, wait \"end\".", out)
}

func (t *Tools) stopLocalRun(c *call) (Result, error) {
	var a struct {
		Repository  *string `json:"repository"`
		ExecutionID *string `json:"execution_id"`
	}
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	if a.ExecutionID == nil || *a.ExecutionID == "" {
		return Result{}, refuse("Give execution_id, from runnir_start_local_run or runnir_list_local_runs.")
	}
	w, err := t.open(c, a.Repository, true)
	if err != nil {
		return Result{}, err
	}
	c.note("run %q", *a.ExecutionID)
	run, err := t.localRun(c, w, *a.ExecutionID, ^uint64(0))
	if err != nil {
		return Result{}, err
	}
	if run.GetPhase() == corev1.LocalRunPhase_LOCAL_RUN_PHASE_FINISHED {
		return result("The local run had already finished.", struct {
			ExecutionID string `json:"execution_id"`
			State       string `json:"state"`
		}{run.GetExecutionId(), executionState(run.GetState())})
	}
	if _, err := t.core.CancelExecution(c.ctx, &corev1.CancelExecutionRequest{ExecutionId: *a.ExecutionID}); err != nil {
		return Result{}, err
	}
	return result("Stopping local run "+*a.ExecutionID+"; its containers are removed afterwards.", struct {
		ExecutionID string `json:"execution_id"`
		Stopping    bool   `json:"stopping"`
	}{*a.ExecutionID, true})
}
