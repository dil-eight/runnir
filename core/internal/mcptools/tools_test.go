package mcptools

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/mcpbridge"
)

// fakeCore answers with what a test put in it and keeps what it was asked.
type fakeCore struct {
	mu        sync.Mutex
	workflows []*corev1.Workflow
	validated *corev1.ValidateWorkflowsResponse
	flow      *corev1.GetFlowResponse
	asked     []any
	activity  *corev1.WorkspaceActivity
	search    *corev1.SearchRunsResponse
	jobs      *corev1.ListRunJobsResponse
	graph     *corev1.GetRunWorkflowResponse
	log       *corev1.GetJobLogResponse
	pulls     *corev1.ListPullRequestsResponse
	remote    *corev1.ListGitHubWorkflowsResponse
	prepared  *corev1.PrepareWorkflowDispatchResponse
	sent      *corev1.ConfirmWorkflowDispatchResponse
	action    *corev1.PrepareRunActionResponse
	done      *corev1.ConfirmRunActionResponse
	// outputs are the answers of GetLocalRunOutput in turn; the last repeats.
	outputs   []*corev1.GetLocalRunOutputResponse
	cancelled []string
	source    string
	local     []LocalRunSummary
}

func (f *fakeCore) note(r any) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.asked = append(f.asked, r)
}

func (f *fakeCore) ListWorkflows(_ context.Context, r *corev1.ListWorkflowsRequest) (*corev1.ListWorkflowsResponse, error) {
	f.note(r)
	return &corev1.ListWorkflowsResponse{Workflows: f.workflows}, nil
}
func (f *fakeCore) ValidateWorkflows(_ context.Context, r *corev1.ValidateWorkflowsRequest) (*corev1.ValidateWorkflowsResponse, error) {
	f.note(r)
	if f.validated == nil {
		return &corev1.ValidateWorkflowsResponse{}, nil
	}
	return f.validated, nil
}
func (f *fakeCore) GetFlow(_ context.Context, r *corev1.GetFlowRequest) (*corev1.GetFlowResponse, error) {
	f.note(r)
	return f.flow, nil
}
func (f *fakeCore) GetWorkspaceActivity(_ context.Context, r *corev1.GetWorkspaceActivityRequest) (*corev1.WorkspaceActivity, error) {
	f.note(r)
	if f.activity == nil {
		return &corev1.WorkspaceActivity{}, nil
	}
	return f.activity, nil
}
func (f *fakeCore) RefreshWorkspaceActivity(_ context.Context, r *corev1.RefreshWorkspaceActivityRequest) (*corev1.WorkspaceActivity, error) {
	f.note(r)
	return f.activity, nil
}
func (f *fakeCore) SearchRuns(_ context.Context, r *corev1.SearchRunsRequest) (*corev1.SearchRunsResponse, error) {
	f.note(r)
	return f.search, nil
}
func (f *fakeCore) ListRunJobs(_ context.Context, r *corev1.ListRunJobsRequest) (*corev1.ListRunJobsResponse, error) {
	f.note(r)
	return f.jobs, nil
}
func (f *fakeCore) GetRunWorkflow(_ context.Context, r *corev1.GetRunWorkflowRequest) (*corev1.GetRunWorkflowResponse, error) {
	f.note(r)
	if f.graph == nil {
		return nil, status.Error(codes.NotFound, "no workflow")
	}
	return f.graph, nil
}
func (f *fakeCore) GetJobLog(_ context.Context, r *corev1.GetJobLogRequest) (*corev1.GetJobLogResponse, error) {
	f.note(r)
	return f.log, nil
}
func (f *fakeCore) ListPullRequests(_ context.Context, r *corev1.ListPullRequestsRequest) (*corev1.ListPullRequestsResponse, error) {
	f.note(r)
	return f.pulls, nil
}
func (f *fakeCore) GetGitHubOrigins(_ context.Context, r *corev1.GetGitHubOriginsRequest) (*corev1.GetGitHubOriginsResponse, error) {
	var out []*corev1.GitHubOrigin
	for _, p := range r.GetPaths() {
		out = append(out, &corev1.GitHubOrigin{Path: p, GithubRepository: "acme/" + p[strings.LastIndex(p, "/")+1:]})
	}
	return &corev1.GetGitHubOriginsResponse{Origins: out}, nil
}
func (f *fakeCore) ListGitHubWorkflows(_ context.Context, r *corev1.ListGitHubWorkflowsRequest) (*corev1.ListGitHubWorkflowsResponse, error) {
	f.note(r)
	return f.remote, nil
}
func (f *fakeCore) PrepareWorkflowDispatch(_ context.Context, r *corev1.PrepareWorkflowDispatchRequest) (*corev1.PrepareWorkflowDispatchResponse, error) {
	f.note(r)
	return f.prepared, nil
}
func (f *fakeCore) ConfirmWorkflowDispatch(_ context.Context, r *corev1.ConfirmWorkflowDispatchRequest) (*corev1.ConfirmWorkflowDispatchResponse, error) {
	f.note(r)
	return f.sent, nil
}
func (f *fakeCore) PrepareRunAction(_ context.Context, r *corev1.PrepareRunActionRequest) (*corev1.PrepareRunActionResponse, error) {
	f.note(r)
	return f.action, nil
}
func (f *fakeCore) ConfirmRunAction(_ context.Context, r *corev1.ConfirmRunActionRequest) (*corev1.ConfirmRunActionResponse, error) {
	f.note(r)
	return f.done, nil
}
func (f *fakeCore) GetLocalRunOutput(_ context.Context, r *corev1.GetLocalRunOutputRequest) (*corev1.GetLocalRunOutputResponse, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.outputs) == 0 {
		return nil, status.Error(codes.NotFound, "no local run with this id")
	}
	out := f.outputs[0]
	if len(f.outputs) > 1 {
		f.outputs = f.outputs[1:]
	}
	// As the Core does: only the lines after the sequence asked.
	copied := proto.Clone(out).(*corev1.GetLocalRunOutputResponse)
	copied.Lines = nil
	for _, l := range out.Lines {
		if l.GetSequence() > r.GetAfterSequence() {
			copied.Lines = append(copied.Lines, l)
		}
	}
	return copied, nil
}
func (f *fakeCore) CancelExecution(_ context.Context, r *corev1.CancelExecutionRequest) (*corev1.CancelExecutionResponse, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.cancelled = append(f.cancelled, r.GetExecutionId())
	return &corev1.CancelExecutionResponse{}, nil
}
func (f *fakeCore) WorkflowSource(_, _ string) ([]byte, error) { return []byte(f.source), nil }
func (f *fakeCore) LocalRuns(context.Context, string, int) ([]LocalRunSummary, error) {
	return f.local, nil
}

