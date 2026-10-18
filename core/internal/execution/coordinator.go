// Package execution schedules workflow runs: at most Limit run at once, the
// rest wait in a bounded FIFO queue. It owns scheduling and lifecycle only;
// a Runner does the work. The MVP ships a stub runner, not an Actions engine.
package execution

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"

	"runnir/core/internal/events"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/repository"
)

const (
	DefaultLimit      = 3
	DefaultQueueLimit = 100
)

var (
	ErrQueueFull = errors.New("execution queue is full")
	ErrShutdown  = errors.New("execution coordinator is shut down")
	ErrNotFound  = errors.New("execution not found")
	// ErrEngineUnavailable is what the stub runner reports.
	ErrEngineUnavailable = errors.New("workflow execution engine is not available in this build")
)

// Job is everything a runner needs. Workflow is a private deep copy taken at
// start, so later refreshes or file edits never change a started execution.
type Job struct {
	ExecutionID    string
	RepositoryID   string
	RepositoryPath string
	Ref            string
	Workflow       repository.Workflow
}

// Runner executes one job. It must return promptly after ctx is cancelled and
// its error text must never contain credentials: it is published in events.
type Runner interface {
	Run(ctx context.Context, job Job) error
}

type RunnerFunc func(ctx context.Context, job Job) error

func (f RunnerFunc) Run(ctx context.Context, job Job) error { return f(ctx, job) }

// StubRunner stands in until a real engine exists. It fails every job
// honestly instead of pretending to succeed.
type StubRunner struct{}

func (StubRunner) Run(context.Context, Job) error { return ErrEngineUnavailable }

type Options struct {
	Limit      int // concurrent executions; default 3
	QueueLimit int // waiting executions; default 100
}

// Execution is the immediate result of Start.
type Execution struct {
	ID           string
	RepositoryID string
	State        corev1.ExecutionState
}

// Coordinator is safe for concurrent use. The publish callback is invoked
// while the coordinator lock is held so that events of one execution keep
// their order; it must be quick, must not block and must not call back in.
type Coordinator struct {
	runner  Runner
	publish func(events.Event)
	limit   int
	maxWait int

	base       context.Context
	cancelBase context.CancelFunc
	wg         sync.WaitGroup

	mu      sync.Mutex
	closed  bool
	queue   []*run
	running map[string]*run
}

type run struct {
	job             Job
	cancel          context.CancelFunc
	cancelRequested bool
}

func New(runner Runner, options Options, publish func(events.Event)) *Coordinator {
	if options.Limit <= 0 {
		options.Limit = DefaultLimit
	}
	if options.QueueLimit <= 0 {
		options.QueueLimit = DefaultQueueLimit
	}
	if publish == nil {
		publish = func(events.Event) {}
	}
	base, cancel := context.WithCancel(context.Background())
	return &Coordinator{
		runner: runner, publish: publish,
		limit: options.Limit, maxWait: options.QueueLimit,
		base: base, cancelBase: cancel,
		running: map[string]*run{},
	}
}

// Start runs the workflow now if a slot is free, otherwise queues it.
func (c *Coordinator) Start(repositoryID, repositoryPath string, workflow repository.Workflow, ref string) (Execution, error) {
	id, err := newID()
	if err != nil {
		return Execution{}, err
	}
	r := &run{job: Job{
		ExecutionID: id, RepositoryID: repositoryID, RepositoryPath: repositoryPath,
		Ref: ref, Workflow: cloneWorkflow(workflow),
	}}

	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return Execution{}, ErrShutdown
	}
	if len(c.running) < c.limit { // a free slot implies an empty queue
		c.startLocked(r)
		return Execution{ID: id, RepositoryID: repositoryID, State: corev1.ExecutionState_EXECUTION_STATE_RUNNING}, nil
	}
	if len(c.queue) >= c.maxWait {
		return Execution{}, ErrQueueFull
	}
	c.queue = append(c.queue, r)
	c.emit(r, corev1.CoreEventType_CORE_EVENT_TYPE_WORKFLOW_STATUS_CHANGED, corev1.ExecutionState_EXECUTION_STATE_QUEUED, "")
	return Execution{ID: id, RepositoryID: repositoryID, State: corev1.ExecutionState_EXECUTION_STATE_QUEUED}, nil
}

