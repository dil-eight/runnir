# Runs Across Repositories (B39) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Runs tab beside Pull requests, in the menu bar window and the Pull Requests window, lists the signed-in user's failed and running runs across registered workspaces and starred repositories.

**Architecture:**
- **The rules live in the Core.** A new package, `core/internal/watch`, holds:
  - `Pick`, the rule that picks the failed and running runs, with no I/O;
  - the `Watcher`, which reads the repositories.
- **How the Watcher reads.**
  - An open workspace answers from its store.
  - Every other repository is read from GitHub with one conditional request (`actor`, ETag), at most every 3 minutes, and kept in memory.
  - The Watcher pauses a server when less than a tenth of its rate limit is left.
  - The starts of B46 are joined from every workspace of a repository: open ones from their store, closed ones from their database read-only.
- **The contract.** One RPC, `ListWatchedRuns`.
- **The app.**
  - A model asks the Core every 3 minutes, like the pull requests model.
  - A tab control switches the menu and the window between the two lists.
  - The menu bar dot shows the worse of the pull request checks and the runs.

**Tech Stack:**
- Go 1.27: pure Go, `CGO_ENABLED=0`, SQLite through the existing store.
- protobuf/gRPC: buf, swift-protobuf 1.39.0, grpc-swift-protobuf 2.5.0.
- Swift 6, SwiftUI, Observation, Swift Testing.

## Global Constraints

- **Sources.**
  - Spec: `docs/superpowers/specs/2026-10-29-runs-across-repositories-design.md`.
  - Pen: `docs/design/runnir.pen`, journey F, Row — Runs across repositories (B39).
- **Bounds.**
  - At most 100 repositories are watched (`watch.MaxWatched`).
  - A repository read less than 3 minutes ago answers from memory (`watch.Reuse`), unless the call asks for `refresh`.
  - At most 4 repositories are read at once.
  - A read asks for 50 runs.
  - A failed run is listed for 7 days after it finished (`watch.FailedFor`).
  - A server is paused when fewer than 10% of its requests are left.
  - A request carries at most 1000 repositories.
- **B27.** Nothing is written to a closed workspace's database. It is opened only with `store.OpenReadOnly` under the runtimes' `claim`.
- **No backward compatibility.** The contract changes in place (AGENTS.md, before the first release tag).
- **Nothing else added.** No new dependencies, no telemetry. Tokens stay only in memory in the Core and in Keychain in the app.
- **Text.** UI text is in English, with `·` as U+00B7. Exact strings:
  - tabs: "Pull requests", "Runs"; window titles "Pull Requests", "Runs";
  - "Updated just now · 14 repositories";
  - chips "N failed", "N running";
  - sections "FAILED", "RUNNING";
  - row prefix "From Runnir · ";
  - row subtitle "owner/name · branch · failed 4 minutes ago", or "timed out …", "started …", "queued …", "waiting …";
  - hover "Open in <workspace name>" / "Open on GitHub", and "Remove from this list";
  - "1 repository skipped: Runnir can't read its Actions." / "N repositories skipped: Runnir can't read their Actions.";
  - "Watching 100 of 130 repositories: workspaces first, then starred ones in the order you starred them.";
  - "No failed or running runs" with "Your runs in 9 workspaces and 5 starred repositories.";
  - "Nothing to watch yet" with "Star repositories in the Workspace Manager's GitHub tab, or link a workspace to its GitHub repository, to see your failed and running runs here." and the button "Open Workspace Manager";
  - "Paused until 14:05 to keep the GitHub rate limit. These runs were read at 13:40.";
  - "GitHub can't be reached. These runs were read at 13:40.";
  - footer "Open Runs Window" with the shortcut, and "Show Removed (N)";
  - menu bar label "Runnir, a run failed, checks running".
- **No AI attribution.** None in commits, code, docs or PRs: no `Co-Authored-By`, no "Generated with".
- **Go for Xcode.** Xcode builds need Go 1.27.3 on the PATH. Run this before `xcodebuild`:
  `export PATH="$HOME/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.27.3.darwin-arm64/bin:$PATH"`
