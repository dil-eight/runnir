package workspace

import (
	"context"
	"errors"
	"os"
	"sync"
	"sync/atomic"
	"time"

	"runnir/core/internal/events"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/store"
)

var (
	// ErrMismatch: the repository context is bound to another workspace.
	ErrMismatch = errors.New("the repository is open for another workspace")
	// ErrOpen: the workspace is open, so its data cannot be deleted.
	ErrOpen = errors.New("the workspace is open")
)

type Options struct {
	// DataDir holds repositories/<workspaceId>/; "" keeps every store in memory.
	DataDir   string
	Publish   func(events.Event)
	Now       func() time.Time
	Intervals Intervals
	// BilledMinutes says what GitHub would have billed for a finished local
	// run's jobs; nil counts nothing.
	BilledMinutes func(executionID string) int64
}

// Usage is what one workspace keeps; State 0 means nothing on disk.
type Usage struct {
	WorkspaceID string
	State       store.State
	Note        string
	Open        bool
	store.Usage
}

// Runtimes holds one Runtime per open workspace. Safe for concurrent use.
type Runtimes struct {
	opts     Options
	now      func() time.Time
	keepLogs atomic.Bool
	recorder *recorder

	mu           sync.Mutex
	byWorkspace  map[string]*Runtime
	byRepository map[string]string
	// opening holds workspaces whose store is being opened; a second
	// Attach waits for it instead of opening the same database again.
	opening map[string]chan struct{}
	// local maps execution ids recorded as local runs to their repository.
	local map[string]string
}

func New(opts Options) *Runtimes {
	if opts.Intervals.Active == 0 {
		opts.Intervals = DefaultIntervals()
	}
	now := opts.Now
	if now == nil {
		now = time.Now
	}
	return &Runtimes{opts: opts, now: now, recorder: newRecorder(),
		byWorkspace: map[string]*Runtime{}, byRepository: map[string]string{}, local: map[string]string{},
		opening: map[string]chan struct{}{}}
}

// Attach binds an open repository context to its workspace, starting the
// workspace's runtime on first use. Another context of the same workspace
// (a relinked folder) takes the runtime over.
func (m *Runtimes) Attach(workspaceID, repositoryID string, resolve Resolver) (*Runtime, error) {
	id, ok := store.NormalizeWorkspaceID(workspaceID)
	if !ok {
		return nil, store.ErrInvalidWorkspace
	}
	for {
		m.mu.Lock()
		if other, bound := m.byRepository[repositoryID]; bound && other != id {
			m.mu.Unlock()
			return nil, ErrMismatch
		}
		if rt, ok := m.byWorkspace[id]; ok {
			if previous := rt.RepositoryID(); previous != repositoryID {
				delete(m.byRepository, previous)
				m.byRepository[repositoryID] = id
				// Local runs going on keep their history.
				for executionID, repository := range m.local {
					if repository == previous {
						m.local[executionID] = repositoryID
					}
				}
				m.mu.Unlock()
				rt.rebind(repositoryID, resolve)
				return rt, nil
			}
			m.mu.Unlock()
			return rt, nil
		}
		if wait, busy := m.opening[id]; busy {
			m.mu.Unlock()
			<-wait
			continue
		}
		done := make(chan struct{})
		m.opening[id] = done
		m.mu.Unlock()

		// Opening may migrate or recover; other workspaces are not held up,
		// and another open of this one waits instead of taking the lock
		// file and falling back to memory.
		st, err := store.Open(m.dir(id), store.Options{Now: m.now})
		m.mu.Lock()
		delete(m.opening, id)
		close(done)
		if err != nil {
			m.mu.Unlock()
			return nil, err
		}
		rt := newRuntime(id, repositoryID, resolve, config{store: st, publish: m.opts.Publish, now: m.now,
			intervals: m.opts.Intervals, keepLogs: m.keepLogs.Load})
		m.byWorkspace[id] = rt
		m.byRepository[repositoryID] = id
		m.mu.Unlock()
		rt.start()
		return rt, nil
	}
}

func (m *Runtimes) dir(id string) string {
	if m.opts.DataDir == "" {
		return ""
	}
	return store.WorkspaceDir(m.opts.DataDir, id)
}

func (m *Runtimes) ForRepository(repositoryID string) (*Runtime, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	rt, ok := m.byWorkspace[m.byRepository[repositoryID]]
	return rt, ok
}

// Detach closes the runtime bound to a repository context that closed:
// queued history is written, the loop stops, the store is closed.
func (m *Runtimes) Detach(repositoryID string) {
	m.mu.Lock()
	id, ok := m.byRepository[repositoryID]
	if !ok {
		m.mu.Unlock()
		return
	}
	rt := m.byWorkspace[id]
	delete(m.byRepository, repositoryID)
	delete(m.byWorkspace, id)
	for executionID, repository := range m.local {
		if repository == repositoryID {
			delete(m.local, executionID)
		}
	}
	m.mu.Unlock()
	m.recorder.flush()
	rt.Close()
	_ = rt.cfg.store.Close()
}