// fakeApp is the app: one workspace, actions on unless turned off.
type fakeApp struct {
	actionsOff bool
	opened     []*corev1.McpRequest
	start      *corev1.McpLocalRunStart
	set        *corev1.McpRequest
}

func (a *fakeApp) Workspaces(context.Context, string) (*corev1.McpWorkspaces, error) {
	return &corev1.McpWorkspaces{Workspaces: []*corev1.McpWorkspace{{Name: "shop", Path: "/Users/me/shop", Open: true}}}, nil
}
func (a *fakeApp) Open(_ context.Context, client, repository string, action bool) (*corev1.McpOpenedWorkspace, error) {
	a.opened = append(a.opened, &corev1.McpRequest{Client: client, Repository: repository, Action: action})
	if action && a.actionsOff {
		return nil, mcpbridge.Refusal("Actions are turned off in Runnir › Settings › MCP.")
	}
	if repository != "/Users/me/shop" && repository != "shop" {
		return nil, mcpbridge.Refusal("Runnir has no workspace for " + repository + ".")
	}
	return &corev1.McpOpenedWorkspace{Workspace: &corev1.McpWorkspace{Name: "shop", Path: "/Users/me/shop"}, RepositoryId: "repo_1", Branch: "feature"}, nil
}
func (a *fakeApp) Start(_ context.Context, _, _ string, start *corev1.McpLocalRunStart) (*corev1.McpLocalRunStarted, error) {
	if a.actionsOff {
		return nil, mcpbridge.Refusal("Actions are turned off in Runnir › Settings › MCP.")
	}
	a.start = start
	return &corev1.McpLocalRunStarted{Workspace: "shop", ExecutionId: "exec_1", Passed: []string{"API_KEY"}, Empty: []string{"REGION"}}, nil
}
func (a *fakeApp) List(context.Context, string, string) (*corev1.McpValueSets, error) {
	return &corev1.McpValueSets{Workspace: "shop", Sets: []*corev1.McpValueSet{{Name: "Repository", Names: []*corev1.McpValueName{
		{Name: "API_KEY", Secret: true, State: corev1.McpValueState_MCP_VALUE_STATE_SAVED, Value: "leaked"},
		{Name: "REGION", State: corev1.McpValueState_MCP_VALUE_STATE_SAVED, Value: "eu"},
	}}}}, nil
}
func (a *fakeApp) Set(_ context.Context, r *corev1.McpRequest) (*corev1.McpSavedValues, error) {
	a.set = r
	return &corev1.McpSavedValues{Workspace: "shop", Set: r.GetSet(), Secrets: []string{"API_KEY"}}, nil
}

func tools(core *fakeCore, app *fakeApp) (*Tools, *bytes.Buffer) {
	log := &bytes.Buffer{}
	t := New(core, app, log)
	t.poll = time.Millisecond
	return t, log
}

func invoke(t *testing.T, tl *Tools, name, args string) Result {
	t.Helper()
	return tl.Call(context.Background(), "claude-code", name, json.RawMessage(args))
}