- **Contract plugins.**
  - Copy the plugins into this session's scratchpad once:
    `mkdir -p "$SCRATCH/bin" && cp /private/tmp/claude-502/-Users-dilbarov-projects-runnir/a77a3c7d-9a6c-4612-8758-e0ea3aa9f7d9/scratchpad/bin/protoc-gen-* "$SCRATCH/bin/"`
    (`$SCRATCH` is this session's scratchpad directory; `protoc-gen-swift --version` must say 1.39.0).
  - Then generate from the repository root:
    `PATH="$HOME/go/bin:$SCRATCH/bin:$PATH" scripts/generate-contracts.sh`.
- **New Swift files.** The Xcode project has no synchronized folders. Task 8 adds three files to `project.pbxproj` by hand with the ids given there.
- **Checks before handoff.**
  - From `core/`: `go test ./...`, `go vet ./...`, `go build ./...`.
  - From the repository root:
    - `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build`;
    - the same with `test -only-testing:RunnirTests` in place of `build`.

---

## File Structure

| File | Responsibility |
| --- | --- |
| `core/internal/watch/pick.go` (new) | `Pick`: the failed and running runs of one repository |
| `core/internal/watch/watcher.go` (new) | `Watcher`: which repositories to read, the ETags, the 3 minutes, the budget, the pause, the starts |
| `core/internal/github/client.go` | The core rate limit of the latest answer, the login once per token, runs by actor with an ETag |
| `core/internal/github/credential.go` | A generation that changes with the token |
| `core/internal/store/watched.go` (new) | `WatchedRuns`: an actor's newest saved runs and when a pass last reached GitHub |
| `core/internal/workspace/watched.go` (new) | `OpenRuns` and `Starts` over open and closed workspaces |
| `contracts/grpc/runnir/core/v1/runnir_core.proto` | `ListWatchedRuns` and its messages |
| `core/internal/server/watched.go` (new) | The RPC handler |
| `apps/macos/Runnir/IPC/*` | The Swift models, the protocol method, the gRPC mapping, `CoreHub.watchedRuns` |
| `apps/macos/Runnir/Features/Desktop/WatchedRuns.swift` (new) | Which repositories, `WatchedRunsModel`, the tab, the texts |
| `apps/macos/Runnir/Features/Desktop/WatchedRunsViews.swift` (new) | The tab control, the Runs list and its rows |
| `apps/macos/Runnir/Features/Desktop/PullRequestsViews.swift` | `FileDismissalStore`, shared chip, section header and remove button, the tabs in the menu and the window |
| `apps/macos/Runnir/Features/Desktop/MenuBarIcon.swift` | The dot and label from both lists |
| `apps/macos/Runnir/App/Desktop/DesktopCoordinator.swift`, `RunnirApp.swift` | The model, what is watched, opening a run, polling, the icon |

---

### Task 1: The rules (`watch.Pick`)

**Files:**
- Create: `core/internal/watch/pick.go`
- Test: `core/internal/watch/pick_test.go`

**Interfaces:**
- Consumes: `github.Run`, `runsearch.StatusOf(status, conclusion string) runsearch.Status`, `runsearch.Failed`.
- Produces:
  - `func Pick(runs []github.Run, login string, now time.Time) (failed, running []github.Run)`;
  - `const FailedFor = 7 * 24 * time.Hour`.

- [ ] **Step 1: Write the failing test**

```go
package watch

import (
	"slices"
	"testing"
	"time"

	"runnir/core/internal/github"
)

var base = time.Date(2026, 10, 29, 12, 0, 0, 0, time.UTC)

func run(id, workflow int64, branch, status, conclusion string, created time.Time) github.Run {
	return github.Run{ID: id, WorkflowID: workflow, Branch: branch, Status: status, Conclusion: conclusion, Actor: "Ana",
		RunAttempt: 1, CreatedAt: created, UpdatedAt: created.Add(5 * time.Minute)}
}

func ids(runs []github.Run) []int64 {
	out := make([]int64, len(runs))
	for i, r := range runs {
		out[i] = r.ID
	}
	return out
}

func TestTheNewestFinishedRunOfAWorkflowOnABranchDecides(t *testing.T) {
	h := time.Hour
	runs := []github.Run{
		run(1, 10, "main", "completed", "failure", base.Add(-3*h)), // fixed by 2
		run(2, 10, "main", "completed", "success", base.Add(-2*h)),
		run(3, 10, "dev", "completed", "timed_out", base.Add(-2*h)), // another branch: listed
		run(4, 11, "main", "completed", "failure", base.Add(-4*h)),  // a later run was cancelled
		run(5, 11, "main", "completed", "cancelled", base.Add(-1*h)),
		run(6, 12, "main", "completed", "startup_failure", base.Add(-1*h)), // listed
		run(7, 13, "main", "completed", "failure", base.Add(-8*24*h)),      // 8 days ago
		run(8, 14, "main", "completed", "failure", base.Add(-5*h)),         // a later run was skipped
		run(9, 14, "main", "completed", "skipped", base.Add(-4*h)),
	}
	failed, running := Pick(runs, "ana", base)
	if got := ids(failed); !slices.Equal(got, []int64{6, 3}) {
		t.Fatalf("failed = %v", got)
	}
	if len(running) != 0 {
		t.Fatalf("running = %v", ids(running))
	}
}

func TestARerunThatPassedListsNothing(t *testing.T) {
	rerun := run(1, 10, "main", "completed", "success", base.Add(-time.Hour))
	rerun.RunAttempt = 2
	if failed, _ := Pick([]github.Run{rerun}, "ana", base); len(failed) != 0 {
		t.Fatalf("failed = %v", ids(failed))
	}
}

func TestRunningIsEveryRunNotCompleted(t *testing.T) {
	m := time.Minute
	runs := []github.Run{
		run(1, 10, "main", "queued", "", base.Add(-5*m)),
		run(2, 10, "main", "in_progress", "", base.Add(-1*m)),
		run(3, 11, "main", "waiting", "", base.Add(-4*m)),
		run(4, 12, "main", "requested", "", base.Add(-3*m)),
		run(5, 13, "main", "pending", "", base.Add(-2*m)),
		run(6, 14, "main", "completed", "action_required", base.Add(-6*m)),
	}
	failed, running := Pick(runs, "ana", base)
	if got := ids(running); !slices.Equal(got, []int64{2, 5, 4, 3, 1}) {
		t.Fatalf("running = %v", got)
	}
	if len(failed) != 0 {
		t.Fatalf("failed = %v", ids(failed))
	}
}

func TestOnlyTheLoginsRunsWhateverItsCase(t *testing.T) {
	theirs := run(1, 10, "main", "completed", "failure", base.Add(-time.Hour))
	theirs.Actor = "bo"
	mine := run(2, 11, "main", "in_progress", "", base.Add(-time.Hour))
	failed, running := Pick([]github.Run{theirs, mine}, "ANA", base)
	if len(failed) != 0 || !slices.Equal(ids(running), []int64{2}) {
		t.Fatalf("failed = %v, running = %v", ids(failed), ids(running))
	}
	if failed, running := Pick([]github.Run{theirs, mine}, "", base); len(failed)+len(running) != 0 {
		t.Fatal("no login lists nothing")
	}
}

func TestFailedRunsAreNewestFirstByTheirUpdate(t *testing.T) {
	early := run(1, 10, "main", "completed", "failure", base.Add(-3*time.Hour))
	early.UpdatedAt = base.Add(-10 * time.Minute) // re-run later, failed again
	late := run(2, 11, "main", "completed", "failure", base.Add(-time.Hour))
	if failed, _ := Pick([]github.Run{late, early}, "ana", base); !slices.Equal(ids(failed), []int64{1, 2}) {
		t.Fatalf("failed = %v", ids(failed))
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd core && go test ./internal/watch/`
Expected: FAIL, `undefined: Pick`.

- [ ] **Step 3: Write the implementation**

```go
// Package watch keeps the signed-in user's failed and running runs of the
// repositories the app watches (B39): the rule that picks them, apart from
// any I/O, and the watcher that reads them.
package watch

import (
	"sort"
	"strings"
	"time"

	"runnir/core/internal/github"
	"runnir/core/internal/runsearch"
)

// FailedFor is how long a failed run stays listed after it finished.
const FailedFor = 7 * 24 * time.Hour

// Pick returns the failed and the running runs that login started, of one
// repository. A run is running while it is not completed. A workflow on a
// branch is failed when its newest finished run is in the Failed group and
// finished within FailedFor of now: a later run that passed, was cancelled
// or was skipped, or a re-run that passed, lists nothing. Failed runs come
// newest first by UpdatedAt, running ones by CreatedAt.
func Pick(runs []github.Run, login string, now time.Time) (failed, running []github.Run) {
	type group struct {
		workflow int64
		branch   string
	}
	newest := map[group]github.Run{}
	for _, r := range runs {
		if login == "" || !strings.EqualFold(r.Actor, login) {
			continue
		}
		if r.Status != "completed" {
			running = append(running, r)
			continue
		}
		key := group{r.WorkflowID, r.Branch}
		if kept, ok := newest[key]; !ok || later(r.CreatedAt, r.ID, kept.CreatedAt, kept.ID) {
			newest[key] = r
		}
	}
	for _, r := range newest {
		if runsearch.StatusOf(r.Status, r.Conclusion) == runsearch.Failed && now.Sub(r.UpdatedAt) <= FailedFor {
			failed = append(failed, r)
		}
	}
	sort.Slice(failed, func(i, j int) bool {
		return later(failed[i].UpdatedAt, failed[i].ID, failed[j].UpdatedAt, failed[j].ID)
	})
	sort.Slice(running, func(i, j int) bool {
		return later(running[i].CreatedAt, running[i].ID, running[j].CreatedAt, running[j].ID)
	})
	return failed, running
}

// later: a is after b, the higher id on a tie.
func later(a time.Time, idA int64, b time.Time, idB int64) bool {
	if !a.Equal(b) {
		return a.After(b)
	}
	return idA > idB
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd core && go test ./internal/watch/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/watch
git commit -m "Core: the rule that picks the user's failed and running runs of a repository (B39)"
```

---

### Task 2: The GitHub client — rate limit, login and runs by actor

**Files:**
- Modify: `core/internal/github/credential.go`
- Modify: `core/internal/github/client.go`
- Test: `core/internal/github/client_test.go`

**Interfaces:**
- Produces:
  - `func (c *Credential) Generation() uint64`;
  - `type RateLimit struct { Remaining, Limit int; Reset time.Time }`;
  - `func (c *Client) RateLimit() RateLimit`;
  - `func (c *Client) Login(ctx context.Context) (string, error)`;
  - `func (c *Client) ActorRunsIfChanged(ctx context.Context, owner, name, actor string, limit int, etag string) ([]Run, string, error)`.

- [ ] **Step 1: Write the failing tests** (append to `client_test.go`; it already imports `net/http`, `net/http/httptest`, `testing`, `time`, `context`; add any that are missing)

```go
func TestTheCoreRateLimitOfTheLatestAnswerIsKept(t *testing.T) {
	reset := time.Date(2026, 10, 29, 13, 0, 0, 0, time.UTC)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		resource, remaining := "core", "4200"
		if r.URL.Path == "/search/issues" {
			resource, remaining = "search", "3"
		}
		w.Header().Set("X-RateLimit-Resource", resource)
		w.Header().Set("X-RateLimit-Limit", "5000")
		w.Header().Set("X-RateLimit-Remaining", remaining)
		w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(reset.Unix(), 10))
		_, _ = w.Write([]byte(`{"workflow_runs":[],"items":[],"total_count":0}`))
	}))
	defer server.Close()
	client := NewClient(credentialWith(t, "ghu_test"), server.URL, "test")
	if got := client.RateLimit(); got.Limit != 0 {
		t.Fatalf("before any answer = %+v", got)
	}
	if _, err := client.Runs(context.Background(), "o", "r", "", 10); err != nil {
		t.Fatal(err)
	}
	var out struct{}
	_ = client.get(context.Background(), "/search/issues", nil, &out)
	got := client.RateLimit()
	if got.Limit != 5000 || got.Remaining != 4200 || !got.Reset.Equal(reset) {
		t.Fatalf("rate limit = %+v, want the core one", got)
	}
}

func TestTheLoginIsReadOncePerToken(t *testing.T) {
	var users atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		users.Add(1)
		if r.Header.Get("Authorization") == "Bearer ghu_other" {
			_, _ = w.Write([]byte(`{"login":"bo"}`))
			return
		}
		_, _ = w.Write([]byte(`{"login":"ana"}`))
	}))
	defer server.Close()
	credential := credentialWith(t, "ghu_test")
	client := NewClient(credential, server.URL, "test")
	for range 2 {
		if login, err := client.Login(context.Background()); err != nil || login != "ana" {
			t.Fatalf("login = %q, %v", login, err)
		}
	}
	if users.Load() != 1 {
		t.Fatalf("GET /user = %d", users.Load())
	}
	_ = credential.Set("ghu_test") // the same token again
	_, _ = client.Login(context.Background())
	if users.Load() != 1 {
		t.Fatal("the same token is not read again")
	}
	_ = credential.Set("ghu_other")
	if login, _ := client.Login(context.Background()); login != "bo" || users.Load() != 2 {
		t.Fatalf("after a new token = %q, %d", login, users.Load())
	}
}

func TestRunsOfAnActorAreAskedWithAnETag(t *testing.T) {
	var query, sent string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		query, sent = r.URL.RawQuery, r.Header.Get("If-None-Match")
		if sent == `"v1"` {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", `"v1"`)
		_, _ = w.Write([]byte(`{"workflow_runs":[{"id":7,"status":"completed","conclusion":"failure","actor":{"login":"ana"}}]}`))
	}))
	defer server.Close()
	client := NewClient(credentialWith(t, "ghu_test"), server.URL, "test")
	runs, tag, err := client.ActorRunsIfChanged(context.Background(), "o", "r", "ana", 50, "")
	if err != nil || len(runs) != 1 || runs[0].Actor != "ana" || tag != `"v1"` || query != "actor=ana&per_page=50" {
		t.Fatalf("runs = %+v, %q, %v, query %q", runs, tag, err, query)
	}
	if _, _, err := client.ActorRunsIfChanged(context.Background(), "o", "r", "ana", 50, tag); !errors.Is(err, ErrNotModified) || sent != `"v1"` {
		t.Fatalf("again = %v, sent %q", err, sent)
	}
}
```

If `client_test.go` has no helper that makes a `*Credential` with a token, add:

```go
func credentialWith(t *testing.T, token string) *Credential {
	t.Helper()
	c := &Credential{}
	if err := c.Set(token); err != nil {
		t.Fatal(err)
	}
	return c
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd core && go test ./internal/github/ -run 'RateLimit|Login|Actor'`
Expected: FAIL, `client.RateLimit undefined`, `client.Login undefined` and `client.ActorRunsIfChanged undefined`.

- [ ] **Step 3: Credential generation** (in `credential.go`)

```go
type Credential struct {
	mu    sync.RWMutex
	token string
	// generation changes whenever the token does.
	generation uint64
}

func (c *Credential) Set(token string) error {
	if token == "" || len(token) > 255 || strings.ContainsFunc(token, func(r rune) bool { return r <= ' ' || r > '~' }) {
		return ErrInvalidToken
	}
	c.mu.Lock()
	if c.token != token {
		c.token = token
		c.generation++
	}
	c.mu.Unlock()
	return nil
}

func (c *Credential) Clear() {
	c.mu.Lock()
	if c.token != "" {
		c.token = ""
		c.generation++
	}
	c.mu.Unlock()
}

// Generation changes whenever the token is set to another or cleared, so
// what was read with a token can be kept until then.
func (c *Credential) Generation() uint64 {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.generation
}
```

- [ ] **Step 4: Client** (in `client.go`)

Add `"sync"` to the imports and fields to `Client`:

```go
type Client struct {
	credential *Credential
	baseURL    string
	http       *http.Client
	userAgent  string

	mu sync.Mutex
	// rate is the core rate limit of the latest answer that said it.
	rate RateLimit
	// login is the user's login, read with the token of loginFor.
	login    string
	loginFor uint64
}

// RateLimit is what GitHub said of the core rate limit in an answer; Limit
// is 0 when no answer said it (an Enterprise server without rate limits).
type RateLimit struct {
	Remaining int
	Limit     int
	Reset     time.Time
}

// RateLimit returns the core rate limit GitHub reported last.
func (c *Client) RateLimit() RateLimit {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.rate
}

// noteRateLimit keeps the core rate limit an answer reports. Search and
// GraphQL have limits of their own and are not kept.
func (c *Client) noteRateLimit(header http.Header) {
	if resource := header.Get("X-RateLimit-Resource"); resource != "" && resource != "core" {
		return
	}
	limit, limitErr := strconv.Atoi(header.Get("X-RateLimit-Limit"))
	remaining, remainingErr := strconv.Atoi(header.Get("X-RateLimit-Remaining"))
	reset, resetErr := strconv.ParseInt(header.Get("X-RateLimit-Reset"), 10, 64)
	if limitErr != nil || remainingErr != nil || resetErr != nil || limit <= 0 {
		return
	}
	c.mu.Lock()
	c.rate = RateLimit{Remaining: remaining, Limit: limit, Reset: time.Unix(reset, 0)}
	c.mu.Unlock()
}

// Login is the signed-in user's login, read with GET /user once per token
// and kept until the token changes.
func (c *Client) Login(ctx context.Context) (string, error) {
	generation := c.credential.Generation()
	c.mu.Lock()
	if c.login != "" && c.loginFor == generation {
		login := c.login
		c.mu.Unlock()
		return login, nil
	}
	c.mu.Unlock()
	var user struct {
		Login string `json:"login"`
	}
	if err := c.get(ctx, "/user", nil, &user); err != nil {
		return "", err
	}
	if user.Login == "" {
		return "", ErrInvalid
	}
	c.mu.Lock()
	c.login, c.loginFor = user.Login, generation
	c.mu.Unlock()
	return user.Login, nil
}
```

In `exchangeWith`, right after `defer response.Body.Close()`:

```go
	c.noteRateLimit(response.Header)
```

Replace `RunsIfChanged` with a shared read and add the actor's:

```go
// RunsIfChanged reads the newest runs like Runs; with etag set GitHub
// answers ErrNotModified when they did not change. It returns the new ETag.
func (c *Client) RunsIfChanged(ctx context.Context, owner, name string, limit int, etag string) ([]Run, string, error) {
	return c.runsIfChanged(ctx, owner, name, url.Values{}, limit, etag)
}

// ActorRunsIfChanged is RunsIfChanged for the runs actor started.
func (c *Client) ActorRunsIfChanged(ctx context.Context, owner, name, actor string, limit int, etag string) ([]Run, string, error) {
	return c.runsIfChanged(ctx, owner, name, url.Values{"actor": {actor}}, limit, etag)
}

func (c *Client) runsIfChanged(ctx context.Context, owner, name string, query url.Values, limit int, etag string) ([]Run, string, error) {
	if limit <= 0 || limit > maxRuns {
		limit = maxRuns
	}
	query.Set("per_page", strconv.Itoa(limit))
	var body struct {
		WorkflowRuns []runJSON `json:"workflow_runs"`
	}
	tag, err := c.getConditional(ctx, repoPath(owner, name, "/actions/runs"), query, etag, &body)
	if err != nil {
		return nil, "", err
	}
	runs := make([]Run, 0, len(body.WorkflowRuns))
	for _, r := range body.WorkflowRuns {
		runs = append(runs, r.run(owner, name))
	}
	return runs, tag, nil
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd core && go test ./internal/github/ && go vet ./internal/github/`
Expected: PASS, no vet findings. In `token.go` a `Client` is built as a struct literal, which is fine with the new mutex because nothing copies it.

- [ ] **Step 6: Commit**

```bash
git add core/internal/github
git commit -m "Core: the GitHub client keeps the core rate limit, reads the login once per token and runs by actor (B39)"
```

---

### Task 3: Open workspaces' runs and every workspace's starts

**Files:**
- Create: `core/internal/store/watched.go`
- Create: `core/internal/store/watched_test.go`
- Create: `core/internal/workspace/watched.go`
- Create: `core/internal/workspace/watched_test.go`

**Interfaces:**
- Consumes: `store.Store.scanRuns`, `readSource`, `scopeActivity`, `fromMillis`, `RunStarts`, `store.OpenReadOnly`, `Runtimes.claim`, `Runtimes.dir`.
- Produces:
  - `type store.Watched struct { Source Source; HasSource bool; SyncedAt time.Time; Runs []github.Run }`;
  - `func (s *Store) WatchedRuns(ctx context.Context, actor string, limit int) (Watched, error)`;
  - `func (m *Runtimes) OpenRuns(ctx context.Context, ids []string, source store.Source, actor string, limit int) ([]github.Run, time.Time, bool)`;
  - `func (m *Runtimes) Starts(ctx context.Context, ids []string, source store.Source) map[int64][]store.RunStart`.

- [ ] **Step 1: Write the failing store test** (`store/watched_test.go`)

```go
//go:build !windows

package store

import (
	"context"
	"testing"
	"time"

	"runnir/core/internal/github"
)

func TestWatchedRunsAreAnActorsNewestSavedRuns(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	if w, err := s.WatchedRuns(ctx, "ana", 50); err != nil || w.HasSource {
		t.Fatalf("empty = %+v, %v", w, err)
	}
	at := fixedNow()
	_, err := s.ApplySync(ctx, Pass{Source: testSource, At: at, OK: true, Runs: &RunsUpdate{Runs: []github.Run{
		{ID: 3, Actor: "Ana", Status: "in_progress", CreatedAt: at},
		{ID: 2, Actor: "bo", Status: "completed", Conclusion: "failure", CreatedAt: at.Add(-time.Minute)},
		{ID: 1, Actor: "ana", Status: "completed", Conclusion: "failure", CreatedAt: at.Add(-2 * time.Minute)},
	}}})
	if err != nil {
		t.Fatal(err)
	}
	w, err := s.WatchedRuns(ctx, "ANA", 50)
	if err != nil || !w.HasSource || w.Source != testSource || !w.SyncedAt.Equal(at) || len(w.Runs) != 2 || w.Runs[0].ID != 3 || w.Runs[1].ID != 1 {
		t.Fatalf("watched = %+v, %v", w, err)
	}
	if w, _ := s.WatchedRuns(ctx, "ana", 1); len(w.Runs) != 1 {
		t.Fatalf("limit = %+v", w.Runs)
	}
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd core && go test ./internal/store/ -run Watched`
Expected: FAIL, `s.WatchedRuns undefined`.

- [ ] **Step 3: Implement `store/watched.go`**

```go
package store

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"runnir/core/internal/github"
)

// Watched is what the watcher of B39 reads of an open workspace.
type Watched struct {
	Source    Source
	HasSource bool
	// SyncedAt is when a pass last reached GitHub; zero for never.
	SyncedAt time.Time
	// Runs are the actor's newest saved runs, newest first.
	Runs []github.Run
}

// WatchedRuns reads the newest limit saved runs actor started, matched
// without case, and when a pass last reached GitHub.
func (s *Store) WatchedRuns(ctx context.Context, actor string, limit int) (Watched, error) {
	var w Watched
	var err error
	if w.Source, w.HasSource, err = readSource(ctx, s.db); err != nil || !w.HasSource {
		return w, err
	}
	var synced int64
	err = s.db.QueryRowContext(ctx, "SELECT synced_at FROM sync_state WHERE scope = ?", scopeActivity).Scan(&synced)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return Watched{}, err
	}
	w.SyncedAt = fromMillis(synced)
	w.Runs, err = s.scanRuns(ctx, "WHERE actor = ? COLLATE NOCASE ORDER BY created_at DESC, id DESC LIMIT ?", actor, limit)
	return w, err
}
```

- [ ] **Step 4: Run the store test to verify it passes**

Run: `cd core && go test ./internal/store/ -run Watched`
Expected: PASS.

- [ ] **Step 5: Write the failing workspace tests** (`workspace/watched_test.go`)

The fake GitHub of `helpers_test.go` sets `f.runs` as a JSON body. `newRuntimes`, `fixedResolver`, `waitRefresh`, `wsA` and `saveClosedWorkspace` already exist.

```go
//go:build !windows

package workspace

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"runnir/core/internal/store"
)

const wsSecond = "9ce88ff0-5c16-43b3-8f20-8e33e852b019"

func TestOpenRunsComeFromAnOpenWorkspaceOfTheRepository(t *testing.T) {
	f, accounts := newFake(t)
	f.set(func(f *fakeGitHub) {
		f.runs = `{"workflow_runs":[{"id":7,"workflow_id":3,"name":"CI","run_number":1,"run_attempt":1,"status":"in_progress","actor":{"login":"ana"},"created_at":"2026-10-28T10:00:00Z","updated_at":"2026-10-28T10:01:00Z"},
{"id":6,"workflow_id":3,"name":"CI","run_number":1,"run_attempt":1,"status":"completed","conclusion":"failure","actor":{"login":"bo"},"created_at":"2026-10-28T09:00:00Z","updated_at":"2026-10-28T09:01:00Z"}]}`
	})
	data := t.TempDir()
	m := newRuntimes(t, data)
	r, _ := m.Attach(wsA, "repo_1", fixedResolver(accounts, "o", "r"))
	waitRefresh(t, r)
	source := store.Source{Repository: "o/r"}

	runs, readAt, ok := m.OpenRuns(context.Background(), []string{wsClosed, wsA}, source, "ana", 50)
	if !ok || len(runs) != 1 || runs[0].ID != 7 || readAt.IsZero() {
		t.Fatalf("open runs = %+v, %v, %v", runs, readAt, ok)
	}
	if _, _, ok := m.OpenRuns(context.Background(), []string{wsA}, store.Source{Repository: "o/other"}, "ana", 50); ok {
		t.Fatal("another repository's data is not this one's")
	}
	if _, _, ok := m.OpenRuns(context.Background(), []string{wsClosed}, source, "ana", 50); ok {
		t.Fatal("a closed workspace is not open")
	}
}

func TestStartsAreJoinedFromOpenAndClosedWorkspacesReadOnly(t *testing.T) {
	_, accounts := newFake(t)
	data := t.TempDir()
	source := store.Source{Repository: "o/r"}
	at := time.Date(2026, 10, 28, 9, 0, 0, 0, time.UTC)

	// A closed workspace left a start of run 7 on disk.
	closed, err := store.Open(store.WorkspaceDir(data, wsClosed), store.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if err := closed.RecordStart(context.Background(), store.RunStart{Source: source, RunID: 7, Attempt: 1, Kind: store.StartDispatch, SentAt: at}); err != nil {
		t.Fatal(err)
	}
	_ = closed.Close()
	file := filepath.Join(store.WorkspaceDir(data, wsClosed), "state.sqlite")
	before, _ := os.ReadFile(file)

	m := newRuntimes(t, data)
	open, _ := m.Attach(wsA, "repo_1", fixedResolver(accounts, "o", "r"))
	if err := open.Store().RecordStart(context.Background(), store.RunStart{Source: source, RunID: 7, Attempt: 2, Kind: store.StartRerun, SentAt: at.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	// A third one's folder holds a file that is not a database.
	damaged := store.WorkspaceDir(data, wsSecond)
	_ = os.MkdirAll(damaged, 0o700)
	_ = os.WriteFile(filepath.Join(damaged, "state.sqlite"), []byte("not a database"), 0o600)

	starts := m.Starts(context.Background(), []string{wsA, wsClosed, wsSecond, "not-an-id"}, source)
	got := starts[7]
	if len(got) != 2 || got[0].Attempt != 1 || got[0].Kind != store.StartDispatch || got[1].Attempt != 2 {
		t.Fatalf("starts = %+v", starts)
	}
	if after, _ := os.ReadFile(file); !bytes.Equal(before, after) {
		t.Fatal("the closed workspace's database was changed")
	}
}
```

- [ ] **Step 6: Run them to verify they fail**

Run: `cd core && go test ./internal/workspace/ -run 'OpenRuns|Starts'`
Expected: FAIL, `m.OpenRuns undefined` and `m.Starts undefined`.

- [ ] **Step 7: Implement `workspace/watched.go`**

```go
package workspace

import (
	"context"
	"sort"
	"time"

	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

// OpenRuns reads, from the first workspace among ids that is open with
// source's saved data, actor's newest limit saved runs and when a pass last
// reached GitHub. false when none is; nothing is sent to GitHub.
func (m *Runtimes) OpenRuns(ctx context.Context, ids []string, source store.Source, actor string, limit int) ([]github.Run, time.Time, bool) {
	for _, raw := range ids {
		id, ok := store.NormalizeWorkspaceID(raw)
		if !ok {
			continue
		}
		m.mu.Lock()
		rt := m.byWorkspace[id]
		m.mu.Unlock()
		if rt == nil {
			continue
		}
		w, err := rt.cfg.store.WatchedRuns(ctx, actor, limit)
		if err != nil || !w.HasSource || w.Source != source {
			continue
		}
		return w.Runs, w.SyncedAt, true
	}
	return nil, time.Time{}, false
}

// Starts joins the attempts Runnir started of source's runs (B46) in the
// workspaces ids: an open one's from its store, a closed one's from its
// database opened read-only, as SearchAll reads it. A workspace that cannot
// be read adds nothing. Each run's attempts are oldest first.
func (m *Runtimes) Starts(ctx context.Context, ids []string, source store.Source) map[int64][]store.RunStart {
	out := map[int64][]store.RunStart{}
	for _, raw := range ids {
		id, ok := store.NormalizeWorkspaceID(raw)
		if !ok {
			continue
		}
		for run, starts := range m.startsOf(ctx, id, source) {
			out[run] = append(out[run], starts...)
		}
	}
	for _, starts := range out {
		sort.Slice(starts, func(i, j int) bool { return starts[i].Attempt < starts[j].Attempt })
	}
	return out
}

func (m *Runtimes) startsOf(ctx context.Context, id string, source store.Source) map[int64][]store.RunStart {
	rt, release := m.claim(id)
	defer release()
	if rt != nil {
		starts, _ := rt.cfg.store.RunStarts(ctx, source)
		return starts
	}
	if m.opts.DataDir == "" {
		return nil
	}
	st, ok, err := store.OpenReadOnly(m.dir(id))
	if err != nil || !ok {
		return nil
	}
	defer st.Close()
	starts, _ := st.RunStarts(ctx, source)
	return starts
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cd core && go test ./internal/store/ ./internal/workspace/`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add core/internal/store/watched.go core/internal/store/watched_test.go core/internal/workspace/watched.go core/internal/workspace/watched_test.go
git commit -m "Core: an open workspace's runs of the user, and Runnir's starts from open and closed workspaces read read-only (B39)"
```

---

### Task 4: The watcher

**Files:**
- Create: `core/internal/watch/watcher.go`
- Test: `core/internal/watch/watcher_test.go`

**Interfaces:**
- Consumes:
  - `Pick` (Task 1);
  - `Client.Login`, `Client.ActorRunsIfChanged`, `Client.RateLimit` (Task 2);
  - `Runtimes.OpenRuns`, `Runtimes.Starts` through `Local` (Task 3);
  - `workspace.Access(account, err) (corev1.GithubAccess, time.Time, error)`.
- Produces:
  - `type Repository struct { ServerID, Name string; WorkspaceIDs []string }`;
  - `type Local interface { OpenRuns(...); Starts(...) }`;
  - `type Answer struct { Access corev1.GithubAccess; RetryAfter time.Time; Watched bool; Failed, Running []github.Run; Starts map[int64][]store.RunStart; ReadAt time.Time }`;
  - `type Pause struct { ServerID string; Until time.Time }`;
  - `func New(accounts *github.Accounts, local Local, now func() time.Time) *Watcher`;
  - `func (w *Watcher) List(ctx context.Context, repositories []Repository, refresh bool) ([]Answer, []Pause, error)`;
  - variables `MaxWatched = 100`, `Reuse = 3 * time.Minute`, `readers = 4`.

- [ ] **Step 1: Write the failing tests**

```go
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
// any other repository as not found.
type fakeGitHub struct {
	mu        sync.Mutex
	login     string
	runs      map[string]string
	users     int
	queries   map[string][]string
	tags      map[string][]string
	remaining int
	reset     time.Time
	limited   bool
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
		_, _ = fmt.Fprintf(w, `{"login":%q}`, f.login)
		return
	}
	w.Header().Set("X-RateLimit-Resource", "core")
	w.Header().Set("X-RateLimit-Limit", "5000")
	w.Header().Set("X-RateLimit-Remaining", strconv.Itoa(f.remaining))
	w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(f.reset.Unix(), 10))
	repo := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/repos/"), "/actions/runs")
	f.queries[repo] = append(f.queries[repo], r.URL.RawQuery)
	f.tags[repo] = append(f.tags[repo], r.Header.Get("If-None-Match"))
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
	open   map[store.Source][]github.Run
	readAt time.Time
	starts map[store.Source]map[int64][]store.RunStart
	asked  int
}