func (m *Runtimes) all() []*Runtime {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]*Runtime, 0, len(m.byWorkspace))
	for _, rt := range m.byWorkspace {
		out = append(out, rt)
	}
	return out
}

// claim returns the workspace's runtime when it is open. Otherwise it marks
// the workspace busy, as an open in progress does, so an Attach meanwhile
// waits instead of finding the lock file taken and falling back to memory;
// release ends that.
func (m *Runtimes) claim(id string) (*Runtime, func()) {
	for {
		m.mu.Lock()
		if rt := m.byWorkspace[id]; rt != nil {
			m.mu.Unlock()
			return rt, func() {}
		}
		if wait, busy := m.opening[id]; busy {
			m.mu.Unlock()
			<-wait
			continue
		}
		done := make(chan struct{})
		m.opening[id] = done
		m.mu.Unlock()
		return nil, func() {
			m.mu.Lock()
			delete(m.opening, id)
			close(done)
			m.mu.Unlock()
		}
	}
}

// CredentialChanged lets the runtimes that use the server sync again.
func (m *Runtimes) CredentialChanged(serverID string) {
	for _, rt := range m.all() {
		rt.credentialChanged(serverID)
	}
}

func (m *Runtimes) KeepLogs() bool { return m.keepLogs.Load() }

// SetKeepLogs turns keeping completed jobs' logs on or off; deleteKept with
// off also deletes what every workspace kept so far.
func (m *Runtimes) SetKeepLogs(keep, deleteKept bool) error {
	m.keepLogs.Store(keep)
	if keep || !deleteKept {
		return nil
	}
	var errs []error
	open := map[string]bool{}
	for _, rt := range m.all() {
		open[rt.WorkspaceID()] = true
		errs = append(errs, rt.cfg.store.DeleteLogs(context.Background()))
	}
	if m.opts.DataDir != "" {
		ids, err := store.Workspaces(m.opts.DataDir)
		errs = append(errs, err)
		for _, id := range ids {
			if open[id] {
				continue
			}
			if rt, release := m.claim(id); rt != nil {
				errs = append(errs, rt.cfg.store.DeleteLogs(context.Background()))
			} else {
				errs = append(errs, store.DeleteKeptLogs(m.opts.DataDir, id))
				release()
			}
		}
	}
	return errors.Join(errs...)
}

// ids normalizes requested ids; none means every workspace on disk and
// every open one.
func (m *Runtimes) ids(requested []string) ([]string, error) {
	if len(requested) > 0 {
		out := make([]string, 0, len(requested))
		for _, raw := range requested {
			id, ok := store.NormalizeWorkspaceID(raw)
			if !ok {
				return nil, store.ErrInvalidWorkspace
			}
			out = append(out, id)
		}
		return out, nil
	}
	seen := map[string]bool{}
	var out []string
	if m.opts.DataDir != "" {
		onDisk, err := store.Workspaces(m.opts.DataDir)
		if err != nil {
			return nil, err
		}
		for _, id := range onDisk {
			seen[id] = true
			out = append(out, id)
		}
	}
	for _, rt := range m.all() {
		if !seen[rt.WorkspaceID()] {
			out = append(out, rt.WorkspaceID())
		}
	}
	return out, nil
}

func (m *Runtimes) Usage(ctx context.Context, requested []string) ([]Usage, error) {
	ids, err := m.ids(requested)
	if err != nil {
		return nil, err
	}
	out := make([]Usage, 0, len(ids))
	for _, id := range ids {
		u, err := m.usage(ctx, id)
		if err != nil {
			return nil, err
		}
		out = append(out, u)
	}
	return out, nil
}

func (m *Runtimes) usage(ctx context.Context, id string) (Usage, error) {
	rt, release := m.claim(id)
	defer release()
	if rt != nil {
		su, err := rt.cfg.store.Usage(ctx)
		report := rt.cfg.store.Report()
		return Usage{WorkspaceID: id, State: report.State, Note: report.Note, Open: true, Usage: su}, err
	}
	if m.opts.DataDir == "" {
		return Usage{WorkspaceID: id}, nil
	}
	su, report, ok := store.Peek(m.dir(id))
	if !ok {
		return Usage{WorkspaceID: id}, nil
	}
	return Usage{WorkspaceID: id, State: report.State, Note: report.Note, Usage: su}, nil
}

// openClosed opens the store of a workspace that is not open, if it has a
// directory.
func (m *Runtimes) openClosed(id string) (*store.Store, bool, error) {
	if m.opts.DataDir == "" {
		return nil, false, nil
	}
	if _, err := os.Lstat(m.dir(id)); errors.Is(err, os.ErrNotExist) {
		return nil, false, nil
	}
	st, err := store.Open(m.dir(id), store.Options{Now: m.now})
	return st, err == nil, err
}

// ClearCache clears the cache of each workspace (all when none are named)
// and returns their usage afterwards.
func (m *Runtimes) ClearCache(ctx context.Context, requested []string) ([]Usage, error) {
	ids, err := m.ids(requested)
	if err != nil {
		return nil, err
	}
	for _, id := range ids {
		if err := m.clearCache(ctx, id); err != nil {
			return nil, err
		}
	}
	return m.Usage(ctx, ids)
}

