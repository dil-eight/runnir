package watch

import (
	"context"
	"errors"
	"sort"
	"strings"
	"sync"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
	"runnir/core/internal/workspace"
)

// Bounds of the watcher; variables so tests can lower them.
var (
	// MaxWatched repositories are read; the rest are answered unwatched.
	MaxWatched = 100
	// Reuse: a repository read this recently answers from memory.
	Reuse = 3 * time.Minute
	// readers is how many repositories are read at once.
	readers = 4
)

// pageSize is how many of the user's newest runs one read asks for.
const pageSize = 50

const (
	accessOK  = corev1.GithubAccess_GITHUB_ACCESS_OK
	limited   = corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED
	offline   = corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE
	signedOut = corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT
	invisible = corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE
)

// Repository is one repository the app watches.
type Repository struct {
	// ServerID is "" for github.com.
	ServerID string
	// Name is "owner/name".
	Name string
	// WorkspaceIDs are the registered workspaces linked to it; none for a
	// starred repository without one.
	WorkspaceIDs []string
}

// Local is what the watcher reads on this Mac: workspace.Runtimes.
type Local interface {
	OpenRuns(ctx context.Context, ids []string, source store.Source, actor string, limit int) ([]github.Run, time.Time, bool)
	Starts(ctx context.Context, ids []string, source store.Source) map[int64][]store.RunStart
}

// Answer is one repository's failed and running runs.
type Answer struct {
	Access     corev1.GithubAccess
	RetryAfter time.Time
	// Watched is false beyond MaxWatched: nothing was read.
	Watched bool
	Failed  []github.Run
	Running []github.Run
	// Starts are the attempts Runnir started of these runs, by run (B46).
	Starts map[int64][]store.RunStart
	// ReadAt is when the runs were read; zero for never.
	ReadAt time.Time
}

// Pause is a server the watcher reads nothing from until a time, to keep
// its rate limit.
type Pause struct {
	ServerID string
	Until    time.Time
}

// Watcher reads the signed-in user's runs of the watched repositories that
// have no workspace open, and keeps what it read in memory only. Safe for
// concurrent use.
type Watcher struct {
	accounts *github.Accounts
	local    Local
	now      func() time.Time

	// call takes List calls one at a time: a second one answers from what
	// the first read.
	call sync.Mutex

	mu     sync.Mutex
	read   map[string]*entry
	paused map[string]time.Time
}

// entry is what the watcher keeps of one repository read from GitHub.
type entry struct {
	// login the runs are of; another sign-in starts over.
	login     string
	etag      string
	runs      []github.Run
	readAt    time.Time
	checkedAt time.Time
	access    corev1.GithubAccess
	retry     time.Time
}

// job is one repository to read from GitHub in a call.
type job struct {
	key, serverID, owner, name, login, etag string
	account                                 *github.Account
}

type login struct {
	name   string
	access corev1.GithubAccess
	retry  time.Time
}

func New(accounts *github.Accounts, local Local, now func() time.Time) *Watcher {
	if now == nil {
		now = time.Now
	}
	return &Watcher{accounts: accounts, local: local, now: now, read: map[string]*entry{}, paused: map[string]time.Time{}}
}

// List answers each repository, in order, and the servers paused. An open
// workspace of a repository answers from its store; any other repository
// is read from GitHub when it was not read in the last Reuse, or with
// refresh. The only error is the call's context ending.
func (w *Watcher) List(ctx context.Context, repositories []Repository, refresh bool) ([]Answer, []Pause, error) {
	w.call.Lock()
	defer w.call.Unlock()
	now := w.now()
	out := make([]Answer, len(repositories))
	keys := make([]string, len(repositories))
	sources := make([]store.Source, len(repositories))
	logins := map[string]login{}
	queued := map[string]bool{}
	var jobs []job
	for i, r := range repositories {
		if i >= MaxWatched {
			continue
		}
		out[i].Watched = true
		owner, name, ok := split(r.Name)
		if !ok {
			out[i].Access = invisible
			continue
		}
		account, ok := w.accounts.Get(r.ServerID)
		if !ok {
			out[i].Access = signedOut
			continue
		}
		if _, ok := account.Credential.Token(); !ok {
			out[i].Access = signedOut
			continue
		}
		user, ok := logins[r.ServerID]
		if !ok {
			read, err := account.Client.Login(ctx)
			access, retry, cancelled := workspace.Access(account, err)
			if cancelled != nil {
				return nil, nil, cancelled
			}
			user = login{name: read, access: access, retry: retry}
			logins[r.ServerID] = user
		}
		if user.access != accessOK {
			out[i].Access, out[i].RetryAfter = user.access, user.retry
			continue
		}
		source := store.Source{ServerID: r.ServerID, Repository: strings.ToLower(owner + "/" + name)}
		sources[i] = source
		if runs, readAt, ok := w.local.OpenRuns(ctx, r.WorkspaceIDs, source, user.name, pageSize); ok {
			out[i].Access, out[i].ReadAt = accessOK, readAt
			out[i].Failed, out[i].Running = Pick(runs, user.name, now)
			continue
		}
		key := r.ServerID + "\x00" + source.Repository
		keys[i] = key
		if queued[key] {
			continue
		}
		queued[key] = true
		checked, etag := w.entry(key, user.name)
		if refresh || checked.IsZero() || now.Sub(checked) >= Reuse {
			jobs = append(jobs, job{key: key, serverID: r.ServerID, owner: owner, name: name, login: user.name, etag: etag, account: account})
		}
	}
	w.readAll(ctx, jobs, now)
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}

	w.mu.Lock()
	for i, key := range keys {
		if key == "" {
			continue
		}
		e := w.read[key]
		out[i].Access, out[i].RetryAfter, out[i].ReadAt = e.access, e.retry, e.readAt
		if until, paused := w.paused[repositories[i].ServerID]; paused && e.access == corev1.GithubAccess_GITHUB_ACCESS_UNSPECIFIED {
			// Never read: the pause held it back.
			out[i].Access, out[i].RetryAfter = limited, until
		}
		out[i].Failed, out[i].Running = Pick(e.runs, e.login, now)
	}
	// What the app no longer watches is forgotten.
	for key := range w.read {
		if !queued[key] {
			delete(w.read, key)
		}
	}
	pauses := w.pauses(now, repositories)
	w.mu.Unlock()

	w.addStarts(ctx, repositories, sources, out)
	return out, pauses, nil
}