func (l *fakeLocal) OpenRuns(_ context.Context, ids []string, source store.Source, _ string, _ int) ([]github.Run, time.Time, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	runs, ok := l.open[source]
	return runs, l.readAt, ok && len(ids) > 0
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
	local := &fakeLocal{open: map[store.Source][]github.Run{}, starts: map[store.Source]map[int64][]store.RunStart{}}
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

func TestAnOpenWorkspaceAnswersFromItsStoreWithItsStarts(t *testing.T) {
	w, f, local, _, _ := rig(t)
	source := store.Source{Repository: "o/r"}
	local.open[source] = []github.Run{{ID: 9, WorkflowID: 1, Status: "in_progress", Actor: "ana", CreatedAt: base}}
	local.readAt = base.Add(-time.Minute)
	local.starts[source] = map[int64][]store.RunStart{9: {{RunID: 9, Attempt: 1, Kind: store.StartDispatch}}, 8: {{RunID: 8, Attempt: 1}}}
	f.runs["o/quiet"] = runJSON(1, 1, "completed", "success", "ana", base)

	answers, _ := list(t, w, false, Repository{Name: "O/R", WorkspaceIDs: []string{"w"}}, Repository{Name: "o/quiet", WorkspaceIDs: []string{"w2"}})
	a := answers[0]
	if f.requests("o/r") != 0 || !slices.Equal(ids(a.Running), []int64{9}) || !a.ReadAt.Equal(local.readAt) || len(a.Starts) != 1 || len(a.Starts[9]) != 1 {
		t.Fatalf("open = %+v", a)
	}
	if local.asked != 1 {
		t.Fatalf("starts asked %d times; a repository with nothing listed is not read", local.asked)
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd core && go test ./internal/watch/`
Expected: FAIL, `undefined: New` and the other names.

- [ ] **Step 3: Implement `watcher.go`**

```go
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd core && go test -race ./internal/watch/ && go vet ./internal/watch/`
Expected: PASS with no race reports.

- [ ] **Step 5: Commit**

```bash
git add core/internal/watch
git commit -m "Core: the watcher reads the user's runs with an ETag, at most every 3 minutes, pauses for the rate limit and joins Runnir's starts (B39)"
```

---

### Task 5: The contract and the RPC

**Files:**
- Modify: `contracts/grpc/runnir/core/v1/runnir_core.proto`
- Regenerate: `core/internal/gen/runnir/core/v1/*`, `apps/macos/Runnir/IPC/Generated/runnir/core/v1/*`
- Create: `core/internal/server/watched.go`
- Create: `core/internal/server/watched_test.go`
- Modify: `core/internal/server/service.go`, `core/internal/server/server.go`
- Modify: `docs/architecture/grpc-api.md`

**Interfaces:**
- Consumes:
  - `watch.New` and `watch.Watcher.List` (Task 4);
  - `runMessage`, `withStarts`, `statusMessage`, `timestamp` in `server`.
- Produces:
  - `rpc ListWatchedRuns(ListWatchedRunsRequest) returns (ListWatchedRunsResponse)`;
  - Swift `Runnir_Core_V1_ListWatchedRunsRequest`, `Runnir_Core_V1_WatchedRepository`, `Runnir_Core_V1_ListWatchedRunsResponse`, `Runnir_Core_V1_WatchedRuns`, `Runnir_Core_V1_ServerPause`.

- [ ] **Step 1: The contract.**
  - After the `ListPullRequests` rpc add:

```proto
  // The signed-in user's failed and running runs in the repositories the
  // app watches (B39): its registered workspaces linked to GitHub and its
  // starred repositories. An open workspace answers from its store; any
  // other repository is read with one conditional request at most every 3
  // minutes, only the runs the user started, and kept in memory. A workflow
  // on a branch counts as failed while its newest finished run failed,
  // within 7 days. At most 100 repositories are watched. Nothing is written
  // to a closed workspace's database; its starts (B46) are read read-only.
  rpc ListWatchedRuns(ListWatchedRunsRequest) returns (ListWatchedRunsResponse);
```

  - After `message PullRequest` and `enum PullRequestCi` add:

```proto
message ListWatchedRunsRequest {
  // In the order the app watches them: workspaces' repositories first,
  // then starred ones. At most 1000.
  repeated WatchedRepository repositories = 1;
  // Read every repository again, however recently it was read.
  bool refresh = 2;
}

message WatchedRepository {
  // Server id; empty is github.com.
  string github_server = 1;
  // "owner/name".
  string repository = 2;
  // The registered workspaces linked to the repository, the one a click
  // opens first; empty for a starred repository without one.
  repeated string workspace_ids = 3;
}

message ListWatchedRunsResponse {
  // One per repository, in the order of the request.
  repeated WatchedRuns repositories = 1;
  // Servers read no further until a time, to keep their rate limit.
  repeated ServerPause pauses = 2;
}

message WatchedRuns {
  WatchedRepository repository = 1;
  GitHubStatus status = 2;
  // False beyond the first 100: nothing was read.
  bool watched = 3;
  // Newest first by updated_at.
  repeated WorkflowRun failed = 4;
  // Newest first by created_at.
  repeated WorkflowRun running = 5;
  // When the runs were read; unset for never.
  google.protobuf.Timestamp read_at = 6;
}

message ServerPause {
  // Server id; empty is github.com.
  string github_server = 1;
  google.protobuf.Timestamp until = 2;
}
```

  - In `WorkflowRun.runnir_starts` change the comment's last sentence to: `Set in workspace activity, SearchRuns, SearchRunsOnGitHub and ListWatchedRuns; empty elsewhere.`

- [ ] **Step 2: Regenerate**

Run (from the repository root): `PATH="$HOME/go/bin:$SCRATCH/bin:$PATH" scripts/generate-contracts.sh && git status --short`
Expected:
- `buf lint` passes;
- the Go and Swift generated files change;
- `core/` builds with `go build ./...`, except that `service` does not implement `ListWatchedRuns` yet, which is fine because it embeds `UnimplementedRunnirCoreServer`.

- [ ] **Step 3: Write the failing server test** (`server/watched_test.go`)

```go
//go:build !windows

package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/store"
)

const wsWatchedClosed = "7ce88ff0-5c16-43b3-8f20-8e33e852b019"

func TestWatchedRunsOfOpenClosedAndStarredRepositories(t *testing.T) {
	var mu sync.Mutex
	actorReads := map[string]int{}
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch r.URL.Path {
		case "/user":
			_, _ = w.Write([]byte(`{"login":"ana"}`))
		case "/repos/o/r":
			_, _ = w.Write([]byte(`{"full_name":"o/r","default_branch":"main"}`))
		case "/repos/o/r/actions/runs":
			if r.URL.Query().Get("actor") != "" {
				actorReads["o/r"]++
			}
			_, _ = w.Write([]byte(`{"workflow_runs":[{"id":21,"workflow_id":1,"name":"CI","run_number":5,"run_attempt":1,"status":"in_progress","head_branch":"main","actor":{"login":"ana"},"created_at":"2026-10-29T11:00:00Z","updated_at":"2026-10-29T11:01:00Z"}]}`))
		case "/repos/o/r/actions/workflows":
			_, _ = w.Write([]byte(`{"total_count":0,"workflows":[]}`))
		case "/repos/o/r/pulls":
			_, _ = w.Write([]byte(`[]`))
		case "/repos/o/app/actions/runs":
			actorReads["o/app"]++
			if !strings.Contains(r.URL.RawQuery, "actor=ana") {
				t.Errorf("query = %q", r.URL.RawQuery)
			}
			at := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
			_, _ = w.Write([]byte(`{"workflow_runs":[{"id":7,"workflow_id":2,"name":"Deploy","display_title":"Release","run_number":3,"run_attempt":1,"status":"completed","conclusion":"failure","head_branch":"main","actor":{"login":"ana"},"created_at":"` + at + `","updated_at":"` + at + `"}]}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer fake.Close()

	data := t.TempDir()
	// A closed workspace of o/app keeps a dispatch Runnir sent.
	closed, err := store.Open(store.WorkspaceDir(data, wsWatchedClosed), store.Options{})
	if err != nil {
		t.Fatal(err)
	}
	_ = closed.RecordStart(context.Background(), store.RunStart{Source: store.Source{Repository: "o/app"}, RunID: 7, Attempt: 1, Kind: store.StartDispatch, SentAt: time.Now()})
	_ = closed.Close()

	client, stop, ctx := workspaceRig(t, data, fake.URL)
	defer stop()
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.com:o/r.git"), WorkspaceId: testWorkspace})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: opened.Repository.Id, Wait: true}); err != nil {
		t.Fatal(err)
	}

	got, err := client.ListWatchedRuns(ctx, &corev1.ListWatchedRunsRequest{Repositories: []*corev1.WatchedRepository{
		{Repository: "o/r", WorkspaceIds: []string{testWorkspace}},
		{Repository: "o/app", WorkspaceIds: []string{wsWatchedClosed}},
		{Repository: "o/star"},
	}})
	if err != nil || len(got.Repositories) != 3 {
		t.Fatalf("answer = %v, %v", got, err)
	}
	open, app, star := got.Repositories[0], got.Repositories[1], got.Repositories[2]
	if len(open.Running) != 1 || open.Running[0].Id != 21 || open.ReadAt == nil || actorReads["o/r"] != 0 {
		t.Fatalf("open workspace = %v, actor reads %d", open, actorReads["o/r"])
	}
	if len(app.Failed) != 1 || app.Failed[0].Id != 7 || len(app.Failed[0].RunnirStarts) != 1 ||
		app.Failed[0].RunnirStarts[0].Kind != corev1.RunnirStartKind_RUNNIR_START_KIND_DISPATCH || app.Repository.GetRepository() != "o/app" {
		t.Fatalf("closed workspace = %v", app)
	}
	if star.Status.GetAccess() != corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE || !star.Watched {
		t.Fatalf("starred = %v", star)
	}

	tooMany := make([]*corev1.WatchedRepository, 1001)
	for i := range tooMany {
		tooMany[i] = &corev1.WatchedRepository{Repository: "o/r"}
	}
	if _, err := client.ListWatchedRuns(ctx, &corev1.ListWatchedRunsRequest{Repositories: tooMany}); err == nil {
		t.Fatal("more than 1000 repositories are refused")
	}
}
```

- [ ] **Step 4: Run it to verify it fails**

Run: `cd core && go test ./internal/server/ -run Watched`
Expected: FAIL, `ListWatchedRuns` answers Unimplemented.

- [ ] **Step 5: Implement**
  - In `service.go`, add a field beside `accounts`:

```go
	// watcher reads the user's runs of the repositories the menu bar
	// watches (B39).
	watcher *watch.Watcher
```

  - In `server.go`, make the accounts once and give them to both:

```go
	accounts := github.NewAccounts(options.GitHubBaseURL, buildinfo.Version)
	corev1.RegisterRunnirCoreServer(grpcServer, &service{
		repositories: repositories, events: bus, executions: executions, workspaces: workspaces,
		accounts:     accounts,
		watcher:      watch.New(accounts, workspaces, time.Now),
		// … the other fields as they are
	})
```

  - Create `server/watched.go`:

```go
package server

import (
	"context"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/watch"
)

// maxWatchedRequest bounds the repositories of one ListWatchedRuns call.
const maxWatchedRequest = 1000

// ListWatchedRuns answers the user's failed and running runs of each
// repository the app watches (B39).
func (s *service) ListWatchedRuns(ctx context.Context, request *corev1.ListWatchedRunsRequest) (*corev1.ListWatchedRunsResponse, error) {
	sent := request.GetRepositories()
	if len(sent) > maxWatchedRequest {
		return nil, status.Error(codes.InvalidArgument, "at most 1000 repositories")
	}
	repositories := make([]watch.Repository, len(sent))
	for i, r := range sent {
		repositories[i] = watch.Repository{ServerID: r.GetGithubServer(), Name: r.GetRepository(), WorkspaceIDs: r.GetWorkspaceIds()}
	}
	answers, pauses, err := s.watcher.List(ctx, repositories, request.GetRefresh())
	if err != nil {
		return nil, status.FromContextError(err).Err()
	}
	out := &corev1.ListWatchedRunsResponse{}
	for i, a := range answers {
		item := &corev1.WatchedRuns{Repository: sent[i], Status: statusMessage(a.Access, a.RetryAfter), Watched: a.Watched,
			Failed: runMessages(a.Failed), Running: runMessages(a.Running), ReadAt: timestamp(a.ReadAt)}
		withStarts(item.Failed, a.Starts)
		withStarts(item.Running, a.Starts)
		out.Repositories = append(out.Repositories, item)
	}
	for _, p := range pauses {
		out.Pauses = append(out.Pauses, &corev1.ServerPause{GithubServer: p.ServerID, Until: timestamppb.New(p.Until)})
	}
	return out, nil
}

func runMessages(runs []github.Run) []*corev1.WorkflowRun {
	out := make([]*corev1.WorkflowRun, len(runs))
	for i, r := range runs {
		out[i] = runMessage(r)
	}
	return out
}
```

- [ ] **Step 6: Run the Core checks**

Run: `cd core && go test ./... && go vet ./... && go build ./...`
Expected: PASS.

- [ ] **Step 7: Document the RPC.** In `docs/architecture/grpc-api.md`, add a row after `ListPullRequests`:

```markdown
| `ListWatchedRuns(repositories, refresh)` | The signed-in user's failed and running runs in the repositories the app watches (B39): each `WatchedRepository` is a server, `owner/name` and the registered workspaces linked to it, the one a click opens first. Only runs whose `actor` is the user's login on that server (read once per token with `GET /user`). Running is every run not completed; a workflow on a branch is failed while its newest finished run is in the Failed group and finished in the last 7 days. An open workspace answers from its store with no request; any other repository is read with `actor` and an ETag (a 304 does not count against the rate limit), at most every 3 minutes unless `refresh`, at most 4 at once, kept in memory only. The first 100 are watched, the rest answered `watched: false`. A server with less than a tenth of its rate limit left, or rate limited, is read no further until its reset and listed in `pauses`. The starts of B46 are joined from every workspace of the repository, a closed one's database read read-only; nothing is written to it. At most 1000 repositories (`INVALID_ARGUMENT`) | GitHub outcomes per repository in `status.access` |
```

- [ ] **Step 8: Commit**

```bash
git add contracts core apps/macos/Runnir/IPC/Generated docs/architecture/grpc-api.md
git commit -m "Core: ListWatchedRuns, the user's failed and running runs of watched repositories (B39)"
```

---

### Task 6: Swift models, the service method and the hub

**Files:**
- Modify: `apps/macos/Runnir/IPC/CoreGitHubModels.swift`
- Modify: `apps/macos/Runnir/IPC/CoreService.swift`
- Modify: `apps/macos/Runnir/IPC/GRPCCoreService.swift`
- Modify: `apps/macos/Runnir/IPC/CoreHub.swift`
- Modify: `apps/macos/RunnirTests/CoreHubTests.swift` (`FakeCore`), `apps/macos/RunnirTests/CoreProcessSupervisorTests.swift` (`FakeService`)
- Test: `apps/macos/RunnirTests/RunLinkMappingTests.swift`

**Interfaces:**
- Produces:
  - `struct CoreWatchedRepository { let repository: GitHubRepositoryRef; var workspaceIDs: [UUID] }`;
  - `struct CoreWatchedRuns { repository, access, watched, failed, running, readAt }`;
  - `struct CoreWatchedRunsList { repositories: [CoreWatchedRuns]; pauses: [String: Date] }`;
  - `CoreServicing.listWatchedRuns(_:refresh:)`;
  - `GRPCCoreService.map(_ response: Runnir_Core_V1_ListWatchedRunsResponse, sent:)`;
  - `CoreHub.watchedRuns(_:refresh:) async -> CoreWatchedRunsList?`;
  - `FakeCore.watchedRunsResult`, `FakeCore.watchedRunsCalls`.

- [ ] **Step 1: Write the failing mapping test** (append to `RunLinkMappingTests.swift`, inside its suite)

```swift
    @Test func watchedRunsKeepTheOrderSentAndThePauses() {
        let sent = [CoreWatchedRepository(repository: GitHubRepositoryRef(serverID: "", fullName: "o/r"), workspaceIDs: [UUID()]),
                    CoreWatchedRepository(repository: GitHubRepositoryRef(serverID: "", fullName: "o/star"))]
        let response = Runnir_Core_V1_ListWatchedRunsResponse.with {
            $0.repositories = [
                .with {
                    $0.status = .with { $0.access = .ok }
                    $0.watched = true
                    $0.failed = [.with { $0.id = 7; $0.status = "completed"; $0.conclusion = "failure"; $0.runAttempt = 2 }]
                    $0.readAt = .init(date: Date(timeIntervalSince1970: 1_000))
                },
                .with { $0.status = .with { $0.access = .notVisible }; $0.watched = true },
            ]
            $0.pauses = [.with { $0.githubServer = ""; $0.until = .init(date: Date(timeIntervalSince1970: 2_000)) }]
        }
        let list = GRPCCoreService.map(response, sent: sent)
        #expect(list.repositories.map(\.repository) == sent)
        #expect(list.repositories[0].failed.map(\.id) == [7] && list.repositories[0].failed[0].runAttempt == 2)
        #expect(list.repositories[0].readAt == Date(timeIntervalSince1970: 1_000))
        #expect(list.repositories[1].access == .notVisible && list.repositories[1].readAt == nil)
        #expect(list.pauses == ["": Date(timeIntervalSince1970: 2_000)])
    }
```

- [ ] **Step 2: Models** (in `CoreGitHubModels.swift`, after `GitHubRepositoryRef`)

```swift
/// A repository the Runs tab watches for the user's runs (B39).
struct CoreWatchedRepository: Equatable, Hashable, Sendable {
    let repository: GitHubRepositoryRef
    /// The registered workspaces linked to it, the one a click opens
    /// first; empty for a starred repository without one.
    var workspaceIDs: [UUID] = []
}

/// One watched repository's failed and running runs, as the Core read them.
struct CoreWatchedRuns: Equatable, Sendable {
    let repository: CoreWatchedRepository
    let access: CoreGitHubAccess
    /// False beyond the first 100: nothing was read.
    let watched: Bool
    let failed: [CoreWorkflowRun]
    let running: [CoreWorkflowRun]
    /// When the runs were read; nil for never.
    let readAt: Date?
}

struct CoreWatchedRunsList: Equatable, Sendable {
    let repositories: [CoreWatchedRuns]
    /// Servers the Core reads no further until a time, by server id.
    let pauses: [String: Date]
}
```

- [ ] **Step 3: Protocol, gRPC, hub and fakes**
  - In `CoreService.swift`, after `listPullRequests`:

```swift
    /// The user's failed and running runs of the watched repositories, one
    /// answer per repository in the order sent.
    func listWatchedRuns(_ repositories: [CoreWatchedRepository], refresh: Bool) async throws -> CoreWatchedRunsList
```

  - In `GRPCCoreService.swift`, after `listPullRequests`:

```swift
    func listWatchedRuns(_ repositories: [CoreWatchedRepository], refresh: Bool) async throws -> CoreWatchedRunsList {
        var options = Self.options(.seconds(60))
        options.maxResponseMessageBytes = 8 << 20
        let response = try await call {
            try await client.listWatchedRuns(.with {
                $0.repositories = repositories.map { sent in
                    Runnir_Core_V1_WatchedRepository.with {
                        $0.githubServer = sent.repository.serverID
                        $0.repository = sent.repository.fullName
                        $0.workspaceIds = sent.workspaceIDs.map { $0.uuidString.lowercased() }
                    }
                }
                $0.refresh = refresh
            }, options: options)
        }
        return Self.map(response, sent: repositories)
    }

    /// The Core answers each repository once, in the order sent.
    static func map(_ response: Runnir_Core_V1_ListWatchedRunsResponse, sent: [CoreWatchedRepository]) -> CoreWatchedRunsList {
        let answers = zip(sent, response.repositories).map { sent, item in
            CoreWatchedRuns(repository: sent, access: Self.map(item.status), watched: item.watched,
                            failed: item.failed.map(Self.map), running: item.running.map(Self.map),
                            readAt: item.hasReadAt ? item.readAt.date : nil)
        }
        let pauses = Dictionary(response.pauses.map { ($0.githubServer, $0.until.date) }, uniquingKeysWith: max)
        return CoreWatchedRunsList(repositories: answers, pauses: pauses)
    }
```

  - In `CoreHub.swift`, after `pullRequests(closedSince:)`:

```swift
    /// The user's failed and running runs of the watched repositories
    /// (B39); nil when the Core is not ready or did not answer.
    func watchedRuns(_ repositories: [CoreWatchedRepository], refresh: Bool) async -> CoreWatchedRunsList? {
        guard isReady, let service = try? await provider.service(),
              let result = try? await service.listWatchedRuns(repositories, refresh: refresh) else { return nil }
        if result.repositories.contains(where: { $0.access == .tokenRejected && $0.repository.repository.serverID.isEmpty }) {
            await onGitHubTokenRejected?()
        }
        return result
    }
```

  - In `FakeCore` (`CoreHubTests.swift`), beside the pull request fakes:

```swift
    /// nil answers as a Core that failed.
    var watchedRunsResult: CoreWatchedRunsList?
    private var _watchedRunsCalls: [(repositories: [CoreWatchedRepository], refresh: Bool)] = []
    var watchedRunsCalls: [(repositories: [CoreWatchedRepository], refresh: Bool)] { lock.withLock { _watchedRunsCalls } }
    func listWatchedRuns(_ repositories: [CoreWatchedRepository], refresh: Bool) async throws -> CoreWatchedRunsList {
        try lock.withLock {
            _watchedRunsCalls.append((repositories, refresh))
            guard let watchedRunsResult else { throw CoreServiceError.unavailable }
            return watchedRunsResult
        }
    }
```

  - In `FakeService` (`CoreProcessSupervisorTests.swift`), beside its `listPullRequests`:

```swift
    func listWatchedRuns(_ repositories: [CoreWatchedRepository], refresh: Bool) async throws -> CoreWatchedRunsList {
        throw CoreServiceError.unavailable
    }
```

- [ ] **Step 4: Build and run the mapping test** (from the repository root, after the Go PATH export)

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/RunLinkMappingTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`. If the suite has another name, use the struct name in `RunLinkMappingTests.swift`.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Runnir/IPC apps/macos/RunnirTests/CoreHubTests.swift apps/macos/RunnirTests/CoreProcessSupervisorTests.swift apps/macos/RunnirTests/RunLinkMappingTests.swift
git commit -m "App: watched repositories and their runs from the Core (B39)"
```

---

### Task 7: Shared pieces of the menu lists

**Files:**
- Modify: `apps/macos/Runnir/Features/Desktop/PullRequestsViews.swift`
- Modify: `apps/macos/Runnir/App/Desktop/DesktopCoordinator.swift` (the store's name at `DesktopAppDelegate.init`)
- Modify: `apps/macos/RunnirTests/PullRequestsTests.swift`

**Interfaces:**
- Produces:
  - `struct FileDismissalStore { init(directory: URL, fileName: String); static let pullRequestsFile, runsFile; static func live(_ fileName: String) throws -> FileDismissalStore; load(); save(_:); static let keepFor }`, which replaces `FileDismissedPullRequestsStore`;
  - `struct ListChip: View` (symbol, label, tint, background);
  - `struct ListSectionHeader: View` (title, count, inset);
  - `struct ListRemoveButton: View` (action), which moves out of `PullRequestRow`.

- [ ] **Step 1: Rename the store.** Replace the struct at the top of the file:

```swift
// MARK: Dismissed items

/// A JSON file in the app's support directory of items removed from a menu
/// bar list, by key, with when: closed pull requests in
/// dismissed-pull-requests.json, failed runs in dismissed-runs.json.
/// Entries older than a week are dropped.
struct FileDismissalStore: Sendable {
    let fileURL: URL

    static let pullRequestsFile = "dismissed-pull-requests.json"
    static let runsFile = "dismissed-runs.json"
    static let maxEntries = 1000
    static let maxFileBytes = 256 * 1024
    static let keepFor: TimeInterval = 7 * 24 * 3600

    private struct Snapshot: Codable {
        var version = 1
        var dismissed: [String: Date]
    }

    init(directory: URL, fileName: String) {
        fileURL = directory.appendingPathComponent(fileName)
    }

    static func live(_ fileName: String) throws -> FileDismissalStore {
        FileDismissalStore(directory: try RunnirSupportDirectory.url(), fileName: fileName)
    }

    // load() and save(_:) stay as they are.
}
```

  - In `PullRequestsModel`, change `FileDismissedPullRequestsStore` to `FileDismissalStore` (its stored property, `init(store:)` and both `keepFor` uses).
  - In `DesktopAppDelegate.init` (`DesktopCoordinator.swift`), use `PullRequestsModel(store: try? FileDismissalStore.live(FileDismissalStore.pullRequestsFile))`.
  - In `PullRequestsTests.swift`, change both `FileDismissedPullRequestsStore(directory: folder)` to `FileDismissalStore(directory: folder, fileName: FileDismissalStore.pullRequestsFile)`.

- [ ] **Step 2: Extract the chip, the header and the remove button.**
  - Above `PullRequestsListState`, add:

```swift
/// A count with a symbol above a menu bar list: "2 failing", "3 running".
struct ListChip: View {
    let symbol: String
    let label: String
    let tint: Color
    let background: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10))
            Text(label).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(background))
    }
}

/// A section's title and count in a menu bar list.
struct ListSectionHeader: View {
    let title: String
    let count: Int
    let inset: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(RunnirTheme.secondaryForeground)
            Text("\(count)").font(.system(size: 10, weight: .semibold)).foregroundStyle(RunnirTheme.mutedForeground)
        }
        .padding(.horizontal, inset).padding(.top, 10).padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }
}

/// Removes a row from a menu bar list: a 28-point target with its own
/// hover, so a near miss removes instead of opening the row under it.
struct ListRemoveButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(hovering ? RunnirTheme.foreground : RunnirTheme.secondaryForeground)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovering ? RunnirTheme.secondary : .clear).frame(width: 22, height: 22))
        }
        .buttonStyle(.hit)
        .onHover { hovering = $0 }
    }
}
```

  - In `PullRequestRow`:
    - delete the nested `private struct RemoveButton`;
    - change `RemoveButton(action: dismiss)` to `ListRemoveButton(action: dismiss)`;
    - remove the comment above it, which moved to `ListRemoveButton`.
  - In `PullRequestsList`:
    - delete the private `chip(_:_:_:_:)` and `sectionHeader(_:count:)`;
    - write `ListChip(symbol: "xmark.circle.fill", label: "\(failing) failing", tint: RunnirTheme.destructive, background: PullRequestColors.failedSoft)` and the like;
    - write `ListSectionHeader(title: "OPEN", count: model.open.count, inset: inset)` and `ListSectionHeader(title: "CLOSED TODAY", count: model.closed.count, inset: inset)`.

- [ ] **Step 3: Build and run the pull request tests**

Run: `xcodebuild … test -only-testing:RunnirTests/PullRequestsTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add apps/macos/Runnir/Features/Desktop/PullRequestsViews.swift apps/macos/Runnir/App/Desktop/DesktopCoordinator.swift apps/macos/RunnirTests/PullRequestsTests.swift
git commit -m "App: one dismissal store and shared chip, header and remove button for the menu bar lists"
```

---

### Task 8: The watched runs model

**Files:**
- Create: `apps/macos/Runnir/Features/Desktop/WatchedRuns.swift`
- Create: `apps/macos/Runnir/Features/Desktop/WatchedRunsViews.swift` (empty for now: `import SwiftUI`)
- Create: `apps/macos/RunnirTests/WatchedRunsTests.swift`
- Modify: `apps/macos/Runnir.xcodeproj/project.pbxproj`
- Modify: `apps/macos/Runnir/Features/Desktop/MenuBarIcon.swift`

**Interfaces:**
- Consumes: `CoreHub.watchedRuns` (Task 6), `FileDismissalStore` (Task 7), `ActivityFreshnessText.relative(_:_:)`.
- Produces:
  - `enum WatchedRepositories { static func of(workspaces: [WorkspaceRecord], isOpen: (UUID) -> Bool, starred: [String]) -> [CoreWatchedRepository] }`;
  - `struct WatchedRun: Identifiable { let run: CoreWorkflowRun; let repository: CoreWatchedRepository; var id: String }`;
  - `final class WatchedRunsModel` (`answers`, `pauses`, `loadedAt`, `isLoading`, `unanswered`, `dismissed`, `failed`, `running`, `watched`, `skipped`, `unwatched`, `offline`, `oldestRead`, `pausedUntil`, `badge`, `repositories`, `refresh(hub:force:)`, `refreshIfStale(hub:)`, `dismiss(_:)`, `restoreDismissed()`, `startPolling(hub:retry:isSignedIn:)`, `stopPolling()`);
  - `enum MenuListTab: String { case pullRequests, runs; static let defaultsKey; var title: String; var segment: String }`;
  - `enum WatchedRunText` (title, subtitle, action and the notes);
  - `MenuBarIcon.badge(for:runs:)` and `MenuBarIcon.accessibilityLabel(checks:runs:)`.

- [ ] **Step 1: Add the three files to the project.** In `project.pbxproj`:
  - PBXBuildFile section:
    `BB3900000000000000001001 = {isa = PBXBuildFile; fileRef = BB3900000000000000000001; };`, the same for `…1002`/`…0002` and `…1003`/`…0003`.
  - PBXFileReference section:
    `BB3900000000000000000001 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Runnir/Features/Desktop/WatchedRuns.swift; sourceTree = SOURCE_ROOT; };`
    `BB3900000000000000000002 = {…; path = Runnir/Features/Desktop/WatchedRunsViews.swift; …};`
    `BB3900000000000000000003 = {…; path = RunnirTests/WatchedRunsTests.swift; …};`
  - Append `BB3900000000000000000001, BB3900000000000000000002, BB3900000000000000000003` to the children of group `B00000000000000000000021`.
  - Append `BB3900000000000000001001, BB3900000000000000001002` to the files of `A00000000000000000070001 /* Sources */` (the app).
  - Append `BB3900000000000000001003` to the files of `A00000000000000000070002 /* Sources */` (the tests).

- [ ] **Step 2: Write the failing tests** (`WatchedRunsTests.swift`)

```swift
import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct WatchedRunsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func readyHub() async -> (CoreHub, FakeProvider) {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.status == .ready(version: "fake") }
        return (hub, provider)
    }

    private func ref(_ key: String) -> GitHubRepositoryRef { GitHubRepositoryRef(key: key)! }

    private func run(_ id: Int64, status: String = "completed", conclusion: String? = "failure", attempt: Int64 = 1,
                     minutesAgo: Double = 5, starts: [CoreRunnirStart] = []) -> CoreWorkflowRun {
        let at = now.addingTimeInterval(-minutesAgo * 60)
        return CoreWorkflowRun(id: id, workflowID: 1, name: "CI", displayTitle: "Fix login", runNumber: id, event: "push",
                               status: status, conclusion: conclusion, branch: "main", headSHA: "abc", actor: "ana",
                               htmlURL: URL(string: "https://github.com/o/r/actions/runs/\(id)"), createdAt: at, updatedAt: at,
                               runAttempt: attempt, runnirStarts: starts)
    }

    private func answer(_ key: String, failed: [CoreWorkflowRun] = [], running: [CoreWorkflowRun] = [],
                        access: CoreGitHubAccess = .ok, watched: Bool = true, workspaces: [UUID] = []) -> CoreWatchedRuns {
        CoreWatchedRuns(repository: CoreWatchedRepository(repository: ref(key), workspaceIDs: workspaces), access: access,
                        watched: watched, failed: failed, running: running, readAt: now)
    }

    @Test func workspacesComeFirstThenStarredOnceEach() {
        let a = UUID(), b = UUID(), c = UUID()
        let ghe = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"
        let workspaces = [
            WorkspaceRecord(id: a, path: "/a", name: "a", bookmark: Data(), lastOpenedAt: now, githubRepository: "o/r"),
            WorkspaceRecord(id: UUID(), path: "/n", name: "n", bookmark: Data(), lastOpenedAt: now),
            WorkspaceRecord(id: b, path: "/b", name: "b", bookmark: Data(), lastOpenedAt: now, githubRepository: "O/R"),
            WorkspaceRecord(id: c, path: "/c", name: "c", bookmark: Data(), lastOpenedAt: now, githubRepository: "\(ghe):corp/app"),
        ]
        let sent = WatchedRepositories.of(workspaces: workspaces, isOpen: { $0 == b }, starred: ["o/R", "o/s", "not a key"])
        #expect(sent.map(\.repository.key) == ["o/r", "\(ghe):corp/app", "o/s"])
        #expect(sent[0].workspaceIDs == [b, a], "the open one first: a click opens it")
        #expect(sent[1].workspaceIDs == [c] && sent[2].workspaceIDs.isEmpty)
    }

    @Test func sectionsChipsAndTheDot() async {
        let (hub, provider) = await readyHub()
        provider.core.watchedRunsResult = CoreWatchedRunsList(repositories: [
            answer("o/r", failed: [run(1, minutesAgo: 30)], running: [run(2, status: "queued", conclusion: nil, minutesAgo: 9)]),
            answer("o/s", failed: [run(3, minutesAgo: 2)], running: [run(4, status: "in_progress", conclusion: nil, minutesAgo: 1)]),
            answer("o/gone", access: .notVisible),
            answer("o/far", watched: false),
        ], pauses: [:])
        let model = WatchedRunsModel(store: nil)
        model.repositories = { [CoreWatchedRepository(repository: GitHubRepositoryRef(key: "o/r")!)] }
        await model.refresh(hub: hub)
        #expect(model.failed.map(\.run.id) == [3, 1])
        #expect(model.running.map(\.run.id) == [4, 2])
        #expect(model.skipped.map(\.repository.repository.fullName) == ["o/gone"] && model.unwatched.count == 1)
        #expect(model.watched.count == 3 && model.badge == .failed)
        #expect(provider.core.watchedRunsCalls.first?.refresh == false)
        await model.refresh(hub: hub, force: true)
        #expect(provider.core.watchedRunsCalls.last?.refresh == true)
    }

    @Test func aRemovedRunStaysRemovedUntilAnotherAttemptFails() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("runs-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (hub, provider) = await readyHub()
        provider.core.watchedRunsResult = CoreWatchedRunsList(repositories: [answer("o/r", failed: [run(5)])], pauses: [:])
        let store = FileDismissalStore(directory: folder, fileName: FileDismissalStore.runsFile)
        let model = WatchedRunsModel(store: store)
        model.repositories = { [CoreWatchedRepository(repository: GitHubRepositoryRef(key: "o/r")!)] }
        await model.refresh(hub: hub)
        model.dismiss(try #require(model.failed.first))
        #expect(model.failed.isEmpty && model.badge == .none)

        let again = WatchedRunsModel(store: store)
        again.repositories = model.repositories
        await again.refresh(hub: hub)
        #expect(again.failed.isEmpty, "kept on this Mac")
        provider.core.watchedRunsResult = CoreWatchedRunsList(repositories: [answer("o/r", failed: [run(5, attempt: 2)])], pauses: [:])
        await again.refresh(hub: hub)
        #expect(again.failed.map(\.run.runAttempt) == [2], "a re-run that failed again comes back")
        again.restoreDismissed()
        #expect(again.dismissed.isEmpty)
    }

    @Test func nothingToWatchAsksNothing() async {
        let (hub, provider) = await readyHub()
        let model = WatchedRunsModel(store: nil)
        await model.refresh(hub: hub)
        #expect(provider.core.watchedRunsCalls.isEmpty && model.answers.isEmpty && model.loadedAt != nil)
    }

    @Test func pollingAsksAgainWhenTheWatchedRepositoriesChange() async {
        let (hub, provider) = await readyHub()
        provider.core.watchedRunsResult = CoreWatchedRunsList(repositories: [], pauses: [:])
        let model = WatchedRunsModel(store: nil)
        var keys = ["o/r"]
        model.repositories = { keys.map { CoreWatchedRepository(repository: GitHubRepositoryRef(key: $0)!) } }
        model.startPolling(hub: hub, retry: .milliseconds(20)) { true }
        defer { model.stopPolling() }
        #expect(await eventually { provider.core.watchedRunsCalls.count == 1 })
        keys.append("o/s")
        #expect(await eventually { provider.core.watchedRunsCalls.last?.repositories.count == 2 })
    }

    @Test func theDotAndTheLabelNameBothLists() {
        #expect(MenuBarIcon.badge(for: .passed, runs: .failed) == .failed)
        #expect(MenuBarIcon.badge(for: .failed, runs: .running) == .failed)
        #expect(MenuBarIcon.badge(for: .running, runs: .none) == .running)
        #expect(MenuBarIcon.badge(for: nil, runs: .running) == .running)
        #expect(MenuBarIcon.badge(for: .passed, runs: .none) == .none)
        #expect(MenuBarIcon.accessibilityLabel(checks: .running, runs: .failed) == "Runnir, a run failed, checks running")
        #expect(MenuBarIcon.accessibilityLabel(checks: .passed, runs: .none) == "Runnir")
    }

    @Test func aRowSaysWhatItIsAndWhatAClickDoes() {
        let workspace = UUID()
        let mine = WatchedRun(run: run(1, minutesAgo: 4), repository: CoreWatchedRepository(repository: ref("o/r"), workspaceIDs: [workspace]))
        #expect(WatchedRunText.title(mine.run) == "CI · Fix login")
        #expect(WatchedRunText.subtitle(mine, host: nil, now: now) == "o/r · main · failed 4 minutes ago")
        #expect(WatchedRunText.subtitle(mine, host: "ghe.test", now: now).hasPrefix("ghe.test · o/r"))
        #expect(WatchedRunText.action(mine) { $0 == workspace ? "runnir" : nil } == "Open in runnir")
        let starred = WatchedRun(run: run(2, status: "queued", conclusion: nil, minutesAgo: 1), repository: CoreWatchedRepository(repository: ref("o/s")))
        #expect(WatchedRunText.subtitle(starred, host: nil, now: now) == "o/s · main · queued 1 minute ago")
        #expect(WatchedRunText.action(starred) { _ in nil } == "Open on GitHub")
        let at = now.addingTimeInterval(-120 * 60)
        let timedOut = CoreWorkflowRun(id: 3, workflowID: 1, name: "Deploy", displayTitle: "Deploy", runNumber: 3, event: "push",
                                       status: "completed", conclusion: "timed_out", branch: "main", headSHA: "abc", actor: "ana",
                                       htmlURL: nil, createdAt: at, updatedAt: at)
        #expect(WatchedRunText.title(timedOut) == "Deploy", "the title alone when it is the workflow's name")
        #expect(WatchedRunText.subtitle(WatchedRun(run: timedOut, repository: starred.repository), host: nil, now: now) == "o/s · main · timed out 2 hours ago")
    }

    @Test func theNotesUnderTheList() {
        #expect(WatchedRunText.updated(count: 14) == " · 14 repositories" && WatchedRunText.updated(count: 1) == " · 1 repository")
        #expect(WatchedRunText.skipped(1) == "1 repository skipped: Runnir can't read its Actions.")
        #expect(WatchedRunText.skipped(2) == "2 repositories skipped: Runnir can't read their Actions.")
        #expect(WatchedRunText.budget(watched: 100, total: 130) == "Watching 100 of 130 repositories: workspaces first, then starred ones in the order you starred them.")
        #expect(WatchedRunText.scope(workspaces: 9, starred: 5) == "Your runs in 9 workspaces and 5 starred repositories.")
        #expect(WatchedRunText.scope(workspaces: 1, starred: 0) == "Your runs in 1 workspace.")
        #expect(WatchedRunText.scope(workspaces: 0, starred: 1) == "Your runs in 1 starred repository.")
        #expect(WatchedRunText.paused(until: now, readAt: now).hasPrefix("Paused until "))
        #expect(WatchedRunText.paused(until: now, readAt: now).contains(" to keep the GitHub rate limit. These runs were read at "))
        #expect(WatchedRunText.offline(readAt: nil) == "GitHub can't be reached.")
        #expect(WatchedRunText.offline(readAt: now).hasPrefix("GitHub can't be reached. These runs were read at "))
    }
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `xcodebuild … test -only-testing:RunnirTests/WatchedRunsTests 2>&1 | tail -5`
Expected: build FAILS, `cannot find 'WatchedRepositories' in scope`.

- [ ] **Step 4: Implement `WatchedRuns.swift`**

```swift
import Foundation
import Observation

// MARK: Which repositories

/// The repositories the Runs tab watches (B39).
enum WatchedRepositories {
    /// The repositories of registered workspaces linked to GitHub, in the
    /// registry's order of their first workspace, each with all its
    /// workspaces, open ones first (a click opens the first); then the
    /// starred repositories in the order they were starred. A repository is
    /// listed once, whatever the case of its name.
    static func of(workspaces: [WorkspaceRecord], isOpen: (UUID) -> Bool, starred: [String]) -> [CoreWatchedRepository] {
        var out: [CoreWatchedRepository] = []
        var position: [String: Int] = [:]
        for workspace in workspaces {
            guard let key = workspace.githubRepository, let ref = GitHubRepositoryRef(key: key) else { continue }
            if let at = position[ref.key.lowercased()] {
                out[at].workspaceIDs.append(workspace.id)
            } else {
                position[ref.key.lowercased()] = out.count
                out.append(CoreWatchedRepository(repository: ref, workspaceIDs: [workspace.id]))
            }
        }
        for index in out.indices {
            let ids = out[index].workspaceIDs
            out[index].workspaceIDs = ids.filter(isOpen) + ids.filter { !isOpen($0) }
        }
        for key in starred {
            guard let ref = GitHubRepositoryRef(key: key), position[ref.key.lowercased()] == nil else { continue }
            position[ref.key.lowercased()] = out.count
            out.append(CoreWatchedRepository(repository: ref))
        }
        return out
    }
}

// MARK: Model

/// A failed or running run of a watched repository.
struct WatchedRun: Equatable, Identifiable, Sendable {
    let run: CoreWorkflowRun
    let repository: CoreWatchedRepository
    /// Its server, run and attempt: a re-run that fails again is a new row.
    var id: String { "\(repository.repository.serverID):\(run.id):\(run.runAttempt)" }
}

/// The tab the menu bar window and the Pull Requests window show, kept in
/// UserDefaults and shared by both.
enum MenuListTab: String, CaseIterable, Sendable {
    case pullRequests, runs

    static let defaultsKey = "menuListTab"

    /// The window's title.
    var title: String { self == .pullRequests ? "Pull Requests" : "Runs" }
    /// The control's label.
    var segment: String { self == .pullRequests ? "Pull requests" : "Runs" }
}

/// The signed-in user's failed and running runs in the watched
/// repositories, for the Runs tab and the menu bar icon (B39). Asked of the
/// Core every three minutes while signed in, when the menu or window opens
/// and when the watched repositories change.
@MainActor
@Observable
final class WatchedRunsModel {
    private(set) var answers: [CoreWatchedRuns] = []
    /// Servers the Core reads nothing from until a time, by server id.
    private(set) var pauses: [String: Date] = [:]
    private(set) var loadedAt: Date?
    private(set) var isLoading = false
    /// The last ask got no answer: the Core is not ready or failed.
    private(set) var unanswered = false
    private(set) var dismissed: [String: Date] = [:]
    @ObservationIgnored private let store: FileDismissalStore?
    @ObservationIgnored private var poll: Task<Void, Never>?
    /// What the last answer was for; nil before any.
    @ObservationIgnored private var sent: [CoreWatchedRepository]?
    @ObservationIgnored var now: () -> Date = Date.init
    /// What to watch, read at every ask; the app delegate sets it.
    @ObservationIgnored var repositories: @MainActor () -> [CoreWatchedRepository] = { [] }

    static let pollInterval: Duration = .seconds(180)
    static let staleAfter: TimeInterval = 60

    init(store: FileDismissalStore?) {
        self.store = store
        let loaded = (try? store?.load()) ?? [:]
        let cutoff = Date().addingTimeInterval(-FileDismissalStore.keepFor)
        dismissed = loaded.filter { $0.value > cutoff }
    }

    /// The repositories read: the first 100.
    var watched: [CoreWatchedRuns] { answers.filter(\.watched) }
    /// Watched repositories whose Actions Runnir can't read.
    var skipped: [CoreWatchedRuns] { watched.filter { $0.access == .notVisible || $0.access == .permissionMissing } }
    /// Beyond the first 100: not read.
    var unwatched: [CoreWatchedRuns] { answers.filter { !$0.watched } }
    /// GitHub did not answer for some repositories; their runs are as read before.
    var offline: Bool { watched.contains { $0.access == .unavailable } }
    /// The oldest read of the runs listed; nil when none was read.
    var oldestRead: Date? { watched.compactMap(\.readAt).min() }
    /// When the latest pause of a server ends; nil when none is paused.
    var pausedUntil: Date? { pauses.values.filter { $0 > now() }.max() }

    /// Failed runs not removed from the list, newest first.
    var failed: [WatchedRun] {
        rows(\.failed).filter { dismissed[$0.id] == nil }
            .sorted { ($0.run.updatedAt ?? .distantPast) > ($1.run.updatedAt ?? .distantPast) }
    }

    /// Running runs, newest first.
    var running: [WatchedRun] {
        rows(\.running).sorted { ($0.run.createdAt ?? .distantPast) > ($1.run.createdAt ?? .distantPast) }
    }

    /// The menu bar dot for the runs alone.
    var badge: MenuBarIcon.Badge { !failed.isEmpty ? .failed : running.isEmpty ? .none : .running }

    private func rows(_ list: KeyPath<CoreWatchedRuns, [CoreWorkflowRun]>) -> [WatchedRun] {
        watched.flatMap { answer in answer[keyPath: list].map { WatchedRun(run: $0, repository: answer.repository) } }
    }

    /// Asks the Core; `force` reads every repository on GitHub again.
    func refresh(hub: CoreHub, force: Bool = false) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let asked = repositories()
        guard !asked.isEmpty else {
            answers = []
            pauses = [:]
            unanswered = false
            sent = asked
            loadedAt = now()
            return
        }
        guard let result = await hub.watchedRuns(asked, refresh: force) else {
            unanswered = true
            return // keep what was read
        }
        answers = result.repositories
        pauses = result.pauses
        unanswered = false
        sent = asked
        loadedAt = now()
    }

    /// Asks again when the list is older than a minute or watches other repositories.
    func refreshIfStale(hub: CoreHub) async {
        if let loadedAt, now().timeIntervalSince(loadedAt) < Self.staleAfter, !unanswered, sent == repositories() { return }
        await refresh(hub: hub)
    }

    /// Removes a failed run's attempt from the list, on this Mac.
    func dismiss(_ run: WatchedRun) {
        var candidate = dismissed
        candidate[run.id] = now()
        let cutoff = now().addingTimeInterval(-FileDismissalStore.keepFor)
        candidate = candidate.filter { $0.value > cutoff }
        try? store?.save(candidate)
        dismissed = candidate
    }

    /// Brings back the runs removed from the list.
    func restoreDismissed() {
        try? store?.save([:])
        dismissed = [:]
    }

    /// Asks every three minutes while `isSignedIn` holds, looking every
    /// `retry`: a sign-in or a change of the watched repositories is read
    /// within seconds, and a sign-out clears the list.
    func startPolling(hub: CoreHub, retry: Duration = .seconds(5), isSignedIn: @escaping @MainActor () -> Bool) {
        poll?.cancel()
        poll = Task { [weak self] in
            let clock = ContinuousClock()
            var lastRead: ContinuousClock.Instant?
            while !Task.isCancelled {
                guard let self else { return }
                if !isSignedIn() {
                    self.clear()
                    lastRead = nil
                } else {
                    // Until a first answer, an unready Core is asked again soon.
                    let every = self.loadedAt == nil && self.unanswered ? retry : Self.pollInterval
                    let changed = self.sent.map { $0 != self.repositories() } ?? false
                    if changed || lastRead.map({ clock.now - $0 >= every }) ?? true {
                        lastRead = clock.now
                        await self.refresh(hub: hub)
                    }
                }
                try? await Task.sleep(for: retry)
            }
        }
    }

    func stopPolling() {
        poll?.cancel()
        poll = nil
    }

    private func clear() {
        guard loadedAt != nil || !answers.isEmpty || sent != nil else { return }
        answers = []
        pauses = [:]
        loadedAt = nil
        unanswered = false
        sent = nil
    }
}

// MARK: Text

/// The words of the Runs tab, kept apart from the views to be tested.
enum WatchedRunText {
    /// "Workflow · title"; the title alone when it is the workflow's name.
    static func title(_ run: CoreWorkflowRun) -> String {
        run.displayTitle.isEmpty || run.displayTitle == run.name ? run.name : "\(run.name) · \(run.displayTitle)"
    }

    /// "host · owner/name · branch · failed 4 minutes ago", the host only when given.
    static func subtitle(_ row: WatchedRun, host: String?, now: Date) -> String {
        var parts = [row.repository.repository.fullName, row.run.branch, when(row.run, now: now)].filter { !$0.isEmpty }
        if let host { parts.insert(host, at: 0) }
        return parts.joined(separator: " · ")
    }

    /// What the run did and how long ago.
    static func when(_ run: CoreWorkflowRun, now: Date) -> String {
        let at: Date?
        let word: String
        switch (run.status, run.conclusion) {
        case ("completed", "timed_out"): (word, at) = ("timed out", run.updatedAt)
        case ("completed", _): (word, at) = ("failed", run.updatedAt)
        case ("in_progress", _): (word, at) = ("started", run.createdAt)
        case ("waiting", _): (word, at) = ("waiting", run.createdAt)
        default: (word, at) = ("queued", run.createdAt)
        }
        guard let at else { return word }
        return word + " " + ActivityFreshnessText.relative(at, now)
    }

    /// What a click does: its workspace's window, or GitHub.
    static func action(_ row: WatchedRun, workspaceName: (UUID) -> String?) -> String {
        if let id = row.repository.workspaceIDs.first, let name = workspaceName(id) { return "Open in \(name)" }
        return "Open on GitHub"
    }

    /// After "Updated …": the number of repositories watched.
    static func updated(count: Int) -> String {
        " · \(count) " + (count == 1 ? "repository" : "repositories")
    }

    static func skipped(_ count: Int) -> String {
        count == 1
            ? "1 repository skipped: Runnir can't read its Actions."
            : "\(count) repositories skipped: Runnir can't read their Actions."
    }

    static func budget(watched: Int, total: Int) -> String {
        "Watching \(watched) of \(total) repositories: workspaces first, then starred ones in the order you starred them."
    }

    /// Under "No failed or running runs".
    static func scope(workspaces: Int, starred: Int) -> String {
        var parts: [String] = []
        if workspaces > 0 { parts.append("\(workspaces) " + (workspaces == 1 ? "workspace" : "workspaces")) }
        if starred > 0 { parts.append("\(starred) starred " + (starred == 1 ? "repository" : "repositories")) }
        return "Your runs in " + parts.joined(separator: " and ") + "."
    }

    static func paused(until: Date, readAt: Date?) -> String {
        let read = readAt.map { " These runs were read at \(time($0))." } ?? ""
        return "Paused until \(time(until)) to keep the GitHub rate limit." + read
    }

    static func offline(readAt: Date?) -> String {
        "GitHub can't be reached." + (readAt.map { " These runs were read at \(time($0))." } ?? "")
    }

    private static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}
```

- [ ] **Step 5: The icon** (in `MenuBarIcon.swift`, after `badge(for:)`)

```swift
    /// The worse of the pull request checks and the watched runs (B39).
    static func badge(for ci: CorePullRequestCI?, runs: Badge) -> Badge {
        let checks = badge(for: ci)
        if checks == .failed || runs == .failed { return .failed }
        if checks == .running || runs == .running { return .running }
        return .none
    }

    /// "Runnir, a run failed, checks running": what the dot stands for.
    static func accessibilityLabel(checks ci: CorePullRequestCI?, runs: Badge) -> String {
        var parts = ["Runnir"]
        switch runs {
        case .failed: parts.append("a run failed")
        case .running: parts.append("runs in progress")
        case .none: break
        }
        switch badge(for: ci) {
        case .failed: parts.append("a check failed")
        case .running: parts.append("checks running")
        case .none: break
        }
        return parts.joined(separator: ", ")
    }
```

  Also change the type's doc comment to: "…with a colored dot for pull request checks and the user's runs."

- [ ] **Step 6: Run the tests to verify they pass**

Run: `xcodebuild … test -only-testing:RunnirTests/WatchedRunsTests 2>&1 | tail -5`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add apps/macos/Runnir.xcodeproj/project.pbxproj apps/macos/Runnir/Features/Desktop/WatchedRuns.swift apps/macos/Runnir/Features/Desktop/WatchedRunsViews.swift apps/macos/Runnir/Features/Desktop/MenuBarIcon.swift apps/macos/RunnirTests/WatchedRunsTests.swift
git commit -m "App: the watched repositories, their failed and running runs, removed rows and the menu bar dot from both lists (B39)"
```

---

### Task 9: The Runs tab, the tabs in the menu and the window, and the wiring

**Files:**
- Modify: `apps/macos/Runnir/Features/Desktop/WatchedRunsViews.swift`
- Modify: `apps/macos/Runnir/Features/Desktop/PullRequestsViews.swift` (`PullRequestsMenu`, `PullRequestsWindowView`)
- Modify: `apps/macos/Runnir/App/Desktop/DesktopCoordinator.swift`
- Modify: `apps/macos/Runnir/App/RunnirApp.swift`

**Interfaces:**
- Consumes: Tasks 7 and 8.
- Produces:
  - `struct MenuListTabPicker: View`;
  - `struct WatchedRunsList: View`;
  - `struct WatchedRunRow: View`;
  - `DesktopCoordinator.watchedRuns`;
  - `DesktopCoordinator.watchedRepositories`;
  - `DesktopCoordinator.showRun(_:workspaceID:)`.

- [ ] **Step 1: Views** (`WatchedRunsViews.swift`)

```swift
import SwiftUI

/// The control at the top of the menu bar window and the Pull Requests
/// window: Pull requests | Runs. The Runs segment carries the number of
/// failed runs in a neutral count, in the colour of the control.
struct MenuListTabPicker: View {
    @Binding var tab: MenuListTab
    let failedCount: Int

    var body: some View {
        HStack(spacing: 2) {
            segment(.pullRequests, count: 0)
            segment(.runs, count: failedCount)
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(RunnirTheme.secondary))
        .accessibilityElement(children: .contain)
    }

    private func segment(_ value: MenuListTab, count: Int) -> some View {
        let chosen = tab == value
        return Button { tab = value } label: {
            HStack(spacing: 5) {
                Text(value.segment).font(.system(size: 12, weight: .medium))
                if count > 0 {
                    Text("\(count)").font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(RunnirTheme.foreground.opacity(0.1)))
                }
            }
            .foregroundStyle(chosen ? RunnirTheme.foreground : RunnirTheme.secondaryForeground)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(chosen ? RunnirTheme.background : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.hit)
        .accessibilityLabel(count > 0 ? "\(value.segment), \(count) failed" : value.segment)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// One failed or running run (S19): its status, "Workflow · title" and
/// where and when. Hovering highlights it and says what a click does; a
/// failed one can be removed from the list.
struct WatchedRunRow: View {
    let row: WatchedRun
    /// The server's host, shown when more than one account is signed in.
    var serverHost: String? = nil
    let action: String
    let open: () -> Void
    var dismiss: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(WatchedRunText.title(row.run)).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    subtitle(now: context.date).font(.system(size: 11)).lineLimit(1)
                }
            }
            if hovering {
                Text(action).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1).padding(.top, 2)
            }
            if let dismiss {
                ListRemoveButton(action: dismiss)
                    .opacity(hovering ? 1 : 0)
                    .padding(.top, -6).padding(.trailing, -6)
                    .help("Remove from this list")
                    .accessibilityLabel("Remove \(WatchedRunText.title(row.run)) from this list")
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? RunnirTheme.selected : .clear))
        .clickable()
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help(action)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(perform: open)
        .accessibilityAction(named: "Remove from this list") { dismiss?() }
    }

    /// "From Runnir · " in the accent colour before the rest.
    private func subtitle(now: Date) -> Text {
        let rest = Text(WatchedRunText.subtitle(row, host: serverHost, now: now)).foregroundStyle(RunnirTheme.secondaryForeground)
        guard row.run.startedFromRunnir else { return rest }
        return Text(RunPresentation.fromRunnirLabel + " · ").foregroundStyle(RunnirTheme.primary) + rest
    }

    @ViewBuilder private var icon: some View {
        let status = RunStatusFilter.of(row.run) ?? (row.run.status == "completed" ? .failed : .queued)
        if row.run.conclusion == "timed_out" {
            Image(systemName: "clock.badge.xmark").foregroundStyle(RunnirTheme.destructive).accessibilityLabel("Timed out")
        } else {
            Image(systemName: status.symbol).foregroundStyle(status.tint).accessibilityLabel(status.label)
        }
    }
}

