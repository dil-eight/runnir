//go:build e2e

// End-to-end runs with a real act and container engine. Run with
//
//	RUNNIR_E2E_ACT=/path/to/act go test -tags e2e ./internal/localrun/
//
// It pulls alpine:3.20 (a few megabytes) if the engine does not have it.
package localrun

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"runnir/core/internal/events"
	"runnir/core/internal/execution"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/tools"
)

const e2eWorkflow = `name: E2E
on: push
jobs:
  hello:
    runs-on: ubuntu-latest
    container: alpine:3.20
    steps:
      - uses: actions/checkout@v4
      - name: Report
        shell: sh
        run: |
          echo "arch=$(uname -m)"
          if [ -S /var/run/docker.sock ]; then echo "docker-socket=mounted"; else echo "docker-socket=absent"; fi
          echo "secret=[${{ secrets.NPM_TOKEN }}]"
          echo "token=[${{ secrets.GITHUB_TOKEN }}]"
          echo "secret-sha=$(printf %s '${{ secrets.NPM_TOKEN }}' | sha256sum | cut -c1-16)"
          echo "region=[${{ vars.REGION }}]"
          ls -a
  wait:
    needs: hello
    runs-on: ubuntu-latest
    container: alpine:3.20
    steps:
      - shell: sh
        run: echo waiting; sleep 300
`

func e2eSpec(t *testing.T, jobID string) (*Spec, *Outputs, execution.Job) {
	t.Helper()
	act := os.Getenv("RUNNIR_E2E_ACT")
	if act == "" {
		t.Skip("RUNNIR_E2E_ACT is not set")
	}
	home, _ := os.UserHomeDir()
	report := tools.NewDetector(home, act, "").Check(context.Background(), true)
	if !report.Ready(false) {
		t.Fatalf("tools not ready: %+v", report)
	}
	repo, _ := filepath.EvalSymlinks(t.TempDir())
	_ = os.MkdirAll(filepath.Join(repo, ".github", "workflows"), 0o755)
	_ = os.WriteFile(filepath.Join(repo, ".github", "workflows", "e2e.yml"), []byte(e2eWorkflow), 0o644)
	_ = os.WriteFile(filepath.Join(repo, "README.md"), []byte("fixture\n"), 0o644)
	_ = os.WriteFile(filepath.Join(repo, ".env"), []byte("LEAK=from-dotenv\n"), 0o644)
	_ = os.WriteFile(filepath.Join(repo, ".secrets"), []byte("NPM_TOKEN=from-secrets-file\n"), 0o644)
	_ = os.WriteFile(filepath.Join(repo, ".actrc"), []byte("--bind\n"), 0o644)
	_ = os.WriteFile(filepath.Join(repo, ".gitignore"), []byte(".env\n.secrets\n.actrc\n"), 0o644)
	_ = os.WriteFile(filepath.Join(repo, "uncommitted.txt"), []byte("draft\n"), 0o644)
	for _, args := range [][]string{
		{"init", "-q", "-b", "main"},
		{"add", "README.md", ".gitignore", ".github"},
		{"-c", "user.name=Runnir", "-c", "user.email=test@example.invalid", "commit", "-q", "-m", "fixture"},
	} {
		git := exec.Command("git", args...)
		git.Dir = repo
		if out, err := git.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %s", args, out)
		}
	}

	plan, err := NewPlan(Request{WorkflowID: ".github/workflows/e2e.yml", Source: []byte(e2eWorkflow), JobID: jobID}, report, false, nil)
	if err != nil || !plan.Runnable() {
		t.Fatalf("plan = %+v, %v", plan, err)
	}
	act0, _ := report.Act(false)
	spec := &Spec{ActPath: act0.Path, DockerPath: report.DockerCLI.Path, DockerHost: report.Engine.Endpoint,
		UserHome: home, RepositoryPath: repo, Plan: plan, CacheDir: filepath.Join(t.TempDir(), "cache")}
	outputs := NewOutputs()
	id, _ := execution.NewID()
	outputs.Create(id, "repo", plan, act0.Version, false, report.Engine.Name)
	return spec, outputs, execution.Job{ExecutionID: id, RepositoryID: "repo", RepositoryPath: repo, Spec: spec}
}

func text(outputs *Outputs, id string) string {
	snap, _ := outputs.Since(id, 0)
	var lines []string
	for _, line := range snap.Lines {
		lines = append(lines, line.Text)
	}
	return strings.Join(lines, "\n")
}

func TestE2ERunReportsOutputWithoutLeaks(t *testing.T) {
	spec, outputs, job := e2eSpec(t, "hello")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	err := NewRunner(outputs).Run(ctx, job)
	out := text(outputs, job.ExecutionID)
	t.Logf("output:\n%s", out)
	if err != nil {
		t.Fatalf("Run = %v", err)
	}
	// The working tree is copied, uncommitted files included, without what
	// .gitignore excludes.
	for _, want := range []string{"docker-socket=absent", "secret=[]", "token=[]", "README.md", "uncommitted.txt"} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q", want)
		}
	}
	for _, leak := range []string{"from-dotenv", "from-secrets-file", "| .env", "| .actrc"} {
		if strings.Contains(out, leak) {
			t.Errorf("output contains %q", leak)
		}
	}
	snap, _ := outputs.Since(job.ExecutionID, 0)
	if snap.ExitCode != 0 || snap.Jobs[0].State != JobSucceeded || snap.CleanupProblem != "" {
		t.Fatalf("exit=%d jobs=%+v cleanup=%q", snap.ExitCode, snap.Jobs, snap.CleanupProblem)
	}
	assertNoContainers(t, spec)
}

