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
	// Tests read macOS runners as on Linux unless they say otherwise, so
	// they pass on every system.
	hostOS = "linux"
	dir, err := os.MkdirTemp("", "runnir-fake-")
	if err != nil {
		panic(err)
	}
	fakeDir = dir
	for _, name := range []string{"act", "docker", "sandbox-exec"} {
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
	for _, name := range []string{"act", "docker", "sandbox-exec"} {
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
			Lanes: []Lane{lane(".github/workflows/ci.yml", "push",
				JobPlan{ID: "lint", Support: Supported},
				JobPlan{ID: "build-ios", Support: Unsupported, Reason: "Not supported locally: macOS runner"})},
			Limits: Limits{CPUs: 2, MemoryBytes: 1 << 30, Timeout: time.Minute},
		},
	}
}

// lane is a direct lane of a workflow with every job given ticked, its copy
// naming them and a payload naming its event.
func lane(workflow, event string, jobs ...JobPlan) Lane {
	copied := "on: " + event + "\njobs:\n"
	for i := range jobs {
		jobs[i].Selected = true
		copied += "  " + jobs[i].ID + ":\n    runs-on: ubuntu-latest\n    steps: [{run: echo}]\n"
	}
	return Lane{WorkflowID: workflow, WorkflowName: strings.TrimSuffix(filepath.Base(workflow), ".yml"), Kind: Direct, Event: event,
		Jobs: jobs, Copy: []byte(copied), Payload: []byte(`{"event":"` + event + `"}`)}
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
		"--directory=" + spec.RepositoryPath, "--json", "--rm", "--pull=false", "--network=bridge",
		"--no-cache-server", "--use-new-action-cache", "--container-daemon-socket=-",
		"--container-options=--label=com.runnir.execution=exec_test --cpus=2 --memory=1073741824",
		"--platform=ubuntu-latest=catthehacker/ubuntu:act-latest",
	} {
		if indexOf(call.Args, want) < 0 {
			t.Fatalf("act args lack %q: %v", want, call.Args)
		}
	}
	if n := len(call.Args); n < 2 || call.Args[n-2] != "--" || call.Args[n-1] != "push" {
		t.Fatalf("the event does not follow --: %v", call.Args)
	}
	for _, arg := range call.Args {
		if strings.HasPrefix(arg, "--job") {
			t.Fatalf("a lane runs its copy, not a chosen job: %v", call.Args)
		}
	}
	// act runs the lane's copy of the workflow with the scenario's event,
	// both in the lane's scratch directory.
	for flag, file := range map[string]string{"--workflows=": filepath.Join("workflows", "ci.yml"), "--eventpath=": "event.json"} {
		at := slices.IndexFunc(call.Args, func(arg string) bool { return strings.HasPrefix(arg, flag) })
		if at < 0 || !strings.HasSuffix(call.Args[at], string(filepath.Separator)+filepath.Base(call.Dir)+string(filepath.Separator)+file) {
			t.Fatalf("%s is not the lane's %s: %v", flag, file, call.Args)
		}
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
	if len(docker) != 1 || strings.Join(docker[0].Args, " ") != "ps --all --quiet --filter label=com.runnir.execution=exec_test" {
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
	spec := &Spec{RepositoryPath: "/repo"}
	ci := lane(".github/workflows/ci.yml", "push")
	for _, arg := range Args(spec, ci, "e1", "/scratch") {
		if strings.HasPrefix(arg, "--github-instance") {
			t.Fatalf("a github.com run has %q", arg)
		}
	}
	spec.GitHubInstance = "github.company.com"
	args := Args(spec, ci, "e1", "/scratch")
	at := slices.Index(args, "--github-instance=github.company.com")
	if at < 0 {
		t.Fatalf("args = %v", args)
	}
	if at > slices.Index(args, "--") {
		t.Fatal("the flag comes after --")
	}
}

func TestValuesReachActThroughPipesOnly(t *testing.T) {
	if !PassesValues {
		t.Skip("values are not passed on this platform")
	}
	secretLine := `{"level":"info","job":"CI/lint","jobID":"lint","raw_output":true,"msg":"token s3cr3t-value and second-line here\n"}`
	actPath, dockerPath, dir := fakeTools(t, map[string]any{"copyValueFiles": true, "lines": []string{startLine, secretLine, doneLine}})
	spec := testSpec(t, actPath, dockerPath)
	spec.Secrets = map[string]string{"NPM_TOKEN": "s3cr3t-value", "CERT": "first-line\nsecond-line"}
	spec.Variables = map[string]string{"REGION": "eu-west-1"}
	runner, outputs, job := startRun(t, spec)
	if err := runner.Run(context.Background(), job); err != nil {
		t.Fatalf("Run = %v", err)
	}

	data, err := os.ReadFile(filepath.Join(dir, "act.files"))
	if err != nil {
		t.Fatal(err)
	}
	var files map[string]string
	if err := json.Unmarshal(data, &files); err != nil {
		t.Fatal(err)
	}
	var secrets, variables map[string]string
	if err := json.Unmarshal([]byte(files["--secret-file="]), &secrets); err != nil {
		t.Fatalf("secret file %q: %v", files["--secret-file="], err)
	}
	if err := json.Unmarshal([]byte(files["--var-file="]), &variables); err != nil {
		t.Fatalf("var file %q: %v", files["--var-file="], err)
	}
	if secrets["NPM_TOKEN"] != "s3cr3t-value" || secrets["CERT"] != "first-line\nsecond-line" || secrets["GITHUB_TOKEN"] != "" || len(secrets) != 3 {
		t.Fatalf("secrets = %v", secrets)
	}
	if variables["REGION"] != "eu-west-1" || len(variables) != 1 {
		t.Fatalf("variables = %v", variables)
	}

	call := invocations(t, dir, "act")[0]
	recorded := strings.Join(append(call.Args, call.Env...), "\n")
	for _, value := range []string{"s3cr3t-value", "first-line", "eu-west-1"} {
		if strings.Contains(recorded, value) {
			t.Fatalf("%q in act's arguments or environment", value)
		}
	}
	snap, _ := outputs.Since(job.ExecutionID, 0)
	for _, line := range snap.Lines {
		if strings.Contains(line.Text, "s3cr3t-value") || strings.Contains(line.Text, "second-line") {
			t.Fatalf("secret kept in output: %q", line.Text)
		}
	}
	if spec.Secrets != nil || spec.Variables != nil {
		t.Fatal("values kept after the run")
	}
}

func TestRunWithoutValuesStillPassesGitHubToken(t *testing.T) {
	if !PassesValues {
		t.Skip("values are not passed on this platform")
	}
	actPath, dockerPath, dir := fakeTools(t, map[string]any{"copyValueFiles": true})
	spec := testSpec(t, actPath, dockerPath)
	runner, _, job := startRun(t, spec)
	if err := runner.Run(context.Background(), job); err != nil {
		t.Fatalf("Run = %v", err)
	}
	data, _ := os.ReadFile(filepath.Join(dir, "act.files"))
	var files map[string]string
	_ = json.Unmarshal(data, &files)
	if files["--secret-file="] != `{"GITHUB_TOKEN":""}` || files["--var-file="] != `{}` {
		t.Fatalf("files = %v", files)
	}
}

func TestLanesRunOneAfterAnotherAndAChainNeedsItsSource(t *testing.T) {
	if !PassesValues {
		t.Skip("act's files are recorded on macOS and Linux")
	}
	// ci.yml succeeds, core.yml fails, so notify.yml after it does not run
	// while docs.yml, independent, still does.
	actPath, dockerPath, dir := fakeTools(t, map[string]any{"copyValueFiles": true, "exits": []int{0, 1, 0}})
	spec := testSpec(t, actPath, dockerPath)
	notify := lane(".github/workflows/notify.yml", "workflow_run", JobPlan{ID: "tell", Support: Supported})
	notify.Kind, notify.After = Chained, ".github/workflows/core.yml"
	skipped := lane(".github/workflows/release.yml", "push", JobPlan{ID: "publish", Support: Supported})
	skipped.Jobs[0].Selected = false
	spec.Plan.Lanes = append(spec.Plan.Lanes,
		lane(".github/workflows/core.yml", "pull_request", JobPlan{ID: "lint", Support: Supported}),
		notify, skipped,
		lane(".github/workflows/docs.yml", "push", JobPlan{ID: "build", Support: Supported}))
	runner, outputs, job := startRun(t, spec)
	err := runner.Run(context.Background(), job)
	if err == nil || err.Error() != "1 of 4 workflows failed" {
		t.Fatalf("Run = %v", err)
	}
	calls := invocations(t, dir, "act")
	if len(calls) != 3 {
		t.Fatalf("act ran %d times", len(calls))
	}
	for i, want := range []string{"push", "pull_request", "push"} {
		if args := calls[i].Args; args[len(args)-1] != want {
			t.Fatalf("run %d event = %v", i, args)
		}
	}
	data, _ := os.ReadFile(filepath.Join(dir, "act.files"))
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	var core map[string]string
	if len(lines) != 3 || json.Unmarshal([]byte(lines[1]), &core) != nil {
		t.Fatalf("files = %s", data)
	}
	if core["--eventpath="] != `{"event":"pull_request"}` || !strings.Contains(core["--workflows="], "lint:") {
		t.Fatalf("core.yml got %v", core)
	}
	snap, _ := outputs.Since(job.ExecutionID, 0)
	byWorkflow := map[string]JobStatus{}
	for _, status := range snap.Jobs {
		byWorkflow[status.Workflow+"/"+status.ID] = status
	}
	if len(snap.Jobs) != 5 || byWorkflow[".github/workflows/notify.yml/tell"].State != JobNotRun ||
		byWorkflow[".github/workflows/notify.yml/tell"].Reason != "Not run: core did not succeed" {
		t.Fatalf("jobs = %+v", snap.Jobs)
	}
	if _, ok := byWorkflow[".github/workflows/release.yml/publish"]; ok {
		t.Fatal("a lane without ticks has jobs")
	}
}

func TestMacJobsRunInTheSandboxWithTheShims(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the macOS sandbox is a Mac's")
	}
	actPath, dockerPath, dir := fakeTools(t, map[string]any{"copyValueFiles": true})
	saved := SandboxExec
	SandboxExec = filepath.Join(dir, "sandbox-exec")
	defer func() { SandboxExec = saved }()
	spec := testSpec(t, actPath, dockerPath)
	spec.HostNode = "/opt/homebrew/bin/node"
	mac := lane(".github/workflows/app.yml", "push", JobPlan{ID: "build", Support: Host, RunsOn: []string{"macos-26"}})
	mac.HostLabels = []string{"macos-26"}
	spec.Plan.Lanes = []Lane{spec.Plan.Lanes[0], mac}
	runner, _, job := startRun(t, spec)
	if err := runner.Run(context.Background(), job); err != nil {
		t.Fatalf("Run = %v", err)
	}
	sandboxed := invocations(t, dir, "sandbox-exec")
	calls := invocations(t, dir, "act")
	if len(calls) != 2 || len(sandboxed) != 1 {
		t.Fatalf("act ran %d times, %d in the sandbox", len(calls), len(sandboxed))
	}
	// The Linux lane runs act as before; the Mac lane runs it in the sandbox.
	if slices.Contains(calls[0].Args, "--platform=macos-26=-self-hosted") || !slices.Contains(calls[1].Args, "--platform=macos-26=-self-hosted") {
		t.Fatalf("platforms = %v / %v", calls[0].Args, calls[1].Args)
	}
	if args := sandboxed[0].Args; args[0] != "-f" || filepath.Base(args[1]) != "sandbox.sb" || args[2] != actPath {
		t.Fatalf("sandbox-exec args = %v", args)
	}
	env := strings.Join(calls[1].Env, "\n")
	for _, want := range []string{"CFFIXED_USER_HOME=", "PATH=" + filepath.Join(filepath.Dir(sandboxed[0].Args[1]), "bin") + ":/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:"} {
		if !strings.Contains(env, want) {
			t.Fatalf("act's environment lacks %q: %s", want, env)
		}
	}
	profile, _ := os.ReadFile(filepath.Join(dir, "sandbox.profile"))
	for _, want := range []string{"(deny file-write*)", "(deny file-read* (subpath ", "com.apple.securityd.xpc", realPath(spec.RepositoryPath), realPath(filepath.Dir(actPath))} {
		if !strings.Contains(string(profile), want) {
			t.Fatalf("profile lacks %q:\n%s", want, profile)
		}
	}
}

