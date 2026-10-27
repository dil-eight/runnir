//go:build !windows

package server

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
)

// searchGitHub serves 250 runs of o/r, newest first, one a minute apart.
// Every 50th is titled "Deploy N", the others "Build N". Runs in `gone` are
// no longer served, as when GitHub deletes them.
type searchGitHub struct {
	mu      sync.Mutex
	gone    map[int]bool
	queries []string
}

var searchEpoch = time.Date(2026, 3, 1, 12, 0, 0, 0, time.UTC)

func searchTitle(id int) string {
	if id%50 == 0 {
		return fmt.Sprintf("Deploy %d", id)
	}
	return fmt.Sprintf("Build %d", id)
}

func (f *searchGitHub) server(t *testing.T) *httptest.Server {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/o/r/actions/runs":
			f.mu.Lock()
			defer f.mu.Unlock()
			f.queries = append(f.queries, r.URL.RawQuery)
			upper := time.Date(2100, 1, 1, 0, 0, 0, 0, time.UTC)
			if created := r.URL.Query().Get("created"); strings.HasPrefix(created, "<=") {
				upper, _ = time.Parse("2006-01-02T15:04:05Z", strings.TrimPrefix(created, "<="))
			}
			var items []string
			for id := 250; id >= 1 && len(items) < 100; id-- {
				at := searchEpoch.Add(time.Duration(id) * time.Minute)
				if f.gone[id] || at.After(upper) {
					continue
				}
				stamp := at.Format("2006-01-02T15:04:05Z")
				items = append(items, fmt.Sprintf(`{"id":%d,"workflow_id":3,"name":"CI","display_title":%q,"run_number":%d,"run_attempt":1,"event":"push",
"status":"completed","conclusion":"success","head_branch":"main","head_sha":"abc","created_at":%q,"updated_at":%q}`,
					id, searchTitle(id), id, stamp, stamp))
			}
			_, _ = w.Write([]byte(`{"workflow_runs":[` + strings.Join(items, ",") + `]}`))
		case "/repos/o/r":
			_, _ = w.Write([]byte(`{"full_name":"o/r","default_branch":"main"}`))
		case "/repos/o/r/pulls":
			_, _ = w.Write([]byte(`[]`))
		case "/repos/o/r/actions/workflows":
			_, _ = w.Write([]byte(`{"total_count":1,"workflows":[{"id":3,"name":"CI","path":".github/workflows/ci.yml","state":"active"}]}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)
	return server
}

func ids(runs []*corev1.WorkflowRun) []int64 {
	out := make([]int64, len(runs))
	for i, r := range runs {
		out[i] = r.Id
	}
	return out
}

func TestSearchFindsRunsBeyondTheCacheAndKeepsWhatGitHubDeleted(t *testing.T) {
	fake := &searchGitHub{gone: map[int]bool{}}
	server := fake.server(t)
	client, stop, ctx := workspaceRig(t, t.TempDir(), server.URL)
	defer stop()
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.com:o/r.git"), WorkspaceId: testWorkspace})
	if err != nil {
		t.Fatal(err)
	}
	id := opened.Repository.Id
	if _, err := client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: id, Wait: true}); err != nil {
		t.Fatal(err)
	}

	// The cache holds the newest 100 runs (151..250): two Deploys among them.
	saved, err := client.SearchRuns(ctx, &corev1.SearchRunsRequest{RepositoryId: id, Query: "deploy"})
	if err != nil || len(saved.CachedRunIds) != 2 || saved.CachedRunIds[0] != 250 || len(saved.IndexedRuns) != 0 || saved.CachedSearched != 100 {
		t.Fatalf("saved = %v, %v", saved, err)
	}

	// A deep search reads pages by creation time: one page, then the rest.
	first, err := client.SearchRunsOnGitHub(ctx, &corev1.SearchRunsOnGitHubRequest{RepositoryId: id, Query: "deploy", Pages: 1})
	if err != nil || first.Stop != corev1.SearchStop_SEARCH_STOP_BUDGET || first.NextCursor == nil || len(first.Runs) != 2 || first.Pages != 1 {
		t.Fatalf("first step = %v, %v", first, err)
	}
	rest, err := client.SearchRunsOnGitHub(ctx, &corev1.SearchRunsOnGitHubRequest{RepositoryId: id, Query: "deploy", Cursor: first.NextCursor})
	if err != nil || rest.Stop != corev1.SearchStop_SEARCH_STOP_DONE || rest.NextCursor != nil {
		t.Fatalf("rest = %v, %v", rest, err)
	}
	found := ids(rest.Runs)
	if len(found) < 3 || found[len(found)-1] != 50 {
		t.Fatalf("the deploys beyond the cache = %v", found)
	}

	// What it read is indexed: the same search now finds the old runs offline.
	again, err := client.SearchRuns(ctx, &corev1.SearchRunsRequest{RepositoryId: id, Query: "deploy"})
	if err != nil || len(again.CachedRunIds) != 2 || len(again.IndexedRuns) != 3 || again.IndexedRuns[0].Id != 150 {
		t.Fatalf("after the deep search = %v, %v", again, err)
	}

	// Qualifiers and a bad one.
	byStatus, err := client.SearchRuns(ctx, &corev1.SearchRunsRequest{RepositoryId: id, Query: "status:failed after:soon"})
	if err != nil || len(byStatus.CachedRunIds) != 0 || len(byStatus.Problems) != 1 {
		t.Fatalf("qualifiers = %v, %v", byStatus, err)
	}

	// GitHub deletes the newest run; the cache drops it on the next pass and the index keeps it.
	fake.mu.Lock()
	fake.gone[250] = true
	fake.mu.Unlock()
	if _, err := client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: id, Wait: true}); err != nil {
		t.Fatal(err)
	}
	gone, err := client.SearchRuns(ctx, &corev1.SearchRunsRequest{RepositoryId: id, Query: "deploy 250"})
	if err != nil || len(gone.CachedRunIds) != 0 || len(gone.IndexedRuns) != 1 || gone.IndexedRuns[0].Id != 250 {
		t.Fatalf("a deleted run = %v, %v", gone, err)
	}

	// Clear Cache keeps the index; Clear Run Index empties it.
	if _, err := client.ClearWorkspaceCache(ctx, &corev1.ClearWorkspaceCacheRequest{WorkspaceIds: []string{testWorkspace}}); err != nil {
		t.Fatal(err)
	}
	// The cleared cache fills again from GitHub; let that pass finish.
	if _, err := client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: id, Wait: true}); err != nil {
		t.Fatal(err)
	}
	kept, err := client.SearchRuns(ctx, &corev1.SearchRunsRequest{RepositoryId: id, Query: "deploy 250"})
	if err != nil || len(kept.IndexedRuns) != 1 {
		t.Fatalf("after Clear Cache = %v, %v", kept, err)
	}
	cleared, err := client.ClearRunIndex(ctx, &corev1.ClearRunIndexRequest{WorkspaceIds: []string{testWorkspace}})
	if err != nil || len(cleared.Workspaces) != 1 || cleared.Workspaces[0].IndexedRuns != 0 {
		t.Fatalf("clearing = %v, %v", cleared, err)
	}
}

func TestADeepSearchNeedsAQuery(t *testing.T) {
	fake := &searchGitHub{gone: map[int]bool{}}
	server := fake.server(t)
	client, stop, ctx := workspaceRig(t, t.TempDir(), server.URL)
	defer stop()
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.com:o/r.git"), WorkspaceId: testWorkspace})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.SearchRunsOnGitHub(ctx, &corev1.SearchRunsOnGitHubRequest{RepositoryId: opened.Repository.Id, Query: "  "}); err == nil {
		t.Fatal("an empty query would read the whole history")
	}
}

func TestEveryRunSaysWhichOfTheSixStatusesItCountsAs(t *testing.T) {
	cases := map[[2]string]corev1.RunStatusGroup{
		{"completed", "success"}:         corev1.RunStatusGroup_RUN_STATUS_GROUP_SUCCESS,
		{"completed", "timed_out"}:       corev1.RunStatusGroup_RUN_STATUS_GROUP_FAILED,
		{"completed", "startup_failure"}: corev1.RunStatusGroup_RUN_STATUS_GROUP_FAILED,
		{"completed", "cancelled"}:       corev1.RunStatusGroup_RUN_STATUS_GROUP_CANCELLED,
		{"in_progress", ""}:              corev1.RunStatusGroup_RUN_STATUS_GROUP_RUNNING,
		{"waiting", ""}:                  corev1.RunStatusGroup_RUN_STATUS_GROUP_QUEUED,
		{"completed", "action_required"}: corev1.RunStatusGroup_RUN_STATUS_GROUP_QUEUED,
		{"completed", "neutral"}:         corev1.RunStatusGroup_RUN_STATUS_GROUP_SKIPPED,
	}
	for pair, want := range cases {
		if got := runMessage(github.Run{Status: pair[0], Conclusion: pair[1]}).StatusGroup; got != want {
			t.Errorf("%s/%s = %v, want %v", pair[0], pair[1], got, want)
		}
	}
}

func TestSearchWorkspacesAnswersFromTheSavedDataOfEveryWorkspace(t *testing.T) {
	fake := &searchGitHub{gone: map[int]bool{}}
	server := fake.server(t)
	client, stop, ctx := workspaceRig(t, t.TempDir(), server.URL)
	defer stop()
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.com:o/r.git"), WorkspaceId: testWorkspace})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: opened.Repository.Id, Wait: true}); err != nil {
		t.Fatal(err)
	}

	got, err := client.SearchWorkspaces(ctx, &corev1.SearchWorkspacesRequest{Query: "deploy status:success after:soon", WorkspaceIds: []string{testWorkspace}, LimitPerKind: 1})
	if err != nil || len(got.Workspaces) != 1 || len(got.Problems) != 1 || len(got.Words) != 1 || got.Words[0] != "deploy" {
		t.Fatalf("got = %v, %v", got, err)
	}
	hits := got.Workspaces[0]
	if !strings.EqualFold(hits.WorkspaceId, testWorkspace) || !hits.Open || hits.Repository != "o/r" || hits.SavedAt == nil {
		t.Fatalf("hits = %v", hits)
	}
	if hits.RunsMatched != 2 || len(hits.Runs) != 1 || hits.Runs[0].Id != 250 || hits.Runs[0].StatusGroup != corev1.RunStatusGroup_RUN_STATUS_GROUP_SUCCESS {
		t.Fatalf("runs = %v of %d", ids(hits.Runs), hits.RunsMatched)
	}

	byName, err := client.SearchWorkspaces(ctx, &corev1.SearchWorkspacesRequest{Query: "ci"})
	if err != nil {
		t.Fatal(err)
	}
	var workflows []string
	for _, w := range byName.Workspaces {
		for _, wf := range w.Workflows {
			workflows = append(workflows, wf.Path)
		}
	}
	if len(workflows) != 1 || workflows[0] != ".github/workflows/ci.yml" {
		t.Fatalf("workflows = %v", workflows)
	}
	if _, err := client.SearchWorkspaces(ctx, &corev1.SearchWorkspacesRequest{Query: "x", WorkspaceIds: []string{"not-an-id"}}); err == nil {
		t.Fatal("an invalid workspace id is refused")
	}
}
