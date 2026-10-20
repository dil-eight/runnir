package localrun

import (
	"encoding/json"
	"regexp"
	"strings"
	"sync"
	"time"

	"runnir/core/internal/events"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// Output bounds: the newest lines of a run are kept, each cut to a length,
// and only the most recent runs are remembered.
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
	ID         string
	Name       string
	State      JobState
	Reason     string
	StartedAt  time.Time
	FinishedAt time.Time
}

type Line struct {
	Sequence uint64
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
	Discarded      bool // lines after the requested sequence were dropped
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
}

type run struct {
	snap  Snapshot
	lines []Line // ring of at most MaxLines
	head  int
	next  uint64
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
	for _, job := range plan.Jobs {
		status := JobStatus{ID: job.ID, Name: job.Name, State: JobWaiting}
		if job.Support == Unsupported {
			status.State, status.Reason = JobUnsupported, job.Reason
		}
		r.snap.Jobs = append(r.snap.Jobs, status)
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
			r.snap.Message = e.Message
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
	ordered := r.ordered()
	if len(ordered) > 0 && ordered[0].Sequence > after+1 {
		snap.Discarded = true
	}
	for _, line := range ordered {
		if line.Sequence > after {
			snap.Lines = append(snap.Lines, line)
		}
	}
	return snap, true
}

func (r *run) ordered() []Line {
	if len(r.lines) < MaxLines {
		return r.lines
	}
	return append(append([]Line(nil), r.lines[r.head:]...), r.lines[:r.head]...)
}

func (o *Outputs) update(executionID string, change func(*run)) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if r := o.runs[executionID]; r != nil {
		change(r)
	}
}

func (r *run) append(jobID, text string, isError bool) {
	if len(text) > MaxLineBytes {
		cut := MaxLineBytes
		for cut > 0 && !utf8Start(text[cut]) {
			cut--
		}
		text = text[:cut] + " …"
	}
	r.next++
	line := Line{Sequence: r.next, JobID: jobID, Text: text, Error: isError}
	if len(r.lines) < MaxLines {
		r.lines = append(r.lines, line)
		return
	}
	r.lines[r.head] = line
	r.head = (r.head + 1) % MaxLines
}

func utf8Start(b byte) bool { return b&0xC0 != 0x80 }

func (r *run) job(id string) *JobStatus {
	for i := range r.snap.Jobs {
		if strings.EqualFold(r.snap.Jobs[i].ID, id) {
			return &r.snap.Jobs[i]
		}
	}
	r.snap.Jobs = append(r.snap.Jobs, JobStatus{ID: id, State: JobWaiting})
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
