package workspace

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	"golang.org/x/sync/singleflight"

	"runnir/core/internal/changes"
	"runnir/core/internal/events"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

// pageSize is how many of the newest runs one pass reads.
const pageSize = 50

// ErrClosed is returned by a runtime whose workspace was closed.
var ErrClosed = errors.New("workspace runtime closed")

// Target is the GitHub repository a workspace's activity comes from.
type Target struct {
	Account     *github.Account
	Owner, Name string
}

// Source names the target for the cache: server id and lowercased owner/name.
func (t Target) Source() store.Source {
	return store.Source{ServerID: t.Account.Server.ID, Repository: strings.ToLower(t.Owner + "/" + t.Name)}
}

// Resolver returns the repository's current target with OK, or the status
// that says why there is none (NO_REMOTE).
type Resolver func() (Target, corev1.GithubAccess)

// Provenance says where a snapshot's data comes from.
type Provenance int

const (
	// NoData: nothing cached for the repository the origin points at now.
	NoData Provenance = iota
	// Cached: read from disk; no pass reached GitHub in this process yet.
	Cached
	// Live: a pass reached GitHub in this process.
	Live
)

// Snapshot is a workspace's activity as the app shows it.
type Snapshot struct {
	// Runs newest first, at most the limit asked for.
	Runs      []github.Run
	Workflows []github.Workflow
	// Links, superseded runs and overlaps over every cached run.
	Analysis changes.Analysis
	// The changes of Runs, newest first.
	Changes         []changes.Change
	CachedRuns      int
	HistoryComplete bool
	Provenance      Provenance
	Syncing         bool
	// Access is the last pass's outcome, or why there is no target;
	// UNSPECIFIED before the first pass.
	Access     corev1.GithubAccess
	RetryAfter time.Time
	CheckedAt  time.Time
	SyncedAt   time.Time
	ChangedAt  time.Time
	// PullRequestsAccess is the last pull request read's outcome once a pass
	// ran in this process; UNSPECIFIED before.
	PullRequestsAccess corev1.GithubAccess
}

type config struct {
	store     *store.Store
	publish   func(events.Event)
	now       func() time.Time
	intervals Intervals
	keepLogs  func() bool
}

// Runtime is one workspace's shared service: one sync loop and one store,
// whatever number of windows show the workspace.
type Runtime struct {
	workspaceID string
	cfg         config
	ctx         context.Context
	cancel      context.CancelFunc
	wake        chan struct{}
	loopDone    chan struct{}
	flights     singleflight.Group
	// branchFor is the target whose default branch a pass read in this
	// process; only the loop goroutine uses it.
	branchFor store.Source

	mu           sync.Mutex
	repositoryID string
	resolve      Resolver
	started      uint64
	finished     uint64
	passDone     chan struct{}
	syncing      bool
	live         bool
	active       bool
	failures     int
	lastAccess   corev1.GithubAccess
	lastRetry    time.Time
	lastServer   string
	hasServer    bool
	// pullsRefused: GitHub refused pull requests; they are not read again
	// until the credential changes or someone asks for a refresh.
	pullsRefused bool
}

func newRuntime(workspaceID, repositoryID string, resolve Resolver, cfg config) *Runtime {
	ctx, cancel := context.WithCancel(context.Background())
	return &Runtime{
		workspaceID: workspaceID, cfg: cfg, ctx: ctx, cancel: cancel,
		wake: make(chan struct{}, 1), loopDone: make(chan struct{}),
		repositoryID: repositoryID, resolve: resolve, passDone: make(chan struct{}),
	}
}

func (r *Runtime) start() { go r.loop() }

func (r *Runtime) WorkspaceID() string { return r.workspaceID }

func (r *Runtime) Store() *store.Store { return r.cfg.store }

func (r *Runtime) RepositoryID() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.repositoryID
}

// rebind moves the runtime to another repository context of the same
// workspace (a relinked folder) and syncs again, the origin may differ.
func (r *Runtime) rebind(repositoryID string, resolve Resolver) {
	r.mu.Lock()
	r.repositoryID, r.resolve = repositoryID, resolve
	r.mu.Unlock()
	_ = r.Refresh(context.Background(), false)
}

// Close stops the loop and waits for a running pass to end. The store is
// closed by its owner.
func (r *Runtime) Close() {
	r.cancel()
	<-r.loopDone
}

func (r *Runtime) loop() {
	defer close(r.loopDone)
	timer := time.NewTimer(0)
	defer timer.Stop()
	for {
		select {
		case <-r.ctx.Done():
			return
		case <-timer.C:
		case <-r.wake:
		}
		timer.Stop()
		r.pass()
		if r.ctx.Err() != nil {
			return
		}
		r.mu.Lock()
		delay, ok := schedule(r.cfg.intervals, r.lastAccess, r.active, r.failures, r.lastRetry, r.cfg.now())
		r.mu.Unlock()
		if ok {
			timer.Reset(delay)
		}
	}
}

