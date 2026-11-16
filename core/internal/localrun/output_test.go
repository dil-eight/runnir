package localrun

import (
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"runnir/core/internal/events"
	corev1 "runnir/core/internal/gen/runnir/core/v1"

	"google.golang.org/protobuf/proto"
)

// onePlan is a run of one lane, ci.yml, with every job given ticked.
func onePlan(jobs ...JobPlan) Plan {
	for i := range jobs {
		jobs[i].Selected = true
	}
	return Plan{Lanes: []Lane{{WorkflowID: "ci.yml", Kind: Direct, Event: "push", Dispatchable: true, Jobs: jobs}}}
}

// newRun creates a run of ci.yml's lint and test, its lane started.
func newRun(o *Outputs, id string) {
	o.Create(id, "repo", onePlan(JobPlan{ID: "lint", Support: Supported}, JobPlan{ID: "test", Support: Supported}), "0.2.89", false, "OrbStack")
	o.startLane(id, "ci.yml", time.Now())
}

func TestOutputKeepsTheNewestLines(t *testing.T) {
	o := NewOutputs()
	newRun(o, "e1")
	o.update("e1", func(r *run) {
		for i := 1; i <= MaxLines+10; i++ {
			r.consume(fmt.Sprintf("line %d", i), time.Now(), false)
		}
	})
	snap, ok := o.Since("e1", 0)
	if !ok || len(snap.Lines) != MaxLines || !snap.Discarded || snap.LastSequence != MaxLines+10 {
		t.Fatalf("lines=%d discarded=%v last=%d", len(snap.Lines), snap.Discarded, snap.LastSequence)
	}
	if snap.Lines[0].Text != "line 11" || snap.Lines[MaxLines-1].Text != fmt.Sprintf("line %d", MaxLines+10) {
		t.Fatalf("first=%q last=%q", snap.Lines[0].Text, snap.Lines[MaxLines-1].Text)
	}
	later, _ := o.Since("e1", MaxLines+5)
	if len(later.Lines) != 5 || later.Discarded {
		t.Fatalf("incremental read = %d lines, discarded %v", len(later.Lines), later.Discarded)
	}
}

// A job that writes a lot, such as a matrix of builds, keeps its own newest
// lines and never pushes out the output of a job that ended before.
func TestEachJobKeepsItsOwnNewestLines(t *testing.T) {
	o := NewOutputs()
	newRun(o, "e1")
	o.update("e1", func(r *run) {
		for i := 1; i <= 3; i++ {
			r.consume(fmt.Sprintf(`{"jobID":"lint","job":"CI/lint","msg":"lint %d"}`, i), time.Now(), false)
		}
		for i := 1; i <= MaxLines+10; i++ {
			r.consume(fmt.Sprintf(`{"jobID":"test","job":"CI/test","msg":"test %d"}`, i), time.Now(), false)
		}
	})
	snap, _ := o.Since("e1", 0)
	if len(snap.Lines) != MaxLines+3 || !snap.Discarded || !slices.Equal(snap.DiscardedJobs, []LineSource{{Workflow: "ci.yml", JobID: "test"}}) {
		t.Fatalf("lines=%d discarded=%v jobs=%v", len(snap.Lines), snap.Discarded, snap.DiscardedJobs)
	}
	var lint []string
	for i, line := range snap.Lines {
		if i > 0 && line.Sequence <= snap.Lines[i-1].Sequence {
			t.Fatalf("line %d is out of order", i)
		}
		if line.JobID == "lint" {
			lint = append(lint, line.Text)
		}
	}
	if strings.Join(lint, ",") != "[CI/lint] lint 1,[CI/lint] lint 2,[CI/lint] lint 3" {
		t.Fatalf("lint lines = %q", lint)
	}
	// Only the noisy job's lines were dropped: reading after them loses nothing.
	later, _ := o.Since("e1", 3+10)
	if len(later.Lines) != MaxLines || later.Discarded || later.DiscardedJobs != nil {
		t.Fatalf("after the dropped lines = %d lines, discarded %v %v", len(later.Lines), later.Discarded, later.DiscardedJobs)
	}
}