/// The Runs tab (S19, B39): the user's failed and running runs across
/// registered workspaces and starred repositories.
struct WatchedRunsList: View {
    let model: WatchedRunsModel
    let desktop: DesktopCoordinator
    var inset: CGFloat = 16
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch PullRequestsListState.of(desktop) {
            case .restoring:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the saved sign-in...") }
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .padding(.horizontal, inset).padding(.vertical, 16)
            case .signedOut:
                PullRequestsSignedOut(desktop: desktop)
            case .lists:
                lists
            }
        }
    }

    @ViewBuilder private var lists: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            if let until = model.pausedUntil {
                note(WatchedRunText.paused(until: until, readAt: model.oldestRead), symbol: "pause.circle")
            } else if model.offline {
                note(WatchedRunText.offline(readAt: model.oldestRead), symbol: "wifi.slash")
            }
        }
        summary
        if model.loadedAt != nil, model.answers.isEmpty {
            nothingToWatch
        } else if model.failed.isEmpty && model.running.isEmpty {
            nothingListed
        } else {
            DesignDivider()
            if !model.failed.isEmpty {
                ListSectionHeader(title: "FAILED", count: model.failed.count, inset: inset)
                ForEach(model.failed) { row in
                    WatchedRunRow(row: row, serverHost: host(of: row), action: action(row), open: { open(row) }) { model.dismiss(row) }
                        .padding(.horizontal, inset - 8)
                }
            }
            if !model.running.isEmpty {
                ListSectionHeader(title: "RUNNING", count: model.running.count, inset: inset)
                ForEach(model.running) { row in
                    WatchedRunRow(row: row, serverHost: host(of: row), action: action(row), open: { open(row) })
                        .padding(.horizontal, inset - 8)
                }
            }
        }
        if !model.skipped.isEmpty {
            note(WatchedRunText.skipped(model.skipped.count), symbol: "eye.slash")
                .help(model.skipped.map(\.repository.repository.fullName).joined(separator: ", "))
                .padding(.top, 10)
        }
        if !model.unwatched.isEmpty {
            note(WatchedRunText.budget(watched: model.watched.count, total: model.answers.count), symbol: "info.circle")
                .help(model.unwatched.map(\.repository.repository.fullName).joined(separator: ", "))
                .padding(.top, 10)
        }
        Color.clear.frame(height: 8)
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, inset).padding(.bottom, 10)
    }

    /// Chips counting failed and running runs.
    @ViewBuilder private var summary: some View {
        let failed = model.failed.count, running = model.running.count
        if failed + running > 0 {
            HStack(spacing: 6) {
                if failed > 0 {
                    ListChip(symbol: "xmark.circle.fill", label: "\(failed) failed", tint: RunnirTheme.destructive, background: PullRequestColors.failedSoft)
                }
                if running > 0 {
                    ListChip(symbol: "arrow.triangle.2.circlepath", label: "\(running) running", tint: PullRequestColors.running, background: PullRequestColors.runningSoft)
                }
            }
            .padding(.horizontal, inset).padding(.bottom, 12)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var nothingListed: some View {
        if model.isLoading && model.loadedAt == nil {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading runs...") }
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .padding(.horizontal, inset).padding(.vertical, 12)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle").font(.system(size: 20)).foregroundStyle(RunnirTheme.success)
                Text("No failed or running runs").font(.system(size: 13, weight: .medium))
                Text(WatchedRunText.scope(workspaces: model.watched.count { !$0.repository.workspaceIDs.isEmpty },
                                          starred: model.watched.count { $0.repository.workspaceIDs.isEmpty }))
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, inset).padding(.top, 14).padding(.bottom, 16)
        }
    }

    private var nothingToWatch: some View {
        VStack(spacing: 6) {
            Image(systemName: "star").font(.system(size: 20)).foregroundStyle(RunnirTheme.secondaryForeground)
            Text("Nothing to watch yet").font(.system(size: 13, weight: .medium))
            Text("Star repositories in the Workspace Manager's GitHub tab, or link a workspace to its GitHub repository, to see your failed and running runs here.")
                .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Workspace Manager") { desktop.showManager() }
                .buttonStyle(DesignButtonStyle()).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, inset).padding(.top, 14).padding(.bottom, 16)
    }

    private func action(_ row: WatchedRun) -> String {
        WatchedRunText.action(row) { id in desktop.snapshot.workspaces.first { $0.id == id }?.name }
    }

    /// A run of a repository with a workspace opens there, in the
    /// inspector; one without opens on GitHub.
    private func open(_ row: WatchedRun) {
        if let id = row.repository.workspaceIDs.first, desktop.snapshot.workspaces.contains(where: { $0.id == id }) {
            desktop.showRun(.run(id: row.run.id, number: row.run.runNumber), workspaceID: id)
        } else if let url = row.run.htmlURL {
            openURL(url)
        }
    }

    /// The run's server host, when more than one account is signed in.
    private func host(of row: WatchedRun) -> String? {
        guard let hub = desktop.core, hub.signedInServers.count > 1 else { return nil }
        let server = row.repository.repository.serverID
        return server.isEmpty ? "github.com" : hub.serverRef(for: server)?.webHost
    }
}
```

- [ ] **Step 2: The menu and the window** (in `PullRequestsViews.swift`)
  - In `PullRequestsMenu`:
    - add `@AppStorage(MenuListTab.defaultsKey) private var tab: MenuListTab = .pullRequests`;
    - in the scroll view use `if tab == .runs { WatchedRunsList(model: desktop.watchedRuns, desktop: desktop) } else { PullRequestsList(model: model, desktop: desktop) }`, with `.frame(maxWidth: .infinity, alignment: .leading)` and the same `onGeometryChange`;
    - change `.task` to refresh both: `.task { if let hub = desktop.core { await model.refreshIfStale(hub: hub); await desktop.watchedRuns.refreshIfStale(hub: hub) } }`.
  - Its header becomes:

```swift
    private var header: some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 6) {
                MenuListTabPicker(tab: $tab, failedCount: desktop.watchedRuns.failed.count)
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    Text(updatedText).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
            }
            Spacer()
            if !signedOut, let hub = desktop.core {
                iconButton("arrow.clockwise", help: tab == .runs ? "Read runs again" : "Read pull requests again") {
                    Task { await refresh(hub) }
                }
                .disabled(tab == .runs ? desktop.watchedRuns.isLoading : model.isLoading)
                iconButton("macwindow", help: "Open the \(tab.title) window") { desktop.showPullRequests() }
            }
        }
        .padding(.top, 12).padding(.bottom, 10).padding(.leading, 16).padding(.trailing, 12)
    }

    private func refresh(_ hub: CoreHub) async {
        if tab == .runs { await desktop.watchedRuns.refresh(hub: hub, force: true) } else { await model.refresh(hub: hub) }
    }

    private var updatedText: String {
        if signedOut { return "Not connected" }
        let loadedAt = tab == .runs ? desktop.watchedRuns.loadedAt : model.loadedAt
        let isLoading = tab == .runs ? desktop.watchedRuns.isLoading : model.isLoading
        guard let loaded = loadedAt else { return isLoading ? "Reading..." : "Not read yet" }
        let when = Date().timeIntervalSince(loaded) < 30 ? "Updated just now" : "Updated " + loaded.formatted(.relative(presentation: .named))
        return tab == .runs ? when + WatchedRunText.updated(count: desktop.watchedRuns.watched.count) : when
    }
