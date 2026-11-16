//go:build !windows

package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"runnir/core/internal/execution"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/localrun"
	"runnir/core/internal/tools"
)

type fakeTools struct {
	mu       sync.Mutex
	report   tools.Report
	refreshs int
	images   map[string]bool
}

func (f *fakeTools) Check(_ context.Context, refresh bool) tools.Report {
	f.mu.Lock()
	defer f.mu.Unlock()
	if refresh {
		f.refreshs++
	}
	return f.report
}

func (f *fakeTools) ImagePresent(_ context.Context, _, _, reference string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.images[reference]
}

func readyTools() *fakeTools {
	return &fakeTools{report: tools.Report{
		BundledAct:   tools.Tool{State: tools.Found, Version: "0.2.89", Path: "/App/Contents/Helpers/act"},
		InstalledAct: tools.Tool{State: tools.Found, Version: "0.2.91", Path: "/opt/homebrew/bin/act", Untested: true},
		DockerCLI:    tools.Tool{State: tools.Found, Version: "29.0.1", Path: "/usr/local/bin/docker"},
		Engine: tools.Engine{State: tools.Found, Name: "OrbStack", Context: "orbstack", Endpoint: "unix:///Users/me/.orbstack/run/docker.sock",
			Local: true, Architecture: "x86_64", CPUs: 8, MemoryBytes: 16 << 30},
		CheckedAt: time.Now(),
	}, images: map[string]bool{"catthehacker/ubuntu:act-latest": true}}
}

// pick ticks jobs of one workflow in .github/workflows.
func pick(file string, jobs ...string) []*corev1.LocalRunSelection {
	return []*corev1.LocalRunSelection{{WorkflowId: ".github/workflows/" + file, JobIds: jobs}}
}

const localWorkflow = "name: CI\non: [push, workflow_dispatch]\njobs:\n  lint:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n  ios:\n    runs-on: macos-latest\n    steps:\n      - run: echo hi\n"

