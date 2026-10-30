package github

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

func fakeGitHub(t *testing.T, handler http.HandlerFunc) (*Client, *Credential) {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	credential := &Credential{}
	_ = credential.Set("ghu_test")
	return NewClient(credential, server.URL, "test"), credential
}

func TestRunsAreReadWithTheTokenAndMapped(t *testing.T) {
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer ghu_test" || r.Header.Get("X-GitHub-Api-Version") == "" {
			t.Errorf("headers = %v", r.Header)
		}
		if r.URL.Path != "/repos/dil-eight/runnir/actions/runs" || r.URL.Query().Get("branch") != "main" || r.URL.Query().Get("per_page") != "20" {
			t.Errorf("request = %s", r.URL)
		}
		_, _ = w.Write([]byte(`{"total_count":2,"workflow_runs":[
			{"id":11,"workflow_id":5,"name":"CI","display_title":"Fix build","run_number":42,"event":"push","status":"completed","conclusion":"failure","head_branch":"main","head_sha":"abc","html_url":"https://github.com/r/1","created_at":"2026-10-18T10:00:00Z","updated_at":"2026-10-18T10:05:00Z","actor":{"login":"octocat"}},
			{"id":12,"workflow_id":5,"name":"CI","run_number":43,"event":"push","status":"in_progress","conclusion":null,"head_branch":"main","head_sha":"def","created_at":"2026-10-18T11:00:00Z","updated_at":"2026-10-18T11:01:00Z","actor":null}
		]}`))
	})
	runs, err := client.Runs(context.Background(), "dil-eight", "runnir", "main", 20)
	if err != nil {
		t.Fatal(err)
	}
	if len(runs) != 2 || runs[0].Conclusion != "failure" || runs[0].Actor != "octocat" || runs[0].RunNumber != 42 ||
		runs[1].Conclusion != "" || runs[1].Status != "in_progress" || runs[1].Actor != "" ||
		!runs[0].CreatedAt.Equal(time.Date(2026, 10, 18, 10, 0, 0, 0, time.UTC)) {
		t.Fatalf("runs = %+v", runs)
	}
}

func TestJobsCarryTheirSteps(t *testing.T) {
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/repos/o/r/actions/runs/11/jobs" {
			t.Errorf("path = %s", r.URL.Path)
		}
		_, _ = w.Write([]byte(`{"jobs":[{"id":1,"name":"build","status":"completed","conclusion":"success","started_at":"2026-10-18T10:00:00Z","completed_at":"2026-10-18T10:03:00Z","html_url":"u",
			"steps":[{"number":1,"name":"Checkout","status":"completed","conclusion":"success"},{"number":2,"name":"Test","status":"in_progress","conclusion":null}]}]}`))
	})
	jobs, err := client.Jobs(context.Background(), "o", "r", 11)
	if err != nil {
		t.Fatal(err)
	}
	if len(jobs) != 1 || len(jobs[0].Steps) != 2 || jobs[0].Steps[1].Conclusion != "" || jobs[0].CompletedAt.IsZero() {
		t.Fatalf("jobs = %+v", jobs)
	}
	if _, err := client.Jobs(context.Background(), "o", "r", 0); !errors.Is(err, ErrInvalid) {
		t.Fatalf("run id 0 = %v", err)
	}
}

func TestJobsArePaged(t *testing.T) {
	var pages []string
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		page := r.URL.Query().Get("page")
		pages = append(pages, page)
		n, last := 100, 0
		if page == "2" {
			n = 30
		}
		jobs := make([]string, n)
		for i := range jobs {
			last = i + 1
			jobs[i] = fmt.Sprintf(`{"id":%s%d,"name":"test (%d)","status":"completed","conclusion":"success"}`, page, last, last)
		}
		_, _ = fmt.Fprintf(w, `{"total_count":130,"jobs":[%s]}`, strings.Join(jobs, ","))
	})
	jobs, err := client.Jobs(context.Background(), "o", "r", 11)
	if err != nil || len(jobs) != 130 || !reflect.DeepEqual(pages, []string{"1", "2"}) {
		t.Fatalf("jobs = %d, pages = %v, err = %v", len(jobs), pages, err)
	}
}

