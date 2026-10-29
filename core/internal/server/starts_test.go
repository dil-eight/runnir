//go:build !windows

package server

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/store"
)

// startsGitHub serves o/r with two runs of Deploy:
//   - 21, failed, in its attempt `attempt`;
//   - 22, which a dispatch starts.
//
// It accepts the dispatch, naming run 22, and re-runs of run 21. Each
// re-run starts the next attempt; refuse makes GitHub refuse them. gone
// stops serving run 21, as when GitHub deletes it.
type startsGitHub struct {
	mu           sync.Mutex
	attempt      int64
	refuse, gone bool
}

var startsCreated = time.Date(2026, 10, 28, 10, 0, 0, 0, time.UTC)

func (f *startsGitHub) set(change func()) {
	f.mu.Lock()
	defer f.mu.Unlock()
	change()
}

func (f *startsGitHub) server(t *testing.T) *httptest.Server {
	t.Helper()
	run := func(id, attempt int64) string {
		stamp := startsCreated.Format(time.RFC3339)
		return fmt.Sprintf(`{"id":%d,"workflow_id":7,"name":"Deploy","display_title":"Deploy %d","run_number":%d,"run_attempt":%d,"event":"workflow_dispatch",
"status":"completed","conclusion":"failure","head_branch":"main","head_sha":"abc","created_at":%q,"updated_at":%q}`, id, id, id, attempt, stamp, stamp)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		switch {
		case r.URL.Path == "/repos/o/r":
			_, _ = w.Write([]byte(`{"full_name":"o/r","default_branch":"main"}`))
		case r.URL.Path == "/repos/o/r/pulls":
			_, _ = w.Write([]byte(`[]`))
		case r.URL.Path == "/repos/o/r/actions/workflows":
			_, _ = w.Write([]byte(`{"total_count":1,"workflows":[{"id":7,"name":"Deploy","path":".github/workflows/deploy.yml","state":"active"}]}`))
		case r.URL.Path == "/repos/o/r/actions/workflows/7":
			_, _ = w.Write([]byte(`{"id":7,"path":".github/workflows/deploy.yml"}`))
		case r.URL.Path == "/repos/o/r/contents/.github/workflows/deploy.yml":
			_, _ = w.Write([]byte(deployWorkflow))
		case r.URL.Path == "/repos/o/r/actions/workflows/7/dispatches" && r.Method == http.MethodPost:
			_, _ = w.Write([]byte(`{"workflow_run_id":22}`))
		case r.URL.Path == "/repos/o/r/actions/runs":
			items := []string{run(22, 1)}
			if !f.gone {
				items = append(items, run(21, f.attempt))
			}
			_, _ = w.Write([]byte(`{"total_count":` + strconv.Itoa(len(items)) + `,"workflow_runs":[` + strings.Join(items, ",") + `]}`))
		case r.URL.Path == "/repos/o/r/actions/runs/21" && r.Method == http.MethodGet && !f.gone:
			_, _ = w.Write([]byte(run(21, f.attempt)))
		case r.URL.Path == "/repos/o/r/actions/jobs/11" && r.Method == http.MethodGet:
			_, _ = w.Write([]byte(`{"id":11,"run_id":21,"name":"build","status":"completed","conclusion":"failure","steps":[]}`))
		case r.Method == http.MethodPost && (r.URL.Path == "/repos/o/r/actions/runs/21/rerun" ||
			r.URL.Path == "/repos/o/r/actions/runs/21/rerun-failed-jobs" || r.URL.Path == "/repos/o/r/actions/jobs/11/rerun"):
			if f.refuse {
				w.WriteHeader(http.StatusForbidden)
				_, _ = w.Write([]byte(`{"message":"Unable to re-run this workflow run because it was created over a month ago"}`))
				return
			}
			f.attempt++
			w.WriteHeader(http.StatusCreated)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)
	return server
}

// startsText is "1:RUNNIR_START_KIND_DISPATCH 2:…", the starts of a run.
func startsText(run *corev1.WorkflowRun) string {
	var parts []string
	for _, s := range run.GetRunnirStarts() {
		parts = append(parts, fmt.Sprintf("%d:%s", s.GetAttempt(), s.GetKind()))
	}
	return strings.Join(parts, " ")
}

func TestAttemptsRunnirStartedAreMarkedOnTheRunsOfTheWorkspace(t *testing.T) {
	fake := &startsGitHub{attempt: 1}
	server := fake.server(t)
	client, stop, ctx := workspaceRig(t, t.TempDir(), server.URL)
	defer stop()
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.com:o/r.git"), WorkspaceId: testWorkspace})
	if err != nil {
		t.Fatal(err)
	}
	id := opened.Repository.Id
	refresh := func() {
		t.Helper()
		if _, err := client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: id, Wait: true}); err != nil {
			t.Fatal(err)
		}
	}
	act := func(action corev1.RunAction, jobID int64) *corev1.ConfirmRunActionResponse {
		t.Helper()
		prepared, err := client.PrepareRunAction(ctx, &corev1.PrepareRunActionRequest{RepositoryId: id, RunId: 21, Action: action, JobId: jobID})
		if err != nil || prepared.ActionId == "" {
			t.Fatalf("prepare %v = %v, %v", action, prepared, err)
		}
		confirmed, err := client.ConfirmRunAction(ctx, &corev1.ConfirmRunActionRequest{ActionId: prepared.ActionId})
		if err != nil {
			t.Fatal(err)
		}
		return confirmed
	}
	refresh()

	if sent := sendDispatch(t, client, ctx, id, "main", map[string]string{"environment": "staging"}); sent.RunId != 22 {
		t.Fatalf("dispatch = %v", sent)
	}
	act(corev1.RunAction_RUN_ACTION_RERUN_FAILED, 0) // attempt 1 reviewed: attempt 2 is Runnir's
	act(corev1.RunAction_RUN_ACTION_RERUN_JOB, 11)   // attempt 2 reviewed: attempt 3 is Runnir's
	fake.set(func() { fake.refuse = true })
	if refused := act(corev1.RunAction_RUN_ACTION_RERUN, 0); refused.Rejection == "" {
		t.Fatalf("refused = %v", refused)
	}
	refresh()

	want := map[int64]string{
		22: "1:RUNNIR_START_KIND_DISPATCH",
		21: "2:RUNNIR_START_KIND_RERUN_FAILED 3:RUNNIR_START_KIND_RERUN_JOB",
	}
	activity, err := client.GetWorkspaceActivity(ctx, &corev1.GetWorkspaceActivityRequest{RepositoryId: id})
	if err != nil || len(activity.Runs) != 2 {
		t.Fatalf("activity = %v, %v", activity, err)
	}
	for _, run := range activity.Runs {
		if got := startsText(run); got != want[run.Id] {
			t.Fatalf("activity run %d = %q, want %q", run.Id, got, want[run.Id])
		}
	}

	deep, err := client.SearchRunsOnGitHub(ctx, &corev1.SearchRunsOnGitHubRequest{RepositoryId: id, Query: "deploy"})
	if err != nil || len(deep.Runs) != 2 {
		t.Fatalf("deep search = %v, %v", deep, err)
	}
	for _, run := range deep.Runs {
		if got := startsText(run); got != want[run.Id] {
			t.Fatalf("found on GitHub %d = %q, want %q", run.Id, got, want[run.Id])
		}
	}

	// GitHub deletes run 21: the cache drops it and the search index keeps it, with its marks.
	fake.set(func() { fake.gone = true })
	refresh()
	indexed, err := client.SearchRuns(ctx, &corev1.SearchRunsRequest{RepositoryId: id, Query: "deploy 21"})
	if err != nil || len(indexed.IndexedRuns) != 1 || startsText(indexed.IndexedRuns[0]) != want[21] {
		t.Fatalf("indexed = %v, %v", indexed, err)
	}
}

