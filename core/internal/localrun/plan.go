// Package localrun runs workflows on this computer with act and a
// Docker-compatible engine. Plan reads a workflow and says what a run would
// do and need; Runner executes an approved plan with a fixed act command
// line and records its bounded output.
package localrun

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/rhysd/actionlint"

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

var (
	ErrUnknownJob   = errors.New("the workflow has no job with this id")
	ErrUnknownEvent = errors.New("the workflow is not triggered by this event")
)

type Support int

const (
	Supported Support = iota + 1
	// Unsupported jobs are skipped by act (or would fail); they are listed
	// so the user sees what will not run.
	Unsupported
	// Unknown: act decides when the job starts, for example when runs-on is
	// an expression.
	Unknown
)

type JobPlan struct {
	ID      string
	Name    string
	RunsOn  []string
	Image   string
	Support Support
	Reason  string
}

type Limits struct {
	CPUs        int
	MemoryBytes uint64
	Timeout     time.Duration
}

// LimitsFor caps the defaults at what the engine reports.
func LimitsFor(engine tools.Engine) Limits {
	limits := Limits{CPUs: DefaultCPUs, MemoryBytes: DefaultMemoryBytes, Timeout: DefaultTimeout}
	if engine.CPUs > 0 && engine.CPUs < limits.CPUs {
		limits.CPUs = engine.CPUs
	}
	if engine.MemoryBytes > 0 && engine.MemoryBytes < limits.MemoryBytes {
		limits.MemoryBytes = engine.MemoryBytes
	}
	return limits
}

type Image struct {
	Ref     string
	Present bool
}

type Plan struct {
	WorkflowID   string
	WorkflowName string
	// Events are the workflow's triggers; Event is the one this run uses.
	Events []string
	Event  string
	// JobID is the chosen job; empty runs every job of the workflow. A
	// chosen job brings the jobs it needs.
	JobID  string
	Jobs   []JobPlan
	Images []Image
	// Secrets the workflow reads. Local runs get none of them.
	Secrets  []string
	Notes    []string
	Blockers []string
	Limits   Limits
	// Digest is the SHA-256 of the workflow file the plan was made from.
	Digest string
}

// Runnable reports whether the plan may be confirmed.
func (p Plan) Runnable() bool { return len(p.Blockers) == 0 }

// Request is what the user asked to run.
type Request struct {
	WorkflowID string
	Source     []byte
	JobID      string
	Event      string
}

// NewPlan reads the workflow and decides what a run would do. imagePresent
// is only asked when the tools are ready, and may be nil. It returns ErrUnknownJob or
// ErrUnknownEvent for a request that does not fit the workflow.
func NewPlan(request Request, report tools.Report, useInstalledAct bool, imagePresent func(string) bool) (Plan, error) {
	digest := sha256.Sum256(request.Source)
	plan := Plan{WorkflowID: request.WorkflowID, JobID: request.JobID, Digest: hex.EncodeToString(digest[:]),
		Limits: LimitsFor(report.Engine)}
	plan.Blockers = toolBlockers(report, useInstalledAct)
	if !report.Ready(useInstalledAct) {
		imagePresent = nil
	}

	workflow, errs := actionlint.Parse(request.Source)
	if workflow == nil || len(errs) > 0 {
		plan.Blockers = append(plan.Blockers, fmt.Sprintf("The workflow file has %s. Fix %s in the Workspace before running it locally.",
			plural(len(errs), "syntax error", "syntax errors"), pronoun(len(errs))))
		return plan, nil
	}
	if workflow.Name != nil {
		plan.WorkflowName = workflow.Name.Value
	}

	for _, event := range workflow.On {
		if name := event.EventName(); name != "" && !contains(plan.Events, name) {
			plan.Events = append(plan.Events, name)
		}
	}
	plan.Event = request.Event
	if plan.Event == "" {
		plan.Event = defaultEvent(plan.Events)
	} else if !contains(plan.Events, plan.Event) {
		return Plan{}, ErrUnknownEvent
	}
	if plan.Event == "" {
		plan.Blockers = append(plan.Blockers, "The workflow has no trigger to run it with.")
	}

	ids, err := jobsToRun(workflow, request.JobID)
	if err != nil {
		return Plan{}, err
	}
	images := map[string]bool{}
	containerJobs := []string{}
	services := []string{}
	runnable := 0
	for _, id := range ids {
		job := workflow.Jobs[id]
		jp := planJob(id, job)
		if jp.Support != Unsupported {
			runnable++
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
			for _, name := range serviceNames(job) {
				services = append(services, name)
			}
			for _, name := range dockerSteps(job) {
				images[name] = true
			}
		}
		plan.Jobs = append(plan.Jobs, jp)
	}

	if request.JobID != "" {
		if chosen := plan.job(request.JobID); chosen != nil && chosen.Support == Unsupported {
			plan.Blockers = append(plan.Blockers, fmt.Sprintf("Job %s can't run locally: %s.", request.JobID, lowerFirst(chosen.Reason)))
		}
	}
	if len(ids) > 0 && runnable == 0 && request.JobID == "" {
		plan.Blockers = append(plan.Blockers, "None of this workflow's jobs can run locally.")
	}

	for ref := range images {
		present := false
		if imagePresent != nil {
			present = imagePresent(ref)
		}
		plan.Images = append(plan.Images, Image{Ref: ref, Present: present})
	}
	sort.Slice(plan.Images, func(i, j int) bool { return plan.Images[i].Ref < plan.Images[j].Ref })

	plan.Secrets = secretNames(request.Source)
	plan.Notes = notes(plan, report, containerJobs, services, request.Source)
	return plan, nil
}

