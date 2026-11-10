package mcptools

import (
	"context"
	"fmt"
	"path"
	"sort"
	"strings"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// Bounds of what one answer holds.
const (
	maxLineBytes   = 4 * 1024
	maxSourceBytes = 256 * 1024
	maxErrorLines  = 50
	// maxLinesBytes bounds the text of the lines of one answer.
	maxLinesBytes = 512 * 1024
)

type workspaceArgs struct {
	Repository *string `json:"repository"`
}

func (t *Tools) listWorkspaces(c *call) (Result, error) {
	var a struct{}
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	listed, err := t.app.Workspaces(c.ctx, c.client)
	if err != nil {
		return Result{}, err
	}
	type item struct {
		Name             string `json:"name"`
		Path             string `json:"path"`
		Open             bool   `json:"open"`
		GitHubRepository string `json:"github_repository,omitempty"`
	}
	var paths []string
	for _, w := range listed.GetWorkspaces() {
		paths = append(paths, w.GetPath())
	}
	origins := map[string]string{}
	if len(paths) > 0 {
		if found, err := t.core.GetGitHubOrigins(c.ctx, &corev1.GetGitHubOriginsRequest{Paths: paths}); err == nil {
			for _, o := range found.GetOrigins() {
				origins[o.GetPath()] = o.GetGithubRepository()
			}
		}
	}
	out := struct {
		Workspaces []item `json:"workspaces"`
	}{Workspaces: []item{}}
	for _, w := range listed.GetWorkspaces() {
		out.Workspaces = append(out.Workspaces, item{Name: w.GetName(), Path: w.GetPath(), Open: w.GetOpen(), GitHubRepository: origins[w.GetPath()]})
	}
	return result("", out)
}

type input struct {
	Name        string   `json:"name"`
	Type        string   `json:"type"`
	Required    bool     `json:"required,omitempty"`
	Default     string   `json:"default,omitempty"`
	Options     []string `json:"options,omitempty"`
	Description string   `json:"description,omitempty"`
}

type workflowJob struct {
	ID          string   `json:"id"`
	Name        string   `json:"name,omitempty"`
	Needs       []string `json:"needs,omitempty"`
	Environment string   `json:"environment,omitempty"`
	// EnvironmentExpression: an expression picks the environment.
	EnvironmentExpression bool     `json:"environment_expression,omitempty"`
	Manual                bool     `json:"manual,omitempty"`
	Secrets               []string `json:"secrets,omitempty"`
	Variables             []string `json:"variables,omitempty"`
}

type workflow struct {
	Path        string        `json:"path"`
	Name        string        `json:"name"`
	Triggers    []string      `json:"triggers"`
	Jobs        []workflowJob `json:"jobs"`
	Secrets     []string      `json:"secrets,omitempty"`
	Variables   []string      `json:"variables,omitempty"`
	Inputs      []input       `json:"dispatch_inputs,omitempty"`
	Concurrency bool          `json:"concurrency,omitempty"`
	ParseError  string        `json:"parse_error,omitempty"`
	Problems    *int          `json:"problems,omitempty"`
}

func workflowOf(w *corev1.Workflow, withValues bool) workflow {
	out := workflow{Path: w.GetId(), Name: w.GetName(), Triggers: append([]string{}, w.GetTriggers()...), Jobs: []workflowJob{},
		Secrets: w.GetSecrets(), Variables: w.GetVariables(), Concurrency: w.GetConcurrency(), ParseError: w.GetParseError()}
	for _, j := range w.GetJobs() {
		job := workflowJob{ID: j.GetId(), Name: j.GetName(), Needs: j.GetNeeds(), Environment: j.GetEnvironment(),
			EnvironmentExpression: j.GetEnvironmentExpression(), Manual: j.GetManual()}
		if withValues {
			job.Secrets, job.Variables = j.GetSecrets(), j.GetVariables()
		}
		out.Jobs = append(out.Jobs, job)
	}
	for _, i := range w.GetDispatchInputs() {
		out.Inputs = append(out.Inputs, input{Name: i.GetName(), Type: lowerName(i.GetType().String(), "DISPATCH_INPUT_TYPE_"),
			Required: i.GetRequired(), Default: i.GetDefaultValue(), Options: i.GetOptions(), Description: clip(i.GetDescription(), 500)})
	}
	return out
}

// findWorkflow finds a workflow by its path, its file name or its name.
func findWorkflow(workflows []*corev1.Workflow, asked string) (*corev1.Workflow, error) {
	asked = strings.TrimSpace(strings.TrimPrefix(asked, "./"))
	for _, w := range workflows {
		if w.GetId() == asked || w.GetId() == ".github/workflows/"+asked {
			return w, nil
		}
	}
	var named []*corev1.Workflow
	for _, w := range workflows {
		if path.Base(w.GetId()) == asked || strings.EqualFold(w.GetName(), asked) {
			named = append(named, w)
		}
	}
	if len(named) == 1 {
		return named[0], nil
	}
	var all []string
	for _, w := range workflows {
		all = append(all, w.GetId())
	}
	if len(named) > 1 {
		var paths []string
		for _, w := range named {
			paths = append(paths, w.GetId())
		}
		return nil, refuse("Several workflows match %s: %s. Give the path.", asked, strings.Join(paths, ", "))
	}
	if len(all) == 0 {
		return nil, refuse("This workspace has no workflow files in .github/workflows.")
	}
	return nil, refuse("No workflow matches %s. The workspace's workflows: %s.", asked, strings.Join(all, ", "))
}

func (t *Tools) workflows(ctx context.Context, w workspace) ([]*corev1.Workflow, error) {
	listed, err := t.core.ListWorkflows(ctx, &corev1.ListWorkflowsRequest{RepositoryId: w.id})
	if err != nil {
		return nil, err
	}
	return listed.GetWorkflows(), nil
}

func (t *Tools) listWorkflows(c *call) (Result, error) {
	var a workspaceArgs
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	w, err := t.open(c, a.Repository, false)
	if err != nil {
		return Result{}, err
	}
	workflows, err := t.workflows(c.ctx, w)
	if err != nil {
		return Result{}, err
	}
	counts := map[string]int{}
	validated, verr := t.core.ValidateWorkflows(c.ctx, &corev1.ValidateWorkflowsRequest{RepositoryId: w.id})
	for _, v := range validated.GetWorkflows() {
		counts[v.GetWorkflowId()] = len(v.GetDiagnostics())
	}
	out := struct {
		Workspace string     `json:"workspace"`
		Branch    string     `json:"branch,omitempty"`
		Workflows []workflow `json:"workflows"`
	}{Workspace: w.name, Branch: w.branch, Workflows: []workflow{}}
	for _, wf := range workflows {
		item := workflowOf(wf, false)
		if verr == nil {
			count := counts[wf.GetId()]
			item.Problems = &count
		}
		out.Workflows = append(out.Workflows, item)
	}
	return result("", out)
}

func (t *Tools) getWorkflow(c *call) (Result, error) {
	var a struct {
		Repository *string `json:"repository"`
		Workflow   *string `json:"workflow"`
	}
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	if a.Workflow == nil || *a.Workflow == "" {
		return Result{}, refuse("Name a workflow: its path, file name or name.")
	}
	w, err := t.open(c, a.Repository, false)
	if err != nil {
		return Result{}, err
	}
	workflows, err := t.workflows(c.ctx, w)
	if err != nil {
		return Result{}, err
	}
	found, err := findWorkflow(workflows, *a.Workflow)
	if err != nil {
		return Result{}, err
	}
	c.note("workflow %q", found.GetId())
	type problem struct {
		Line    int32  `json:"line,omitempty"`
		Column  int32  `json:"column,omitempty"`
		Kind    string `json:"kind"`
		Message string `json:"message"`
	}
	out := struct {
		Workspace         string    `json:"workspace"`
		Branch            string    `json:"branch,omitempty"`
		Workflow          workflow  `json:"workflow"`
		Problems          []problem `json:"problems"`
		ProblemsTruncated bool      `json:"problems_truncated,omitempty"`
		ValidationProblem string    `json:"validation_problem,omitempty"`
		Validator         string    `json:"validator,omitempty"`
		Source            string    `json:"source,omitempty"`
		SourceTruncated   bool      `json:"source_truncated,omitempty"`
	}{Workspace: w.name, Branch: w.branch, Workflow: workflowOf(found, true), Problems: []problem{}}
	validated, err := t.core.ValidateWorkflows(c.ctx, &corev1.ValidateWorkflowsRequest{RepositoryId: w.id, WorkflowId: found.GetId()})
	if err != nil {
		out.ValidationProblem = message(err)
	} else {
		out.Validator = validated.GetValidator()
		for _, v := range validated.GetWorkflows() {
			for _, d := range v.GetDiagnostics() {
				out.Problems = append(out.Problems, problem{Line: d.GetLine(), Column: d.GetColumn(), Kind: d.GetKind(), Message: d.GetMessage()})
			}
			out.ProblemsTruncated = out.ProblemsTruncated || v.GetTruncated()
			if v.GetProblem() != "" {
				out.ValidationProblem = v.GetProblem()
			}
		}
	}
	if source, err := t.core.WorkflowSource(w.id, found.GetId()); err == nil {
		out.SourceTruncated = len(source) > maxSourceBytes
		out.Source = clip(string(source), maxSourceBytes)
	}
	return result("", out)
}

func (t *Tools) planScenario(c *call) (Result, error) {
	var a struct {
		Repository *string `json:"repository"`
		Scenario   *string `json:"scenario"`
		Target     *string `json:"target"`
	}
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	asked, err := scenarioArg(a.Scenario, a.Target)
	if err != nil {
		return Result{}, err
	}
	w, err := t.open(c, a.Repository, false)
	if err != nil {
		return Result{}, err
	}
	flow, err := t.core.GetFlow(c.ctx, &corev1.GetFlowRequest{RepositoryId: w.id, Scenario: asked})
	if err != nil {
		return Result{}, err
	}
	type job struct {
		ID          string   `json:"id"`
		Name        string   `json:"name,omitempty"`
		Needs       []string `json:"needs,omitempty"`
		Column      int32    `json:"column"`
		Matrix      int32    `json:"matrix,omitempty"`
		Environment string   `json:"environment,omitempty"`
		Condition   string   `json:"condition,omitempty"`
		Skipped     string   `json:"skipped,omitempty"`
		Manual      bool     `json:"manual,omitempty"`
		Uses        string   `json:"uses,omitempty"`
	}
	type newest struct {
		ID         int64  `json:"id"`
		Status     string `json:"status"`
		Conclusion string `json:"conclusion,omitempty"`
		Commit     string `json:"from_commit,omitempty"`
		URL        string `json:"url,omitempty"`
	}
	type lane struct {
		Workflow   string  `json:"workflow"`
		Name       string  `json:"name"`
		Kind       string  `json:"kind"`
		After      string  `json:"after,omitempty"`
		Why        string  `json:"why,omitempty"`
		ParseError string  `json:"parse_error,omitempty"`
		Jobs       []job   `json:"jobs"`
		NewestRun  *newest `json:"newest_run,omitempty"`
	}
	type skipped struct {
		Workflow string `json:"workflow"`
		Name     string `json:"name"`
		Reason   string `json:"reason"`
	}
	type changes struct {
		Applies bool   `json:"applies"`
		Known   bool   `json:"known"`
		Count   uint32 `json:"count"`
		Against string `json:"against,omitempty"`
		Note    string `json:"note,omitempty"`
	}
	out := struct {
		Workspace       string     `json:"workspace"`
		Branch          string     `json:"branch,omitempty"`
		Scenario        *scenario  `json:"scenario"`
		Scenarios       []scenario `json:"scenarios"`
		PullRequestBase string     `json:"pull_request_base,omitempty"`
		Changes         *changes   `json:"changes,omitempty"`
		Lanes           []lane     `json:"lanes"`
		Skipped         []skipped  `json:"skipped"`
	}{Workspace: w.name, Branch: w.branch, Scenario: scenarioOf(flow.GetScenario()), Scenarios: scenariosOf(flow.GetScenarios()),
		PullRequestBase: flow.GetPullRequestBase(), Lanes: []lane{}, Skipped: []skipped{}}
	if ch := flow.GetChanges(); ch != nil {
		out.Changes = &changes{Applies: ch.GetApplies(), Known: ch.GetKnown(), Count: ch.GetCount(), Against: ch.GetAgainst(), Note: ch.GetNote()}
	}
	for _, l := range flow.GetLanes() {
		item := lane{Workflow: l.GetWorkflowPath(), Name: l.GetWorkflowName(), Kind: lowerName(l.GetKind().String(), "LANE_KIND_"),
			After: l.GetAfterPath(), Why: l.GetWhy(), ParseError: l.GetParseError(), Jobs: []job{}}
		for _, j := range l.GetJobs() {
			item.Jobs = append(item.Jobs, job{ID: j.GetId(), Name: j.GetName(), Needs: j.GetNeeds(), Column: j.GetColumn(), Matrix: j.GetMatrix(),
				Environment: j.GetEnvironment(), Condition: j.GetCondition(), Skipped: j.GetSkipped(), Manual: j.GetManual(), Uses: j.GetUses()})
		}
		if r := l.GetRun(); r != nil && r.GetId() != 0 {
			item.NewestRun = &newest{ID: r.GetId(), Status: r.GetStatus(), Conclusion: r.GetConclusion(), Commit: l.GetStatusesFrom(), URL: r.GetHtmlUrl()}
		}
		out.Lanes = append(out.Lanes, item)
	}
	for _, s := range flow.GetSkipped() {
		out.Skipped = append(out.Skipped, skipped{Workflow: s.GetWorkflowPath(), Name: s.GetWorkflowName(), Reason: s.GetReason()})
	}
	return result("", out)
}

// maxCachedRuns is how many cached runs a lookup by id reads.
const maxCachedRuns = 5000

func (t *Tools) listRuns(c *call) (Result, error) {
	var a struct {
		Repository *string `json:"repository"`
		Branch     *string `json:"branch"`
		Workflow   *string `json:"workflow"`
		Status     *string `json:"status"`
		Event      *string `json:"event"`
		Query      *string `json:"query"`
		Limit      *int    `json:"limit"`
		Refresh    *bool   `json:"refresh"`
	}
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	var terms []string
	for _, f := range []struct {
		key   string
		value *string
	}{{"branch", a.Branch}, {"status", a.Status}, {"event", a.Event}} {
		if f.value == nil || *f.value == "" {
			continue
		}
		if strings.ContainsAny(*f.value, " \t\n") {
			return Result{}, refuse("%s cannot hold spaces.", f.key)
		}
		terms = append(terms, f.key+":"+*f.value)
	}
	if a.Query != nil && strings.TrimSpace(*a.Query) != "" {
		terms = append(terms, strings.TrimSpace(*a.Query))
	}
	limit := bounded(a.Limit, 20, 100)
	w, err := t.open(c, a.Repository, false)
	if err != nil {
		return Result{}, err
	}
	if a.Refresh != nil && *a.Refresh {
		ctx, cancel := context.WithTimeout(c.ctx, 30*time.Second)
		_, _ = t.core.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: w.id, Wait: true, Limit: 1})
		cancel()
	}
	activity, err := t.core.GetWorkspaceActivity(c.ctx, &corev1.GetWorkspaceActivityRequest{RepositoryId: w.id, Limit: maxCachedRuns})
	if err != nil {
		return Result{}, err
	}
	runs := activity.GetRuns()
	var problems []string
	if len(terms) > 0 {
		found, err := t.core.SearchRuns(c.ctx, &corev1.SearchRunsRequest{RepositoryId: w.id, Query: strings.Join(terms, " "), Limit: 200})
		if err != nil {
			return Result{}, err
		}
		problems = found.GetProblems()
		byID := map[int64]*corev1.WorkflowRun{}
		for _, r := range activity.GetRuns() {
			byID[r.GetId()] = r
		}
		runs = nil
		for _, id := range found.GetCachedRunIds() {
			if r := byID[id]; r != nil {
				runs = append(runs, r)
			}
		}
		runs = append(runs, found.GetIndexedRuns()...)
	}
	if a.Workflow != nil && *a.Workflow != "" {
		ids, err := gitHubWorkflowIDs(activity.GetWorkflows(), *a.Workflow)
		if err != nil {
			return Result{}, err
		}
		var kept []*corev1.WorkflowRun
		for _, r := range runs {
			if ids[r.GetWorkflowId()] {
				kept = append(kept, r)
			}
		}
		runs = kept
	}
	out := struct {
		Workspace string   `json:"workspace"`
		Runs      []run    `json:"runs"`
		More      bool     `json:"more,omitempty"`
		SyncedAt  string   `json:"synced_at,omitempty"`
		Problem   string   `json:"github_problem,omitempty"`
		Problems  []string `json:"query_problems,omitempty"`
	}{Workspace: w.name, Runs: []run{}, SyncedAt: stamp(activity.GetFreshness().GetSyncedAt()),
		Problem: gitHubProblem(activity.GetFreshness().GetStatus()), Problems: problems}
	for i, r := range runs {
		if i == limit {
			out.More = true
			break
		}
		out.Runs = append(out.Runs, runOf(r))
	}
	return result("", out)
}