// structured reads a result's structured content as JSON.
func structured(t *testing.T, r Result) map[string]any {
	t.Helper()
	if r.IsError {
		t.Fatalf("error: %s", r.Text)
	}
	data, err := json.Marshal(r.Structured)
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(data, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(r.Text, string(data)) {
		t.Fatalf("the text does not hold the structured content: %s", r.Text)
	}
	return out
}

func refused(t *testing.T, r Result, words string) {
	t.Helper()
	if !r.IsError || !strings.Contains(r.Text, words) {
		t.Fatalf("result = %+v, want a refusal with %q", r, words)
	}
}

func TestEveryToolOfTheCatalogHasAHandler(t *testing.T) {
	tl, _ := tools(&fakeCore{}, &fakeApp{})
	seen := map[string]bool{}
	for _, tool := range Catalog {
		if tl.handle[tool.Name] == nil || seen[tool.Name] {
			t.Errorf("%s: no handler or listed twice", tool.Name)
		}
		seen[tool.Name] = true
		var schema map[string]any
		if err := json.Unmarshal(tool.InputSchema, &schema); err != nil || schema["type"] != "object" {
			t.Errorf("%s: schema %s: %v", tool.Name, tool.InputSchema, err)
		}
	}
	if len(tl.handle) != len(Catalog) {
		t.Fatalf("%d handlers for %d tools", len(tl.handle), len(Catalog))
	}
	refused(t, invoke(t, tl, "runnir_nothing", `{}`), "no tool")
}

func TestArgumentsAreReadStrictly(t *testing.T) {
	tl, _ := tools(&fakeCore{}, &fakeApp{})
	refused(t, invoke(t, tl, ListWorkflows, `{"repository":"shop","extra":1}`), `"extra" is not an argument`)
	refused(t, invoke(t, tl, GetRun, `{"repository":"shop","run_id":"x"}`), "run_id must be a int64")
	refused(t, invoke(t, tl, ListWorkflows, `{}`), "Name a repository")
	refused(t, invoke(t, tl, ListWorkflows, `{"repository":"/elsewhere"}`), "no workspace for /elsewhere")
}

func TestWorkspacesCarryTheirGitHubRepository(t *testing.T) {
	tl, _ := tools(&fakeCore{}, &fakeApp{})
	out := structured(t, invoke(t, tl, ListWorkspaces, `{}`))
	ws := out["workspaces"].([]any)[0].(map[string]any)
	if ws["name"] != "shop" || ws["github_repository"] != "acme/shop" || ws["open"] != true {
		t.Fatalf("workspaces = %v", out)
	}
}

func ciWorkflows() []*corev1.Workflow {
	return []*corev1.Workflow{
		{Id: ".github/workflows/ci.yml", Name: "CI", Triggers: []string{"pull_request"}, Jobs: []*corev1.Job{
			{Id: "test", Secrets: []string{"API_KEY"}}, {Id: "lint", Needs: []string{"test"}}}},
		{Id: ".github/workflows/release.yml", Name: "Release", Triggers: []string{"workflow_dispatch"},
			DispatchInputs: []*corev1.DispatchInput{{Name: "channel", Type: corev1.DispatchInputType_DISPATCH_INPUT_TYPE_CHOICE, Options: []string{"beta"}}}},
	}
}

func TestWorkflowsAreListedWithTheirProblems(t *testing.T) {
	core := &fakeCore{workflows: ciWorkflows(), validated: &corev1.ValidateWorkflowsResponse{Workflows: []*corev1.WorkflowValidation{
		{WorkflowId: ".github/workflows/ci.yml", Diagnostics: []*corev1.WorkflowDiagnostic{{Line: 3, Message: "bad"}}}}}}
	app := &fakeApp{}
	tl, log := tools(core, app)
	out := structured(t, invoke(t, tl, ListWorkflows, `{"repository":"/Users/me/shop"}`))
	workflows := out["workflows"].([]any)
	ci, release := workflows[0].(map[string]any), workflows[1].(map[string]any)
	if out["branch"] != "feature" || ci["problems"] != 1.0 || release["problems"] != 0.0 || release["dispatch_inputs"] == nil {
		t.Fatalf("out = %v", out)
	}
	if app.opened[0].Action {
		t.Fatal("reading asked as an action")
	}
	if !strings.Contains(log.String(), `mcp: list_workflows client "claude-code" workspace "shop": ok`) {
		t.Fatalf("log = %q", log.String())
	}
}

func TestAWorkflowIsFoundByPathFileOrName(t *testing.T) {
	core := &fakeCore{workflows: ciWorkflows(), source: "name: CI\n", validated: &corev1.ValidateWorkflowsResponse{Validator: "actionlint",
		Workflows: []*corev1.WorkflowValidation{{WorkflowId: ".github/workflows/ci.yml", Diagnostics: []*corev1.WorkflowDiagnostic{{Line: 3, Column: 5, Kind: "syntax-check", Message: "bad"}}}}}}
	tl, _ := tools(core, &fakeApp{})
	for _, asked := range []string{".github/workflows/ci.yml", "ci.yml", "ci"} {
		out := structured(t, invoke(t, tl, GetWorkflow, `{"repository":"shop","workflow":"`+asked+`"}`))
		wf := out["workflow"].(map[string]any)
		if wf["path"] != ".github/workflows/ci.yml" || out["source"] != "name: CI\n" || len(out["problems"].([]any)) != 1 {
			t.Fatalf("%s: out = %v", asked, out)
		}
		if job := wf["jobs"].([]any)[0].(map[string]any); job["secrets"] == nil {
			t.Fatalf("jobs = %v", wf["jobs"])
		}
	}
	refused(t, invoke(t, tl, GetWorkflow, `{"repository":"shop","workflow":"deploy"}`), "ci.yml, .github/workflows/release.yml")
}

func TestAScenarioIsPlannedAsAsked(t *testing.T) {
	core := &fakeCore{flow: &corev1.GetFlowResponse{
		Scenario: &corev1.Scenario{Kind: corev1.ScenarioKind_SCENARIO_KIND_TAG, Target: "v1", Title: "Tag v1"},
		Lanes: []*corev1.FlowLane{{WorkflowPath: ".github/workflows/release.yml", Kind: corev1.LaneKind_LANE_KIND_DIRECT,
			Jobs: []*corev1.FlowJob{{Id: "build", Skipped: "if is false"}}, Run: &corev1.WorkflowRun{Id: 9, Status: "completed", Conclusion: "failure"}}},
		Skipped: []*corev1.SkippedWorkflow{{WorkflowPath: ".github/workflows/ci.yml", Reason: "no tag trigger"}},
	}}
	tl, _ := tools(core, &fakeApp{})
	out := structured(t, invoke(t, tl, PlanScenario, `{"repository":"shop","scenario":"tag","target":"v1"}`))
	asked := core.asked[0].(*corev1.GetFlowRequest)
	if asked.GetScenario().GetKind() != corev1.ScenarioKind_SCENARIO_KIND_TAG || asked.GetScenario().GetTarget() != "v1" {
		t.Fatalf("asked = %v", asked)
	}
	lane := out["lanes"].([]any)[0].(map[string]any)
	if lane["kind"] != "direct" || lane["newest_run"].(map[string]any)["conclusion"] != "failure" || out["scenario"].(map[string]any)["kind"] != "tag" {
		t.Fatalf("out = %v", out)
	}
	refused(t, invoke(t, tl, PlanScenario, `{"repository":"shop","scenario":"deploy"}`), "scenario must be")
	refused(t, invoke(t, tl, PlanScenario, `{"repository":"shop","target":"main"}`), "Give a scenario")
}

func TestRunsAreFilteredAndBounded(t *testing.T) {
	var runs []*corev1.WorkflowRun
	for i := int64(1); i <= 30; i++ {
		runs = append(runs, &corev1.WorkflowRun{Id: i, WorkflowId: 100 + i%2, HeadSha: "abcdef1234", StatusGroup: corev1.RunStatusGroup_RUN_STATUS_GROUP_FAILED,
			RunnirStarts: map[bool][]*corev1.RunnirStart{true: {{Attempt: 1}}}[i == 1]})
	}
	core := &fakeCore{
		activity: &corev1.WorkspaceActivity{Runs: runs, Workflows: []*corev1.GitHubWorkflow{{Id: 100, Name: "CI", Path: ".github/workflows/ci.yml"}, {Id: 101, Name: "Release", Path: ".github/workflows/release.yml"}},
			Freshness: &corev1.ActivityFreshness{Status: &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED}}},
		search: &corev1.SearchRunsResponse{CachedRunIds: []int64{2, 3, 4}, IndexedRuns: []*corev1.WorkflowRun{{Id: 999, WorkflowId: 100}}},
	}
	tl, _ := tools(core, &fakeApp{})
	out := structured(t, invoke(t, tl, ListRuns, `{"repository":"shop"}`))
	if len(out["runs"].([]any)) != 20 || out["more"] != true || !strings.Contains(out["github_problem"].(string), "rate limit") {
		t.Fatalf("out = %v", out)
	}
	first := out["runs"].([]any)[0].(map[string]any)
	if first["commit"] != "abcdef1" || first["status_group"] != "failed" || first["started_from_runnir"] != true {
		t.Fatalf("run = %v", first)
	}
	out = structured(t, invoke(t, tl, ListRuns, `{"repository":"shop","branch":"main","status":"failed","workflow":"ci.yml","query":"author:me"}`))
	var query string
	for _, a := range core.asked {
		if s, ok := a.(*corev1.SearchRunsRequest); ok {
			query = s.GetQuery()
		}
	}
	if query != "branch:main status:failed author:me" {
		t.Fatalf("query = %q", query)
	}
	var ids []float64
	for _, r := range out["runs"].([]any) {
		ids = append(ids, r.(map[string]any)["id"].(float64))
	}
	if len(ids) != 3 || ids[0] != 2 || ids[1] != 4 || ids[2] != 999 {
		t.Fatalf("ids = %v", ids)
	}
	refused(t, invoke(t, tl, ListRuns, `{"repository":"shop","workflow":"deploy"}`), "CI (.github/workflows/ci.yml)")
	refused(t, invoke(t, tl, ListRuns, `{"repository":"shop","branch":"a b"}`), "cannot hold spaces")
}