func (m *Runtimes) clearCache(ctx context.Context, id string) error {
	rt, release := m.claim(id)
	defer release()
	if rt != nil {
		return rt.ClearCache(ctx)
	}
	st, ok, err := m.openClosed(id)
	if err != nil || !ok {
		return err
	}
	clearErr := st.ClearCache(ctx)
	_ = st.Close()
	return clearErr
}

// ClearRunIndex forgets the search index of each workspace (all when none are
// named) and returns their usage afterwards.
func (m *Runtimes) ClearRunIndex(ctx context.Context, requested []string) ([]Usage, error) {
	ids, err := m.ids(requested)
	if err != nil {
		return nil, err
	}
	for _, id := range ids {
		if err := m.clearRunIndex(ctx, id); err != nil {
			return nil, err
		}
	}
	return m.Usage(ctx, ids)
}

func (m *Runtimes) clearRunIndex(ctx context.Context, id string) error {
	rt, release := m.claim(id)
	defer release()
	if rt != nil {
		return rt.cfg.store.ClearRunIndex(ctx)
	}
	st, ok, err := m.openClosed(id)
	if err != nil || !ok {
		return err
	}
	clearErr := st.ClearRunIndex(ctx)
	_ = st.Close()
	return clearErr
}

// Delete removes a workspace's whole directory; refused while it is open.
func (m *Runtimes) Delete(raw string) error {
	id, ok := store.NormalizeWorkspaceID(raw)
	if !ok {
		return store.ErrInvalidWorkspace
	}
	rt, release := m.claim(id)
	defer release()
	if rt != nil {
		return ErrOpen
	}
	if m.opts.DataDir == "" {
		return nil
	}
	return store.DeleteWorkspace(m.opts.DataDir, id)
}

// RecordLocalRun queues a local run's record. Call it before the execution
// starts, so its events are written after it.
func (m *Runtimes) RecordLocalRun(repositoryID string, run store.LocalRun) {
	m.mu.Lock()
	rt, ok := m.byWorkspace[m.byRepository[repositoryID]]
	if ok {
		m.local[run.ExecutionID] = repositoryID
	}
	m.mu.Unlock()
	if !ok {
		return
	}
	m.recorder.add(func() { _ = rt.cfg.store.RecordLocalRun(context.Background(), run) })
}

// LocalRunNotStarted marks a recorded run that could not start as failed.
func (m *Runtimes) LocalRunNotStarted(executionID, message string) {
	m.ObserveExecution(events.Event{ExecutionID: executionID, ExecutionState: corev1.ExecutionState_EXECUTION_STATE_FAILED,
		Message: message, At: m.now()})
}

// ObserveExecution writes a recorded local run's state change. It only
// queues work: it is called from the execution coordinator's callback.
func (m *Runtimes) ObserveExecution(e events.Event) {
	if e.ExecutionID == "" {
		return
	}
	state, ok := localState(e.ExecutionState)
	if !ok {
		return
	}
	m.mu.Lock()
	repositoryID, known := m.local[e.ExecutionID]
	var rt *Runtime
	if known {
		rt = m.byWorkspace[m.byRepository[repositoryID]]
		if state != store.LocalQueued && state != store.LocalRunning {
			delete(m.local, e.ExecutionID)
		}
	}
	m.mu.Unlock()
	if rt == nil {
		return
	}
	at := e.At
	if at.IsZero() {
		at = m.now()
	}
	// Read now: the run's output is forgotten after later runs.
	var minutes int64
	if (state == store.LocalSucceeded || state == store.LocalFailed) && m.opts.BilledMinutes != nil {
		minutes = m.opts.BilledMinutes(e.ExecutionID)
	}
	m.recorder.add(func() {
		ctx := context.Background()
		_ = rt.cfg.store.UpdateLocalRun(ctx, e.ExecutionID, state, at, e.Message)
		if minutes > 0 && rt.cfg.store.AddSaving(ctx, store.SavingLocalRuns, minutes, at) == nil {
			rt.publish()
		}
	})
}

func localState(state corev1.ExecutionState) (string, bool) {
	switch state {
	case corev1.ExecutionState_EXECUTION_STATE_QUEUED:
		return store.LocalQueued, true
	case corev1.ExecutionState_EXECUTION_STATE_RUNNING:
		return store.LocalRunning, true
	case corev1.ExecutionState_EXECUTION_STATE_SUCCEEDED:
		return store.LocalSucceeded, true
	case corev1.ExecutionState_EXECUTION_STATE_FAILED:
		return store.LocalFailed, true
	case corev1.ExecutionState_EXECUTION_STATE_CANCELLED:
		return store.LocalCancelled, true
	}
	return "", false
}

// Shutdown closes every runtime after the queued history is written.
func (m *Runtimes) Shutdown() {
	m.mu.Lock()
	repositories := make([]string, 0, len(m.byRepository))
	for repositoryID := range m.byRepository {
		repositories = append(repositories, repositoryID)
	}
	m.mu.Unlock()
	for _, repositoryID := range repositories {
		m.Detach(repositoryID)
	}
	m.recorder.close()
}
