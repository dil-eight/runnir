# Runs Linked To Commits And Pull Requests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show which pull request and commit each GitHub Actions run belongs to, hide runs a newer push replaced, offer a "By change" view, keep up to 5000 runs with lazy loading, and suggest a `concurrency` block that the user reviews in the editor.

**Architecture:** The Go Core reads pull requests next to runs in each sync pass (ETag), fills gaps with bounded lookups, and keeps them in the workspace SQLite cache. A new pure package `internal/changes` links runs to pull requests, marks superseded runs, measures overlap, groups runs into changes and builds concurrency hints; the server puts the result into `WorkspaceActivity`. The scanner detects and inserts `concurrency`. The Swift app renders what the Core computed: labels, hidden superseded runs, a `List | By change` switch, inspector links, lazy loading and an undoable editor insertion.

**Tech Stack:** Go 1.27.3 (`CGO_ENABLED=0`), modernc.org/sqlite, `go.yaml.in/yaml/v3`, protobuf + buf, grpc-go; Swift 6, SwiftUI, Observation, AppKit (`NSTextView`), Swift Testing, grpc-swift generated client; Pencil MCP for `docs/design/runnir.pen`.

Spec: [docs/superpowers/specs/2026-10-23-run-change-links-design.md](../specs/2026-10-23-run-change-links-design.md).

## Global Constraints

- Go commands: prefix with `PATH="$HOME/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.27.3.darwin-arm64/bin:$PATH"` and run from `core/`.
- Contract generation: `PATH="<scratchpad>/bin:$HOME/go/bin:$PATH" scripts/generate-contracts.sh`, where `<scratchpad>/bin` holds protoc-gen-swift 1.39.0 and protoc-gen-grpc-swift-2 2.5.0 (build them with `swift build -c release --product <name>` from apple/swift-protobuf 1.39.0 and grpc/grpc-swift-protobuf 2.5.0 if missing). Go plugins: buf v1.65.0, protoc-gen-go v1.36.11, protoc-gen-go-grpc v1.6.1.
- Start from `main` after B25 (branch `b25-repository-presets`) is merged: B25 also changes the proto, `docs/architecture/grpc-api.md` and `OverviewViews.swift` (Run manually). Do not stack on the B25 branch: one open PR at a time.
- No new Go modules or Swift packages. Run `gofmt -w` on changed Go files.
- No backward compatibility before the first release tag (AGENTS.md): the SQLite schema `schemaV1`, the proto and `WorkspaceWindowRecord` change in place; no migration entries, no fallbacks.
- Budgets per workspace: 5000 runs (jobs and steps cascade); pull requests kept when a cached run or lookup names them, plus the 500 most recently updated; at most 10 lookups per pass; gap filling reads at most 10 pages of 100; `LoadOlderRuns` reads 100.
- Sync: 50 newest runs per pass; the pull request list is `GET /repos/{o}/{r}/pulls?state=all&sort=updated&direction=desc&per_page=50` with `If-None-Match`.
- A concurrency hint needs at least 2 runs with an overlap.
- Activity limit: 0 → 200, at most 5000. The app starts at 200 and grows by 200.
- The concurrency block, verbatim:

  ```yaml
  # Newer commits on a pull request or branch cancel its older runs; runs on the default branch, scheduled and manual runs are never cancelled.
  concurrency:
    group: ${{ github.workflow }}-${{ github.event.pull_request.number || (github.event_name == 'push' && github.ref != format('refs/heads/{0}', github.event.repository.default_branch) && github.ref) || github.run_id }}
    cancel-in-progress: true
  ```

- UI text in English. No telemetry. No credentials on disk or in notes. No AI attribution in commits, code, docs or PRs (no `Co-Authored-By`, no "Generated with").
- Commit only the files of the task; never stash, reset or switch branches in a shared checkout.
- Before handing off: from `core/` `go test ./...`, `go vet ./...`, `CGO_ENABLED=0 go build ./...`; then `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build` and `... test -only-testing:RunnirTests` (with the Go 1.27.3 PATH, because the build bundles the Core).

## Spec Adjustments Made While Planning

- "Don't suggest for this workflow" is kept in `UserDefaults` (key `dismissedConcurrencyHints`), like the "Keep job logs" toggle, instead of a JSON file next to the favorites: it is a small per-Mac preference.
- `summarizeCI` is split: the new exported `github.SummarizeRuns` sums up the runs it is given; the menu bar keeps picking the newest run per workflow before calling it, so its counts do not change. Changes pass the newest run per workflow and event.
- The fine-grained token check (`CheckGitHubToken`) is not changed; the token help text adds "Pull requests: Read-only" as the spec says.
- The default branch is read once per runtime and target in the loop goroutine (`Runtime.branchFor`), not stored per pass when unchanged.
- The lazy-loading trigger is a footer row in a `LazyVStack` with `.task(id: runs.count)`, so it asks again while it stays on screen and stops when it scrolls away.
- Development databases created before this change have the old columns. The schema changes in place, so delete `~/Library/Application Support/Runnir/repositories/*/state.sqlite*` once after updating; local run history is restored from `backups/local-data.sqlite` (B26 recovery). Task 15 records this in the PR description.

## File Map

Design:
- `docs/design/runnir.pen` — row D frames (Task 1).

Core (Go):
- `core/internal/github/client.go` — run fields, `OlderRuns` (Task 2).
- `core/internal/github/account.go` — `pull_requests: read` (Task 2).
- New `core/internal/github/repopulls.go` — repository pull requests and lookups (Task 3).
- `core/internal/github/pulls.go` — `SummarizeRuns` (Task 3).
- `core/internal/store/schema.go`, `activity.go` — columns, links, budgets, history (Task 4).
- New `core/internal/store/pulls.go` — pull requests, lookups, older runs (Task 5).
- New `core/internal/changes/{changes.go,link.go,group.go,missing.go,hints.go}` (Tasks 6–7).
- `core/internal/workspace/runtime.go`, new `core/internal/workspace/older.go`, `core/internal/workspace/lookups.go` (Task 8).
- `core/internal/repository/manager.go`, `core/internal/scanner/scanner.go`, new `core/internal/scanner/concurrency.go` (Task 9).
- `contracts/grpc/runnir/core/v1/runnir_core.proto` and generated Go/Swift; `core/internal/server/workspace.go`, `service.go`, new `core/internal/server/changes.go` (Task 10).

App (Swift):
- `apps/macos/Runnir/IPC/CoreGitHubModels.swift`, `CoreWorkspaceModels.swift`, `CoreService.swift`, `GRPCCoreService.swift`, `CoreHub.swift`; tests `CoreHubTests.swift`, `CoreProcessSupervisorTests.swift` (Task 11).
- New `apps/macos/Runnir/Features/Desktop/RunChanges.swift`, new `ConcurrencyHints.swift`; `GitHubAccessHelp.swift`; test `RunChangesTests.swift` (Task 12).
- `GitHubActivityViews.swift`, `RunInspectorView.swift`, `OverviewViews.swift`, new `RunChangeViews.swift`; `App/AppState.swift`, `App/Desktop/DesktopStateStore.swift`, `App/Desktop/DesktopCoordinator.swift`, `DesktopViews.swift` (Task 13).
- `CodeEditor.swift`, `DesktopViews.swift` (`WorkspaceFilesModel`, window); test `WorkflowEditingTests.swift` (Task 14).

Docs (Task 15): `docs/architecture/grpc-api.md`, `docs/architecture/workspace-persistence.md`, `docs/security/github-authentication.md`, `docs/design/screens-and-states.md`, `docs/product/mvp-implementation-checklist.md`, the B26/B27 spec, the B30 spec status line.

---

### Task 1: Design frames in `runnir.pen`, row D

**Files:**
- Modify: `docs/design/runnir.pen` (through the Pencil MCP tools only; `.pen` files are encrypted, never use Read, Grep or Write on them)

**Interfaces:**
- Consumes: the existing Runs frames in row D.
- Produces: frames the Swift tasks follow (13 and 14). Copy and sizes come from this task; where code and frames differ, the frames win unless the spec says otherwise.

- [ ] **Step 1: Load the Pencil tools and read the file**

Load the tools with ToolSearch `select:mcp__pencil__get_app_state,mcp__pencil__execute,mcp__pencil__get_style,mcp__pencil__read_skill,mcp__pencil__browser`. Call `mcp__pencil__read_skill` for the `.pen` schema and the `execute` instructions, then `mcp__pencil__get_app_state` with `docs/design/runnir.pen` open. Find row D (Runs) and the existing Runs frame (run list on the left, 300 points wide; inspector on the right). Note its node id, size (1280 x 800) and the components it uses (RunRow, freshness line, toolbar).

- [ ] **Step 2: Add the frames, to the right of the existing Runs frame in row D, in this order**

1. **D · Runs · List.** Copy of the Runs frame. Above the list: a segmented control `List | By change` (List selected), the current-branch checkbox, Reload. Rows show the new detail line: `CI #881 · main · push · #142 after merge`, `CI #879 · retry · pull_request · #142`, `Nightly #31 · main · schedule · b7c8d9e`. One row with an "outdated" label (capsule, info tint) and its run still running. Last row: `6 superseded runs hidden · Show`.
2. **D · Runs · List with superseded shown.** Same, the footer reads `Hide superseded runs`, and two rows are dimmed with "older commit".
3. **D · Runs · By change.** The segmented control on `By change`. Blocks: merged `#142 Add retry to deploy` (status passed; sections "After merge · main · a1b2c3d" with CI push and Deploy workflow_dispatch, "On the PR · 9f8e7d6 (latest)" with CI pull_request and Lint pull_request; `2 earlier runs on 2 older commits`), open draft `#145 Cache act images` (running), commit `3c4d5e6 Bump Go to 1.25 · main` (failed), commit `b7c8d9e Nightly · main` with `6 earlier runs on this commit`. Under #142 a concurrency banner (see 5).
4. **D · Run inspector · Superseded.** The inspector of an outdated run: under the summary line, "Pull request #142 Add retry to deploy · open" and "Commit 7e8f9a0 Tweak retry count"; "Superseded by CI #883 on a newer commit" (a link); the existing Cancel Run button enabled.
5. **D · Concurrency banner.** In the inspector of a superseded run: "3 runs of CI on older commits kept running after a newer push (about 18 min)." Buttons "Add concurrency…" (primary) and "Don't suggest for this workflow" (link).
6. **D · Runs · Pull requests unreadable.** Runs list with a note under the freshness line: title "Pull requests can't be read", text "Runs after a merge and runs from forks are not linked to their pull requests. Runnir Desktop needs Pull requests (read) on o/r; an owner of o accepts it on GitHub.", button "Review on GitHub...".
7. **D · Runs · Loading older.** The end of a long list: "Loading older runs…" with a small spinner; a second variant "Couldn't load older runs." with Retry; a third "Older runs are on GitHub" with "Open Actions on GitHub".
8. **E · Workspace editor · Concurrency inserted.** In row E next to the existing Workspace editor frame: the editor with the four inserted lines highlighted above `jobs:` and the usual unsaved dot; a second variant with an info banner "This workflow already has a concurrency setting, so nothing was added." and Dismiss.

Use the file's existing components and color tokens; synthetic names only (o/r, octocat).

- [ ] **Step 3: Check the frames**

Take a screenshot of each new frame with the Pencil tools and compare with the existing Runs frame: same sidebar, toolbar height 52, list width 300, 13 pt titles, 11–12 pt metadata. Fix overlaps and clipped text.

- [ ] **Step 4: Commit**

```bash
git add docs/design/runnir.pen
git commit -m "Design: runs linked to pull requests and commits in row D (B30)"
```

---

### Task 2: Runs carry their commit and pull requests; older runs; the pull request permission

**Files:**
- Modify: `core/internal/github/client.go:106-122` (Run), `:215-294` (reads and `runJSON`)
- Modify: `core/internal/github/pulls.go:177` (`r.run()` caller)
- Modify: `core/internal/github/account.go:32` (`RequiredPermissions`)
- Test: `core/internal/github/client_test.go`, `core/internal/github/account_test.go:128-146`, `core/internal/server/dispatch_test.go:260`

**Interfaces:**
- Produces:
  - `github.Run` gains `HeadRepository string` (lowercased `owner/name`), `CommitTitle string`, `PullRequests []int64` (only pull requests whose base is the run's own repository).
  - `func (c *Client) OlderRuns(ctx context.Context, owner, name string, before time.Time, limit int) ([]Run, error)` — runs with `created_at <= before`, newest first, at most `limit` (1–100).
  - `github.RequiredPermissions["pull_requests"] == "read"`.

- [ ] **Step 1: Write the failing tests**

Append to `core/internal/github/client_test.go`:

```go
func TestRunsCarryTheirCommitAndPullRequests(t *testing.T) {
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"workflow_runs":[
			{"id":1,"workflow_id":5,"event":"pull_request","head_branch":"retry","head_sha":"b2","created_at":"2026-10-18T10:00:00Z",
			 "head_repository":{"full_name":"O/R"},"head_commit":{"message":"Add retry\n\nWith a longer body"},
			 "pull_requests":[{"number":142,"base":{"repo":{"url":"https://api.github.com/repos/o/r"}}},
			                  {"number":9,"base":{"repo":{"url":"https://api.github.com/repos/upstream/r"}}}]},
			{"id":2,"workflow_id":5,"event":"push","head_branch":"main","head_sha":"c3","created_at":"2026-10-18T09:00:00Z",
			 "head_repository":null,"head_commit":null,"pull_requests":null}]}`))
	})
	runs, _, err := client.RunsIfChanged(context.Background(), "o", "r", 50, "")
	if err != nil || len(runs) != 2 {
		t.Fatalf("runs = %+v, %v", runs, err)
	}
	first := runs[0]
	// In a fork GitHub also lists the upstream's pull requests: only this
	// repository's are kept.
	if first.HeadRepository != "o/r" || first.CommitTitle != "Add retry" || len(first.PullRequests) != 1 || first.PullRequests[0] != 142 {
		t.Fatalf("first = %+v", first)
	}
	if second := runs[1]; second.HeadRepository != "" || second.CommitTitle != "" || second.PullRequests != nil {
		t.Fatalf("second = %+v", second)
	}
}

func TestOlderRunsAskForRunsCreatedUpToATime(t *testing.T) {
	before := time.Date(2026, 10, 1, 10, 0, 0, 0, time.UTC)
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		query := r.URL.Query()
		if r.URL.Path != "/repos/o/r/actions/runs" || query.Get("created") != "<=2026-10-01T10:00:00Z" || query.Get("per_page") != "100" {
			t.Errorf("request = %s", r.URL)
		}
		_, _ = w.Write([]byte(`{"workflow_runs":[{"id":3,"workflow_id":5,"created_at":"2026-10-01T09:00:00Z","head_commit":{"message":"Old"}}]}`))
	})
	runs, err := client.OlderRuns(context.Background(), "o", "r", before, 100)
	if err != nil || len(runs) != 1 || runs[0].ID != 3 || runs[0].CommitTitle != "Old" {
		t.Fatalf("runs = %+v, %v", runs, err)
	}
}
```

Make sure `client_test.go` imports `time` (add it to the import block if missing).

In `core/internal/github/account_test.go`, change the installations fixture and expectation so the new permission is part of what an up-to-date installation has:

```go
				{"id":1,"account":{"login":"Current","type":"Organization"},"permissions":{"actions":"write","contents":"write","metadata":"read","pull_requests":"read"}},
				{"id":2,"account":{"login":"behind","type":"User"},"permissions":{"actions":"read","metadata":"read"}},
				{"id":3,"account":{"login":"paused","type":"Organization"},"permissions":{"actions":"write","contents":"read","metadata":"read","pull_requests":"read"},"suspended_at":"2026-10-01T00:00:00Z"}]}`))
```

```go
	if strings.Join(installations[1].MissingPermissions, ",") != "actions: write,contents: read,pull_requests: read" {
```

In `core/internal/server/dispatch_test.go:260`, add `"pull_requests":"read"` to the installation's permissions so the test still sees only `actions: write` missing:

```go
			_, _ = w.Write([]byte(`{"total_count":1,"installations":[{"id":5,"account":{"login":"o","type":"Organization"},"repository_selection":"selected","html_url":"https://github.com/organizations/o/settings/installations/5","permissions":{"actions":"read","contents":"read","metadata":"read","pull_requests":"read"}}]}`))
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `go test ./internal/github/ -run 'TestRunsCarryTheirCommitAndPullRequests|TestOlderRunsAskForRunsCreatedUpToATime|TestInstallationsSayWhichPermissionsWaitForAnOwner'`
Expected: FAIL (`first.HeadRepository undefined`, `client.OlderRuns undefined`, and the installation expectation).

- [ ] **Step 3: Implement**

In `core/internal/github/client.go`, extend `Run` (after `UpdatedAt time.Time`):

```go
	// "owner/name" the head commit came from, lowercased; a fork's differs
	// from the run's repository. Empty when GitHub does not say (a deleted fork).
	HeadRepository string
	// The first line of the head commit's message.
	CommitTitle string
	// Pull requests GitHub lists on the run whose base is the run's own
	// repository; in a fork GitHub also lists the upstream's, which are dropped.
	PullRequests []int64
```

Replace `runJSON` and its method:

```go
type runJSON struct {
	ID           int64     `json:"id"`
	WorkflowID   int64     `json:"workflow_id"`
	Name         string    `json:"name"`
	DisplayTitle string    `json:"display_title"`
	RunNumber    int64     `json:"run_number"`
	RunAttempt   int64     `json:"run_attempt"`
	Event        string    `json:"event"`
	Status       string    `json:"status"`
	Conclusion   *string   `json:"conclusion"`
	HeadBranch   string    `json:"head_branch"`
	HeadSHA      string    `json:"head_sha"`
	HTMLURL      string    `json:"html_url"`
	CreatedAt    time.Time `json:"created_at"`
	UpdatedAt    time.Time `json:"updated_at"`
	Actor        *struct {
		Login string `json:"login"`
	} `json:"actor"`
	HeadRepository *struct {
		FullName string `json:"full_name"`
	} `json:"head_repository"`
	HeadCommit *struct {
		Message string `json:"message"`
	} `json:"head_commit"`
	PullRequests []struct {
		Number int64 `json:"number"`
		Base   struct {
			Repo struct {
				URL string `json:"url"`
			} `json:"repo"`
		} `json:"base"`
	} `json:"pull_requests"`
}

// run maps a run of owner/name.
func (r runJSON) run(owner, name string) Run {
	run := Run{
		ID: r.ID, WorkflowID: r.WorkflowID, Name: r.Name, DisplayTitle: r.DisplayTitle, RunNumber: r.RunNumber,
		RunAttempt: r.RunAttempt, Event: r.Event, Status: r.Status, Branch: r.HeadBranch, HeadSHA: r.HeadSHA,
		HTMLURL: r.HTMLURL, CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt,
	}
	if r.Conclusion != nil {
		run.Conclusion = *r.Conclusion
	}
	if r.Actor != nil {
		run.Actor = r.Actor.Login
	}
	if r.HeadRepository != nil {
		run.HeadRepository = strings.ToLower(r.HeadRepository.FullName)
	}
	if r.HeadCommit != nil {
		run.CommitTitle = commitTitle(r.HeadCommit.Message)
	}
	own := strings.ToLower("/repos/" + owner + "/" + name)
	for _, pr := range r.PullRequests {
		if pr.Number > 0 && strings.HasSuffix(strings.ToLower(pr.Base.Repo.URL), own) {
			run.PullRequests = append(run.PullRequests, pr.Number)
		}
	}
	return run
}

// commitTitle is a commit message's first line, at most 300 characters.
func commitTitle(message string) string {
	title, _, _ := strings.Cut(message, "\n")
	return truncate(strings.TrimSpace(title), 300)
}
```

Update the three callers in `client.go` (`Runs`: `runs = append(runs, r.run(owner, name))`; `RunsIfChanged`: the same; `Run`: `return body.run(owner, name), nil`) and the one in `pulls.go:177` (`list = append(list, r.run(owner, name))`).

Add after `RunsIfChanged`:

```go
// OlderRuns reads up to limit runs created at or before `before`, newest
// first: a page of history older than what the caller holds. Runs created
// in the same second as `before` come again; callers drop the ones they have.
func (c *Client) OlderRuns(ctx context.Context, owner, name string, before time.Time, limit int) ([]Run, error) {
	if limit <= 0 || limit > maxRuns {
		limit = maxRuns
	}
	query := url.Values{"per_page": {strconv.Itoa(limit)}, "created": {"<=" + before.UTC().Format(time.RFC3339)}}
	var body struct {
		WorkflowRuns []runJSON `json:"workflow_runs"`
	}
	if err := c.get(ctx, repoPath(owner, name, "/actions/runs"), query, &body); err != nil {
		return nil, err
	}
	runs := make([]Run, 0, len(body.WorkflowRuns))
	for _, r := range body.WorkflowRuns {
		runs = append(runs, r.run(owner, name))
	}
	return runs, nil
}
```

In `core/internal/github/account.go:32`:

```go
var RequiredPermissions = map[string]string{"actions": "write", "contents": "read", "metadata": "read", "pull_requests": "read"}
```

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/github/ ./internal/server/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/github/client.go core/internal/github/pulls.go core/internal/github/account.go core/internal/github/client_test.go core/internal/github/account_test.go core/internal/server/dispatch_test.go
git commit -m "Runs carry their commit and pull requests; older runs; ask for pull requests read"
```

---

### Task 3: Repository pull requests, lookups and `SummarizeRuns`

**Files:**
- Create: `core/internal/github/repopulls.go`
- Modify: `core/internal/github/pulls.go:183-237` (`summarizeCI`)
- Test: create `core/internal/github/repopulls_test.go`; `core/internal/github/pulls_test.go`

**Interfaces:**
- Produces:

```go
type RepositoryPullRequest struct {
	Number         int64
	Title          string
	State          string // "open" or "closed"
	Draft          bool
	Author         string
	HTMLURL        string
	HeadRef        string
	HeadSHA        string
	HeadRepository string // lowercased "owner/name"; empty when the fork was deleted
	BaseRef        string
	MergeCommitSHA string // only when merged
	CreatedAt, UpdatedAt, ClosedAt, MergedAt time.Time
}
func (c *Client) PullRequestsIfChanged(ctx context.Context, owner, name, etag string) ([]RepositoryPullRequest, string, error)
func (c *Client) RepositoryPull(ctx context.Context, owner, name string, number int64) (RepositoryPullRequest, error)
func (c *Client) CommitPullRequests(ctx context.Context, owner, name, sha string) ([]RepositoryPullRequest, error)
func (c *Client) HeadPullRequests(ctx context.Context, owner, name, headOwner, branch string) ([]RepositoryPullRequest, error)

type CISummary struct {
	State   CIState
	Runs    int
	Failed  int
	Running int
	URL     string // the first failed run, else the first running one
}
func SummarizeRuns(runs []Run) CISummary
```

- [ ] **Step 1: Write the failing tests**

Create `core/internal/github/repopulls_test.go`:

```go
package github

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"
)

const pullsPage = `[
	{"number":142,"title":"Add retry","state":"closed","draft":false,"html_url":"https://github.com/o/r/pull/142",
	 "user":{"login":"octocat"},"head":{"ref":"retry","sha":"b2","repo":{"full_name":"O/R"}},"base":{"ref":"main"},
	 "merge_commit_sha":"m1","created_at":"2026-10-18T08:00:00Z","updated_at":"2026-10-18T12:00:00Z",
	 "closed_at":"2026-10-18T11:00:00Z","merged_at":"2026-10-18T11:00:00Z"},
	{"number":145,"title":"Cache images","state":"open","draft":true,"html_url":"https://github.com/o/r/pull/145",
	 "user":null,"head":{"ref":"cache","sha":"d4","repo":null},"base":{"ref":"main"},
	 "merge_commit_sha":"test-merge","created_at":"2026-10-18T09:00:00Z","updated_at":"2026-10-18T10:00:00Z",
	 "closed_at":null,"merged_at":null}]`

func TestRepositoryPullRequestsAreReadConditionally(t *testing.T) {
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		query := r.URL.Query()
		if r.URL.Path != "/repos/o/r/pulls" || query.Get("state") != "all" || query.Get("sort") != "updated" ||
			query.Get("direction") != "desc" || query.Get("per_page") != "50" {
			t.Errorf("request = %s", r.URL)
		}
		if r.Header.Get("If-None-Match") == `"p1"` {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", `"p1"`)
		_, _ = w.Write([]byte(pullsPage))
	})
	ctx := context.Background()
	pulls, tag, err := client.PullRequestsIfChanged(ctx, "o", "r", "")
	if err != nil || tag != `"p1"` || len(pulls) != 2 {
		t.Fatalf("pulls = %+v, %q, %v", pulls, tag, err)
	}
	merged, open := pulls[0], pulls[1]
	if merged.Number != 142 || merged.State != "closed" || merged.Author != "octocat" || merged.HeadRepository != "o/r" ||
		merged.MergeCommitSHA != "m1" || !merged.MergedAt.Equal(time.Date(2026, 10, 18, 11, 0, 0, 0, time.UTC)) {
		t.Fatalf("merged = %+v", merged)
	}
	// An open pull request's merge_commit_sha is GitHub's test merge: not kept.
	if open.MergeCommitSHA != "" || !open.Draft || open.HeadRepository != "" || !open.ClosedAt.IsZero() {
		t.Fatalf("open = %+v", open)
	}
	if _, _, err := client.PullRequestsIfChanged(ctx, "o", "r", tag); !errors.Is(err, ErrNotModified) {
		t.Fatalf("second read = %v", err)
	}
}

func TestPullRequestLookups(t *testing.T) {
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/repos/o/r/pulls/142":
			_, _ = w.Write([]byte(`{"number":142,"title":"Add retry","state":"open","head":{"ref":"retry","sha":"b2","repo":{"full_name":"o/r"}},"base":{"ref":"main"}}`))
		case r.URL.Path == "/repos/o/r/commits/m1/pulls":
			_, _ = w.Write([]byte(pullsPage))
		case r.URL.Path == "/repos/o/r/pulls" && r.URL.Query().Get("head") == "fork:patch-1":
			if r.URL.Query().Get("state") != "all" {
				t.Errorf("head query = %s", r.URL)
			}
			_, _ = w.Write([]byte(`[{"number":150,"title":"Typo","state":"open","head":{"ref":"patch-1","sha":"f5","repo":{"full_name":"fork/r"}},"base":{"ref":"main"}}]`))
		default:
			t.Errorf("unexpected %s", r.URL)
			w.WriteHeader(http.StatusNotFound)
		}
	})
	ctx := context.Background()
	if pr, err := client.RepositoryPull(ctx, "o", "r", 142); err != nil || pr.Number != 142 || pr.HeadSHA != "b2" {
		t.Fatalf("pull = %+v, %v", pr, err)
	}
	if prs, err := client.CommitPullRequests(ctx, "o", "r", "m1"); err != nil || len(prs) != 2 {
		t.Fatalf("commit = %+v, %v", prs, err)
	}
	if prs, err := client.HeadPullRequests(ctx, "o", "r", "fork", "patch-1"); err != nil || len(prs) != 1 || prs[0].HeadRepository != "fork/r" {
		t.Fatalf("head = %+v, %v", prs, err)
	}
	if _, err := client.RepositoryPull(ctx, "o", "r", 0); !errors.Is(err, ErrInvalid) {
		t.Fatalf("number 0 = %v", err)
	}
}
```

Append to `core/internal/github/pulls_test.go`:

```go
func TestSummarizeRunsCountsEveryRunItIsGiven(t *testing.T) {
	t0 := time.Date(2026, 10, 21, 10, 0, 0, 0, time.UTC)
	// A push run and a pull_request run of the same workflow both count:
	// the caller already chose the runs that matter.
	s := SummarizeRuns([]Run{
		{WorkflowID: 1, Event: "push", Status: "completed", Conclusion: "success", CreatedAt: t0},
		{WorkflowID: 1, Event: "pull_request", Status: "completed", Conclusion: "failure", CreatedAt: t0, HTMLURL: "f"},
	})
	if s.State != CIFailed || s.Runs != 2 || s.Failed != 1 || s.URL != "f" {
		t.Fatalf("summary = %+v", s)
	}
	if SummarizeRuns(nil).State != CINone {
		t.Fatal("no runs is not CINone")
	}
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `go test ./internal/github/ -run 'TestRepositoryPullRequestsAreReadConditionally|TestPullRequestLookups|TestSummarizeRunsCountsEveryRunItIsGiven'`
Expected: FAIL (undefined `PullRequestsIfChanged`, `RepositoryPull`, `SummarizeRuns`).

- [ ] **Step 3: Implement**

Create `core/internal/github/repopulls.go`:

```go
package github

