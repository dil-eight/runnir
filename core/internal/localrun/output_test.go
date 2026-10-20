package localrun

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"runnir/core/internal/events"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func newRun(o *Outputs, id string) {
	o.Create(id, "repo", Plan{Jobs: []JobPlan{{ID: "lint", Support: Supported}, {ID: "test", Support: Supported}}}, "0.2.89", false, "OrbStack")
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