// The Core says whose lines were dropped after the sequence asked, so a job
// that lost nothing is not said to: act's own messages count as a job with
// no id, and a job of another workflow with the same id is another job.
func TestDroppedLinesNameTheirJobs(t *testing.T) {
	o := NewOutputs()
	newRun(o, "e1")
	o.update("e1", func(r *run) {
		// act's own messages: 1 to MaxLines+2, the first 2 dropped.
		for i := 1; i <= MaxLines+2; i++ {
			r.consume(fmt.Sprintf("act %d", i), time.Now(), false)
		}
		// test: the next MaxLines+5, the first 5 dropped.
		for i := 1; i <= MaxLines+5; i++ {
			r.consume(fmt.Sprintf(`{"jobID":"test","job":"CI/test","msg":"test %d"}`, i), time.Now(), false)
		}
		r.consume(`{"jobID":"lint","job":"CI/lint","msg":"lint"}`, time.Now(), false)
	})
	o.startLane("e1", "release.yml", time.Now())
	o.update("e1", func(r *run) {
		r.consume(`{"jobID":"test","job":"Release/test","msg":"test"}`, time.Now(), false)
	})
	act, test := LineSource{Workflow: "ci.yml"}, LineSource{Workflow: "ci.yml", JobID: "test"}
	for _, c := range []struct {
		after uint64
		want  []LineSource
	}{
		{0, []LineSource{act, test}},
		{1, []LineSource{act, test}},
		{2, []LineSource{test}},
		{MaxLines + 6, []LineSource{test}},
		{MaxLines + 7, nil},
	} {
		snap, _ := o.Since("e1", c.after)
		if snap.Discarded != (c.want != nil) || !slices.Equal(snap.DiscardedJobs, c.want) {
			t.Fatalf("after %d: discarded %v, jobs %v; want %v", c.after, snap.Discarded, snap.DiscardedJobs, c.want)
		}
	}
}

func TestLongLinesAreCutOnACharacterBoundary(t *testing.T) {
	o := NewOutputs()
	newRun(o, "e1")
	o.update("e1", func(r *run) { r.consume(strings.Repeat("é", MaxLineBytes), time.Now(), false) })
	snap, _ := o.Since("e1", 0)
	text := snap.Lines[0].Text
	if len(text) > MaxLineBytes+4 || !strings.HasSuffix(text, " …") || !strings.HasPrefix(text, "éé") {
		t.Fatalf("len=%d suffix=%q", len(text), text[len(text)-6:])
	}
	if !strings.Contains(text, "é …") {
		t.Fatal("cut inside a character")
	}
}

// A line or a message that is not UTF-8 would make every later read of the
// run fail to marshal, so the app could never learn that it finished.
func TestOutputIsAlwaysValidUTF8(t *testing.T) {
	o := NewOutputs()
	newRun(o, "e1")
	o.update("e1", func(r *run) { r.consume("act \xe2\x9c said", time.Now(), true) })
	o.Observe(events.Event{ExecutionID: "e1", ExecutionState: corev1.ExecutionState_EXECUTION_STATE_FAILED, Message: "failed \xff"})
	snap, _ := o.Since("e1", 0)
	if snap.Lines[0].Text != "act � said" || snap.Message != "failed �" {
		t.Fatalf("line = %q, message = %q", snap.Lines[0].Text, snap.Message)
	}
	if _, err := proto.Marshal(&corev1.LocalRunLine{Text: snap.Lines[0].Text}); err != nil {
		t.Fatal(err)
	}
}

func TestFinishedRunMarksJobsThatNeverEnded(t *testing.T) {
	o := NewOutputs()
	newRun(o, "e1")
	o.Observe(events.Event{ExecutionID: "e1", ExecutionState: corev1.ExecutionState_EXECUTION_STATE_RUNNING})
	o.update("e1", func(r *run) { r.consume(`{"jobID":"lint","job":"CI/lint","msg":"start"}`, time.Now(), false) })
	o.Observe(events.Event{ExecutionID: "e1", ExecutionState: corev1.ExecutionState_EXECUTION_STATE_CANCELLED})
	snap, _ := o.Since("e1", 0)
	if snap.Phase != PhaseFinished || snap.State != corev1.ExecutionState_EXECUTION_STATE_CANCELLED || snap.StartedAt.IsZero() || snap.FinishedAt.IsZero() {
		t.Fatalf("snap = %+v", snap)
	}
	if snap.Jobs[0].State != JobCancelled || snap.Jobs[1].State != JobNotRun {
		t.Fatalf("jobs = %+v", snap.Jobs)
	}
}

