package execution

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"runnir/core/internal/events"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/repository"
)

type eventLog struct {
	mu     sync.Mutex
	events []events.Event
}

func (l *eventLog) publish(e events.Event) {
	l.mu.Lock()
	l.events = append(l.events, e)
	l.mu.Unlock()
}

func (l *eventLog) forExecution(id string) []corev1.CoreEventType {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []corev1.CoreEventType
	for _, e := range l.events {
		if e.ExecutionID == id {
			out = append(out, e.Type)
		}
	}
	return out
}

func (l *eventLog) startedOrder() []string {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []string
	for _, e := range l.events {
		if e.Type == started {
			out = append(out, e.ExecutionID)
		}
	}
	return out
}

func (l *eventLog) last(id string) events.Event {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out events.Event
	for _, e := range l.events {
		if e.ExecutionID == id {
			out = e
		}
	}
	return out
}

const (
	started   = corev1.CoreEventType_CORE_EVENT_TYPE_WORKFLOW_STARTED
	changed   = corev1.CoreEventType_CORE_EVENT_TYPE_WORKFLOW_STATUS_CHANGED
	completed = corev1.CoreEventType_CORE_EVENT_TYPE_WORKFLOW_COMPLETED
	failed    = corev1.CoreEventType_CORE_EVENT_TYPE_WORKFLOW_FAILED
)

// gateRunner blocks every job until released or cancelled, recording order.
type gateRunner struct {
	mu       sync.Mutex
	order    []string
	jobs     map[string]Job
	gates    map[string]chan struct{}
	running  atomic.Int32
	peak     atomic.Int32
	failWith error
}

func newGateRunner() *gateRunner {
	return &gateRunner{jobs: map[string]Job{}, gates: map[string]chan struct{}{}}
}

func (r *gateRunner) gate(id string) chan struct{} {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.gates[id] == nil {
		r.gates[id] = make(chan struct{})
	}
	return r.gates[id]
}

func (r *gateRunner) release(id string) { close(r.gate(id)) }

func (r *gateRunner) Run(ctx context.Context, job Job) error {
	n := r.running.Add(1)
	defer r.running.Add(-1)
	for {
		p := r.peak.Load()
		if n <= p || r.peak.CompareAndSwap(p, n) {
			break
		}
	}
	r.mu.Lock()
	r.order = append(r.order, job.ExecutionID)
	r.jobs[job.ExecutionID] = job
	r.mu.Unlock()
	select {
	case <-r.gate(job.ExecutionID):
		return r.failWith
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (r *gateRunner) started() []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return append([]string(nil), r.order...)
}

func waitFor(t *testing.T, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(time.Millisecond)
	}
}

func workflow(id string) repository.Workflow {
	return repository.Workflow{ID: id, Name: id, Triggers: []string{"push"}, Jobs: []repository.Job{{ID: "build", Needs: []string{"x"}}}}
}

func newCoordinator(t *testing.T, runner Runner, limit, queue int) (*Coordinator, *eventLog) {
	t.Helper()
	log := &eventLog{}
	c := New(runner, Options{Limit: limit, QueueLimit: queue}, log.publish)
	t.Cleanup(func() { c.Shutdown(context.Background()) })
	return c, log
}