func TestLocalRunIsPreparedConfirmedAndCancelled(t *testing.T) {
	path := socketPath(t)
	fake := readyTools()
	var spec *localrun.Spec
	started := make(chan struct{})
	hold := execution.RunnerFunc(func(ctx context.Context, job execution.Job) error {
		spec, _ = job.Spec.(*localrun.Spec)
		close(started)
		<-ctx.Done()
		return ctx.Err()
	})
	stop := startWith(t, path, Options{Runner: hold, Tools: fake, Home: "/Users/me", ActCache: "/cache/act"})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	root := repoWithWorkflows(t, map[string]string{"ci.yml": localWorkflow})
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	repo := opened.Repository.Id

	prepared, err := client.PrepareLocalRun(ctx, &corev1.PrepareLocalRunRequest{RepositoryId: repo, Selection: pick("ci.yml", "lint")})
	if err != nil {
		t.Fatal(err)
	}
	plan := prepared.Plan
	// Outside git, the default branch's merge is the scenario: a push to main.
	if prepared.ConfirmationId == "" || len(plan.Blockers) != 0 || plan.Scenario.GetTitle() != "Merge into main" || len(plan.Scenarios) != 2 ||
		plan.ActVersion != "0.2.89" || plan.InstalledAct {
		t.Fatalf("prepared = %v", prepared)
	}
	lane := plan.Lanes[0]
	if len(plan.Lanes) != 1 || lane.Event != "push" || !lane.Selected || lane.Kind != corev1.LocalRunLaneKind_LOCAL_RUN_LANE_KIND_DIRECT ||
		len(lane.Jobs) != 2 || !lane.Jobs[0].Selected || lane.Jobs[1].Selected ||
		lane.Jobs[0].Support != corev1.LocalJobSupport_LOCAL_JOB_SUPPORT_SUPPORTED || plan.Cpus != 4 || plan.TimeoutSeconds != 1800 {
		t.Fatalf("plan = %v", plan)
	}
	if len(plan.Images) != 1 || !plan.Images[0].Present || plan.EngineName != "OrbStack" || plan.EngineContext != "orbstack" {
		t.Fatalf("plan = %v", plan)
	}
	if fake.refreshs != 1 {
		t.Fatalf("the review did not recheck the tools (%d)", fake.refreshs)
	}

	confirmed, err := client.ConfirmLocalRun(ctx, &corev1.ConfirmLocalRunRequest{ConfirmationId: prepared.ConfirmationId})
	if err != nil {
		t.Fatal(err)
	}
	id := confirmed.Execution.ExecutionId
	<-started
	if spec == nil || spec.ActPath != "/App/Contents/Helpers/act" || spec.RepositoryPath != root || spec.UserHome != "/Users/me" ||
		spec.CacheDir != "/cache/act" || spec.DockerHost != "unix:///Users/me/.orbstack/run/docker.sock" ||
		!strings.Contains(string(spec.Plan.Lanes[0].Payload), `"ref":"refs/heads/main"`) || strings.Contains(string(spec.Plan.Lanes[0].Copy), "ios:") {
		t.Fatalf("spec = %+v", spec)
	}
	if _, err := client.ConfirmLocalRun(ctx, &corev1.ConfirmLocalRunRequest{ConfirmationId: prepared.ConfirmationId}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("second confirm = %v", err)
	}

	output, err := client.GetLocalRunOutput(ctx, &corev1.GetLocalRunOutputRequest{ExecutionId: id})
	if err != nil {
		t.Fatal(err)
	}
	if output.State != corev1.ExecutionState_EXECUTION_STATE_RUNNING || output.Phase != corev1.LocalRunPhase_LOCAL_RUN_PHASE_RUNNING ||
		output.ExitCode != -1 || len(output.Jobs) != 1 || output.Jobs[0].WorkflowId != ".github/workflows/ci.yml" ||
		output.Plan.ActVersion != "0.2.89" || output.StartedAt == nil {
		t.Fatalf("output = %v", output)
	}

	if _, err := client.CancelExecution(ctx, &corev1.CancelExecutionRequest{ExecutionId: id}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		output, err = client.GetLocalRunOutput(ctx, &corev1.GetLocalRunOutputRequest{ExecutionId: id})
		if err != nil {
			t.Fatal(err)
		}
		if output.Phase == corev1.LocalRunPhase_LOCAL_RUN_PHASE_FINISHED || time.Now().After(deadline) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if output.State != corev1.ExecutionState_EXECUTION_STATE_CANCELLED || output.FinishedAt == nil {
		t.Fatalf("after cancel = %v", output)
	}
	if _, err := client.CancelExecution(ctx, &corev1.CancelExecutionRequest{ExecutionId: id}); err != nil {
		t.Fatalf("cancelling a finished run = %v", err)
	}
	if _, err := client.CancelExecution(ctx, &corev1.CancelExecutionRequest{ExecutionId: "exec_nope"}); status.Code(err) != codes.NotFound {
		t.Fatalf("unknown cancel = %v", err)
	}
}

func TestOptedInInstalledActIsUsed(t *testing.T) {
	client, ctx := servedWith(t, Options{Runner: execution.RunnerFunc(func(context.Context, execution.Job) error { return nil }), Tools: readyTools()})
	root := repoWithWorkflows(t, map[string]string{"ci.yml": localWorkflow})
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	prepared, err := client.PrepareLocalRun(ctx, &corev1.PrepareLocalRunRequest{RepositoryId: opened.Repository.Id,
		Selection: pick("ci.yml", "lint"), UseInstalledAct: true})
	if err != nil {
		t.Fatal(err)
	}
	if !prepared.Plan.InstalledAct || prepared.Plan.ActVersion != "0.2.91" || !prepared.Readiness.InstalledAct.Untested {
		t.Fatalf("plan = %v", prepared.Plan)
	}
}

func TestLocalRunIsRefusedWhenTheFileChangedAfterReview(t *testing.T) {
	client, ctx := servedWith(t, Options{Runner: execution.RunnerFunc(func(context.Context, execution.Job) error { return nil }), Tools: readyTools()})
	root := repoWithWorkflows(t, map[string]string{"ci.yml": localWorkflow})
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	prepared, err := client.PrepareLocalRun(ctx, &corev1.PrepareLocalRunRequest{RepositoryId: opened.Repository.Id})
	if err != nil || prepared.ConfirmationId == "" {
		t.Fatalf("prepare = %v %v", prepared, err)
	}
	if err := os.WriteFile(filepath.Join(root, ".github", "workflows", "ci.yml"), []byte(localWorkflow+"# edited\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := client.ConfirmLocalRun(ctx, &corev1.ConfirmLocalRunRequest{ConfirmationId: prepared.ConfirmationId}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("confirm after an edit = %v", err)
	}
}

func TestBlockedPlanHasNoConfirmation(t *testing.T) {
	path := socketPath(t)
	fake := readyTools()
	fake.report.Engine = tools.Engine{State: tools.Stopped, Name: "OrbStack", Context: "orbstack", Local: true, Detail: "OrbStack is not running or does not answer."}
	stop := startWith(t, path, Options{Tools: fake})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	root := repoWithWorkflows(t, map[string]string{"ci.yml": localWorkflow})
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	repo := opened.Repository.Id
	prepared, err := client.PrepareLocalRun(ctx, &corev1.PrepareLocalRunRequest{RepositoryId: repo})
	if err != nil {
		t.Fatal(err)
	}
	if prepared.ConfirmationId != "" || len(prepared.Plan.Blockers) != 1 || prepared.Readiness.Engine.State != corev1.ToolState_TOOL_STATE_STOPPED {
		t.Fatalf("prepared = %v", prepared)
	}

	for name, tc := range map[string]struct {
		request *corev1.PrepareLocalRunRequest
		want    codes.Code
	}{
		"unknown repository": {&corev1.PrepareLocalRunRequest{RepositoryId: "repo_nope"}, codes.NotFound},
		"unknown workflow":   {&corev1.PrepareLocalRunRequest{RepositoryId: repo, Selection: pick("../../../etc/passwd", "a")}, codes.NotFound},
		"unknown job":        {&corev1.PrepareLocalRunRequest{RepositoryId: repo, Selection: pick("ci.yml", "deploy")}, codes.NotFound},
	} {
		if _, err := client.PrepareLocalRun(ctx, tc.request); status.Code(err) != tc.want {
			t.Errorf("%s: %v, want %v", name, err, tc.want)
		}
	}
	if _, err := client.ConfirmLocalRun(ctx, &corev1.ConfirmLocalRunRequest{ConfirmationId: "local_nope"}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("unknown confirmation = %v", err)
	}
	if _, err := client.GetLocalRunOutput(ctx, &corev1.GetLocalRunOutputRequest{ExecutionId: "exec_nope"}); status.Code(err) != codes.NotFound {
		t.Fatalf("unknown output = %v", err)
	}
}

func TestToolReadinessReportsEveryTool(t *testing.T) {
	fake := readyTools()
	client, ctx := servedWith(t, Options{Tools: fake})
	response, err := client.GetToolReadiness(ctx, &corev1.GetToolReadinessRequest{Refresh: true})
	if err != nil {
		t.Fatal(err)
	}
	r := response.Readiness
	if r.BundledAct.Version != "0.2.89" || r.InstalledAct.Path != "/opt/homebrew/bin/act" || r.DockerCli.State != corev1.ToolState_TOOL_STATE_FOUND ||
		r.Engine.Name != "OrbStack" || r.Engine.Cpus != 8 || !r.Engine.Local || r.TestedActVersion != tools.TestedActVersion.String() ||
		r.MinimumActVersion != tools.MinActVersion.String() || r.CheckedAt == nil {
		t.Fatalf("readiness = %v", r)
	}
	if fake.refreshs != 1 {
		t.Fatalf("refresh not passed on (%d)", fake.refreshs)
	}
}

const valuesWorkflow = "name: CI\non: push\njobs:\n  lint:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ${{ secrets.NPM_TOKEN }} ${{ vars.region }}\n"

func TestLocalRunTakesValuesForPlanNamesOnly(t *testing.T) {
	path := socketPath(t)
	var spec *localrun.Spec
	started := make(chan struct{})
	hold := execution.RunnerFunc(func(ctx context.Context, job execution.Job) error {
		spec, _ = job.Spec.(*localrun.Spec)
		close(started)
		<-ctx.Done()
		return ctx.Err()
	})
	stop := startWith(t, path, Options{Runner: hold, Tools: readyTools(), Home: "/Users/me"})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repoWithWorkflows(t, map[string]string{"ci.yml": valuesWorkflow})})
	if err != nil {
		t.Fatal(err)
	}
	prepare := func() *corev1.PrepareLocalRunResponse {
		t.Helper()
		prepared, err := client.PrepareLocalRun(ctx, &corev1.PrepareLocalRunRequest{RepositoryId: opened.Repository.Id})
		if err != nil {
			t.Fatal(err)
		}
		return prepared
	}

	first := prepare()
	if !slices.Equal(first.Plan.Secrets, []string{"NPM_TOKEN"}) || !slices.Equal(first.Plan.Variables, []string{"REGION"}) {
		t.Fatalf("plan = %v", first.Plan)
	}
	for _, bad := range []*corev1.ConfirmLocalRunRequest{
		{Secrets: map[string]string{"OTHER": "x"}},
		{Variables: map[string]string{"NPM_TOKEN": "x"}},
		{Secrets: map[string]string{"NPM_TOKEN": strings.Repeat("x", 48<<10+1)}},
		{Secrets: map[string]string{"npm_token": "a", "NPM_TOKEN": "b"}},
	} {
		bad.ConfirmationId = prepare().ConfirmationId
		if _, err := client.ConfirmLocalRun(ctx, bad); status.Code(err) != codes.InvalidArgument {
			t.Fatalf("confirm %v = %v", bad, err)
		}
	}

	confirmed, err := client.ConfirmLocalRun(ctx, &corev1.ConfirmLocalRunRequest{ConfirmationId: first.ConfirmationId,
		Secrets: map[string]string{"npm_token": "s3cr3t"}, Variables: map[string]string{"Region": "eu"}})
	if err != nil {
		t.Fatal(err)
	}
	<-started
	if spec.Secrets["NPM_TOKEN"] != "s3cr3t" || spec.Variables["REGION"] != "eu" || len(spec.Secrets) != 1 || len(spec.Variables) != 1 {
		t.Fatalf("spec values = %v %v", spec.Secrets, spec.Variables)
	}
	output, err := client.GetLocalRunOutput(ctx, &corev1.GetLocalRunOutputRequest{ExecutionId: confirmed.Execution.ExecutionId})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(output.String(), "s3cr3t") {
		t.Fatal("a value is in the run's output message")
	}
}

