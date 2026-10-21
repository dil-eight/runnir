package localrun

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"runnir/core/internal/execution"
)

var fakeDir string

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "runnir-fake-")
	if err != nil {
		panic(err)
	}
	fakeDir = dir
	for _, name := range []string{"act", "docker"} {
		out := filepath.Join(dir, name)
		if runtime.GOOS == "windows" {
			out += ".exe"
		}
		build := exec.Command("go", "build", "-o", out, "./testdata/fake")
		build.Env = append(os.Environ(), "CGO_ENABLED=0")
		if output, err := build.CombinedOutput(); err != nil {
			panic(string(output))
		}
	}
	code := m.Run()
	os.RemoveAll(dir)
	os.Exit(code)
}

// fakeTools copies the fake act and docker into a fresh directory with the
// given act script, so tests do not share recordings.
func fakeTools(t *testing.T, script map[string]any) (actPath, dockerPath, dir string) {
	t.Helper()
	dir = t.TempDir()
	for _, name := range []string{"act", "docker"} {
		file := name
		if runtime.GOOS == "windows" {
			file += ".exe"
		}
		data, err := os.ReadFile(filepath.Join(fakeDir, file))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, file), data, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	encoded, _ := json.Marshal(script)
	if err := os.WriteFile(filepath.Join(dir, "act.json"), encoded, 0o600); err != nil {
		t.Fatal(err)
	}
	actPath, dockerPath = filepath.Join(dir, "act"), filepath.Join(dir, "docker")
	if runtime.GOOS == "windows" {
		actPath += ".exe"
		dockerPath += ".exe"
	}
	return actPath, dockerPath, dir
}

type recorded struct {
	Args []string `json:"args"`
	Env  []string `json:"env"`
	Dir  string   `json:"dir"`
}

func invocations(t *testing.T, dir, name string) []recorded {
	t.Helper()
	f, err := os.Open(filepath.Join(dir, name+".invocations"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var out []recorded
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 1<<20), 1<<20)
	for scanner.Scan() {
		var r recorded
		if err := json.Unmarshal(scanner.Bytes(), &r); err != nil {
			t.Fatal(err)
		}
		out = append(out, r)
	}
	return out
}

func testSpec(t *testing.T, actPath, dockerPath string) *Spec {
	repo := t.TempDir()
	return &Spec{
		ActPath: actPath, DockerPath: dockerPath, DockerHost: "unix:///tmp/engine.sock",
		UserHome: t.TempDir(), RepositoryPath: repo, CacheDir: filepath.Join(t.TempDir(), "cache"),
		Plan: Plan{
			WorkflowID: ".github/workflows/ci.yml", Event: "push", JobID: "lint",
			Jobs:   []JobPlan{{ID: "lint", Support: Supported}, {ID: "build-ios", Support: Unsupported, Reason: "Not supported locally: macOS runner"}},
			Limits: Limits{CPUs: 2, MemoryBytes: 1 << 30, Timeout: time.Minute},
		},
	}
}

func startRun(t *testing.T, spec *Spec) (*Runner, *Outputs, execution.Job) {
	outputs := NewOutputs()
	runner := NewRunner(outputs)
	job := execution.Job{ExecutionID: "exec_test", RepositoryID: "repo", RepositoryPath: spec.RepositoryPath, Spec: spec}
	outputs.Create(job.ExecutionID, job.RepositoryID, spec.Plan, "0.2.89", false, "OrbStack")
	return runner, outputs, job
}

const (
	startLine  = `{"level":"info","job":"CI/lint","jobID":"lint","msg":"🚀  Start image=catthehacker/ubuntu:act-latest","time":"2026-10-20T10:00:00Z"}`
	outputLine = `{"level":"info","job":"CI/lint","jobID":"lint","raw_output":true,"msg":"\u001b[32mok\u001b[0m\n"}`
	doneLine   = `{"level":"info","job":"CI/lint","jobID":"lint","jobResult":"success","msg":"🏁  Job succeeded"}`
	failLine   = `{"level":"info","job":"CI/lint","jobID":"lint","jobResult":"failure","msg":"🏁  Job failed"}`
)

