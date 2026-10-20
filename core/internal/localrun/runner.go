package localrun

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"runnir/core/internal/execution"
)

// Label marks every job container of a run so it can be removed afterwards.
const Label = "dev.runnir.execution"

const (
	stopGrace      = 8 * time.Second
	cleanupTimeout = 30 * time.Second
	maxScanLine    = 1 << 20
)

var ErrTimedOut = errors.New("the run took longer than its time limit and was stopped")

// Spec is an approved run: everything the runner needs, fixed at
// confirmation. It travels in execution.Job.Spec.
type Spec struct {
	ActPath    string
	DockerPath string
	// DockerHost is the engine endpoint act and the cleanup use.
	DockerHost string
	// UserHome is the user's home directory, for the Docker CLI only.
	UserHome       string
	RepositoryPath string
	Plan           Plan
	// CacheDir keeps act's clones of actions between runs.
	CacheDir string
}

// Runner runs approved plans with act. It implements execution.Runner.
type Runner struct {
	outputs *Outputs
	now     func() time.Time
	// grace is how long act gets to stop after an interrupt.
	grace time.Duration
}

func NewRunner(outputs *Outputs) *Runner {
	return &Runner{outputs: outputs, now: time.Now, grace: stopGrace}
}

// Run starts act and waits for it. Cancelling ctx interrupts act's process
// group, kills it after a grace period and still removes the containers.
func (r *Runner) Run(ctx context.Context, job execution.Job) error {
	spec, ok := job.Spec.(*Spec)
	if !ok || spec == nil {
		return execution.ErrEngineUnavailable
	}
	id := job.ExecutionID
	scratch, err := os.MkdirTemp("", "runnir-act-")
	if err != nil {
		return fmt.Errorf("prepare the run: %w", err)
	}
	defer os.RemoveAll(scratch)
	if err := prepareScratch(scratch); err != nil {
		return fmt.Errorf("prepare the run: %w", err)
	}
	if spec.CacheDir != "" {
		if err := os.MkdirAll(spec.CacheDir, 0o700); err != nil {
			return fmt.Errorf("prepare act's cache: %w", err)
		}
	}

	timeout := spec.Plan.Limits.Timeout
	if timeout <= 0 {
		timeout = DefaultTimeout
	}
	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := exec.Command(spec.ActPath, Args(spec, id, scratch)...)
	cmd.Dir = scratch // keeps act from reading an .actrc where the Core runs
	cmd.Env = actEnv(spec, scratch)
	setProcessGroup(cmd)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("start act: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return fmt.Errorf("start act: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start act: %w", err)
	}

	var readers sync.WaitGroup
	readers.Add(2)
	go r.read(&readers, id, stdout, false)
	go r.read(&readers, id, stderr, true)
	waited := make(chan error, 1)
	go func() {
		readers.Wait() // Wait closes the pipes; read them to the end first
		waited <- cmd.Wait()
	}()

	var waitErr error
	stopped, killed := false, false
	select {
	case waitErr = <-waited:
	case <-runCtx.Done():
		stopped = true
		r.outputs.update(id, func(run *run) { run.snap.Phase = PhaseStopping })
		_ = interruptGroup(cmd)
		select {
		case waitErr = <-waited:
		case <-time.After(r.grace):
			killed = true
			_ = killGroup(cmd)
			waitErr = <-waited
		}
	}

	exitCode := -1
	var exitErr *exec.ExitError
	switch {
	case waitErr == nil:
		exitCode = 0
	case errors.As(waitErr, &exitErr) && exitErr.ExitCode() >= 0:
		exitCode = exitErr.ExitCode()
	}
	r.outputs.update(id, func(run *run) {
		run.snap.ExitCode = exitCode
		run.snap.Phase = PhaseCleaningUp
	})
	problem := r.cleanup(spec, id)
	if problem == "" && killed {
		// Only job containers without a container section carry the label;
		// act removes the others itself unless it is killed.
		problem = "act had to be force-stopped. Containers it started for services or jobs with their own container image may remain; their names start with act-."
	}
	if problem != "" {
		r.outputs.update(id, func(run *run) { run.snap.CleanupProblem = problem })
	}

	switch {
	case stopped && errors.Is(runCtx.Err(), context.DeadlineExceeded) && ctx.Err() == nil:
		return ErrTimedOut
	case stopped:
		return ctx.Err()
	case waitErr == nil:
		return nil
	case exitCode > 0:
		return fmt.Errorf("act exited with code %d", exitCode)
	default:
		return errors.New("act stopped unexpectedly")
	}
}

func (r *Runner) read(wg *sync.WaitGroup, id string, stream io.Reader, stderr bool) {
	defer wg.Done()
	scanner := bufio.NewScanner(stream)
	scanner.Buffer(make([]byte, 64*1024), maxScanLine)
	for scanner.Scan() {
		text := scanner.Text()
		r.outputs.update(id, func(run *run) { run.consume(text, r.now(), stderr) })
	}
	// A line longer than maxScanLine ends the scan; drain the rest so act
	// never blocks on a full pipe.
	_, _ = io.Copy(io.Discard, stream)
}