func (p *Plan) job(id string) *JobPlan {
	for i := range p.Jobs {
		if p.Jobs[i].ID == id {
			return &p.Jobs[i]
		}
	}
	return nil
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

func defaultEvent(events []string) string {
	for _, preferred := range []string{"push", "pull_request", "workflow_dispatch"} {
		if contains(events, preferred) {
			return preferred
		}
	}
	if len(events) > 0 {
		return events[0]
	}
	return ""
}

// jobsToRun returns the chosen job and every job it needs, or all jobs, in
// the order they appear in the file.
func jobsToRun(workflow *actionlint.Workflow, chosen string) ([]string, error) {
	include := map[string]bool{}
	if chosen == "" {
		for id := range workflow.Jobs {
			include[id] = true
		}
	} else {
		key := strings.ToLower(chosen)
		if workflow.Jobs[key] == nil {
			return nil, ErrUnknownJob
		}
		queue := []string{key}
		for len(queue) > 0 {
			id := queue[0]
			queue = queue[1:]
			if include[id] {
				continue
			}
			include[id] = true
			if job := workflow.Jobs[id]; job != nil {
				for _, need := range job.Needs {
					if need != nil && workflow.Jobs[strings.ToLower(need.Value)] != nil {
						queue = append(queue, strings.ToLower(need.Value))
					}
				}
			}
		}
	}
	ids := make([]string, 0, len(include))
	for id := range include {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return position(workflow.Jobs[ids[i]]) < position(workflow.Jobs[ids[j]]) })
	return ids, nil
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

var secretPattern = regexp.MustCompile(`secrets\.([A-Za-z_][A-Za-z0-9_]*)`)

func secretNames(source []byte) []string {
	seen := map[string]bool{}
	var names []string
	for _, match := range secretPattern.FindAllSubmatch(source, -1) {
		name := string(match[1])
		if !seen[name] {
			seen[name] = true
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names
}

func notes(plan Plan, report tools.Report, containerJobs, services []string, source []byte) []string {
	var notes []string
	if len(plan.Secrets) > 0 {
		notes = append(notes, fmt.Sprintf("The workflow reads %s. Local runs get no secrets, so %s empty.",
			strings.Join(plan.Secrets, ", "), map[bool]string{true: "it is", false: "they are"}[len(plan.Secrets) == 1]))
	}
	if arch := strings.ToLower(report.Engine.Architecture); arch == "aarch64" || arch == "arm64" {
		notes = append(notes, "Jobs run as linux/arm64 on this Mac. Steps that download x64-only tools may fail.")
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
	text := string(source)
	if strings.Contains(text, "actions/upload-artifact") || strings.Contains(text, "actions/download-artifact") {
		notes = append(notes, "Artifact upload and download steps fail locally: Runnir does not start act's artifact server.")
	}
	if strings.Contains(text, "actions/cache") {
		notes = append(notes, "actions/cache finds no cache locally: Runnir does not start act's cache server.")
	}
	return notes
}

func contains(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
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