func TestLocalRunLimitsAreAskedCappedAndKeptForTheWorkspace(t *testing.T) {
	path := socketPath(t)
	fake := readyTools()
	done := execution.RunnerFunc(func(context.Context, execution.Job) error { return nil })
	stop := startWith(t, path, Options{Runner: done, Tools: fake, Home: "/Users/me", ActCache: "/cache/act", DataDir: t.TempDir()})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	root := repoWithWorkflows(t, map[string]string{"ci.yml": localWorkflow})
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root, WorkspaceId: testWorkspace})
	if err != nil {
		t.Fatal(err)
	}
	prepare := func(request *corev1.PrepareLocalRunRequest) *corev1.PrepareLocalRunResponse {
		t.Helper()
		request.RepositoryId, request.Selection = opened.Repository.Id, pick("ci.yml", "lint")
		prepared, err := client.PrepareLocalRun(ctx, request)
		if err != nil {
			t.Fatal(err)
		}
		return prepared
	}
	confirm := func(prepared *corev1.PrepareLocalRunResponse) {
		t.Helper()
		if _, err := client.ConfirmLocalRun(ctx, &corev1.ConfirmLocalRunRequest{ConfirmationId: prepared.ConfirmationId}); err != nil {
			t.Fatal(err)
		}
	}

	defaults := prepare(&corev1.PrepareLocalRunRequest{}).Plan
	if defaults.Cpus != 4 || defaults.MemoryBytes != 8<<30 || defaults.OwnLimits || defaults.MaxCpus != 8 ||
		defaults.MaxMemoryBytes != 16<<30 || defaults.MaxTimeoutSeconds != 6*3600 || len(defaults.LimitWarnings) != 0 || defaults.LimitNote != "" {
		t.Fatalf("defaults = %v", defaults)
	}

	// Asked above the engine: capped, with what it risks.
	asked := prepare(&corev1.PrepareLocalRunRequest{Limits: &corev1.LocalRunLimits{Cpus: 12, MemoryBytes: 15 << 30, TimeoutSeconds: 3600}})
	plan := asked.Plan
	if plan.Cpus != 8 || plan.MemoryBytes != 15<<30 || plan.TimeoutSeconds != 3600 || !plan.OwnLimits || len(plan.LimitWarnings) != 2 {
		t.Fatalf("asked = %v", plan)
	}
	// Not kept until a run with them is confirmed.
	if again := prepare(&corev1.PrepareLocalRunRequest{}).Plan; again.OwnLimits {
		t.Fatalf("kept before a confirmed run: %v", again)
	}
	confirm(asked)
	kept := prepare(&corev1.PrepareLocalRunRequest{}).Plan
	if !kept.OwnLimits || kept.Cpus != 8 || kept.MemoryBytes != 15<<30 || kept.TimeoutSeconds != 3600 {
		t.Fatalf("kept = %v", kept)
	}

	// Reset plans the defaults and, once confirmed, forgets the workspace's.
	reset := prepare(&corev1.PrepareLocalRunRequest{ResetLimits: true})
	if reset.Plan.OwnLimits || reset.Plan.Cpus != 4 {
		t.Fatalf("reset = %v", reset.Plan)
	}
	confirm(reset)
	if after := prepare(&corev1.PrepareLocalRunRequest{}).Plan; after.OwnLimits || after.Cpus != 4 {
		t.Fatalf("after reset = %v", after)
	}
}