func TestSkippedPlatformAndUnknownJobs(t *testing.T) {
	o := NewOutputs()
	newRun(o, "e1")
	o.update("e1", func(r *run) {
		r.consume(`{"jobID":"test","job":"CI/test","msg":"🚧  Skipping unsupported platform -- Try running with `+"`-P macos-latest=...`"+`"}`, time.Now(), false)
		r.consume(`{"jobID":"called","job":"CI/called","msg":"hello"}`, time.Now(), false)
		r.consume(`{"level":"error","msg":"Error: boom"}`, time.Now(), true)
		r.consume(`{"msg": 5}`, time.Now(), false)
	})
	snap, _ := o.Since("e1", 0)
	if snap.Jobs[1].State != JobSkipped || len(snap.Jobs) != 3 || snap.Jobs[2].ID != "called" || snap.Jobs[2].State != JobRunning {
		t.Fatalf("jobs = %+v", snap.Jobs)
	}
	if !snap.Lines[2].Error || snap.Lines[2].Text != "Error: boom" {
		t.Fatalf("error line = %+v", snap.Lines[2])
	}
	if snap.Lines[3].Text != `{"msg": 5}` {
		t.Fatalf("unreadable JSON line = %+v", snap.Lines[3])
	}
}

func TestOnlyRecentFinishedRunsAreKept(t *testing.T) {
	o := NewOutputs()
	newRun(o, "running")
	for i := 0; i < MaxRuns+5; i++ {
		id := fmt.Sprintf("e%d", i)
		newRun(o, id)
		o.Observe(events.Event{ExecutionID: id, ExecutionState: corev1.ExecutionState_EXECUTION_STATE_SUCCEEDED})
	}
	if _, ok := o.Since("running", 0); !ok {
		t.Fatal("a running run was forgotten")
	}
	o.Remove("e3")
	if _, ok := o.Since("e3", 0); ok {
		t.Fatal("Remove kept the run")
	}
}

func TestJobsStoppedOnRequestAreCancelledNotFailed(t *testing.T) {
	o := NewOutputs()
	newRun(o, "e1")
	o.update("e1", func(r *run) {
		r.consume(`{"jobID":"lint","job":"CI/lint","msg":"start"}`, time.Now(), false)
		r.snap.Phase = PhaseStopping
		r.consume(`{"jobID":"lint","job":"CI/lint","jobResult":"failure","msg":"Job failed"}`, time.Now(), false)
	})
	if snap, _ := o.Since("e1", 0); snap.Jobs[0].State != JobCancelled {
		t.Fatalf("jobs = %+v", snap.Jobs)
	}
}

func TestOnlyErrorLinesOnStandardErrorAreErrors(t *testing.T) {
	o := NewOutputs()
	newRun(o, "e1")
	o.update("e1", func(r *run) {
		r.consume("Using docker host 'unix:///var/run/docker.sock', and daemon socket '-'", time.Now(), true)
		r.consume("Error: Job 'lint' failed", time.Now(), true)
		r.consume(`time="2026-10-20" level=error msg="boom"`, time.Now(), true)
	})
	snap, _ := o.Since("e1", 0)
	if snap.Lines[0].Error || !snap.Lines[1].Error || !snap.Lines[2].Error {
		t.Fatalf("lines = %+v", snap.Lines)
	}
}

func TestBilledMinutesRoundEachJobUp(t *testing.T) {
	o := NewOutputs()
	o.Create("e1", "repo", onePlan(JobPlan{ID: "lint", Support: Supported}, JobPlan{ID: "test", Support: Supported},
		JobPlan{ID: "quick", Support: Supported}, JobPlan{ID: "macos", Support: Unsupported}, JobPlan{ID: "never", Support: Supported}), "0.2.89", false, "OrbStack")
	o.startLane("e1", "ci.yml", time.Now())
	start := time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)
	o.Observe(events.Event{ExecutionID: "e1", ExecutionState: corev1.ExecutionState_EXECUTION_STATE_RUNNING})
	o.update("e1", func(r *run) {
		r.consume(`{"jobID":"lint","msg":"start"}`, start, false)
		r.consume(`{"jobID":"test","msg":"start"}`, start, false)
		r.consume(`{"jobID":"quick","msg":"start"}`, start, false)
		r.consume(`{"jobID":"lint","jobResult":"success","msg":"done"}`, start.Add(61*time.Second), false)
		r.consume(`{"jobID":"test","jobResult":"failure","msg":"done"}`, start.Add(3*time.Minute), false)
		r.consume(`{"jobID":"quick","jobResult":"success","msg":"done"}`, start, false)
	})
	if got := o.BilledMinutes("e1"); got != 0 {
		t.Fatalf("a run still going counted %d", got)
	}
	o.Observe(events.Event{ExecutionID: "e1", ExecutionState: corev1.ExecutionState_EXECUTION_STATE_FAILED})
	// lint 1m 1s → 2, test 3m → 3, quick → at least 1; macos and never did not run.
	if got := o.BilledMinutes("e1"); got != 6 {
		t.Fatalf("billed = %d, want 6", got)
	}
	if got := o.BilledMinutes("unknown"); got != 0 {
		t.Fatalf("unknown run billed %d", got)
	}
}

