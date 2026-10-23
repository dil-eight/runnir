package github

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
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
