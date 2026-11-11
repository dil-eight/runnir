// Package localrun runs workflows on this computer with act and a
// Docker-compatible engine. Plan reads a workflow and says what a run would
// do and need; Runner executes an approved plan with a fixed act command
// line and records its bounded output.
package localrun

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"time"

	"github.com/rhysd/actionlint"

	"runnir/core/internal/flow"
	"runnir/core/internal/references"
	"runnir/core/internal/tools"
)

// Limits every local run gets, lowered to what the engine has.
const (
	DefaultCPUs        = 4
	DefaultMemoryBytes = 8 << 30
	DefaultTimeout     = 30 * time.Minute
)

// Platforms maps the GitHub-hosted runner labels act can stand in for to
// runner images: act's medium images, which bootstrap most actions.
var Platforms = map[string]string{
	"ubuntu-latest":    "catthehacker/ubuntu:act-latest",
	"ubuntu-24.04":     "catthehacker/ubuntu:act-24.04",
	"ubuntu-22.04":     "catthehacker/ubuntu:act-22.04",
	"ubuntu-20.04":     "catthehacker/ubuntu:act-20.04",
	"ubuntu-24.04-arm": "catthehacker/ubuntu:act-24.04",
	"ubuntu-22.04-arm": "catthehacker/ubuntu:act-22.04",
}

// ErrUnknownJob: a selection names a job its workflow does not have.
var ErrUnknownJob = errors.New("the workflow has no job with this id")

// The shape GitHub allows for event names. act gets a lane's event on its
// command line, so nothing else from a workflow file may reach it there.
var eventNamePattern = regexp.MustCompile(`^[a-z][a-z_]*$`)

// macOSLabel is a GitHub-hosted macOS runner label act can run on a Mac
// itself (macos-latest, macos-15, macos-26-xlarge). It reaches act's
// command line, so only this shape counts.
var macOSLabel = regexp.MustCompile(`^macos-[a-z0-9][a-z0-9.-]*$`)

// hostOS is the system the Core runs on: on a Mac, macOS jobs run here.
var hostOS = runtime.GOOS

type Support int

const (
	Supported Support = iota + 1
	// Unsupported jobs are skipped by act (or would fail); they are listed
	// so the user sees what will not run.
	Unsupported
	// Unknown: act decides when the job starts, for example when runs-on is
	// an expression.
	Unknown
	// Host: a macOS runner on a Mac. act runs the job on this Mac in the
	// macOS sandbox, not in a container. Never ticked by default.
	Host
)

type JobPlan struct {
	ID      string
	Name    string
	RunsOn  []string
	Image   string
	Support Support
	Reason  string
	// Needs are the jobs it needs, by id as the file spells them.
	Needs []string
	// Selected: ticked, so it runs.
	Selected bool
	// Skipped says why the scenario skips it on GitHub; empty when it runs there.
	Skipped string
	// GitHubOnly: it uses an action that works only on GitHub, or needs a
	// job that does. Unsupported, with the reason; never run locally.
	GitHubOnly bool
}

type Limits struct {
	CPUs        int
	MemoryBytes uint64
	Timeout     time.Duration
}

type Image struct {
	Ref     string
	Present bool
}

// LaneKind says why a workflow is in a run's scenario.
type LaneKind int

const (
	// Direct: the scenario's event starts it.
	Direct LaneKind = iota + 1
	// Chained: workflow_run starts it after another lane.
	Chained
	// Manual: it starts only by hand.
	Manual
	// Outside: the scenario does not start it.
	Outside
)

