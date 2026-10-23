// Package repository owns the independent per-repository contexts of the
// single Core process. Contexts never share mutable state; a manager lock
// guards only the registry, so work on one repository never blocks another.
package repository

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

var (
	// ErrInvalidPath means the path is not an absolute, existing directory.
	ErrInvalidPath = errors.New("path is not an absolute existing directory")
	// ErrNotFound means no open repository has the given id.
	ErrNotFound = errors.New("repository not found")
	// ErrAccessDenied means the operating system refuses the Core read access
	// to the folder, for example a protected location the user has not allowed.
	ErrAccessDenied = errors.New("folder is not readable by the Core")
)

// Scanner reads a repository's workflow state from disk. It must honor ctx
// cancellation. Implementations are called concurrently for different
// repositories but never concurrently for the same one.
type Scanner interface {
	Scan(ctx context.Context, root string) (Snapshot, error)
}

// Snapshot is an immutable result of one scan. Managers replace snapshots
// wholesale and never mutate one after publishing it; callers must not either.
type Snapshot struct {
	Branch string
	// OriginHost is the origin remote's host, lowercased; OriginRepository
	// its "owner/name". Both empty without a readable origin.
	OriginHost       string
	OriginRepository string
	Workflows        []Workflow
	// LaunchPresets are the Run Workflow presets of .runnir/launches, with
	// entries for files or folders that cannot be used.
	LaunchPresets []LaunchPreset
}

type Workflow struct {
	ID         string
	Name       string
	Triggers   []string
	Jobs       []Job
	ParseError string
	// DispatchInputs are the workflow_dispatch inputs the local file declares.
	DispatchInputs []DispatchInput
	// Concurrency: the file sets concurrency at the top level or in a job.
	Concurrency bool
}

// DispatchInput is one `on.workflow_dispatch.inputs` entry.
type DispatchInput struct {
	Name        string
	Description string
	// Type is "string" (the default), "boolean", "choice", "number" or "environment".
	Type     string
	Required bool
	Default  string
	Options  []string
}

type Job struct {
	ID    string
	Name  string
	Needs []string
}

// LaunchPreset is one file of .runnir/launches: a Run Workflow preset the
// repository shares, or, with Problem set, why a file or folder there cannot
// be used.
type LaunchPreset struct {
	// Path is ".runnir/launches/<file>", or ".runnir" or ".runnir/launches"
	// for an entry about that folder.
	Path string
	Name string
	// WorkflowPath is ".github/workflows/<file>".
	WorkflowPath string
	// Ref is empty when the preset keeps the form's branch.
	Ref    string
	Inputs map[string]string
	// Problem is empty for a usable preset.
	Problem string
}

// Info is a point-in-time view of one repository context.
type Info struct {
	ID               string
	Path             string
	Branch           string
	OriginHost       string
	OriginRepository string
	WorkflowCount    int
	LastRefresh      time.Time
}

type EventType int

const (
	RepositoryOpened EventType = iota + 1
	RepositoryRefreshed
	RepositoryClosed
)

type Event struct {
	Type         EventType
	RepositoryID string
}

// Manager is safe for concurrent use.
type Manager struct {
	scanner Scanner
	onEvent func(Event)
	now     func() time.Time

	mu      sync.RWMutex
	entries map[string]*entry
}

// New returns a manager. onEvent may be nil. It is called outside the
// registry lock, sometimes under one repository's lock, so it must not call
// back into the manager.
func New(scanner Scanner, onEvent func(Event)) *Manager {
	return &Manager{scanner: scanner, onEvent: onEvent, now: time.Now, entries: map[string]*entry{}}
}

type entry struct {
	id       string
	path     string
	fileInfo os.FileInfo

	ctx    context.Context // cancelled when the repository is closed
	cancel context.CancelFunc

	ready   chan struct{} // closed when the initial scan finished
	openErr error         // valid after ready is closed
	refresh chan struct{} // capacity-1 semaphore serializing scans

	mu     sync.RWMutex
	closed bool
	snap   Snapshot
	last   time.Time
}