func TestTheSandboxProfileClosesTheHomeButForWhatTheRunNeeds(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS jobs run on a Mac")
	}
	profile := sandboxProfile(sandboxRoots{Home: "/Users/me", Readable: []string{"/Users/me/code/app", `/Users/me/odd "name"`},
		Writable: []string{"/private/var/folders/x/T/runnir-act-1/0"}})
	for _, want := range []string{
		"(deny file-write*)\n(allow file-write*\n  (subpath \"/private/var/folders/x/T/runnir-act-1/0\")",
		"(deny file-read* (subpath \"/Users/me\"))",
		"(subpath \"/Users/me/code/app\")",
		`(subpath "/Users/me/odd \"name\"")`,
		"(literal \"/Users/me/code\")", "(literal \"/Users/me\")",
		"(global-name \"com.apple.SecurityServer\")",
	} {
		if !strings.Contains(profile, want) {
			t.Fatalf("profile lacks %q:\n%s", want, profile)
		}
	}
}

func TestMacJobsAskedToRunWithoutTheSandboxRunAsActAlone(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS jobs run on a Mac")
	}
	actPath, dockerPath, dir := fakeTools(t, map[string]any{})
	saved := SandboxExec
	SandboxExec = filepath.Join(dir, "sandbox-exec")
	defer func() { SandboxExec = saved }()
	spec := testSpec(t, actPath, dockerPath)
	mac := lane(".github/workflows/app.yml", "push", JobPlan{ID: "build", Support: Host, RunsOn: []string{"macos-26"}})
	mac.HostLabels = []string{"macos-26"}
	spec.Plan.Lanes = []Lane{mac}
	spec.Plan.HostUnsandboxed = true
	runner, _, job := startRun(t, spec)
	if err := runner.Run(context.Background(), job); err != nil {
		t.Fatalf("Run = %v", err)
	}
	calls := invocations(t, dir, "act")
	if len(invocations(t, dir, "sandbox-exec")) != 0 || len(calls) != 1 || !slices.Contains(calls[0].Args, "--platform=macos-26=-self-hosted") {
		t.Fatalf("act calls = %+v", calls)
	}
	path := ""
	for _, entry := range calls[0].Env {
		if v, ok := strings.CutPrefix(entry, "PATH="); ok {
			path = v
		}
	}
	shims := strings.SplitN(path, ":", 2)[0]
	if filepath.Base(shims) != "bin" || !strings.Contains(path, "/opt/homebrew/bin") {
		t.Fatalf("PATH = %s", path)
	}
}