// Refresh asks for a pass. Requests during a pass are merged into exactly
// one more. With wait it returns once a pass that started after the request
// has ended.
func (r *Runtime) Refresh(ctx context.Context, wait bool) error {
	select {
	case <-r.loopDone:
		return ErrClosed
	default:
	}
	// Reading the count and waking happen under the lock that a starting
	// pass drains the wake under, so a request is either answered by that
	// pass or leaves a wake for the next one, never a stale wake.
	r.mu.Lock()
	// Asking for a refresh tries pull requests again after a refusal.
	r.pullsRefused = false
	target := r.started + 1
	select {
	case r.wake <- struct{}{}:
	default:
	}
	r.mu.Unlock()
	if !wait {
		return nil
	}
	for {
		r.mu.Lock()
		finished, done := r.finished, r.passDone
		r.mu.Unlock()
		if finished >= target {
			return nil
		}
		select {
		case <-done:
		case <-ctx.Done():
			return ctx.Err()
		case <-r.loopDone:
			return ErrClosed
		}
	}
}

func (r *Runtime) pass() {
	r.mu.Lock()
	// This pass answers every request made before it started, so a wake
	// they left would only cause an extra pass.
	select {
	case <-r.wake:
	default:
	}
	r.started++
	r.syncing = true
	resolve := r.resolve
	r.mu.Unlock()
	r.publish()

	p, target := r.read(resolve)
	if r.ctx.Err() == nil {
		_, _ = r.cfg.store.ApplySync(r.ctx, p)
		if p.OK && target != nil {
			r.branchFor = p.Source
			r.lookUp(*target)
		}
	}
	active := false
	if a, err := r.cfg.store.Activity(r.ctx, pageSize); err == nil {
		active = isActive(a.Runs)
	}

	r.mu.Lock()
	r.syncing = false
	r.finished++
	r.lastAccess, r.lastRetry = corev1.GithubAccess(p.Access), p.RetryAfter
	r.lastServer, r.hasServer = "", false
	if target != nil {
		r.lastServer, r.hasServer = target.Account.Server.ID, true
	}
	r.active = active
	switch {
	case p.OK:
		r.live, r.failures = true, 0
	case r.lastAccess == corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE:
		r.failures++
	default:
		r.failures = 0
	}
	close(r.passDone)
	r.passDone = make(chan struct{})
	r.mu.Unlock()
	r.publish()
}

// read asks GitHub, conditionally where it can, for the default branch
// (once per target), the newest runs (and older pages to reach the cache),
// the workflows and the pull requests. target is nil when there is none.
func (r *Runtime) read(resolve Resolver) (store.Pass, *Target) {
	target, problem := resolve()
	if problem != corev1.GithubAccess_GITHUB_ACCESS_OK {
		return store.Pass{At: r.cfg.now(), Access: int32(problem)}, nil
	}
	source := target.Source()
	p := store.Pass{Source: source}
	tags, _ := r.cfg.store.ETags(r.ctx, source)
	client := target.Account.Client
	if r.branchFor != source {
		repository, err := client.Repository(r.ctx, target.Owner, target.Name)
		if err != nil {
			return r.failed(p, target, err), &target
		}
		p.DefaultBranch = repository.DefaultBranch
	}
	runs, tag, err := client.RunsIfChanged(r.ctx, target.Owner, target.Name, pageSize, tags.Runs)
	switch {
	case errors.Is(err, github.ErrNotModified):
		p.Runs = &store.RunsUpdate{NotModified: true, ETag: tags.Runs}
	case err != nil:
		return r.failed(p, target, err), &target
	default:
		update := &store.RunsUpdate{Runs: runs, Complete: len(runs) < pageSize, ETag: tag}
		if !update.Complete {
			if err := r.fillGap(client, target, update); err != nil {
				return r.failed(p, target, err), &target
			}
		}
		p.Runs = update
	}
	workflows, workflowsTag, err := client.WorkflowsIfChanged(r.ctx, target.Owner, target.Name, tags.Workflows)
	switch {
	case errors.Is(err, github.ErrNotModified):
		p.Workflows = &store.WorkflowsUpdate{NotModified: true, ETag: tags.Workflows}
	case err != nil:
		return r.failed(p, target, err), &target
	default:
		p.Workflows = &store.WorkflowsUpdate{Workflows: workflows, ETag: workflowsTag}
	}
	r.mu.Lock()
	refused := r.pullsRefused
	r.mu.Unlock()
	if !refused {
		ok := int32(corev1.GithubAccess_GITHUB_ACCESS_OK)
		pulls, pullsTag, err := client.PullRequestsIfChanged(r.ctx, target.Owner, target.Name, tags.Pulls)
		switch {
		case errors.Is(err, github.ErrNotModified):
			p.PullRequests = &store.PullRequestsUpdate{NotModified: true, ETag: tags.Pulls, Access: ok}
		case errors.Is(err, github.ErrPermissionMissing), errors.Is(err, github.ErrNotVisible):
			access, _, _ := Access(target.Account, err)
			p.PullRequests = &store.PullRequestsUpdate{Refused: true, ETag: tags.Pulls, Access: int32(access)}
			r.refusePulls()
		case err != nil:
			return r.failed(p, target, err), &target
		default:
			p.PullRequests = &store.PullRequestsUpdate{PullRequests: pulls, ETag: pullsTag, Access: ok}
		}
	}
	p.At, p.OK, p.Access = r.cfg.now(), true, int32(corev1.GithubAccess_GITHUB_ACCESS_OK)
	return p, &target
}