func TestWorkflowsArePaged(t *testing.T) {
	calls := 0
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Query().Get("page") == "1" {
			var items []string
			for i := 0; i < 100; i++ {
				items = append(items, `{"id":1,"name":"w","path":".github/workflows/w.yml","state":"active"}`)
			}
			_, _ = w.Write([]byte(`{"total_count":101,"workflows":[` + strings.Join(items, ",") + `]}`))
			return
		}
		_, _ = w.Write([]byte(`{"total_count":101,"workflows":[{"id":2,"name":"last","path":"p","state":"disabled_manually"}]}`))
	})
	workflows, err := client.Workflows(context.Background(), "o", "r")
	if err != nil || len(workflows) != 101 || calls != 2 || workflows[100].State != "disabled_manually" {
		t.Fatalf("workflows = %d, calls = %d, err = %v", len(workflows), calls, err)
	}
}

func TestStatusesMapToActionableErrors(t *testing.T) {
	cases := []struct {
		status  int
		headers map[string]string
		want    error
	}{
		{401, nil, ErrUnauthorized},
		{404, nil, ErrNotVisible},
		{403, nil, ErrNotVisible},
		{502, nil, ErrUnavailable},
		{418, nil, ErrInvalid},
	}
	for _, tc := range cases {
		client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
			for k, v := range tc.headers {
				w.Header().Set(k, v)
			}
			w.WriteHeader(tc.status)
		})
		if _, err := client.Runs(context.Background(), "o", "r", "", 0); !errors.Is(err, tc.want) {
			t.Errorf("status %d: %v, want %v", tc.status, err, tc.want)
		}
	}

	reset := time.Now().Add(10 * time.Minute).Unix()
	limited, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-RateLimit-Remaining", "0")
		w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(reset, 10))
		w.WriteHeader(403)
	})
	_, err := limited.Runs(context.Background(), "o", "r", "", 0)
	var rateLimit *RateLimitError
	if !errors.As(err, &rateLimit) || rateLimit.Reset.Unix() != reset {
		t.Fatalf("rate limit = %v", err)
	}

	// A refused change keeps GitHub's reason; a refused read stays NOT_VISIBLE.
	refused, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(403)
		_, _ = w.Write([]byte(`{"message":"Unable to re-run this workflow run because it was created over a month ago"}`))
	})
	var rejected *RejectedError
	if err := refused.RerunRun(context.Background(), "o", "r", 9, false); !errors.As(err, &rejected) || !strings.Contains(rejected.Message, "over a month ago") {
		t.Fatalf("forbidden change = %v", err)
	}
	if _, err := refused.Run(context.Background(), "o", "r", 9); !errors.Is(err, ErrNotVisible) {
		t.Fatalf("forbidden read = %v", err)
	}
	// A missing permission, the app's or the user's, is its own error for
	// reads and changes alike, so the app can say which step fixes it.
	noPermission, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(403)
		_, _ = w.Write([]byte(`{"message":"Resource not accessible by integration"}`))
	})
	if err := noPermission.CancelRun(context.Background(), "o", "r", 9); !errors.Is(err, ErrPermissionMissing) {
		t.Fatalf("change = %v", err)
	}
	if _, err := noPermission.Run(context.Background(), "o", "r", 9); !errors.Is(err, ErrPermissionMissing) {
		t.Fatalf("read = %v", err)
	}
	// A repository the app does not reach is a 404.
	notInstalled, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(404) })
	if _, err := notInstalled.Run(context.Background(), "o", "r", 9); !errors.Is(err, ErrNotVisible) {
		t.Fatalf("not installed = %v", err)
	}
}

func TestNoTokenMeansNoRequest(t *testing.T) {
	called := false
	client, credential := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) { called = true })
	credential.Clear()
	if _, err := client.Runs(context.Background(), "o", "r", "", 0); !errors.Is(err, ErrNoCredential) || called {
		t.Fatalf("err = %v, called = %v", err, called)
	}
}