func (e *entry) info() Info {
	e.mu.RLock()
	defer e.mu.RUnlock()
	return Info{ID: e.id, Path: e.path, Branch: e.snap.Branch, OriginHost: e.snap.OriginHost, OriginRepository: e.snap.OriginRepository,
		WorkflowCount: len(e.snap.Workflows), LastRefresh: e.last}
}

func (e *entry) isReady() bool {
	select {
	case <-e.ready:
		return true
	default:
		return false
	}
}

// Open registers the repository at path, or returns the existing context.
// The id is derived from the first resolved path and stays stable across
// close and reopen. Concurrent opens of the same directory share one initial
// scan.
func (m *Manager) Open(ctx context.Context, path string) (Info, error) {
	resolved, fileInfo, err := resolve(path)
	if err != nil {
		return Info{}, err
	}

	m.mu.Lock()
	for _, existing := range m.entries {
		if existing.path == resolved || os.SameFile(existing.fileInfo, fileInfo) {
			m.mu.Unlock()
			return existing.awaitInfo(ctx)
		}
	}
	scope, cancel := context.WithCancel(context.Background())
	created := &entry{
		id: idFor(resolved), path: resolved, fileInfo: fileInfo,
		ctx: scope, cancel: cancel,
		ready: make(chan struct{}), refresh: make(chan struct{}, 1),
	}
	m.entries[created.id] = created
	m.mu.Unlock()

	snapshot, scanErr := m.scanner.Scan(created.ctx, resolved)

	created.mu.Lock()
	switch {
	case created.closed: // closed while scanning; the scan error is just the cancellation
		created.openErr = ErrNotFound
	case scanErr != nil:
		created.openErr = scanErr
	default:
		created.snap, created.last = snapshot, m.now()
	}
	created.mu.Unlock()
	if created.openErr != nil {
		m.remove(created)
		created.cancel()
		close(created.ready)
		return Info{}, created.openErr
	}
	close(created.ready)
	m.emit(Event{Type: RepositoryOpened, RepositoryID: created.id})
	return created.info(), nil
}

func (e *entry) awaitInfo(ctx context.Context) (Info, error) {
	select {
	case <-e.ready:
	case <-ctx.Done():
		return Info{}, ctx.Err()
	}
	if e.openErr != nil {
		return Info{}, e.openErr
	}
	return e.info(), nil
}

// Get returns the current view of an open repository without blocking on
// running scans.
func (m *Manager) Get(id string) (Info, error) {
	e, err := m.lookupReady(id)
	if err != nil {
		return Info{}, err
	}
	return e.info(), nil
}

// Workflows returns the workflows of the latest published snapshot.
func (m *Manager) Workflows(id string) ([]Workflow, error) {
	e, err := m.lookupReady(id)
	if err != nil {
		return nil, err
	}
	e.mu.RLock()
	defer e.mu.RUnlock()
	return append([]Workflow(nil), e.snap.Workflows...), nil
}

// LaunchPresets returns the .runnir/launches presets of the latest published
// snapshot.
func (m *Manager) LaunchPresets(id string) ([]LaunchPreset, error) {
	e, err := m.lookupReady(id)
	if err != nil {
		return nil, err
	}
	e.mu.RLock()
	defer e.mu.RUnlock()
	return append([]LaunchPreset(nil), e.snap.LaunchPresets...), nil
}