import (
	"context"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// RepositoryPullRequest is a pull request of the repository a workspace
// syncs, with what linking runs to it needs.
type RepositoryPullRequest struct {
	Number int64
	Title  string
	// "open" or "closed"; MergedAt tells a merge apart.
	State   string
	Draft   bool
	Author  string
	HTMLURL string
	HeadRef string
	HeadSHA string
	// Lowercased "owner/name" of the head branch's repository; a fork's
	// differs. Empty when the fork was deleted.
	HeadRepository string
	BaseRef        string
	// The commit the merge created; only set once merged (before that
	// GitHub reports a test merge, which no run is on).
	MergeCommitSHA string
	CreatedAt      time.Time
	UpdatedAt      time.Time
	ClosedAt       time.Time
	MergedAt       time.Time
}

// pullsPerPage is how many of the most recently updated pull requests one
// sync pass reads.
const pullsPerPage = 50

type pullJSON struct {
	Number  int64  `json:"number"`
	Title   string `json:"title"`
	State   string `json:"state"`
	Draft   bool   `json:"draft"`
	HTMLURL string `json:"html_url"`
	User    *struct {
		Login string `json:"login"`
	} `json:"user"`
	Head struct {
		Ref  string `json:"ref"`
		SHA  string `json:"sha"`
		Repo *struct {
			FullName string `json:"full_name"`
		} `json:"repo"`
	} `json:"head"`
	Base struct {
		Ref string `json:"ref"`
	} `json:"base"`
	MergeCommitSHA *string    `json:"merge_commit_sha"`
	CreatedAt      *time.Time `json:"created_at"`
	UpdatedAt      *time.Time `json:"updated_at"`
	ClosedAt       *time.Time `json:"closed_at"`
	MergedAt       *time.Time `json:"merged_at"`
}

func (p pullJSON) pull() RepositoryPullRequest {
	out := RepositoryPullRequest{
		Number: p.Number, Title: truncate(p.Title, 300), State: p.State, Draft: p.Draft, HTMLURL: p.HTMLURL,
		HeadRef: p.Head.Ref, HeadSHA: p.Head.SHA, BaseRef: p.Base.Ref,
		CreatedAt: deref(p.CreatedAt), UpdatedAt: deref(p.UpdatedAt), ClosedAt: deref(p.ClosedAt), MergedAt: deref(p.MergedAt),
	}
	if p.User != nil {
		out.Author = p.User.Login
	}
	if p.Head.Repo != nil {
		out.HeadRepository = strings.ToLower(p.Head.Repo.FullName)
	}
	if p.MergedAt != nil && p.MergeCommitSHA != nil {
		out.MergeCommitSHA = *p.MergeCommitSHA
	}
	return out
}

func pulls(list []pullJSON) []RepositoryPullRequest {
	out := make([]RepositoryPullRequest, 0, len(list))
	for _, p := range list {
		if p.Number > 0 {
			out = append(out, p.pull())
		}
	}
	return out
}

// PullRequestsIfChanged reads the 50 most recently updated pull requests,
// open and closed; with etag set GitHub answers ErrNotModified when they did
// not change. It returns the new ETag.
func (c *Client) PullRequestsIfChanged(ctx context.Context, owner, name, etag string) ([]RepositoryPullRequest, string, error) {
	query := url.Values{"state": {"all"}, "sort": {"updated"}, "direction": {"desc"}, "per_page": {strconv.Itoa(pullsPerPage)}}
	var body []pullJSON
	tag, err := c.getConditional(ctx, repoPath(owner, name, "/pulls"), query, etag, &body)
	if err != nil {
		return nil, "", err
	}
	return pulls(body), tag, nil
}

// RepositoryPull reads one pull request.
func (c *Client) RepositoryPull(ctx context.Context, owner, name string, number int64) (RepositoryPullRequest, error) {
	if number <= 0 {
		return RepositoryPullRequest{}, ErrInvalid
	}
	var body pullJSON
	if err := c.get(ctx, repoPath(owner, name, fmt.Sprintf("/pulls/%d", number)), nil, &body); err != nil {
		return RepositoryPullRequest{}, err
	}
	return body.pull(), nil
}

// CommitPullRequests lists the pull requests a commit belongs to; for a
// merge commit on the default branch, the pull request it merged.
func (c *Client) CommitPullRequests(ctx context.Context, owner, name, sha string) ([]RepositoryPullRequest, error) {
	if sha == "" {
		return nil, ErrInvalid
	}
	var body []pullJSON
	if err := c.get(ctx, repoPath(owner, name, "/commits/"+url.PathEscape(sha)+"/pulls"), url.Values{"per_page": {"10"}}, &body); err != nil {
		return nil, err
	}
	return pulls(body), nil
}

// HeadPullRequests lists the pull requests, open or closed, whose head is
// branch in headOwner's fork.
func (c *Client) HeadPullRequests(ctx context.Context, owner, name, headOwner, branch string) ([]RepositoryPullRequest, error) {
	if headOwner == "" || branch == "" {
		return nil, ErrInvalid
	}
	query := url.Values{"head": {headOwner + ":" + branch}, "state": {"all"}, "per_page": {"10"}}
	var body []pullJSON
	if err := c.get(ctx, repoPath(owner, name, "/pulls"), query, &body); err != nil {
		return nil, err
	}
	return pulls(body), nil
}
```

In `core/internal/github/pulls.go`, replace `summarizeCI` with:

```go
// CISummary sums up a set of runs: any failure fails, then anything still
// going (or waiting for a maintainer's approval) is running, then all
// cancelled is cancelled, else passed. URL is the first failed run, else
// the first running one.
type CISummary struct {
	State   CIState
	Runs    int
	Failed  int
	Running int
	URL     string
}

// SummarizeRuns sums up the runs as given; callers pick the runs that count
// (the newest of each workflow, say).
func SummarizeRuns(runs []Run) CISummary {
	s := CISummary{State: CINone, Runs: len(runs)}
	if len(runs) == 0 {
		return s
	}
	ordered := append([]Run(nil), runs...)
	sort.SliceStable(ordered, func(i, j int) bool { return ordered[i].CreatedAt.Before(ordered[j].CreatedAt) })
	cancelled := 0
	var failedURL, runningURL string
	for _, run := range ordered {
		switch {
		// A run waiting for a maintainer's approval (a fork's pull request)
		// has not run yet, so it counts as still going, not as a pass.
		case run.Status != "completed" || run.Conclusion == "action_required":
			s.Running++
			if runningURL == "" {
				runningURL = run.HTMLURL
			}
		case run.Conclusion == "failure" || run.Conclusion == "timed_out" || run.Conclusion == "startup_failure":
			s.Failed++
			if failedURL == "" {
				failedURL = run.HTMLURL
			}
		case run.Conclusion == "cancelled":
			cancelled++
		}
	}
	switch {
	case s.Failed > 0:
		s.State, s.URL = CIFailed, failedURL
	case s.Running > 0:
		s.State, s.URL = CIRunning, runningURL
	case cancelled == len(ordered):
		s.State = CICancelled
	default:
		s.State = CIPassed
	}
	return s
}

// summarizeCI keeps the newest run of each workflow (a re-run replaces the
// one before) and sums them up.
func summarizeCI(pr *PullRequest, runs []Run) {
	latest := map[int64]Run{}
	for _, run := range runs {
		if current, ok := latest[run.WorkflowID]; !ok || run.CreatedAt.After(current.CreatedAt) {
			latest[run.WorkflowID] = run
		}
	}
	chosen := make([]Run, 0, len(latest))
	for _, run := range latest {
		chosen = append(chosen, run)
	}
	s := SummarizeRuns(chosen)
	pr.CI, pr.CIRuns, pr.CIFailed, pr.CIRunning, pr.CIURL = s.State, s.Runs, s.Failed, s.Running, s.URL
}
```

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/github/`
Expected: PASS (the existing `TestCIIsSummedUpPerWorkflow` still passes).

- [ ] **Step 5: Commit**

```bash
git add core/internal/github/repopulls.go core/internal/github/repopulls_test.go core/internal/github/pulls.go core/internal/github/pulls_test.go
git commit -m "Read a repository's pull requests and look up missing ones"
```

---

### Task 4: Store keeps run commits, links, the default branch, history and 5000 runs

**Files:**
- Modify: `core/internal/store/schema.go` (schemaV1 in place)
- Modify: `core/internal/store/activity.go` (whole file below)
- Test: `core/internal/store/activity_test.go`

**Interfaces:**
- Consumes: `github.Run.HeadRepository`, `CommitTitle`, `PullRequests` (Task 2).
- Produces:
  - `store.MaxRuns` (var, 5000).
  - `RunsUpdate.Restart bool`; `Pass.DefaultBranch string`.
  - `Activity.DefaultBranch string`, `Activity.CachedRuns int`, `Activity.HistoryComplete bool`; `Activity.Runs[i].PullRequests` holds the cached links (they only accumulate).
  - `func (s *Store) Newest(ctx context.Context, src Source) (time.Time, bool, error)` — `created_at` of the newest cached run of `src`.
  - Package helpers for Task 5: `upsertRun(ctx, tx, github.Run) (bool, error)`, `trimRuns(ctx, tx) (bool, error)`, `setHistory(ctx, tx, bool) (bool, error)`, `oldestCreated([]github.Run) time.Time`, `type statement struct{ query string; args []any }`.

- [ ] **Step 1: Write the failing tests**

In `core/internal/store/activity_test.go`, add after `pass`:

```go
// lowerBudget makes the run budget n for one test.
func lowerBudget(t *testing.T, n int) {
	t.Helper()
	old := MaxRuns
	MaxRuns = n
	t.Cleanup(func() { MaxRuns = old })
}
```

Replace `TestOnlyTheNewest200RunsAreKept` with:

```go
func TestOnlyTheNewestRunsAreKept(t *testing.T) {
	lowerBudget(t, 200)
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	for batch := 0; batch < 5; batch++ {
		var page []github.Run
		for i := 49; i >= 0; i-- {
			id := int64(batch*50 + i + 1)
			page = append(page, run(id, int(id), "completed"))
		}
		_, _ = s.ApplySync(ctx, pass(batch, page, false))
	}
	a, _ := s.Activity(ctx, 1000)
	if len(a.Runs) != 200 || a.CachedRuns != 200 || a.Runs[0].ID != 250 || a.Runs[199].ID != 51 || a.HistoryComplete {
		t.Fatalf("kept %d (%d), newest %d, oldest %d, complete %v", len(a.Runs), a.CachedRuns, a.Runs[0].ID, a.Runs[len(a.Runs)-1].ID, a.HistoryComplete)
	}
}
```

Append:

```go
func TestRunsKeepTheirCommitAndPullRequestLinks(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	linked := run(1, 1, "completed")
	linked.HeadRepository, linked.CommitTitle, linked.PullRequests = "o/r", "Add retry", []int64{142}
	if changed, err := s.ApplySync(ctx, pass(0, []github.Run{linked}, true)); err != nil || !changed {
		t.Fatalf("apply = %v, %v", changed, err)
	}
	// GitHub may later list no pull request on the run: the link stays.
	linked.PullRequests = nil
	if changed, _ := s.ApplySync(ctx, pass(1, []github.Run{linked}, true)); changed {
		t.Fatal("an empty pull request list counted as a change")
	}
	a, _ := s.Activity(ctx, 50)
	got := a.Runs[0]
	if got.HeadRepository != "o/r" || got.CommitTitle != "Add retry" || len(got.PullRequests) != 1 || got.PullRequests[0] != 142 {
		t.Fatalf("run = %+v", got)
	}
	linked.PullRequests = []int64{150}
	if changed, _ := s.ApplySync(ctx, pass(2, []github.Run{linked}, true)); !changed {
		t.Fatal("a new link is a change")
	}
	if a, _ := s.Activity(ctx, 50); len(a.Runs[0].PullRequests) != 2 {
		t.Fatalf("links = %v", a.Runs[0].PullRequests)
	}
}

func TestTheDefaultBranchAndTheHistoryAreKept(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	p := pass(0, []github.Run{run(2, 2, "completed"), run(1, 1, "completed")}, true)
	p.DefaultBranch = "main"
	_, _ = s.ApplySync(ctx, p)
	a, _ := s.Activity(ctx, 1)
	if a.DefaultBranch != "main" || !a.HistoryComplete || a.CachedRuns != 2 || len(a.Runs) != 1 {
		t.Fatalf("activity = %+v", a)
	}
	if newest, ok, _ := s.Newest(ctx, source); !ok || !newest.Equal(fixedNow().Add(2*time.Minute)) {
		t.Fatalf("newest = %v %v", newest, ok)
	}
	if _, ok, _ := s.Newest(ctx, Source{Repository: "o/other"}); ok {
		t.Fatal("newest of another repository")
	}
	// A page that never reached the cache: older runs go and the history
	// is no longer complete; the default branch stays.
	restart := pass(1, []github.Run{run(9, 9, "completed"), run(8, 8, "completed")}, false)
	restart.Runs.Restart = true
	_, _ = s.ApplySync(ctx, restart)
	a, _ = s.Activity(ctx, 50)
	if a.CachedRuns != 2 || a.Runs[1].ID != 8 || a.HistoryComplete || a.DefaultBranch != "main" {
		t.Fatalf("after restart = %+v", a)
	}
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `go test ./internal/store/ -run 'TestOnlyTheNewestRunsAreKept|TestRunsKeepTheirCommitAndPullRequestLinks|TestTheDefaultBranchAndTheHistoryAreKept'`
Expected: FAIL to compile (`MaxRuns`, `Restart`, `DefaultBranch`, `Newest` undefined).

- [ ] **Step 3: Change the schema in place**

In `core/internal/store/schema.go`, replace the `cache_source` and `runs` tables of `schemaV1` and add the new tables after `CREATE INDEX runs_workflow ON runs (workflow_id);`:

```sql
-- cache: the GitHub repository the cached activity belongs to, its default
-- branch, and whether GitHub has no run older than the oldest cached one.
CREATE TABLE cache_source (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	server_id TEXT NOT NULL,
	repository TEXT NOT NULL,
	default_branch TEXT NOT NULL DEFAULT '',
	history_complete INTEGER NOT NULL DEFAULT 0
);
```

```sql
-- cache
CREATE TABLE runs (
	id INTEGER PRIMARY KEY,
	workflow_id INTEGER NOT NULL,
	name TEXT NOT NULL,
	display_title TEXT NOT NULL,
	run_number INTEGER NOT NULL,
	run_attempt INTEGER NOT NULL,
	event TEXT NOT NULL,
	status TEXT NOT NULL,
	conclusion TEXT NOT NULL,
	branch TEXT NOT NULL,
	head_sha TEXT NOT NULL,
	head_repository TEXT NOT NULL,
	commit_title TEXT NOT NULL,
	actor TEXT NOT NULL,
	html_url TEXT NOT NULL,
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL
);
CREATE INDEX runs_created ON runs (created_at DESC, id DESC);
CREATE INDEX runs_workflow ON runs (workflow_id);
CREATE INDEX runs_head ON runs (head_sha);
-- cache: pull requests GitHub listed on a run, whose base is this
-- repository. Links only accumulate; they go with the run.
CREATE TABLE run_pull_requests (
	run_id INTEGER NOT NULL REFERENCES runs (id) ON DELETE CASCADE,
	number INTEGER NOT NULL,
	PRIMARY KEY (run_id, number)
);
-- cache
CREATE TABLE pull_requests (
	number INTEGER PRIMARY KEY,
	title TEXT NOT NULL,
	state TEXT NOT NULL,
	draft INTEGER NOT NULL,
	author TEXT NOT NULL,
	html_url TEXT NOT NULL,
	head_ref TEXT NOT NULL,
	head_sha TEXT NOT NULL,
	head_repository TEXT NOT NULL,
	base_ref TEXT NOT NULL,
	merge_commit_sha TEXT NOT NULL,
	created_at INTEGER NOT NULL,
	updated_at INTEGER NOT NULL,
	closed_at INTEGER NOT NULL,
	merged_at INTEGER NOT NULL
);
CREATE INDEX pull_requests_updated ON pull_requests (updated_at DESC);
-- cache: answers to lookups for pull requests the runs miss, by key
-- ("pr:<n>", "commit:<sha>", "head:<owner/name>:<branch>"); numbers is a
-- JSON array, possibly empty.
CREATE TABLE link_lookups (
	key TEXT PRIMARY KEY,
	numbers TEXT NOT NULL,
	fetched_at INTEGER NOT NULL
);
```

Do not add a migration entry: the schema changes in place (AGENTS.md).

- [ ] **Step 4: Rewrite `core/internal/store/activity.go`**

```go
package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"runnir/core/internal/github"
)

// MaxRuns is how many runs a workspace keeps, newest first; their jobs and
// steps go with them. A variable so tests can lower it.
var MaxRuns = 5000

// Source is the GitHub repository cached activity belongs to.
type Source struct {
	ServerID   string // "" is github.com
	Repository string // "owner/name", lowercased
}

// RunsUpdate is one read of the newest runs.
type RunsUpdate struct {
	NotModified bool
	// Newest first, one unbroken stretch of history; empty when NotModified.
	Runs []github.Run
	// Complete means the runs are every run of the repository: any cached
	// run missing from them was deleted, and the history is complete.
	Complete bool
	// Restart means the runs never reached the cached ones (a gap the pass
	// could not fill): cached runs older than them are dropped, so the
	// cache stays one unbroken stretch of history.
	Restart bool
	ETag    string
}

// WorkflowsUpdate is one read of the repository's workflows.
type WorkflowsUpdate struct {
	NotModified bool
	Workflows   []github.Workflow
	ETag        string
}

// Pass is what one sync pass learned. Access is the caller's status code
// for the pass; the store keeps it without interpreting it. OK means every
// read got an answer (data or not modified).
type Pass struct {
	Source     Source
	At         time.Time
	OK         bool
	Access     int32
	RetryAfter time.Time
	// DefaultBranch of the repository when the pass read it; "" keeps the
	// stored one.
	DefaultBranch string
	Runs          *RunsUpdate
	Workflows     *WorkflowsUpdate
}

// Activity is the cached activity and what the last passes said.
type Activity struct {
	Source    Source
	HasSource bool
	Runs      []github.Run
	Workflows []github.Workflow
	// DefaultBranch of the cached repository; "" until a pass read it.
	DefaultBranch string
	// CachedRuns counts every cached run, also those beyond the limit read.
	CachedRuns int
	// HistoryComplete: GitHub has no run older than the oldest cached one.
	HistoryComplete bool
	CheckedAt       time.Time
	SyncedAt        time.Time
	ChangedAt       time.Time
	// Access and RetryAfter are the last pass's; Access is 0 before one.
	Access     int32
	RetryAfter time.Time
}

const (
	scopeActivity  = "activity"
	scopeRuns      = "runs"
	scopeWorkflows = "workflows"
)

// ApplySync stores a pass in one transaction and reports whether cached
// rows changed. Data for another repository than the cached one replaces
// the cache; a pass without data never does.
func (s *Store) ApplySync(ctx context.Context, p Pass) (bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	changed := false
	hasData := (p.Runs != nil && !p.Runs.NotModified) || (p.Workflows != nil && !p.Workflows.NotModified)
	if hasData {
		current, has, err := readSource(ctx, tx)
		if err != nil {
			return false, err
		}
		if !has || current != p.Source {
			if err := clearCache(ctx, tx); err != nil {
				return false, err
			}
			if _, err := tx.ExecContext(ctx, "INSERT INTO cache_source (id, server_id, repository) VALUES (1, ?, ?)", p.Source.ServerID, p.Source.Repository); err != nil {
				return false, err
			}
			changed = true
		}
	}
	if p.DefaultBranch != "" {
		if current, has, err := readSource(ctx, tx); err != nil {
			return false, err
		} else if has && current == p.Source {
			result, err := tx.ExecContext(ctx, "UPDATE cache_source SET default_branch = ? WHERE id = 1 AND default_branch <> ?", p.DefaultBranch, p.DefaultBranch)
			if err != nil {
				return false, err
			}
			if n, _ := result.RowsAffected(); n > 0 {
				changed = true
			}
		}
	}
	if p.Runs != nil {
		if !p.Runs.NotModified {
			c, err := applyRuns(ctx, tx, p.Runs)
			if err != nil {
				return false, err
			}
			changed = changed || c
		}
		if err := setETag(ctx, tx, scopeRuns, p.Runs.ETag); err != nil {
			return false, err
		}
	}
	if p.Workflows != nil {
		if !p.Workflows.NotModified {
			c, err := applyWorkflows(ctx, tx, p.Workflows.Workflows)
			if err != nil {
				return false, err
			}
			changed = changed || c
		}
		if err := setETag(ctx, tx, scopeWorkflows, p.Workflows.ETag); err != nil {
			return false, err
		}
	}
	at := millis(p.At)
	if _, err := tx.ExecContext(ctx, `
INSERT INTO sync_state (scope, checked_at, synced_at, changed_at, access, retry_after) VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT (scope) DO UPDATE SET
	checked_at = excluded.checked_at,
	synced_at = CASE WHEN ? THEN excluded.checked_at ELSE sync_state.synced_at END,
	changed_at = CASE WHEN ? THEN excluded.checked_at ELSE sync_state.changed_at END,
	access = excluded.access, retry_after = excluded.retry_after`,
		scopeActivity, at, okMillis(p.OK, at), okMillis(changed, at), p.Access, millis(p.RetryAfter), p.OK, changed); err != nil {
		return false, err
	}
	return changed, tx.Commit()
}

func okMillis(ok bool, at int64) int64 {
	if ok {
		return at
	}
	return 0
}

func readSource(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}) (Source, bool, error) {
	var src Source
	err := q.QueryRowContext(ctx, "SELECT server_id, repository FROM cache_source WHERE id = 1").Scan(&src.ServerID, &src.Repository)
	if errors.Is(err, sql.ErrNoRows) {
		return Source{}, false, nil
	}
	return src, err == nil, err
}

func setETag(ctx context.Context, tx *sql.Tx, scope, etag string) error {
	_, err := tx.ExecContext(ctx, `INSERT INTO sync_state (scope, etag) VALUES (?, ?)
ON CONFLICT (scope) DO UPDATE SET etag = excluded.etag`, scope, etag)
	return err
}

func idsJSON[T any](items []T, id func(T) int64) string {
	ids := make([]int64, 0, len(items))
	for _, item := range items {
		ids = append(ids, id(item))
	}
	data, _ := json.Marshal(ids)
	return string(data)
}

// statement is one SQL statement with its arguments.
type statement struct {
	query string
	args  []any
}

func oldestCreated(runs []github.Run) time.Time {
	oldest := runs[0].CreatedAt
	for _, r := range runs[1:] {
		if r.CreatedAt.Before(oldest) {
			oldest = r.CreatedAt
		}
	}
	return oldest
}

// upsertRun stores a run and adds its pull request links; true when a row
// changed.
func upsertRun(ctx context.Context, tx *sql.Tx, r github.Run) (bool, error) {
	result, err := tx.ExecContext(ctx, `
INSERT INTO runs (id, workflow_id, name, display_title, run_number, run_attempt, event, status, conclusion, branch, head_sha,
	head_repository, commit_title, actor, html_url, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (id) DO UPDATE SET
	workflow_id = excluded.workflow_id, name = excluded.name, display_title = excluded.display_title,
	run_number = excluded.run_number, run_attempt = excluded.run_attempt, event = excluded.event,
	status = excluded.status, conclusion = excluded.conclusion, branch = excluded.branch,
	head_sha = excluded.head_sha, head_repository = excluded.head_repository, commit_title = excluded.commit_title,
	actor = excluded.actor, html_url = excluded.html_url,
	created_at = excluded.created_at, updated_at = excluded.updated_at
WHERE (runs.workflow_id, runs.name, runs.display_title, runs.run_number, runs.run_attempt, runs.event, runs.status,
	runs.conclusion, runs.branch, runs.head_sha, runs.head_repository, runs.commit_title, runs.actor, runs.html_url,
	runs.created_at, runs.updated_at)
	<> (excluded.workflow_id, excluded.name, excluded.display_title, excluded.run_number, excluded.run_attempt, excluded.event,
	excluded.status, excluded.conclusion, excluded.branch, excluded.head_sha, excluded.head_repository, excluded.commit_title,
	excluded.actor, excluded.html_url, excluded.created_at, excluded.updated_at)`,
		r.ID, r.WorkflowID, r.Name, r.DisplayTitle, r.RunNumber, r.RunAttempt, r.Event, r.Status, r.Conclusion,
		r.Branch, r.HeadSHA, r.HeadRepository, r.CommitTitle, r.Actor, r.HTMLURL, millis(r.CreatedAt), millis(r.UpdatedAt))
	if err != nil {
		return false, err
	}
	n, _ := result.RowsAffected()
	changed := n > 0
	for _, number := range r.PullRequests {
		result, err := tx.ExecContext(ctx, "INSERT OR IGNORE INTO run_pull_requests (run_id, number) VALUES (?, ?)", r.ID, number)
		if err != nil {
			return false, err
		}
		if n, _ := result.RowsAffected(); n > 0 {
			changed = true
		}
	}
	return changed, nil
}

// trimRuns keeps the newest MaxRuns runs; true when some were deleted.
func trimRuns(ctx context.Context, tx *sql.Tx) (bool, error) {
	result, err := tx.ExecContext(ctx, `DELETE FROM runs WHERE id IN (
	SELECT id FROM runs ORDER BY created_at DESC, id DESC LIMIT -1 OFFSET ?)`, MaxRuns)
	if err != nil {
		return false, err
	}
	n, _ := result.RowsAffected()
	return n > 0, nil
}

// setHistory records whether the cache holds the whole history; true when
// that changed.
func setHistory(ctx context.Context, tx *sql.Tx, complete bool) (bool, error) {
	result, err := tx.ExecContext(ctx, "UPDATE cache_source SET history_complete = ? WHERE id = 1 AND history_complete <> ?", complete, complete)
	if err != nil {
		return false, err
	}
	n, _ := result.RowsAffected()
	return n > 0, nil
}

func applyRuns(ctx context.Context, tx *sql.Tx, u *RunsUpdate) (bool, error) {
	runs := u.Runs
	changed := false
	for _, r := range runs {
		c, err := upsertRun(ctx, tx, r)
		if err != nil {
			return false, err
		}
		changed = changed || c
	}
	ids := idsJSON(runs, func(r github.Run) int64 { return r.ID })
	var statements []statement
	switch {
	case u.Complete:
		statements = append(statements, statement{"DELETE FROM runs WHERE id NOT IN (SELECT value FROM json_each(?))", []any{ids}})
	case len(runs) > 0:
		oldest := millis(oldestCreated(runs))
		statements = append(statements, statement{"DELETE FROM runs WHERE created_at > ? AND id NOT IN (SELECT value FROM json_each(?))", []any{oldest, ids}})
		if u.Restart {
			statements = append(statements, statement{"DELETE FROM runs WHERE created_at < ?", []any{oldest}})
		}
	}
	for _, statement := range statements {
		result, err := tx.ExecContext(ctx, statement.query, statement.args...)
		if err != nil {
			return false, err
		}
		if n, _ := result.RowsAffected(); n > 0 {
			changed = true
		}
	}
	if u.Complete || u.Restart {
		c, err := setHistory(ctx, tx, u.Complete)
		if err != nil {
			return false, err
		}
		changed = changed || c
	}
	trimmed, err := trimRuns(ctx, tx)
	if err != nil {
		return false, err
	}
	if trimmed {
		changed = true
		if _, err := setHistory(ctx, tx, false); err != nil {
			return false, err
		}
	}
	return changed, nil
}

func applyWorkflows(ctx context.Context, tx *sql.Tx, workflows []github.Workflow) (bool, error) {
	changed := false
	for i, w := range workflows {
		result, err := tx.ExecContext(ctx, `
INSERT INTO remote_workflows (id, position, name, path, state, html_url) VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT (id) DO UPDATE SET position = excluded.position, name = excluded.name, path = excluded.path,
	state = excluded.state, html_url = excluded.html_url
WHERE (remote_workflows.position, remote_workflows.name, remote_workflows.path, remote_workflows.state, remote_workflows.html_url)
	<> (excluded.position, excluded.name, excluded.path, excluded.state, excluded.html_url)`,
			w.ID, i, w.Name, w.Path, w.State, w.HTMLURL)
		if err != nil {
			return false, err
		}
		if n, _ := result.RowsAffected(); n > 0 {
			changed = true
		}
	}
	result, err := tx.ExecContext(ctx, "DELETE FROM remote_workflows WHERE id NOT IN (SELECT value FROM json_each(?))",
		idsJSON(workflows, func(w github.Workflow) int64 { return w.ID }))
	if err != nil {
		return false, err
	}
	if n, _ := result.RowsAffected(); n > 0 {
		changed = true
	}
	return changed, nil
}

// Activity reads the cached activity: up to limit newest runs.
func (s *Store) Activity(ctx context.Context, limit int) (Activity, error) {
	var a Activity
	var err error
	if a.Source, a.HasSource, err = readSource(ctx, s.db); err != nil {
		return Activity{}, err
	}
	if a.HasSource {
		if err := s.db.QueryRowContext(ctx, "SELECT default_branch, history_complete FROM cache_source WHERE id = 1").
			Scan(&a.DefaultBranch, &a.HistoryComplete); err != nil {
			return Activity{}, err
		}
	}
	if err := s.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM runs").Scan(&a.CachedRuns); err != nil {
		return Activity{}, err
	}
	if a.Runs, err = s.runs(ctx, "ORDER BY created_at DESC, id DESC LIMIT ?", limit); err != nil {
		return Activity{}, err
	}
	rows, err := s.db.QueryContext(ctx, "SELECT id, name, path, state, html_url FROM remote_workflows ORDER BY position, id")
	if err != nil {
		return Activity{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var w github.Workflow
		if err := rows.Scan(&w.ID, &w.Name, &w.Path, &w.State, &w.HTMLURL); err != nil {
			return Activity{}, err
		}
		a.Workflows = append(a.Workflows, w)
	}
	if err := rows.Err(); err != nil {
		return Activity{}, err
	}
	rows.Close()
	var checked, synced, changed, retry int64
	err = s.db.QueryRowContext(ctx, "SELECT checked_at, synced_at, changed_at, access, retry_after FROM sync_state WHERE scope = ?", scopeActivity).
		Scan(&checked, &synced, &changed, &a.Access, &retry)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return Activity{}, err
	}
	a.CheckedAt, a.SyncedAt, a.ChangedAt, a.RetryAfter = fromMillis(checked), fromMillis(synced), fromMillis(changed), fromMillis(retry)
	return a, nil
}

const runColumns = "id, workflow_id, name, display_title, run_number, run_attempt, event, status, conclusion, branch, head_sha, head_repository, commit_title, actor, html_url, created_at, updated_at"

func (s *Store) runs(ctx context.Context, tail string, args ...any) ([]github.Run, error) {
	out, err := s.scanRuns(ctx, tail, args...)
	if err != nil || len(out) == 0 {
		return out, err
	}
	// Read once the runs' rows are closed: the store has one connection.
	links, err := s.links(ctx)
	if err != nil {
		return nil, err
	}
	for i := range out {
		out[i].PullRequests = links[out[i].ID]
	}
	return out, nil
}

func (s *Store) scanRuns(ctx context.Context, tail string, args ...any) ([]github.Run, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT "+runColumns+" FROM runs "+tail, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []github.Run
	for rows.Next() {
		var r github.Run
		var created, updated int64
		if err := rows.Scan(&r.ID, &r.WorkflowID, &r.Name, &r.DisplayTitle, &r.RunNumber, &r.RunAttempt, &r.Event, &r.Status,
			&r.Conclusion, &r.Branch, &r.HeadSHA, &r.HeadRepository, &r.CommitTitle, &r.Actor, &r.HTMLURL, &created, &updated); err != nil {
			return nil, err
		}
		r.CreatedAt, r.UpdatedAt = fromMillis(created), fromMillis(updated)
		out = append(out, r)
	}
	return out, rows.Err()
}

// links are the cached pull request numbers of every run, ascending.
func (s *Store) links(ctx context.Context) (map[int64][]int64, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT run_id, number FROM run_pull_requests ORDER BY run_id, number")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[int64][]int64{}
	for rows.Next() {
		var run, number int64
		if err := rows.Scan(&run, &number); err != nil {
			return nil, err
		}
		out[run] = append(out[run], number)
	}
	return out, rows.Err()
}

// Newest returns the created_at of the newest cached run of src; false when
// none is cached for it.
func (s *Store) Newest(ctx context.Context, src Source) (time.Time, bool, error) {
	current, has, err := readSource(ctx, s.db)
	if err != nil || !has || current != src {
		return time.Time{}, false, err
	}
	var newest sql.NullInt64
	if err := s.db.QueryRowContext(ctx, "SELECT MAX(created_at) FROM runs").Scan(&newest); err != nil {
		return time.Time{}, false, err
	}
	if !newest.Valid {
		return time.Time{}, false, nil
	}
	return fromMillis(newest.Int64), true, nil
}

// ETags returns the stored ETags when the cache holds this repository's
// data, otherwise empty strings, so another repository's never match.
func (s *Store) ETags(ctx context.Context, src Source) (string, string, error) {
	current, has, err := readSource(ctx, s.db)
	if err != nil || !has || current != src {
		return "", "", err
	}
	tags := map[string]string{}
	rows, err := s.db.QueryContext(ctx, "SELECT scope, etag FROM sync_state WHERE scope IN (?, ?)", scopeRuns, scopeWorkflows)
	if err != nil {
		return "", "", err
	}
	defer rows.Close()
	for rows.Next() {
		var scope, etag string
		if err := rows.Scan(&scope, &etag); err != nil {
			return "", "", err
		}
		tags[scope] = etag
	}
	return tags[scopeRuns], tags[scopeWorkflows], rows.Err()
}

func clearCache(ctx context.Context, tx *sql.Tx) error {
	for _, statement := range []string{"DELETE FROM runs", "DELETE FROM remote_workflows", "DELETE FROM pull_requests",
		"DELETE FROM link_lookups", "DELETE FROM sync_state", "DELETE FROM cache_source"} {
		if _, err := tx.ExecContext(ctx, statement); err != nil {
			return err
		}
	}
	return nil
}

// CacheSource returns the repository the cached activity belongs to.
func (s *Store) CacheSource(ctx context.Context) (Source, bool, error) { return readSource(ctx, s.db) }
```

- [ ] **Step 5: Run the store tests**

Run: `go test ./internal/store/`
Expected: PASS (all existing tests too: run rows read back with empty `HeadRepository`, `CommitTitle` and nil `PullRequests`).

- [ ] **Step 6: Commit**

```bash
git add core/internal/store/schema.go core/internal/store/activity.go core/internal/store/activity_test.go
git commit -m "Keep run commits, pull request links, the default branch and up to 5000 runs"
```

---

### Task 5: Store keeps pull requests, lookups and older runs

**Files:**
- Create: `core/internal/store/pulls.go`
- Modify: `core/internal/store/activity.go` (`Pass`, `Activity`, `ApplySync`, `Activity()`, `ETags`)
- Modify: `core/internal/workspace/runtime.go:253-275` (the new `ETags` result)
- Test: create `core/internal/store/pulls_test.go`; `core/internal/store/activity_test.go:44-50` (ETags)

**Interfaces:**
- Consumes: `github.RepositoryPullRequest` (Task 3); helpers from Task 4.
- Produces:

```go
type PullRequestsUpdate struct {
	NotModified  bool
	Refused      bool // GitHub did not allow reading pull requests; Access says why
	PullRequests []github.RepositoryPullRequest
	ETag         string
	Access       int32 // kept uninterpreted, as Pass.Access
}
type Lookup struct {
	Key          string // "pr:<n>", "commit:<sha>", "head:<owner/name>:<branch>"
	Numbers      []int64
	PullRequests []github.RepositoryPullRequest
}
type LookupsUpdate struct {
	Source  Source
	At      time.Time
	Lookups []Lookup
	Access  int32 // non-zero: a refusal, kept as the pulls access
}
type History struct {
	Oldest   time.Time
	Count    int
	Complete bool
}
type Tags struct{ Runs, Workflows, Pulls string }

// Pass gains: PullRequests *PullRequestsUpdate
// Activity gains: PullRequests []github.RepositoryPullRequest (most recently updated first),
//                 Lookups map[string][]int64, PullRequestsAccess int32

func (s *Store) ApplyLookups(ctx context.Context, u LookupsUpdate) (bool, error)
func (s *Store) History(ctx context.Context, src Source) (History, bool, error)
func (s *Store) AddOlderRuns(ctx context.Context, src Source, before time.Time, runs []github.Run, complete bool) (int, error)
func (s *Store) ETags(ctx context.Context, src Source) (Tags, error)
```

- [ ] **Step 1: Write the failing tests**

In `core/internal/store/activity_test.go`, replace the ETag assertions in `TestAPassIsStoredAndReadBackNewestFirst`:

```go
	tags, _ := s.ETags(ctx, source)
	if tags.Runs != `"r"` || tags.Workflows != `"w"` {
		t.Fatalf("etags = %+v", tags)
	}
	if tags, _ := s.ETags(ctx, Source{Repository: "other/repo"}); tags != (Tags{}) {
		t.Fatal("etags leaked to another repository")
	}
```

Create `core/internal/store/pulls_test.go`:

```go
//go:build !windows

package store

import (
	"context"
	"fmt"
	"testing"
	"time"

	"runnir/core/internal/github"
)

func pull(number int64, updated int) github.RepositoryPullRequest {
	at := fixedNow().Add(time.Duration(updated) * time.Minute)
	return github.RepositoryPullRequest{Number: number, Title: fmt.Sprintf("PR %d", number), State: "open",
		HeadRef: "b", HeadSHA: "s", HeadRepository: "o/r", BaseRef: "main", CreatedAt: at, UpdatedAt: at}
}