```

  - In its footer's signed-in branch:
    - the link becomes `Button("Open \(tab.title) Window") { desktop.showPullRequests() }`;
    - Show Removed becomes:

```swift
                let removed = tab == .runs ? desktop.watchedRuns.dismissed.count : model.dismissed.count
                if removed > 0 {
                    Button("Show Removed (\(removed))") {
                        if tab == .runs { desktop.watchedRuns.restoreDismissed() } else { model.restoreDismissed() }
                    }
                    .buttonStyle(.hit)
                    .foregroundStyle(RunnirTheme.secondaryForeground)
                    .help(tab == .runs ? "Bring back the runs removed from this list" : "Bring back the closed pull requests removed from this list")
                }
```

  - In `PullRequestsWindowView`:
    - add `@AppStorage(MenuListTab.defaultsKey) private var tab: MenuListTab = .pullRequests`;
    - the header row becomes:

```swift
            HStack(spacing: 10) {
                MenuListTabPicker(tab: $tab, failedCount: desktop.watchedRuns.failed.count)
                if let loaded = tab == .runs ? desktop.watchedRuns.loadedAt : model.loadedAt {
                    TimelineView(.periodic(from: .now, by: 15)) { _ in
                        Text("updated \(loaded.formatted(.relative(presentation: .named)))"
                             + (tab == .runs ? WatchedRunText.updated(count: desktop.watchedRuns.watched.count) : ""))
                    }
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
                Spacer()
                if let hub = desktop.core {
                    Button {
                        Task {
                            if tab == .runs { await desktop.watchedRuns.refresh(hub: hub, force: true) } else { await model.refresh(hub: hub) }
                        }
                    } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .buttonStyle(DesignButtonStyle())
                        .disabled(tab == .runs ? desktop.watchedRuns.isLoading : model.isLoading)
                }
            }
```

    - the list becomes `if tab == .runs { WatchedRunsList(model: desktop.watchedRuns, desktop: desktop, inset: 20) } else { PullRequestsList(model: model, desktop: desktop, inset: 20) }`, keeping `.padding(.top, 14).frame(maxWidth: .infinity, alignment: .leading)`;
    - add `.navigationTitle(tab.title)`;
    - change `.task` to refresh both models, as in the menu.

- [ ] **Step 3: The coordinator**
  - Add a `watchedRuns: WatchedRunsModel = WatchedRunsModel(store: nil)` parameter to `init`, after `pullRequests`, with the stored `let`:

```swift
    /// The user's failed and running runs across repositories (B39), for
    /// the Runs tab and the menu bar icon.
    let watchedRuns: WatchedRunsModel
```

  - Add:

```swift
    /// What the Runs tab watches: workspaces' repositories, then starred ones (B39).
    var watchedRepositories: [CoreWatchedRepository] {
        WatchedRepositories.of(workspaces: snapshot.workspaces, isOpen: { openCount($0) > 0 }, starred: repositoryFavorites.names)
    }

    /// Shows a run in a window of its workspace, opened or brought forward,
    /// as a global search result does (B43).
    func showRun(_ destination: SearchDestination, workspaceID: UUID) {
        guard let workspace = snapshot.workspaces.first(where: { $0.id == workspaceID }) else { return }
        openOrFocus(workspace)
        windows.values.first { $0.record.workspaceID == workspaceID }?.navigate(to: destination)
    }
```

  - In `open(_:workspaceID:from:)`, replace the two lines after the `own` check with `showRun(destination, workspaceID: workspaceID)`.
  - In `showPullRequests()`, keep the hosting controller in a constant and bridge the title:

```swift
            let hosting = NSHostingController(rootView: PullRequestsWindowView(model: pullRequests, desktop: self)
                .environment(\.openRunnirSettings) { [weak self] section in self?.showSettingsInFrontWindow(section: section) }
                .handPointerButtons())
            // The window's title follows the tab: "Pull Requests" or "Runs".
            hosting.sceneBridgingOptions = [.title]
            window.contentViewController = hosting
```

  - In `DesktopAppDelegate.init`, pass `watchedRuns: WatchedRunsModel(store: try? FileDismissalStore.live(FileDismissalStore.runsFile))`.
  - In `applicationDidFinishLaunching`, after the pull requests polling starts:

```swift
        // The user's runs across repositories, asked again when what is watched changes.
        desktop.watchedRuns.repositories = { [desktop] in desktop.watchedRepositories }
        desktop.watchedRuns.startPolling(hub: coreHub, isSignedIn: { [github, coreHub] in github.user != nil || !coreHub.signedInServers.isEmpty })
```

- [ ] **Step 4: The icon** (in `RunnirApp.swift`)

```swift
    /// The logo glyph, with a dot when a check or a run failed or runs,
    /// dimmed while no account is signed in.
    private var menuBarImage: NSImage {
        let signedIn = delegate.github.user != nil || !delegate.coreHub.signedInServers.isEmpty
        let badge = MenuBarIcon.badge(for: delegate.desktop.pullRequests.worstCI, runs: delegate.desktop.watchedRuns.badge)
        return MenuBarIcon.image(badge: badge, dimmed: !signedIn)
    }

    private var menuBarLabel: String {
        MenuBarIcon.accessibilityLabel(checks: delegate.desktop.pullRequests.worstCI, runs: delegate.desktop.watchedRuns.badge)
    }
```

- [ ] **Step 5: Build and run every app test**

Run (from the repository root, after the Go PATH export):
- `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build 2>&1 | tail -3`
- `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests 2>&1 | tail -5`

Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Runnir
git commit -m "App: a Runs tab beside Pull requests in the menu bar and the window; a run opens in its workspace or on GitHub (B39)"
```

---

### Task 10: Docs

**Files:**
- Modify: `docs/product/mvp-implementation-checklist.md`
- Modify: `docs/design/screens-and-states.md`
- Modify: `docs/superpowers/specs/2026-10-29-runs-across-repositories-design.md`

- [ ] **Step 1: Checklist.** In the progress table, after the B46 row, add:

```markdown
| B39 | Runs across repositories ([spec](../superpowers/specs/2026-10-29-runs-across-repositories-design.md)): a Runs tab beside Pull requests in the menu bar window and the Pull Requests window lists the signed-in user's failed runs (a workflow on a branch whose newest finished run failed in the last 7 days, removable on this Mac) and running runs, across registered workspaces linked to GitHub and starred repositories. `ListWatchedRuns` answers an open workspace from its store and reads any other repository with `actor` and an ETag at most every 3 minutes, in memory only; 100 repositories at most, a pause below a tenth of the rate limit, repositories without Actions access named; From Runnir (B46) on runs of open and closed workspaces, a closed one's database read read-only. A row opens the run in its workspace's inspector, or on GitHub. The menu bar dot shows the worse of the checks and the runs |
```

- [ ] **Step 2: Screens.** In the S03 row of `screens-and-states.md`, replace `planned: failed and active runs across favorite repositories and workspaces, also in the menu bar (B39);` with `failed and running runs across registered workspaces and starred repositories are in the Runs tab of the menu bar window and the Pull Requests window (built, B39);`.
- [ ] **Step 3: Spec status.** Change the spec's first line to `Status: design approved on 2026-10-29, built on branch dilbarov/runs-across-repositories.`
- [ ] **Step 4: Commit**

```bash
git add docs
git commit -m "Docs: B39 built, the Runs tab and ListWatchedRuns"
```

---

### Task 11: Verify

- [ ] From `core/`: `go test ./... && go vet ./... && go build ./...`. Expected: all pass.
- [ ] From the repository root, with the Go PATH export, run both `xcodebuild` commands of the Global Constraints. Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **`.
- [ ] `git log --format=%B main..HEAD | grep -ci "co-authored\|generated with"`. Expected: `0`.
- [ ] Not covered by unit tests: real GitHub, and the menu bar in the running app. Say so in the handoff.