func start(t *testing.T, c *Coordinator, repo string) Execution {
	t.Helper()
	e, err := c.Start(repo, "/tmp/"+repo, workflow(".github/workflows/ci.yml"), "main")
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func TestRunsAtMostLimitAndQueuesTheRestFIFO(t *testing.T) {
	runner := newGateRunner()
	c, log := newCoordinator(t, runner, 3, 10)

	var ids []string
	for i := 0; i < 6; i++ {
		e := start(t, c, "repo")
		wantState := corev1.ExecutionState_EXECUTION_STATE_RUNNING
		if i >= 3 {
			wantState = corev1.ExecutionState_EXECUTION_STATE_QUEUED
		}
		if e.State != wantState {
			t.Fatalf("execution %d state = %v, want %v", i, e.State, wantState)
		}
		ids = append(ids, e.ID)
	}
	waitFor(t, "three running", func() bool { return len(runner.started()) == 3 })
	if c.Running() != 3 || c.Queued() != 3 {
		t.Fatalf("running=%d queued=%d", c.Running(), c.Queued())
	}

	// Finishing one starts the oldest queued execution, never a newer one.
	runner.release(ids[0])
	waitFor(t, "fourth start", func() bool { return len(runner.started()) == 4 })
	if got := log.startedOrder()[3]; got != ids[3] {
		t.Fatalf("started %s next, want %s (FIFO)", got, ids[3])
	}
	runner.release(ids[1])
	runner.release(ids[2])
	waitFor(t, "sixth start", func() bool { return len(runner.started()) == 6 })
	// STARTED events are published under the coordinator lock, so they give
	// the dispatch order; runner goroutines may record theirs in any order.
	if got := log.startedOrder(); len(got) != 6 {
		t.Fatalf("started %v", got)
	} else {
		for i := range ids {
			if got[i] != ids[i] {
				t.Fatalf("dispatch order %v, want %v (FIFO)", got, ids)
			}
		}
	}
	for _, id := range ids[3:] {
		runner.release(id)
	}
	waitFor(t, "drain", func() bool { return c.Running() == 0 && c.Queued() == 0 })
	if runner.peak.Load() > 3 {
		t.Fatalf("peak concurrency %d exceeds limit", runner.peak.Load())
	}

	want := []corev1.CoreEventType{changed, started, completed}
	got := log.forExecution(ids[5])
	if len(got) != 3 || got[0] != want[0] || got[1] != want[1] || got[2] != want[2] {
		t.Fatalf("queued execution events = %v, want %v", got, want)
	}
	if got := log.forExecution(ids[0]); len(got) != 2 || got[0] != started || got[1] != completed {
		t.Fatalf("immediate execution events = %v", got)
	}
}

func TestCancelQueuedExecutionNeverRuns(t *testing.T) {
	runner := newGateRunner()
	c, log := newCoordinator(t, runner, 1, 10)
	first := start(t, c, "repo")
	second := start(t, c, "repo")
	third := start(t, c, "repo")

	if err := c.Cancel(second.ID); err != nil {
		t.Fatal(err)
	}
	if c.Queued() != 1 {
		t.Fatalf("queued = %d", c.Queued())
	}
	last := log.last(second.ID)
	if last.Type != changed || last.ExecutionState != corev1.ExecutionState_EXECUTION_STATE_CANCELLED {
		t.Fatalf("event = %+v", last)
	}
	runner.release(first.ID)
	waitFor(t, "third start", func() bool { return len(runner.started()) == 2 })
	if runner.started()[1] != third.ID {
		t.Fatalf("started %v; cancelled execution must be skipped", runner.started())
	}
	runner.release(third.ID)
	if err := c.Cancel(second.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("second cancel = %v, want ErrNotFound", err)
	}
}

func TestCancelRunningFreesTheSlot(t *testing.T) {
	runner := newGateRunner()
	c, log := newCoordinator(t, runner, 1, 10)
	first := start(t, c, "repo")
	second := start(t, c, "repo")
	waitFor(t, "first running", func() bool { return len(runner.started()) == 1 })

	if err := c.Cancel(first.ID); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "second starts", func() bool { return len(runner.started()) == 2 })
	waitFor(t, "cancel recorded", func() bool {
		return log.last(first.ID).ExecutionState == corev1.ExecutionState_EXECUTION_STATE_CANCELLED
	})
	runner.release(second.ID)
	waitFor(t, "drain", func() bool { return c.Running() == 0 })
}

func TestCancelRepositoryAffectsOnlyThatRepository(t *testing.T) {
	runner := newGateRunner()
	c, _ := newCoordinator(t, runner, 2, 10)
	a1 := start(t, c, "a")
	b1 := start(t, c, "b")
	a2 := start(t, c, "a") // queued
	b2 := start(t, c, "b") // queued
	waitFor(t, "two running", func() bool { return len(runner.started()) == 2 })

	c.CancelRepository("a")
	waitFor(t, "b2 takes the freed slot", func() bool { return len(runner.started()) == 3 })
	if got := runner.started()[2]; got != b2.ID {
		t.Fatalf("started %s, want %s", got, b2.ID)
	}
	if err := c.Cancel(a2.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("a2 should already be gone: %v", err)
	}
	_ = a1
	runner.release(b1.ID)
	runner.release(b2.ID)
	waitFor(t, "drain", func() bool { return c.Running() == 0 && c.Queued() == 0 })
}

func TestQueueIsBounded(t *testing.T) {
	runner := newGateRunner()
	c, _ := newCoordinator(t, runner, 1, 2)
	start(t, c, "r") // running
	start(t, c, "r") // queued
	start(t, c, "r") // queued
	if _, err := c.Start("r", "/tmp/r", workflow("w"), ""); !errors.Is(err, ErrQueueFull) {
		t.Fatalf("err = %v, want ErrQueueFull", err)
	}
	if c.Queued() != 2 {
		t.Fatalf("queued = %d", c.Queued())
	}
}

