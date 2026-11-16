package localrun

import (
	"encoding/json"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"runnir/core/internal/events"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// Output bounds: the newest lines of each job of a run are kept (act's own
// messages count as a job of their workflow), each cut to a length, and only
// the most recent runs are remembered.
const (
	MaxLines     = 5000
	MaxLineBytes = 4096
	MaxRuns      = 20
)

type JobState int

const (
	JobWaiting JobState = iota + 1
	JobRunning
	JobSucceeded
	JobFailed
	JobSkipped
	JobUnsupported
	JobCancelled
	JobNotRun
)

type JobStatus struct {
	// Workflow is the lane the job is in.
	Workflow   string
	ID         string
	Name       string
	State      JobState
	Reason     string
	StartedAt  time.Time
	FinishedAt time.Time
}

type Line struct {
	Sequence uint64
	// Workflow is the lane that was running; JobID is empty for act's own
	// messages.
	Workflow string
	JobID    string
	Text     string
	Error    bool
}

type Phase int

const (
	PhaseQueued Phase = iota + 1
	PhaseRunning
	PhaseStopping
	PhaseCleaningUp
	PhaseFinished
)

// Snapshot is a copy of one run's output after a sequence number.
type Snapshot struct {
	ExecutionID    string
	RepositoryID   string
	State          corev1.ExecutionState
	Phase          Phase
	Lines          []Line
	Discarded      bool         // lines after the requested sequence were dropped
	DiscardedJobs  []LineSource // the jobs those lines were from, sorted
	Jobs           []JobStatus
	Plan           Plan
	ActVersion     string
	ActInstalled   bool
	EngineName     string
	StartedAt      time.Time
	FinishedAt     time.Time
	ExitCode       int // -1 until act exits, or when it was killed
	Message        string
	CleanupProblem string
	LastSequence   uint64
	// StartedBy is the MCP client that started the run; empty for the user.
	StartedBy string
}

// laneTimes is when a lane's act started and ended.
type laneTimes struct {
	started, finished time.Time
}

type run struct {
	snap Snapshot
	// lane is the workflow of the lane running; lanes their times.
	lane  string
	lanes map[string]laneTimes
	// outputs keeps each job's newest lines, so a job that writes a lot
	// never pushes out what another one wrote.
	outputs map[LineSource]*ring
	next    uint64
	// masks are the secret values hidden in kept lines while the run goes.
	masks []string
}

// Outputs keeps the output of recent local runs. Safe for concurrent use.
type Outputs struct {
	mu    sync.Mutex
	runs  map[string]*run
	order []string
	now   func() time.Time
}

func NewOutputs() *Outputs {
	return &Outputs{runs: map[string]*run{}, now: time.Now}
}

// Create records a confirmed run before it starts.
func (o *Outputs) Create(executionID, repositoryID string, plan Plan, actVersion string, actInstalled bool, engineName string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	r := &run{snap: Snapshot{ExecutionID: executionID, RepositoryID: repositoryID, Plan: plan,
		State: corev1.ExecutionState_EXECUTION_STATE_QUEUED, Phase: PhaseQueued, ExitCode: -1,
		ActVersion: actVersion, ActInstalled: actInstalled, EngineName: engineName}}
	r.lanes = map[string]laneTimes{}
	for _, lane := range plan.Selected() {
		for _, job := range lane.Jobs {
			if !job.Selected {
				continue
			}
			status := JobStatus{Workflow: lane.WorkflowID, ID: job.ID, Name: job.Name, State: JobWaiting}
			if job.Support == Unsupported {
				status.State, status.Reason = JobUnsupported, job.Reason
			}
			r.snap.Jobs = append(r.snap.Jobs, status)
		}
	}
	o.runs[executionID] = r
	o.order = append(o.order, executionID)
	for len(o.order) > MaxRuns {
		oldest := o.order[0]
		if old := o.runs[oldest]; old != nil && old.snap.Phase != PhaseFinished {
			break // never forget a run that is still going
		}
		delete(o.runs, oldest)
		o.order = o.order[1:]
	}
}

// Remove forgets a run that could not be started.
func (o *Outputs) Remove(executionID string) {
	o.mu.Lock()
	defer o.mu.Unlock()
	delete(o.runs, executionID)
	for i, id := range o.order {
		if id == executionID {
			o.order = append(o.order[:i], o.order[i+1:]...)
			break
		}
	}
}

// Observe follows the coordinator's events, which own the run's state.
func (o *Outputs) Observe(e events.Event) {
	if e.ExecutionID == "" {
		return
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	r := o.runs[e.ExecutionID]
	if r == nil || e.ExecutionState == corev1.ExecutionState_EXECUTION_STATE_UNSPECIFIED {
		return
	}
	r.snap.State = e.ExecutionState
	now := o.now()
	switch e.ExecutionState {
	case corev1.ExecutionState_EXECUTION_STATE_RUNNING:
		if r.snap.StartedAt.IsZero() {
			r.snap.StartedAt = now
		}
		if r.snap.Phase == PhaseQueued {
			r.snap.Phase = PhaseRunning
		}
	case corev1.ExecutionState_EXECUTION_STATE_SUCCEEDED, corev1.ExecutionState_EXECUTION_STATE_FAILED,
		corev1.ExecutionState_EXECUTION_STATE_CANCELLED:
		r.snap.Phase = PhaseFinished
		r.snap.FinishedAt = now
		if e.Message != "" {
			r.snap.Message = strings.ToValidUTF8(e.Message, "\uFFFD")
		}
		cancelled := e.ExecutionState == corev1.ExecutionState_EXECUTION_STATE_CANCELLED
		for i := range r.snap.Jobs {
			job := &r.snap.Jobs[i]
			switch job.State {
			case JobRunning:
				job.FinishedAt = now
				if cancelled {
					job.State = JobCancelled
				} else {
					job.State = JobNotRun
					job.Reason = "act ended before the job reported a result"
				}
			case JobWaiting:
				job.State = JobNotRun
			}
		}
	}
}

// BilledMinutes is what GitHub would have billed for a finished run's jobs:
// each job that ended with a result counts its time rounded up to a whole
// minute, at least one, as GitHub bills hosted runners. It is 0 for a run
// that is unknown or still going.
func (o *Outputs) BilledMinutes(executionID string) int64 {
	o.mu.Lock()
	defer o.mu.Unlock()
	r := o.runs[executionID]
	if r == nil || r.snap.Phase != PhaseFinished {
		return 0
	}
	return billedMinutes(r.snap.Jobs)
}

// LaneSummary is one finished lane, for analytics: its workflow, whether
// every job of it ran, its span and its jobs.
type LaneSummary struct {
	WorkflowID    string
	WholeWorkflow bool
	// Dispatchable: the workflow has a workflow_dispatch trigger, so GitHub
	// can start it by hand.
	Dispatchable bool
	StartedAt    time.Time
	FinishedAt   time.Time
	Jobs         []JobStatus
}

// Summary is a finished run, for analytics: the lanes that ran.
type Summary struct {
	Lanes []LaneSummary
}

// Summary returns a finished run's summary; false while it runs or once it
// was forgotten.
func (o *Outputs) Summary(executionID string) (Summary, bool) {
	o.mu.Lock()
	defer o.mu.Unlock()
	r := o.runs[executionID]
	if r == nil || r.snap.Phase != PhaseFinished {
		return Summary{}, false
	}
	var summary Summary
	for _, lane := range r.snap.Plan.Selected() {
		times, ran := r.lanes[lane.WorkflowID]
		if !ran {
			continue
		}
		whole := true
		for _, job := range lane.Jobs {
			whole = whole && job.Selected
		}
		ls := LaneSummary{WorkflowID: lane.WorkflowID, WholeWorkflow: whole, Dispatchable: lane.Dispatchable,
			StartedAt: times.started, FinishedAt: times.finished}
		for _, job := range r.snap.Jobs {
			if job.Workflow == lane.WorkflowID {
				ls.Jobs = append(ls.Jobs, job)
			}
		}
		summary.Lanes = append(summary.Lanes, ls)
	}
	return summary, true
}

// startLane records that act started on a lane: its output and jobs are
// the lane's from now on.
// A lane that runs as several acts (Parts) keeps its first start.
func (o *Outputs) startLane(executionID, workflow string, now time.Time) {
	o.update(executionID, func(r *run) {
		r.lane = workflow
		if _, ok := r.lanes[workflow]; !ok {
			r.lanes[workflow] = laneTimes{started: now}
		}
	})
}

// jobStates are the states of a lane's jobs, by lower-cased id.
func (o *Outputs) jobStates(executionID, workflow string) map[string]JobState {
	states := map[string]JobState{}
	o.update(executionID, func(r *run) {
		for _, job := range r.snap.Jobs {
			if job.Workflow == workflow {
				states[strings.ToLower(job.ID)] = job.State
			}
		}
	})
	return states
}

// skipJobs records waiting jobs of a lane that do not run, with the reason
// for each, by lower-cased id.
func (o *Outputs) skipJobs(executionID, workflow string, reasons map[string]string) {
	if len(reasons) == 0 {
		return
	}
	o.update(executionID, func(r *run) {
		for i := range r.snap.Jobs {
			job := &r.snap.Jobs[i]
			if reason := reasons[strings.ToLower(job.ID)]; reason != "" && job.Workflow == workflow && job.State == JobWaiting {
				job.State, job.Reason = JobNotRun, reason
			}
		}
	})
}

// finishLane records that a lane's act exited. Jobs that never reported a
// result did not run.
func (o *Outputs) finishLane(executionID, workflow string, now time.Time) {
	o.update(executionID, func(r *run) {
		if times, ok := r.lanes[workflow]; ok {
			times.finished = now
			r.lanes[workflow] = times
		}
		for i := range r.snap.Jobs {
			job := &r.snap.Jobs[i]
			if job.Workflow != workflow {
				continue
			}
			switch job.State {
			case JobRunning:
				job.FinishedAt = now
				if r.snap.Phase == PhaseStopping {
					job.State = JobCancelled
				} else {
					job.State, job.Reason = JobNotRun, "act ended before the job reported a result"
				}
			case JobWaiting:
				job.State = JobNotRun
			}
		}
	})
}

// skipLane records a lane that does not run, with the reason.
func (o *Outputs) skipLane(executionID, workflow, reason string) {
	o.update(executionID, func(r *run) {
		for i := range r.snap.Jobs {
			if job := &r.snap.Jobs[i]; job.Workflow == workflow && job.State == JobWaiting {
				job.State, job.Reason = JobNotRun, reason
			}
		}
	})
}

// BilledJobMinutes is how GitHub bills a job on a hosted runner: its time
// rounded up to a whole minute, at least one.
func BilledJobMinutes(d time.Duration) int64 {
	return max(int64((max(d, 0)+time.Minute-1)/time.Minute), 1)
}

func billedMinutes(jobs []JobStatus) int64 {
	var total int64
	for _, job := range jobs {
		if (job.State != JobSucceeded && job.State != JobFailed) || job.StartedAt.IsZero() || job.FinishedAt.IsZero() {
			continue
		}
		total += BilledJobMinutes(job.FinishedAt.Sub(job.StartedAt))
	}
	return total
}

// MarkStartedBy keeps the MCP client that started a run.
func (o *Outputs) MarkStartedBy(executionID, client string) {
	o.update(executionID, func(r *run) { r.snap.StartedBy = client })
}

// Recent returns the runs of a repository the Core still holds, newest
// first, without their lines.
func (o *Outputs) Recent(repositoryID string) []Snapshot {
	o.mu.Lock()
	defer o.mu.Unlock()
	var out []Snapshot
	for i := len(o.order) - 1; i >= 0; i-- {
		r := o.runs[o.order[i]]
		if r == nil || r.snap.RepositoryID != repositoryID {
			continue
		}
		snap := r.snap
		snap.Jobs = append([]JobStatus(nil), r.snap.Jobs...)
		snap.LastSequence = r.next
		out = append(out, snap)
	}
	return out
}

// Since returns the lines after a sequence number and the run's state.
func (o *Outputs) Since(executionID string, after uint64) (Snapshot, bool) {
	o.mu.Lock()
	defer o.mu.Unlock()
	r := o.runs[executionID]
	if r == nil {
		return Snapshot{}, false
	}
	snap := r.snap
	snap.Jobs = append([]JobStatus(nil), r.snap.Jobs...)
	snap.LastSequence = r.next
	for source, output := range r.outputs {
		if output.dropped > after {
			snap.Discarded = true
			snap.DiscardedJobs = append(snap.DiscardedJobs, source)
		}
		snap.Lines = output.since(after, snap.Lines)
	}
	sort.Slice(snap.Lines, func(i, j int) bool { return snap.Lines[i].Sequence < snap.Lines[j].Sequence })
	sort.Slice(snap.DiscardedJobs, func(i, j int) bool {
		a, b := snap.DiscardedJobs[i], snap.DiscardedJobs[j]
		return a.Workflow < b.Workflow || (a.Workflow == b.Workflow && a.JobID < b.JobID)
	})
	return snap, true
}

// LineSource is the job a line is from: its workflow and its id, empty for
// act's own messages of that workflow.
type LineSource struct {
	Workflow string
	JobID    string
}

// ring keeps the newest MaxLines lines of one job.
type ring struct {
	lines []Line
	// head is the oldest line once the ring is full.
	head int
	// dropped is the sequence of the newest line no longer kept.
	dropped uint64
}

func (b *ring) add(line Line) {
	if len(b.lines) < MaxLines {
		b.lines = append(b.lines, line)
		return
	}
	b.dropped = b.lines[b.head].Sequence
	b.lines[b.head] = line
	b.head = (b.head + 1) % MaxLines
}

// since appends the lines after a sequence number, oldest first.
func (b *ring) since(after uint64, out []Line) []Line {
	n := len(b.lines)
	at := func(i int) Line { return b.lines[(b.head+i)%n] }
	for i := sort.Search(n, func(i int) bool { return at(i).Sequence > after }); i < n; i++ {
		out = append(out, at(i))
	}
	return out
}

func (o *Outputs) update(executionID string, change func(*run)) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if r := o.runs[executionID]; r != nil {
		change(r)
	}
}

func (r *run) append(jobID, text string, isError bool) {
	workflow := r.lane
	// Every line goes out in a protobuf string, which must be UTF-8: one
	// broken line would keep the run's output from being read at all.
	text = strings.ToValidUTF8(mask(text, r.masks), "\uFFFD")
	if len(text) > MaxLineBytes {
		cut := MaxLineBytes
		for cut > 0 && !utf8Start(text[cut]) {
			cut--
		}
		text = text[:cut] + " …"
	}
	r.next++
	source := LineSource{Workflow: workflow, JobID: jobID}
	output := r.outputs[source]
	if output == nil {
		output = &ring{}
		if r.outputs == nil {
			r.outputs = map[LineSource]*ring{}
		}
		r.outputs[source] = output
	}
	output.add(Line{Sequence: r.next, Workflow: workflow, JobID: jobID, Text: text, Error: isError})
}

func utf8Start(b byte) bool { return b&0xC0 != 0x80 }

// job is the running lane's job with this id, added when act reports one
// the plan did not list.
func (r *run) job(id string) *JobStatus {
	for i := range r.snap.Jobs {
		if r.snap.Jobs[i].Workflow == r.lane && strings.EqualFold(r.snap.Jobs[i].ID, id) {
			return &r.snap.Jobs[i]
		}
	}
	r.snap.Jobs = append(r.snap.Jobs, JobStatus{Workflow: r.lane, ID: id, State: JobWaiting})
	return &r.snap.Jobs[len(r.snap.Jobs)-1]
}

var ansi = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07`)

// actEntry is the part of act's --json log entries Runnir reads. Unknown
// fields are ignored and lines that are not JSON are shown as they are, so
// a change in act's format degrades job states, not the run.
type actEntry struct {
	Message   string `json:"msg"`
	Level     string `json:"level"`
	Job       string `json:"job"`
	JobID     string `json:"jobID"`
	RawOutput bool   `json:"raw_output"`
	JobResult string `json:"jobResult"`
}

// consume records one line act wrote.
func (r *run) consume(raw string, now time.Time, stderr bool) {
	raw = strings.TrimRight(raw, "\r\n")
	if raw == "" {
		return
	}
	var entry actEntry
	if !strings.HasPrefix(raw, "{") || json.Unmarshal([]byte(raw), &entry) != nil {
		// act writes notices to standard error too ("Using docker host
		// ..."); only lines that say so are errors.
		text := ansi.ReplaceAllString(raw, "")
		isError := stderr && (strings.HasPrefix(text, "Error") || strings.Contains(text, "level=error") || strings.Contains(text, "level=fatal"))
		r.append("", text, isError)
		return
	}
	message := strings.TrimRight(ansi.ReplaceAllString(entry.Message, ""), "\r\n")
	isError := entry.Level == "error" || entry.Level == "fatal"
	if entry.JobID == "" {
		for _, text := range strings.Split(message, "\n") {
			r.append("", text, isError)
		}
		return
	}
	job := r.job(entry.JobID)
	if job.State == JobWaiting {
		job.State = JobRunning
		job.StartedAt = now
	}
	switch {
	case entry.JobResult == "success":
		job.State, job.FinishedAt = JobSucceeded, now
	case entry.JobResult != "" && r.snap.Phase == PhaseStopping:
		// act reports a job it was asked to stop as failed.
		job.State, job.FinishedAt = JobCancelled, now
	case entry.JobResult != "":
		job.State, job.FinishedAt = JobFailed, now
	case strings.Contains(message, "Skipping unsupported platform"):
		job.State, job.FinishedAt = JobSkipped, now
		job.Reason = "No local image for this runner"
	}
	prefix := "[" + entry.Job + "] "
	if entry.Job == "" {
		prefix = "[" + entry.JobID + "] "
	}
	if entry.RawOutput {
		prefix += "  | "
	}
	for _, text := range strings.Split(message, "\n") {
		r.append(job.ID, prefix+strings.TrimRight(text, "\r"), isError)
	}
}