// Lane is one workflow of a run. act runs it on its own, after the lanes
// before it, with a copy of its file that holds only the selected jobs and
// the jobs they need.
type Lane struct {
	WorkflowID   string
	WorkflowName string
	Kind         LaneKind
	// Event is the event act gets; Why says what starts the lane in the
	// scenario, Skipped why the scenario does not (an Outside lane).
	Event, Why, Skipped string
	// After is the workflow a Chained lane follows.
	After      string
	ParseError string
	// Dispatchable: GitHub can start the workflow by hand.
	Dispatchable bool
	// HostLabels are the macOS runner labels of the lane's selected jobs,
	// which act runs on this Mac.
	HostLabels []string
	Jobs       []JobPlan
	// Digest is the SHA-256 of the file as reviewed; Copy is that file with
	// only the selected jobs, which act runs; Payload is the event act gets,
	// written by the server once the scenario's refs are known.
	Digest  string
	Copy    []byte
	Payload []byte
}

// Selected reports whether any of the lane's jobs runs.
func (l Lane) Selected() bool {
	for _, job := range l.Jobs {
		if job.Selected {
			return true
		}
	}
	return false
}

// Plan is a local run of a scenario: a lane per workflow of the repository,
// and what the selected jobs together need.
type Plan struct {
	Scenarios []flow.Scenario
	Scenario  flow.Scenario
	// Lanes: the scenario's in run order, then those it does not start.
	Lanes  []Lane
	Images []Image
	// Secrets and Variables the selected jobs read, upper-cased. The values
	// the user sets travel in Spec, never in the plan.
	Secrets   []string
	Variables []string
	// UnnamedSecrets: a workflow also reads secrets it does not name.
	UnnamedSecrets bool
	// Environment is the environment whose values the run takes before the
	// Repository's; empty for the Repository's alone or when the user
	// chooses. act gives every job the same values, so for a run of jobs in
	// several environments, or in one an expression picks,
	// EnvironmentChoice says why the user chooses among Environments, which
	// the server fills from ListEnvironments.
	Environment       string
	EnvironmentChoice string
	Environments      []string
	Notes             []string
	Blockers          []string
	// HostJobs are the selected jobs that run on this Mac, as "CI ›
	// build-ios": in the macOS sandbox, or without it when HostUnsandboxed.
	HostJobs        []string
	HostUnsandboxed bool
	// Limits apply to each lane; the timeout is per workflow.
	Limits Limits
	// Ceiling is the most the engine allows; OwnLimits: the limits are the
	// workspace's, not the defaults. LimitWarnings say what they risk and
	// LimitNote what is worth reading about the engine; neither blocks a run.
	Ceiling       Ceiling
	OwnLimits     bool
	LimitWarnings []string
	LimitNote     string
}

// Runnable reports whether the plan may be confirmed.
func (p Plan) Runnable() bool { return len(p.Blockers) == 0 }

// Selected are the lanes that run, in order.
func (p Plan) Selected() []Lane {
	var lanes []Lane
	for _, lane := range p.Lanes {
		if lane.Selected() {
			lanes = append(lanes, lane)
		}
	}
	return lanes
}

// LaneInput is one workflow of the repository as the scenario sees it.
type LaneInput struct {
	WorkflowID string
	Source     []byte
	Kind       LaneKind
	Event      string
	Why        string
	Skipped    string
	After      string
	// ParseError is the planner's; actionlint's errors also stop the lane.
	ParseError string
	// Order lists job ids as the scenario draws them; other jobs follow in
	// the file's order.
	Order []string
	// JobSkipped says why the scenario skips a job, by id.
	JobSkipped map[string]string
	// Selected are the ticked job ids, used when the request is Chosen.
	Selected []string
}

// Request is what the user asked to run.
type Request struct {
	Scenarios []flow.Scenario
	Scenario  flow.Scenario
	Lanes     []LaneInput
	// Chosen: the lanes' Selected are the user's ticks; otherwise the run
	// takes what the scenario starts that can run here.
	Chosen bool
	// HostUnsandboxed runs the selected macOS jobs without the macOS
	// sandbox, as the user asked for this run.
	HostUnsandboxed bool
}

