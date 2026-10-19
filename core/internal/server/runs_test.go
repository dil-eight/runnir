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

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

const jobJSON = `{"id":%d,"name":"build","status":"%s","conclusion":%s,"steps":[
 {"number":1,"name":"Set up job","status":"completed","conclusion":"success","started_at":"2026-10-19T10:00:00Z","completed_at":"2026-10-19T10:00:02Z"},
 {"number":2,"name":"Archive","status":"completed","conclusion":"failure","started_at":"2026-10-19T10:00:03Z","completed_at":"2026-10-19T10:00:09Z"},
 {"number":3,"name":"Upload","status":"completed","conclusion":"skipped","started_at":"2026-10-19T10:00:09Z","completed_at":"2026-10-19T10:00:09Z"}]}`

type fakeRunsGitHub struct {
	mu        sync.Mutex
	runStatus string
	posts     []string
	conflict  bool
	forbidden bool
}

func (f *fakeRunsGitHub) sent() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.posts...)
}

func (f *fakeRunsGitHub) handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		switch {
		case r.URL.Path == "/repos/o/r/actions/jobs/11":
			_, _ = w.Write([]byte(strings.NewReplacer("%d", "11", "%s", "completed", "conclusion\":%s", "conclusion\":\"failure\"").Replace(jobJSON)))
		case r.URL.Path == "/repos/o/r/actions/jobs/12":
			_, _ = w.Write([]byte(strings.NewReplacer("%d", "12", "%s", "in_progress", "conclusion\":%s", "conclusion\":null").Replace(jobJSON)))
		case r.URL.Path == "/repos/o/r/actions/jobs/13":
			_, _ = w.Write([]byte(strings.NewReplacer("%d", "13", "%s", "completed", "conclusion\":%s", "conclusion\":\"failure\"").Replace(jobJSON)))
		case r.URL.Path == "/repos/o/r/actions/jobs/11/logs":
			http.Redirect(w, r, "/blob/11", http.StatusFound)
		case r.URL.Path == "/blob/11":
			_, _ = w.Write([]byte("2026-10-19T10:00:01.0000000Z Current runner version: '2.330.0'\n" +
				"2026-10-19T10:00:04.0000000Z ##[group]Run xcodebuild archive\n" +
				"2026-10-19T10:00:08.0000000Z ##[error]Provisioning profile expired\n"))
		case r.URL.Path == "/repos/o/r/actions/jobs/14":
			_, _ = w.Write([]byte(strings.NewReplacer("%d", "14", "%s", "completed", "conclusion\":%s", "conclusion\":\"success\"").Replace(jobJSON)))
		case r.URL.Path == "/repos/o/r/actions/jobs/14/logs":
			_, _ = w.Write([]byte(strings.Repeat("x\n", maxLogLines+10)))
		case r.URL.Path == "/repos/o/r/actions/jobs/15":
			_, _ = w.Write([]byte(`{"id":15,"name":"deploy","status":"completed","conclusion":"skipped","steps":[]}`))
		case r.URL.Path == "/repos/o/r/actions/jobs/16":
			finished := time.Now().UTC().Format(time.RFC3339)
			_, _ = w.Write([]byte(`{"id":16,"name":"build","status":"completed","conclusion":"success","completed_at":"` + finished + `",
				"steps":[{"number":1,"name":"Set up job","status":"completed","conclusion":"success","started_at":"` + finished + `"}]}`))
		case r.URL.Path == "/repos/o/r/actions/jobs/17":
			_, _ = w.Write([]byte(strings.NewReplacer("%d", "17", "%s", "completed", "conclusion\":%s", "conclusion\":\"success\"").Replace(jobJSON)))
		case r.URL.Path == "/repos/o/r/actions/jobs/17/logs":
			http.Redirect(w, r, "/blob/slow", http.StatusFound)
		case r.URL.Path == "/blob/slow":
			f.mu.Unlock()
			time.Sleep(500 * time.Millisecond)
			f.mu.Lock()
			_, _ = w.Write([]byte("too late\n"))
		case r.URL.Path == "/repos/o/r/actions/jobs/15/logs", r.URL.Path == "/repos/o/r/actions/jobs/16/logs":
			w.WriteHeader(http.StatusNotFound)
		case r.URL.Path == "/repos/o/r/actions/jobs/13/logs":
			w.WriteHeader(http.StatusGone)
		case r.URL.Path == "/repos/o/r/actions/runs/21" && r.Method == http.MethodGet:
			conclusion := `"failure"`
			if f.runStatus != "completed" {
				conclusion = "null"
			}
			_, _ = w.Write([]byte(`{"id":21,"run_number":1482,"run_attempt":1,"name":"CI","status":"` + f.runStatus + `","conclusion":` + conclusion + `}`))
		case strings.HasPrefix(r.URL.Path, "/repos/o/r/actions/runs/21/") && r.Method == http.MethodPost:
			f.posts = append(f.posts, strings.TrimPrefix(r.URL.Path, "/repos/o/r/actions/runs/21/"))
			if f.forbidden {
				w.WriteHeader(http.StatusForbidden)
				_, _ = w.Write([]byte(`{"message":"Unable to re-run this workflow run because it was created over a month ago"}`))
				return
			}
			if f.conflict {
				w.WriteHeader(http.StatusConflict)
				_, _ = w.Write([]byte(`{"message":"Cannot cancel a workflow run that is completed."}`))
				return
			}
			w.WriteHeader(http.StatusAccepted)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}
}