func TestOutcomeEvents(t *testing.T) {
	runner := newGateRunner()
	runner.failWith = errors.New("boom")
	c, log := newCoordinator(t, runner, 3, 10)
	e := start(t, c, "r")
	runner.release(e.ID)
	waitFor(t, "failure", func() bool { return log.last(e.ID).Type == failed })
	if log.last(e.ID).ExecutionState != corev1.ExecutionState_EXECUTION_STATE_FAILED || log.last(e.ID).Message != "boom" {
		t.Fatalf("event = %+v", log.last(e.ID))
	}

	ok := newGateRunner()
	c2, log2 := newCoordinator(t, ok, 3, 10)
	e2 := start(t, c2, "r")
	ok.release(e2.ID)
	waitFor(t, "success", func() bool { return log2.last(e2.ID).Type == completed })
	if log2.last(e2.ID).ExecutionState != corev1.ExecutionState_EXECUTION_STATE_SUCCEEDED {
		t.Fatalf("event = %+v", log2.last(e2.ID))
	}
}

func TestExecutionKeepsItsOwnWorkflowSnapshot(t *testing.T) {
	runner := newGateRunner()
	c, _ := newCoordinator(t, runner, 1, 10)
	w := workflow(".github/workflows/ci.yml")
	e, err := c.Start("r", "/tmp/r", w, "main")
	if err != nil {
		t.Fatal(err)
	}
	// An external edit and refresh replace the caller's data afterwards.
	w.Name = "changed"
	w.Triggers[0] = "schedule"
	w.Jobs[0].ID = "other"
	w.Jobs[0].Needs[0] = "y"

	waitFor(t, "start", func() bool { return len(runner.started()) == 1 })
	runner.mu.Lock()
	job := runner.jobs[e.ID]
	runner.mu.Unlock()
	if job.Workflow.Name != ".github/workflows/ci.yml" || job.Workflow.Triggers[0] != "push" ||
		job.Workflow.Jobs[0].ID != "build" || job.Workflow.Jobs[0].Needs[0] != "x" {
		t.Fatalf("running job saw later edits: %+v", job.Workflow)
	}
	if job.RepositoryID != "r" || job.RepositoryPath != "/tmp/r" || job.Ref != "main" {
		t.Fatalf("job = %+v", job)
	}
	runner.release(e.ID)
}

func TestConcurrentStartsRespectTheLimit(t *testing.T) {
	var peak, running atomic.Int32
	var done atomic.Int32
	runner := RunnerFunc(func(ctx context.Context, job Job) error {
		n := running.Add(1)
		for {
			p := peak.Load()
			if n <= p || peak.CompareAndSwap(p, n) {
				break
			}
		}
		time.Sleep(time.Millisecond)
		running.Add(-1)
		done.Add(1)
		return nil
	})
	c, _ := newCoordinator(t, runner, 3, 1000)
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 10; j++ {
				if _, err := c.Start("r", "/tmp/r", workflow("w"), ""); err != nil {
					t.Error(err)
				}
			}
		}()
	}
	wg.Wait()
	waitFor(t, "all done", func() bool { return done.Load() == 200 })
	waitFor(t, "idle", func() bool { return c.Running() == 0 && c.Queued() == 0 })
	if peak.Load() > 3 {
		t.Fatalf("peak concurrency %d exceeds limit 3", peak.Load())
	}
}

func TestShutdownCancelsEverythingAndRefusesNewWork(t *testing.T) {
	runner := newGateRunner()
	log := &eventLog{}
	c := New(runner, Options{Limit: 1, QueueLimit: 10}, log.publish)
	first := start(t, c, "r")
	second := start(t, c, "r")
	waitFor(t, "running", func() bool { return len(runner.started()) == 1 })

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c.Shutdown(ctx)
	if c.Running() != 0 || c.Queued() != 0 || runner.running.Load() != 0 {
		t.Fatalf("running=%d queued=%d runner=%d", c.Running(), c.Queued(), runner.running.Load())
	}
	for _, id := range []string{first.ID, second.ID} {
		if log.last(id).ExecutionState != corev1.ExecutionState_EXECUTION_STATE_CANCELLED {
			t.Fatalf("%s final event = %+v", id, log.last(id))
		}
	}
	if _, err := c.Start("r", "/tmp/r", workflow("w"), ""); !errors.Is(err, ErrShutdown) {
		t.Fatalf("err = %v, want ErrShutdown", err)
	}
}

func TestStubRunnerFailsHonestly(t *testing.T) {
	log := &eventLog{}
	c := New(StubRunner{}, Options{}, log.publish)
	defer c.Shutdown(context.Background())
	e := start(t, c, "r")
	waitFor(t, "stub failure", func() bool { return log.last(e.ID).Type == failed })
	if log.last(e.ID).Message != ErrEngineUnavailable.Error() {
		t.Fatalf("message = %q", log.last(e.ID).Message)
	}
}