func TestARunShowsItsJobsAndWhySomeWereSkipped(t *testing.T) {
	core := &fakeCore{
		activity: &corev1.WorkspaceActivity{Runs: []*corev1.WorkflowRun{{Id: 7, RunAttempt: 2, Name: "CI"}}},
		jobs: &corev1.ListRunJobsResponse{Jobs: []*corev1.RunJob{
			{Id: 1, Name: "test", Conclusion: "failure", StartedAt: timestamppb.New(time.Unix(1700000000, 0)),
				Steps: []*corev1.RunStep{{Number: 3, Name: "go test", Conclusion: "failure"}}},
			{Id: 2, Name: "deploy", Conclusion: "skipped"}}},
		graph: &corev1.GetRunWorkflowResponse{WorkflowPath: ".github/workflows/ci.yml", Skips: []*corev1.JobSkip{{JobId: "deploy", Kind: corev1.SkipKind_SKIP_KIND_NEEDS, Need: "test", NeedResult: "failure"}}},
	}
	tl, _ := tools(core, &fakeApp{})
	out := structured(t, invoke(t, tl, GetRun, `{"repository":"shop","run_id":7}`))
	if out["run"].(map[string]any)["attempt"] != 2.0 || out["failed_jobs"].([]any)[0] != 1.0 || out["workflow_path"] != ".github/workflows/ci.yml" {
		t.Fatalf("out = %v", out)
	}
	skip := out["skips"].([]any)[0].(map[string]any)
	if skip["kind"] != "needs" || skip["need"] != "test" {
		t.Fatalf("skip = %v", skip)
	}
	job := out["jobs"].([]any)[0].(map[string]any)
	if job["started_at"] != "2023-11-14T22:13:20Z" || job["steps"].([]any)[0].(map[string]any)["name"] != "go test" {
		t.Fatalf("job = %v", job)
	}
	core.jobs = &corev1.ListRunJobsResponse{Status: &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT}}
	refused(t, invoke(t, tl, GetRun, `{"repository":"shop","run_id":7}`), "not signed in")
}