// gitHubWorkflowIDs are the GitHub workflows a path, file name or name
// names.
func gitHubWorkflowIDs(workflows []*corev1.GitHubWorkflow, asked string) (map[int64]bool, error) {
	asked = strings.TrimSpace(strings.TrimPrefix(asked, "./"))
	ids := map[int64]bool{}
	for _, w := range workflows {
		if w.GetPath() == asked || w.GetPath() == ".github/workflows/"+asked || path.Base(w.GetPath()) == asked || strings.EqualFold(w.GetName(), asked) {
			ids[w.GetId()] = true
		}
	}
	if len(ids) > 0 {
		return ids, nil
	}
	var names []string
	for _, w := range workflows {
		names = append(names, fmt.Sprintf("%s (%s)", w.GetName(), w.GetPath()))
	}
	sort.Strings(names)
	if len(names) == 0 {
		return nil, refuse("Runnir knows no workflow of this repository on GitHub yet.")
	}
	return nil, refuse("No workflow on GitHub matches %s. Its workflows: %s.", asked, strings.Join(names, ", "))
}

// cachedRun is a run of the activity cache by id; nil when it is not there.
func (t *Tools) cachedRun(ctx context.Context, w workspace, id int64) *corev1.WorkflowRun {
	activity, err := t.core.GetWorkspaceActivity(ctx, &corev1.GetWorkspaceActivityRequest{RepositoryId: w.id, Limit: maxCachedRuns})
	if err != nil {
		return nil
	}
	for _, r := range activity.GetRuns() {
		if r.GetId() == id {
			return r
		}
	}
	return nil
}