func TestErrorsNeverContainTheToken(t *testing.T) {
	for _, err := range []error{ErrNoCredential, ErrUnauthorized, ErrNotVisible, ErrPermissionMissing, ErrUnavailable, ErrInvalid, &RateLimitError{}} {
		if strings.Contains(err.Error(), "ghu_") {
			t.Fatalf("error leaks a token: %v", err)
		}
	}
}

func TestAnAPIURLEndingInASlashAddsNoEmptySegment(t *testing.T) {
	var path string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path = r.URL.Path
		_, _ = w.Write([]byte(`{"workflows":[]}`))
	}))
	t.Cleanup(server.Close)
	credential := &Credential{}
	_ = credential.Set("ghp_test")
	client := NewClient(credential, server.URL+"/api/v3/", "test")
	if _, err := client.Workflows(context.Background(), "org", "app"); err != nil {
		t.Fatal(err)
	}
	if path != "/api/v3/repos/org/app/actions/workflows" {
		t.Errorf("path = %q", path)
	}
}

func TestConditionalReadsUseETags(t *testing.T) {
	var runsSeen, workflowsSeen []string
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/o/r/actions/runs":
			runsSeen = append(runsSeen, r.Header.Get("If-None-Match"))
			if r.Header.Get("If-None-Match") == `"runs-1"` {
				w.WriteHeader(http.StatusNotModified)
				return
			}
			w.Header().Set("ETag", `"runs-1"`)
			_, _ = w.Write([]byte(`{"workflow_runs":[{"id":7,"status":"completed","created_at":"2026-10-18T10:00:00Z","updated_at":"2026-10-18T10:00:00Z"}]}`))
		case "/repos/o/r/actions/workflows":
			workflowsSeen = append(workflowsSeen, r.Header.Get("If-None-Match"))
			if r.Header.Get("If-None-Match") == `"wf-1"` {
				w.WriteHeader(http.StatusNotModified)
				return
			}
			w.Header().Set("ETag", `"wf-1"`)
			_, _ = w.Write([]byte(`{"total_count":1,"workflows":[{"id":3,"name":"CI","path":".github/workflows/ci.yml","state":"active"}]}`))
		}
	})
	ctx := context.Background()

	runs, tag, err := client.RunsIfChanged(ctx, "o", "r", 50, "")
	if err != nil || len(runs) != 1 || tag != `"runs-1"` {
		t.Fatalf("first = %v %q %v", runs, tag, err)
	}
	if _, _, err := client.RunsIfChanged(ctx, "o", "r", 50, tag); !errors.Is(err, ErrNotModified) {
		t.Fatalf("second = %v", err)
	}
	workflows, wtag, err := client.WorkflowsIfChanged(ctx, "o", "r", "")
	if err != nil || len(workflows) != 1 || wtag != `"wf-1"` {
		t.Fatalf("workflows = %v %q %v", workflows, wtag, err)
	}
	if _, _, err := client.WorkflowsIfChanged(ctx, "o", "r", wtag); !errors.Is(err, ErrNotModified) {
		t.Fatalf("workflows again = %v", err)
	}
	if len(runsSeen) != 2 || runsSeen[0] != "" || runsSeen[1] != `"runs-1"` || workflowsSeen[1] != `"wf-1"` {
		t.Fatalf("headers = %v %v", runsSeen, workflowsSeen)
	}
}

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