// act runs a step on this Mac from a script in its cache folder and splits
// the script's path at spaces, so a lane with Mac jobs keeps act's cache off
// a path with one ("Runnir Local") and on the run's own folder.
func TestHostLanesKeepActsCacheOffPathsWithSpaces(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("macOS jobs run on a Mac")
	}
	spec := &Spec{CacheDir: "/Users/me/Library/Caches/Runnir Local", DockerHost: "unix:///tmp/engine.sock"}
	env := strings.Join(hostEnv(actEnv(spec, "/tmp/runnir-act-1"), "/tmp/runnir-act-1", ""), "\n")
	if !strings.Contains(env, "XDG_CACHE_HOME=/tmp/runnir-act-1/cache\n") || strings.Contains(env, "Runnir Local") {
		t.Fatalf("a host lane's act cache has a space: %s", env)
	}
	if env := strings.Join(actEnv(spec, "/tmp/runnir-act-1"), "\n"); !strings.Contains(env, "XDG_CACHE_HOME="+spec.CacheDir) {
		t.Fatalf("a container lane lost the shared cache: %s", env)
	}
	spec.CacheDir = "/Users/me/Library/Caches/Runnir"
	if env := strings.Join(hostEnv(actEnv(spec, "/tmp/runnir-act-1"), "/tmp/runnir-act-1", ""), "\n"); !strings.Contains(env, "XDG_CACHE_HOME="+spec.CacheDir) {
		t.Fatalf("a host lane lost a cache without spaces: %s", env)
	}
}