func TestSummaryOfAFinishedRun(t *testing.T) {
	o := NewOutputs()
	plan := onePlan(JobPlan{ID: "lint", Name: "Lint", Support: Supported})
	plan.Lanes = append(plan.Lanes,
		Lane{WorkflowID: "core.yml", Kind: Direct, Event: "push", Jobs: []JobPlan{{ID: "lint", Name: "Lint", Support: Supported, Selected: true}, {ID: "slow", Support: Supported}}},
		Lane{WorkflowID: "notify.yml", Kind: Chained, Event: "workflow_run", After: "core.yml", Jobs: []JobPlan{{ID: "tell", Support: Supported, Selected: true}}})
	o.Create("e1", "repo", plan, "0.2.89", false, "OrbStack")
	start := time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)
	o.Observe(events.Event{ExecutionID: "e1", ExecutionState: corev1.ExecutionState_EXECUTION_STATE_RUNNING})
	o.startLane("e1", "ci.yml", start)
	o.update("e1", func(r *run) {
		r.consume(`{"jobID":"lint","msg":"start"}`, start, false)
		r.consume(`{"jobID":"lint","jobResult":"success","msg":"done"}`, start.Add(90*time.Second), false)
	})
	o.finishLane("e1", "ci.yml", start.Add(95*time.Second))
	o.startLane("e1", "core.yml", start.Add(100*time.Second))
	o.update("e1", func(r *run) {
		r.consume(`{"jobID":"lint","msg":"start"}`, start.Add(100*time.Second), false)
		r.consume(`{"jobID":"lint","jobResult":"failure","msg":"done"}`, start.Add(130*time.Second), false)
	})
	o.finishLane("e1", "core.yml", start.Add(130*time.Second))
	o.skipLane("e1", "notify.yml", "Not run: core.yml did not succeed")
	if _, ok := o.Summary("e1"); ok {
		t.Fatal("a run still going has a summary")
	}
	o.Observe(events.Event{ExecutionID: "e1", ExecutionState: corev1.ExecutionState_EXECUTION_STATE_FAILED})
	s, ok := o.Summary("e1")
	if !ok || len(s.Lanes) != 2 {
		t.Fatalf("summary = %+v, %v", s, ok)
	}
	ci, core := s.Lanes[0], s.Lanes[1]
	if ci.WorkflowID != "ci.yml" || !ci.WholeWorkflow || !ci.Dispatchable || len(ci.Jobs) != 1 || ci.Jobs[0].State != JobSucceeded ||
		ci.FinishedAt.Sub(ci.StartedAt) != 95*time.Second {
		t.Fatalf("ci = %+v", ci)
	}
	// Jobs of the same id in two workflows are told apart.
	if core.WorkflowID != "core.yml" || core.WholeWorkflow || core.Jobs[0].State != JobFailed {
		t.Fatalf("core = %+v", core)
	}
	snap, _ := o.Since("e1", 0)
	if snap.Jobs[2].Workflow != "notify.yml" || snap.Jobs[2].State != JobNotRun || snap.Jobs[2].Reason != "Not run: core.yml did not succeed" {
		t.Fatalf("notify = %+v", snap.Jobs[2])
	}
	if snap.Lines[0].Workflow != "ci.yml" || snap.Lines[2].Workflow != "core.yml" {
		t.Fatalf("lines = %+v", snap.Lines)
	}
	if BilledJobMinutes(90*time.Second) != 2 || BilledJobMinutes(0) != 1 || BilledJobMinutes(time.Minute) != 1 {
		t.Fatal("billed job minutes do not round up to at least one")
	}
}

// An agent's run keeps the agent's name, and Recent lists a repository's
// runs newest first without their lines.
func TestRecentRunsKeepWhoStartedThem(t *testing.T) {
	o := NewOutputs()
	newRun(o, "e1")
	newRun(o, "e2")
	o.Create("e3", "other", onePlan(JobPlan{ID: "lint", Support: Supported}), "0.2.89", false, "OrbStack")
	o.MarkStartedBy("e2", "claude-code")
	o.update("e1", func(r *run) { r.consume("line", time.Now(), false) })
	recent := o.Recent("repo")
	if len(recent) != 2 || recent[0].ExecutionID != "e2" || recent[1].ExecutionID != "e1" {
		t.Fatalf("recent = %+v", recent)
	}
	if recent[0].StartedBy != "claude-code" || recent[1].StartedBy != "" || len(recent[1].Lines) != 0 || recent[1].LastSequence == 0 {
		t.Fatalf("recent = %+v", recent)
	}
	if snap, _ := o.Since("e2", 0); snap.StartedBy != "claude-code" {
		t.Fatalf("since = %+v", snap)
	}
}