func TestAJobLogIsCutToWhatWasAsked(t *testing.T) {
	var lines []*corev1.LogLine
	for i := int64(1); i <= 500; i++ {
		kind := corev1.LogLineKind_LOG_LINE_KIND_PLAIN
		if i%100 == 0 {
			kind = corev1.LogLineKind_LOG_LINE_KIND_ERROR
		}
		lines = append(lines, &corev1.LogLine{Number: i, Text: "line " + strings.Repeat("x", int(i%3)), Kind: kind, StepNumber: 1 + i/250})
	}
	lines = append(lines, &corev1.LogLine{Number: 501, Text: strings.Repeat("y", 10000), StepNumber: 3})
	core := &fakeCore{log: &corev1.GetJobLogResponse{Availability: corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_AVAILABLE, Lines: lines}}
	tl, _ := tools(core, &fakeApp{})
	out := structured(t, invoke(t, tl, GetJobLog, `{"repository":"shop","job_id":5}`))
	got := out["lines"].([]any)
	if len(got) != 200 || got[199].(map[string]any)["n"] != 501.0 || len(got[199].(map[string]any)["text"].(string)) > maxLineBytes+4 {
		t.Fatalf("lines = %d", len(got))
	}
	if len(out["errors"].([]any)) != 5 || out["total_lines"] != 501.0 || out["earlier_lines_dropped"] != true {
		t.Fatalf("out = %v", out["errors"])
	}
	out = structured(t, invoke(t, tl, GetJobLog, `{"repository":"shop","job_id":5,"step":2,"search":"XX","lines":5}`))
	if out["matched"] != 83.0 || len(out["lines"].([]any)) != 5 {
		t.Fatalf("matched = %v", out["matched"])
	}
	core.log = &corev1.GetJobLogResponse{Availability: corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_NOT_READY}
	refused(t, invoke(t, tl, GetJobLog, `{"repository":"shop","job_id":5}`), "not ready")
}

func TestPullRequestsCanBeOfOneRepository(t *testing.T) {
	core := &fakeCore{pulls: &corev1.ListPullRequestsResponse{Open: []*corev1.PullRequest{
		{Repository: "acme/shop", Number: 1, Ci: corev1.PullRequestCi_PULL_REQUEST_CI_FAILED},
		{Repository: "acme/other", Number: 2}}}}
	tl, _ := tools(core, &fakeApp{})
	out := structured(t, invoke(t, tl, ListPullRequests, `{"github_repository":"ACME/shop"}`))
	open := out["open"].([]any)
	if len(open) != 1 || open[0].(map[string]any)["ci"] != "failed" {
		t.Fatalf("open = %v", open)
	}
}

func localOutput(phase corev1.LocalRunPhase, last uint64, lines ...*corev1.LocalRunLine) *corev1.GetLocalRunOutputResponse {
	return &corev1.GetLocalRunOutputResponse{ExecutionId: "exec_1", RepositoryId: "repo_1", Phase: phase, LastSequence: last, Lines: lines,
		State: corev1.ExecutionState_EXECUTION_STATE_RUNNING, ExitCode: -1, StartedBy: "claude-code",
		Plan: &corev1.LocalRunPlan{Scenario: &corev1.Scenario{Title: "Pull request → main"}, Notes: []string{"act differs"},
			Lanes: []*corev1.LocalRunLane{{WorkflowId: ".github/workflows/ci.yml", Jobs: []*corev1.LocalRunJob{{Id: "test", Selected: true}, {Id: "mac"}}}}},
		Jobs: []*corev1.LocalRunJobStatus{{WorkflowId: ".github/workflows/ci.yml", Id: "test", State: corev1.LocalJobState_LOCAL_JOB_STATE_RUNNING}}}
}