// NewPlan reads the workflows and decides what a run would do with limits
// (`Choose` makes them). imagePresent is only asked when the tools are ready,
// and may be nil. It returns ErrUnknownJob for a selection of a job its
// workflow does not have.
func NewPlan(request Request, report tools.Report, useInstalledAct bool, imagePresent func(string) bool, limits Limits) (Plan, error) {
	plan := Plan{Scenarios: request.Scenarios, Scenario: request.Scenario, Limits: limits}
	plan.Blockers = toolBlockers(report, useInstalledAct)
	if !report.Ready(useInstalledAct) {
		imagePresent = nil
	}
	images := map[string]bool{}
	var containerJobs, services, unparsed, sudo, xcodeTests []string
	var copies [][]byte
	var picks []environmentPick
	secrets, variables := map[string]bool{}, map[string]bool{}
	selected, runnable := 0, 0
	for _, in := range request.Lanes {
		lane, workflow, err := planLane(in, request.Chosen)
		if err != nil {
			return Plan{}, err
		}
		plan.Lanes = append(plan.Lanes, lane)
		if lane.ParseError != "" && in.Kind != Outside && in.Kind != Manual {
			unparsed = append(unparsed, lane.WorkflowID)
		}
		if !lane.Selected() {
			continue
		}
		if !eventNamePattern.MatchString(lane.Event) {
			plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s has no event act can run it with.", lane.WorkflowID))
		}
		copies = append(copies, lane.Copy)
		names := references.Find(lane.Copy)
		for _, name := range names.Secrets {
			secrets[name] = true
		}
		for _, name := range names.Variables {
			variables[name] = true
		}
		plan.UnnamedSecrets = plan.UnnamedSecrets || names.UnnamedSecrets
		var ids []string
		for _, jp := range lane.Jobs {
			if !jp.Selected {
				continue
			}
			selected++
			key := strings.ToLower(jp.ID)
			ids = append(ids, key)
			if jp.GitHubOnly {
				plan.Blockers = append(plan.Blockers, fmt.Sprintf("%s › %s cannot run locally. %s", laneTitle(lane), jp.ID, jp.Reason))
			}
			if jp.Support == Unsupported {
				continue
			}
			runnable++
			if jp.Support == Host {
				plan.HostJobs = append(plan.HostJobs, laneTitle(lane)+" › "+jp.ID)
				if usesSudo(workflow.Jobs[key]) {
					sudo = append(sudo, jp.ID)
				}
				if runsXcodeTests(workflow.Jobs[key]) {
					xcodeTests = append(xcodeTests, jp.ID)
				}
				continue
			}
			job := workflow.Jobs[key]
			if jp.Image != "" {
				images[jp.Image] = true
			}
			// act passes Runnir's container options (limits and the run's
			// label) only to jobs without a container section.
			if job.Container != nil {
				containerJobs = append(containerJobs, jp.ID)
			}
			for _, name := range serviceImages(job) {
				images[name] = true
			}
			services = append(services, serviceNames(job)...)
			for _, name := range dockerSteps(job) {
				images[name] = true
			}
		}
		picks = append(picks, environmentPick{workflow: workflow, ids: ids})
	}
	plan.HostUnsandboxed = request.HostUnsandboxed && len(plan.HostJobs) > 0
	if len(plan.HostJobs) > 0 && !plan.HostUnsandboxed {
		if _, err := os.Stat(SandboxExec); err != nil {
			plan.Blockers = append(plan.Blockers, "macOS jobs run in the macOS sandbox, and this Mac has no sandbox-exec.")
		}
	}
	switch {
	case selected == 0:
		plan.Blockers = append(plan.Blockers, "Tick at least one job to run.")
	case runnable == 0:
		plan.Blockers = append(plan.Blockers, "None of the ticked jobs can run locally.")
	}

	for ref := range images {
		present := false
		if imagePresent != nil {
			present = imagePresent(ref)
		}
		plan.Images = append(plan.Images, Image{Ref: ref, Present: present})
	}
	sort.Slice(plan.Images, func(i, j int) bool { return plan.Images[i].Ref < plan.Images[j].Ref })
	plan.Secrets, plan.Variables = sortedKeys(secrets), sortedKeys(variables)
	sort.Strings(services)
	plan.Notes = notes(plan.UnnamedSecrets, runnable > len(plan.HostJobs), report, containerJobs, services, copies)
	if len(sudo) > 0 {
		plan.Notes = append(plan.Notes, fmt.Sprintf("%s %s sudo. A job on this Mac gets no root: sudo xcode-select -s selects that Xcode for the next steps, any other sudo fails.",
			andList(sudo), map[bool]string{true: "runs", false: "run"}[len(sudo) == 1]))
	}
	if len(xcodeTests) > 0 && !plan.HostUnsandboxed {
		plan.Notes = append(plan.Notes, fmt.Sprintf("%s %s xcodebuild test, which cannot run in the macOS sandbox: Xcode's tests cannot reach Xcode from inside it, so that step fails. swift test works.",
			andList(xcodeTests), map[bool]string{true: "runs", false: "run"}[len(xcodeTests) == 1]))
	}
	if len(unparsed) > 0 {
		plan.Notes = append(plan.Notes, fmt.Sprintf("%s cannot run: fix the syntax errors in the Workspace first.", andList(unparsed)))
	}
	if plan.Scenario.Kind == flow.Merge && selected > 0 {
		plan.Notes = append(plan.Notes, fmt.Sprintf("The run uses this working tree as if merged into %s; a real merge can differ when %s has moved on.",
			plan.Scenario.Target, plan.Scenario.Target))
	}
	var environmentNote string
	plan.Environment, plan.EnvironmentChoice, environmentNote = runEnvironment(picks)
	if environmentNote != "" {
		plan.Notes = append(plan.Notes, environmentNote)
	}
	return plan, nil
}