func (t *Tools) getRun(c *call) (Result, error) {
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
	w, err := t.open(c, a.Repository, false)
	if err != nil {
		return Result{}, err
	}
	c.note("run %d", *a.RunID)
	jobs, err := t.core.ListRunJobs(c.ctx, &corev1.ListRunJobsRequest{RepositoryId: w.id, RunId: *a.RunID})
	if err != nil {
		return Result{}, err
	}
	if problem := gitHubProblem(jobs.GetStatus()); problem != "" {
		return Result{}, refusal(problem)
	}
	type step struct {
		Number     int64  `json:"number"`
		Name       string `json:"name"`
		Status     string `json:"status"`
		Conclusion string `json:"conclusion,omitempty"`
	}
	type job struct {
		ID          int64  `json:"id"`
		Name        string `json:"name"`
		WorkflowJob string `json:"workflow_job,omitempty"`
		Status      string `json:"status"`
		Conclusion  string `json:"conclusion,omitempty"`
		StartedAt   string `json:"started_at,omitempty"`
		CompletedAt string `json:"completed_at,omitempty"`
		URL         string `json:"url,omitempty"`
		Steps       []step `json:"steps"`
	}
	type skip struct {
		Job        string   `json:"job"`
		Kind       string   `json:"kind"`
		Need       string   `json:"need,omitempty"`
		NeedResult string   `json:"need_result,omitempty"`
		Condition  string   `json:"condition,omitempty"`
		Unknown    []string `json:"unknown,omitempty"`
		Note       string   `json:"note,omitempty"`
	}
	out := struct {
		Workspace    string  `json:"workspace"`
		Run          *run    `json:"run,omitempty"`
		WorkflowPath string  `json:"workflow_path,omitempty"`
		Jobs         []job   `json:"jobs"`
		FailedJobs   []int64 `json:"failed_jobs,omitempty"`
		Skips        []skip  `json:"skips,omitempty"`
		Note         string  `json:"note,omitempty"`
	}{Workspace: w.name, Jobs: []job{}}
	if r := t.cachedRun(c.ctx, w, *a.RunID); r != nil {
		summary := runOf(r)
		out.Run = &summary
	}
	for _, j := range jobs.GetJobs() {
		item := job{ID: j.GetId(), Name: j.GetName(), WorkflowJob: j.GetWorkflowJobId(), Status: j.GetStatus(), Conclusion: j.GetConclusion(),
			StartedAt: stamp(j.GetStartedAt()), CompletedAt: stamp(j.GetCompletedAt()), URL: j.GetHtmlUrl(), Steps: []step{}}
		for _, s := range j.GetSteps() {
			item.Steps = append(item.Steps, step{Number: s.GetNumber(), Name: s.GetName(), Status: s.GetStatus(), Conclusion: s.GetConclusion()})
		}
		if c := j.GetConclusion(); c == "failure" || c == "timed_out" || c == "startup_failure" {
			out.FailedJobs = append(out.FailedJobs, j.GetId())
		}
		out.Jobs = append(out.Jobs, item)
	}
	attempt := int64(0)
	if out.Run != nil {
		attempt = out.Run.Attempt
	}
	if graph, err := t.core.GetRunWorkflow(c.ctx, &corev1.GetRunWorkflowRequest{RepositoryId: w.id, RunId: *a.RunID, RunAttempt: attempt}); err == nil {
		out.WorkflowPath = graph.GetWorkflowPath()
		for _, s := range graph.GetSkips() {
			out.Skips = append(out.Skips, skip{Job: s.GetJobId(), Kind: lowerName(s.GetKind().String(), "SKIP_KIND_"), Need: s.GetNeed(),
				NeedResult: s.GetNeedResult(), Condition: s.GetCondition(), Unknown: s.GetUnknown(), Note: s.GetNote()})
		}
	}
	if out.Run == nil {
		out.Note = "Runnir has not saved this run yet, so only its jobs are shown; runnir_list_runs with refresh reads new runs."
	}
	return result("", out)
}