func prepareScratch(dir string) error {
	for _, sub := range []string{"home", "config"} {
		if err := os.Mkdir(filepath.Join(dir, sub), 0o700); err != nil {
			return err
		}
	}
	return os.WriteFile(filepath.Join(dir, "empty"), nil, 0o600)
}

// Args is act's full command line. Every value is fixed by Runnir or comes
// from the approved plan; nothing from the repository adds flags.
func Args(spec *Spec, executionID, scratch string) []string {
	plan := spec.Plan
	empty := filepath.Join(scratch, "empty")
	args := []string{
		plan.Event,
		"--workflows", filepath.Join(spec.RepositoryPath, filepath.FromSlash(plan.WorkflowID)),
		"--directory", spec.RepositoryPath,
		"--json",
		// Remove containers and volumes even when a job fails.
		"--rm",
		// Download an image only when it is missing.
		"--pull=false",
		// Not the engine's host network, which on some engines reaches the
		// Mac's own local services.
		"--network", "bridge",
		// The cache server would listen on a network address of this Mac.
		"--no-cache-server",
		// Never mount the engine's socket into job containers.
		"--container-daemon-socket", "-",
		// Override act's defaults (.env, .secrets, .vars, .input in the
		// repository) so no local file reaches the jobs.
		"--env-file", empty,
		"--secret-file", empty,
		"--var-file", empty,
		"--input-file", empty,
		"--container-options", containerOptions(plan.Limits, executionID),
	}
	if plan.JobID != "" {
		args = append(args, "--job", plan.JobID)
	}
	labels := make([]string, 0, len(Platforms))
	for label := range Platforms {
		labels = append(labels, label)
	}
	sort.Strings(labels)
	for _, label := range labels {
		args = append(args, "--platform", label+"="+Platforms[label])
	}
	return args
}

func containerOptions(limits Limits, executionID string) string {
	options := []string{"--label=" + Label + "=" + executionID}
	if limits.CPUs > 0 {
		options = append(options, "--cpus="+strconv.Itoa(limits.CPUs))
	}
	if limits.MemoryBytes > 0 {
		options = append(options, "--memory="+strconv.FormatUint(limits.MemoryBytes, 10))
	}
	return strings.Join(options, " ")
}

// actEnv gives act a private home and configuration directory, so neither
// the user's nor the repository's act configuration or Docker credentials
// apply, and no token from the Core's environment is passed on.
func actEnv(spec *Spec, scratch string) []string {
	env := []string{
		"HOME=" + filepath.Join(scratch, "home"),
		"XDG_CONFIG_HOME=" + filepath.Join(scratch, "config"),
		"PATH=/usr/bin:/bin:/usr/sbin:/sbin",
		"LANG=C",
		"TMPDIR=" + scratch,
		"ACT_DISABLE_VERSION_CHECK=1",
		"DOCKER_HOST=" + dockerHost(spec.DockerHost),
	}
	if spec.CacheDir != "" {
		env = append(env, "XDG_CACHE_HOME="+spec.CacheDir)
	} else {
		env = append(env, "XDG_CACHE_HOME="+filepath.Join(scratch, "cache"))
	}
	return env
}

func dockerHost(endpoint string) string {
	if endpoint == "" {
		return "unix:///var/run/docker.sock"
	}
	return endpoint
}

// cleanup removes the run's job containers that act left behind, for
// example after it was killed. It returns a problem for the user, or "".
func (r *Runner) cleanup(spec *Spec, executionID string) string {
	if spec.DockerPath == "" {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), cleanupTimeout)
	defer cancel()
	env := []string{"HOME=" + spec.UserHome, "PATH=" + filepath.Dir(spec.DockerPath) + string(os.PathListSeparator) + "/usr/bin:/bin", "LANG=C",
		"DOCKER_HOST=" + dockerHost(spec.DockerHost)}
	list := exec.CommandContext(ctx, spec.DockerPath, "ps", "--all", "--quiet", "--filter", "label="+Label+"="+executionID)
	list.Env = env
	out, err := list.Output()
	if err != nil {
		return "Runnir could not check for containers left by this run. Look for containers labelled " + Label + "=" + executionID + " in your container engine."
	}
	ids := strings.Fields(string(out))
	if len(ids) == 0 {
		return ""
	}
	remove := exec.CommandContext(ctx, spec.DockerPath, append([]string{"rm", "--force", "--volumes"}, ids...)...)
	remove.Env = env
	if err := remove.Run(); err != nil {
		return fmt.Sprintf("Cleanup failed: %d container%s of this run may still exist. Retry, or remove %s in your container engine.",
			len(ids), map[bool]string{true: "", false: "s"}[len(ids) == 1], map[bool]string{true: "it", false: "them"}[len(ids) == 1])
	}
	return ""
}