// planLane plans one workflow: its jobs, which are selected, and the copy
// of its file act runs.
func planLane(in LaneInput, chosen bool) (Lane, *actionlint.Workflow, error) {
	digest := sha256.Sum256(in.Source)
	lane := Lane{WorkflowID: in.WorkflowID, Kind: in.Kind, Event: in.Event, Why: in.Why, Skipped: in.Skipped, After: in.After,
		ParseError: in.ParseError, Digest: hex.EncodeToString(digest[:])}
	workflow, errs := actionlint.Parse(in.Source)
	if workflow == nil || len(errs) > 0 {
		if lane.ParseError == "" {
			lane.ParseError = fmt.Sprintf("The file has %s.", plural(len(errs), "syntax error", "syntax errors"))
		}
		if chosen && len(in.Selected) > 0 {
			return Lane{}, nil, ErrUnknownJob
		}
		return lane, nil, nil
	}
	if workflow.Name != nil {
		lane.WorkflowName = workflow.Name.Value
	}
	for _, event := range workflow.On {
		if event.EventName() == "workflow_dispatch" {
			lane.Dispatchable = true
		}
	}
	for _, key := range jobOrder(workflow, in.Order) {
		job := workflow.Jobs[key]
		jp := planJob(key, job)
		for _, need := range job.Needs {
			if need != nil && workflow.Jobs[strings.ToLower(need.Value)] != nil {
				jp.Needs = append(jp.Needs, planJob(strings.ToLower(need.Value), workflow.Jobs[strings.ToLower(need.Value)]).ID)
			}
		}
		jp.Skipped = skippedReason(in.JobSkipped, jp.ID)
		lane.Jobs = append(lane.Jobs, jp)
	}
	markGitHubOnly(lane.Jobs, workflow)

	var ticked []string
	if chosen {
		for _, id := range in.Selected {
			if workflow.Jobs[strings.ToLower(id)] == nil {
				return Lane{}, nil, ErrUnknownJob
			}
			ticked = append(ticked, strings.ToLower(id))
		}
	} else if in.Kind == Direct || in.Kind == Chained {
		for _, jp := range lane.Jobs {
			if jp.Support != Unsupported && jp.Support != Host && jp.Skipped == "" {
				ticked = append(ticked, strings.ToLower(jp.ID))
			}
		}
	}
	keep := Closure(workflow, ticked)
	labels := map[string]bool{}
	for i := range lane.Jobs {
		job := &lane.Jobs[i]
		job.Selected = keep[strings.ToLower(job.ID)]
		if job.Selected && job.Support == Host {
			for _, label := range job.RunsOn {
				if macOSLabel.MatchString(strings.ToLower(label)) {
					labels[strings.ToLower(label)] = true
				}
			}
		}
	}
	lane.HostLabels = sortedKeys(labels)
	if lane.Selected() {
		copied, err := Trim(in.Source, keep)
		if err != nil {
			lane.ParseError = "The file could not be copied for act."
			for i := range lane.Jobs {
				lane.Jobs[i].Selected = false
			}
		}
		lane.Copy = copied
	}
	return lane, workflow, nil
}