func TestSuccessfulRunRecordsOutputAndJobs(t *testing.T) {
	t.Setenv("GITHUB_TOKEN", "ghp_should_not_leak")
	actPath, dockerPath, dir := fakeTools(t, map[string]any{"lines": []string{startLine, outputLine, doneLine}, "stderr": []string{"plain text"}})
	spec := testSpec(t, actPath, dockerPath)
	runner, outputs, job := startRun(t, spec)

	if err := runner.Run(context.Background(), job); err != nil {
		t.Fatalf("Run = %v", err)
	}
	snap, _ := outputs.Since(job.ExecutionID, 0)
	if snap.ExitCode != 0 || snap.CleanupProblem != "" {
		t.Fatalf("exit=%d cleanup=%q", snap.ExitCode, snap.CleanupProblem)
	}
	texts := []string{}
	for _, line := range snap.Lines {
		texts = append(texts, line.Text)
	}
	joined := strings.Join(texts, "\n")
	for _, want := range []string{"[CI/lint] 🚀  Start image=catthehacker/ubuntu:act-latest", "[CI/lint]   | ok", "plain text"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("output lacks %q:\n%s", want, joined)
		}
	}
	if strings.Contains(joined, "\x1b") {
		t.Fatal("ANSI escape kept")
	}
	if snap.Jobs[0].State != JobSucceeded || snap.Jobs[1].State != JobUnsupported {
		t.Fatalf("jobs = %+v", snap.Jobs)
	}

	calls := invocations(t, dir, "act")
	if len(calls) != 1 {
		t.Fatalf("act ran %d times", len(calls))
	}
	call := calls[0]
	for _, want := range []string{
		"--workflows=" + filepath.Join(spec.RepositoryPath, ".github", "workflows", "ci.yml"),
		"--directory=" + spec.RepositoryPath, "--json", "--rm", "--pull=false", "--network=bridge",
		"--no-cache-server", "--container-daemon-socket=-", "--job=lint",
		"--container-options=--label=dev.runnir.execution=exec_test --cpus=2 --memory=1073741824",
		"--platform=ubuntu-latest=catthehacker/ubuntu:act-latest",
	} {
		if indexOf(call.Args, want) < 0 {
			t.Fatalf("act args lack %q: %v", want, call.Args)
		}
	}
	if n := len(call.Args); n < 2 || call.Args[n-2] != "--" || call.Args[n-1] != "push" {
		t.Fatalf("the event does not follow --: %v", call.Args)
	}
	for _, flag := range []string{"--env-file=", "--secret-file=", "--var-file=", "--input-file="} {
		value := ""
		for _, arg := range call.Args {
			if v, ok := strings.CutPrefix(arg, flag); ok {
				value = v
			}
		}
		// The scratch directory is gone by now, so compare names.
		if value == "" || filepath.Base(filepath.Dir(value)) != filepath.Base(call.Dir) {
			t.Fatalf("%s points at %v", flag, call.Args)
		}
	}
	env := strings.Join(call.Env, "\n")
	if strings.Contains(env, "ghp_should_not_leak") || strings.Contains(env, "HOME="+spec.UserHome) {
		t.Fatalf("act environment leaks: %s", env)
	}
	for _, want := range []string{"DOCKER_HOST=unix:///tmp/engine.sock", "ACT_DISABLE_VERSION_CHECK=1", "XDG_CACHE_HOME=" + spec.CacheDir} {
		if !strings.Contains(env, want) {
			t.Fatalf("act environment lacks %q: %s", want, env)
		}
	}
	if sameDir(call.Dir, spec.RepositoryPath) {
		t.Fatal("act ran in the repository, where it would read .actrc")
	}
	if _, err := os.Stat(call.Dir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("scratch directory kept: %v", err)
	}

	docker := invocations(t, dir, "docker")
	if len(docker) != 1 || strings.Join(docker[0].Args, " ") != "ps --all --quiet --filter label=dev.runnir.execution=exec_test" {
		t.Fatalf("docker calls = %+v", docker)
	}
}

func TestFailedRunReportsTheExitCode(t *testing.T) {
	actPath, dockerPath, _ := fakeTools(t, map[string]any{"lines": []string{startLine, failLine}, "exit": 1})
	runner, outputs, job := startRun(t, testSpec(t, actPath, dockerPath))
	err := runner.Run(context.Background(), job)
	if err == nil || err.Error() != "act exited with code 1" {
		t.Fatalf("Run = %v", err)
	}
	snap, _ := outputs.Since(job.ExecutionID, 0)
	if snap.ExitCode != 1 || snap.Jobs[0].State != JobFailed {
		t.Fatalf("exit=%d jobs=%+v", snap.ExitCode, snap.Jobs)
	}
}

func waitForLine(t *testing.T, outputs *Outputs, id string) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if snap, _ := outputs.Since(id, 0); len(snap.Lines) > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("act wrote nothing")
}