func TestE2EValuesReachTheJob(t *testing.T) {
	spec, outputs, job := e2eSpec(t, "hello")
	spec.Secrets = map[string]string{"NPM_TOKEN": "e2e-secret-value"}
	spec.Variables = map[string]string{"REGION": "eu-test-1"}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	err := NewRunner(outputs).Run(ctx, job)
	out := text(outputs, job.ExecutionID)
	t.Logf("output:\n%s", out)
	if err != nil {
		t.Fatalf("Run = %v", err)
	}
	sum := sha256.Sum256([]byte("e2e-secret-value"))
	for _, want := range []string{"secret-sha=" + hex.EncodeToString(sum[:])[:16], "region=[eu-test-1]", "secret=[***]"} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q", want)
		}
	}
	if strings.Contains(out, "e2e-secret-value") {
		t.Error("the secret's value is in the output")
	}
	assertNoContainers(t, spec)
}

func TestE2ECancelStopsTheRunAndCleansUp(t *testing.T) {
	spec, outputs, job := e2eSpec(t, "wait")
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- NewRunner(outputs).Run(ctx, job) }()
	deadline := time.Now().Add(3 * time.Minute)
	for !strings.Contains(text(outputs, job.ExecutionID), "waiting") {
		if time.Now().After(deadline) {
			cancel()
			t.Fatalf("the wait job never started:\n%s", text(outputs, job.ExecutionID))
		}
		time.Sleep(200 * time.Millisecond)
	}
	stoppedAt := time.Now()
	cancel()
	select {
	case err := <-done:
		t.Logf("Run = %v after %s", err, time.Since(stoppedAt))
	case <-time.After(time.Minute):
		t.Fatal("the run did not stop")
	}
	outputs.Observe(events.Event{ExecutionID: job.ExecutionID, ExecutionState: corev1.ExecutionState_EXECUTION_STATE_CANCELLED})
	snap, _ := outputs.Since(job.ExecutionID, 0)
	t.Logf("cleanup=%q jobs=%+v\n%s", snap.CleanupProblem, snap.Jobs, text(outputs, job.ExecutionID))
	assertNoContainers(t, spec)
}

// assertNoContainers fails when act left containers of this fixture.
func assertNoContainers(t *testing.T, spec *Spec) {
	t.Helper()
	cmd := exec.Command(spec.DockerPath, "ps", "--all", "--format", "{{.Names}}", "--filter", "name=act-E2E")
	cmd.Env = []string{"HOME=" + spec.UserHome, "DOCKER_HOST=" + dockerHost(spec.DockerHost)}
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("docker ps: %v", err)
	}
	if names := strings.TrimSpace(string(out)); names != "" {
		t.Fatalf("containers left behind: %s", names)
	}
}

// Jobs without a container section get the run's label and limits. The
// runner image is swapped for alpine so the test downloads megabytes, not
// the gigabyte runner image.
func TestE2EJobContainersCarryTheLabelAndLimits(t *testing.T) {
	saved := Platforms["ubuntu-latest"]
	Platforms["ubuntu-latest"] = "alpine:3.20"
	defer func() { Platforms["ubuntu-latest"] = saved }()

	spec, outputs, job := e2eSpec(t, "hello")
	spec.Plan.JobID = "plain"
	spec.Plan.Limits = Limits{CPUs: 2, MemoryBytes: 512 << 20, Timeout: 5 * time.Minute}
	workflow := "name: E2E\non: push\njobs:\n  plain:\n    runs-on: ubuntu-latest\n    steps:\n      - shell: sh\n        run: echo waiting; sleep 300\n"
	if err := os.WriteFile(filepath.Join(spec.RepositoryPath, ".github", "workflows", "e2e.yml"), []byte(workflow), 0o644); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- NewRunner(outputs).Run(ctx, job) }()
	deadline := time.Now().Add(3 * time.Minute)
	for !strings.Contains(text(outputs, job.ExecutionID), "waiting") {
		if time.Now().After(deadline) {
			cancel()
			t.Fatalf("the job never started:\n%s", text(outputs, job.ExecutionID))
		}
		time.Sleep(200 * time.Millisecond)
	}
	inspect := exec.Command(spec.DockerPath, "ps", "--filter", "label="+Label+"="+job.ExecutionID, "--format", "{{.ID}}")
	inspect.Env = []string{"HOME=" + spec.UserHome, "DOCKER_HOST=" + dockerHost(spec.DockerHost)}
	ids, err := inspect.Output()
	if err != nil || strings.TrimSpace(string(ids)) == "" {
		cancel()
		t.Fatalf("no container carries the run's label: %v", err)
	}
	limits := exec.Command(spec.DockerPath, "inspect", "--format", "{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}} {{.HostConfig.NetworkMode}} {{len .Mounts}}", strings.Fields(string(ids))[0])
	limits.Env = inspect.Env
	out, err := limits.Output()
	cancel()
	<-done
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("container: %s", out)
	if fields := strings.Fields(string(out)); len(fields) < 3 || fields[0] != "2000000000" || fields[1] != "536870912" || fields[2] != "bridge" {
		t.Fatalf("limits/network = %q", out)
	}
	assertNoContainers(t, spec)
}