func TestRunsCarryTheAttemptsRunnirStartedUpToTheirOwn(t *testing.T) {
	at := time.Date(2026, 10, 28, 10, 0, 0, 0, time.UTC)
	runs := []*corev1.WorkflowRun{{Id: 21, RunAttempt: 2}, {Id: 22}, {Id: 23, RunAttempt: 1}}
	withStarts(runs, map[int64][]store.RunStart{
		21: {
			{RunID: 21, Attempt: 1, Kind: store.StartDispatch, SentAt: at},
			{RunID: 21, Attempt: 2, Kind: store.StartRerunFailed, SentAt: at},
			// Recorded before GitHub reports attempt 3: it waits.
			{RunID: 21, Attempt: 3, Kind: store.StartRerun, SentAt: at},
		},
		22: {{RunID: 22, Attempt: 1, Kind: store.StartDispatch, SentAt: at}},
	})
	if got := startsText(runs[0]); got != "1:RUNNIR_START_KIND_DISPATCH 2:RUNNIR_START_KIND_RERUN_FAILED" ||
		!runs[0].GetRunnirStarts()[1].GetSentAt().AsTime().Equal(at) {
		t.Fatalf("run 21 = %v", runs[0].GetRunnirStarts())
	}
	// A run that does not say its attempt is in its first.
	if got := startsText(runs[1]); got != "1:RUNNIR_START_KIND_DISPATCH" {
		t.Fatalf("run 22 = %q", got)
	}
	if len(runs[2].GetRunnirStarts()) != 0 {
		t.Fatalf("run 23 = %v", runs[2].GetRunnirStarts())
	}
}

func TestOnlyReRunsStartAnAttempt(t *testing.T) {
	for action, want := range map[corev1.RunAction]string{
		corev1.RunAction_RUN_ACTION_RERUN: store.StartRerun, corev1.RunAction_RUN_ACTION_RERUN_FAILED: store.StartRerunFailed,
		corev1.RunAction_RUN_ACTION_RERUN_JOB: store.StartRerunJob, corev1.RunAction_RUN_ACTION_CANCEL: "",
		corev1.RunAction_RUN_ACTION_APPROVE_DEPLOYMENTS: "",
	} {
		if kind, ok := startKind(action); kind != want || ok != (want != "") {
			t.Fatalf("%v = %q, %v", action, kind, ok)
		}
	}
}