func TestPullRequestsAreStoredWithTheirETagAndAccess(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	p := pass(0, []github.Run{run(1, 1, "completed")}, true)
	merged := pull(142, 5)
	merged.State, merged.MergeCommitSHA, merged.MergedAt, merged.Draft = "closed", "m1", fixedNow(), true
	p.PullRequests = &PullRequestsUpdate{PullRequests: []github.RepositoryPullRequest{merged, pull(145, 3)}, ETag: `"p"`, Access: 1}
	if changed, err := s.ApplySync(ctx, p); err != nil || !changed {
		t.Fatalf("apply = %v, %v", changed, err)
	}
	a, _ := s.Activity(ctx, 50)
	if len(a.PullRequests) != 2 || a.PullRequests[0].Number != 142 || a.PullRequests[0].MergeCommitSHA != "m1" ||
		!a.PullRequests[0].Draft || !a.PullRequests[0].MergedAt.Equal(fixedNow()) || a.PullRequestsAccess != 1 {
		t.Fatalf("pulls = %+v, access %d", a.PullRequests, a.PullRequestsAccess)
	}
	if tags, _ := s.ETags(ctx, source); tags.Pulls != `"p"` {
		t.Fatalf("tags = %+v", tags)
	}
	// The same list again is no change.
	again := pass(1, []github.Run{run(1, 1, "completed")}, true)
	again.PullRequests = &PullRequestsUpdate{PullRequests: []github.RepositoryPullRequest{merged, pull(145, 3)}, ETag: `"p"`, Access: 1}
	if changed, _ := s.ApplySync(ctx, again); changed {
		t.Fatal("identical pull requests counted as a change")
	}
	// A refusal keeps what was read and records why.
	refused := pass(2, []github.Run{run(1, 1, "completed")}, true)
	refused.PullRequests = &PullRequestsUpdate{Refused: true, ETag: `"p"`, Access: 8}
	_, _ = s.ApplySync(ctx, refused)
	if a, _ := s.Activity(ctx, 50); len(a.PullRequests) != 2 || a.PullRequestsAccess != 8 {
		t.Fatalf("after refusal = %+v, access %d", a.PullRequests, a.PullRequestsAccess)
	}
}

func TestLookupsAreKeptWhileARunNeedsThem(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	linked := run(1, 1, "completed")
	linked.PullRequests, linked.HeadSHA = []int64{142}, "m1"
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{linked}, true))
	merged := pull(142, 1)
	merged.MergeCommitSHA = "m1"
	changed, err := s.ApplyLookups(ctx, LookupsUpdate{Source: source, At: fixedNow(), Lookups: []Lookup{
		{Key: "pr:142", Numbers: []int64{142}, PullRequests: []github.RepositoryPullRequest{merged}},
		{Key: "commit:m1", Numbers: []int64{142}},
		{Key: "commit:gone"},
	}})
	if err != nil || !changed {
		t.Fatalf("lookups = %v, %v", changed, err)
	}
	a, _ := s.Activity(ctx, 50)
	if len(a.PullRequests) != 1 || len(a.Lookups["pr:142"]) != 1 || len(a.Lookups["commit:m1"]) != 1 {
		t.Fatalf("activity = %+v", a)
	}
	// No cached run is on "gone": its lookup is not kept.
	if _, ok := a.Lookups["commit:gone"]; ok {
		t.Fatal("a lookup no run needs was kept")
	}
	if changed, _ := s.ApplyLookups(ctx, LookupsUpdate{Source: Source{Repository: "o/other"}, Lookups: []Lookup{{Key: "pr:1"}}}); changed {
		t.Fatal("lookups for another repository were stored")
	}
	// A refusal is kept as the pull requests' access.
	_, _ = s.ApplyLookups(ctx, LookupsUpdate{Source: source, At: fixedNow(), Access: 8})
	if a, _ := s.Activity(ctx, 50); a.PullRequestsAccess != 8 {
		t.Fatalf("access = %d", a.PullRequestsAccess)
	}
	if err := s.ClearCache(ctx); err != nil {
		t.Fatal(err)
	}
	if a, _ := s.Activity(ctx, 50); len(a.PullRequests) != 0 || len(a.Lookups) != 0 {
		t.Fatalf("after Clear Cache = %+v", a)
	}
}

func TestOnlyNamedAndRecentPullRequestsAreKept(t *testing.T) {
	old := maxPullRequests
	maxPullRequests = 2
	t.Cleanup(func() { maxPullRequests = old })
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	linked := run(1, 1, "completed")
	linked.PullRequests = []int64{1}
	p := pass(0, []github.Run{linked}, true)
	p.PullRequests = &PullRequestsUpdate{PullRequests: []github.RepositoryPullRequest{pull(4, 4), pull(3, 3), pull(2, 2), pull(1, 1)}, Access: 1}
	_, _ = s.ApplySync(ctx, p)
	a, _ := s.Activity(ctx, 50)
	got := []int64{}
	for _, pr := range a.PullRequests {
		got = append(got, pr.Number)
	}
	// 4 and 3 are the newest; 1 is named by a run; 2 goes.
	if fmt.Sprint(got) != "[4 3 1]" {
		t.Fatalf("kept %v", got)
	}
}

func TestOlderRunsFillTheHistory(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{run(10, 10, "completed"), run(9, 9, "completed")}, false))
	h, ok, _ := s.History(ctx, source)
	if !ok || h.Count != 2 || !h.Oldest.Equal(fixedNow().Add(9*time.Minute)) || h.Complete {
		t.Fatalf("history = %+v, %v", h, ok)
	}
	// Run 9 comes again (same time bound); 8 and 6 are new.
	added, err := s.AddOlderRuns(ctx, source, h.Oldest, []github.Run{run(9, 9, "completed"), run(8, 8, "completed"), run(6, 6, "completed")}, true)
	if err != nil || added != 2 {
		t.Fatalf("added = %d, %v", added, err)
	}
	if h, _, _ = s.History(ctx, source); h.Count != 4 || !h.Complete {
		t.Fatalf("history = %+v", h)
	}
	// Run 8 was deleted on GitHub: a page that lacks it removes it.
	_, _ = s.AddOlderRuns(ctx, source, fixedNow().Add(9*time.Minute), []github.Run{run(9, 9, "completed"), run(6, 6, "completed")}, true)
	if h, _, _ = s.History(ctx, source); h.Count != 3 {
		t.Fatalf("history = %+v", h)
	}
	if added, _ := s.AddOlderRuns(ctx, Source{Repository: "o/other"}, h.Oldest, []github.Run{run(1, 1, "completed")}, false); added != 0 {
		t.Fatal("older runs of another repository were stored")
	}
	if _, ok, _ := s.History(ctx, Source{Repository: "o/other"}); ok {
		t.Fatal("history of another repository")
	}
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `go test ./internal/store/`
Expected: FAIL to compile (`Tags`, `PullRequestsUpdate`, `ApplyLookups`, `History`, `AddOlderRuns`, `maxPullRequests` undefined).

- [ ] **Step 3: Create `core/internal/store/pulls.go`**

```go
package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"

	"runnir/core/internal/github"
)

// PullRequestsUpdate is one read of the repository's pull requests.
type PullRequestsUpdate struct {
	NotModified bool
	// Refused: GitHub did not allow reading pull requests; Access says why.
	Refused      bool
	PullRequests []github.RepositoryPullRequest
	ETag         string
	// Access is the read's outcome, kept uninterpreted like Pass.Access.
	Access int32
}

// Lookup is the answer to one lookup: the pull requests found and their
// numbers, under the lookup's key ("pr:<n>", "commit:<sha>",
// "head:<owner/name>:<branch>"). Numbers may be empty: nothing was found,
// and the lookup is not repeated.
type Lookup struct {
	Key          string
	Numbers      []int64
	PullRequests []github.RepositoryPullRequest
}

// LookupsUpdate is what a pass's lookups learned.
type LookupsUpdate struct {
	Source  Source
	At      time.Time
	Lookups []Lookup
	// Non-zero: GitHub refused a lookup; kept as the pull requests' access.
	Access int32
}

// History is what the cache holds of a repository's runs.
type History struct {
	// Oldest is the created_at of the oldest cached run.
	Oldest   time.Time
	Count    int
	Complete bool
}

// Tags are the stored ETags of the reads a pass makes conditionally.
type Tags struct{ Runs, Workflows, Pulls string }

const scopePulls = "pulls"

// maxPullRequests are kept besides those a cached run or lookup names. A
// variable so tests can lower it.
var maxPullRequests = 500

func applyPulls(ctx context.Context, tx *sql.Tx, u *PullRequestsUpdate) (bool, error) {
	changed := false
	if !u.NotModified && !u.Refused {
		c, err := upsertPulls(ctx, tx, u.PullRequests)
		if err != nil {
			return false, err
		}
		changed = c
	}
	_, err := tx.ExecContext(ctx, `INSERT INTO sync_state (scope, etag, access) VALUES (?, ?, ?)
ON CONFLICT (scope) DO UPDATE SET etag = excluded.etag, access = excluded.access`, scopePulls, u.ETag, u.Access)
	return changed, err
}

func upsertPulls(ctx context.Context, tx *sql.Tx, pulls []github.RepositoryPullRequest) (bool, error) {
	changed := false
	for _, p := range pulls {
		result, err := tx.ExecContext(ctx, `
INSERT INTO pull_requests (number, title, state, draft, author, html_url, head_ref, head_sha, head_repository, base_ref,
	merge_commit_sha, created_at, updated_at, closed_at, merged_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
ON CONFLICT (number) DO UPDATE SET
	title = excluded.title, state = excluded.state, draft = excluded.draft, author = excluded.author,
	html_url = excluded.html_url, head_ref = excluded.head_ref, head_sha = excluded.head_sha,
	head_repository = excluded.head_repository, base_ref = excluded.base_ref, merge_commit_sha = excluded.merge_commit_sha,
	created_at = excluded.created_at, updated_at = excluded.updated_at, closed_at = excluded.closed_at,
	merged_at = excluded.merged_at
WHERE (pull_requests.title, pull_requests.state, pull_requests.draft, pull_requests.author, pull_requests.html_url,
	pull_requests.head_ref, pull_requests.head_sha, pull_requests.head_repository, pull_requests.base_ref,
	pull_requests.merge_commit_sha, pull_requests.created_at, pull_requests.updated_at, pull_requests.closed_at,
	pull_requests.merged_at)
	<> (excluded.title, excluded.state, excluded.draft, excluded.author, excluded.html_url, excluded.head_ref,
	excluded.head_sha, excluded.head_repository, excluded.base_ref, excluded.merge_commit_sha, excluded.created_at,
	excluded.updated_at, excluded.closed_at, excluded.merged_at)`,
			p.Number, p.Title, p.State, p.Draft, p.Author, p.HTMLURL, p.HeadRef, p.HeadSHA, p.HeadRepository, p.BaseRef,
			p.MergeCommitSHA, millis(p.CreatedAt), millis(p.UpdatedAt), millis(p.ClosedAt), millis(p.MergedAt))
		if err != nil {
			return false, err
		}
		if n, _ := result.RowsAffected(); n > 0 {
			changed = true
		}
	}
	return changed, nil
}

// trimLinks drops lookups no cached run needs any more, then pull requests
// that no cached run or lookup names, beyond the most recently updated.
func trimLinks(ctx context.Context, tx *sql.Tx) (bool, error) {
	changed := false
	for _, statement := range []statement{
		{`DELETE FROM link_lookups WHERE NOT (
	(key LIKE 'pr:%' AND CAST(substr(key, 4) AS INTEGER) IN (SELECT number FROM run_pull_requests))
	OR (key LIKE 'commit:%' AND substr(key, 8) IN (SELECT head_sha FROM runs))
	OR (key LIKE 'head:%' AND substr(key, 6) IN (SELECT head_repository || ':' || branch FROM runs)))`, nil},
		{`DELETE FROM pull_requests WHERE number NOT IN (SELECT number FROM run_pull_requests)
	AND number NOT IN (SELECT j.value FROM link_lookups, json_each(link_lookups.numbers) AS j)
	AND number NOT IN (SELECT number FROM pull_requests ORDER BY updated_at DESC, number DESC LIMIT ?)`, []any{maxPullRequests}},
	} {
		result, err := tx.ExecContext(ctx, statement.query, statement.args...)
		if err != nil {
			return false, err
		}
		if n, _ := result.RowsAffected(); n > 0 {
			changed = true
		}
	}
	return changed, nil
}

// ApplyLookups stores what lookups found, for the cached repository only,
// and reports whether rows changed.
func (s *Store) ApplyLookups(ctx context.Context, u LookupsUpdate) (bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return false, err
	}
	defer tx.Rollback()
	current, has, err := readSource(ctx, tx)
	if err != nil || !has || current != u.Source {
		return false, err
	}
	changed := false
	for _, l := range u.Lookups {
		c, err := upsertPulls(ctx, tx, l.PullRequests)
		if err != nil {
			return false, err
		}
		numbers := l.Numbers
		if numbers == nil {
			numbers = []int64{}
		}
		data, _ := json.Marshal(numbers)
		result, err := tx.ExecContext(ctx, `INSERT INTO link_lookups (key, numbers, fetched_at) VALUES (?, ?, ?)
ON CONFLICT (key) DO UPDATE SET numbers = excluded.numbers, fetched_at = excluded.fetched_at
WHERE link_lookups.numbers <> excluded.numbers`, l.Key, string(data), millis(u.At))
		if err != nil {
			return false, err
		}
		n, _ := result.RowsAffected()
		changed = changed || c || n > 0
	}
	if u.Access != 0 {
		if _, err := tx.ExecContext(ctx, `INSERT INTO sync_state (scope, access) VALUES (?, ?)
ON CONFLICT (scope) DO UPDATE SET access = excluded.access`, scopePulls, u.Access); err != nil {
			return false, err
		}
	}
	trimmed, err := trimLinks(ctx, tx)
	if err != nil {
		return false, err
	}
	return changed || trimmed, tx.Commit()
}

// History returns what is cached of src's runs; false when nothing is.
func (s *Store) History(ctx context.Context, src Source) (History, bool, error) {
	current, has, err := readSource(ctx, s.db)
	if err != nil || !has || current != src {
		return History{}, false, err
	}
	var h History
	var oldest sql.NullInt64
	if err := s.db.QueryRowContext(ctx, "SELECT MIN(created_at), COUNT(*) FROM runs").Scan(&oldest, &h.Count); err != nil {
		return History{}, false, err
	}
	if err := s.db.QueryRowContext(ctx, "SELECT history_complete FROM cache_source WHERE id = 1").Scan(&h.Complete); err != nil {
		return History{}, false, err
	}
	h.Oldest = fromMillis(oldest.Int64)
	return h, h.Count > 0, nil
}

// AddOlderRuns stores a page of src's runs created up to `before`, read to
// extend the history back. Cached runs after the page's oldest and up to
// `before` that the page lacks were deleted on GitHub. complete marks the
// history complete. It returns how many runs were not cached before.
func (s *Store) AddOlderRuns(ctx context.Context, src Source, before time.Time, runs []github.Run, complete bool) (int, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	current, has, err := readSource(ctx, tx)
	if err != nil || !has || current != src {
		return 0, err
	}
	added := 0
	for _, r := range runs {
		var cached int
		if err := tx.QueryRowContext(ctx, "SELECT COUNT(*) FROM runs WHERE id = ?", r.ID).Scan(&cached); err != nil {
			return 0, err
		}
		if cached == 0 {
			added++
		}
		if _, err := upsertRun(ctx, tx, r); err != nil {
			return 0, err
		}
	}
	if len(runs) > 0 {
		if _, err := tx.ExecContext(ctx, "DELETE FROM runs WHERE created_at > ? AND created_at <= ? AND id NOT IN (SELECT value FROM json_each(?))",
			millis(oldestCreated(runs)), millis(before), idsJSON(runs, func(r github.Run) int64 { return r.ID })); err != nil {
			return 0, err
		}
	}
	if complete {
		if _, err := setHistory(ctx, tx, true); err != nil {
			return 0, err
		}
	}
	trimmed, err := trimRuns(ctx, tx)
	if err != nil {
		return 0, err
	}
	if trimmed {
		if _, err := setHistory(ctx, tx, false); err != nil {
			return 0, err
		}
	}
	if _, err := trimLinks(ctx, tx); err != nil {
		return 0, err
	}
	return added, tx.Commit()
}

func (s *Store) pullRequests(ctx context.Context) ([]github.RepositoryPullRequest, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT number, title, state, draft, author, html_url, head_ref, head_sha, head_repository,
	base_ref, merge_commit_sha, created_at, updated_at, closed_at, merged_at FROM pull_requests ORDER BY updated_at DESC, number DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []github.RepositoryPullRequest
	for rows.Next() {
		var p github.RepositoryPullRequest
		var created, updated, closed, merged int64
		if err := rows.Scan(&p.Number, &p.Title, &p.State, &p.Draft, &p.Author, &p.HTMLURL, &p.HeadRef, &p.HeadSHA,
			&p.HeadRepository, &p.BaseRef, &p.MergeCommitSHA, &created, &updated, &closed, &merged); err != nil {
			return nil, err
		}
		p.CreatedAt, p.UpdatedAt, p.ClosedAt, p.MergedAt = fromMillis(created), fromMillis(updated), fromMillis(closed), fromMillis(merged)
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *Store) lookups(ctx context.Context) (map[string][]int64, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT key, numbers FROM link_lookups")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string][]int64{}
	for rows.Next() {
		var key, numbers string
		if err := rows.Scan(&key, &numbers); err != nil {
			return nil, err
		}
		var list []int64
		if err := json.Unmarshal([]byte(numbers), &list); err != nil {
			continue
		}
		out[key] = list
	}
	return out, rows.Err()
}
```

- [ ] **Step 4: Wire pull requests into `activity.go`**

Add to `Pass` after `Workflows *WorkflowsUpdate`:

```go
	// PullRequests is the pull request list's read; nil when the pass did
	// not read it.
	PullRequests *PullRequestsUpdate
```

Add to `Activity` after `HistoryComplete bool`:

```go
	// PullRequests most recently updated first; Lookups by key.
	PullRequests []github.RepositoryPullRequest
	Lookups      map[string][]int64
	// PullRequestsAccess is the last read's outcome; 0 before one.
	PullRequestsAccess int32
```

In `ApplySync`, extend `hasData`:

```go
	hasData := (p.Runs != nil && !p.Runs.NotModified) || (p.Workflows != nil && !p.Workflows.NotModified) ||
		(p.PullRequests != nil && !p.PullRequests.NotModified && !p.PullRequests.Refused)
```

and add after the `if p.Workflows != nil { … }` block:

```go
	if p.PullRequests != nil {
		c, err := applyPulls(ctx, tx, p.PullRequests)
		if err != nil {
			return false, err
		}
		changed = changed || c
	}
	if hasData {
		c, err := trimLinks(ctx, tx)
		if err != nil {
			return false, err
		}
		changed = changed || c
	}
```

In `Activity()`, after the explicit `rows.Close()` that ends the `remote_workflows` read and before the `sync_state` read:

```go
	if a.PullRequests, err = s.pullRequests(ctx); err != nil {
		return Activity{}, err
	}
	if a.Lookups, err = s.lookups(ctx); err != nil {
		return Activity{}, err
	}
	err = s.db.QueryRowContext(ctx, "SELECT access FROM sync_state WHERE scope = ?", scopePulls).Scan(&a.PullRequestsAccess)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return Activity{}, err
	}
```

Replace `ETags`:

```go
// ETags returns the stored ETags when the cache holds this repository's
// data, otherwise empty strings, so another repository's never match.
func (s *Store) ETags(ctx context.Context, src Source) (Tags, error) {
	current, has, err := readSource(ctx, s.db)
	if err != nil || !has || current != src {
		return Tags{}, err
	}
	rows, err := s.db.QueryContext(ctx, "SELECT scope, etag FROM sync_state WHERE scope IN (?, ?, ?)", scopeRuns, scopeWorkflows, scopePulls)
	if err != nil {
		return Tags{}, err
	}
	defer rows.Close()
	var tags Tags
	for rows.Next() {
		var scope, etag string
		if err := rows.Scan(&scope, &etag); err != nil {
			return Tags{}, err
		}
		switch scope {
		case scopeRuns:
			tags.Runs = etag
		case scopeWorkflows:
			tags.Workflows = etag
		case scopePulls:
			tags.Pulls = etag
		}
	}
	return tags, rows.Err()
}
```

In `core/internal/workspace/runtime.go` `read`, replace `runsTag, workflowsTag, _ := r.cfg.store.ETags(r.ctx, source)` with `tags, _ := r.cfg.store.ETags(r.ctx, source)` and use `tags.Runs` and `tags.Workflows` where `runsTag` and `workflowsTag` were used (four places). Task 8 rewrites this function; this keeps the package compiling now.

- [ ] **Step 5: Run the tests**

Run: `go test ./internal/store/ ./internal/workspace/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add core/internal/store/pulls.go core/internal/store/pulls_test.go core/internal/store/activity.go core/internal/store/activity_test.go core/internal/workspace/runtime.go
git commit -m "Keep pull requests, lookups and older runs in the workspace cache"
```

---

### Task 6: `internal/changes` — links, superseded runs and overlap

**Files:**
- Create: `core/internal/changes/changes.go`, `core/internal/changes/link.go`
- Test: create `core/internal/changes/helpers_test.go`, `core/internal/changes/analyze_test.go`

**Interfaces:**
- Consumes: `github.Run` (with `HeadRepository`, `PullRequests`), `github.RepositoryPullRequest`.
- Produces:

```go
type Input struct {
	Runs          []github.Run // newest first; Run.PullRequests holds the cached links
	PullRequests  []github.RepositoryPullRequest
	Lookups       map[string][]int64
	DefaultBranch string
	Repository    string // lowercased "owner/name"
	RepositoryURL string // "https://github.com/owner/name"
	Now           time.Time
}
type LinkKind int // LinkNone, LinkPullRequest, LinkAfterMerge
type Link struct{ Kind LinkKind; PullRequest int64 }
type Overlap struct{ RunIDs []int64; Duration time.Duration; PullRequests []int64 }
type Analysis struct {
	Links        map[int64]Link
	SupersededBy map[int64]int64
	Overlaps     map[int64]Overlap // by workflow id
}
func Analyze(in Input) Analysis
// for Task 7, in link.go:
type index struct{ … }
func newIndex([]github.RepositoryPullRequest) index
func isPullRequestEvent(event string) bool
func headKey(repository, branch string) string // "head:<repository>:<branch>"
```

- [ ] **Step 1: Write the test helpers**

Create `core/internal/changes/helpers_test.go`:

```go
package changes

import (
	"sort"
	"time"

	"runnir/core/internal/github"
)

var t0 = time.Date(2026, 10, 20, 10, 0, 0, 0, time.UTC)

func at(minute int) time.Time { return t0.Add(time.Duration(minute) * time.Minute) }

type option func(*github.Run)

// mk is a successful first attempt from o/r that took five minutes.
func mk(id, workflow int64, event, branch, sha string, minute int, options ...option) github.Run {
	r := github.Run{ID: id, WorkflowID: workflow, Name: "W", DisplayTitle: "Title", Event: event, Status: "completed",
		Conclusion: "success", Branch: branch, HeadSHA: sha, HeadRepository: "o/r", RunAttempt: 1,
		CreatedAt: at(minute), UpdatedAt: at(minute + 5)}
	for _, o := range options {
		o(&r)
	}
	return r
}

func lists(numbers ...int64) option         { return func(r *github.Run) { r.PullRequests = numbers } }
func fromRepository(name string) option     { return func(r *github.Run) { r.HeadRepository = name } }
func endsAt(minute int) option              { return func(r *github.Run) { r.UpdatedAt = at(minute) } }
func stillRunning() option                  { return func(r *github.Run) { r.Status, r.Conclusion = "in_progress", "" } }
func concluded(conclusion string) option    { return func(r *github.Run) { r.Conclusion = conclusion } }
func attempt(n int64) option                { return func(r *github.Run) { r.RunAttempt = n } }
func titled(title string) option            { return func(r *github.Run) { r.DisplayTitle = title } }

// newestFirst orders runs as the store returns them.
func newestFirst(runs ...github.Run) []github.Run {
	sort.SliceStable(runs, func(i, j int) bool {
		if runs[i].CreatedAt.Equal(runs[j].CreatedAt) {
			return runs[i].ID > runs[j].ID
		}
		return runs[i].CreatedAt.After(runs[j].CreatedAt)
	})
	return runs
}

// retryPR is #142: opened at minute 0 from retry, last pushed as c3,
// merged at minute 60 as m1.
func retryPR() github.RepositoryPullRequest {
	return github.RepositoryPullRequest{Number: 142, Title: "Add retry to deploy", State: "closed", Author: "octocat",
		HTMLURL: "https://github.com/o/r/pull/142", HeadRef: "retry", HeadSHA: "c3", HeadRepository: "o/r", BaseRef: "main",
		MergeCommitSHA: "m1", CreatedAt: at(0), UpdatedAt: at(60), ClosedAt: at(60), MergedAt: at(60)}
}

// example is the spec's example: CI on three pushes to #142, the merge,
// CI on the merge commit and Deploy started by hand on it. Run 1 is linked
// by its branch, run 2 by GitHub's list, run 3 by the pull request's head.
func example() Input {
	return Input{
		Runs: newestFirst(
			mk(1, 1, "pull_request", "retry", "c1", 1, endsAt(20)),
			mk(2, 1, "pull_request", "retry", "c2", 10, lists(142), endsAt(25)),
			mk(3, 1, "pull_request", "retry", "c3", 20),
			mk(4, 1, "push", "main", "m1", 61),
			mk(5, 2, "workflow_dispatch", "main", "m1", 70),
		),
		PullRequests:  []github.RepositoryPullRequest{retryPR()},
		DefaultBranch: "main", Repository: "o/r", RepositoryURL: "https://github.com/o/r", Now: at(100),
	}
}
```

- [ ] **Step 2: Write the failing tests**

Create `core/internal/changes/analyze_test.go`:

```go
package changes

import (
	"reflect"
	"testing"
	"time"

	"runnir/core/internal/github"
)

func TestTheExampleIsLinkedToItsPullRequest(t *testing.T) {
	a := Analyze(example())
	want := map[int64]Link{1: {LinkPullRequest, 142}, 2: {LinkPullRequest, 142}, 3: {LinkPullRequest, 142},
		4: {LinkAfterMerge, 142}, 5: {LinkAfterMerge, 142}}
	if !reflect.DeepEqual(a.Links, want) {
		t.Fatalf("links = %v", a.Links)
	}
	if !reflect.DeepEqual(a.SupersededBy, map[int64]int64{1: 3, 2: 3}) {
		t.Fatalf("superseded = %v", a.SupersededBy)
	}
	// Run 1 kept going 10 minutes after run 2 started, run 2 five minutes after run 3.
	o := a.Overlaps[1]
	if !reflect.DeepEqual(o.RunIDs, []int64{1, 2}) || o.Duration != 15*time.Minute || !reflect.DeepEqual(o.PullRequests, []int64{142}) {
		t.Fatalf("overlap = %+v", o)
	}
	if _, ok := a.Overlaps[2]; ok {
		t.Fatal("Deploy has no overlap")
	}
}

func TestAReleasePullRequestFromMainNeverTakesPushesToMain(t *testing.T) {
	release := github.RepositoryPullRequest{Number: 200, State: "open", HeadRef: "main", HeadSHA: "a2", HeadRepository: "o/r",
		BaseRef: "release", CreatedAt: at(0), UpdatedAt: at(20)}
	in := Input{Runs: newestFirst(mk(1, 1, "push", "main", "a1", 5, lists(200)), mk(2, 1, "push", "main", "a2", 15, lists(200))),
		PullRequests: []github.RepositoryPullRequest{release}, DefaultBranch: "main", Repository: "o/r"}
	a := Analyze(in)
	if a.Links[1].Kind != LinkNone || a.Links[2].Kind != LinkNone || len(a.SupersededBy) != 0 {
		t.Fatalf("analysis = %+v", a)
	}
}

func TestPullRequestTargetRunsAreNeverAfterMerge(t *testing.T) {
	in := example()
	// pull_request_target runs on the base branch's commit, here the merge of #142.
	in.Runs = []github.Run{mk(9, 3, "pull_request_target", "main", "m1", 80, lists(145))}
	if got := Analyze(in).Links[9]; got != (Link{LinkPullRequest, 145}) {
		t.Fatalf("link = %+v", got)
	}
}

func TestAForksRunIsLinkedThroughItsLookupOrItsPullRequest(t *testing.T) {
	run := mk(1, 1, "pull_request", "patch-1", "f1", 1, fromRepository("fork/r"))
	in := Input{Runs: []github.Run{run}, DefaultBranch: "main", Repository: "o/r"}
	if got := Analyze(in).Links[1]; got.Kind != LinkNone {
		t.Fatalf("without data = %+v", got)
	}
	in.Lookups = map[string][]int64{"head:fork/r:patch-1": {150}}
	if got := Analyze(in).Links[1]; got != (Link{LinkPullRequest, 150}) {
		t.Fatalf("by lookup = %+v", got)
	}
	in.Lookups = nil
	in.PullRequests = []github.RepositoryPullRequest{{Number: 150, State: "open", HeadRef: "patch-1", HeadSHA: "f2",
		HeadRepository: "fork/r", BaseRef: "main", CreatedAt: at(0), UpdatedAt: at(5)}}
	if got := Analyze(in).Links[1]; got != (Link{LinkPullRequest, 150}) {
		t.Fatalf("by branch = %+v", got)
	}
}

func TestRunsOnOneCommitAreNotSuperseded(t *testing.T) {
	in := example()
	in.Runs = newestFirst(mk(1, 1, "pull_request", "retry", "c3", 1, lists(142)), mk(2, 1, "pull_request", "retry", "c3", 2, lists(142)))
	if a := Analyze(in); len(a.SupersededBy) != 0 || len(a.Overlaps) != 0 {
		t.Fatalf("analysis = %+v", a)
	}
}

func TestOverlapSkipsCancelledAndReRunRunsAndCountsRunningOnesToNow(t *testing.T) {
	in := example()
	in.Runs = newestFirst(
		mk(1, 1, "pull_request", "retry", "c1", 1, lists(142), concluded("cancelled"), endsAt(30)),
		mk(2, 1, "pull_request", "retry", "c2", 10, lists(142), attempt(2), endsAt(40)),
		mk(3, 1, "pull_request", "retry", "c3", 20, lists(142), stillRunning()),
		mk(4, 1, "pull_request", "retry", "c4", 30, lists(142)),
	)
	in.Now = at(45)
	a := Analyze(in)
	if a.SupersededBy[1] != 4 || a.SupersededBy[2] != 4 || a.SupersededBy[3] != 4 {
		t.Fatalf("superseded = %v", a.SupersededBy)
	}
	// 1 was cancelled and 2 is a re-run: no overlap. 3 still runs since 4 started at 30.
	if o := a.Overlaps[1]; !reflect.DeepEqual(o.RunIDs, []int64{3}) || o.Duration != 15*time.Minute {
		t.Fatalf("overlap = %+v", o)
	}
}

func TestTheMostRecentlyUpdatedPullRequestWins(t *testing.T) {
	older := github.RepositoryPullRequest{Number: 142, UpdatedAt: at(1)}
	newer := github.RepositoryPullRequest{Number: 145, UpdatedAt: at(2)}
	in := Input{Runs: []github.Run{mk(1, 1, "push", "shared", "x1", 3, lists(142, 145))},
		PullRequests: []github.RepositoryPullRequest{older, newer}, DefaultBranch: "main", Repository: "o/r"}
	if got := Analyze(in).Links[1]; got != (Link{LinkPullRequest, 145}) {
		t.Fatalf("link = %+v", got)
	}
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `go test ./internal/changes/`
Expected: FAIL to compile (package has no non-test files; `Analyze` undefined).

- [ ] **Step 4: Implement**

Create `core/internal/changes/changes.go`:

```go
// Package changes links GitHub Actions runs to the pull requests and
// commits they ran for, finds runs a newer push replaced and how long they
// kept going, groups runs into changes, and says where a concurrency block
// would help. Pure functions over cached data; no I/O.
package changes

import (
	"sort"
	"time"

	"runnir/core/internal/github"
)

// Input is a workspace's cached activity.
type Input struct {
	// Runs newest first; Run.PullRequests holds the cached links.
	Runs         []github.Run
	PullRequests []github.RepositoryPullRequest
	// Lookup answers by key: "pr:<n>", "commit:<sha>", "head:<owner/name>:<branch>".
	Lookups       map[string][]int64
	DefaultBranch string
	// Lowercased "owner/name" of the repository.
	Repository string
	// The repository's web address, for links to pull requests not read yet.
	RepositoryURL string
	Now           time.Time
}

type LinkKind int

const (
	LinkNone LinkKind = iota
	// The run ran on a commit of the pull request, before its merge.
	LinkPullRequest
	// The run ran on the commit the pull request's merge created.
	LinkAfterMerge
)

type Link struct {
	Kind        LinkKind
	PullRequest int64
}

// Overlap is how long superseded runs of one workflow kept going after the
// next run on a newer commit started. Wall-clock time, not runner minutes.
type Overlap struct {
	RunIDs       []int64
	Duration     time.Duration
	PullRequests []int64
}

// Analysis is what Analyze finds over every cached run.
type Analysis struct {
	Links map[int64]Link
	// SupersededBy maps a run to the newest run of the same workflow and
	// event on a newer commit of its pull request.
	SupersededBy map[int64]int64
	// Overlaps by workflow id.
	Overlaps map[int64]Overlap
}

// Analyze links every run, finds superseded runs and measures their overlap.
func Analyze(in Input) Analysis {
	ix := newIndex(in.PullRequests)
	a := Analysis{Links: map[int64]Link{}, SupersededBy: map[int64]int64{}, Overlaps: map[int64]Overlap{}}
	type key struct {
		pull, workflow int64
		event          string
	}
	groups := map[key][]github.Run{}
	for _, r := range in.Runs {
		link := ix.link(r, in)
		a.Links[r.ID] = link
		if link.Kind == LinkPullRequest && (r.Event == "pull_request" || r.Event == "push") {
			k := key{link.PullRequest, r.WorkflowID, r.Event}
			groups[k] = append(groups[k], r)
		}
	}
	for k, runs := range groups {
		sort.SliceStable(runs, func(i, j int) bool {
			if runs[i].CreatedAt.Equal(runs[j].CreatedAt) {
				return runs[i].ID < runs[j].ID
			}
			return runs[i].CreatedAt.Before(runs[j].CreatedAt)
		})
		for i, r := range runs {
			var next, newest *github.Run
			for j := i + 1; j < len(runs); j++ {
				if runs[j].HeadSHA == r.HeadSHA {
					continue
				}
				if next == nil {
					next = &runs[j]
				}
				newest = &runs[j]
			}
			if newest == nil {
				continue
			}
			a.SupersededBy[r.ID] = newest.ID
			// A cancelled run stopped in time; a re-run of an old commit was
			// started on purpose.
			if r.Conclusion == "cancelled" || r.RunAttempt > 1 {
				continue
			}
			end := r.UpdatedAt
			if r.Status != "completed" {
				end = in.Now
			}
			if d := end.Sub(next.CreatedAt); d > 0 {
				o := a.Overlaps[k.workflow]
				o.RunIDs = append(o.RunIDs, r.ID)
				o.Duration += d
				if !contains(o.PullRequests, k.pull) {
					o.PullRequests = append(o.PullRequests, k.pull)
				}
				a.Overlaps[k.workflow] = o
			}
		}
	}
	for workflow, o := range a.Overlaps {
		sort.Slice(o.RunIDs, func(i, j int) bool { return o.RunIDs[i] < o.RunIDs[j] })
		sort.Slice(o.PullRequests, func(i, j int) bool { return o.PullRequests[i] < o.PullRequests[j] })
		a.Overlaps[workflow] = o
	}
	return a
}

func contains(list []int64, value int64) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}
```

Create `core/internal/changes/link.go`:

```go
package changes