// Cancel removes a queued execution at once, or asks a running one to stop.
// A running execution keeps its slot until its runner returns.
func (c *Coordinator) Cancel(executionID string) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if r, ok := c.running[executionID]; ok {
		r.cancelRequested = true
		r.cancel()
		return nil
	}
	for i, r := range c.queue {
		if r.job.ExecutionID == executionID {
			c.dequeueLocked(i)
			return nil
		}
	}
	return ErrNotFound
}

// CancelRepository cancels every queued and running execution of a repository.
func (c *Coordinator) CancelRepository(repositoryID string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for i := 0; i < len(c.queue); {
		if c.queue[i].job.RepositoryID == repositoryID {
			c.dequeueLocked(i)
			continue
		}
		i++
	}
	for _, r := range c.running {
		if r.job.RepositoryID == repositoryID {
			r.cancelRequested = true
			r.cancel()
		}
	}
}

func (c *Coordinator) Running() int { c.mu.Lock(); defer c.mu.Unlock(); return len(c.running) }
func (c *Coordinator) Queued() int  { c.mu.Lock(); defer c.mu.Unlock(); return len(c.queue) }

// Shutdown cancels everything, refuses new work and waits for runners to
// return or ctx to end.
func (c *Coordinator) Shutdown(ctx context.Context) {
	c.mu.Lock()
	c.closed = true
	for len(c.queue) > 0 {
		c.dequeueLocked(0)
	}
	for _, r := range c.running {
		r.cancelRequested = true
	}
	c.mu.Unlock()
	c.cancelBase()

	done := make(chan struct{})
	go func() { c.wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-ctx.Done():
	}
}

func (c *Coordinator) dequeueLocked(i int) {
	r := c.queue[i]
	c.queue = append(c.queue[:i], c.queue[i+1:]...)
	c.emit(r, corev1.CoreEventType_CORE_EVENT_TYPE_WORKFLOW_STATUS_CHANGED, corev1.ExecutionState_EXECUTION_STATE_CANCELLED, "")
}

func (c *Coordinator) startLocked(r *run) {
	ctx, cancel := context.WithCancel(c.base)
	r.cancel = cancel
	c.running[r.job.ExecutionID] = r
	c.emit(r, corev1.CoreEventType_CORE_EVENT_TYPE_WORKFLOW_STARTED, corev1.ExecutionState_EXECUTION_STATE_RUNNING, "")
	c.wg.Add(1)
	go func() {
		defer c.wg.Done()
		c.finish(r, c.runSafely(ctx, r.job))
	}()
}

func (c *Coordinator) runSafely(ctx context.Context, job Job) (err error) {
	defer func() {
		if recover() != nil {
			err = errors.New("runner panicked")
		}
	}()
	return c.runner.Run(ctx, job)
}

func (c *Coordinator) finish(r *run, runErr error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	delete(c.running, r.job.ExecutionID)
	r.cancel()
	switch {
	case r.cancelRequested:
		c.emit(r, corev1.CoreEventType_CORE_EVENT_TYPE_WORKFLOW_STATUS_CHANGED, corev1.ExecutionState_EXECUTION_STATE_CANCELLED, "")
	case runErr != nil:
		c.emit(r, corev1.CoreEventType_CORE_EVENT_TYPE_WORKFLOW_FAILED, corev1.ExecutionState_EXECUTION_STATE_FAILED, runErr.Error())
	default:
		c.emit(r, corev1.CoreEventType_CORE_EVENT_TYPE_WORKFLOW_COMPLETED, corev1.ExecutionState_EXECUTION_STATE_SUCCEEDED, "")
	}
	for !c.closed && len(c.running) < c.limit && len(c.queue) > 0 {
		next := c.queue[0]
		c.queue = c.queue[1:]
		c.startLocked(next)
	}
}

func (c *Coordinator) emit(r *run, t corev1.CoreEventType, state corev1.ExecutionState, message string) {
	c.publish(events.Event{
		Type: t, RepositoryID: r.job.RepositoryID, ExecutionID: r.job.ExecutionID,
		ExecutionState: state, Message: message,
	})
}

func newID() (string, error) {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("generate execution id: %w", err)
	}
	return "exec_" + hex.EncodeToString(b[:]), nil
}

func cloneWorkflow(w repository.Workflow) repository.Workflow {
	out := w
	out.Triggers = append([]string(nil), w.Triggers...)
	out.Jobs = make([]repository.Job, len(w.Jobs))
	for i, j := range w.Jobs {
		out.Jobs[i] = repository.Job{ID: j.ID, Name: j.Name, Needs: append([]string(nil), j.Needs...)}
	}
	return out
}
