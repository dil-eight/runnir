//go:build !windows

package workspace

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"runnir/core/internal/events"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

// fakeGitHub serves o/r: the repository, runs with an ETag (and older runs
// for created=… reads), workflows, pull requests with an ETag, jobs and any
// extra paths, and counts requests per path ("?created" is added for older
// runs). gate, when set, blocks newest-runs reads until closed.
type fakeGitHub struct {
	mu          sync.Mutex
	runs        string // JSON body for /actions/runs
	etag        string
	older       string // JSON body for /actions/runs?created=…
	pulls       string // JSON body for /pulls
	pullsTag    string
	pullsStatus int               // non-zero: /pulls, /pulls/… and /commits/… answer it
	extra       map[string]string // more paths and their JSON bodies
	status      int               // non-zero: answer every request with it
	gate        chan struct{}
	requests    map[string]int
}

func newFake(t *testing.T) (*fakeGitHub, *github.Accounts) {
	t.Helper()
	f := &fakeGitHub{etag: `"v1"`, older: `{"workflow_runs":[]}`, pulls: `[]`, pullsTag: `"p1"`,
		extra: map[string]string{}, requests: map[string]int{},
		runs: `{"workflow_runs":[{"id":7,"workflow_id":3,"name":"CI","run_number":1,"run_attempt":1,"status":"completed","conclusion":"success","created_at":"2026-10-18T10:00:00Z","updated_at":"2026-10-18T10:04:00Z"}]}`}
	server := httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(server.Close)
	accounts := github.NewAccounts(server.URL, "test")
	if _, err := accounts.Set(github.Server{}, "ghu_test"); err != nil {
		t.Fatal(err)
	}
	return f, accounts
}

func (f *fakeGitHub) serve(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	older := r.URL.Query().Get("created") != ""
	f.mu.Lock()
	if older {
		f.requests[path+"?created"]++
	} else {
		f.requests[path]++
	}
	status, body, etag, gate := f.status, f.runs, f.etag, f.gate
	olderBody, pulls, pullsTag, pullsStatus := f.older, f.pulls, f.pullsTag, f.pullsStatus
	extra, hasExtra := f.extra[path]
	f.mu.Unlock()
	if status != 0 {
		w.WriteHeader(status)
		return
	}
	pullRead := path == "/repos/o/r/pulls" || strings.HasPrefix(path, "/repos/o/r/pulls/") || strings.HasPrefix(path, "/repos/o/r/commits/")
	switch {
	case path == "/repos/o/r":
		_, _ = w.Write([]byte(`{"full_name":"o/r","default_branch":"main"}`))
	case path == "/repos/o/r/actions/runs" && older:
		_, _ = w.Write([]byte(olderBody))
	case path == "/repos/o/r/actions/runs":
		if gate != nil {
			<-gate
		}
		if r.Header.Get("If-None-Match") == etag {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", etag)
		_, _ = w.Write([]byte(body))
	case path == "/repos/o/r/actions/workflows":
		_, _ = w.Write([]byte(`{"total_count":1,"workflows":[{"id":3,"name":"CI","path":".github/workflows/ci.yml","state":"active"}]}`))
	case path == "/repos/o/r/actions/runs/7/jobs":
		_, _ = w.Write([]byte(`{"jobs":[{"id":11,"name":"build","status":"completed","conclusion":"success","steps":[{"number":1,"name":"Checkout","status":"completed","conclusion":"success"}]}]}`))
	case pullRead && pullsStatus != 0:
		w.WriteHeader(pullsStatus)
		_, _ = w.Write([]byte(`{"message":"Resource not accessible by integration"}`))
	case path == "/repos/o/r/pulls" && r.URL.Query().Get("head") == "":
		if r.Header.Get("If-None-Match") == pullsTag {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", pullsTag)
		_, _ = w.Write([]byte(pulls))
	case hasExtra:
		_, _ = w.Write([]byte(extra))
	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func (f *fakeGitHub) count(path string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.requests[path]
}

func (f *fakeGitHub) set(change func(*fakeGitHub)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	change(f)
}

func fixedResolver(accounts *github.Accounts, owner, name string) Resolver {
	return func() (Target, corev1.GithubAccess) {
		account, _ := accounts.Get("")
		return Target{Account: account, Owner: owner, Name: name}, corev1.GithubAccess_GITHUB_ACCESS_OK
	}
}

// eventLog collects published events.
type eventLog struct {
	mu     sync.Mutex
	events []events.Event
	count  atomic.Int64
}

func (l *eventLog) publish(e events.Event) {
	l.mu.Lock()
	l.events = append(l.events, e)
	l.mu.Unlock()
	l.count.Add(1)
}

func testIntervals() Intervals {
	iv := DefaultIntervals()
	iv.Active, iv.Idle = time.Hour, time.Hour // no timer passes during a test
	return iv
}

func startRuntime(t *testing.T, dir string, resolve Resolver, log *eventLog) *Runtime {
	t.Helper()
	return startRuntimeWith(t, dir, resolve, log, nil)
}

// startRuntimeWith lets a test change the configuration before the loop
// starts; changing it afterwards would race with the loop.
func startRuntimeWith(t *testing.T, dir string, resolve Resolver, log *eventLog, change func(*config)) *Runtime {
	t.Helper()
	st, err := store.Open(dir, store.Options{})
	if err != nil {
		t.Fatal(err)
	}
	publish := func(events.Event) {}
	if log != nil {
		publish = log.publish
	}
	cfg := config{store: st, publish: publish, now: time.Now, intervals: testIntervals(), keepLogs: func() bool { return false }}
	if change != nil {
		change(&cfg)
	}
	r := newRuntime("5ce88ff0-5c16-43b3-8f20-8e33e852b019", "repo_1", resolve, cfg)
	r.start()
	t.Cleanup(func() { r.Close(); _ = st.Close() })
	return r
}