// Refresh rescans one repository. Refreshes of the same repository run one at
// a time; other repositories are unaffected. Closing the repository cancels a
// running refresh, which then returns ErrNotFound.
func (m *Manager) Refresh(ctx context.Context, id string) (Info, error) {
	e, err := m.lookup(id)
	if err != nil {
		return Info{}, err
	}
	if _, err := e.awaitInfo(ctx); err != nil {
		return Info{}, err
	}
	select {
	case e.refresh <- struct{}{}:
		defer func() { <-e.refresh }()
	case <-ctx.Done():
		return Info{}, ctx.Err()
	case <-e.ctx.Done():
		return Info{}, ErrNotFound
	}

	scanCtx, cancel := context.WithCancel(e.ctx)
	defer cancel()
	stop := context.AfterFunc(ctx, cancel)
	defer stop()

	snapshot, scanErr := m.scanner.Scan(scanCtx, e.path)

	e.mu.Lock()
	if e.closed {
		e.mu.Unlock()
		return Info{}, ErrNotFound
	}
	if scanErr != nil {
		e.mu.Unlock()
		if ctx.Err() != nil {
			return Info{}, ctx.Err()
		}
		return Info{}, scanErr
	}
	e.snap, e.last = snapshot, m.now()
	// Emitted under the entry lock so a concurrent Close, which takes the
	// same lock first, always reports CLOSED after this REFRESHED.
	m.emit(Event{Type: RepositoryRefreshed, RepositoryID: e.id})
	info := Info{ID: e.id, Path: e.path, Branch: e.snap.Branch, OriginHost: e.snap.OriginHost, OriginRepository: e.snap.OriginRepository,
		WorkflowCount: len(e.snap.Workflows), LastRefresh: e.last}
	e.mu.Unlock()
	return info, nil
}

// Close releases a repository and cancels its running work.
func (m *Manager) Close(id string) error {
	m.mu.Lock()
	e, ok := m.entries[id]
	if ok {
		delete(m.entries, id)
	}
	m.mu.Unlock()
	if !ok {
		return ErrNotFound
	}
	m.closeEntry(e)
	return nil
}

// Count reports the number of registered repositories.
func (m *Manager) Count() int {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return len(m.entries)
}

// Shutdown closes every repository.
func (m *Manager) Shutdown() {
	m.mu.Lock()
	all := make([]*entry, 0, len(m.entries))
	for id, e := range m.entries {
		all = append(all, e)
		delete(m.entries, id)
	}
	m.mu.Unlock()
	for _, e := range all {
		m.closeEntry(e)
	}
}

func (m *Manager) closeEntry(e *entry) {
	e.mu.Lock()
	e.closed = true
	e.mu.Unlock()
	e.cancel()
	m.emit(Event{Type: RepositoryClosed, RepositoryID: e.id})
}

func (m *Manager) lookup(id string) (*entry, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	e, ok := m.entries[id]
	if !ok {
		return nil, ErrNotFound
	}
	return e, nil
}

func (m *Manager) lookupReady(id string) (*entry, error) {
	e, err := m.lookup(id)
	if err != nil {
		return nil, err
	}
	if !e.isReady() || e.openErr != nil {
		return nil, ErrNotFound
	}
	return e, nil
}

// remove deletes e only if it is still the registered entry for its id.
func (m *Manager) remove(e *entry) {
	m.mu.Lock()
	if m.entries[e.id] == e {
		delete(m.entries, e.id)
	}
	m.mu.Unlock()
}

func (m *Manager) emit(event Event) {
	if m.onEvent != nil {
		m.onEvent(event)
	}
}

func resolve(path string) (string, os.FileInfo, error) {
	if path == "" || !filepath.IsAbs(path) {
		return "", nil, fmt.Errorf("%w: %q", ErrInvalidPath, path)
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		return "", nil, fmt.Errorf("%w: %q", ErrInvalidPath, path)
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.IsDir() {
		return "", nil, fmt.Errorf("%w: %q", ErrInvalidPath, path)
	}
	return resolved, info, nil
}

func idFor(resolvedPath string) string {
	sum := sha256.Sum256([]byte(resolvedPath))
	return "repo_" + hex.EncodeToString(sum[:8])
}
