//go:build !windows

package server

import (
	"context"
	"net/http"
	"net/http/httptest"
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
}

func (c *countingGitHub) server(t *testing.T) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/o/r/actions/runs":
			c.runs.Add(1)
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
	if _, err := client.GetWorkspaceActivity(ctx, &corev1.GetWorkspaceActivityRequest{RepositoryId: plain.Repository.Id, Limit: 201}); status.Code(err) != codes.InvalidArgument {
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