// entry returns when key was last checked and its ETag; an entry of
// another login starts over.
func (w *Watcher) entry(key, login string) (time.Time, string) {
	w.mu.Lock()
	defer w.mu.Unlock()
	e := w.read[key]
	if e == nil || e.login != login {
		e = &entry{login: login}
		w.read[key] = e
	}
	return e.checkedAt, e.etag
}

func (w *Watcher) readAll(ctx context.Context, jobs []job, now time.Time) {
	var wg sync.WaitGroup
	slots := make(chan struct{}, readers)
	for _, j := range jobs {
		wg.Add(1)
		go func() {
			defer wg.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			if w.mayRead(j, now) {
				w.readOne(ctx, j, now)
			}
		}()
	}
	wg.Wait()
}

// mayRead: the server is not paused, and more than a tenth of its rate
// limit is left; otherwise it is paused until the limit resets.
func (w *Watcher) mayRead(j job, now time.Time) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if until, ok := w.paused[j.serverID]; ok && now.Before(until) {
		return false
	}
	rate := j.account.Client.RateLimit()
	if rate.Limit > 0 && rate.Remaining*10 < rate.Limit && rate.Reset.After(now) {
		w.paused[j.serverID] = rate.Reset
		return false
	}
	return true
}

func (w *Watcher) readOne(ctx context.Context, j job, now time.Time) {
	runs, tag, err := j.account.Client.ActorRunsIfChanged(ctx, j.owner, j.name, j.login, pageSize, j.etag)
	access, retry, cancelled := workspace.Access(j.account, err)
	if cancelled != nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	e := w.read[j.key]
	switch {
	case err == nil:
		e.runs, e.etag, e.readAt, e.checkedAt = runs, tag, now, now
	case errors.Is(err, github.ErrNotModified):
		e.readAt, e.checkedAt = now, now
	case access == limited:
		// Read again once the pause ends; what was read stays.
		w.paused[j.serverID] = retry
	case access == offline:
		// Offline: what was read stays, labelled with when.
		e.checkedAt = now
	default:
		// No access any more: nothing of it is kept.
		e.runs, e.etag, e.readAt, e.checkedAt = nil, "", time.Time{}, now
	}
	e.access, e.retry = access, retry
}

// pauses lists the paused servers of the repositories asked for; pauses
// that ended are dropped. Caller holds mu.
func (w *Watcher) pauses(now time.Time, repositories []Repository) []Pause {
	asked := map[string]bool{}
	for _, r := range repositories {
		asked[r.ServerID] = true
	}
	var out []Pause
	for server, until := range w.paused {
		if !now.Before(until) {
			delete(w.paused, server)
			continue
		}
		if asked[server] {
			out = append(out, Pause{ServerID: server, Until: until})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ServerID < out[j].ServerID })
	return out
}

// addStarts joins Runnir's starts of the listed runs from the repository's
// workspaces, only where a run is listed, at most readers at once.
func (w *Watcher) addStarts(ctx context.Context, repositories []Repository, sources []store.Source, out []Answer) {
	var wg sync.WaitGroup
	slots := make(chan struct{}, readers)
	for i := range out {
		a := &out[i]
		if len(a.Failed)+len(a.Running) == 0 || len(repositories[i].WorkspaceIDs) == 0 {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			all := w.local.Starts(ctx, repositories[i].WorkspaceIDs, sources[i])
			for _, list := range [][]github.Run{a.Failed, a.Running} {
				for _, r := range list {
					if starts := all[r.ID]; len(starts) > 0 {
						if a.Starts == nil {
							a.Starts = map[int64][]store.RunStart{}
						}
						a.Starts[r.ID] = starts
					}
				}
			}
		}()
	}
	wg.Wait()
}

// split reads "owner/name".
func split(full string) (string, string, bool) {
	owner, name, ok := strings.Cut(full, "/")
	if !ok || owner == "" || name == "" || strings.Contains(name, "/") || strings.ContainsAny(full, " \t\n?#") {
		return "", "", false
	}
	return owner, name, true
}