func (r *Runtime) refusePulls() {
	r.mu.Lock()
	r.pullsRefused = true
	r.mu.Unlock()
}

func (r *Runtime) failed(p store.Pass, target Target, err error) store.Pass {
	access, retry, _ := Access(target.Account, err)
	if access == corev1.GithubAccess_GITHUB_ACCESS_UNSPECIFIED {
		access = corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE // cancelled: the runtime is closing
	}
	p.At, p.Access, p.RetryAfter = r.cfg.now(), int32(access), retry
	return p
}

func (r *Runtime) publish() {
	if r.cfg.publish == nil {
		return
	}
	r.cfg.publish(events.Event{Type: corev1.CoreEventType_CORE_EVENT_TYPE_ACTIVITY_CHANGED, RepositoryID: r.RepositoryID()})
}

// Snapshot reads the cached activity without waiting for GitHub: every
// cached run is linked, and the newest limit are returned. Data of another
// repository than the origin's current one is never returned.
func (r *Runtime) Snapshot(ctx context.Context, limit int) (Snapshot, error) {
	r.mu.Lock()
	resolve, syncing, live, passed := r.resolve, r.syncing, r.live, r.finished > 0
	r.mu.Unlock()
	a, err := r.cfg.store.Activity(ctx, store.MaxRuns)
	if err != nil {
		return Snapshot{}, err
	}
	snap := Snapshot{Syncing: syncing, CheckedAt: a.CheckedAt}
	// The saved outcome may be from a session long ago (a token since
	// replaced): it is reported only once a pass ran in this process.
	if passed {
		snap.Access, snap.RetryAfter = corev1.GithubAccess(a.Access), a.RetryAfter
		snap.PullRequestsAccess = corev1.GithubAccess(a.PullRequestsAccess)
	}
	target, problem := resolve()
	if problem != corev1.GithubAccess_GITHUB_ACCESS_OK {
		snap.Access = problem
		return snap, nil
	}
	if !a.HasSource || a.Source != target.Source() {
		return snap, nil
	}
	window := a.Runs
	if limit > 0 && len(window) > limit {
		window = window[:limit]
	}
	in := input(a, target, r.cfg.now())
	snap.Analysis = changes.Analyze(in)
	snap.Changes = changes.Group(in, snap.Analysis, window)
	snap.Runs, snap.Workflows, snap.SyncedAt, snap.ChangedAt = window, a.Workflows, a.SyncedAt, a.ChangedAt
	snap.CachedRuns, snap.HistoryComplete = a.CachedRuns, a.HistoryComplete
	switch {
	case live:
		snap.Provenance = Live
	case len(a.Runs) > 0 || len(a.Workflows) > 0 || !a.SyncedAt.IsZero():
		snap.Provenance = Cached
	}
	return snap, nil
}

// ClearCache empties the workspace's cache and syncs again.
func (r *Runtime) ClearCache(ctx context.Context) error {
	if err := r.cfg.store.ClearCache(ctx); err != nil {
		return err
	}
	r.mu.Lock()
	r.live = false
	r.mu.Unlock()
	r.publish()
	return r.Refresh(ctx, false)
}

// credentialChanged starts a pass when the token of the server the last
// pass used changed, or when the last pass had no server (a new server may
// now match the origin), with backoff reset.
func (r *Runtime) credentialChanged(serverID string) {
	r.mu.Lock()
	match := !r.hasServer || r.lastServer == serverID
	if match {
		r.failures = 0
		r.pullsRefused = false
	}
	r.mu.Unlock()
	if match {
		_ = r.Refresh(context.Background(), false)
	}
}