func TestALocalRunIsReadInPages(t *testing.T) {
	var lines []*corev1.LocalRunLine
	for i := uint64(1); i <= 10; i++ {
		job := "test"
		if i%2 == 0 {
			job = "lint"
		}
		lines = append(lines, &corev1.LocalRunLine{Sequence: i, JobId: job, Text: "out", Error: i == 9})
	}
	core := &fakeCore{outputs: []*corev1.GetLocalRunOutputResponse{localOutput(corev1.LocalRunPhase_LOCAL_RUN_PHASE_RUNNING, 10, lines...)}}
	tl, _ := tools(core, &fakeApp{})
	out := structured(t, invoke(t, tl, GetLocalRun, `{"repository":"shop","execution_id":"exec_1","after_sequence":2,"lines":3}`))
	got := out["lines"].([]any)
	if len(got) != 3 || got[0].(map[string]any)["seq"] != 3.0 || out["next_after"] != 5.0 || out["more"] != true {
		t.Fatalf("out = %v", out)
	}
	if out["started_by"] != "claude-code" || out["exit_code"] != nil || out["workflows"].([]any)[0].(map[string]any)["jobs"].([]any)[0] != "test" {
		t.Fatalf("out = %v", out)
	}
	out = structured(t, invoke(t, tl, GetLocalRun, `{"repository":"shop","execution_id":"exec_1","job":"test"}`))
	if got := out["lines"].([]any); len(got) != 5 || out["next_after"] != 10.0 || out["more"] != nil {
		t.Fatalf("out = %v", out)
	}
}

func TestWaitingForALocalRun(t *testing.T) {
	running := localOutput(corev1.LocalRunPhase_LOCAL_RUN_PHASE_RUNNING, 4)
	withOutput := localOutput(corev1.LocalRunPhase_LOCAL_RUN_PHASE_RUNNING, 5, &corev1.LocalRunLine{Sequence: 5, Text: "new"})
	finished := localOutput(corev1.LocalRunPhase_LOCAL_RUN_PHASE_FINISHED, 6, &corev1.LocalRunLine{Sequence: 5, Text: "new"}, &corev1.LocalRunLine{Sequence: 6, Text: "done"})
	finished.State, finished.ExitCode = corev1.ExecutionState_EXECUTION_STATE_FAILED, 1

	core := &fakeCore{outputs: []*corev1.GetLocalRunOutputResponse{running, running, withOutput, finished}}
	tl, _ := tools(core, &fakeApp{})
	out := structured(t, invoke(t, tl, GetLocalRun, `{"repository":"shop","execution_id":"exec_1","after_sequence":4,"wait":"output"}`))
	if out["finished"] != false || len(out["lines"].([]any)) != 1 || out["next_after"] != 5.0 {
		t.Fatalf("output: %v", out)
	}
	out = structured(t, invoke(t, tl, GetLocalRun, `{"repository":"shop","execution_id":"exec_1","after_sequence":5,"wait":"end"}`))
	if out["finished"] != true || out["state"] != "failed" || out["exit_code"] != 1.0 || len(out["lines"].([]any)) != 1 {
		t.Fatalf("end: %v", out)
	}

	core.outputs = []*corev1.GetLocalRunOutputResponse{running}
	out = structured(t, invoke(t, tl, GetLocalRun, `{"repository":"shop","execution_id":"exec_1","after_sequence":4,"wait":"end","wait_seconds":1}`))
	if out["wait_ended_before_the_run"] != true {
		t.Fatalf("timed out: %v", out)
	}

	other := localOutput(corev1.LocalRunPhase_LOCAL_RUN_PHASE_RUNNING, 1)
	other.RepositoryId = "repo_2"
	core.outputs = []*corev1.GetLocalRunOutputResponse{other}
	refused(t, invoke(t, tl, GetLocalRun, `{"repository":"shop","execution_id":"exec_1"}`), "not a run of shop")
	refused(t, invoke(t, tl, GetLocalRun, `{"repository":"shop","execution_id":"exec_1","wait":"forever"}`), "wait must be")
}

func TestALocalRunStartsThroughTheApp(t *testing.T) {
	core := &fakeCore{outputs: []*corev1.GetLocalRunOutputResponse{localOutput(corev1.LocalRunPhase_LOCAL_RUN_PHASE_QUEUED, 0)}}
	app := &fakeApp{}
	tl, log := tools(core, app)
	r := invoke(t, tl, StartLocalRun, `{"repository":"shop","scenario":"pull_request","target":"main","workflows":[{"workflow":"ci.yml","jobs":["test"]}],"allow_missing_values":true}`)
	out := structured(t, r)
	if !strings.HasPrefix(r.Text, "Started local run exec_1 in shop.") || out["execution_id"] != "exec_1" || out["values_empty"].([]any)[0] != "REGION" {
		t.Fatalf("result = %s", r.Text)
	}
	if out["scenario"] != "Pull request → main" || out["notes"].([]any)[0] != "act differs" {
		t.Fatalf("out = %v", out)
	}
	if app.start.GetScenario().GetKind() != corev1.ScenarioKind_SCENARIO_KIND_PULL_REQUEST || app.start.GetWorkflows()[0].GetJobs()[0] != "test" ||
		!app.start.GetAllowMissingValues() || app.start.GetMacosWithoutSandbox() {
		t.Fatalf("start = %v", app.start)
	}
	if !strings.Contains(log.String(), `started "exec_1": ok`) {
		t.Fatalf("log = %q", log.String())
	}
	refused(t, invoke(t, tl, StartLocalRun, `{"repository":"shop","workflows":[{"jobs":["x"]}]}`), "names a workflow")
}