func runsRig(t *testing.T) (corev1.RunnirCoreClient, string, *fakeRunsGitHub, context.Context) {
	t.Helper()
	fake := &fakeRunsGitHub{runStatus: "completed"}
	server := httptest.NewServer(fake.handler())
	t.Cleanup(server.Close)
	path := socketPath(t)
	stop := startWith(t, path, Options{GitHubBaseURL: server.URL})
	t.Cleanup(func() { _ = stop() })
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	t.Cleanup(cancel)
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "https://github.com/o/r.git")})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghu_test"}); err != nil {
		t.Fatal(err)
	}
	return client, opened.Repository.Id, fake, ctx
}

func TestJobLogLinesCarryKindAndStep(t *testing.T) {
	client, id, _, ctx := runsRig(t)
	log, err := client.GetJobLog(ctx, &corev1.GetJobLogRequest{RepositoryId: id, JobId: 11})
	if err != nil || log.Availability != corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_AVAILABLE || len(log.Lines) != 3 {
		t.Fatalf("log = %v, %v", log, err)
	}
	want := []struct {
		kind corev1.LogLineKind
		step int64
		text string
	}{
		{corev1.LogLineKind_LOG_LINE_KIND_PLAIN, 1, "Current runner version: '2.330.0'"},
		{corev1.LogLineKind_LOG_LINE_KIND_GROUP, 2, "Run xcodebuild archive"},
		{corev1.LogLineKind_LOG_LINE_KIND_ERROR, 2, "Provisioning profile expired"},
	}
	for i, w := range want {
		line := log.Lines[i]
		if line.Kind != w.kind || line.StepNumber != w.step || line.Text != w.text || line.Number != int64(i+1) {
			t.Errorf("line %d = %v", i+1, line)
		}
	}

	running, err := client.GetJobLog(ctx, &corev1.GetJobLogRequest{RepositoryId: id, JobId: 12})
	if err != nil || running.Availability != corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_NOT_READY || len(running.Lines) != 0 {
		t.Fatalf("running job = %v, %v", running, err)
	}
	expired, err := client.GetJobLog(ctx, &corev1.GetJobLogRequest{RepositoryId: id, JobId: 13})
	if err != nil || expired.Availability != corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_EXPIRED {
		t.Fatalf("expired = %v, %v", expired, err)
	}
	skipped, err := client.GetJobLog(ctx, &corev1.GetJobLogRequest{RepositoryId: id, JobId: 15})
	if err != nil || skipped.Availability != corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_AVAILABLE || len(skipped.Lines) != 0 {
		t.Fatalf("a job that never ran = %v, %v", skipped, err)
	}
	settling, err := client.GetJobLog(ctx, &corev1.GetJobLogRequest{RepositoryId: id, JobId: 16})
	if err != nil || settling.Availability != corev1.JobLogAvailability_JOB_LOG_AVAILABILITY_NOT_READY {
		t.Fatalf("a job that just finished = %v, %v", settling, err)
	}
	short, err := client.GetJobLog(ctx, &corev1.GetJobLogRequest{RepositoryId: id, JobId: 14})
	if err != nil || len(short.Lines) != maxLogLines || !short.Truncated || short.Lines[0].Number != 11 {
		t.Fatalf("many short lines = %d lines, truncated %v, %v", len(short.GetLines()), short.GetTruncated(), err)
	}
	missing, err := client.GetJobLog(ctx, &corev1.GetJobLogRequest{RepositoryId: id, JobId: 99})
	if err != nil || missing.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE {
		t.Fatalf("unknown job = %v, %v", missing, err)
	}
	if _, err := client.GetJobLog(ctx, &corev1.GetJobLogRequest{RepositoryId: id}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("no job id = %v", err)
	}
}

