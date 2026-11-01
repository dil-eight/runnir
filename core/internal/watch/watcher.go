package watch

import (
	"context"
	"errors"
	"maps"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/parallel"
	"runnir/core/internal/store"
	"runnir/core/internal/workspace"
)

// Bounds of the watcher; variables so tests can lower them.
var (
	// MaxWatched repositories are read; the rest are answered unwatched.
	MaxWatched = 100
	// Reuse: a repository read this recently answers from memory, and a
	// server that gave no login this recently is not asked again.
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

// Watcher reads the signed-in user's runs of the watched repositories, and
// keeps what it read in memory only. A workspace's saved runs are not used:
// its sync refreshes only its newest runs, so an older saved one can stay in
// progress. Safe for concurrent use.
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
	// users is who is signed in to each server, as GET /user said.
	users map[string]*user
}

// user is what the watcher knows of who is signed in to a server.
type user struct {
	// signIn and generation are the credential's at the last GET /user.
	signIn, generation uint64
	// name is the sign-in's login; "" until GET /user answered for it.
	name string
	// access and retry are the last GET /user's outcome, at askedAt.
	access  corev1.GithubAccess
	retry   time.Time
	askedAt time.Time
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

// login is who is signed in to a server for one call: name is "" when
// GitHub has not said for this sign-in.
type login struct {
	name   string
	access corev1.GithubAccess
	retry  time.Time
}

func New(accounts *github.Accounts, local Local, now func() time.Time) *Watcher {
	if now == nil {
		now = time.Now
	}
	return &Watcher{accounts: accounts, local: local, now: now, read: map[string]*entry{}, paused: map[string]time.Time{}, users: map[string]*user{}}
}

// List answers each repository, in order, and the servers paused. A
// repository is read from GitHub when it was not read in the last Reuse,
// or with refresh. The only error is the call's context ending.
func (w *Watcher) List(ctx context.Context, repositories []Repository, refresh bool) ([]Answer, []Pause, error) {
	w.call.Lock()
	defer w.call.Unlock()
	now := w.now()
	out := make([]Answer, len(repositories))
	accounts := make([]*github.Account, len(repositories))
	servers := map[string]*github.Account{}
	for i, r := range repositories {
		if i >= MaxWatched {
			continue
		}
		out[i].Watched = true
		if !github.ValidRepository(r.Name) {
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
		accounts[i], servers[r.ServerID] = account, account
	}
	logins, err := w.signIns(ctx, servers, now, refresh)
	if err != nil {
		return nil, nil, err
	}

	keys := make([]string, len(repositories))
	sources := make([]store.Source, len(repositories))
	queued := map[string]bool{}
	var jobs []job
	for i, r := range repositories {
		account := accounts[i]
		if account == nil {
			continue
		}
		owner, name, _ := strings.Cut(r.Name, "/")
		source := store.SourceOf(r.ServerID, owner, name)
		key := r.ServerID + "\x00" + source.Repository
		user := logins[r.ServerID]
		switch user.access {
		case accessOK:
		case offline, limited:
			// GitHub did not say who is signed in: what was read stays.
			sources[i], keys[i], queued[key] = source, key, true
			continue
		default:
			out[i].Access, out[i].RetryAfter = user.access, user.retry
			continue
		}
		sources[i], keys[i] = source, key
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
		if user := logins[repositories[i].ServerID]; user.access != accessOK {
			out[i].Access, out[i].RetryAfter = user.access, user.retry
			// Only the runs of this sign-in's login, once GitHub said it.
			if e != nil && user.name != "" && e.login == user.name {
				out[i].ReadAt = e.readAt
				out[i].Failed, out[i].Running = Pick(e.runs, e.login, now)
			}
			continue
		}
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

// signIns asks every server who is signed in, all at once, so a server
// that does not answer holds up no other. The only error is the call's
// context ending.
func (w *Watcher) signIns(ctx context.Context, accounts map[string]*github.Account, now time.Time, refresh bool) (map[string]login, error) {
	servers := slices.Sorted(maps.Keys(accounts))
	logins := make([]login, len(servers))
	errs := make([]error, len(servers))
	parallel.Each(len(servers), len(servers), func(i int) {
		logins[i], errs[i] = w.signedIn(ctx, servers[i], accounts[servers[i]], now, refresh)
	})
	out := make(map[string]login, len(servers))
	for i, server := range servers {
		if errs[i] != nil {
			return nil, errs[i]
		}
		out[server] = logins[i]
	}
	return out, nil
}

// signedIn is who is signed in to a server. GET /user is asked once per
// token; a failed ask stands for Reuse unless refresh, and a paused server
// is not asked. Another sign-in forgets the login of the one before, so its
// runs are not shown for it.
func (w *Watcher) signedIn(ctx context.Context, serverID string, account *github.Account, now time.Time, refresh bool) (login, error) {
	signIn, generation := account.Credential.SignIn(), account.Credential.Generation()
	w.mu.Lock()
	u := w.users[serverID]
	if u == nil || u.signIn != signIn {
		u = &user{signIn: signIn}
		w.users[serverID] = u
	}
	asked := u.generation == generation && !u.askedAt.IsZero()
	askedAt, known := u.askedAt, login{name: u.name, access: u.access, retry: u.retry}
	until := w.paused[serverID]
	w.mu.Unlock()
	switch {
	case asked && known.access == accessOK:
		return known, nil
	case now.Before(until):
		known.access, known.retry = limited, until
		return known, nil
	case asked && !refresh && now.Sub(askedAt) < Reuse:
		return known, nil
	}

	name, err := account.Client.Login(ctx)
	access, retry, cancelled := workspace.Access(account, err)
	if cancelled != nil {
		return login{}, cancelled
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if access == accessOK {
		u.name = name
	}
	if access == limited {
		w.paused[serverID] = retry
	}
	u.generation, u.access, u.retry, u.askedAt = generation, access, retry, now
	return login{name: u.name, access: access, retry: retry}, nil
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

// readAll reads the jobs, at most readers at once. down are the servers
// that did not answer a read of this call: their other repositories are not
// asked, so one unreachable server does not hold up the call.
func (w *Watcher) readAll(ctx context.Context, jobs []job, now time.Time) {
	down := map[string]bool{}
	parallel.Each(len(jobs), readers, func(i int) {
		if w.mayRead(jobs[i], now, down) {
			w.readOne(ctx, jobs[i], now, down)
		}
	})
}

// mayRead: the server answered this call, is not paused, and more than a
// tenth of its rate limit is left; below that it is paused until the limit
// resets. A repository of a server down keeps what was read, as offline,
// and counts as asked, as the one that got no answer does.
func (w *Watcher) mayRead(j job, now time.Time, down map[string]bool) bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	if down[j.serverID] {
		e := w.read[j.key]
		e.access, e.retry, e.checkedAt = offline, time.Time{}, now
		return false
	}
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

func (w *Watcher) readOne(ctx context.Context, j job, now time.Time, down map[string]bool) {
	runs, tag, err := j.account.Client.ActorRunsIfChanged(ctx, j.owner, j.name, j.login, pageSize, j.etag)
	access, retry, cancelled := workspace.Access(j.account, err)
	if cancelled != nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if errors.Is(err, github.ErrUnreachable) {
		down[j.serverID] = true
	}
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
	var listed []int
	for i, a := range out {
		if len(a.Failed)+len(a.Running) > 0 && len(repositories[i].WorkspaceIDs) > 0 {
			listed = append(listed, i)
		}
	}
	parallel.Each(len(listed), readers, func(n int) {
		i := listed[n]
		a := &out[i]
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
	})
}
