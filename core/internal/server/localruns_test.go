//go:build !windows

package server

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
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

	prepared, err := client.PrepareLocalRun(ctx, &corev1.PrepareLocalRunRequest{RepositoryId: repo, WorkflowId: ".github/workflows/ci.yml", JobId: "lint"})
	if err != nil {
		t.Fatal(err)
	}
	plan := prepared.Plan
	if prepared.ConfirmationId == "" || len(plan.Blockers) != 0 || plan.Event != "push" || plan.JobId != "lint" || plan.ActVersion != "0.2.89" || plan.InstalledAct {
		t.Fatalf("prepared = %v", prepared)
	}
	if len(plan.Jobs) != 1 || plan.Jobs[0].Support != corev1.LocalJobSupport_LOCAL_JOB_SUPPORT_SUPPORTED || plan.Cpus != 4 || plan.TimeoutSeconds != 1800 {
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
		spec.CacheDir != "/cache/act" || spec.DockerHost != "unix:///Users/me/.orbstack/run/docker.sock" || spec.Plan.JobID != "lint" {
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
		output.ExitCode != -1 || len(output.Jobs) != 1 || output.Plan.ActVersion != "0.2.89" || output.StartedAt == nil {
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
	path := socketPath(t)
	stop := startWith(t, path, Options{Runner: execution.RunnerFunc(func(context.Context, execution.Job) error { return nil }), Tools: readyTools()})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	root := repoWithWorkflows(t, map[string]string{"ci.yml": localWorkflow})
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	prepared, err := client.PrepareLocalRun(ctx, &corev1.PrepareLocalRunRequest{RepositoryId: opened.Repository.Id,
		WorkflowId: ".github/workflows/ci.yml", JobId: "lint", UseInstalledAct: true})
	if err != nil {
		t.Fatal(err)
	}
	if !prepared.Plan.InstalledAct || prepared.Plan.ActVersion != "0.2.91" || !prepared.Readiness.InstalledAct.Untested {
		t.Fatalf("plan = %v", prepared.Plan)
	}
}

func TestLocalRunIsRefusedWhenTheFileChangedAfterReview(t *testing.T) {
	path := socketPath(t)
	stop := startWith(t, path, Options{Runner: execution.RunnerFunc(func(context.Context, execution.Job) error { return nil }), Tools: readyTools()})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	root := repoWithWorkflows(t, map[string]string{"ci.yml": localWorkflow})
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	prepared, err := client.PrepareLocalRun(ctx, &corev1.PrepareLocalRunRequest{RepositoryId: opened.Repository.Id, WorkflowId: ".github/workflows/ci.yml"})
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
	prepared, err := client.PrepareLocalRun(ctx, &corev1.PrepareLocalRunRequest{RepositoryId: repo, WorkflowId: ".github/workflows/ci.yml"})
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
		"unknown repository": {&corev1.PrepareLocalRunRequest{RepositoryId: "repo_nope", WorkflowId: ".github/workflows/ci.yml"}, codes.NotFound},
		"unknown workflow":   {&corev1.PrepareLocalRunRequest{RepositoryId: repo, WorkflowId: "../../etc/passwd"}, codes.NotFound},
		"unknown job":        {&corev1.PrepareLocalRunRequest{RepositoryId: repo, WorkflowId: ".github/workflows/ci.yml", JobId: "deploy"}, codes.NotFound},
		"unknown event":      {&corev1.PrepareLocalRunRequest{RepositoryId: repo, WorkflowId: ".github/workflows/ci.yml", Event: "release"}, codes.InvalidArgument},
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
	path := socketPath(t)
	fake := readyTools()
	stop := startWith(t, path, Options{Tools: fake})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
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
		prepared, err := client.PrepareLocalRun(ctx, &corev1.PrepareLocalRunRequest{RepositoryId: opened.Repository.Id, WorkflowId: ".github/workflows/ci.yml"})
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