func TestJobsSayTheirEnvironmentAndAPlanTakesIt(t *testing.T) {
	client, ctx := served(t)
	deploy := "on: workflow_dispatch\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps: [{run: \"echo ${{ secrets.GHCR_TOKEN }}\"}]\n" +
		"  production:\n    environment: production\n    runs-on: ubuntu-latest\n    steps: [{run: \"echo ${{ secrets.DEPLOY_KEY }} ${{ vars.API_URL }}\"}]\n"
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repoWithWorkflows(t, map[string]string{"deploy.yml": deploy})})
	if err != nil {
		t.Fatal(err)
	}
	listed, err := client.ListWorkflows(ctx, &corev1.ListWorkflowsRequest{RepositoryId: opened.Repository.Id})
	if err != nil || len(listed.Workflows) != 1 || len(listed.Workflows[0].Jobs) != 2 {
		t.Fatalf("workflows = %v, %v", listed, err)
	}
	production := listed.Workflows[0].Jobs[1]
	if production.Environment != "production" || !slices.Equal(production.Secrets, []string{"DEPLOY_KEY"}) || !slices.Equal(production.Variables, []string{"API_URL"}) {
		t.Fatalf("production = %v", production)
	}
	prepared, err := client.PrepareLocalRun(ctx, &corev1.PrepareLocalRunRequest{RepositoryId: opened.Repository.Id,
		Selection: pick("deploy.yml", "production")})
	if err != nil || prepared.Plan.Environment != "production" {
		t.Fatalf("plan = %v, %v", prepared.GetPlan(), err)
	}
}

