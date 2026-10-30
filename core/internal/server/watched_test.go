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