import (
	"time"

	"runnir/core/internal/github"
)

func isPullRequestEvent(event string) bool {
	return event == "pull_request" || event == "pull_request_target"
}

func headKey(repository, branch string) string { return "head:" + repository + ":" + branch }

// index holds the pull requests by what runs are matched on.
type index struct {
	byNumber   map[int64]github.RepositoryPullRequest
	mergedInto map[string][]int64 // merge commit
	byHeadSHA  map[string][]github.RepositoryPullRequest
	byBranch   map[string][]github.RepositoryPullRequest // "owner/name:ref"
}

func newIndex(pulls []github.RepositoryPullRequest) index {
	ix := index{byNumber: map[int64]github.RepositoryPullRequest{}, mergedInto: map[string][]int64{},
		byHeadSHA: map[string][]github.RepositoryPullRequest{}, byBranch: map[string][]github.RepositoryPullRequest{}}
	for _, p := range pulls {
		ix.byNumber[p.Number] = p
		if p.MergeCommitSHA != "" {
			ix.mergedInto[p.MergeCommitSHA] = append(ix.mergedInto[p.MergeCommitSHA], p.Number)
		}
		if p.HeadSHA != "" {
			ix.byHeadSHA[p.HeadSHA] = append(ix.byHeadSHA[p.HeadSHA], p)
		}
		if p.HeadRepository != "" && p.HeadRef != "" {
			key := p.HeadRepository + ":" + p.HeadRef
			ix.byBranch[key] = append(ix.byBranch[key], p)
		}
	}
	return ix
}

// best picks the most recently updated pull request of numbers; one not
// read yet ranks below those read, and among those the highest number wins.
// 0 when numbers is empty.
func (ix index) best(numbers []int64) int64 {
	var best int64
	var bestAt time.Time
	known := false
	for _, n := range numbers {
		p, ok := ix.byNumber[n]
		switch {
		case ok && (!known || p.UpdatedAt.After(bestAt) || (p.UpdatedAt.Equal(bestAt) && n > best)):
			best, bestAt, known = n, p.UpdatedAt, true
		case !ok && !known && n > best:
			best = n
		}
	}
	return best
}

// link decides a run's link; the first rule that matches wins (see the spec).
func (ix index) link(r github.Run, in Input) Link {
	if !isPullRequestEvent(r.Event) {
		// 1. After merge: the run is on the commit a merged pull request
		// created. pull_request_target runs can carry the base branch's
		// commit, so they never take this rule.
		if n := ix.best(ix.mergedInto[r.HeadSHA]); n != 0 {
			return Link{LinkAfterMerge, n}
		}
		// Otherwise a run on the default branch belongs to no pull request:
		// a push to main is not part of a release pull request from main.
		if in.DefaultBranch != "" && r.Branch == in.DefaultBranch {
			return Link{}
		}
	}
	// 2. GitHub's list on the run, and for a fork's run what its lookup found.
	candidates := append([]int64(nil), r.PullRequests...)
	if r.Event == "pull_request" {
		candidates = append(candidates, in.Lookups[headKey(r.HeadRepository, r.Branch)]...)
	}
	if n := ix.best(candidates); n != 0 {
		return Link{LinkPullRequest, n}
	}
	if r.HeadRepository == "" {
		return Link{}
	}
	// 3. The pull request's current head.
	var heads []int64
	for _, p := range ix.byHeadSHA[r.HeadSHA] {
		if p.HeadRepository == r.HeadRepository {
			heads = append(heads, p.Number)
		}
	}
	if n := ix.best(heads); n != 0 {
		return Link{LinkPullRequest, n}
	}
	// 4. The pull request's branch while it was open.
	if r.Event != "pull_request" && r.Event != "push" {
		return Link{}
	}
	var open []int64
	for _, p := range ix.byBranch[r.HeadRepository+":"+r.Branch] {
		if !r.CreatedAt.Before(p.CreatedAt) && (p.ClosedAt.IsZero() || !r.CreatedAt.After(p.ClosedAt)) {
			open = append(open, p.Number)
		}
	}
	if n := ix.best(open); n != 0 {
		return Link{LinkPullRequest, n}
	}
	return Link{}
}
```

- [ ] **Step 5: Run the tests**

Run: `go test ./internal/changes/ && go vet ./internal/changes/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add core/internal/changes
git commit -m "Link runs to pull requests and find superseded runs"
```

---

### Task 7: `internal/changes` — changes, missing pull requests and concurrency hints

**Files:**
- Create: `core/internal/changes/group.go`, `core/internal/changes/missing.go`, `core/internal/changes/hints.go`
- Test: create `core/internal/changes/group_test.go`

**Interfaces:**
- Consumes: `Input`, `Analysis`, `index` (Task 6); `github.SummarizeRuns` (Task 3).
- Produces:

```go
type SectionKind int // SectionAfterMerge = 1, SectionLatestCommit, SectionCommit
type Section struct {
	Kind         SectionKind
	HeadSHA      string
	Branch       string
	CommitTitle  string
	RunIDs       []int64 // newest run per workflow and event, newest first
	RepeatRunIDs []int64 // the other runs of those workflows and events here
}
type PullRequest struct {
	Number     int64
	Title      string
	State      string // "open", "closed", "merged"; "" when not read yet
	Draft      bool
	Author     string
	HTMLURL    string
	HeadBranch string
	BaseBranch string
	MergedAt   time.Time
}
type Change struct {
	ID           string // "pr:142" or "commit:<sha>"
	PullRequest  *PullRequest
	Status       github.CIState
	LatestAt     time.Time
	Sections     []Section
	OlderRunIDs  []int64
	OlderCommits int
}
func Group(in Input, a Analysis, window []github.Run) []Change

type NeedKind int // NeedPullRequest = 1, NeedCommit, NeedHead
type Need struct {
	Kind      NeedKind
	Key       string
	Number    int64
	SHA       string
	HeadOwner string
	Branch    string
}
func Missing(in Input, a Analysis, max int) []Need

type LocalWorkflow struct {
	Path        string
	Triggers    []string
	Concurrency bool
	ParseError  string
}
type Hint struct {
	WorkflowID     int64
	Path           string
	Runs           int
	OverlapMinutes int
	RunIDs         []int64
	PullRequests   []int64
}
const MinOverlappingRuns = 2
func Hints(a Analysis, remote []github.Workflow, local []LocalWorkflow) []Hint
```

- [ ] **Step 1: Write the failing tests**

Create `core/internal/changes/group_test.go`:

```go
package changes

import (
	"reflect"
	"testing"

	"runnir/core/internal/github"
)

func TestTheExampleIsOneChange(t *testing.T) {
	in := example()
	changes := Group(in, Analyze(in), in.Runs)
	if len(changes) != 1 {
		t.Fatalf("changes = %+v", changes)
	}
	c := changes[0]
	if c.ID != "pr:142" || c.PullRequest == nil || c.PullRequest.Title != "Add retry to deploy" || c.PullRequest.State != "merged" ||
		c.Status != github.CIPassed || !c.LatestAt.Equal(at(70)) {
		t.Fatalf("change = %+v", c)
	}
	if len(c.Sections) != 2 {
		t.Fatalf("sections = %+v", c.Sections)
	}
	merged, latest := c.Sections[0], c.Sections[1]
	if merged.Kind != SectionAfterMerge || merged.HeadSHA != "m1" || merged.Branch != "main" || !reflect.DeepEqual(merged.RunIDs, []int64{5, 4}) {
		t.Fatalf("after merge = %+v", merged)
	}
	if latest.Kind != SectionLatestCommit || latest.HeadSHA != "c3" || !reflect.DeepEqual(latest.RunIDs, []int64{3}) {
		t.Fatalf("latest = %+v", latest)
	}
	if !reflect.DeepEqual(c.OlderRunIDs, []int64{2, 1}) || c.OlderCommits != 2 {
		t.Fatalf("older = %v, %d", c.OlderRunIDs, c.OlderCommits)
	}
}

func TestCommitsCollapseRepeats(t *testing.T) {
	in := Input{Runs: newestFirst(
		mk(1, 7, "schedule", "main", "s1", 1),
		mk(2, 7, "schedule", "main", "s1", 2),
		mk(3, 7, "schedule", "main", "s1", 3, concluded("failure")),
		mk(4, 8, "push", "main", "s1", 0),
		mk(5, 1, "push", "main", "s2", 10),
	), DefaultBranch: "main", Repository: "o/r"}
	changes := Group(in, Analyze(in), in.Runs)
	if len(changes) != 2 || changes[0].ID != "commit:s2" || changes[1].ID != "commit:s1" {
		t.Fatalf("changes = %+v", changes)
	}
	s1 := changes[1]
	section := s1.Sections[0]
	if s1.PullRequest != nil || s1.Status != github.CIFailed || section.Kind != SectionCommit ||
		!reflect.DeepEqual(section.RunIDs, []int64{3, 4}) || !reflect.DeepEqual(section.RepeatRunIDs, []int64{2, 1}) {
		t.Fatalf("s1 = %+v", s1)
	}
}

func TestAPullRequestNotReadYetStillFormsAChange(t *testing.T) {
	in := Input{Runs: []github.Run{mk(1, 1, "pull_request", "typo", "t1", 1, lists(300), titled("Fix typo"))},
		DefaultBranch: "main", Repository: "o/r", RepositoryURL: "https://github.com/o/r"}
	c := Group(in, Analyze(in), in.Runs)[0]
	if c.ID != "pr:300" || c.PullRequest.Title != "Fix typo" || c.PullRequest.State != "" ||
		c.PullRequest.HTMLURL != "https://github.com/o/r/pull/300" || c.PullRequest.HeadBranch != "typo" {
		t.Fatalf("change = %+v %+v", c, c.PullRequest)
	}
}

func TestMissingPullRequestsAreAskedForNewestFirst(t *testing.T) {
	in := Input{Runs: newestFirst(
		mk(1, 1, "pull_request", "retry", "c1", 1, lists(142)),
		mk(2, 1, "push", "main", "m1", 2),
		mk(3, 1, "pull_request", "patch-1", "f1", 3, fromRepository("fork/r")),
		mk(4, 1, "push", "main", "m0", 4),
	), Lookups: map[string][]int64{"commit:m0": {}}, DefaultBranch: "main", Repository: "o/r"}
	a := Analyze(in)
	want := []Need{
		{Kind: NeedHead, Key: "head:fork/r:patch-1", HeadOwner: "fork", Branch: "patch-1"},
		{Kind: NeedCommit, Key: "commit:m1", SHA: "m1"},
		{Kind: NeedPullRequest, Key: "pr:142", Number: 142},
	}
	if got := Missing(in, a, 10); !reflect.DeepEqual(got, want) {
		t.Fatalf("needs = %+v", got)
	}
	if got := Missing(in, a, 1); len(got) != 1 || got[0].Key != "head:fork/r:patch-1" {
		t.Fatalf("first need = %+v", got)
	}
}

func TestHintsNeedOverlapsAndAFileWithoutConcurrency(t *testing.T) {
	in := example()
	a := Analyze(in)
	ci := ".github/workflows/ci.yml"
	remote := []github.Workflow{{ID: 1, Path: ci}, {ID: 2, Path: ".github/workflows/deploy.yml"}}
	hints := Hints(a, remote, []LocalWorkflow{{Path: ci, Triggers: []string{"pull_request", "push"}}})
	if len(hints) != 1 || hints[0].WorkflowID != 1 || hints[0].Path != ci || hints[0].Runs != 2 || hints[0].OverlapMinutes != 15 ||
		!reflect.DeepEqual(hints[0].RunIDs, []int64{1, 2}) || !reflect.DeepEqual(hints[0].PullRequests, []int64{142}) {
		t.Fatalf("hints = %+v", hints)
	}
	for name, file := range map[string]LocalWorkflow{
		"has concurrency":         {Path: ci, Triggers: []string{"pull_request"}, Concurrency: true},
		"unreadable":              {Path: ci, Triggers: []string{"pull_request"}, ParseError: "invalid YAML"},
		"called only":             {Path: ci, Triggers: []string{"workflow_call"}},
		"not in the working tree": {Path: ".github/workflows/other.yml", Triggers: []string{"pull_request"}},
	} {
		if got := Hints(a, remote, []LocalWorkflow{file}); len(got) != 0 {
			t.Errorf("%s: hints = %+v", name, got)
		}
	}
	one := example()
	one.Runs = one.Runs[:len(one.Runs)-1] // without run 1, the oldest
	if got := Hints(Analyze(one), remote, []LocalWorkflow{{Path: ci, Triggers: []string{"pull_request"}}}); len(got) != 0 {
		t.Fatalf("one overlapping run made a hint: %+v", got)
	}
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `go test ./internal/changes/`
Expected: FAIL to compile (`Group`, `Missing`, `Hints` undefined).

- [ ] **Step 3: Implement**

Create `core/internal/changes/group.go`:

```go
package changes

import (
	"fmt"
	"time"

	"runnir/core/internal/github"
)

type SectionKind int

const (
	SectionAfterMerge SectionKind = iota + 1
	SectionLatestCommit
	SectionCommit
)

// Section is a change's runs on one commit.
type Section struct {
	Kind        SectionKind
	HeadSHA     string
	Branch      string
	CommitTitle string
	// RunIDs: the newest run of each workflow and event, newest first.
	RunIDs []int64
	// RepeatRunIDs: the other runs of those workflows and events here.
	RepeatRunIDs []int64
}

// PullRequest is what a change shows of its pull request.
type PullRequest struct {
	Number int64
	Title  string
	// "open", "closed" or "merged"; "" when it was not read yet.
	State      string
	Draft      bool
	Author     string
	HTMLURL    string
	HeadBranch string
	BaseBranch string
	MergedAt   time.Time
}

// Change is a pull request with every run linked to it, or a commit with
// the runs that have no link.
type Change struct {
	ID          string
	PullRequest *PullRequest
	// Status of the first section with runs, summed up like the menu bar's.
	Status   github.CIState
	LatestAt time.Time
	// After merge, then the latest commit; a commit has one section.
	Sections []Section
	// Runs on older commits of the pull request, newest first.
	OlderRunIDs  []int64
	OlderCommits int
}

// Group builds the changes of window (newest first), the runs a caller
// shows, newest change first.
func Group(in Input, a Analysis, window []github.Run) []Change {
	ix := newIndex(in.PullRequests)
	byID := make(map[int64]github.Run, len(window))
	var order []string
	members := map[string][]github.Run{}
	for _, r := range window {
		byID[r.ID] = r
		id := "commit:" + r.HeadSHA
		if link := a.Links[r.ID]; link.Kind != LinkNone {
			id = fmt.Sprintf("pr:%d", link.PullRequest)
		}
		if _, seen := members[id]; !seen {
			order = append(order, id)
		}
		members[id] = append(members[id], r)
	}
	out := make([]Change, 0, len(order))
	for _, id := range order {
		runs := members[id]
		change := Change{ID: id, LatestAt: runs[0].CreatedAt}
		if link := a.Links[runs[0].ID]; link.Kind != LinkNone {
			change.PullRequest = pullRequest(ix, in, link.PullRequest, runs)
			change.Sections, change.OlderRunIDs, change.OlderCommits = pullSections(runs, a, ix.byNumber[link.PullRequest])
		} else {
			change.Sections = []Section{section(SectionCommit, runs)}
		}
		change.Status = github.CINone
		for _, s := range change.Sections {
			if len(s.RunIDs) == 0 {
				continue
			}
			shown := make([]github.Run, 0, len(s.RunIDs))
			for _, runID := range s.RunIDs {
				shown = append(shown, byID[runID])
			}
			change.Status = github.SummarizeRuns(shown).State
			break
		}
		out = append(out, change)
	}
	return out
}

func pullSections(runs []github.Run, a Analysis, pr github.RepositoryPullRequest) ([]Section, []int64, int) {
	var merged, onPull []github.Run
	for _, r := range runs {
		if a.Links[r.ID].Kind == LinkAfterMerge {
			merged = append(merged, r)
		} else {
			onPull = append(onPull, r)
		}
	}
	var sections []Section
	if len(merged) > 0 {
		sections = append(sections, section(SectionAfterMerge, merged))
	}
	if len(onPull) == 0 {
		return sections, nil, 0
	}
	latest := onPull[0].HeadSHA
	for _, r := range onPull {
		if pr.HeadSHA != "" && r.HeadSHA == pr.HeadSHA {
			latest = pr.HeadSHA
			break
		}
	}
	var current []github.Run
	var older []int64
	commits := map[string]bool{}
	for _, r := range onPull {
		if r.HeadSHA == latest {
			current = append(current, r)
			continue
		}
		older = append(older, r.ID)
		commits[r.HeadSHA] = true
	}
	return append(sections, section(SectionLatestCommit, current)), older, len(commits)
}

func section(kind SectionKind, runs []github.Run) Section {
	s := Section{Kind: kind, HeadSHA: runs[0].HeadSHA, Branch: runs[0].Branch, CommitTitle: runs[0].CommitTitle}
	seen := map[string]bool{}
	for _, r := range runs {
		key := fmt.Sprintf("%d/%s", r.WorkflowID, r.Event)
		if seen[key] {
			s.RepeatRunIDs = append(s.RepeatRunIDs, r.ID)
			continue
		}
		seen[key] = true
		s.RunIDs = append(s.RunIDs, r.ID)
	}
	return s
}

func pullRequest(ix index, in Input, number int64, runs []github.Run) *PullRequest {
	if p, ok := ix.byNumber[number]; ok {
		state := p.State
		if !p.MergedAt.IsZero() {
			state = "merged"
		}
		return &PullRequest{Number: number, Title: p.Title, State: state, Draft: p.Draft, Author: p.Author, HTMLURL: p.HTMLURL,
			HeadBranch: p.HeadRef, BaseBranch: p.BaseRef, MergedAt: p.MergedAt}
	}
	out := &PullRequest{Number: number}
	if in.RepositoryURL != "" {
		out.HTMLURL = fmt.Sprintf("%s/pull/%d", in.RepositoryURL, number)
	}
	for _, r := range runs {
		if r.Event == "pull_request" && r.DisplayTitle != "" {
			out.Title, out.HeadBranch = r.DisplayTitle, r.Branch
			break
		}
	}
	return out
}
```

Create `core/internal/changes/missing.go`:

```go
package changes

import (
	"fmt"
	"strings"
)

type NeedKind int

const (
	// A pull request a run names that was not read.
	NeedPullRequest NeedKind = iota + 1
	// The pull request merged into a commit on the default branch.
	NeedCommit
	// The pull request of a run from a fork.
	NeedHead
)

// Need is one lookup the runs need; Key is what its answer is kept under.
type Need struct {
	Kind      NeedKind
	Key       string
	Number    int64
	SHA       string
	HeadOwner string
	Branch    string
}

// Missing lists up to max lookups, newest run first, that were not asked
// before.
func Missing(in Input, a Analysis, max int) []Need {
	ix := newIndex(in.PullRequests)
	var out []Need
	seen := map[string]bool{}
	add := func(need Need) {
		if _, asked := in.Lookups[need.Key]; asked || seen[need.Key] || len(out) >= max {
			return
		}
		seen[need.Key] = true
		out = append(out, need)
	}
	for _, r := range in.Runs {
		if len(out) >= max {
			break
		}
		for _, number := range r.PullRequests {
			if _, read := ix.byNumber[number]; !read {
				add(Need{Kind: NeedPullRequest, Key: fmt.Sprintf("pr:%d", number), Number: number})
			}
		}
		if a.Links[r.ID].Kind != LinkNone {
			continue
		}
		switch {
		case !isPullRequestEvent(r.Event) && in.DefaultBranch != "" && r.Branch == in.DefaultBranch && r.HeadSHA != "":
			add(Need{Kind: NeedCommit, Key: "commit:" + r.HeadSHA, SHA: r.HeadSHA})
		case r.Event == "pull_request" && r.HeadRepository != "" && r.HeadRepository != in.Repository && r.Branch != "":
			owner, _, _ := strings.Cut(r.HeadRepository, "/")
			add(Need{Kind: NeedHead, Key: headKey(r.HeadRepository, r.Branch), HeadOwner: owner, Branch: r.Branch})
		}
	}
	return out
}
```

Create `core/internal/changes/hints.go`:

```go
package changes

import (
	"math"

	"runnir/core/internal/github"
)

// MinOverlappingRuns is how many superseded runs of a workflow must have
// kept going before a hint shows.
const MinOverlappingRuns = 2

// LocalWorkflow is a workflow file in the working tree as the scanner read it.
type LocalWorkflow struct {
	Path        string
	Triggers    []string
	Concurrency bool
	ParseError  string
}

// Hint suggests a concurrency block for one workflow.
type Hint struct {
	WorkflowID     int64
	Path           string
	Runs           int
	OverlapMinutes int
	RunIDs         []int64
	PullRequests   []int64
}

// Hints suggest a concurrency block where superseded runs kept going and the
// working tree's file has none, is readable and runs on pull requests or pushes.
func Hints(a Analysis, remote []github.Workflow, local []LocalWorkflow) []Hint {
	files := make(map[string]LocalWorkflow, len(local))
	for _, w := range local {
		files[w.Path] = w
	}
	var out []Hint
	for _, w := range remote {
		o, ok := a.Overlaps[w.ID]
		if !ok || len(o.RunIDs) < MinOverlappingRuns {
			continue
		}
		file, ok := files[w.Path]
		if !ok || file.ParseError != "" || file.Concurrency || !runsOnChanges(file.Triggers) {
			continue
		}
		out = append(out, Hint{WorkflowID: w.ID, Path: w.Path, Runs: len(o.RunIDs),
			OverlapMinutes: int(math.Ceil(o.Duration.Minutes())), RunIDs: o.RunIDs, PullRequests: o.PullRequests})
	}
	return out
}

func runsOnChanges(triggers []string) bool {
	for _, t := range triggers {
		if t == "pull_request" || t == "push" {
			return true
		}
	}
	return false
}
```

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/changes/ && go vet ./internal/changes/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/changes
git commit -m "Group runs into changes, list missing pull requests, suggest concurrency"
```

---

### Task 8: Workspace sync reads pull requests, fills gaps, looks up and loads older runs

**Files:**
- Modify: `core/internal/workspace/runtime.go` (Snapshot, Runtime fields, Refresh, pass, read, Snapshot(), credentialChanged)
- Create: `core/internal/workspace/links.go` (input, gap filling, lookups), `core/internal/workspace/older.go`
- Test: `core/internal/workspace/helpers_test.go` (fake GitHub), create `core/internal/workspace/links_test.go`, `core/internal/server/workspace_test.go` (`countingGitHub` answers the new reads)

**Interfaces:**
- Consumes: Tasks 2–7.
- Produces:

```go
// Snapshot gains:
	Analysis           changes.Analysis
	Changes            []changes.Change
	CachedRuns         int
	HistoryComplete    bool
	PullRequestsAccess corev1.GithubAccess
type OlderRuns struct {
	Access          corev1.GithubAccess
	RetryAfter      time.Time
	Added           int
	HistoryComplete bool
	BudgetReached   bool
}
func (r *Runtime) LoadOlderRuns(ctx context.Context) (OlderRuns, error)
```

`Snapshot(ctx, limit)` now reads every cached run (`store.MaxRuns`) to link them, and returns the newest `limit`.

- [ ] **Step 1: Teach the fake GitHub the new reads**

In `core/internal/workspace/helpers_test.go`, replace `fakeGitHub`, `newFake` and `serve` with:

```go
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
```

Add `"strings"` to the imports of `helpers_test.go`.

In `core/internal/server/workspace_test.go`, make `countingGitHub` answer the new reads (the server's workspace tests sync through the same runtime): add to its switch

```go
		case "/repos/o/r":
			_, _ = w.Write([]byte(`{"full_name":"o/r","default_branch":"main"}`))
		case "/repos/o/r/pulls":
			_, _ = w.Write([]byte(`[]`))
```

- [ ] **Step 2: Write the failing tests**

Create `core/internal/workspace/links_test.go`:

```go
//go:build !windows

package workspace

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"runnir/core/internal/changes"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/store"
)

// runsPage is a runs page of ids, each a minute older than the one before,
// the first created at newest.
func runsPage(ids []int, newest time.Time) string {
	parts := make([]string, 0, len(ids))
	for i, id := range ids {
		created := newest.Add(-time.Duration(i) * time.Minute).UTC().Format(time.RFC3339)
		parts = append(parts, fmt.Sprintf(`{"id":%d,"workflow_id":3,"name":"CI","run_number":%d,"run_attempt":1,"event":"push","status":"completed","conclusion":"success","head_branch":"main","head_sha":"s%d","created_at":%q,"updated_at":%q}`,
			id, id, id, created, created))
	}
	return `{"workflow_runs":[` + strings.Join(parts, ",") + `]}`
}

// span is from down to to, both included.
func span(from, to int) []int {
	var out []int
	for id := from; id >= to; id-- {
		out = append(out, id)
	}
	return out
}

const pullsPath = "/repos/o/r/pulls"

func TestPullRequestsAreReadNextToRuns(t *testing.T) {
	fake, accounts := newFake(t)
	fake.set(func(f *fakeGitHub) {
		f.runs = `{"workflow_runs":[
			{"id":8,"workflow_id":3,"name":"CI","run_number":2,"run_attempt":1,"event":"push","status":"completed","conclusion":"success","head_branch":"main","head_sha":"m1","created_at":"2026-10-18T11:00:00Z","updated_at":"2026-10-18T11:04:00Z"},
			{"id":7,"workflow_id":3,"name":"CI","run_number":1,"run_attempt":1,"event":"pull_request","status":"completed","conclusion":"success","head_branch":"retry","head_sha":"c3","created_at":"2026-10-18T10:00:00Z","updated_at":"2026-10-18T10:04:00Z","head_repository":{"full_name":"o/r"}}]}`
		f.pulls = `[{"number":142,"title":"Add retry","state":"closed","head":{"ref":"retry","sha":"c3","repo":{"full_name":"o/r"}},"base":{"ref":"main"},"merge_commit_sha":"m1","created_at":"2026-10-18T09:00:00Z","updated_at":"2026-10-18T10:30:00Z","closed_at":"2026-10-18T10:30:00Z","merged_at":"2026-10-18T10:30:00Z"}]`
	})
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	waitRefresh(t, r)
	snap, err := r.Snapshot(context.Background(), 50)
	if err != nil || len(snap.Changes) != 1 || snap.Changes[0].ID != "pr:142" || len(snap.Changes[0].Sections) != 2 ||
		snap.Analysis.Links[8].Kind != changes.LinkAfterMerge || snap.CachedRuns != 2 || !snap.HistoryComplete {
		t.Fatalf("snapshot = %+v, %v", snap, err)
	}
	if snap.PullRequestsAccess != corev1.GithubAccess_GITHUB_ACCESS_OK {
		t.Fatalf("pull requests access = %v", snap.PullRequestsAccess)
	}
	// The default branch is read once; the list on every pass, like the
	// runs (the opening pass may come before or after the first refresh).
	if passes := fake.count(runsPath); fake.count("/repos/o/r") != 1 || fake.count(pullsPath) != passes || passes < 2 {
		t.Fatalf("repository reads %d, pull request reads %d, passes %d", fake.count("/repos/o/r"), fake.count(pullsPath), passes)
	}
}

func TestARefusedPullRequestListKeepsThePassOKAndStopsLookups(t *testing.T) {
	fake, accounts := newFake(t)
	fake.set(func(f *fakeGitHub) {
		f.pullsStatus = http.StatusForbidden
		f.runs = `{"workflow_runs":[{"id":7,"workflow_id":3,"name":"CI","run_number":1,"run_attempt":1,"event":"pull_request","status":"completed","conclusion":"success","head_branch":"retry","head_sha":"c3","created_at":"2026-10-18T10:00:00Z","updated_at":"2026-10-18T10:04:00Z","pull_requests":[{"number":142,"base":{"repo":{"url":"https://api.github.com/repos/o/r"}}}]}]}`
	})
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	snap, _ := r.Snapshot(context.Background(), 50)
	if snap.Access != corev1.GithubAccess_GITHUB_ACCESS_OK || snap.PullRequestsAccess != corev1.GithubAccess_GITHUB_ACCESS_PERMISSION_MISSING ||
		len(snap.Runs) != 1 || fake.count(pullsPath+"/142") != 0 {
		t.Fatalf("snapshot = %+v, lookups %d", snap, fake.count(pullsPath+"/142"))
	}
	// A refresh tries again; the missing pull request is looked up once.
	fake.set(func(f *fakeGitHub) {
		f.pullsStatus = 0
		f.extra[pullsPath+"/142"] = `{"number":142,"title":"Add retry","state":"open","head":{"ref":"retry","sha":"c3","repo":{"full_name":"o/r"}},"base":{"ref":"main"}}`
	})
	waitRefresh(t, r)
	waitRefresh(t, r)
	snap, _ = r.Snapshot(context.Background(), 50)
	if snap.PullRequestsAccess != corev1.GithubAccess_GITHUB_ACCESS_OK || len(snap.Changes) != 1 ||
		snap.Changes[0].PullRequest.Title != "Add retry" || fake.count(pullsPath+"/142") != 1 {
		t.Fatalf("snapshot = %+v, lookups %d", snap, fake.count(pullsPath+"/142"))
	}
}

func TestAGapIsFilledFromOlderPages(t *testing.T) {
	fake, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r) // run 7, 2026-10-18
	newer := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	fake.set(func(f *fakeGitHub) {
		f.runs, f.etag = runsPage(span(1049, 1000), newer), `"v2"`
		// The next older page reaches run 7 and is the end of the history.
		f.older = runsPage(append(span(999, 990), 7), newer.Add(-50*time.Minute))
	})
	waitRefresh(t, r)
	snap, _ := r.Snapshot(context.Background(), 5000)
	if snap.CachedRuns != 61 || !snap.HistoryComplete || fake.count(runsPath+"?created") != 1 {
		t.Fatalf("cached %d, complete %v, older reads %d", snap.CachedRuns, snap.HistoryComplete, fake.count(runsPath+"?created"))
	}
}

func TestAGapThatNeverClosesStartsTheHistoryAgain(t *testing.T) {
	fake, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r) // run 7, 2026-10-18
	newer := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	fake.set(func(f *fakeGitHub) {
		f.runs, f.etag = runsPage(span(1049, 1000), newer), `"v2"`
		// GitHub keeps answering the same hundred runs, all newer than run 7.
		f.older = runsPage(span(1099, 1000), newer)
	})
	waitRefresh(t, r)
	snap, _ := r.Snapshot(context.Background(), 5000)
	if snap.CachedRuns != 100 || snap.HistoryComplete {
		t.Fatalf("cached %d, complete %v", snap.CachedRuns, snap.HistoryComplete)
	}
	for _, run := range snap.Runs {
		if run.ID == 7 {
			t.Fatal("the run before the gap was kept")
		}
	}
}

func TestLoadOlderRunsExtendsTheHistory(t *testing.T) {
	fake, accounts := newFake(t)
	newer := time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)
	fake.set(func(f *fakeGitHub) {
		f.runs = runsPage(span(1049, 1000), newer)
		f.older = runsPage(span(999, 970), newer.Add(-50*time.Minute))
	})
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r) // nothing was cached, so no gap: 50 runs, history open
	ctx := context.Background()
	result, err := r.LoadOlderRuns(ctx)
	if err != nil || result.Access != corev1.GithubAccess_GITHUB_ACCESS_OK || result.Added != 30 || !result.HistoryComplete || result.BudgetReached {
		t.Fatalf("result = %+v, %v", result, err)
	}
	again, _ := r.LoadOlderRuns(ctx)
	if !again.HistoryComplete || again.Added != 0 || fake.count(runsPath+"?created") != 1 {
		t.Fatalf("again = %+v, older reads %d", again, fake.count(runsPath+"?created"))
	}
}