func TestASlowLogDownloadGivesUpWithinItsBudget(t *testing.T) {
	previous := jobLogBudget
	jobLogBudget = 100 * time.Millisecond
	t.Cleanup(func() { jobLogBudget = previous })
	client, id, _, ctx := runsRig(t)
	slow, err := client.GetJobLog(ctx, &corev1.GetJobLogRequest{RepositoryId: id, JobId: 17})
	if err != nil || slow.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE || len(slow.Lines) != 0 {
		t.Fatalf("slow download = %v, %v", slow, err)
	}
}

func TestRunActionsCheckTheRunStateAndSendOnce(t *testing.T) {
	client, id, fake, ctx := runsRig(t)
	prepare := func(action corev1.RunAction) *corev1.PrepareRunActionResponse {
		t.Helper()
		prepared, err := client.PrepareRunAction(ctx, &corev1.PrepareRunActionRequest{RepositoryId: id, RunId: 21, Action: action})
		if err != nil {
			t.Fatal(err)
		}
		return prepared
	}

	finished := prepare(corev1.RunAction_RUN_ACTION_CANCEL)
	if finished.ActionId != "" || len(finished.Problems) != 1 || !strings.Contains(finished.Problems[0], "already finished") ||
		finished.Run.GetRunNumber() != 1482 || finished.Run.GetRunAttempt() != 1 {
		t.Fatalf("cancel a finished run = %v", finished)
	}

	rerun := prepare(corev1.RunAction_RUN_ACTION_RERUN_FAILED)
	if rerun.ActionId == "" || rerun.ExpiresAt == nil || len(fake.sent()) != 0 {
		t.Fatalf("prepare re-run = %v, posts %v", rerun, fake.sent())
	}
	confirmed, err := client.ConfirmRunAction(ctx, &corev1.ConfirmRunActionRequest{ActionId: rerun.ActionId})
	if err != nil || confirmed.AcceptedAt == nil || confirmed.Rejection != "" {
		t.Fatalf("confirm = %v, %v", confirmed, err)
	}
	if _, err := client.ConfirmRunAction(ctx, &corev1.ConfirmRunActionRequest{ActionId: rerun.ActionId}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("second confirm = %v", err)
	}

	fake.mu.Lock()
	fake.runStatus = "in_progress"
	fake.mu.Unlock()
	if still := prepare(corev1.RunAction_RUN_ACTION_RERUN); still.ActionId != "" || !strings.Contains(still.Problems[0], "in progress") {
		t.Fatalf("re-run an active run = %v", still)
	}
	cancel := prepare(corev1.RunAction_RUN_ACTION_CANCEL)
	// The run finishes between review and confirmation: GitHub refuses.
	fake.mu.Lock()
	fake.conflict = true
	fake.mu.Unlock()
	refused, err := client.ConfirmRunAction(ctx, &corev1.ConfirmRunActionRequest{ActionId: cancel.ActionId})
	if err != nil || !strings.Contains(refused.Rejection, "Cannot cancel") || refused.AcceptedAt != nil {
		t.Fatalf("refused = %v, %v", refused, err)
	}

	if posts := fake.sent(); strings.Join(posts, ",") != "rerun-failed-jobs,cancel" {
		t.Fatalf("posts = %v", posts)
	}

	// A refused change keeps GitHub's reason instead of looking like
	// missing access.
	fake.mu.Lock()
	fake.runStatus, fake.conflict, fake.forbidden = "completed", false, true
	fake.mu.Unlock()
	old := prepare(corev1.RunAction_RUN_ACTION_RERUN)
	tooOld, err := client.ConfirmRunAction(ctx, &corev1.ConfirmRunActionRequest{ActionId: old.ActionId})
	if err != nil || !strings.Contains(tooOld.Rejection, "over a month ago") || tooOld.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_OK {
		t.Fatalf("forbidden re-run = %v, %v", tooOld, err)
	}
	if _, err := client.PrepareRunAction(ctx, &corev1.PrepareRunActionRequest{RepositoryId: id, RunId: 21}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("no action = %v", err)
	}
}