// usesSudo reports a job with a run step that calls sudo.
func usesSudo(job *actionlint.Job) bool {
	for _, step := range job.Steps {
		if step == nil {
			continue
		}
		if run, ok := step.Exec.(*actionlint.ExecRun); ok && run.Run != nil && sudoCall.MatchString(run.Run.Value) {
			return true
		}
	}
	return false
}

var sudoCall = regexp.MustCompile(`(^|[\s;&|(])sudo\s`)

// runsXcodeTests reports a job with a run step that runs xcodebuild's tests.
func runsXcodeTests(job *actionlint.Job) bool {
	for _, step := range job.Steps {
		if step == nil {
			continue
		}
		if run, ok := step.Exec.(*actionlint.ExecRun); ok && run.Run != nil && xcodeTestCall.MatchString(run.Run.Value) {
			return true
		}
	}
	return false
}

var xcodeTestCall = regexp.MustCompile(`xcodebuild\b[^\n;&|]*\s(test|test-without-building)(\s|$)`)

func skippedReason(skipped map[string]string, id string) string {
	for key, reason := range skipped {
		if strings.EqualFold(key, id) {
			return reason
		}
	}
	return ""
}

// jobOrder lists the workflow's job keys as the scenario draws them, then
// the rest in the file's order.
func jobOrder(workflow *actionlint.Workflow, order []string) []string {
	seen := map[string]bool{}
	var keys []string
	for _, id := range order {
		key := strings.ToLower(id)
		if workflow.Jobs[key] != nil && !seen[key] {
			seen[key] = true
			keys = append(keys, key)
		}
	}
	var rest []string
	for key := range workflow.Jobs {
		if !seen[key] {
			rest = append(rest, key)
		}
	}
	sort.Slice(rest, func(i, j int) bool { return position(workflow.Jobs[rest[i]]) < position(workflow.Jobs[rest[j]]) })
	return append(keys, rest...)
}

// Closure is the jobs given and every job they need, all the way down, by
// lower-cased key.
func Closure(workflow *actionlint.Workflow, ids []string) map[string]bool {
	include := map[string]bool{}
	queue := append([]string(nil), ids...)
	for len(queue) > 0 {
		id := strings.ToLower(queue[0])
		queue = queue[1:]
		job := workflow.Jobs[id]
		if include[id] || job == nil {
			continue
		}
		include[id] = true
		for _, need := range job.Needs {
			if need != nil {
				queue = append(queue, need.Value)
			}
		}
	}
	return include
}