func TestLoadOlderRunsStopsAtTheBudget(t *testing.T) {
	old := store.MaxRuns
	store.MaxRuns = 50
	t.Cleanup(func() { store.MaxRuns = old })
	fake, accounts := newFake(t)
	fake.set(func(f *fakeGitHub) { f.runs = runsPage(span(1049, 1000), time.Date(2026, 10, 19, 12, 0, 0, 0, time.UTC)) })
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	result, err := r.LoadOlderRuns(context.Background())
	if err != nil || !result.BudgetReached || fake.count(runsPath+"?created") != 0 {
		t.Fatalf("result = %+v, %v, older reads %d", result, err, fake.count(runsPath+"?created"))
	}
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `go test ./internal/workspace/`
Expected: FAIL to compile (`snap.Changes`, `LoadOlderRuns` undefined).

- [ ] **Step 4: Implement**

In `core/internal/workspace/runtime.go`:

1. Add `"runnir/core/internal/changes"` to the imports.

2. Replace the `Snapshot` type:

```go
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
```

3. Add to `Runtime`, after `flights singleflight.Group`:

```go
	// branchFor is the target whose default branch a pass read in this
	// process; only the loop goroutine uses it.
	branchFor store.Source
```

and after `hasServer bool` (under `mu`):

```go
	// pullsRefused: GitHub refused pull requests; they are not read again
	// until the credential changes or someone asks for a refresh.
	pullsRefused bool
```

4. In `Refresh`, right after `r.mu.Lock()`:

```go
	// Asking for a refresh tries pull requests again after a refusal.
	r.pullsRefused = false
```

5. Replace the body of `pass` from `p, server, hasServer := r.read(resolve)` to the end:

```go
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
```

6. Replace `read`:

```go
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
```

7. Replace `Snapshot`:

```go
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
```

8. In `credentialChanged`, inside `if match { … }`, add `r.pullsRefused = false` next to `r.failures = 0`.

Create `core/internal/workspace/links.go`:

```go
package workspace

import (
	"context"
	"errors"
	"strings"
	"time"

	"runnir/core/internal/changes"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

const (
	// maxGapPages bounds the older pages of 100 a pass reads to reach the
	// cached runs.
	maxGapPages = 10
	// maxLookups bounds the lookup requests of one pass.
	maxLookups = 10
)

// input is the cache as the changes package reads it.
func input(a store.Activity, target Target, now time.Time) changes.Input {
	return changes.Input{
		Runs: a.Runs, PullRequests: a.PullRequests, Lookups: a.Lookups, DefaultBranch: a.DefaultBranch,
		Repository:    strings.ToLower(target.Owner + "/" + target.Name),
		RepositoryURL: "https://" + target.Account.Server.WebHost + "/" + target.Owner + "/" + target.Name,
		Now:           now,
	}
}

// fillGap reads older pages until the newest runs reach the cached ones.
// When they never do, the update starts the history again from them.
func (r *Runtime) fillGap(client *github.Client, target Target, u *store.RunsUpdate) error {
	newest, cached, err := r.cfg.store.Newest(r.ctx, target.Source())
	if err != nil || !cached {
		return err
	}
	seen := make(map[int64]bool, len(u.Runs))
	for _, run := range u.Runs {
		seen[run.ID] = true
	}
	for page := 0; ; page++ {
		oldest := u.Runs[len(u.Runs)-1].CreatedAt
		if !oldest.After(newest) {
			return nil
		}
		if page == maxGapPages {
			u.Restart = true
			return nil
		}
		more, err := client.OlderRuns(r.ctx, target.Owner, target.Name, oldest, 100)
		if err != nil {
			return err
		}
		added := 0
		for _, run := range more {
			if !seen[run.ID] {
				seen[run.ID] = true
				u.Runs = append(u.Runs, run)
				added++
			}
		}
		if len(more) < 100 {
			u.Complete = true
			return nil
		}
		if added == 0 { // GitHub keeps answering the same runs
			u.Restart = true
			return nil
		}
	}
}

// lookUp asks GitHub for at most maxLookups pull requests the cached runs
// miss, and stores the answers. A refusal stops pull request reads like a
// refused list.
func (r *Runtime) lookUp(target Target) {
	r.mu.Lock()
	refused := r.pullsRefused
	r.mu.Unlock()
	if refused {
		return
	}
	source := target.Source()
	a, err := r.cfg.store.Activity(r.ctx, store.MaxRuns)
	if err != nil || !a.HasSource || a.Source != source {
		return
	}
	in := input(a, target, r.cfg.now())
	needs := changes.Missing(in, changes.Analyze(in), maxLookups)
	if len(needs) == 0 {
		return
	}
	update := store.LookupsUpdate{Source: source, At: r.cfg.now()}
	for _, need := range needs {
		lookup, err := lookUpOne(r.ctx, target, need)
		if err != nil {
			if errors.Is(err, github.ErrPermissionMissing) {
				access, _, _ := Access(target.Account, err)
				update.Access = int32(access)
				r.refusePulls()
			}
			break
		}
		update.Lookups = append(update.Lookups, lookup)
	}
	_, _ = r.cfg.store.ApplyLookups(r.ctx, update)
}

func lookUpOne(ctx context.Context, target Target, need changes.Need) (store.Lookup, error) {
	client := target.Account.Client
	lookup := store.Lookup{Key: need.Key, Numbers: []int64{}}
	var found []github.RepositoryPullRequest
	var err error
	switch need.Kind {
	case changes.NeedPullRequest:
		var pr github.RepositoryPullRequest
		if pr, err = client.RepositoryPull(ctx, target.Owner, target.Name, need.Number); err == nil {
			found = []github.RepositoryPullRequest{pr}
		}
	case changes.NeedCommit:
		var prs []github.RepositoryPullRequest
		if prs, err = client.CommitPullRequests(ctx, target.Owner, target.Name, need.SHA); err == nil {
			// The commit is in other pull requests too (one from main, say):
			// only the one whose merge created it counts.
			for _, pr := range prs {
				if pr.MergeCommitSHA == need.SHA {
					found = append(found, pr)
				}
			}
		}
	case changes.NeedHead:
		found, err = client.HeadPullRequests(ctx, target.Owner, target.Name, need.HeadOwner, need.Branch)
	}
	var rejected *github.RejectedError
	switch {
	case errors.Is(err, github.ErrNotVisible), errors.As(err, &rejected):
		// No such pull request, or GitHub does not know the commit any
		// more: remembered as nothing found.
		return lookup, nil
	case err != nil:
		return store.Lookup{}, err
	}
	for _, pr := range found {
		lookup.Numbers = append(lookup.Numbers, pr.Number)
	}
	lookup.PullRequests = found
	return lookup, nil
}
```

Create `core/internal/workspace/older.go`:

```go
package workspace

import (
	"context"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/store"
)

// olderPage is how many runs LoadOlderRuns reads.
const olderPage = 100

// OlderRuns is what LoadOlderRuns did.
type OlderRuns struct {
	Access          corev1.GithubAccess
	RetryAfter      time.Time
	Added           int
	HistoryComplete bool
	// The cache holds store.MaxRuns runs; older ones stay on GitHub.
	BudgetReached bool
}

// LoadOlderRuns reads one page of runs older than the oldest cached one and
// stores it. Concurrent calls share one request.
func (r *Runtime) LoadOlderRuns(ctx context.Context) (OlderRuns, error) {
	select {
	case <-r.loopDone:
		return OlderRuns{}, ErrClosed
	default:
	}
	ch := r.flights.DoChan("older", func() (any, error) { return r.loadOlder() })
	select {
	case result := <-ch:
		if result.Err != nil {
			return OlderRuns{}, result.Err
		}
		return result.Val.(OlderRuns), nil
	case <-ctx.Done():
		return OlderRuns{}, ctx.Err()
	}
}

func (r *Runtime) loadOlder() (OlderRuns, error) {
	r.mu.Lock()
	resolve := r.resolve
	r.mu.Unlock()
	target, problem := resolve()
	if problem != corev1.GithubAccess_GITHUB_ACCESS_OK {
		return OlderRuns{Access: problem}, nil
	}
	source := target.Source()
	history, ok, err := r.cfg.store.History(r.ctx, source)
	if err != nil {
		return OlderRuns{}, err
	}
	result := OlderRuns{Access: corev1.GithubAccess_GITHUB_ACCESS_OK}
	switch {
	case !ok: // nothing cached yet: the sync pass reads the newest runs first
		return result, nil
	case history.Count >= store.MaxRuns:
		result.BudgetReached = true
		return result, nil
	case history.Complete:
		result.HistoryComplete = true
		return result, nil
	}
	fetchCtx, cancel := context.WithTimeout(r.ctx, r.cfg.intervals.FetchTimeout)
	defer cancel()
	runs, err := target.Account.Client.OlderRuns(fetchCtx, target.Owner, target.Name, history.Oldest, olderPage)
	if err != nil {
		access, retry, cancelled := Access(target.Account, err)
		if cancelled != nil {
			access = corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE
		}
		return OlderRuns{Access: access, RetryAfter: retry}, nil
	}
	complete := len(runs) < olderPage
	added, err := r.cfg.store.AddOlderRuns(r.ctx, source, history.Oldest, runs, complete)
	if err != nil {
		return OlderRuns{}, err
	}
	result.Added, result.HistoryComplete = added, complete
	result.BudgetReached = history.Count+added >= store.MaxRuns
	if added > 0 || complete {
		r.publish()
	}
	return result, nil
}
```

- [ ] **Step 5: Run the tests**

Run: `go test ./... && go vet ./internal/workspace/` (from `core/`; also `go test -race ./internal/workspace/`)
Expected: PASS (the existing runtime and server tests too: the first pass now also reads `/repos/o/r` and `/repos/o/r/pulls`, which the fakes answer).

- [ ] **Step 6: Commit**

```bash
git add core/internal/workspace core/internal/server/workspace_test.go
git commit -m "Sync pull requests, fill gaps, look up missing pull requests and load older runs"
```

---

### Task 9: The scanner detects and inserts `concurrency`

**Files:**
- Modify: `core/internal/repository/manager.go:46-52` (`Workflow`)
- Modify: `core/internal/scanner/scanner.go:452-526` (`parse`, `jobs`)
- Create: `core/internal/scanner/concurrency.go`
- Test: create `core/internal/scanner/concurrency_test.go`; `core/internal/validate/validate_test.go`

**Interfaces:**
- Produces:

```go
// repository.Workflow gains: Concurrency bool
type ConcurrencyRefusal int // ConcurrencyInserted (0), ConcurrencyAlreadyPresent, ConcurrencyNoJobs, ConcurrencyNotBlockMapping, ConcurrencyParseError, ConcurrencyTooLarge
type ConcurrencyEdit struct {
	Content   string
	FirstLine int // 1-based, the block's first line
	LastLine  int
	Refusal   ConcurrencyRefusal
}
func InsertConcurrency(content string) ConcurrencyEdit
```

- [ ] **Step 1: Write the failing tests**

Create `core/internal/scanner/concurrency_test.go`:

```go
package scanner

import (
	"strings"
	"testing"
)

const concurrencyCI = "name: CI\non:\n  pull_request:\n  push:\n\n# The jobs\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make\n"

func TestConcurrencyIsDetected(t *testing.T) {
	for name, tc := range map[string]struct {
		source string
		want   bool
	}{
		"none":      {concurrencyCI, false},
		"top level": {"on: push\nconcurrency: ci\njobs:\n  a:\n    runs-on: x\n", true},
		"in a job":  {"on: push\njobs:\n  a:\n    concurrency: ci\n    runs-on: x\n", true},
	} {
		if got := parse("ci.yml", []byte(tc.source)); got.Concurrency != tc.want || got.ParseError != "" {
			t.Errorf("%s: %+v", name, got)
		}
	}
}

func TestConcurrencyGoesBeforeJobsAndItsComments(t *testing.T) {
	edit := InsertConcurrency(concurrencyCI)
	if edit.Refusal != ConcurrencyInserted || edit.FirstLine != 6 || edit.LastLine != 9 {
		t.Fatalf("edit = %+v", edit)
	}
	lines := strings.Split(edit.Content, "\n")
	if !strings.HasPrefix(lines[5], "# Newer commits on a pull request") || lines[6] != "concurrency:" ||
		lines[8] != "  cancel-in-progress: true" || lines[9] != "" || lines[10] != "# The jobs" || lines[11] != "jobs:" {
		t.Fatalf("content =\n%s", edit.Content)
	}
	if w := parse("ci.yml", []byte(edit.Content)); !w.Concurrency || w.ParseError != "" || len(w.Jobs) != 1 {
		t.Fatalf("parsed = %+v", w)
	}
}

func TestABlankLineSeparatesTheBlockFromTheKeyAbove(t *testing.T) {
	edit := InsertConcurrency("on: push\njobs:\n  a:\n    runs-on: x\n")
	lines := strings.Split(edit.Content, "\n")
	if edit.FirstLine != 3 || edit.LastLine != 6 || lines[1] != "" || lines[6] != "" || lines[7] != "jobs:" {
		t.Fatalf("edit = %+v\n%s", edit, edit.Content)
	}
}

func TestConcurrencyKeepsWindowsLineEndings(t *testing.T) {
	edit := InsertConcurrency(strings.ReplaceAll(concurrencyCI, "\n", "\r\n"))
	if edit.Refusal != ConcurrencyInserted || strings.Count(edit.Content, "\n") != strings.Count(edit.Content, "\r\n") {
		t.Fatalf("edit = %q", edit.Content)
	}
}

func TestConcurrencyRefusals(t *testing.T) {
	for name, tc := range map[string]struct {
		source string
		want   ConcurrencyRefusal
	}{
		"already at the top": {"concurrency: x\non: push\njobs:\n  a:\n    runs-on: y\n", ConcurrencyAlreadyPresent},
		"already in a job":   {"on: push\njobs:\n  a:\n    concurrency: x\n    runs-on: y\n", ConcurrencyAlreadyPresent},
		"no jobs":            {"on: push\n", ConcurrencyNoJobs},
		"flow mapping":       {"{on: push, jobs: {}}\n", ConcurrencyNotBlockMapping},
		"two documents":      {"on: push\njobs: {}\n---\non: push\n", ConcurrencyNotBlockMapping},
		"indented root":      {"  on: push\n  jobs:\n    a:\n      runs-on: y\n", ConcurrencyNotBlockMapping},
		"not YAML":           {"on: [push\n", ConcurrencyParseError},
		"empty":              {"", ConcurrencyParseError},
		"too large":          {strings.Repeat("#", maxFileBytes+1), ConcurrencyTooLarge},
	} {
		if got := InsertConcurrency(tc.source); got.Refusal != tc.want || got.Content != "" {
			t.Errorf("%s: %+v", name, got)
		}
	}
}
```

Append to `core/internal/validate/validate_test.go` (add `"runnir/core/internal/scanner"` to its imports):

```go
func TestTheConcurrencyBlockPassesActionlint(t *testing.T) {
	root := repo(t)
	edit := scanner.InsertConcurrency("name: CI\non:\n  pull_request:\n  push:\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make\n")
	if edit.Refusal != scanner.ConcurrencyInserted {
		t.Fatalf("refusal = %v", edit.Refusal)
	}
	write(t, root, ".github/workflows/ci.yml", edit.Content)
	report, err := Workflows(context.Background(), root, "")
	if err != nil || len(report.Results) != 1 || len(report.Results[0].Diagnostics) != 0 || report.Results[0].Problem != "" {
		t.Fatalf("report = %+v, %v", report, err)
	}
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `go test ./internal/scanner/ ./internal/validate/`
Expected: FAIL to compile (`Concurrency`, `InsertConcurrency` undefined).

- [ ] **Step 3: Implement**

In `core/internal/repository/manager.go`, add to `Workflow` after `Jobs []Job`:

```go
	// Concurrency: the file sets concurrency at the top level or in a job.
	Concurrency bool
```

In `core/internal/scanner/scanner.go` `parse`, add a case to the top-level switch:

```go
		case "concurrency":
			workflow.Concurrency = true
```

and in `jobs`, add a case to the switch over a job's keys:

```go
				case "concurrency":
					workflow.Concurrency = true
```

Create `core/internal/scanner/concurrency.go`:

```go
package scanner

import (
	"io"
	"strings"

	"go.yaml.in/yaml/v3"
)

// concurrencyBlock is what InsertConcurrency adds. Pull requests group by
// number and pushes to other branches than the default by ref, so a newer
// commit cancels the older run in progress; everything else gets a group
// of its own (run_id) and is never cancelled or queued.
const concurrencyBlock = "# Newer commits on a pull request or branch cancel its older runs; runs on the default branch, scheduled and manual runs are never cancelled.\n" +
	"concurrency:\n" +
	"  group: ${{ github.workflow }}-${{ github.event.pull_request.number || (github.event_name == 'push' && github.ref != format('refs/heads/{0}', github.event.repository.default_branch) && github.ref) || github.run_id }}\n" +
	"  cancel-in-progress: true"

// ConcurrencyRefusal says why InsertConcurrency changed nothing.
type ConcurrencyRefusal int

const (
	ConcurrencyInserted ConcurrencyRefusal = iota
	ConcurrencyAlreadyPresent
	ConcurrencyNoJobs
	ConcurrencyNotBlockMapping
	ConcurrencyParseError
	ConcurrencyTooLarge
)

// ConcurrencyEdit is the text with the block and the block's first and last
// line (1-based), or the refusal with no text.
type ConcurrencyEdit struct {
	Content   string
	FirstLine int
	LastLine  int
	Refusal   ConcurrencyRefusal
}

// InsertConcurrency adds the concurrency block to a workflow's text before
// the top-level jobs key, or before the comment lines directly above it,
// keeping the file's line endings. It reads nothing from disk.
func InsertConcurrency(content string) ConcurrencyEdit {
	if len(content) > maxFileBytes {
		return ConcurrencyEdit{Refusal: ConcurrencyTooLarge}
	}
	decoder := yaml.NewDecoder(strings.NewReader(content))
	var document yaml.Node
	if err := decoder.Decode(&document); err != nil {
		return ConcurrencyEdit{Refusal: ConcurrencyParseError}
	}
	var more yaml.Node
	if err := decoder.Decode(&more); err != io.EOF {
		return ConcurrencyEdit{Refusal: ConcurrencyNotBlockMapping}
	}
	if document.Kind != yaml.DocumentNode || len(document.Content) != 1 {
		return ConcurrencyEdit{Refusal: ConcurrencyParseError}
	}
	top := resolve(document.Content[0])
	if top.Kind != yaml.MappingNode || top.Style&yaml.FlowStyle != 0 {
		return ConcurrencyEdit{Refusal: ConcurrencyNotBlockMapping}
	}
	jobsLine := 0
	for i := 0; i+1 < len(top.Content); i += 2 {
		key, value := top.Content[i], resolve(top.Content[i+1])
		switch key.Value {
		case "concurrency":
			return ConcurrencyEdit{Refusal: ConcurrencyAlreadyPresent}
		case "jobs":
			if key.Column != 1 {
				return ConcurrencyEdit{Refusal: ConcurrencyNotBlockMapping}
			}
			jobsLine = key.Line
			if value.Kind == yaml.MappingNode {
				for j := 0; j+1 < len(value.Content); j += 2 {
					if body := resolve(value.Content[j+1]); body.Kind == yaml.MappingNode && hasKey(body, "concurrency") {
						return ConcurrencyEdit{Refusal: ConcurrencyAlreadyPresent}
					}
				}
			}
		}
	}
	if jobsLine == 0 {
		return ConcurrencyEdit{Refusal: ConcurrencyNoJobs}
	}
	newline := "\n"
	if strings.Contains(content, "\r\n") {
		newline = "\r\n"
	}
	lines := strings.SplitAfter(content, "\n")
	at := jobsLine - 1
	for at > 0 && strings.HasPrefix(strings.TrimSpace(lines[at-1]), "#") {
		at--
	}
	var inserted []string
	if at > 0 && strings.TrimSpace(lines[at-1]) != "" {
		inserted = append(inserted, "")
	}
	first := at + len(inserted) + 1
	inserted = append(inserted, strings.Split(concurrencyBlock, "\n")...)
	last := at + len(inserted)
	inserted = append(inserted, "")
	var b strings.Builder
	for _, line := range lines[:at] {
		b.WriteString(line)
	}
	for _, line := range inserted {
		b.WriteString(line)
		b.WriteString(newline)
	}
	for _, line := range lines[at:] {
		b.WriteString(line)
	}
	return ConcurrencyEdit{Content: b.String(), FirstLine: first, LastLine: last}
}

func hasKey(mapping *yaml.Node, name string) bool {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == name {
			return true
		}
	}
	return false
}
```

- [ ] **Step 4: Run the tests**

Run: `go test ./internal/scanner/ ./internal/validate/ ./internal/repository/`
Expected: PASS. If actionlint reports a diagnostic on the block's expression, stop and report the message: the block is copied from the spec and must not be changed without the user.

- [ ] **Step 5: Commit**

```bash
git add core/internal/repository/manager.go core/internal/scanner core/internal/validate/validate_test.go
git commit -m "Detect concurrency in workflow files and insert the suggested block"
```

---

### Task 10: Contract and server

**Files:**
- Modify: `contracts/grpc/runnir/core/v1/runnir_core.proto`
- Regenerate: `core/internal/gen/runnir/core/v1/*`, `apps/macos/Runnir/IPC/Generated/runnir/core/v1/*`
- Modify: `core/internal/server/workspace.go`, `core/internal/server/service.go:142-156` (`ListWorkflows`)
- Create: `core/internal/server/changes.go`
- Test: `core/internal/server/workspace_test.go`

**Interfaces:**
- Consumes: `workspace.Snapshot` (Task 8), `changes.Hints`/`LocalWorkflow` (Task 7), `scanner.InsertConcurrency` (Task 9), `repository.Workflow.Concurrency`.
- Produces: the messages and RPCs below; Swift sees them as `Runnir_Core_V1_*` (field `head_repository` → `headRepository`, `run_ids` → `runIds`, `superseded_by` → `supersededBy`, enum cases without their prefix, e.g. `.afterMerge`).

- [ ] **Step 1: Change the proto**

In `service RunnirCore`, after `rpc RefreshWorkspaceActivity(…)`:

```proto
  // Reads one page of runs older than the oldest cached one from GitHub and
  // stores it; nothing is read when the cache holds 5000 runs or the whole
  // history. Concurrent calls for one workspace share one request.
  rpc LoadOlderRuns(LoadOlderRunsRequest) returns (LoadOlderRunsResponse);
```

after `rpc RenameWorkflowFile(…)`:

```proto
  // The editor's text with the suggested concurrency block before the
  // top-level jobs key, or why it was not added. Writes nothing.
  rpc InsertWorkflowConcurrency(InsertWorkflowConcurrencyRequest) returns (InsertWorkflowConcurrencyResponse);
```

In `message Workflow`, after `parse_error = 5`:

```proto
  // The file sets concurrency at the top level or in a job.
  bool concurrency = 6;
```

In `message WorkflowRun`, after `run_attempt = 15`:

```proto
  // "owner/name" the head commit came from; a fork's differs.
  string head_repository = 16;
  // The first line of the head commit's message.
  string commit_title = 17;
  // Set in workspace activity only.
  RunLink link = 18;
  // The newest run of the same workflow and event on a newer commit of the
  // same pull request; 0 when not superseded. Workspace activity only.
  int64 superseded_by = 19;
```

Change the comment of `GetWorkspaceActivityRequest.limit` to `// Runs to return, newest first: 1 to 5000; 0 means 200.`

Replace `message WorkspaceActivity` and extend `ActivityFreshness`:

```proto
message WorkspaceActivity {
  repeated WorkflowRun runs = 1;
  repeated GitHubWorkflow workflows = 2;
  ActivityFreshness freshness = 3;
  // The changes of runs above, newest first.
  repeated RunChange changes = 4;
  repeated ConcurrencyHint concurrency_hints = 5;
  // Every run in the cache.
  uint32 cached_runs = 6;
  // GitHub has no run older than the oldest cached one.
  bool history_complete = 7;
}
```

```proto
  // Reading pull requests: UNSPECIFIED before a read, else OK,
  // PERMISSION_MISSING or NOT_VISIBLE.
  GithubAccess pull_requests_access = 7;
```

Add after `ActivityFreshness`:

```proto
enum RunLinkKind {
  RUN_LINK_KIND_UNSPECIFIED = 0;
  RUN_LINK_KIND_NONE = 1;
  // Ran on a commit of the pull request, before its merge.
  RUN_LINK_KIND_PULL_REQUEST = 2;
  // Ran on the commit the pull request's merge created.
  RUN_LINK_KIND_AFTER_MERGE = 3;
}

message RunLink {
  RunLinkKind kind = 1;
  int64 pull_request = 2;
}

// A pull request with every run linked to it, or a commit with the runs
// that have no link.
message RunChange {
  // "pr:142" or "commit:<sha>".
  string id = 1;
  // Set for a pull request.
  ChangePullRequest pull_request = 2;
  // Of the first section with runs.
  PullRequestCi status = 3;
  google.protobuf.Timestamp latest_at = 4;
  // After merge, then the latest commit; a commit has one section.
  repeated RunChangeSection sections = 5;
  // Runs on older commits of the pull request, newest first.
  repeated int64 older_run_ids = 6;
  uint32 older_commits = 7;
}

message ChangePullRequest {
  int64 number = 1;
  string title = 2;
  // "open", "closed" or "merged"; empty when not read yet.
  string state = 3;
  bool draft = 4;
  string author = 5;
  string html_url = 6;
  string head_branch = 7;
  string base_branch = 8;
  google.protobuf.Timestamp merged_at = 9;
}

enum RunChangeSectionKind {
  RUN_CHANGE_SECTION_KIND_UNSPECIFIED = 0;
  RUN_CHANGE_SECTION_KIND_AFTER_MERGE = 1;
  RUN_CHANGE_SECTION_KIND_LATEST_COMMIT = 2;
  RUN_CHANGE_SECTION_KIND_COMMIT = 3;
}

message RunChangeSection {
  RunChangeSectionKind kind = 1;
  string head_sha = 2;
  string branch = 3;
  string commit_title = 4;
  // The newest run of each workflow and event, newest first.
  repeated int64 run_ids = 5;
  // The other runs of those workflows and events on this commit.
  repeated int64 repeat_run_ids = 6;
}

// A concurrency block would have stopped superseded runs of this workflow.
message ConcurrencyHint {
  int64 workflow_id = 1;
  string path = 2;
  // Superseded runs that kept going after a newer push.
  uint32 runs = 3;
  // How long they kept going, wall-clock, rounded up.
  uint32 overlap_minutes = 4;
  // May include runs outside WorkspaceActivity.runs.
  repeated int64 run_ids = 5;
  repeated int64 pull_requests = 6;
}

message LoadOlderRunsRequest {
  string repository_id = 1;
}

message LoadOlderRunsResponse {
  GitHubStatus status = 1;
  uint32 added = 2;
  bool history_complete = 3;
  // The cache holds 5000 runs; older ones stay on GitHub.
  bool budget_reached = 4;
}

message InsertWorkflowConcurrencyRequest {
  string repository_id = 1;
  // The editor's text, UTF-8, at most 1 MiB.
  string content = 2;
}

enum ConcurrencyRefusal {
  CONCURRENCY_REFUSAL_UNSPECIFIED = 0;
  CONCURRENCY_REFUSAL_NONE = 1;
  CONCURRENCY_REFUSAL_ALREADY_PRESENT = 2;
  CONCURRENCY_REFUSAL_NO_JOBS = 3;
  CONCURRENCY_REFUSAL_NOT_BLOCK_MAPPING = 4;
  CONCURRENCY_REFUSAL_PARSE_ERROR = 5;
  CONCURRENCY_REFUSAL_TOO_LARGE = 6;
}

message InsertWorkflowConcurrencyResponse {
  // The text with the block; empty when refused.
  string content = 1;
  // The block's first and last line, 1-based.
  uint32 first_line = 2;
  uint32 last_line = 3;
  ConcurrencyRefusal refusal = 4;
}
```

- [ ] **Step 2: Regenerate**

Run from the repository root: `PATH="<scratchpad>/bin:$HOME/go/bin:$PATH" scripts/generate-contracts.sh`
Expected: `buf lint` passes; Go and Swift files under `core/internal/gen` and `apps/macos/Runnir/IPC/Generated` change. `go build ./...` from `core/` fails until Step 4 (the server does not implement the new RPCs yet).

- [ ] **Step 3: Write the failing tests**

In the server test that ends with `Limit: 201`, change the limit to `Limit: 5001`.

Append:

```go
// linkingGitHub serves the spec's example: CI on three pushes to #142 that
// kept running after the next push, the merge, CI on the merge commit and
// Deploy started by hand on it.
func linkingGitHub(t *testing.T) *httptest.Server {
	t.Helper()
	runs := `{"workflow_runs":[
		{"id":5,"workflow_id":4,"name":"Deploy","run_number":5,"run_attempt":1,"event":"workflow_dispatch","status":"completed","conclusion":"success","head_branch":"main","head_sha":"m1","created_at":"2026-10-18T11:10:00Z","updated_at":"2026-10-18T11:15:00Z","head_repository":{"full_name":"o/r"}},
		{"id":4,"workflow_id":3,"name":"CI","run_number":4,"run_attempt":1,"event":"push","status":"completed","conclusion":"success","head_branch":"main","head_sha":"m1","created_at":"2026-10-18T11:01:00Z","updated_at":"2026-10-18T11:06:00Z","head_repository":{"full_name":"o/r"}},
		{"id":3,"workflow_id":3,"name":"CI","run_number":3,"run_attempt":1,"event":"pull_request","status":"completed","conclusion":"success","head_branch":"retry","head_sha":"c3","created_at":"2026-10-18T10:20:00Z","updated_at":"2026-10-18T10:25:00Z","head_repository":{"full_name":"o/r"}},
		{"id":2,"workflow_id":3,"name":"CI","run_number":2,"run_attempt":1,"event":"pull_request","status":"completed","conclusion":"success","head_branch":"retry","head_sha":"c2","created_at":"2026-10-18T10:10:00Z","updated_at":"2026-10-18T10:25:00Z","head_repository":{"full_name":"o/r"},"pull_requests":[{"number":142,"base":{"repo":{"url":"https://api.github.com/repos/o/r"}}}]},
		{"id":1,"workflow_id":3,"name":"CI","run_number":1,"run_attempt":1,"event":"pull_request","status":"completed","conclusion":"success","head_branch":"retry","head_sha":"c1","created_at":"2026-10-18T10:01:00Z","updated_at":"2026-10-18T10:20:00Z","head_repository":{"full_name":"o/r"}}]}`
	pulls := `[{"number":142,"title":"Add retry to deploy","state":"closed","user":{"login":"octocat"},"html_url":"https://github.com/o/r/pull/142","head":{"ref":"retry","sha":"c3","repo":{"full_name":"o/r"}},"base":{"ref":"main"},"merge_commit_sha":"m1","created_at":"2026-10-18T10:00:00Z","updated_at":"2026-10-18T11:00:00Z","closed_at":"2026-10-18T11:00:00Z","merged_at":"2026-10-18T11:00:00Z"}]`
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/repos/o/r":
			_, _ = w.Write([]byte(`{"full_name":"o/r","default_branch":"main"}`))
		case r.URL.Path == "/repos/o/r/actions/runs" && r.URL.Query().Get("created") != "":
			_, _ = w.Write([]byte(`{"workflow_runs":[]}`))
		case r.URL.Path == "/repos/o/r/actions/runs":
			_, _ = w.Write([]byte(runs))
		case r.URL.Path == "/repos/o/r/actions/workflows":
			_, _ = w.Write([]byte(`{"total_count":2,"workflows":[{"id":3,"name":"CI","path":".github/workflows/ci.yml","state":"active"},{"id":4,"name":"Deploy","path":".github/workflows/deploy.yml","state":"active"}]}`))
		case r.URL.Path == "/repos/o/r/pulls":
			_, _ = w.Write([]byte(pulls))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)
	return server
}

func TestActivityLinksRunsAndSuggestsConcurrency(t *testing.T) {
	fake := linkingGitHub(t)
	client, stop, ctx := workspaceRig(t, t.TempDir(), fake.URL)
	defer stop()
	repo := linkedRepository(t, "git@github.com:o/r.git")
	workflows := filepath.Join(repo, ".github", "workflows")
	if err := os.MkdirAll(workflows, 0o755); err != nil {
		t.Fatal(err)
	}
	ci := "name: CI\non:\n  pull_request:\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make\n"
	if err := os.WriteFile(filepath.Join(workflows, "ci.yml"), []byte(ci), 0o644); err != nil {
		t.Fatal(err)
	}
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo, WorkspaceId: testWorkspace})
	if err != nil {
		t.Fatal(err)
	}
	id := opened.Repository.Id
	activity, err := client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: id, Wait: true})
	if err != nil || len(activity.Runs) != 5 || activity.CachedRuns != 5 || !activity.HistoryComplete ||
		activity.Freshness.PullRequestsAccess != corev1.GithubAccess_GITHUB_ACCESS_OK {
		t.Fatalf("activity = %v, %v", activity, err)
	}
	runs := map[int64]*corev1.WorkflowRun{}
	for _, run := range activity.Runs {
		runs[run.Id] = run
	}
	if runs[4].GetLink().GetKind() != corev1.RunLinkKind_RUN_LINK_KIND_AFTER_MERGE || runs[1].GetLink().GetPullRequest() != 142 ||
		runs[1].SupersededBy != 3 || runs[2].SupersededBy != 3 || runs[3].SupersededBy != 0 || runs[3].HeadRepository != "o/r" {
		t.Fatalf("runs = %v", activity.Runs)
	}
	if len(activity.Changes) != 1 {
		t.Fatalf("changes = %v", activity.Changes)
	}
	change := activity.Changes[0]
	if change.Id != "pr:142" || change.PullRequest.GetState() != "merged" || change.Status != corev1.PullRequestCi_PULL_REQUEST_CI_PASSED ||
		len(change.Sections) != 2 || change.Sections[0].Kind != corev1.RunChangeSectionKind_RUN_CHANGE_SECTION_KIND_AFTER_MERGE ||
		len(change.OlderRunIds) != 2 || change.OlderCommits != 2 {
		t.Fatalf("change = %v", change)
	}
	if len(activity.ConcurrencyHints) != 1 || activity.ConcurrencyHints[0].Path != ".github/workflows/ci.yml" ||
		activity.ConcurrencyHints[0].Runs != 2 || activity.ConcurrencyHints[0].OverlapMinutes != 15 {
		t.Fatalf("hints = %v", activity.ConcurrencyHints)
	}
	workflowList, _ := client.ListWorkflows(ctx, &corev1.ListWorkflowsRequest{RepositoryId: id})
	if len(workflowList.Workflows) != 1 || workflowList.Workflows[0].Concurrency {
		t.Fatalf("workflows = %v", workflowList.Workflows)
	}
	older, err := client.LoadOlderRuns(ctx, &corev1.LoadOlderRunsRequest{RepositoryId: id})
	if err != nil || !older.HistoryComplete || older.Added != 0 || older.Status.GetAccess() != corev1.GithubAccess_GITHUB_ACCESS_OK {
		t.Fatalf("older = %v, %v", older, err)
	}
}

func TestInsertWorkflowConcurrencyOnlyChangesTheText(t *testing.T) {
	client, stop, ctx := workspaceRig(t, "", "http://127.0.0.1:1")
	defer stop()
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.com:o/r.git")})
	if err != nil {
		t.Fatal(err)
	}
	text := "on: push\njobs:\n  a:\n    runs-on: x\n"
	answer, err := client.InsertWorkflowConcurrency(ctx, &corev1.InsertWorkflowConcurrencyRequest{RepositoryId: opened.Repository.Id, Content: text})
	if err != nil || answer.Refusal != corev1.ConcurrencyRefusal_CONCURRENCY_REFUSAL_NONE || answer.FirstLine != 3 || answer.LastLine != 6 ||
		!strings.Contains(answer.Content, "cancel-in-progress: true") {
		t.Fatalf("answer = %v, %v", answer, err)
	}
	again, _ := client.InsertWorkflowConcurrency(ctx, &corev1.InsertWorkflowConcurrencyRequest{RepositoryId: opened.Repository.Id, Content: answer.Content})
	if again.Refusal != corev1.ConcurrencyRefusal_CONCURRENCY_REFUSAL_ALREADY_PRESENT || again.Content != "" {
		t.Fatalf("again = %v", again)
	}
	if _, err := client.InsertWorkflowConcurrency(ctx, &corev1.InsertWorkflowConcurrencyRequest{RepositoryId: "nope", Content: text}); status.Code(err) != codes.NotFound {
		t.Fatalf("unknown repository = %v", err)
	}
}
```

Add `"os"`, `"path/filepath"` and `"strings"` to the test file's imports if missing.

- [ ] **Step 4: Implement the server**

In `core/internal/server/workspace.go`:

```go
const defaultActivityRuns = 200

func activityLimit(limit uint32) (int, error) {
	switch {
	case limit == 0:
		return defaultActivityRuns, nil
	case int(limit) > store.MaxRuns:
		return 0, status.Errorf(codes.InvalidArgument, "limit must be %d or less", store.MaxRuns)
	default:
		return int(limit), nil
	}
}
```

(remove `maxActivityRuns`). In `GetWorkspaceActivity` and `RefreshWorkspaceActivity`, call `return s.snapshotMessage(ctx, rt, limit, request.GetRepositoryId())`, and replace `snapshotMessage`:

```go
func (s *service) snapshotMessage(ctx context.Context, rt *workspace.Runtime, limit int, repositoryID string) (*corev1.WorkspaceActivity, error) {
	snap, err := rt.Snapshot(ctx, limit)
	if err != nil {
		if ctx.Err() != nil {
			return nil, status.FromContextError(ctx.Err()).Err()
		}
		return nil, status.Error(codes.Internal, "the workspace's activity could not be read")
	}
	freshness := &corev1.ActivityFreshness{
		Source: activitySource(snap.Provenance), Syncing: snap.Syncing,
		CheckedAt: timestamp(snap.CheckedAt), SyncedAt: timestamp(snap.SyncedAt), ChangedAt: timestamp(snap.ChangedAt),
		PullRequestsAccess: snap.PullRequestsAccess,
	}
	if snap.Access != corev1.GithubAccess_GITHUB_ACCESS_UNSPECIFIED {
		freshness.Status = statusMessage(snap.Access, snap.RetryAfter)
	}
	out := &corev1.WorkspaceActivity{Freshness: freshness, CachedRuns: uint32(snap.CachedRuns), HistoryComplete: snap.HistoryComplete}
	for _, r := range snap.Runs {
		message := runMessage(r)
		message.Link = linkMessage(snap.Analysis.Links[r.ID])
		message.SupersededBy = snap.Analysis.SupersededBy[r.ID]
		out.Runs = append(out.Runs, message)
	}
	for _, w := range snap.Workflows {
		out.Workflows = append(out.Workflows, &corev1.GitHubWorkflow{Id: w.ID, Name: w.Name, Path: w.Path, State: w.State, HtmlUrl: w.HTMLURL})
	}
	out.Changes = changeMessages(snap.Changes)
	out.ConcurrencyHints = hintMessages(changes.Hints(snap.Analysis, snap.Workflows, s.localWorkflows(repositoryID)))
	return out, nil
}
```

Add `"runnir/core/internal/changes"` to its imports.

Create `core/internal/server/changes.go`:

```go
package server

import (
	"context"
	"errors"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"runnir/core/internal/changes"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/scanner"
	"runnir/core/internal/workspace"
)

func linkMessage(link changes.Link) *corev1.RunLink {
	kind := corev1.RunLinkKind_RUN_LINK_KIND_NONE
	switch link.Kind {
	case changes.LinkPullRequest:
		kind = corev1.RunLinkKind_RUN_LINK_KIND_PULL_REQUEST
	case changes.LinkAfterMerge:
		kind = corev1.RunLinkKind_RUN_LINK_KIND_AFTER_MERGE
	}
	return &corev1.RunLink{Kind: kind, PullRequest: link.PullRequest}
}

func changeMessages(list []changes.Change) []*corev1.RunChange {
	out := make([]*corev1.RunChange, 0, len(list))
	for _, c := range list {
		message := &corev1.RunChange{Id: c.ID, Status: pullRequestCI(c.Status), LatestAt: timestamp(c.LatestAt),
			OlderRunIds: c.OlderRunIDs, OlderCommits: uint32(c.OlderCommits)}
		if p := c.PullRequest; p != nil {
			message.PullRequest = &corev1.ChangePullRequest{Number: p.Number, Title: p.Title, State: p.State, Draft: p.Draft,
				Author: p.Author, HtmlUrl: p.HTMLURL, HeadBranch: p.HeadBranch, BaseBranch: p.BaseBranch, MergedAt: timestamp(p.MergedAt)}
		}
		for _, s := range c.Sections {
			message.Sections = append(message.Sections, &corev1.RunChangeSection{Kind: sectionKind(s.Kind), HeadSha: s.HeadSHA,
				Branch: s.Branch, CommitTitle: s.CommitTitle, RunIds: s.RunIDs, RepeatRunIds: s.RepeatRunIDs})
		}
		out = append(out, message)
	}
	return out
}

func sectionKind(kind changes.SectionKind) corev1.RunChangeSectionKind {
	switch kind {
	case changes.SectionAfterMerge:
		return corev1.RunChangeSectionKind_RUN_CHANGE_SECTION_KIND_AFTER_MERGE
	case changes.SectionLatestCommit:
		return corev1.RunChangeSectionKind_RUN_CHANGE_SECTION_KIND_LATEST_COMMIT
	default:
		return corev1.RunChangeSectionKind_RUN_CHANGE_SECTION_KIND_COMMIT
	}
}

func hintMessages(hints []changes.Hint) []*corev1.ConcurrencyHint {
	out := make([]*corev1.ConcurrencyHint, 0, len(hints))
	for _, h := range hints {
		out = append(out, &corev1.ConcurrencyHint{WorkflowId: h.WorkflowID, Path: h.Path, Runs: uint32(h.Runs),
			OverlapMinutes: uint32(h.OverlapMinutes), RunIds: h.RunIDs, PullRequests: h.PullRequests})
	}
	return out
}

// localWorkflows are the working tree's workflow files as last scanned;
// none when the repository is not open.
func (s *service) localWorkflows(repositoryID string) []changes.LocalWorkflow {
	workflows, err := s.repositories.Workflows(repositoryID)
	if err != nil {
		return nil
	}
	out := make([]changes.LocalWorkflow, 0, len(workflows))
	for _, w := range workflows {
		out = append(out, changes.LocalWorkflow{Path: w.ID, Triggers: w.Triggers, Concurrency: w.Concurrency, ParseError: w.ParseError})
	}
	return out
}

func (s *service) LoadOlderRuns(ctx context.Context, request *corev1.LoadOlderRunsRequest) (*corev1.LoadOlderRunsResponse, error) {
	rt, err := s.runtimeFor(request.GetRepositoryId())
	if err != nil {
		return nil, err
	}
	result, err := rt.LoadOlderRuns(ctx)
	switch {
	case errors.Is(err, workspace.ErrClosed):
		return nil, status.Error(codes.NotFound, "repository not found")
	case ctx.Err() != nil:
		return nil, status.FromContextError(ctx.Err()).Err()
	case err != nil:
		return nil, status.Error(codes.Internal, "older runs could not be stored")
	}
	return &corev1.LoadOlderRunsResponse{Status: statusMessage(result.Access, result.RetryAfter), Added: uint32(result.Added),
		HistoryComplete: result.HistoryComplete, BudgetReached: result.BudgetReached}, nil
}

func (s *service) InsertWorkflowConcurrency(_ context.Context, request *corev1.InsertWorkflowConcurrencyRequest) (*corev1.InsertWorkflowConcurrencyResponse, error) {
	if _, err := s.repositories.Get(request.GetRepositoryId()); err != nil {
		return nil, rpcError(err)
	}
	edit := scanner.InsertConcurrency(request.GetContent())
	out := &corev1.InsertWorkflowConcurrencyResponse{Refusal: concurrencyRefusal(edit.Refusal)}
	if edit.Refusal == scanner.ConcurrencyInserted {
		out.Content, out.FirstLine, out.LastLine = edit.Content, uint32(edit.FirstLine), uint32(edit.LastLine)
	}
	return out, nil
}

func concurrencyRefusal(refusal scanner.ConcurrencyRefusal) corev1.ConcurrencyRefusal {
	switch refusal {
	case scanner.ConcurrencyAlreadyPresent:
		return corev1.ConcurrencyRefusal_CONCURRENCY_REFUSAL_ALREADY_PRESENT
	case scanner.ConcurrencyNoJobs:
		return corev1.ConcurrencyRefusal_CONCURRENCY_REFUSAL_NO_JOBS
	case scanner.ConcurrencyNotBlockMapping:
		return corev1.ConcurrencyRefusal_CONCURRENCY_REFUSAL_NOT_BLOCK_MAPPING
	case scanner.ConcurrencyParseError:
		return corev1.ConcurrencyRefusal_CONCURRENCY_REFUSAL_PARSE_ERROR
	case scanner.ConcurrencyTooLarge:
		return corev1.ConcurrencyRefusal_CONCURRENCY_REFUSAL_TOO_LARGE
	default:
		return corev1.ConcurrencyRefusal_CONCURRENCY_REFUSAL_NONE
	}
}
```

In `core/internal/server/service.go` `ListWorkflows`, set the new field:

```go
		item := &corev1.Workflow{Id: w.ID, Name: w.Name, Triggers: w.Triggers, ParseError: w.ParseError, Concurrency: w.Concurrency}
```

- [ ] **Step 5: Run the Core checks**

Run from `core/`: `go test ./... && go vet ./... && CGO_ENABLED=0 go build ./...`
Expected: PASS. (The Swift app does not build yet: `GRPCCoreService` does not implement the new methods until Task 11.)

- [ ] **Step 6: Commit**

```bash
git add contracts/grpc core/internal/gen apps/macos/Runnir/IPC/Generated core/internal/server
git commit -m "Contract: links, changes, concurrency hints, older runs and concurrency insertion"
```

---

### Task 11: Swift models, the gRPC service and CoreHub

**Files:**
- Modify: `apps/macos/Runnir/IPC/CoreGitHubModels.swift:256-281` (`CoreWorkflowRun`)
- Modify: `apps/macos/Runnir/IPC/CoreWorkspaceModels.swift`
- Modify: `apps/macos/Runnir/IPC/CoreService.swift:35-41` (`CoreWorkflow`), `:130-` (`CoreServicing`)
- Modify: `apps/macos/Runnir/IPC/GRPCCoreService.swift`
- Modify: `apps/macos/Runnir/IPC/CoreHub.swift` (`RepositorySession`, activity section)
- Test: `apps/macos/RunnirTests/CoreHubTests.swift` (`FakeCore`), `apps/macos/RunnirTests/CoreProcessSupervisorTests.swift` (`FakeService`), `apps/macos/RunnirTests/WorkspaceCacheTests.swift`, create `apps/macos/RunnirTests/RunLinkMappingTests.swift`

**Interfaces:**
- Consumes: the generated `Runnir_Core_V1_*` types (Task 10).
- Produces:

```swift
enum CoreRunLink: Equatable, Sendable { case none, pullRequest(Int64), afterMerge(Int64); var pullRequest: Int64? }
// CoreWorkflowRun gains: var headRepository = "", var commitTitle = "", var link: CoreRunLink = .none,
//   var supersededBy: Int64?, var isSuperseded: Bool, var isOutdated: Bool
struct CoreChangePullRequest  // number, title, state, draft, author, htmlURL, headBranch, baseBranch, mergedAt
enum CoreRunChangeSectionKind { case afterMerge, latestCommit, commit }
struct CoreRunChangeSection   // kind, headSHA, branch, commitTitle, runIDs, repeatRunIDs
struct CoreRunChange: Identifiable // id, pullRequest, status: CorePullRequestCI, latestAt, sections, olderRunIDs, olderCommits
struct CoreConcurrencyHint    // workflowID, path, runs, overlapMinutes, runIDs, pullRequests
struct CoreOlderRuns          // access, added, historyComplete, budgetReached
enum CoreConcurrencyRefusal { case alreadyPresent, noJobs, notBlockMapping, parseError, tooLarge; var message: String }
enum CoreConcurrencyInsertion { case inserted(content: String, firstLine: Int, lastLine: Int), refused(CoreConcurrencyRefusal) }
// CoreActivityFreshness gains: var pullRequestsAccess: CoreGitHubAccess?
// CoreWorkspaceActivity gains: var changes, concurrencyHints, cachedRuns, historyComplete
// CoreWorkflow gains: var concurrency = false
// CoreServicing gains:
func loadOlderRuns(repositoryID: String) async throws -> CoreOlderRuns
func insertWorkflowConcurrency(repositoryID: String, content: String) async throws -> CoreConcurrencyInsertion
// RepositorySession gains: changes, concurrencyHints, cachedRuns, historyComplete, activityLimit, olderRuns: OlderRunsState
enum OlderRunsState: Equatable { case idle, loading, failed(CoreGitHubAccess), budgetReached }
// CoreHub gains:
static let activityPage = 200, static let maxActivityLimit = 5000   // replaces activityLimit = 50
func showMoreRuns(workspaceID: UUID) async
func insertWorkflowConcurrency(workspaceID: UUID, content: String) async -> CoreConcurrencyInsertion?
func pullRequestsHelp(workspaceID: UUID) -> GitHubAccessHelp?   // uses GitHubAccessHelp.pullRequestsUnreadable from Task 12
```

`pullRequestsHelp` calls `GitHubAccessHelp.pullRequestsUnreadable`, which Task 12 adds; implement Task 12's Step 3 part for `GitHubAccessHelp` first if you run the tasks out of order.

- [ ] **Step 1: Write the failing tests**

Create `apps/macos/RunnirTests/RunLinkMappingTests.swift`:

```swift
import Foundation
import Testing
@testable import Runnir

@Suite struct RunLinkMappingTests {
    @Test func activityCarriesLinksChangesAndHints() throws {
        let message = Runnir_Core_V1_WorkspaceActivity.with {
            $0.runs = [
                .with {
                    $0.id = 4; $0.name = "CI"; $0.headSha = "m1"; $0.headRepository = "o/r"; $0.commitTitle = "Merge #142"
                    $0.link = .with { $0.kind = .afterMerge; $0.pullRequest = 142 }
                },
                .with { $0.id = 1; $0.name = "CI"; $0.supersededBy = 3; $0.link = .with { $0.kind = .pullRequest; $0.pullRequest = 142 } },
                .with { $0.id = 9; $0.name = "Nightly" },
            ]
            $0.changes = [.with {
                $0.id = "pr:142"
                $0.status = .passed
                $0.pullRequest = .with { $0.number = 142; $0.title = "Add retry"; $0.state = "merged"; $0.htmlURL = "https://github.com/o/r/pull/142" }
                $0.sections = [.with { $0.kind = .afterMerge; $0.headSha = "m1"; $0.branch = "main"; $0.runIds = [4] }]
                $0.olderRunIds = [1]
                $0.olderCommits = 1
            }]
            $0.concurrencyHints = [.with { $0.workflowID = 3; $0.path = ".github/workflows/ci.yml"; $0.runs = 2; $0.overlapMinutes = 15; $0.runIds = [1, 2] }]
            $0.cachedRuns = 250
            $0.historyComplete = true
            $0.freshness = .with { $0.source = .live; $0.pullRequestsAccess = .permissionMissing }
        }
        let activity = GRPCCoreService.map(message)
        #expect(activity.runs[0].link == .afterMerge(142) && activity.runs[0].headRepository == "o/r" && activity.runs[0].commitTitle == "Merge #142")
        #expect(activity.runs[1].supersededBy == 3 && activity.runs[1].isSuperseded && activity.runs[1].link.pullRequest == 142)
        #expect(activity.runs[2].link == .none && activity.runs[2].supersededBy == nil)
        let change = try #require(activity.changes.first)
        #expect(change.id == "pr:142" && change.status == .passed && change.pullRequest?.state == "merged")
        #expect(change.pullRequest?.htmlURL?.absoluteString == "https://github.com/o/r/pull/142")
        #expect(change.sections == [CoreRunChangeSection(kind: .afterMerge, headSHA: "m1", branch: "main", commitTitle: "", runIDs: [4], repeatRunIDs: [])])
        #expect(change.olderRunIDs == [1] && change.olderCommits == 1)
        #expect(activity.concurrencyHints == [CoreConcurrencyHint(workflowID: 3, path: ".github/workflows/ci.yml", runs: 2, overlapMinutes: 15, runIDs: [1, 2], pullRequests: [])])
        #expect(activity.cachedRuns == 250 && activity.historyComplete)
        #expect(activity.freshness.pullRequestsAccess == .permissionMissing)
    }

    @Test func insertionAnswersMapToEditsOrReasons() {
        let inserted = GRPCCoreService.map(Runnir_Core_V1_InsertWorkflowConcurrencyResponse.with {
            $0.refusal = .none; $0.content = "x"; $0.firstLine = 3; $0.lastLine = 6
        })
        #expect(inserted == .inserted(content: "x", firstLine: 3, lastLine: 6))
        #expect(GRPCCoreService.map(Runnir_Core_V1_InsertWorkflowConcurrencyResponse.with { $0.refusal = .alreadyPresent }) == .refused(.alreadyPresent))
    }
}
```

In `apps/macos/RunnirTests/WorkspaceCacheTests.swift`, add to `CacheFirstHubTests`:

```swift
    @Test func moreRunsComeFromTheCacheThenFromGitHub() async {
        let (hub, provider) = await readyHub()
        let runs = (1...200).map { run(Int64($0)) }
        let fresh = CoreActivityFreshness(source: .live, access: .ok)
        provider.core.setActivity(CoreWorkspaceActivity(runs: runs, workflows: [], freshness: fresh, cachedRuns: 250), for: "/repo/linked")
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.cachedRuns == 250 })
        #expect(provider.core.activityLimits.allSatisfy { $0 == 200 })
        // 250 are cached: the next read asks for 400, and nothing goes to GitHub.
        await hub.showMoreRuns(workspaceID: workspace)
        #expect(provider.core.activityLimits.last == 400)
        #expect(provider.core.olderRunsCalls.isEmpty)
        // Every cached run is shown and GitHub has older ones: one page from GitHub.
        provider.core.setActivity(CoreWorkspaceActivity(runs: runs, workflows: [], freshness: fresh, cachedRuns: 200), for: "/repo/linked")
        provider.core.olderRunsResult = CoreOlderRuns(access: .ok, added: 100, historyComplete: false, budgetReached: false)
        await hub.showMoreRuns(workspaceID: workspace) // reads again from the cache: 200 cached
        await hub.showMoreRuns(workspaceID: workspace)
        #expect(provider.core.olderRunsCalls.count == 1)
        #expect(hub.session(for: workspace)?.olderRuns == .idle)
    }

    @Test func olderRunsSayWhenGitHubFailsAndWhenTheBudgetIsReached() async {
        let (hub, provider) = await readyHub()
        provider.core.setActivity(CoreWorkspaceActivity(runs: [run(1)], workflows: [], freshness: CoreActivityFreshness(source: .live, access: .ok),
                                                        cachedRuns: 1), for: "/repo/linked")
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.runs.count == 1 })
        provider.core.olderRunsResult = CoreOlderRuns(access: .unavailable, added: 0, historyComplete: false, budgetReached: false)
        await hub.showMoreRuns(workspaceID: workspace)
        #expect(hub.session(for: workspace)?.olderRuns == .failed(.unavailable))
        provider.core.olderRunsResult = CoreOlderRuns(access: .ok, added: 0, historyComplete: false, budgetReached: true)
        await hub.showMoreRuns(workspaceID: workspace) // Retry
        #expect(hub.session(for: workspace)?.olderRuns == .budgetReached)
        await hub.showMoreRuns(workspaceID: workspace)
        #expect(provider.core.olderRunsCalls.count == 2, "nothing more is asked once the budget is reached")
    }
```

- [ ] **Step 2: Add the models**

In `CoreGitHubModels.swift`, before `struct CoreWorkflowRun`:

```swift
/// What a run belongs to, as the Core linked it.
enum CoreRunLink: Equatable, Sendable {
    case none
    /// Ran on a commit of the pull request, before its merge.
    case pullRequest(Int64)
    /// Ran on the commit the pull request's merge created.
    case afterMerge(Int64)

    var pullRequest: Int64? {
        switch self {
        case .none: nil
        case .pullRequest(let number), .afterMerge(let number): number
        }
    }
}
```

and in `CoreWorkflowRun`, after `var runAttempt: Int64 = 1`:

```swift
    /// "owner/name" the head commit came from; a fork's differs.
    var headRepository = ""
    /// The first line of the head commit's message.
    var commitTitle = ""
    var link: CoreRunLink = .none
    /// The newest run of the same workflow on a newer commit of the pull
    /// request; nil when this run is not superseded.
    var supersededBy: Int64?

    var isSuperseded: Bool { supersededBy != nil }
    /// Superseded and still going: it uses runners for a commit the pull
    /// request has moved past.
    var isOutdated: Bool { isSuperseded && outcome.isActive }
```

In `CoreWorkspaceModels.swift`, add `var pullRequestsAccess: CoreGitHubAccess?` at the end of `CoreActivityFreshness` (with the comment `/// Reading pull requests: nil before a read, else .ok or why not.`), and replace `CoreWorkspaceActivity`:

```swift
/// A workspace's GitHub activity as saved by the Core.
struct CoreWorkspaceActivity: Equatable, Sendable {
    var runs: [CoreWorkflowRun]
    var workflows: [CoreGitHubWorkflow]
    var freshness: CoreActivityFreshness
    /// The changes of `runs`, newest first.
    var changes: [CoreRunChange] = []
    var concurrencyHints: [CoreConcurrencyHint] = []
    /// Every run the Core keeps for the workspace.
    var cachedRuns = 0
    /// GitHub has no run older than the oldest kept.
    var historyComplete = false
}

/// What a change shows of its pull request.
struct CoreChangePullRequest: Equatable, Sendable {
    let number: Int64
    let title: String
    /// "open", "closed" or "merged"; empty when the Core has not read it yet.
    let state: String
    let draft: Bool
    let author: String
    let htmlURL: URL?
    let headBranch: String
    let baseBranch: String
    let mergedAt: Date?
}

enum CoreRunChangeSectionKind: Equatable, Sendable { case afterMerge, latestCommit, commit }

/// A change's runs on one commit.
struct CoreRunChangeSection: Equatable, Sendable {
    let kind: CoreRunChangeSectionKind
    let headSHA: String
    let branch: String
    let commitTitle: String
    /// The newest run of each workflow and event, newest first.
    let runIDs: [Int64]
    /// The other runs of those workflows and events on this commit.
    let repeatRunIDs: [Int64]
}

/// A pull request with every run linked to it, or a commit with the runs
/// that have no link.
struct CoreRunChange: Equatable, Identifiable, Sendable {
    /// "pr:142" or "commit:<sha>".
    let id: String
    let pullRequest: CoreChangePullRequest?
    let status: CorePullRequestCI
    let latestAt: Date?
    let sections: [CoreRunChangeSection]
    let olderRunIDs: [Int64]
    let olderCommits: Int
}

/// A concurrency block would have stopped superseded runs of a workflow.
struct CoreConcurrencyHint: Equatable, Sendable {
    let workflowID: Int64
    let path: String
    let runs: Int
    let overlapMinutes: Int
    let runIDs: [Int64]
    let pullRequests: [Int64]
}

/// What a request for older runs did.
struct CoreOlderRuns: Equatable, Sendable {
    let access: CoreGitHubAccess
    let added: Int
    let historyComplete: Bool
    let budgetReached: Bool
}

/// Why the Core did not add the concurrency block.
enum CoreConcurrencyRefusal: Equatable, Sendable {
    case alreadyPresent, noJobs, notBlockMapping, parseError, tooLarge

    var message: String {
        switch self {
        case .alreadyPresent: "This workflow already has a concurrency setting, so nothing was added."
        case .noJobs: "This workflow has no jobs key, so there is nowhere to add the block."
        case .notBlockMapping: "Runnir adds the block only to a workflow written as a plain YAML mapping. Add it by hand."
        case .parseError: "This workflow can't be read as YAML. Fix it first, then try again."
        case .tooLarge: "This workflow file is larger than 1 MiB."
        }
    }
}

enum CoreConcurrencyInsertion: Equatable, Sendable {
    case inserted(content: String, firstLine: Int, lastLine: Int)
    case refused(CoreConcurrencyRefusal)
}
```

In `CoreService.swift`, add `var concurrency = false` (with `/// The file sets concurrency at the top level or in a job.`) at the end of `CoreWorkflow`, and to `CoreServicing` after `refreshWorkspaceActivity`:

```swift
    /// Reads one page of older runs from GitHub into the workspace's cache.
    func loadOlderRuns(repositoryID: String) async throws -> CoreOlderRuns
```

and after `renameWorkflowFile`:

```swift
    /// The editor's text with the suggested concurrency block, or why not;
    /// nothing is written.
    func insertWorkflowConcurrency(repositoryID: String, content: String) async throws -> CoreConcurrencyInsertion
```

- [ ] **Step 3: Map in `GRPCCoreService.swift`**

Add the methods after `refreshWorkspaceActivity`:

```swift
    func loadOlderRuns(repositoryID: String) async throws -> CoreOlderRuns {
        let response = try await call {
            try await client.loadOlderRuns(.with { $0.repositoryID = repositoryID }, options: Self.options(.seconds(60)))
        }
        return CoreOlderRuns(access: Self.map(response.status), added: Int(response.added),
                             historyComplete: response.historyComplete, budgetReached: response.budgetReached)
    }

    func insertWorkflowConcurrency(repositoryID: String, content: String) async throws -> CoreConcurrencyInsertion {
        let response = try await call {
            try await client.insertWorkflowConcurrency(.with {
                $0.repositoryID = repositoryID
                $0.content = content
            }, options: Self.options(Self.callTimeout))
        }
        return Self.map(response)
    }

    static func map(_ response: Runnir_Core_V1_InsertWorkflowConcurrencyResponse) -> CoreConcurrencyInsertion {
        switch response.refusal {
        case .alreadyPresent: .refused(.alreadyPresent)
        case .noJobs: .refused(.noJobs)
        case .notBlockMapping: .refused(.notBlockMapping)
        case .parseError: .refused(.parseError)
        case .tooLarge: .refused(.tooLarge)
        default: .inserted(content: response.content, firstLine: Int(response.firstLine), lastLine: Int(response.lastLine))
        }
    }
```

Replace `static func map(_ activity: Runnir_Core_V1_WorkspaceActivity)`:

```swift
    static func map(_ activity: Runnir_Core_V1_WorkspaceActivity) -> CoreWorkspaceActivity {
        let f = activity.freshness
        let source: CoreActivitySource = switch f.source {
        case .cache: .cache
        case .live: .live
        default: .none
        }
        let pullRequestsAccess: CoreGitHubAccess? = f.pullRequestsAccess == .unspecified
            ? nil : map(Runnir_Core_V1_GitHubStatus.with { $0.access = f.pullRequestsAccess })
        return CoreWorkspaceActivity(
            runs: activity.runs.map(map), workflows: activity.workflows.map(map),
            freshness: CoreActivityFreshness(
                source: source, syncing: f.syncing, access: f.hasStatus ? map(f.status) : nil,
                checkedAt: f.hasCheckedAt ? f.checkedAt.date : nil, syncedAt: f.hasSyncedAt ? f.syncedAt.date : nil,
                changedAt: f.hasChangedAt ? f.changedAt.date : nil, pullRequestsAccess: pullRequestsAccess),
            changes: activity.changes.map(map), concurrencyHints: activity.concurrencyHints.map(map),
            cachedRuns: Int(activity.cachedRuns), historyComplete: activity.historyComplete)
    }

    static func map(_ change: Runnir_Core_V1_RunChange) -> CoreRunChange {
        CoreRunChange(id: change.id, pullRequest: change.hasPullRequest ? map(change.pullRequest) : nil, status: map(change.status),
                      latestAt: change.hasLatestAt ? change.latestAt.date : nil, sections: change.sections.map(map),
                      olderRunIDs: change.olderRunIds, olderCommits: Int(change.olderCommits))
    }

    static func map(_ pullRequest: Runnir_Core_V1_ChangePullRequest) -> CoreChangePullRequest {
        CoreChangePullRequest(number: pullRequest.number, title: pullRequest.title, state: pullRequest.state, draft: pullRequest.draft,
                              author: pullRequest.author, htmlURL: webURL(pullRequest.htmlURL), headBranch: pullRequest.headBranch,
                              baseBranch: pullRequest.baseBranch, mergedAt: pullRequest.hasMergedAt ? pullRequest.mergedAt.date : nil)
    }

    static func map(_ section: Runnir_Core_V1_RunChangeSection) -> CoreRunChangeSection {
        let kind: CoreRunChangeSectionKind = switch section.kind {
        case .afterMerge: .afterMerge
        case .latestCommit: .latestCommit
        default: .commit
        }
        return CoreRunChangeSection(kind: kind, headSHA: section.headSha, branch: section.branch, commitTitle: section.commitTitle,
                                    runIDs: section.runIds, repeatRunIDs: section.repeatRunIds)
    }

    static func map(_ hint: Runnir_Core_V1_ConcurrencyHint) -> CoreConcurrencyHint {
        CoreConcurrencyHint(workflowID: hint.workflowID, path: hint.path, runs: Int(hint.runs), overlapMinutes: Int(hint.overlapMinutes),
                            runIDs: hint.runIds, pullRequests: hint.pullRequests)
    }

    static func map(_ link: Runnir_Core_V1_RunLink) -> CoreRunLink {
        switch link.kind {
        case .pullRequest: .pullRequest(link.pullRequest)
        case .afterMerge: .afterMerge(link.pullRequest)
        default: .none
        }
    }

    static func map(_ ci: Runnir_Core_V1_PullRequestCi) -> CorePullRequestCI {
        switch ci {
        case .none: .none
        case .running: .running
        case .passed: .passed
        case .failed: .failed
        case .cancelled: .cancelled
        default: .unknown
        }
    }
```

In `listPullRequests`, replace the local `let ci: CorePullRequestCI = switch pr.ci { … }` with `let ci = Self.map(pr.ci)`. Replace `static func map(_ run: Runnir_Core_V1_WorkflowRun)`:

```swift
    static func map(_ run: Runnir_Core_V1_WorkflowRun) -> CoreWorkflowRun {
        CoreWorkflowRun(
            id: run.id, workflowID: run.workflowID, name: run.name, displayTitle: run.displayTitle,
            runNumber: run.runNumber, event: run.event, status: run.status,
            conclusion: run.conclusion.isEmpty ? nil : run.conclusion, branch: run.branch, headSHA: run.headSha,
            actor: run.actor.isEmpty ? nil : run.actor, htmlURL: Self.webURL(run.htmlURL),
            createdAt: run.hasCreatedAt ? run.createdAt.date : nil,
            updatedAt: run.hasUpdatedAt ? run.updatedAt.date : nil,
            runAttempt: max(1, run.runAttempt),
            headRepository: run.headRepository, commitTitle: run.commitTitle,
            link: run.hasLink ? Self.map(run.link) : .none,
            supersededBy: run.supersededBy == 0 ? nil : run.supersededBy
        )
    }
```

In `listWorkflows`, pass `concurrency: workflow.concurrency` as the last argument of `CoreWorkflow(…)`.

- [ ] **Step 4: CoreHub and the fakes**

In `CoreHub.swift`, before `final class RepositorySession`:

```swift
/// Loading runs older than the cached ones, as the run list's end shows it.
enum OlderRunsState: Equatable {
    case idle
    case loading
    /// GitHub did not answer; Retry asks again.
    case failed(CoreGitHubAccess)
    /// The Core keeps 5000 runs; older ones are on GitHub.
    case budgetReached
}
```

Add to `RepositorySession`, after `freshness`:

```swift
    /// The changes of `runs` and the concurrency suggestions, as the Core
    /// grouped them.
    fileprivate(set) var changes: [CoreRunChange] = []
    fileprivate(set) var concurrencyHints: [CoreConcurrencyHint] = []
    /// Every run the Core keeps, and whether GitHub has none older.
    fileprivate(set) var cachedRuns = 0
    fileprivate(set) var historyComplete = false
    /// How many of the newest runs the session reads; grows as lists scroll.
    fileprivate(set) var activityLimit = CoreHub.activityPage
    fileprivate(set) var olderRuns: OlderRunsState = .idle
```

Replace `static let activityLimit = 50` with:

```swift
    /// How many runs a session reads at first, and how many more each time
    /// a list reaches its end.
    static let activityPage = 200
    /// The Core keeps at most this many runs per workspace.
    static let maxActivityLimit = 5000
```

In `loadGitHubActivity` and `readActivity`, replace `limit: Self.activityLimit` with `limit: session.activityLimit`. Replace `apply(_:to:)`:

```swift
    private func apply(_ activity: CoreWorkspaceActivity, to session: RepositorySession) async {
        let previous = session.freshness.access
        let previousPullRequests = session.freshness.pullRequestsAccess
        session.runs = activity.runs
        session.remoteWorkflows = activity.workflows
        session.freshness = activity.freshness
        session.changes = activity.changes
        session.concurrencyHints = activity.concurrencyHints
        session.cachedRuns = activity.cachedRuns
        session.historyComplete = activity.historyComplete
        // Whether an owner has to accept the pull request permission decides
        // what the note asks for.
        if activity.freshness.pullRequestsAccess == .permissionMissing, previousPullRequests != .permissionMissing {
            await githubRepository(workspaceID: session.workspaceID)
        }
        let access = activity.freshness.access
        guard access != previous else { return }
        // Only a rejection of the token the Core holds now signs out: one
        // checked before the last hand-over was about an earlier token.
        if access == .tokenRejected, (activity.freshness.checkedAt ?? .distantPast) >= (credentialPushedAt ?? .distantPast) {
            await tokenRejected(on: .workspace(session.workspaceID))
        }
        // Whether an owner has to accept permissions, or the user lacks
        // access, decides what the notice asks for.
        if access == .permissionMissing { await githubRepository(workspaceID: session.workspaceID) }
    }
```

Add after `apply`:

```swift
    /// Shows more runs when a list reaches its end: 200 more from the cache,
    /// or, once every cached run is shown, one page of older runs from GitHub.
    func showMoreRuns(workspaceID: UUID) async {
        guard let session = sessions[workspaceID], session.olderRuns != .loading else { return }
        if session.cachedRuns > session.runs.count {
            session.activityLimit = min(Self.maxActivityLimit, session.activityLimit + Self.activityPage)
            await readActivity(of: session)
            return
        }
        guard !session.historyComplete, session.olderRuns != .budgetReached, session.githubAccess == .ok,
              let coreID = session.coreID, isReady, let service = try? await provider.service() else { return }
        session.olderRuns = .loading
        let result = try? await service.loadOlderRuns(repositoryID: coreID)
        guard sessions[workspaceID] === session else { return }
        switch result {
        case nil:
            session.olderRuns = .failed(.unavailable)
        case let result? where result.budgetReached && result.added == 0:
            session.olderRuns = .budgetReached
        case let result? where result.access != .ok:
            session.olderRuns = .failed(result.access)
        case let result?:
            session.olderRuns = result.budgetReached ? .budgetReached : .idle
            session.activityLimit = min(Self.maxActivityLimit, max(session.activityLimit, session.runs.count + result.added))
            await readActivity(of: session)
        }
    }

    /// The editor's text with the suggested concurrency block from the Core;
    /// nil when the Core is not ready or did not answer.
    func insertWorkflowConcurrency(workspaceID: UUID, content: String) async -> CoreConcurrencyInsertion? {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else { return nil }
        return try? await service.insertWorkflowConcurrency(repositoryID: coreID, content: content)
    }

    /// What keeps the Core from reading the workspace's pull requests, and
    /// the fix; nil when it reads them.
    func pullRequestsHelp(workspaceID: UUID) -> GitHubAccessHelp? {
        guard let session = sessions[workspaceID], let access = session.freshness.pullRequestsAccess,
              access == .permissionMissing || access == .notVisible else { return nil }
        return GitHubAccessHelp.pullRequestsUnreadable(repository: session.githubRepository, details: session.githubDetails,
                                                       credential: credentialKind(for: session.githubServerID),
                                                       server: serverRef(for: session.githubServerID))
    }
```

In `apps/macos/RunnirTests/CoreHubTests.swift` `FakeCore`, record the limit in `workspaceActivity` (`_activityLimits.append(limit)` inside its `lock.withLock`) and add:

```swift
    // MARK: Older runs and concurrency

    private var _activityLimits: [Int] = []
    var activityLimits: [Int] { lock.withLock { _activityLimits } }
    var olderRunsResult = CoreOlderRuns(access: .ok, added: 0, historyComplete: true, budgetReached: false)
    private var _olderRunsCalls: [String] = []
    var olderRunsCalls: [String] { lock.withLock { _olderRunsCalls } }
    func loadOlderRuns(repositoryID: String) async throws -> CoreOlderRuns {
        lock.withLock {
            _olderRunsCalls.append(repositoryID)
            return olderRunsResult
        }
    }
    var concurrencyInsertion: CoreConcurrencyInsertion = .refused(.alreadyPresent)
    private var _insertions: [String] = []
    var insertions: [String] { lock.withLock { _insertions } }
    func insertWorkflowConcurrency(repositoryID: String, content: String) async throws -> CoreConcurrencyInsertion {
        lock.withLock {
            _insertions.append(content)
            return concurrencyInsertion
        }
    }
```

In `apps/macos/RunnirTests/CoreProcessSupervisorTests.swift` `FakeService`, add:

```swift
    func loadOlderRuns(repositoryID: String) async throws -> CoreOlderRuns { throw CoreServiceError.unavailable }
    func insertWorkflowConcurrency(repositoryID: String, content: String) async throws -> CoreConcurrencyInsertion { throw CoreServiceError.unavailable }
```

Search for other uses of `CoreHub.activityLimit` (`grep -rn activityLimit apps/macos`) and replace them with `CoreHub.activityPage`.

- [ ] **Step 5: Build and run the tests**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/RunLinkMappingTests -only-testing:RunnirTests/CacheFirstHubTests`
Expected: PASS. (`pullRequestsHelp` needs `GitHubAccessHelp.pullRequestsUnreadable`; if Task 12 is not done yet, do its Step 3 `GitHubAccessHelp` part now.)

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Runnir/IPC apps/macos/RunnirTests/CoreHubTests.swift apps/macos/RunnirTests/CoreProcessSupervisorTests.swift apps/macos/RunnirTests/WorkspaceCacheTests.swift apps/macos/RunnirTests/RunLinkMappingTests.swift
git commit -m "App: run links, changes, hints, older runs and concurrency insertion from the Core"
```

---

### Task 12: How runs and changes read; dismissed hints; the pull request permission help

**Files:**
- Create: `apps/macos/Runnir/Features/Desktop/RunChanges.swift`, `apps/macos/Runnir/Features/Desktop/ConcurrencyHints.swift`
- Modify: `apps/macos/Runnir/Features/Desktop/GitHubAccessHelp.swift:178` (token text), `:245-250` (`permissionName`); add `pullRequestsUnreadable`
- Modify: `apps/macos/Runnir/App/Desktop/DesktopCoordinator.swift:100-130` (`hintDismissals`), `:431` (removal)
- Test: create `apps/macos/RunnirTests/RunChangesTests.swift`; `apps/macos/RunnirTests/GitHubAccessHelpTests.swift`

**Interfaces:**
- Consumes: Task 11 models.
- Produces:

```swift
enum RunPresentation {
    static func linkText(_ run: CoreWorkflowRun) -> String
    static func detail(_ run: CoreWorkflowRun) -> String
    static func summary(_ run: CoreWorkflowRun) -> String          // "run #881 · a1b2c3d · #142 after merge"
    static func visible(_ runs: [CoreWorkflowRun], showingSuperseded: Bool) -> [CoreWorkflowRun]
    static func hiddenCount(_ runs: [CoreWorkflowRun]) -> Int
    static func pullRequests(_ changes: [CoreRunChange]) -> [Int64: CoreChangePullRequest]
    static func changes(_ changes: [CoreRunChange], runs: [Int64: CoreWorkflowRun], branch: String?) -> [CoreRunChange]
    static func changeTitle(_ change: CoreRunChange) -> String
    static func sectionTitle(_ section: CoreRunChangeSection) -> String?
    static func olderText(_ change: CoreRunChange) -> String?
    static func repeatsText(_ section: CoreRunChangeSection) -> String?
    static func stateLabel(_ pullRequest: CoreChangePullRequest) -> String?
    static func pullRequestLine(_ pullRequest: CoreChangePullRequest) -> String
    static func commitLine(_ run: CoreWorkflowRun) -> String
    static func rowHelp(_ run: CoreWorkflowRun, pullRequest: CoreChangePullRequest?) -> String
    static func outdatedHelp(_ run: CoreWorkflowRun, newer: CoreWorkflowRun?) -> String
    static func hintText(_ hint: CoreConcurrencyHint, workflowName: String) -> String
    static func actionsURL(_ runs: [CoreWorkflowRun]) -> URL?
    static func context(for run: CoreWorkflowRun, runs: [Int64: CoreWorkflowRun], pullRequests: [Int64: CoreChangePullRequest],
                        hints: [CoreConcurrencyHint], workflowName: String) -> RunInspectorContext
}
struct RunInspectorContext: Equatable { var pullRequest: CoreChangePullRequest?; var supersededBy: CoreWorkflowRun?; var hint: CoreConcurrencyHint?; var workflowName = "" }
@MainActor @Observable final class ConcurrencyHintDismissals {
    init(defaults: UserDefaults = .standard)
    func isDismissed(_ path: String, workspaceID: UUID) -> Bool
    func dismiss(_ path: String, workspaceID: UUID)
    func removeAll(workspaceID: UUID)
}
extension GitHubAccessHelp {
    static func pullRequestsUnreadable(repository: String?, details: CoreGitHubRepository?,
                                       credential: CoreGitHubCredentialKind?, server: GitHubServerRef?) -> GitHubAccessHelp
}
// DesktopCoordinator gains: let hintDismissals: ConcurrencyHintDismissals (init parameter, default ConcurrencyHintDismissals())
```

- [ ] **Step 1: Write the failing tests**

Create `apps/macos/RunnirTests/RunChangesTests.swift`:

```swift
import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite struct RunChangesTests {
    private func run(_ id: Int64, sha: String = "a1b2c3d4", link: CoreRunLink = .none, supersededBy: Int64? = nil,
                     status: String = "completed", branch: String = "main") -> CoreWorkflowRun {
        CoreWorkflowRun(id: id, workflowID: 3, name: "CI", displayTitle: "Add retry", runNumber: id, event: "push", status: status,
                        conclusion: status == "completed" ? "success" : nil, branch: branch, headSHA: sha, actor: nil,
                        htmlURL: URL(string: "https://github.com/o/r/actions/runs/\(id)"), createdAt: nil, updatedAt: nil,
                        commitTitle: "Bump retry count", link: link, supersededBy: supersededBy)
    }

    private let pull = CoreChangePullRequest(number: 142, title: "Add retry to deploy", state: "merged", draft: false, author: "octocat",
                                             htmlURL: URL(string: "https://github.com/o/r/pull/142"), headBranch: "retry", baseBranch: "main",
                                             mergedAt: nil)

    @Test func runsSayWhatTheyBelongTo() {
        #expect(RunPresentation.linkText(run(1, link: .pullRequest(142))) == "#142")
        #expect(RunPresentation.linkText(run(1, link: .afterMerge(142))) == "#142 after merge")
        #expect(RunPresentation.linkText(run(1)) == "a1b2c3d")
        #expect(RunPresentation.detail(run(881, link: .afterMerge(142))) == "CI #881 · main · push · #142 after merge")
        #expect(RunPresentation.summary(run(881, link: .afterMerge(142))) == "run #881 · a1b2c3d · #142 after merge")
        #expect(RunPresentation.summary(run(881)) == "run #881 · a1b2c3d")
        #expect(RunPresentation.pullRequestLine(pull) == "Pull request #142 Add retry to deploy · merged")
        #expect(RunPresentation.commitLine(run(1)) == "Commit a1b2c3d Bump retry count")
        #expect(RunPresentation.rowHelp(run(1, link: .pullRequest(142)), pullRequest: pull) == "Pull request #142 Add retry to deploy\nCommit a1b2c3d Bump retry count")
    }

    @Test func completedSupersededRunsAreHiddenUntilAskedFor() {
        let runs = [run(3), run(2, supersededBy: 3), run(1, supersededBy: 3, status: "in_progress")]
        #expect(RunPresentation.visible(runs, showingSuperseded: false).map(\.id) == [3, 1], "an outdated run stays")
        #expect(RunPresentation.visible(runs, showingSuperseded: true).map(\.id) == [3, 2, 1])
        #expect(RunPresentation.hiddenCount(runs) == 1)
        #expect(runs[2].isOutdated && !runs[1].isOutdated)
    }

    @Test func changesReadAsTheSpecSays() {
        let merged = CoreRunChangeSection(kind: .afterMerge, headSHA: "a1b2c3d4", branch: "main", commitTitle: "", runIDs: [5, 4], repeatRunIDs: [])
        let latest = CoreRunChangeSection(kind: .latestCommit, headSHA: "9f8e7d6c", branch: "retry", commitTitle: "", runIDs: [3], repeatRunIDs: [7, 8])
        let change = CoreRunChange(id: "pr:142", pullRequest: pull, status: .passed, latestAt: nil, sections: [merged, latest],
                                   olderRunIDs: [2, 1], olderCommits: 2)
        #expect(RunPresentation.changeTitle(change) == "#142 Add retry to deploy")
        #expect(RunPresentation.sectionTitle(merged) == "After merge · main · a1b2c3d")
        #expect(RunPresentation.sectionTitle(latest) == "On the PR · 9f8e7d6 (latest)")
        #expect(RunPresentation.olderText(change) == "2 earlier runs on 2 older commits")
        #expect(RunPresentation.repeatsText(latest) == "2 earlier runs on this commit")
        #expect(RunPresentation.repeatsText(merged) == nil)
        #expect(RunPresentation.stateLabel(pull) == "merged")
        let commit = CoreRunChange(id: "commit:3c4d5e6f", pullRequest: nil, status: .failed, latestAt: nil,
                                   sections: [CoreRunChangeSection(kind: .commit, headSHA: "3c4d5e6f", branch: "main", commitTitle: "Bump Go", runIDs: [9], repeatRunIDs: [])],
                                   olderRunIDs: [], olderCommits: 0)
        #expect(RunPresentation.changeTitle(commit) == "3c4d5e6 Bump Go")
        #expect(RunPresentation.sectionTitle(commit.sections[0]) == nil)
        let runs = Dictionary(uniqueKeysWithValues: [run(9, branch: "main"), run(3, branch: "retry")].map { ($0.id, $0) })
        #expect(RunPresentation.changes([change, commit], runs: runs, branch: "retry").map(\.id) == ["pr:142"])
        #expect(RunPresentation.changes([change, commit], runs: runs, branch: nil).count == 2)
        #expect(RunPresentation.pullRequests([change, commit])[142]?.title == "Add retry to deploy")
    }

    @Test func theInspectorKnowsThePullRequestTheNewerRunAndTheHint() {
        let older = run(1, link: .pullRequest(142), supersededBy: 3)
        let newer = run(3, link: .pullRequest(142))
        let hint = CoreConcurrencyHint(workflowID: 3, path: ".github/workflows/ci.yml", runs: 3, overlapMinutes: 18, runIDs: [1], pullRequests: [142])
        let context = RunPresentation.context(for: older, runs: [3: newer], pullRequests: [142: pull], hints: [hint], workflowName: "CI")
        #expect(context.pullRequest == pull && context.supersededBy == newer && context.hint == hint)
        #expect(RunPresentation.hintText(hint, workflowName: "CI") == "3 runs of CI on older commits kept running after a newer push (about 18 min).")
        #expect(RunPresentation.outdatedHelp(older, newer: newer) == "A newer commit of #142 started CI #3. Cancel this run to save runner time.")
        #expect(RunPresentation.actionsURL([newer])?.absoluteString == "https://github.com/o/r/actions")
    }

    @Test func dismissedHintsAreKeptPerWorkspace() {
        let defaults = TestDefaults()
        defer { defaults.remove() }
        let workspace = UUID(), other = UUID()
        let dismissals = ConcurrencyHintDismissals(defaults: defaults.defaults)
        dismissals.dismiss(".github/workflows/ci.yml", workspaceID: workspace)
        #expect(dismissals.isDismissed(".github/workflows/ci.yml", workspaceID: workspace))
        #expect(!dismissals.isDismissed(".github/workflows/ci.yml", workspaceID: other))
        let reread = ConcurrencyHintDismissals(defaults: defaults.defaults)
        #expect(reread.isDismissed(".github/workflows/ci.yml", workspaceID: workspace))
        reread.removeAll(workspaceID: workspace)
        #expect(!ConcurrencyHintDismissals(defaults: defaults.defaults).isDismissed(".github/workflows/ci.yml", workspaceID: workspace))
    }
}
```

Append to `apps/macos/RunnirTests/GitHubAccessHelpTests.swift` (inside its suite):

```swift
    @Test func unreadablePullRequestsSayWhatToFix() {
        let token = GitHubAccessHelp.pullRequestsUnreadable(repository: "o/r", details: nil, credential: .fineGrained, server: nil)
        #expect(token.message.contains("Pull requests: Read-only"))
        if case .editToken = token.fix {} else { Issue.record("fix = \(token.fix)") }
        let installation = CoreGitHubInstallation(id: 1, account: "o", accountType: "Organization", repositorySelection: "all",
                                                  htmlURL: URL(string: "https://github.com/organizations/o/settings/installations/1"),
                                                  missingPermissions: ["pull_requests: read"])
        let details = CoreGitHubRepository(access: .ok, fullName: "o/r", visibility: "private", defaultBranch: "main", htmlURL: nil,
                                           canPush: true, installation: installation)
        let pending = GitHubAccessHelp.pullRequestsUnreadable(repository: "o/r", details: details, credential: .appUser, server: nil)
        #expect(pending.title == "Pull requests can't be read")
        #expect(pending.message.contains("An owner of o accepts it on GitHub"))
        #expect(pending.fix == .reviewPermissions(URL(string: "https://github.com/organizations/o/settings/installations/1")!))
        #expect(GitHubAccessHelp.permissionName("pull_requests: read") == "Pull requests (read)")
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `xcodebuild … test -only-testing:RunnirTests/RunChangesTests -only-testing:RunnirTests/GitHubAccessHelpTests`
Expected: FAIL to build (`RunPresentation`, `ConcurrencyHintDismissals`, `pullRequestsUnreadable` undefined).

- [ ] **Step 3: Implement**

Create `apps/macos/Runnir/Features/Desktop/RunChanges.swift`:

```swift
import Foundation

/// What the Runs section knows around a run: its pull request, the run that
/// superseded it, and a concurrency suggestion for its workflow.
struct RunInspectorContext: Equatable {
    var pullRequest: CoreChangePullRequest?
    var supersededBy: CoreWorkflowRun?
    var hint: CoreConcurrencyHint?
    var workflowName = ""
}

/// How runs and changes read in the Runs section, the inspector and the
/// Overview. The Core decides links, superseded runs and changes; this only
/// words them.
enum RunPresentation {
    static func shortSHA(_ sha: String) -> String { String(sha.prefix(7)) }

    /// "#142", "#142 after merge", or the short commit without a pull request.
    static func linkText(_ run: CoreWorkflowRun) -> String {
        switch run.link {
        case .pullRequest(let number): "#\(number)"
        case .afterMerge(let number): "#\(number) after merge"
        case .none: shortSHA(run.headSHA)
        }
    }

    /// A row's second line: workflow and number, branch, event and link.
    static func detail(_ run: CoreWorkflowRun) -> String {
        ["\(run.name) #\(run.runNumber)", run.branch, run.event, linkText(run)].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The Overview's latest run: "run #881 · a1b2c3d · #142 after merge".
    static func summary(_ run: CoreWorkflowRun) -> String {
        var parts = ["run #\(run.runNumber)", shortSHA(run.headSHA)]
        if run.link.pullRequest != nil { parts.append(linkText(run)) }
        return parts.joined(separator: " · ")
    }

    /// The runs a list shows: completed superseded runs only when asked for.
    /// An outdated run (superseded, still going) always shows.
    static func visible(_ runs: [CoreWorkflowRun], showingSuperseded: Bool) -> [CoreWorkflowRun] {
        showingSuperseded ? runs : runs.filter { !$0.isSuperseded || $0.outcome.isActive }
    }

    static func hiddenCount(_ runs: [CoreWorkflowRun]) -> Int {
        runs.count { $0.isSuperseded && !$0.outcome.isActive }
    }

    /// The pull requests the changes describe, by number.
    static func pullRequests(_ changes: [CoreRunChange]) -> [Int64: CoreChangePullRequest] {
        Dictionary(changes.compactMap { change in change.pullRequest.map { ($0.number, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// Changes with a run on `branch`; all of them for nil.
    static func changes(_ changes: [CoreRunChange], runs: [Int64: CoreWorkflowRun], branch: String?) -> [CoreRunChange] {
        guard let branch else { return changes }
        return changes.filter { change in
            (change.sections.flatMap { $0.runIDs + $0.repeatRunIDs } + change.olderRunIDs).contains { runs[$0]?.branch == branch }
        }
    }

    /// "#142 Add retry to deploy", or "3c4d5e6 Bump Go" for a commit.
    static func changeTitle(_ change: CoreRunChange) -> String {
        if let pullRequest = change.pullRequest {
            return pullRequest.title.isEmpty ? "#\(pullRequest.number)" : "#\(pullRequest.number) \(pullRequest.title)"
        }
        guard let section = change.sections.first else { return change.id }
        return [shortSHA(section.headSHA), section.commitTitle].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "After merge · main · a1b2c3d", "On the PR · 9f8e7d6 (latest)"; nil
    /// for a commit, whose header already says it.
    static func sectionTitle(_ section: CoreRunChangeSection) -> String? {
        switch section.kind {
        case .afterMerge: "After merge · \(section.branch) · \(shortSHA(section.headSHA))"
        case .latestCommit: "On the PR · \(shortSHA(section.headSHA)) (latest)"
        case .commit: nil
        }
    }

    /// "2 earlier runs on 2 older commits"; nil without any.
    static func olderText(_ change: CoreRunChange) -> String? {
        guard !change.olderRunIDs.isEmpty else { return nil }
        let runs = change.olderRunIDs.count == 1 ? "1 earlier run" : "\(change.olderRunIDs.count) earlier runs"
        let commits = change.olderCommits == 1 ? "1 older commit" : "\(change.olderCommits) older commits"
        return "\(runs) on \(commits)"
    }

    /// "2 earlier runs on this commit"; nil without any.
    static func repeatsText(_ section: CoreRunChangeSection) -> String? {
        switch section.repeatRunIDs.count {
        case 0: nil
        case 1: "1 earlier run on this commit"
        case let n: "\(n) earlier runs on this commit"
        }
    }

    /// "open", "draft", "merged" or "closed"; nil when the Core has not read it.
    static func stateLabel(_ pullRequest: CoreChangePullRequest) -> String? {
        if pullRequest.state == "open" && pullRequest.draft { return "draft" }
        return pullRequest.state.isEmpty ? nil : pullRequest.state
    }

    /// "Pull request #142 Add retry to deploy · merged".
    static func pullRequestLine(_ pullRequest: CoreChangePullRequest) -> String {
        var line = "Pull request #\(pullRequest.number)"
        if !pullRequest.title.isEmpty { line += " \(pullRequest.title)" }
        if let state = stateLabel(pullRequest) { line += " · \(state)" }
        return line
    }

    /// "Commit a1b2c3d Bump retry count".
    static func commitLine(_ run: CoreWorkflowRun) -> String {
        ["Commit", shortSHA(run.headSHA), run.commitTitle].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A row's help: the pull request's title and the commit.
    static func rowHelp(_ run: CoreWorkflowRun, pullRequest: CoreChangePullRequest?) -> String {
        var lines: [String] = []
        if let pullRequest {
            lines.append(pullRequest.title.isEmpty ? "Pull request #\(pullRequest.number)" : "Pull request #\(pullRequest.number) \(pullRequest.title)")
        }
        lines.append(commitLine(run))
        return lines.joined(separator: "\n")
    }

    /// The "outdated" label's help.
    static func outdatedHelp(_ run: CoreWorkflowRun, newer: CoreWorkflowRun?) -> String {
        let pull = run.link.pullRequest.map { " of #\($0)" } ?? ""
        let started = newer.map { " started \($0.name) #\($0.runNumber)" } ?? " started a newer run"
        return "A newer commit\(pull)\(started). Cancel this run to save runner time."
    }

    /// "3 runs of CI on older commits kept running after a newer push (about 18 min)."
    static func hintText(_ hint: CoreConcurrencyHint, workflowName: String) -> String {
        let runs = hint.runs == 1 ? "1 run" : "\(hint.runs) runs"
        return "\(runs) of \(workflowName) on older commits kept running after a newer push (about \(hint.overlapMinutes) min)."
    }

    /// The repository's Actions page, from a run's address.
    static func actionsURL(_ runs: [CoreWorkflowRun]) -> URL? {
        guard let address = runs.last?.htmlURL?.absoluteString, let range = address.range(of: "/actions/runs/") else { return nil }
        return URL(string: String(address[..<range.lowerBound]) + "/actions")
    }

    static func context(for run: CoreWorkflowRun, runs: [Int64: CoreWorkflowRun], pullRequests: [Int64: CoreChangePullRequest],
                        hints: [CoreConcurrencyHint], workflowName: String) -> RunInspectorContext {
        RunInspectorContext(pullRequest: run.link.pullRequest.flatMap { pullRequests[$0] },
                            supersededBy: run.supersededBy.flatMap { runs[$0] },
                            hint: hints.first { $0.workflowID == run.workflowID }, workflowName: workflowName)
    }
}
```

Create `apps/macos/Runnir/Features/Desktop/ConcurrencyHints.swift`:

```swift
import Foundation
import Observation

/// Workflows for which the user turned the concurrency suggestion off, per
/// workspace, kept on this Mac in UserDefaults.
@MainActor
@Observable
final class ConcurrencyHintDismissals {
    static let key = "dismissedConcurrencyHints"
    @ObservationIgnored private let defaults: UserDefaults
    private(set) var dismissed: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dismissed = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isDismissed(_ path: String, workspaceID: UUID) -> Bool {
        dismissed.contains(Self.entry(path, workspaceID))
    }

    func dismiss(_ path: String, workspaceID: UUID) {
        dismissed.insert(Self.entry(path, workspaceID))
        save()
    }

    /// Forgets a removed workspace's choices.
    func removeAll(workspaceID: UUID) {
        let prefix = workspaceID.uuidString.lowercased() + "|"
        dismissed = dismissed.filter { !$0.hasPrefix(prefix) }
        save()
    }

    private func save() { defaults.set(dismissed.sorted(), forKey: Self.key) }

    private static func entry(_ path: String, _ workspaceID: UUID) -> String {
        workspaceID.uuidString.lowercased() + "|" + path
    }
}
```

In `GitHubAccessHelp.swift`:
- line 178: `"To \(purpose.phrase) in \(name), a fine-grained token needs Actions: Read and write, Contents: Read-only and Pull requests: Read-only for it."`
- replace `permissionName`:

```swift
    /// "actions: write" reads as "Actions (write)", "pull_requests: read" as
    /// "Pull requests (read)".
    static func permissionName(_ permission: String) -> String {
        let parts = permission.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return permission }
        let name = parts[0].replacingOccurrences(of: "_", with: " ")
        return "\(name.prefix(1).uppercased() + name.dropFirst()) (\(parts[1]))"
    }
```

- add to the `GitHubAccessHelp` struct:

```swift
    /// Why runs are not linked to their pull requests: the Core could not
    /// read them. The fix is the token's permission, the installation's
    /// pending permission, or the app's permissions on GitHub.
    static func pullRequestsUnreadable(repository: String?, details: CoreGitHubRepository?,
                                       credential: CoreGitHubCredentialKind?, server: GitHubServerRef?) -> GitHubAccessHelp {
        let name = repository.flatMap { $0.isEmpty ? nil : $0 } ?? "this repository"
        let title = "Pull requests can't be read"
        let lead = "Runs after a merge and runs from forks are not linked to their pull requests."
        if let credential, credential.isPersonal {
            let message = credential == .fineGrained
                ? "\(lead) A fine-grained token needs Pull requests: Read-only for \(name)."
                : "\(lead) The token needs the repo scope for \(name)."
            let fix: Fix = if let server, !server.isDotCom { .openSettings } else { .editToken(tokenSettingsURL(credential)) }
            return GitHubAccessHelp(title: title, message: message, fix: fix)
        }
        if let installation = details?.installation, installation.missingPermissions.contains(where: { $0.hasPrefix("pull_requests") }) {
            let who = installation.accountType == "User" ? "\(installation.account) accepts it on GitHub." : "An owner of \(installation.account) accepts it on GitHub."
            return GitHubAccessHelp(title: title, message: "\(lead) Runnir Desktop needs Pull requests (read) on \(name); \(who)",
                                    fix: .reviewPermissions(installation.htmlURL ?? installationURL))
        }
        return GitHubAccessHelp(title: title, message: "\(lead) Runnir Desktop needs Pull requests (read) on \(name). Check the app's permissions on GitHub.",
                                fix: .reviewPermissions(details?.installation?.htmlURL ?? installationURL))
    }
```

In `DesktopCoordinator.swift`, add next to `favorites`:

```swift
    /// Workflows whose concurrency suggestion the user turned off, per workspace.
    let hintDismissals: ConcurrencyHintDismissals
```

an init parameter `hintDismissals: ConcurrencyHintDismissals = ConcurrencyHintDismissals(),` after `favorites:`, the assignment `self.hintDismissals = hintDismissals`, and next to `favorites.removeAll(workspaceID: workspace.id)` (line 431): `hintDismissals.removeAll(workspaceID: workspace.id)`.

- [ ] **Step 4: Run the tests**

Run: `xcodebuild … test -only-testing:RunnirTests/RunChangesTests -only-testing:RunnirTests/GitHubAccessHelpTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/macos/Runnir/Features/Desktop/RunChanges.swift apps/macos/Runnir/Features/Desktop/ConcurrencyHints.swift apps/macos/Runnir/Features/Desktop/GitHubAccessHelp.swift apps/macos/Runnir/App/Desktop/DesktopCoordinator.swift apps/macos/RunnirTests/RunChangesTests.swift apps/macos/RunnirTests/GitHubAccessHelpTests.swift
git commit -m "App: words for run links and changes, dismissed hints, pull request permission help"
```

---

### Task 13: The editor applies the concurrency block as one undoable edit

**Files:**
- Modify: `apps/macos/Runnir/Features/Desktop/CodeEditor.swift` (`CodeEditorEdit`, `edit` parameter, coordinator)
- Modify: `apps/macos/Runnir/Features/Desktop/DesktopViews.swift` (`WorkspaceFilesModel`, `LocalWorkflowBrowser`, the window's `open`)
- Test: `apps/macos/RunnirTests/WorkflowEditingTests.swift`

**Interfaces:**
- Consumes: `CoreHub.insertWorkflowConcurrency(workspaceID:content:)`, `CoreConcurrencyRefusal.message` (Task 11).
- Produces:

```swift
struct CodeEditorEdit: Equatable, Sendable { let id: Int; let before: String; let range: NSRange; let replacement: String
    init?(from before: String, to after: String, id: Int) }
// CodeEditor gains: var edit: CodeEditorEdit? = nil
// WorkspaceFilesModel gains: pendingEdit, editNotice, waitUntilLoaded(_:), insertConcurrency(hub:workspaceID:), dismissEditNotice()
// DesktopWorkspaceView (window) gains: private func addConcurrency(path: String)   — used by Task 14
```

- [ ] **Step 1: Write the failing tests**

Append to `WorkflowEditingTests`:

```swift
    @Test func anEditIsTheTextBetweenTheCommonStartAndEnd() throws {
        let edit = try #require(CodeEditorEdit(from: "a\nc\n", to: "a\nb\nc\n", id: 1))
        #expect(edit.range == NSRange(location: 2, length: 0) && edit.replacement == "b\n")
        #expect(CodeEditorEdit(from: "same", to: "same", id: 2) == nil)
        let replaced = try #require(CodeEditorEdit(from: "abc", to: "aXc", id: 3))
        #expect(replaced.range == NSRange(location: 1, length: 1) && replaced.replacement == "X")
    }

    @Test func theConcurrencyBlockBecomesOneEditForTheEditor() async throws {
        let (root, reader, hub, core, workspace) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = await loaded(reader)
        let inserted = "name: CI\non: push\n\n# block\nconcurrency:\n  group: g\n  cancel-in-progress: true\n\njobs:\n  lint:\n    runs-on: ubuntu-latest\n"
        core.concurrencyInsertion = .inserted(content: inserted, firstLine: 4, lastLine: 7)
        await model.insertConcurrency(hub: hub, workspaceID: workspace)
        #expect(core.insertions == [Self.original])
        let edit = try #require(model.pendingEdit)
        #expect(edit.before == Self.original)
        #expect(edit.range == NSRange(location: 18, length: 0))
        #expect(edit.replacement == "\n# block\nconcurrency:\n  group: g\n  cancel-in-progress: true\n\n")
        #expect(model.highlightedLine == 4)
        #expect(model.source == Self.original, "the editor applies the edit; the text follows through its binding")
        #expect(model.editNotice == nil)
    }

    @Test func aRefusedConcurrencyBlockSaysWhyAndChangesNothing() async throws {
        let (root, reader, hub, core, workspace) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = await loaded(reader)
        core.concurrencyInsertion = .refused(.alreadyPresent)
        await model.insertConcurrency(hub: hub, workspaceID: workspace)
        #expect(model.pendingEdit == nil && model.source == Self.original)
        #expect(model.editNotice == CoreConcurrencyRefusal.alreadyPresent.message)
        model.dismissEditNotice()
        #expect(model.editNotice == nil)
    }

    @Test func waitingForAFileEndsWhenItIsLoaded() async throws {
        let (root, reader, _, _, _) = try await setUp()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceFilesModel()
        let file = LocalWorkflowFile(relativePath: ".github/workflows/ci.yml")
        model.select(file, reader: reader)
        #expect(await model.waitUntilLoaded(file))
        #expect(model.source == Self.original)
        #expect(!(await model.waitUntilLoaded(LocalWorkflowFile(relativePath: ".github/workflows/other.yml"))))
    }
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `xcodebuild … test -only-testing:RunnirTests/WorkflowEditingTests`
Expected: FAIL to build (`CodeEditorEdit`, `insertConcurrency`, `waitUntilLoaded` undefined).

- [ ] **Step 3: Implement the edit in the editor**

In `CodeEditor.swift`, before `struct CodeEditor`:

```swift
/// One replacement the editor applies as a single undoable change, as
/// typing would, when its text is still `before`.
struct CodeEditorEdit: Equatable, Sendable {
    let id: Int
    let before: String
    /// UTF-16 range in `before`.
    let range: NSRange
    let replacement: String

    /// The replacement that turns `before` into `after`: what lies between
    /// their common start and common end. nil when they are equal.
    init?(from before: String, to after: String, id: Int) {
        guard before != after else { return nil }
        let old = Array(before.utf16), new = Array(after.utf16)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        self.id = id
        self.before = before
        range = NSRange(location: prefix, length: old.count - prefix - suffix)
        replacement = String(decoding: new[prefix..<(new.count - suffix)], as: UTF16.self)
    }
}
```

Add to `CodeEditor`, after `var isEditable: Bool`:

```swift
    /// An edit to apply once, undoable (the concurrency block).
    var edit: CodeEditorEdit? = nil
```

In `updateNSView`, replace

```swift
        if textView.string != text {
            // A new file or a reload from disk, not an edit.
            coordinator.load(text)
        }
```

with

```swift
        if let edit, edit.id != coordinator.appliedEdit, textView.string == edit.before {
            coordinator.appliedEdit = edit.id
            // After this update: the change sets the binding.
            Task { @MainActor in coordinator.apply(edit) }
        } else if textView.string != text {
            // A new file or a reload from disk, not an edit.
            coordinator.load(text)
        }
```

Add to `Coordinator` (after `private var loading = false`):

```swift
        /// The last edit applied, so each one is applied once.
        var appliedEdit = 0

        /// Replaces text as one undoable change, as typing would; the
        /// delegate then updates the binding.
        func apply(_ edit: CodeEditorEdit) {
            guard let textView, textView.string == edit.before,
                  textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
            textView.textStorage?.replaceCharacters(in: edit.range, with: NSAttributedString(string: edit.replacement, attributes: Self.plainAttributes))
            textView.didChangeText()
            textView.undoManager?.setActionName("Add Concurrency")
        }
```

- [ ] **Step 4: Implement the model and the window**

In `WorkspaceFilesModel` (DesktopViews.swift), add after `private var loadGeneration = 0`:

```swift
    /// An edit the editor applies as one undoable change (the concurrency block).
    private(set) var pendingEdit: CodeEditorEdit?
    /// Why the last suggested edit was not made, shown over the editor.
    private(set) var editNotice: String?
    private var editCount = 0
```

In `select(_:reader:)`, after `saveError = nil` add `pendingEdit = nil` and `editNotice = nil`. Add methods after `reloadFromDisk`:

```swift
    /// Waits until `file` is loaded in the editor; false when another file
    /// is open or it could not be read.
    func waitUntilLoaded(_ file: LocalWorkflowFile) async -> Bool {
        await sourceTask?.value
        return selected == file && savedDigest != nil
    }

    /// Asks the Core for the open file's text with the concurrency block and
    /// hands it to the editor as one undoable edit. Nothing is saved.
    func insertConcurrency(hub: CoreHub, workspaceID: UUID) async {
        guard selected != nil, savedDigest != nil else { return }
        guard isWritable else {
            editNotice = "This workflow file is read-only, so the concurrency block can't be added."
            return
        }
        let before = source
        switch await hub.insertWorkflowConcurrency(workspaceID: workspaceID, content: before) {
        case .inserted(let content, let firstLine, _)?:
            // Typing while the Core answered: the answer is for older text.
            guard source == before, let edit = CodeEditorEdit(from: before, to: content, id: editCount + 1) else { return }
            editCount += 1
            editNotice = nil
            pendingEdit = edit
            reveal(line: firstLine)
        case .refused(let refusal)?:
            editNotice = refusal.message
        case nil:
            editNotice = "Runnir Core could not add the block. Try again once it is ready."
        }
    }

    func dismissEditNotice() { editNotice = nil }
```

In `LocalWorkflowBrowser.sourcePanel`, pass the edit to the editor:

```swift
                CodeEditor(text: $model.source, flaggedLines: model.isDirty ? [] : flagged, highlightedLine: model.highlightedLine,
                           revealCount: model.revealCount, isEditable: model.isWritable && model.savedDigest != nil, edit: model.pendingEdit)
```

and in `editorBanner`, after the `else if let error = model.saveError { … }` branch:

```swift
        } else if let notice = model.editNotice {
            banner(notice, symbol: "info.circle", tint: RunnirTheme.info) {
                Button("Dismiss") { model.dismissEditNotice() }
            }
```

In the window view (the struct with `private func open(_ file: LocalWorkflowFile)`), replace `open(_:)` with:

```swift
    /// Opens a file in the editor, asking first, in a sheet on this window,
    /// when the open one has unsaved edits; true once that file is loaded.
    private func openAndLoad(_ file: LocalWorkflowFile) async -> Bool {
        guard let reader else { return false }
        if file != files.selected {
            if files.isDirty, let current = files.selected {
                let choice = await UnsavedChangesPrompt.ask(fileName: current.name, sheetOn: desktop.window(windowID))
                // Answered for the file that was open when asked.
                guard files.selected == current else { return false }
                switch choice {
                case .save:
                    guard await saveAndRevalidate() else { return false }
                case .discard:
                    break
                case .cancel:
                    return false
                }
            }
            files.select(file, reader: reader)
        }
        return await files.waitUntilLoaded(file)
    }

    private func open(_ file: LocalWorkflowFile) {
        Task { _ = await openAndLoad(file) }
    }

    /// Opens a workflow file in the editor with the suggested concurrency
    /// block as an unsaved edit; the user reviews, saves and commits it.
    private func addConcurrency(path: String) {
        guard let hub = desktop.core else { return }
        let file = LocalWorkflowFile(relativePath: path)
        state.selectedSection = .workspace
        state.workspaceTab = .editor
        Task {
            guard await openAndLoad(file) else { return }
            await files.insertConcurrency(hub: hub, workspaceID: workspace.id)
        }
    }
```

- [ ] **Step 5: Run the tests**

Run: `xcodebuild … test -only-testing:RunnirTests/WorkflowEditingTests`
Expected: PASS. (`addConcurrency(path:)` is unused until Task 14; the compiler does not warn about unused private methods in views.)

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Runnir/Features/Desktop/CodeEditor.swift apps/macos/Runnir/Features/Desktop/DesktopViews.swift apps/macos/RunnirTests/WorkflowEditingTests.swift
git commit -m "App: add the concurrency block to the editor as one undoable edit"
```

---

### Task 14: Runs section, inspector, Overview and the runs mode per window

**Files:**
- Create: `apps/macos/Runnir/Features/Desktop/RunChangeViews.swift`
- Modify: `apps/macos/Runnir/Features/Desktop/GitHubActivityViews.swift` (`RunRow`, `RecentRunsList`, `WorkspaceRunsView`)
- Modify: `apps/macos/Runnir/Features/Desktop/RunInspectorView.swift` (init, `links`)
- Modify: `apps/macos/Runnir/Features/Desktop/OverviewViews.swift` (`latestRunSummary`)
- Modify: `apps/macos/Runnir/App/AppState.swift`, `apps/macos/Runnir/App/Desktop/DesktopStateStore.swift:17-22`, `apps/macos/Runnir/App/Desktop/DesktopCoordinator.swift` (`selectRunsMode`, `installContent`)
- Modify: `apps/macos/Runnir/Features/Desktop/DesktopViews.swift` (Runs section call, `onChange`)
- Test: `apps/macos/RunnirTests/DesktopStateTests.swift`

**Interfaces:**
- Consumes: Tasks 11–13.
- Produces: `enum RunsMode: String, Codable, Sendable { case list, byChange }`; `AppState.runsMode`; `WorkspaceWindowRecord.runsMode: RunsMode?`; `DesktopCoordinator.selectRunsMode(_:windowID:)`; views `RunTag`, `RunChangeBlock`, `ConcurrencyHintBanner`, `OlderRunsFooter`.

- [ ] **Step 1: Write the failing test**

Add to the suite in `DesktopStateTests.swift` that holds `relinkRebindsEveryOpenWindowAndPreservesIdentityAndNavigation`:

```swift
    @Test func theRunsModeIsKeptPerWindow() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let factory = TestWindowFactory()
        let coordinator = DesktopCoordinator(store: fixture.store, makeGrant: factory.makeGrant,
                                             makeWorkspaceWindow: factory.makeWindow)
        await coordinator.loadSession()
        coordinator.openRegistered(fixture.original)
        coordinator.openRegistered(fixture.original)
        let first = try #require(factory.windows.first)
        let second = try #require(factory.windows.last)
        coordinator.selectRunsMode(.byChange, windowID: first.record.id)
        let saved = try fixture.store.load().windows
        #expect(saved.first { $0.id == first.record.id }?.runsMode == .byChange)
        #expect(saved.first { $0.id == second.record.id }?.runsMode == nil, "a window that never switched shows the list")
    }
```

- [ ] **Step 2: Run it to see it fail**

Run: `xcodebuild … test -only-testing:RunnirTests/DesktopStateTests`
Expected: FAIL to build (`selectRunsMode`, `runsMode` undefined).

- [ ] **Step 3: The runs mode per window**

In `AppState.swift`, before `final class AppState`:

```swift
/// How the Runs section lists runs.
enum RunsMode: String, Codable, Sendable {
    case list
    case byChange
}
```

and in `AppState`, after `selectedRunID`:

```swift
    /// The Runs section's list or changes; List until the user switches.
    var runsMode: RunsMode = .list
```

In `WorkspaceWindowRecord` (`DesktopStateStore.swift`), after `var section: AppSection = .dashboard`:

```swift
    /// nil until the user switches the Runs section; reads as List.
    var runsMode: RunsMode? = nil
```

In `DesktopCoordinator.swift`, after `selectSection`:

```swift
    func selectRunsMode(_ mode: RunsMode, windowID: UUID) {
        guard let index = snapshot.windows.firstIndex(where: { $0.id == windowID }) else { return }
        var candidate = snapshot
        candidate.windows[index].runsMode = mode
        do { try commit(candidate); windows[windowID]?.record.runsMode = mode }
        catch { message = "Window navigation could not be saved." }
    }
```

and in `installContent`, after `state.selectedSection = record.section.restored`: `state.runsMode = record.runsMode ?? .list`.

In `DesktopViews.swift`, next to `.onChange(of: state.selectedSection) { … }` add:

```swift
        .onChange(of: state.runsMode) { _, value in desktop.selectRunsMode(value, windowID: windowID) }
```

and replace the Runs case of `content`:

```swift
        case .runs:
            if let session, let hub = desktop.core {
                WorkspaceRunsView(session: session, hub: hub, github: desktop.github,
                                  selectedRunID: Binding(get: { state.selectedRunID }, set: { state.selectedRunID = $0 }),
                                  mode: Binding(get: { state.runsMode }, set: { state.runsMode = $0 }),
                                  dismissals: desktop.hintDismissals,
                                  addConcurrency: { path in addConcurrency(path: path) })
            } else {
                coreUnavailable
            }
```

- [ ] **Step 4: The views**

Create `apps/macos/Runnir/Features/Desktop/RunChangeViews.swift`:

```swift
import SwiftUI

/// A small capsule label next to a run's title.
struct RunTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(tint)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

/// The concurrency suggestion: what happened and the two choices.
struct ConcurrencyHintBanner: View {
    let hint: CoreConcurrencyHint
    let workflowName: String
    let add: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb").foregroundStyle(RunnirTheme.info)
            VStack(alignment: .leading, spacing: 6) {
                Text(RunPresentation.hintText(hint, workflowName: workflowName))
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Button("Add concurrency…", action: add).buttonStyle(DesignButtonStyle(primary: true))
                        .help("Open \(hint.path) in the editor with a block that cancels runs a newer commit replaced. Nothing is saved until you save it.")
                    Button("Don't suggest for this workflow", action: dismiss).buttonStyle(.link)
                }.font(.system(size: 12))
            }
            Spacer(minLength: 0)
        }
        .padding(12).background(RunnirTheme.info.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// One change in By change: its header, its sections, the runs it folds
/// away, and a concurrency suggestion that names its pull request.
struct RunChangeBlock: View {
    let change: CoreRunChange
    let runs: [Int64: CoreWorkflowRun]
    let selectedRunID: Int64?
    @Binding var expanded: Set<String>
    let hints: [CoreConcurrencyHint]
    let workflowName: (Int64) -> String
    let select: (Int64) -> Void
    let addConcurrency: (String) -> Void
    let dismissHint: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            ForEach(Array(change.sections.enumerated()), id: \.offset) { _, section in
                if let title = RunPresentation.sectionTitle(section) {
                    Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(RunnirTheme.secondaryForeground)
                        .padding(.horizontal, 10).padding(.top, 4)
                }
                rows(section.runIDs)
                if let text = RunPresentation.repeatsText(section) {
                    expander(text, key: "\(change.id)/\(section.headSHA)/repeats", ids: section.repeatRunIDs)
                }
            }
            if let text = RunPresentation.olderText(change) {
                expander(text, key: "\(change.id)/older", ids: change.olderRunIDs)
            }
            ForEach(hints, id: \.workflowID) { hint in
                ConcurrencyHintBanner(hint: hint, workflowName: workflowName(hint.workflowID),
                                      add: { addConcurrency(hint.path) }, dismiss: { dismissHint(hint.path) })
                    .padding(.horizontal, 6).padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { DesignDivider() }
    }

    private var header: some View {
        let icon = PullRequestRow.ciIcon(change.status)
        return HStack(spacing: 8) {
            Image(systemName: icon.symbol).foregroundStyle(icon.tint).font(.system(size: 13))
            Text(RunPresentation.changeTitle(change)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 6)
            if let pullRequest = change.pullRequest, let state = RunPresentation.stateLabel(pullRequest) {
                RunTag(text: state, tint: RunnirTheme.secondaryForeground)
            } else if change.pullRequest == nil, let branch = change.sections.first?.branch {
                Text(branch).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func rows(_ ids: [Int64]) -> some View {
        ForEach(ids.compactMap { runs[$0] }) { run in
            RunRow(run: run, selected: run.id == selectedRunID, pullRequest: change.pullRequest)
                .onTapGesture { select(run.id) }
        }
    }

    @ViewBuilder private func expander(_ text: String, key: String, ids: [Int64]) -> some View {
        let open = expanded.contains(key)
        Button {
            if open { expanded.remove(key) } else { expanded.insert(key) }
        } label: {
            Label(text, systemImage: open ? "chevron.down" : "chevron.right").font(.system(size: 11))
        }
        .buttonStyle(.borderless).foregroundStyle(RunnirTheme.secondaryForeground)
        .padding(.horizontal, 10).padding(.vertical, 2)
        if open { rows(ids) }
    }
}

/// The end of a run list. While it is on screen it asks for more runs: from
/// the cache first, then one page of older runs from GitHub.
struct OlderRunsFooter: View {
    let session: RepositorySession
    let hub: CoreHub
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            switch session.olderRuns {
            case .loading:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading older runs…") }
            case .failed:
                HStack(spacing: 8) {
                    Text("Couldn't load older runs.")
                    Button("Retry") { Task { await hub.showMoreRuns(workspaceID: session.workspaceID) } }.buttonStyle(.link)
                }
            case .budgetReached:
                HStack(spacing: 8) {
                    Text("Older runs are on GitHub.")
                    if let url = RunPresentation.actionsURL(session.runs) {
                        Button("Open Actions on GitHub") { openURL(url) }.buttonStyle(.link)
                    }
                }
            case .idle:
                Color.clear.frame(height: 1)
            }
        }
        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(10)
        .task(id: session.runs.count) {
            guard session.olderRuns == .idle, !session.runs.isEmpty else { return }
            await hub.showMoreRuns(workspaceID: session.workspaceID)
        }
    }
}
```

In `GitHubActivityViews.swift`, replace `RunRow`:

```swift
/// One line per run: status, title, number, branch, event, what it belongs
/// to and age. A superseded run shown on request is dimmed; an outdated one
/// (superseded, still going) says so.
struct RunRow: View {
    let run: CoreWorkflowRun
    var selected = false
    /// The pull request the run belongs to, for the help.
    var pullRequest: CoreChangePullRequest? = nil
    /// The run that superseded this one, for the outdated label's help.
    var newer: CoreWorkflowRun? = nil

    private var dimmed: Bool { run.isSuperseded && !run.outcome.isActive }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RunOutcomeIcon(outcome: run.outcome).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(run.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if run.isOutdated {
                        RunTag(text: "outdated", tint: RunnirTheme.info).help(RunPresentation.outdatedHelp(run, newer: newer))
                    } else if dimmed {
                        RunTag(text: "older commit", tint: RunnirTheme.secondaryForeground)
                    }
                }
                Text(RunPresentation.detail(run)).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let created = run.createdAt {
                Text(created, format: .relative(presentation: .named))
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
        }
        .opacity(dimmed ? 0.6 : 1)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(selected ? RunnirTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
        .help(RunPresentation.rowHelp(run, pullRequest: pullRequest))
        .accessibilityElement(children: .combine)
    }
}
```

In `RecentRunsList`, replace the `ForEach(session.runs.prefix(limit)) { … }` with:

```swift
            let pullRequests = RunPresentation.pullRequests(session.changes)
            ForEach(RunPresentation.visible(session.runs, showingSuperseded: false).prefix(limit)) { run in
                Button { open(run) } label: {
                    RunRow(run: run, pullRequest: run.link.pullRequest.flatMap { pullRequests[$0] })
                }.buttonStyle(.plain)
            }
```

Replace `WorkspaceRunsView` entirely:

```swift
/// Runs section: the runs as a list or by change, and the selected run's
/// jobs and steps.
struct WorkspaceRunsView: View {
    let session: RepositorySession
    let hub: CoreHub
    let github: GitHubSession?
    @Binding var selectedRunID: Int64?
    @Binding var mode: RunsMode
    var dismissals: ConcurrencyHintDismissals? = nil
    var addConcurrency: (String) -> Void = { _ in }
    @State private var onlyCurrentBranch = false
    @State private var showingSuperseded = false
    @State private var expanded: Set<String> = []

    private var branch: String? { onlyCurrentBranch && !session.branch.isEmpty ? session.branch : nil }
    private var runsByID: [Int64: CoreWorkflowRun] {
        Dictionary(session.runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }
    private var branchRuns: [CoreWorkflowRun] {
        guard let branch else { return session.runs }
        return session.runs.filter { $0.branch == branch }
    }
    private var pullRequests: [Int64: CoreChangePullRequest] { RunPresentation.pullRequests(session.changes) }
    /// Suggestions the user did not turn off.
    private var hints: [CoreConcurrencyHint] {
        session.concurrencyHints.filter { !(dismissals?.isDismissed($0.path, workspaceID: session.workspaceID) ?? false) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                header
                ActivityFreshnessLine(session: session).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 10)
                if let help = hub.pullRequestsHelp(workspaceID: session.workspaceID) {
                    GitHubAccessNotice(help: help, style: .note, github: github).padding(.horizontal, 12).padding(.bottom, 8)
                }
                DesignDivider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if let access = session.githubAccess,
                           let help = hub.accessHelp(access, workspaceID: session.workspaceID, purpose: .read, details: session.githubDetails) {
                            GitHubAccessNotice(help: help, style: .banner, github: github) {
                                Task { await hub.loadGitHubActivity(workspaceID: session.workspaceID) }
                            }.padding(8)
                        }
                        switch mode {
                        case .list: listRows
                        case .byChange: changeBlocks
                        }
                        OlderRunsFooter(session: session, hub: hub)
                    }.padding(6)
                }
            }
            .frame(width: 300)
            DesignDivider(vertical: true)
            inspector.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if selectedRunID == nil { selectedRunID = session.runs.first?.id } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Show runs", selection: $mode) {
                Text("List").tag(RunsMode.list)
                Text("By change").tag(RunsMode.byChange)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("List shows runs newest first; By change groups them by pull request and commit")
            Toggle(isOn: $onlyCurrentBranch) {
                Text(session.branch.isEmpty ? "Current branch" : session.branch).lineLimit(1)
            }.toggleStyle(.checkbox).disabled(session.branch.isEmpty)
            Spacer()
            Button {
                Task { await hub.loadGitHubActivity(workspaceID: session.workspaceID) }
            } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.borderless).disabled(session.isLoadingGitHub).help("Reload runs from GitHub")
        }
        .font(.system(size: 12)).padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
    }

    @ViewBuilder private var listRows: some View {
        let runs = RunPresentation.visible(branchRuns, showingSuperseded: showingSuperseded)
        ForEach(runs) { run in
            RunRow(run: run, selected: run.id == selectedRunID, pullRequest: run.link.pullRequest.flatMap { pullRequests[$0] },
                   newer: run.supersededBy.flatMap { runsByID[$0] })
                .onTapGesture { selectedRunID = run.id }
        }
        if runs.isEmpty && session.githubAccess == .ok {
            Text(onlyCurrentBranch ? "No runs on this branch." : "No runs yet.")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(12)
        }
        let hidden = RunPresentation.hiddenCount(branchRuns)
        if showingSuperseded || hidden > 0 {
            Button(showingSuperseded ? "Hide superseded runs" : "\(hidden) superseded \(hidden == 1 ? "run" : "runs") hidden · Show") {
                showingSuperseded.toggle()
            }
            .buttonStyle(.link).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 6)
            .help("Runs on older commits of a pull request that a newer push replaced")
        }
    }

    @ViewBuilder private var changeBlocks: some View {
        let changes = RunPresentation.changes(session.changes, runs: runsByID, branch: branch)
        ForEach(changes) { change in
            RunChangeBlock(change: change, runs: runsByID, selectedRunID: selectedRunID, expanded: $expanded,
                           hints: hints.filter { hint in change.pullRequest.map { hint.pullRequests.contains($0.number) } ?? false },
                           workflowName: workflowName, select: { selectedRunID = $0 },
                           addConcurrency: addConcurrency, dismissHint: dismissHint)
        }
        if changes.isEmpty && session.githubAccess == .ok {
            Text(onlyCurrentBranch ? "No runs on this branch." : "No runs yet.")
                .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(12)
        }
    }

    @ViewBuilder private var inspector: some View {
        if let run = session.runs.first(where: { $0.id == selectedRunID }) {
            RunInspectorView(run: run, workspaceID: session.workspaceID, hub: hub, github: github,
                             context: RunPresentation.context(for: run, runs: runsByID, pullRequests: pullRequests, hints: hints,
                                                              workflowName: workflowName(run.workflowID)),
                             select: { selectedRunID = $0 }, addConcurrency: addConcurrency, dismissHint: dismissHint)
                .id(run.id)
        } else {
            UnavailableFeature(title: "Select a run", detail: "Choose a run to see its jobs, steps and logs.", symbol: "play.circle")
                .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func workflowName(_ id: Int64) -> String {
        session.remoteWorkflows.first { $0.id == id }?.name ?? "this workflow"
    }

    private func dismissHint(_ path: String) {
        dismissals?.dismiss(path, workspaceID: session.workspaceID)
    }
}
```

In `RunInspectorView.swift`, add stored properties after `var github: GitHubSession? = nil`:

```swift
    /// Its pull request, the run that superseded it and a suggestion.
    let context: RunInspectorContext
    let select: (Int64) -> Void
    let addConcurrency: (String) -> Void
    let dismissHint: (String) -> Void
```

replace the initializer:

```swift
    init(run: CoreWorkflowRun, workspaceID: UUID, hub: CoreHub, github: GitHubSession? = nil,
         context: RunInspectorContext = RunInspectorContext(), select: @escaping (Int64) -> Void = { _ in },
         addConcurrency: @escaping (String) -> Void = { _ in }, dismissHint: @escaping (String) -> Void = { _ in }) {
        self.run = run
        self.workspaceID = workspaceID
        self.hub = hub
        self.github = github
        self.context = context
        self.select = select
        self.addConcurrency = addConcurrency
        self.dismissHint = dismissHint
        _actions = State(initialValue: RunActionModel(hub: hub, workspaceID: workspaceID))
    }
```

in `body`, after `summary` add `links`, and add:

```swift
    // MARK: Pull request and commit

    private var links: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let pullRequest = context.pullRequest {
                Button {
                    if let url = pullRequest.htmlURL { openURL(url) }
                } label: {
                    Label(RunPresentation.pullRequestLine(pullRequest), systemImage: "arrow.triangle.pull").lineLimit(1)
                }
                .buttonStyle(.link).disabled(pullRequest.htmlURL == nil).help("Open the pull request on GitHub")
            }
            Label(RunPresentation.commitLine(run), systemImage: "smallcircle.filled.circle")
                .foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
            if let newer = context.supersededBy {
                Button("Superseded by \(newer.name) #\(newer.runNumber) on a newer commit") { select(newer.id) }
                    .buttonStyle(.link).help("Show the run that replaced this one")
            }
            if run.isSuperseded, let hint = context.hint {
                ConcurrencyHintBanner(hint: hint, workflowName: context.workflowName,
                                      add: { addConcurrency(hint.path) }, dismiss: { dismissHint(hint.path) })
                    .padding(.top, 4)
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20).padding(.bottom, 8)
    }
```

In `OverviewViews.swift` `latestRunSummary`, replace `Text("run #\(run.runNumber) · \(String(run.headSHA.prefix(7)))")` with `Text(RunPresentation.summary(run))` (same modifiers).

- [ ] **Step 5: Build, test and look**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build` and `… test -only-testing:RunnirTests`
Expected: BUILD SUCCEEDED; all RunnirTests pass.

Then run the app (the `run` skill) against a repository with pull requests, or the fake Enterprise server used for the B27 live check, and compare the Runs section, the inspector, the banner and the editor insertion with the Task 1 frames. Record what was checked and what was not in the PR description; do not claim a real-GitHub check that was not done.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Runnir apps/macos/RunnirTests/DesktopStateTests.swift
git commit -m "App: runs by change, superseded runs, links in the inspector and lazy loading"
```

---

### Task 15: Documentation and full verification

**Files:**
- Modify: `docs/architecture/grpc-api.md`, `docs/architecture/workspace-persistence.md`, `docs/security/github-authentication.md:23`, `docs/design/screens-and-states.md` (S07), `docs/product/mvp-implementation-checklist.md`, `docs/superpowers/specs/2026-10-22-workspace-cache-design.md` (status line), `docs/superpowers/specs/2026-10-23-run-change-links-design.md` (status line)

- [ ] **Step 1: Update the documents**

- `grpc-api.md`: add `LoadOlderRuns` and `InsertWorkflowConcurrency` to the RPC list (one line each, as in the proto comments); in the workspace activity part, the limit is 1–5000 with 0 meaning 200, and `WorkspaceActivity` carries `changes`, `concurrency_hints`, `cached_runs`, `history_complete`; `ActivityFreshness.pull_requests_access`; `WorkflowRun` fields 16–19 are set in workspace activity only.
- `workspace-persistence.md`: the cache keeps up to 5000 runs, pull requests (named ones plus the 500 most recently updated) and lookup answers; it is one unbroken stretch of history that lazy loading extends; the schema changes in place before the first release.
- `github-authentication.md:23`: add "Pull requests read-only (link runs to pull requests, merges and forks)" to the repository permissions; note that the app on github.com has it since 2026-10-23 and installations accept it.
- `screens-and-states.md`, S07 Runs browser: List and By change, superseded runs hidden with a reveal row, outdated label, pull request and commit lines in the inspector, the concurrency banner, the pull-requests-unreadable note, loading older runs and the end of the kept history.
- `mvp-implementation-checklist.md`: a B30 row in the progress table ("Runs linked to pull requests and commits: links after merge and from forks, superseded runs hidden, By change, 5000 runs with lazy loading, concurrency suggestion inserted in the editor" / evidence still needed: "A live check on a real pull request with pushes, a merge and a manual run"); in the B26 row, 200 runs becomes 5000.
- B26/B27 spec status line: append "The run budget became 5000 in B30 ([spec](2026-10-23-run-change-links-design.md))."
- B30 spec status line: "Status: design approved on 2026-10-23; implemented on <date> ([plan](../plans/2026-10-23-run-change-links.md))." with the adjustments listed under "Spec Adjustments Made While Planning".

- [ ] **Step 2: Run everything**

From `core/`:

```bash
go test ./... && go vet ./... && CGO_ENABLED=0 go build ./...
```

From the repository root:

```bash
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests
```

Expected: all pass. Report failures with their output; do not hand off with failing checks.

- [ ] **Step 3: Commit**

```bash
git add docs
git commit -m "Docs: runs linked to commits and pull requests (B30)"
```

- [ ] **Step 4: PR description notes (when the user asks for a PR)**

Include: what changed for the user; the schema changed in place, so development databases need `~/Library/Application Support/Runnir/repositories/*/state.sqlite*` deleted once (local run history comes back from the backup); the GitHub App permission; what was verified (tests, build, the manual check from Task 14) and what was not (a live check on github.com, the concurrency block's effect on a real repository). No AI attribution.

---

## Self-Review Notes

- Spec coverage: links and the four rules (Task 6), superseded and overlap (Task 6), changes, sections, repeats, unknown pull requests (Task 7), lookups (Tasks 7–8), pull request list with ETag and refusals (Tasks 3, 5, 8), default branch (Tasks 4, 8), gap filling and restart (Tasks 4, 8), `LoadOlderRuns` and the 5000 budget (Tasks 4, 5, 8, 10, 11, 14), pull request and lookup budgets (Task 5), Clear Cache (Tasks 4–5), concurrency detection, hint conditions and insertion (Tasks 7, 9, 10, 13), contract (Task 10), the app's List and By change, hidden runs, outdated label, inspector lines, banner, permission note, lazy loading, Overview (Tasks 11–14), the permission (Tasks 2, 12), design (Task 1), docs (Task 15).
- Names used across tasks: `store.MaxRuns`, `store.Tags`, `store.PullRequestsUpdate.Refused`, `store.LookupsUpdate`, `store.History`, `changes.Analyze/Group/Missing/Hints`, `workspace.OlderRuns`, `CoreHub.showMoreRuns`, `CoreHub.activityPage`, `OlderRunsState`, `RunPresentation`, `RunInspectorContext`, `ConcurrencyHintDismissals`, `CodeEditorEdit`, `RunsMode`.
- Risk: the store's single connection — `runs()` reads links only after the runs' rows are closed (Task 4). `trimLinks` runs inside the same transaction as the writes.
- Risk: actionlint on the block (Task 9 Step 4 says to stop and report rather than change the block).
- Order with B25: B25 also changes the proto, `grpc-api.md` and `OverviewViews.swift`. Start this plan from `main` after B25 is merged (one open PR at a time).
