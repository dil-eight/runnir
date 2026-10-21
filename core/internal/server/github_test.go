//go:build !windows

package server

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// linkedRepository creates a working tree whose origin is github.com/o/r.
func linkedRepository(t *testing.T, origin string) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	config := "[remote \"origin\"]\n\turl = " + origin + "\n"
	if err := os.WriteFile(filepath.Join(root, ".git", "config"), []byte(config), 0o644); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestGitHubDataForAnOpenRepository(t *testing.T) {
	var status401 atomic.Bool
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if status401.Load() {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		switch r.URL.Path {
		case "/repos/o/r/actions/runs":
			_, _ = w.Write([]byte(`{"workflow_runs":[{"id":7,"workflow_id":3,"name":"CI","run_number":12,"event":"push","status":"completed","conclusion":"success","head_branch":"main","head_sha":"abc","created_at":"2026-10-18T10:00:00Z","updated_at":"2026-10-18T10:04:00Z","actor":{"login":"octocat"}}]}`))
		case "/repos/o/r/actions/runs/7/jobs":
			_, _ = w.Write([]byte(`{"jobs":[{"id":1,"name":"build","status":"completed","conclusion":"success","steps":[{"number":1,"name":"Checkout","status":"completed","conclusion":"success"}]}]}`))
		case "/repos/o/r/actions/workflows":
			_, _ = w.Write([]byte(`{"total_count":1,"workflows":[{"id":3,"name":"CI","path":".github/workflows/ci.yml","state":"active"}]}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer fake.Close()

	path := socketPath(t)
	stop := startWith(t, path, Options{GitHubBaseURL: fake.URL})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.com:o/r.git")})
	if err != nil {
		t.Fatal(err)
	}
	id := opened.Repository.Id

	// Before sign-in.
	runs, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{RepositoryId: id})
	if err != nil || runs.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT {
		t.Fatalf("signed out = %v, %v", runs, err)
	}

	if _, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghu_test"}); err != nil {
		t.Fatal(err)
	}
	runs, err = client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{RepositoryId: id, Branch: "main", Limit: 10})
	if err != nil || runs.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_OK || len(runs.Runs) != 1 ||
		runs.Runs[0].Conclusion != "success" || runs.Runs[0].Actor != "octocat" || runs.Runs[0].CreatedAt == nil {
		t.Fatalf("runs = %v, %v", runs, err)
	}
	jobs, err := client.ListRunJobs(ctx, &corev1.ListRunJobsRequest{RepositoryId: id, RunId: 7})
	if err != nil || len(jobs.Jobs) != 1 || len(jobs.Jobs[0].Steps) != 1 || jobs.Jobs[0].StartedAt != nil {
		t.Fatalf("jobs = %v, %v", jobs, err)
	}
	workflows, err := client.ListGitHubWorkflows(ctx, &corev1.ListGitHubWorkflowsRequest{RepositoryId: id})
	if err != nil || len(workflows.Workflows) != 1 || workflows.Workflows[0].Path != ".github/workflows/ci.yml" {
		t.Fatalf("workflows = %v, %v", workflows, err)
	}

	// A rejected token is reported and forgotten.
	status401.Store(true)
	runs, err = client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{RepositoryId: id})
	if err != nil || runs.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_TOKEN_REJECTED {
		t.Fatalf("rejected = %v, %v", runs, err)
	}
	health, _ := client.HealthCheck(ctx, &corev1.HealthCheckRequest{})
	if health.GithubCredentialSet {
		t.Fatal("rejected token was kept")
	}
}

func TestGitHubCallsReportMissingRemoteAndBadInput(t *testing.T) {
	path := socketPath(t)
	stop := startWith(t, path, Options{GitHubBaseURL: "http://127.0.0.1:1"})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	gitlab, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "https://gitlab.com/o/r.git")})
	if err != nil {
		t.Fatal(err)
	}
	runs, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{RepositoryId: gitlab.Repository.Id})
	if err != nil || runs.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE {
		t.Fatalf("no remote = %v, %v", runs, err)
	}
	if _, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{RepositoryId: "repo_unknown"}); status.Code(err) != codes.NotFound {
		t.Fatalf("unknown id = %v", err)
	}
	if _, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{RepositoryId: gitlab.Repository.Id, Limit: 101}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("limit = %v", err)
	}
	if _, err := client.ListRunJobs(ctx, &corev1.ListRunJobsRequest{RepositoryId: gitlab.Repository.Id}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("run id = %v", err)
	}

	// GitHub unreachable: a status, not a call error.
	linked, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "https://github.com/o/r")})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghu_test"}); err != nil {
		t.Fatal(err)
	}
	runs, err = client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{RepositoryId: linked.Repository.Id})
	if err != nil || runs.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE {
		t.Fatalf("unreachable = %v, %v", runs, err)
	}
}

func TestGitHubOriginsAreReadWithoutOpening(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	github := linkedRepository(t, "git@github.com:Dil-Eight/runnir.git")
	elsewhere := linkedRepository(t, "https://gitlab.com/o/r.git")
	plain := t.TempDir()
	response, err := client.GetGitHubOrigins(ctx, &corev1.GetGitHubOriginsRequest{
		Paths: []string{github, elsewhere, plain, "relative/path", filepath.Join(plain, "missing")},
	})
	if err != nil || len(response.Origins) != 1 || response.Origins[0].Path != github ||
		response.Origins[0].GithubRepository != "Dil-Eight/runnir" {
		t.Fatalf("origins = %v, %v", response, err)
	}
	many := make([]string, 501)
	for i := range many {
		many[i] = github
	}
	if _, err := client.GetGitHubOrigins(ctx, &corev1.GetGitHubOriginsRequest{Paths: many}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("501 paths = %v", err)
	}
}