func TestAJobAnExpressionPlacesChoosesAmongTheRepositorysEnvironments(t *testing.T) {
	var asked atomic.Int32
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/o/r/environments" {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		asked.Add(1)
		_, _ = w.Write([]byte(`{"total_count":2,"environments":[{"id":1,"name":"staging"},{"id":2,"name":"production"}]}`))
	}))
	defer fake.Close()
	client, ctx := servedWith(t, Options{GitHubBaseURL: fake.URL})
	root := linkedRepository(t, "https://github.com/o/r.git")
	deploy := "on: workflow_dispatch\njobs:\n  deploy:\n    environment: ${{ inputs.target }}\n    runs-on: ubuntu-latest\n" +
		"    steps: [{run: \"echo ${{ secrets.DEPLOY_KEY }}\"}]\n"
	if err := os.MkdirAll(filepath.Join(root, ".github", "workflows"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ".github", "workflows", "deploy.yml"), []byte(deploy), 0o644); err != nil {
		t.Fatal(err)
	}
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	id := opened.Repository.Id
	prepare := &corev1.PrepareLocalRunRequest{RepositoryId: id, Selection: pick("deploy.yml", "deploy")}

	// Signed out, Runnir knows no environment, and the run gets the Repository's values.
	listed, err := client.ListEnvironments(ctx, &corev1.ListEnvironmentsRequest{RepositoryId: id})
	if err != nil || len(listed.Names) != 0 {
		t.Fatalf("signed out = %v, %v", listed, err)
	}
	prepared, err := client.PrepareLocalRun(ctx, prepare)
	if err != nil || prepared.Plan.EnvironmentChoice != "" || len(prepared.Plan.Environments) != 0 ||
		!slices.ContainsFunc(prepared.Plan.Notes, func(note string) bool { return strings.Contains(note, "knows no environment") }) {
		t.Fatalf("signed out plan = %v, %v", prepared.GetPlan(), err)
	}

	if _, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghu_test"}); err != nil {
		t.Fatal(err)
	}
	listed, err = client.ListEnvironments(ctx, &corev1.ListEnvironmentsRequest{RepositoryId: id})
	if err != nil || !slices.Equal(listed.Names, []string{"production", "staging"}) {
		t.Fatalf("environments = %v, %v", listed, err)
	}
	prepared, err = client.PrepareLocalRun(ctx, prepare)
	if err != nil || prepared.Plan.Environment != "" || !slices.Equal(prepared.Plan.Environments, []string{"production", "staging"}) ||
		prepared.Plan.EnvironmentChoice != "deploy picks its environment with an expression, known only when it runs." {
		t.Fatalf("plan = %v, %v", prepared.GetPlan(), err)
	}
	// A review reuses what Secrets and Variables just read; the section asks again.
	if _, err := client.PrepareLocalRun(ctx, prepare); err != nil || asked.Load() != 1 {
		t.Fatalf("asked GitHub %d times, %v", asked.Load(), err)
	}
	if _, err := client.ListEnvironments(ctx, &corev1.ListEnvironmentsRequest{RepositoryId: id}); err != nil || asked.Load() != 2 {
		t.Fatalf("asked GitHub %d times, %v", asked.Load(), err)
	}
}