func TestStoppingALocalRun(t *testing.T) {
	core := &fakeCore{outputs: []*corev1.GetLocalRunOutputResponse{localOutput(corev1.LocalRunPhase_LOCAL_RUN_PHASE_RUNNING, 3)}}
	app := &fakeApp{}
	tl, _ := tools(core, app)
	structured(t, invoke(t, tl, StopLocalRun, `{"repository":"shop","execution_id":"exec_1"}`))
	if len(core.cancelled) != 1 || !app.opened[0].Action {
		t.Fatalf("cancelled = %v, opened = %v", core.cancelled, app.opened)
	}
	core.outputs = []*corev1.GetLocalRunOutputResponse{localOutput(corev1.LocalRunPhase_LOCAL_RUN_PHASE_FINISHED, 3)}
	if r := invoke(t, tl, StopLocalRun, `{"repository":"shop","execution_id":"exec_1"}`); !strings.Contains(r.Text, "already finished") || len(core.cancelled) != 1 {
		t.Fatalf("result = %+v", r)
	}
}

func TestActionsTurnedOffAreRefusedAndReadingGoesOn(t *testing.T) {
	core := &fakeCore{workflows: ciWorkflows(), outputs: []*corev1.GetLocalRunOutputResponse{localOutput(corev1.LocalRunPhase_LOCAL_RUN_PHASE_RUNNING, 0)}}
	tl, _ := tools(core, &fakeApp{actionsOff: true})
	for name, args := range map[string]string{
		StopLocalRun:     `{"repository":"shop","execution_id":"exec_1"}`,
		StartLocalRun:    `{"repository":"shop"}`,
		DispatchWorkflow: `{"repository":"shop","workflow":"release"}`,
		CancelRun:        `{"repository":"shop","run_id":1}`,
		RerunRun:         `{"repository":"shop","run_id":1}`,
	} {
		refused(t, invoke(t, tl, name, args), "Actions are turned off")
	}
	if len(core.cancelled) != 0 {
		t.Fatal("a run was stopped")
	}
	structured(t, invoke(t, tl, ListWorkflows, `{"repository":"shop"}`))
}

func TestADispatchIsPreparedAndConfirmed(t *testing.T) {
	core := &fakeCore{workflows: ciWorkflows(),
		remote:   &corev1.ListGitHubWorkflowsResponse{Workflows: []*corev1.GitHubWorkflow{{Id: 55, Name: "Release", Path: ".github/workflows/release.yml"}}},
		prepared: &corev1.PrepareWorkflowDispatchResponse{DispatchId: "d1", WorkflowPath: ".github/workflows/release.yml"},
		sent:     &corev1.ConfirmWorkflowDispatchResponse{RunId: 4242, DispatchedAt: timestamppb.Now()},
	}
	app := &fakeApp{}
	tl, log := tools(core, app)
	r := invoke(t, tl, DispatchWorkflow, `{"repository":"shop","workflow":"Release","inputs":{"channel":"secret-beta"}}`)
	out := structured(t, r)
	if out["run_id"] != 4242.0 || out["ref"] != "feature" || out["url"] != "https://github.com/acme/shop/actions/runs/4242" || !app.opened[0].Action {
		t.Fatalf("out = %v", out)
	}
	var prepared *corev1.PrepareWorkflowDispatchRequest
	var confirmed *corev1.ConfirmWorkflowDispatchRequest
	for _, a := range core.asked {
		switch r := a.(type) {
		case *corev1.PrepareWorkflowDispatchRequest:
			prepared = r
		case *corev1.ConfirmWorkflowDispatchRequest:
			confirmed = r
		}
	}
	if prepared.GetWorkflowId() != 55 || prepared.GetInputs()["channel"] != "secret-beta" || confirmed.GetDispatchId() != "d1" {
		t.Fatalf("prepared = %v, confirmed = %v", prepared, confirmed)
	}
	if strings.Contains(log.String(), "secret-beta") || !strings.Contains(log.String(), "inputs=[channel]") {
		t.Fatalf("log = %q", log.String())
	}
	core.prepared = &corev1.PrepareWorkflowDispatchResponse{Problems: []string{"channel must be beta or stable."}}
	refused(t, invoke(t, tl, DispatchWorkflow, `{"repository":"shop","workflow":"release.yml","ref":"main"}`), "channel must be")
	core.prepared = &corev1.PrepareWorkflowDispatchResponse{DispatchId: "d2"}
	core.sent = &corev1.ConfirmWorkflowDispatchResponse{Rejection: "workflow does not have workflow_dispatch"}
	refused(t, invoke(t, tl, DispatchWorkflow, `{"repository":"shop","workflow":"release.yml"}`), "GitHub refused: Workflow does not have")
}

