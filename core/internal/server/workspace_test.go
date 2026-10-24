//go:build !windows

package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

const testWorkspace = "5CE88FF0-5C16-43B3-8F20-8E33E852B019"

type countingGitHub struct {
	runs, jobs atomic.Int64
	// hold, when set, keeps the next runs request waiting until it is closed.
	hold atomic.Pointer[chan struct{}]
}

func (c *countingGitHub) server(t *testing.T) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/o/r/actions/runs":
			c.runs.Add(1)
			if gate := c.hold.Swap(nil); gate != nil {
				<-*gate
			}
			if r.Header.Get("If-None-Match") == `"v1"` {
				w.WriteHeader(http.StatusNotModified)
				return
			}
			w.Header().Set("ETag", `"v1"`)
			_, _ = w.Write([]byte(`{"workflow_runs":[{"id":7,"workflow_id":3,"name":"CI","run_number":12,"run_attempt":1,"event":"push","status":"completed","conclusion":"success","head_branch":"main","created_at":"2026-10-18T10:00:00Z","updated_at":"2026-10-18T10:04:00Z"}]}`))
		case "/repos/o/r":
			_, _ = w.Write([]byte(`{"full_name":"o/r","default_branch":"main"}`))
		case "/repos/o/r/pulls":
			_, _ = w.Write([]byte(`[]`))
		case "/repos/o/r/actions/workflows":
			_, _ = w.Write([]byte(`{"total_count":1,"workflows":[{"id":3,"name":"CI","path":".github/workflows/ci.yml","state":"active"}]}`))
		case "/repos/o/r/actions/runs/7/jobs":
			c.jobs.Add(1)
			_, _ = w.Write([]byte(`{"jobs":[{"id":1,"name":"build","status":"completed","conclusion":"success","steps":[]}]}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)
	return server
}

func workspaceRig(t *testing.T, data, githubURL string) (corev1.RunnirCoreClient, func() error, context.Context) {
	t.Helper()
	path := socketPath(t)
	stop := startWith(t, path, Options{GitHubBaseURL: githubURL, DataDir: data})
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	t.Cleanup(cancel)
	if _, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghu_test"}); err != nil {
		t.Fatal(err)
	}
	return client, stop, ctx
}

func TestWindowsOfOneWorkspaceShareOneSync(t *testing.T) {
	counts := &countingGitHub{}
	fake := counts.server(t)
	client, stop, ctx := workspaceRig(t, t.TempDir(), fake.URL)
	defer stop()
	repo := linkedRepository(t, "git@github.com:o/r.git")
	first, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo, WorkspaceId: testWorkspace})
	if err != nil {
		t.Fatal(err)
	}
	second, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo, WorkspaceId: testWorkspace})
	if err != nil || second.Repository.Id != first.Repository.Id {
		t.Fatalf("second window = %v, %v", second, err)
	}
	id := first.Repository.Id
	activity, err := client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: id, Wait: true})
	if err != nil || len(activity.Runs) != 1 || activity.Freshness.Source != corev1.ActivitySource_ACTIVITY_SOURCE_LIVE ||
		activity.Freshness.Status.GetAccess() != corev1.GithubAccess_GITHUB_ACCESS_OK {
		t.Fatalf("activity = %v, %v", activity, err)
	}
	before := counts.runs.Load()
	gate := make(chan struct{})
	counts.hold.Store(&gate)
	var wg sync.WaitGroup
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: id, Wait: true}); err != nil {
				t.Error(err)
			}
		}()
	}
	// The first request starts a pass, which waits at GitHub while the other
	// windows ask; without the wait a slow machine lets a late request find
	// the next pass already started, which rightly needs a third.
	for deadline := time.Now().Add(5 * time.Second); counts.runs.Load() == before && time.Now().Before(deadline); {
		time.Sleep(5 * time.Millisecond)
	}
	time.Sleep(300 * time.Millisecond)
	close(gate)
	wg.Wait()
	if added := counts.runs.Load() - before; added < 1 || added > 2 {
		t.Fatalf("six windows refreshing made %d runs requests", added)
	}
	for i := 0; i < 3; i++ {
		jobs, err := client.ListRunJobs(ctx, &corev1.ListRunJobsRequest{RepositoryId: id, RunId: 7})
		if err != nil || len(jobs.Jobs) != 1 {
			t.Fatalf("jobs = %v, %v", jobs, err)
		}
	}
	if counts.jobs.Load() != 1 {
		t.Fatalf("jobs requests = %d", counts.jobs.Load())
	}
}

func TestCachedActivityIsShownAfterARestartWithoutGitHub(t *testing.T) {
	counts := &countingGitHub{}
	fake := counts.server(t)
	data := t.TempDir()
	repo := linkedRepository(t, "git@github.com:o/r.git")
	client, stop, ctx := workspaceRig(t, data, fake.URL)
	opened, _ := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo, WorkspaceId: testWorkspace})
	if _, err := client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: opened.Repository.Id, Wait: true}); err != nil {
		t.Fatal(err)
	}
	if err := stop(); err != nil {
		t.Fatal(err)
	}

	offline, stopOffline, ctx := workspaceRig(t, data, "http://127.0.0.1:1")
	defer stopOffline()
	reopened, err := offline.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo, WorkspaceId: testWorkspace})
	if err != nil {
		t.Fatal(err)
	}
	activity, err := offline.GetWorkspaceActivity(ctx, &corev1.GetWorkspaceActivityRequest{RepositoryId: reopened.Repository.Id})
	if err != nil || len(activity.Runs) != 1 || len(activity.Workflows) != 1 || activity.Freshness.Source != corev1.ActivitySource_ACTIVITY_SOURCE_CACHE {
		t.Fatalf("cached = %v, %v", activity, err)
	}
	after, err := offline.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: reopened.Repository.Id, Wait: true})
	if err != nil || len(after.Runs) != 1 || after.Freshness.Status.GetAccess() != corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE {
		t.Fatalf("offline refresh = %v, %v", after, err)
	}
}

func TestStorageCallsOverGRPC(t *testing.T) {
	counts := &countingGitHub{}
	fake := counts.server(t)
	client, stop, ctx := workspaceRig(t, t.TempDir(), fake.URL)
	defer stop()
	opened, _ := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.com:o/r.git"), WorkspaceId: testWorkspace})
	id := opened.Repository.Id
	_, _ = client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: id, Wait: true})

	usage, err := client.GetStorageUsage(ctx, &corev1.GetStorageUsageRequest{})
	if err != nil || len(usage.Workspaces) != 1 || usage.Workspaces[0].CachedRuns != 1 || !usage.Workspaces[0].Open ||
		usage.Workspaces[0].State != corev1.StorageState_STORAGE_STATE_PERSISTENT || usage.Workspaces[0].WorkspaceId != "5ce88ff0-5c16-43b3-8f20-8e33e852b019" {
		t.Fatalf("usage = %v, %v", usage, err)
	}
	if _, err := client.SetStoragePreferences(ctx, &corev1.SetStoragePreferencesRequest{KeepJobLogs: true}); err != nil {
		t.Fatal(err)
	}
	if usage, _ := client.GetStorageUsage(ctx, &corev1.GetStorageUsageRequest{}); !usage.KeepJobLogs {
		t.Fatal("preference not kept")
	}
	if _, err := client.ClearWorkspaceCache(ctx, &corev1.ClearWorkspaceCacheRequest{WorkspaceIds: []string{testWorkspace}}); err != nil {
		t.Fatal(err)
	}
	_, err = client.DeleteWorkspaceData(ctx, &corev1.DeleteWorkspaceDataRequest{WorkspaceId: testWorkspace})
	if status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("delete while open = %v", err)
	}
	if _, err := client.CloseRepository(ctx, &corev1.CloseRepositoryRequest{RepositoryId: id}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.DeleteWorkspaceData(ctx, &corev1.DeleteWorkspaceDataRequest{WorkspaceId: testWorkspace}); err != nil {
		t.Fatal(err)
	}
	if usage, _ := client.GetStorageUsage(ctx, &corev1.GetStorageUsageRequest{}); len(usage.Workspaces) != 0 {
		t.Fatalf("after delete = %v", usage)
	}
}

func TestWorkspaceIDsAreChecked(t *testing.T) {
	client, stop, ctx := workspaceRig(t, t.TempDir(), "http://127.0.0.1:1")
	defer stop()
	repo := linkedRepository(t, "git@github.com:o/r.git")
	if _, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo, WorkspaceId: "../x"}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("bad id = %v", err)
	}
	plain, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.GetWorkspaceActivity(ctx, &corev1.GetWorkspaceActivityRequest{RepositoryId: plain.Repository.Id}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("no workspace = %v", err)
	}
	if _, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo, WorkspaceId: testWorkspace}); err != nil {
		t.Fatal(err)
	}
	other := "6ce88ff0-5c16-43b3-8f20-8e33e852b019"
	if _, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repo, WorkspaceId: other}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("other workspace = %v", err)
	}
	if _, err := client.GetWorkspaceActivity(ctx, &corev1.GetWorkspaceActivityRequest{RepositoryId: plain.Repository.Id, Limit: 5001}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("limit = %v", err)
	}
}

func TestWithoutADataDirWorkspacesStayInMemory(t *testing.T) {
	client, stop, ctx := workspaceRig(t, "", "http://127.0.0.1:1")
	defer stop()
	_, _ = client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.com:o/r.git"), WorkspaceId: testWorkspace})
	usage, err := client.GetStorageUsage(ctx, &corev1.GetStorageUsageRequest{})
	if err != nil || len(usage.Workspaces) != 1 || usage.Workspaces[0].State != corev1.StorageState_STORAGE_STATE_MEMORY_ONLY {
		t.Fatalf("usage = %v, %v", usage, err)
	}
}

func TestActivityChangesAreAnnounced(t *testing.T) {
	counts := &countingGitHub{}
	fake := counts.server(t)
	client, stop, ctx := workspaceRig(t, t.TempDir(), fake.URL)
	defer stop()
	stream, err := client.SubscribeEvents(ctx, &corev1.SubscribeEventsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	next(t, stream) // CORE_READY
	opened, _ := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.com:o/r.git"), WorkspaceId: testWorkspace})
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		e := next(t, stream)
		if e.Type == corev1.CoreEventType_CORE_EVENT_TYPE_ACTIVITY_CHANGED && e.RepositoryId == opened.Repository.Id {
			return
		}
	}
	t.Fatal("no ACTIVITY_CHANGED event")
}

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