func TestALocalRunPlansTheScenarioAndTheWorkflowsItLeavesOut(t *testing.T) {
	client, ctx := servedWith(t, Options{Runner: execution.RunnerFunc(func(context.Context, execution.Job) error { return nil }), Tools: readyTools()})
	release := "name: Release\non:\n  push:\n    tags: [\"v*\"]\njobs:\n  publish:\n    runs-on: ubuntu-latest\n    steps: [{run: echo}]\n"
	notify := "name: Notify\non:\n  workflow_run:\n    workflows: [CI]\njobs:\n  tell:\n    runs-on: ubuntu-latest\n    steps: [{run: echo}]\n"
	root := repoWithWorkflows(t, map[string]string{"ci.yml": localWorkflow, "release.yml": release, "notify.yml": notify})
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	prepared, err := client.PrepareLocalRun(ctx, &corev1.PrepareLocalRunRequest{RepositoryId: opened.Repository.Id})
	if err != nil {
		t.Fatal(err)
	}
	lanes := map[string]*corev1.LocalRunLane{}
	var order []string
	for _, lane := range prepared.Plan.Lanes {
		lanes[lane.WorkflowId], order = lane, append(order, lane.WorkflowId)
	}
	ci, chained, outside := lanes[".github/workflows/ci.yml"], lanes[".github/workflows/notify.yml"], lanes[".github/workflows/release.yml"]
	if len(order) != 3 || order[0] != ".github/workflows/ci.yml" || order[1] != ".github/workflows/notify.yml" {
		t.Fatalf("order = %v", order)
	}
	if !ci.Selected || ci.Why == "" || !chained.Selected || chained.Kind != corev1.LocalRunLaneKind_LOCAL_RUN_LANE_KIND_CHAINED ||
		chained.After != ".github/workflows/ci.yml" || chained.Event != "workflow_run" {
		t.Fatalf("scenario lanes = %v %v", ci, chained)
	}
	if outside.Selected || outside.Kind != corev1.LocalRunLaneKind_LOCAL_RUN_LANE_KIND_OUTSIDE || outside.Skipped != "runs on tag pushes" || outside.Event != "push" {
		t.Fatalf("release = %v", outside)
	}

	// Ticked by hand, it runs alone.
	prepared, err = client.PrepareLocalRun(ctx, &corev1.PrepareLocalRunRequest{RepositoryId: opened.Repository.Id, Selection: pick("release.yml", "publish")})
	if err != nil || prepared.ConfirmationId == "" {
		t.Fatalf("prepared = %v, %v", prepared, err)
	}
	for _, lane := range prepared.Plan.Lanes {
		if lane.Selected != (lane.WorkflowId == ".github/workflows/release.yml") {
			t.Fatalf("lanes = %v", prepared.Plan.Lanes)
		}
	}
	if _, err := client.ConfirmLocalRun(ctx, &corev1.ConfirmLocalRunRequest{ConfirmationId: prepared.ConfirmationId}); err != nil {
		t.Fatal(err)
	}
}

