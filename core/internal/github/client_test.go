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
	for _, err := range []error{ErrNoCredential, ErrUnauthorized, ErrNotVisible, ErrUnavailable, ErrInvalid, &RateLimitError{}} {
		if strings.Contains(err.Error(), "ghu_") {
			t.Fatalf("error leaks a token: %v", err)
		}
	}
}