func (t *Tools) getJobLog(c *call) (Result, error) {
	var a struct {
		Repository *string `json:"repository"`
		JobID      *int64  `json:"job_id"`
		Step       *int64  `json:"step"`
		Search     *string `json:"search"`
		Lines      *int    `json:"lines"`
	}
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	if a.JobID == nil || *a.JobID <= 0 {
		return Result{}, refuse("Give job_id, a job's id from runnir_get_run.")
	}
	limit := bounded(a.Lines, 200, 2000)
	w, err := t.open(c, a.Repository, false)
	if err != nil {
		return Result{}, err
	}
	c.note("job %d", *a.JobID)
	log, err := t.core.GetJobLog(c.ctx, &corev1.GetJobLogRequest{RepositoryId: w.id, JobId: *a.JobID})
	if err != nil {
		return Result{}, err
	}
	if problem := gitHubProblem(log.GetStatus()); problem != "" {
		return Result{}, refusal(problem)
	}
	switch log.GetAvailability() {
	case corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_EXPIRED:
		return Result{}, refuse("GitHub no longer has this job's log: its retention passed or it was deleted.")
	case corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_NOT_READY:
		return Result{}, refuse("This job's log is not ready: the job has not finished, or GitHub is still storing it. Ask again shortly.")
	}
	type line struct {
		Number int64  `json:"n"`
		Step   int64  `json:"step,omitempty"`
		Kind   string `json:"kind,omitempty"`
		Text   string `json:"text"`
	}
	lineOf := func(l *corev1.LogLine) line {
		kind := lowerName(l.GetKind().String(), "LOG_LINE_KIND_")
		if kind == "plain" {
			kind = ""
		}
		return line{Number: l.GetNumber(), Step: l.GetStepNumber(), Kind: kind, Text: clip(l.GetText(), maxLineBytes)}
	}
	var matched []*corev1.LogLine
	search := ""
	if a.Search != nil {
		search = strings.ToLower(*a.Search)
	}
	errorsOut := []line{}
	for _, l := range log.GetLines() {
		if l.GetKind() == corev1.LogLineKind_LOG_LINE_KIND_ERROR && len(errorsOut) < maxErrorLines {
			errorsOut = append(errorsOut, lineOf(l))
		}
		if a.Step != nil && l.GetStepNumber() != *a.Step {
			continue
		}
		if search != "" && !strings.Contains(strings.ToLower(l.GetText()), search) {
			continue
		}
		matched = append(matched, l)
	}
	out := struct {
		JobID        int64  `json:"job_id"`
		TotalLines   int64  `json:"total_lines"`
		Matched      int    `json:"matched"`
		Lines        []line `json:"lines"`
		Errors       []line `json:"errors"`
		Truncated    bool   `json:"earlier_lines_dropped,omitempty"`
		StoppedEarly bool   `json:"log_larger_than_read,omitempty"`
	}{JobID: *a.JobID, Matched: len(matched), Lines: []line{}, Errors: errorsOut,
		Truncated: log.GetTruncated(), StoppedEarly: log.GetStoppedEarly()}
	if all := log.GetLines(); len(all) > 0 {
		out.TotalLines = all[len(all)-1].GetNumber()
	}
	// The newest lines that fit both bounds, in order.
	first, size := len(matched), 0
	for first > 0 && len(matched)-first < limit {
		next := len(clip(matched[first-1].GetText(), maxLineBytes))
		if size+next > maxLinesBytes {
			break
		}
		size += next
		first--
	}
	out.Truncated = out.Truncated || first > 0
	for _, l := range matched[first:] {
		out.Lines = append(out.Lines, lineOf(l))
	}
	return result("", out)
}

