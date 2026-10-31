package watch

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

const ghe = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"

// fakeGitHub serves /user and the runs of the repositories in runs, with
// an ETag; o/locked answers as an installation without Actions access and
// any other repository as not found. userStatus fails /user with a status;
// drop ends every runs request without an answer.
type fakeGitHub struct {
	mu         sync.Mutex
	login      string
	runs       map[string]string
	users      int
	userStatus int
	queries    map[string][]string
	tags       map[string][]string
	remaining  int
	reset      time.Time
	limited    bool
	drop       bool
}

func newFakeGitHub(t *testing.T, login string) (*fakeGitHub, *httptest.Server) {
	f := &fakeGitHub{login: login, runs: map[string]string{}, queries: map[string][]string{}, tags: map[string][]string{}, remaining: 5000}
	server := httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(server.Close)
	return f, server
}

func (f *fakeGitHub) serve(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if r.URL.Path == "/user" {
		f.users++
		if f.userStatus == http.StatusForbidden {
			w.Header().Set("X-RateLimit-Remaining", "0")
			w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(f.reset.Unix(), 10))
		}
		if f.userStatus != 0 {
			w.WriteHeader(f.userStatus)
			return
		}
		_, _ = fmt.Fprintf(w, `{"login":%q}`, f.login)
		return
	}
	w.Header().Set("X-RateLimit-Resource", "core")
	w.Header().Set("X-RateLimit-Limit", "5000")
	w.Header().Set("X-RateLimit-Remaining", strconv.Itoa(f.remaining))
	w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(f.reset.Unix(), 10))
	// GitHub matches names without case.
	repo := strings.ToLower(strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/repos/"), "/actions/runs"))
	f.queries[repo] = append(f.queries[repo], r.URL.RawQuery)
	f.tags[repo] = append(f.tags[repo], r.Header.Get("If-None-Match"))
	if f.drop {
		if conn, _, err := w.(http.Hijacker).Hijack(); err == nil {
			_ = conn.Close()
		}
		return
	}
	if f.limited {
		w.Header().Set("X-RateLimit-Remaining", "0")
		w.WriteHeader(http.StatusForbidden)
		return
	}
	if repo == "o/locked" {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"message":"Resource not accessible by integration"}`))
		return
	}
	body, ok := f.runs[repo]
	if !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	tag := fmt.Sprintf(`"%d"`, len(body))
	if r.Header.Get("If-None-Match") == tag {
		w.WriteHeader(http.StatusNotModified)
		return
	}
	w.Header().Set("ETag", tag)
	_, _ = w.Write([]byte(`{"workflow_runs":[` + body + `]}`))
}

func (f *fakeGitHub) requests(repo string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.queries[repo])
}

func runJSON(id, workflow int64, status, conclusion, actor string, at time.Time) string {
	stamp := at.UTC().Format(time.RFC3339)
	return fmt.Sprintf(`{"id":%d,"workflow_id":%d,"name":"CI","run_number":%d,"run_attempt":1,"status":%q,"conclusion":%q,"head_branch":"main","actor":{"login":%q},"created_at":%q,"updated_at":%q}`,
		id, workflow, id, status, conclusion, actor, stamp, stamp)
}

type fakeLocal struct {
	mu     sync.Mutex
	starts map[store.Source]map[int64][]store.RunStart
	asked  int
}

func (l *fakeLocal) Starts(_ context.Context, _ []string, source store.Source) map[int64][]store.RunStart {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.asked++
	return l.starts[source]
}

type clock struct {
	mu sync.Mutex
	at time.Time
}

func (c *clock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.at
}

func (c *clock) add(d time.Duration) {
	c.mu.Lock()
	c.at = c.at.Add(d)
	c.mu.Unlock()
}

func rig(t *testing.T) (*Watcher, *fakeGitHub, *fakeLocal, *clock, *github.Accounts) {
	f, server := newFakeGitHub(t, "ana")
	f.reset = base.Add(time.Hour)
	accounts := github.NewAccounts(server.URL, "test")
	if _, err := accounts.Set(github.Server{}, "ghu_test"); err != nil {
		t.Fatal(err)
	}
	local := &fakeLocal{starts: map[store.Source]map[int64][]store.RunStart{}}
	c := &clock{at: base}
	return New(accounts, local, c.now), f, local, c, accounts
}

func list(t *testing.T, w *Watcher, refresh bool, repos ...Repository) ([]Answer, []Pause) {
	t.Helper()
	answers, pauses, err := w.List(context.Background(), repos, refresh)
	if err != nil {
		t.Fatal(err)
	}
	return answers, pauses
}

func TestRunsAreReadByActorWithAnETagAndKeptThreeMinutes(t *testing.T) {
	w, f, _, c, _ := rig(t)
	f.runs["o/r"] = runJSON(2, 1, "completed", "failure", "ana", base.Add(-time.Hour)) + "," + runJSON(3, 2, "queued", "", "ana", base.Add(-time.Minute))
	repo := Repository{Name: "o/r"}

	answers, _ := list(t, w, false, repo)
	a := answers[0]
	if !a.Watched || a.Access != corev1.GithubAccess_GITHUB_ACCESS_OK || !slices.Equal(ids(a.Failed), []int64{2}) ||
		!slices.Equal(ids(a.Running), []int64{3}) || !a.ReadAt.Equal(base) {
		t.Fatalf("answer = %+v", a)
	}
	if q := f.queries["o/r"][0]; q != "actor=ana&per_page=50" {
		t.Fatalf("query = %q", q)
	}

	c.add(time.Minute)
	list(t, w, false, repo)
	if f.requests("o/r") != 1 {
		t.Fatal("read again within 3 minutes")
	}
	list(t, w, true, repo)
	c.add(3 * time.Minute)
	answers, _ = list(t, w, false, repo)
	if f.requests("o/r") != 3 || f.tags["o/r"][2] == "" {
		t.Fatalf("requests = %d, tags %q", f.requests("o/r"), f.tags["o/r"])
	}
	// The 304 kept the runs and counts as read.
	if len(answers[0].Failed) != 1 || !answers[0].ReadAt.Equal(base.Add(4*time.Minute)) {
		t.Fatalf("after a 304 = %+v", answers[0])
	}
	if f.users != 1 {
		t.Fatalf("GET /user = %d", f.users)
	}
}

func TestNoAccessIsAStatusAndAnUnknownRepositoryToo(t *testing.T) {
	w, _, _, _, _ := rig(t)
	answers, _ := list(t, w, false, Repository{Name: "o/gone"}, Repository{Name: "o/locked"}, Repository{Name: "not a name"})
	if answers[0].Access != corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE || answers[1].Access != corev1.GithubAccess_GITHUB_ACCESS_PERMISSION_MISSING ||
		answers[2].Access != corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE {
		t.Fatalf("answers = %+v", answers)
	}
}

func TestTheWatcherPausesBelowATenthOfTheLimit(t *testing.T) {
	defer func(n int) { readers = n }(readers)
	readers = 1
	w, f, _, c, _ := rig(t)
	for _, name := range []string{"o/a", "o/b", "o/c"} {
		f.runs[name] = runJSON(1, 1, "in_progress", "", "ana", base)
	}
	total := func() int { return f.requests("o/a") + f.requests("o/b") + f.requests("o/c") }
	all := []Repository{{Name: "o/a"}, {Name: "o/b"}, {Name: "o/c"}}
	f.remaining = 400 // of 5000
	answers, pauses := list(t, w, false, all...)
	if total() != 1 {
		t.Fatal("reads went on below a tenth of the limit")
	}
	if len(pauses) != 1 || pauses[0].ServerID != "" || !pauses[0].Until.Equal(f.reset) {
		t.Fatalf("pauses = %+v", pauses)
	}
	read := 0
	for _, a := range answers {
		if a.Access == corev1.GithubAccess_GITHUB_ACCESS_OK {
			read++
		} else if a.Access != corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED || !a.RetryAfter.Equal(f.reset) {
			t.Fatalf("an unread one = %+v", a)
		}
	}
	if read != 1 {
		t.Fatalf("answers = %+v", answers)
	}

	// After the reset the rest are read; a rate limit error pauses again.
	c.add(2 * time.Hour)
	f.remaining, f.reset = 5000, base.Add(3*time.Hour)
	list(t, w, false, all...)
	if total() != 4 {
		t.Fatal("the rest were not read after the reset")
	}
	f.limited = true
	_, pauses = list(t, w, true, all...)
	if len(pauses) != 1 || !pauses[0].Until.Equal(f.reset) || total() != 5 {
		t.Fatalf("after a rate limit error = %+v, %d", pauses, total())
	}
}

func TestOnlyTheFirstRepositoriesAreWatched(t *testing.T) {
	defer func(n int) { MaxWatched = n }(MaxWatched)
	MaxWatched = 3
	w, f, _, _, _ := rig(t)
	for _, name := range []string{"o/a", "o/b", "o/c"} {
		f.runs[name] = ""
	}
	answers, _ := list(t, w, false, Repository{Name: "o/a"}, Repository{Name: "o/b"}, Repository{Name: "o/a"}, Repository{Name: "o/c"})
	if !answers[0].Watched || !answers[1].Watched || !answers[2].Watched || answers[3].Watched || f.requests("o/c") != 0 {
		t.Fatalf("answers = %+v", answers)
	}
	if f.requests("o/a") != 1 {
		t.Fatal("a repository asked twice is read once")
	}
}

func TestAWorkspacesRepositoryIsReadFromGitHubWithItsStarts(t *testing.T) {
	w, f, local, _, _ := rig(t)
	source := store.Source{Repository: "o/r"}
	f.runs["o/r"] = runJSON(9, 1, "in_progress", "", "ana", base)
	local.starts[source] = map[int64][]store.RunStart{9: {{RunID: 9, Attempt: 1, Kind: store.StartDispatch}}, 8: {{RunID: 8, Attempt: 1}}}
	f.runs["o/quiet"] = runJSON(1, 1, "completed", "success", "ana", base)

	answers, _ := list(t, w, false, Repository{Name: "O/R", WorkspaceIDs: []string{"w"}}, Repository{Name: "o/quiet", WorkspaceIDs: []string{"w2"}})
	a := answers[0]
	if f.requests("o/r") != 1 || !slices.Equal(ids(a.Running), []int64{9}) || !a.ReadAt.Equal(base) || len(a.Starts) != 1 || len(a.Starts[9]) != 1 {
		t.Fatalf("workspace = %+v", a)
	}
	if local.asked != 1 {
		t.Fatalf("starts asked %d times; a repository with nothing listed is not read", local.asked)
	}
}

func TestAServerThatDoesNotAnswerKeepsWhatWasReadAndIsAskedOnce(t *testing.T) {
	defer func(n int) { readers = n }(readers)
	readers = 1
	w, f, _, c, _ := rig(t)
	names := []string{"o/a", "o/b", "o/c"}
	var all []Repository
	for i, name := range names {
		f.runs[name] = runJSON(int64(i+1), 1, "in_progress", "", "ana", base)
		all = append(all, Repository{Name: name})
	}
	list(t, w, false, all...)

	f.drop = true
	c.add(Reuse)
	answers, _ := list(t, w, false, all...)
	for _, a := range answers {
		if a.Access != offline || len(a.Running) != 1 || !a.ReadAt.Equal(base) {
			t.Fatalf("offline = %+v", a)
		}
	}
	asked := 0
	for _, name := range names {
		if f.requests(name) > 1 {
			asked++
		}
	}
	if asked != 1 {
		t.Fatalf("%d repositories asked after the server stopped answering", asked)
	}
}

func TestARepositoryNoLongerVisibleKeepsNothing(t *testing.T) {
	w, f, _, _, _ := rig(t)
	f.runs["o/r"] = runJSON(1, 1, "in_progress", "", "ana", base)
	list(t, w, false, Repository{Name: "o/r"})
	delete(f.runs, "o/r")
	answers, _ := list(t, w, true, Repository{Name: "o/r"})
	if a := answers[0]; a.Access != invisible || len(a.Running) != 0 || !a.ReadAt.IsZero() {
		t.Fatalf("gone = %+v", a)
	}
}

func TestARepositoryNoLongerAskedForIsForgotten(t *testing.T) {
	w, f, _, _, _ := rig(t)
	f.runs["o/r"] = runJSON(1, 1, "in_progress", "", "ana", base)
	f.runs["o/s"] = ""
	list(t, w, false, Repository{Name: "o/r"})
	list(t, w, false, Repository{Name: "o/s"})
	answers, _ := list(t, w, false, Repository{Name: "o/r"})
	if f.requests("o/r") != 2 || f.tags["o/r"][1] != "" || len(answers[0].Running) != 1 {
		t.Fatalf("requests = %d, tags %q", f.requests("o/r"), f.tags["o/r"])
	}
}

func TestWhatWasReadStaysWhenGitHubDoesNotSayWhoIsSignedIn(t *testing.T) {
	w, f, _, _, accounts := rig(t)
	f.runs["o/r"] = runJSON(1, 1, "in_progress", "", "ana", base)
	list(t, w, false, Repository{Name: "o/r"})
	// A new token is read with GET /user again.
	if _, err := accounts.Set(github.Server{}, "ghu_new"); err != nil {
		t.Fatal(err)
	}

	f.userStatus = http.StatusBadGateway
	answers, pauses := list(t, w, true, Repository{Name: "o/r"})
	if a := answers[0]; a.Access != offline || len(a.Running) != 1 || !a.ReadAt.Equal(base) || len(pauses) != 0 {
		t.Fatalf("offline = %+v, %+v", a, pauses)
	}

	f.userStatus = http.StatusForbidden
	answers, pauses = list(t, w, true, Repository{Name: "o/r"})
	if a := answers[0]; a.Access != limited || len(a.Running) != 1 || len(pauses) != 1 || !pauses[0].Until.Equal(f.reset) {
		t.Fatalf("rate limited = %+v, %+v", a, pauses)
	}
	if f.requests("o/r") != 1 {
		t.Fatalf("runs read %d times without a login", f.requests("o/r"))
	}
}

func TestEachServerHasItsLoginAndASignedOutOneIsNotAsked(t *testing.T) {
	w, f, _, _, accounts := rig(t)
	f.runs["o/r"] = runJSON(1, 1, "in_progress", "", "ana", base)
	other, server := newFakeGitHub(t, "ana-ghe")
	other.reset = base.Add(time.Hour)
	other.runs["corp/app"] = runJSON(2, 1, "in_progress", "", "ana-ghe", base)
	if _, err := accounts.Set(github.Server{ID: ghe, APIURL: server.URL, WebHost: "ghe.test"}, "ghp_corp"); err != nil {
		t.Fatal(err)
	}
	answers, _ := list(t, w, false, Repository{Name: "o/r"}, Repository{ServerID: ghe, Name: "corp/app"},
		Repository{ServerID: "2b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed", Name: "x/y"})
	if len(answers[0].Running) != 1 || len(answers[1].Running) != 1 || other.queries["corp/app"][0] != "actor=ana-ghe&per_page=50" {
		t.Fatalf("answers = %+v, query %q", answers, other.queries["corp/app"])
	}
	if answers[2].Access != corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT {
		t.Fatalf("unknown server = %+v", answers[2])
	}
	accounts.Clear("")
	answers, _ = list(t, w, true, Repository{Name: "o/r"})
	if answers[0].Access != corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT || f.requests("o/r") != 1 {
		t.Fatalf("signed out = %+v, %d requests", answers[0], f.requests("o/r"))
	}
}