func TestRerunJobPostsToTheJobOnceAndKeepsRefusals(t *testing.T) {
	var calls []string
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		calls = append(calls, r.Method+" "+r.URL.Path+" "+string(body))
		w.WriteHeader(http.StatusCreated)
	})
	if err := client.RerunJob(context.Background(), "o", "r", 7); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 1 || calls[0] != "POST /repos/o/r/actions/jobs/7/rerun {}" {
		t.Fatalf("calls = %q", calls)
	}
	if err := client.RerunJob(context.Background(), "o", "r", 0); !errors.Is(err, ErrInvalid) || len(calls) != 1 {
		t.Fatalf("job 0 = %v, calls %q", err, calls)
	}

	// A server error is not retried: a lost answer must not start two attempts.
	attempts := 0
	broken, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		attempts++
		w.WriteHeader(http.StatusBadGateway)
	})
	if err := broken.RerunJob(context.Background(), "o", "r", 7); err == nil || attempts != 1 {
		t.Fatalf("bad gateway = %v after %d attempts", err, attempts)
	}

	refused, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		_, _ = w.Write([]byte(`{"message":"Unable to re-run this job because the run is still in progress"}`))
	})
	var rejected *RejectedError
	if err := refused.RerunJob(context.Background(), "o", "r", 7); !errors.As(err, &rejected) || !strings.Contains(rejected.Message, "still in progress") {
		t.Fatalf("refused = %v", err)
	}
}

func TestAJobCarriesTheRunItBelongsTo(t *testing.T) {
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":5,"run_id":9,"run_attempt":3,"name":"build","status":"completed","conclusion":"failure","steps":[]}`))
	})
	job, err := client.Job(context.Background(), "o", "r", 5)
	if err != nil || job.RunID != 9 || job.RunAttempt != 3 {
		t.Fatalf("job = %+v, %v", job, err)
	}
}

func TestTheCoreRateLimitOfTheLatestAnswerIsKept(t *testing.T) {
	reset := time.Date(2026, 10, 29, 13, 0, 0, 0, time.UTC)
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		resource, remaining := "core", "4200"
		if r.URL.Path == "/search/issues" {
			resource, remaining = "search", "3"
		}
		w.Header().Set("X-RateLimit-Resource", resource)
		w.Header().Set("X-RateLimit-Limit", "5000")
		w.Header().Set("X-RateLimit-Remaining", remaining)
		w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(reset.Unix(), 10))
		_, _ = w.Write([]byte(`{"workflow_runs":[],"items":[],"total_count":0}`))
	})
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
	users := 0
	client, credential := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		users++
		if r.Header.Get("Authorization") == "Bearer ghu_other" {
			_, _ = w.Write([]byte(`{"login":"bo"}`))
			return
		}
		_, _ = w.Write([]byte(`{"login":"ana"}`))
	})
	for range 2 {
		if login, err := client.Login(context.Background()); err != nil || login != "ana" {
			t.Fatalf("login = %q, %v", login, err)
		}
	}
	if users != 1 {
		t.Fatalf("GET /user = %d", users)
	}
	_ = credential.Set("ghu_test") // the same token again
	_, _ = client.Login(context.Background())
	if users != 1 {
		t.Fatal("the same token is not read again")
	}
	_ = credential.Set("ghu_other")
	if login, _ := client.Login(context.Background()); login != "bo" || users != 2 {
		t.Fatalf("after a new token = %q, %d", login, users)
	}
}

func TestRunsOfAnActorAreAskedWithAnETag(t *testing.T) {
	var query, sent string
	client, _ := fakeGitHub(t, func(w http.ResponseWriter, r *http.Request) {
		query, sent = r.URL.RawQuery, r.Header.Get("If-None-Match")
		if sent == `"v1"` {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("ETag", `"v1"`)
		_, _ = w.Write([]byte(`{"workflow_runs":[{"id":7,"status":"completed","conclusion":"failure","actor":{"login":"ana"}}]}`))
	})
	runs, tag, err := client.ActorRunsIfChanged(context.Background(), "o", "r", "ana", 50, "")
	if err != nil || len(runs) != 1 || runs[0].Actor != "ana" || tag != `"v1"` || query != "actor=ana&per_page=50" {
		t.Fatalf("runs = %+v, %q, %v, query %q", runs, tag, err, query)
	}
	if _, _, err := client.ActorRunsIfChanged(context.Background(), "o", "r", "ana", 50, tag); !errors.Is(err, ErrNotModified) || sent != `"v1"` {
		t.Fatalf("again = %v, sent %q", err, sent)
	}
}