func (t *Tools) listPullRequests(c *call) (Result, error) {
	var a struct {
		GitHubRepository *string `json:"github_repository"`
	}
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	listed, err := t.core.ListPullRequests(c.ctx, &corev1.ListPullRequestsRequest{})
	if err != nil {
		return Result{}, err
	}
	if problem := gitHubProblem(listed.GetStatus()); problem != "" {
		return Result{}, refusal(problem)
	}
	type pull struct {
		Repository string `json:"repository"`
		Number     int64  `json:"number"`
		Title      string `json:"title"`
		State      string `json:"state"`
		Draft      bool   `json:"draft,omitempty"`
		Branch     string `json:"branch"`
		UpdatedAt  string `json:"updated_at,omitempty"`
		ClosedAt   string `json:"closed_at,omitempty"`
		URL        string `json:"url"`
		CI         string `json:"ci"`
		CIRuns     int32  `json:"ci_runs,omitempty"`
		CIFailed   int32  `json:"ci_failed,omitempty"`
		CIRunning  int32  `json:"ci_running,omitempty"`
		CIURL      string `json:"ci_url,omitempty"`
	}
	keep := func(list []*corev1.PullRequest) []pull {
		out := []pull{}
		for _, p := range list {
			if a.GitHubRepository != nil && *a.GitHubRepository != "" && !strings.EqualFold(p.GetRepository(), *a.GitHubRepository) {
				continue
			}
			out = append(out, pull{Repository: p.GetRepository(), Number: p.GetNumber(), Title: clip(p.GetTitle(), 300), State: p.GetState(),
				Draft: p.GetDraft(), Branch: p.GetHeadBranch(), UpdatedAt: stamp(p.GetUpdatedAt()), ClosedAt: stamp(p.GetClosedAt()),
				URL: p.GetHtmlUrl(), CI: lowerName(p.GetCi().String(), "PULL_REQUEST_CI_"), CIRuns: p.GetCiRuns(), CIFailed: p.GetCiFailed(),
				CIRunning: p.GetCiRunning(), CIURL: p.GetCiUrl()})
		}
		return out
	}
	out := struct {
		Open            []pull `json:"open"`
		Closed          []pull `json:"closed"`
		HeadsUnreadable bool   `json:"ci_unknown_for_some,omitempty"`
	}{Open: keep(listed.GetOpen()), Closed: keep(listed.GetClosed()), HeadsUnreadable: listed.GetHeadsUnreadable()}
	return result("", out)
}