// An answer holds a bounded share of the lines; the app asks again after
// the last one given until no more lines follow.
func TestOutputAnswersHoldABoundedShareOfTheLines(t *testing.T) {
	var lines []localrun.Line
	for i := uint64(1); i <= 10; i++ {
		lines = append(lines, localrun.Line{Sequence: i, Workflow: "ci.yml", JobID: "lint", Text: strings.Repeat("x", 100)})
	}
	out := &corev1.GetLocalRunOutputResponse{LastSequence: 10}
	answerLines(out, lines, 450)
	if len(out.Lines) != 3 || !out.MoreLines || out.LastSequence != 3 {
		t.Fatalf("lines %d, more %v, last %d", len(out.Lines), out.MoreLines, out.LastSequence)
	}
	out = &corev1.GetLocalRunOutputResponse{LastSequence: 10}
	answerLines(out, lines, 10)
	if len(out.Lines) != 1 || !out.MoreLines || out.LastSequence != 1 {
		t.Fatalf("a line longer than the room still goes: %d, %v, %d", len(out.Lines), out.MoreLines, out.LastSequence)
	}
	out = &corev1.GetLocalRunOutputResponse{LastSequence: 10}
	answerLines(out, lines, maxOutputAnswerBytes)
	if len(out.Lines) != 10 || out.MoreLines || out.LastSequence != 10 {
		t.Fatalf("lines %d, more %v, last %d", len(out.Lines), out.MoreLines, out.LastSequence)
	}
}