func TestReRunsAndCancels(t *testing.T) {
	core := &fakeCore{action: &corev1.PrepareRunActionResponse{ActionId: "a1", Run: &corev1.WorkflowRun{HtmlUrl: "https://github.com/acme/shop/actions/runs/7"}},
		done: &corev1.ConfirmRunActionResponse{AcceptedAt: timestamppb.Now()}}
	tl, _ := tools(core, &fakeApp{})
	cases := map[string]corev1.RunAction{
		`{"repository":"shop","run_id":7}`:                          corev1.RunAction_RUN_ACTION_RERUN,
		`{"repository":"shop","run_id":7,"mode":"failed"}`:          corev1.RunAction_RUN_ACTION_RERUN_FAILED,
		`{"repository":"shop","run_id":7,"mode":"job","job_id":12}`: corev1.RunAction_RUN_ACTION_RERUN_JOB,
	}
	for args, want := range cases {
		core.asked = nil
		structured(t, invoke(t, tl, RerunRun, args))
		prepared := core.asked[0].(*corev1.PrepareRunActionRequest)
		if prepared.GetAction() != want || core.asked[1].(*corev1.ConfirmRunActionRequest).GetActionId() != "a1" {
			t.Fatalf("%s: asked = %v", args, core.asked)
		}
	}
	refused(t, invoke(t, tl, RerunRun, `{"repository":"shop","run_id":7,"mode":"job"}`), "needs job_id")
	refused(t, invoke(t, tl, RerunRun, `{"repository":"shop","run_id":7,"job_id":3}`), "goes with mode job")
	core.asked = nil
	out := structured(t, invoke(t, tl, CancelRun, `{"repository":"shop","run_id":7}`))
	if core.asked[0].(*corev1.PrepareRunActionRequest).GetAction() != corev1.RunAction_RUN_ACTION_CANCEL || out["action"] != "cancel" {
		t.Fatalf("asked = %v", core.asked)
	}
	core.action = &corev1.PrepareRunActionResponse{Problems: []string{"The run already finished."}}
	refused(t, invoke(t, tl, CancelRun, `{"repository":"shop","run_id":7}`), "already finished")
}

func TestValuesKeepSecretsOut(t *testing.T) {
	app := &fakeApp{}
	tl, log := tools(&fakeCore{}, app)
	out := structured(t, invoke(t, tl, ListValueSets, `{"repository":"shop"}`))
	if strings.Contains(callText(out), "leaked") || !strings.Contains(callText(out), `"eu"`) {
		t.Fatalf("out = %v", out)
	}
	r := invoke(t, tl, SetValues, `{"repository":"shop","set":"Repository","secrets":{"API_KEY":"s3cr3t"},"variables":{"REGION":"eu-west-1"}}`)
	if r.IsError || !strings.HasPrefix(r.Text, "Saved in shop › Repository") || app.set.GetSecrets()[0].GetValue() != "s3cr3t" {
		t.Fatalf("result = %+v", r)
	}
	if got := log.String(); strings.Contains(got, "s3cr3t") || strings.Contains(got, "eu-west-1") || !strings.Contains(got, "secrets=[API_KEY]") {
		t.Fatalf("log = %q", got)
	}
	refused(t, invoke(t, tl, SetValues, `{"repository":"shop","set":"Repository","secrets":{"GITHUB_SHA":"x"}}`), "GITHUB_")
	refused(t, invoke(t, tl, SetValues, `{"repository":"shop","set":"Repository","secrets":{"A":null}}`), "has no value")
}

func callText(v any) string {
	data, _ := json.Marshal(v)
	return string(data)
}

func TestLocalRunsAreListed(t *testing.T) {
	core := &fakeCore{local: []LocalRunSummary{{ExecutionID: "e2", State: "running", StartedBy: "codex", StartedAt: time.Unix(1700000000, 0)}, {ExecutionID: "e1", State: "failed"}}}
	tl, _ := tools(core, &fakeApp{})
	out := structured(t, invoke(t, tl, ListLocalRuns, `{"repository":"shop"}`))
	runs := out["runs"].([]any)
	if len(runs) != 2 || runs[0].(map[string]any)["started_by"] != "codex" || runs[0].(map[string]any)["started_at"] != "2023-11-14T22:13:20Z" {
		t.Fatalf("runs = %v", runs)
	}
}

func TestMessagesAreSentences(t *testing.T) {
	cases := map[error]string{
		status.Error(codes.FailedPrecondition, "a local run of this workspace is still going"): "A local run of this workspace is still going.",
		mcpbridge.ErrNoApp:          mcpbridge.ErrNoApp.Error(),
		mcpbridge.Refusal("No."):    "No.",
		context.Canceled:            "The call was cancelled.",
		errors.New("disk is full"):  "Runnir could not do it: Disk is full.",
		refuse("Give %s.", "a run"): "Give a run.",
	}
	for err, want := range cases {
		if got := message(err); got != want {
			t.Errorf("%v: %q, want %q", err, got, want)
		}
	}
}