func sortedKeys(set map[string]bool) []string {
	keys := make([]string, 0, len(set))
	for key := range set {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

// environmentPick is the selected jobs of one workflow.
type environmentPick struct {
	workflow *actionlint.Workflow
	ids      []string
}

// runEnvironment is the environment whose values a run of these jobs takes,
// or why the user chooses it, and a note when the run's jobs do not all get
// what GitHub would give them.
func runEnvironment(picks []environmentPick) (environment, choice, note string) {
	names := map[string]bool{}
	var picked []string
	without := false
	for _, pick := range picks {
		for _, id := range pick.ids {
			job := pick.workflow.Jobs[id]
			switch {
			case job.Environment == nil || job.Environment.Name == nil || job.Environment.Name.Value == "":
				without = true
			case job.Environment.Name.ContainsExpression():
				picked = append(picked, planJob(id, job).ID)
			default:
				names[job.Environment.Name.Value] = true
			}
		}
	}
	list := sortedKeys(names)
	sort.Strings(picked)
	switch {
	case len(picked) == 1:
		return "", fmt.Sprintf("%s picks its environment with an expression, known only when it runs.", picked[0]), ""
	case len(picked) > 1:
		return "", fmt.Sprintf("%s pick their environment with an expression, known only when they run.", andList(picked)), ""
	case len(list) > 1:
		return "", fmt.Sprintf("Jobs of this run deploy to %s, and act gives every job the same values.", andList(list)), ""
	case len(list) == 1 && without:
		return list[0], "", fmt.Sprintf("act gives every job of this run the same values: %s's, then the Repository's.", list[0])
	case len(list) == 1:
		return list[0], "", ""
	}
	return "", "", ""
}

func toolBlockers(report tools.Report, useInstalledAct bool) []string {
	var blockers []string
	if act, _ := report.Act(useInstalledAct); act.State != tools.Found {
		blockers = append(blockers, "act is not available: "+lowerFirst(act.Detail))
	}
	if report.DockerCLI.State != tools.Found {
		blockers = append(blockers, "The Docker CLI is not available: "+lowerFirst(report.DockerCLI.Detail))
	}
	engine := report.Engine
	switch {
	case report.DockerCLI.State != tools.Found:
	case engine.State == tools.Found && !engine.Local:
		blockers = append(blockers, "The container engine is on another computer.")
	case engine.State != tools.Found:
		blockers = append(blockers, engine.Detail)
	}
	return blockers
}

func position(job *actionlint.Job) int {
	if job == nil || job.Pos == nil {
		return 0
	}
	return job.Pos.Line
}

func planJob(key string, job *actionlint.Job) JobPlan {
	jp := JobPlan{ID: key}
	if job.ID != nil {
		jp.ID = job.ID.Value
	}
	if job.Name != nil {
		jp.Name = job.Name.Value
	}
	if job.WorkflowCall != nil {
		jp.Support = Unknown
		jp.Reason = "Calls a reusable workflow; act runs those with limited support"
		return jp
	}
	runner := job.RunsOn
	if runner == nil {
		jp.Support = Unsupported
		jp.Reason = "No runs-on"
		return jp
	}
	if runner.LabelsExpr != nil {
		jp.RunsOn = []string{runner.LabelsExpr.Value}
		jp.Support = Unknown
		jp.Reason = "runs-on is an expression; act decides when the job starts"
		return jp
	}
	for _, label := range runner.Labels {
		if label != nil {
			jp.RunsOn = append(jp.RunsOn, label.Value)
		}
	}
	if runner.Group != nil {
		jp.Support = Unsupported
		jp.Reason = "Needs a runner group"
		return jp
	}
	for _, label := range jp.RunsOn {
		if strings.Contains(label, "${{") {
			jp.Support = Unknown
			jp.Reason = "runs-on is an expression; act decides when the job starts"
			return jp
		}
	}
	for _, label := range jp.RunsOn {
		if hostOS == "darwin" && macOSLabel.MatchString(strings.ToLower(label)) {
			jp.Support = Host
			jp.Reason = "Runs on this Mac in the macOS sandbox, not in a container"
			return jp
		}
		if image, ok := Platforms[strings.ToLower(label)]; ok {
			jp.Image = image
			jp.Support = Supported
			if job.Container != nil && job.Container.Image != nil {
				if image := job.Container.Image.Value; image != "" && !strings.Contains(image, "${{") {
					jp.Image = image
				}
			}
			return jp
		}
	}
	jp.Support = Unsupported
	jp.Reason = unsupportedReason(jp.RunsOn)
	return jp
}

func unsupportedReason(labels []string) string {
	for _, label := range labels {
		lower := strings.ToLower(label)
		switch {
		case lower == "self-hosted":
			return "Not supported locally: self-hosted runner"
		case strings.HasPrefix(lower, "macos"):
			return "Not supported locally: macOS runner"
		case strings.HasPrefix(lower, "windows"):
			return "Not supported locally: Windows runner"
		}
	}
	if len(labels) == 0 {
		return "No runs-on"
	}
	return "No local image for runner " + strings.Join(labels, ", ")
}

func serviceImages(job *actionlint.Job) []string {
	var images []string
	if job.Services == nil {
		return nil
	}
	for _, service := range job.Services.Value {
		if service != nil && service.Container != nil && service.Container.Image != nil {
			if image := service.Container.Image.Value; image != "" && !strings.Contains(image, "${{") {
				images = append(images, image)
			}
		}
	}
	return images
}

func serviceNames(job *actionlint.Job) []string {
	if job.Services == nil {
		return nil
	}
	var names []string
	for key, service := range job.Services.Value {
		name := key
		if service != nil && service.Name != nil {
			name = service.Name.Value
		}
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

func dockerSteps(job *actionlint.Job) []string {
	var images []string
	for _, step := range job.Steps {
		if step == nil {
			continue
		}
		action, ok := step.Exec.(*actionlint.ExecAction)
		if !ok || action.Uses == nil {
			continue
		}
		if image, found := strings.CutPrefix(action.Uses.Value, "docker://"); found && image != "" && !strings.Contains(image, "${{") {
			images = append(images, image)
		}
	}
	return images
}

func notes(unnamedSecrets, contained bool, report tools.Report, containerJobs, services []string, sources [][]byte) []string {
	var notes []string
	if unnamedSecrets {
		notes = append(notes, "A workflow of this run reads secrets it does not name; only the listed ones are passed.")
	}
	if arch := strings.ToLower(report.Engine.Architecture); contained && (arch == "aarch64" || arch == "arm64") {
		notes = append(notes, "Jobs in containers run as linux/arm64 on this Mac. Steps that download x64-only tools may fail.")
	}
	if len(services) > 0 {
		notes = append(notes, "act starts service containers: "+strings.Join(services, ", ")+".")
	}
	if len(containerJobs) > 0 {
		one := len(containerJobs) == 1
		notes = append(notes, fmt.Sprintf("%s run%s in %s own container image, so the CPU and memory limits do not apply to %s.",
			strings.Join(containerJobs, ", "), map[bool]string{true: "s", false: ""}[one],
			map[bool]string{true: "its", false: "their"}[one], map[bool]string{true: "it", false: "them"}[one]))
	}
	text := string(bytes.Join(sources, []byte("\n")))
	if strings.Contains(text, "actions/upload-artifact") || strings.Contains(text, "actions/download-artifact") {
		notes = append(notes, "Artifact upload and download steps fail locally: Runnir does not start act's artifact server.")
	}
	if strings.Contains(text, "actions/cache") {
		notes = append(notes, "actions/cache finds no cache locally: Runnir does not start act's cache server.")
	}
	return notes
}

func plural(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return fmt.Sprintf("%d %s", n, many)
}

func pronoun(n int) string {
	if n == 1 {
		return "it"
	}
	return "them"
}

func lowerFirst(text string) string {
	if text == "" || strings.HasPrefix(text, "act") {
		return text
	}
	return strings.ToLower(text[:1]) + text[1:]
}