func TestCancelStopsActAndRemovesContainers(t *testing.T) {
	actPath, dockerPath, dir := fakeTools(t, map[string]any{"lines": []string{startLine}, "waitForSignal": true})
	if err := os.WriteFile(filepath.Join(dir, "containers"), []byte("abc123\ndef456\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runner, outputs, job := startRun(t, testSpec(t, actPath, dockerPath))
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runner.Run(ctx, job) }()
	waitForLine(t, outputs, job.ExecutionID)
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("Run = %v", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("Run did not return after cancel")
	}
	docker := invocations(t, dir, "docker")
	if len(docker) != 2 || strings.Join(docker[1].Args, " ") != "rm --force --volumes abc123 def456" {
		t.Fatalf("docker calls = %+v", docker)
	}
	if snap, _ := outputs.Since(job.ExecutionID, 0); snap.CleanupProblem != "" {
		t.Fatalf("cleanup problem %q", snap.CleanupProblem)
	}
}

func TestActThatIgnoresTheInterruptIsKilled(t *testing.T) {
	actPath, dockerPath, _ := fakeTools(t, map[string]any{"lines": []string{startLine}, "waitForSignal": true, "ignoreInterrupt": true})
	runner, outputs, job := startRun(t, testSpec(t, actPath, dockerPath))
	runner.grace = 200 * time.Millisecond
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- runner.Run(ctx, job) }()
	waitForLine(t, outputs, job.ExecutionID)
	cancel()
	select {
	case <-done:
	case <-time.After(15 * time.Second):
		t.Fatal("Run did not return after the grace period")
	}
	snap, _ := outputs.Since(job.ExecutionID, 0)
	if snap.ExitCode != -1 && runtime.GOOS != "windows" {
		t.Fatalf("exit code = %d, want -1 for a killed act", snap.ExitCode)
	}
	if runtime.GOOS != "windows" && !strings.Contains(snap.CleanupProblem, "force-stopped") {
		t.Fatalf("cleanup problem = %q", snap.CleanupProblem)
	}
}

func TestRunsStopAtTheirTimeLimit(t *testing.T) {
	actPath, dockerPath, _ := fakeTools(t, map[string]any{"lines": []string{startLine}, "waitForSignal": true})
	spec := testSpec(t, actPath, dockerPath)
	spec.Plan.Limits.Timeout = 300 * time.Millisecond
	runner, _, job := startRun(t, spec)
	if err := runner.Run(context.Background(), job); !errors.Is(err, ErrTimedOut) {
		t.Fatalf("Run = %v", err)
	}
}

func TestFailedCleanupIsReported(t *testing.T) {
	actPath, dockerPath, dir := fakeTools(t, map[string]any{"lines": []string{startLine, doneLine}})
	_ = os.WriteFile(filepath.Join(dir, "containers"), []byte("abc123\n"), 0o600)
	_ = os.WriteFile(filepath.Join(dir, "rm-fails"), nil, 0o600)
	runner, outputs, job := startRun(t, testSpec(t, actPath, dockerPath))
	if err := runner.Run(context.Background(), job); err != nil {
		t.Fatalf("Run = %v", err)
	}
	snap, _ := outputs.Since(job.ExecutionID, 0)
	if !strings.Contains(snap.CleanupProblem, "1 container of this run may still exist") {
		t.Fatalf("cleanup problem %q", snap.CleanupProblem)
	}
}

func TestJobWithoutAPlanIsRefused(t *testing.T) {
	runner := NewRunner(NewOutputs())
	if err := runner.Run(context.Background(), execution.Job{ExecutionID: "exec_x"}); !errors.Is(err, execution.ErrEngineUnavailable) {
		t.Fatalf("Run = %v", err)
	}
}

func indexOf(list []string, value string) int {
	for i, item := range list {
		if item == value {
			return i
		}
	}
	return -1
}

func sameDir(a, b string) bool {
	ra, errA := filepath.EvalSymlinks(a)
	rb, errB := filepath.EvalSymlinks(b)
	return errA == nil && errB == nil && ra == rb
}

func TestArgsNameTheEnterpriseInstance(t *testing.T) {
	spec := &Spec{RepositoryPath: "/repo", Plan: Plan{WorkflowID: ".github/workflows/ci.yml", Event: "push"}}
	for _, arg := range Args(spec, "e1", "/scratch") {
		if strings.HasPrefix(arg, "--github-instance") {
			t.Fatalf("a github.com run has %q", arg)
		}
	}
	spec.GitHubInstance = "github.company.com"
	args := Args(spec, "e1", "/scratch")
	at := slices.Index(args, "--github-instance=github.company.com")
	if at < 0 {
		t.Fatalf("args = %v", args)
	}
	if at > slices.Index(args, "--") {
		t.Fatal("the flag comes after --")
	}
}
