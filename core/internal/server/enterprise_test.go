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

const companyID = "1b9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"

// fakeAPI answers runs for o/r and records the tokens it saw.
func fakeAPI(t *testing.T) (*httptest.Server, func() []string) {
	t.Helper()
	var mu sync.Mutex
	var tokens []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		tokens = append(tokens, strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
		mu.Unlock()
		switch r.URL.Path {
		case "/repos/o/r/actions/runs":
			_, _ = w.Write([]byte(`{"workflow_runs":[]}`))
		case "/search/issues":
			_, _ = w.Write([]byte(`{"items":[]}`))
		case "/user/repos":
			_, _ = w.Write([]byte(`[]`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(server.Close)
	return server, func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), tokens...)
	}
}

func TestEnterpriseCallsGoToTheirServer(t *testing.T) {
	dotcom, dotcomTokens := fakeAPI(t)
	company, companyTokens := fakeAPI(t)
	path := socketPath(t)
	stop := startWith(t, path, Options{GitHubBaseURL: dotcom.URL})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if _, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghu_dotcom"}); err != nil {
		t.Fatal(err)
	}
	server := &corev1.GithubServer{Id: companyID, ApiUrl: company.URL, WebHost: "github.company.com"}
	set, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghp_company", Server: server})
	if err != nil || set.Kind != corev1.GithubCredentialKind_GITHUB_CREDENTIAL_KIND_CLASSIC {
		t.Fatalf("set = %v, %v", set, err)
	}

	// A working tree on the Enterprise host goes to the Enterprise API.
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.company.com:o/r.git")})
	if err != nil {
		t.Fatal(err)
	}
	if opened.Repository.GithubRepository != "o/r" || opened.Repository.GithubServerId != companyID || opened.Repository.OriginHost != "github.company.com" {
		t.Fatalf("repository = %+v", opened.Repository)
	}
	runs, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{RepositoryId: opened.Repository.Id})
	if err != nil || runs.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_OK {
		t.Fatalf("runs = %v, %v", runs, err)
	}
	// A named repository goes where github_server says; lists too.
	if _, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{GithubRepository: "o/r", GithubServer: companyID}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{GithubRepository: "o/r"}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.ListPullRequests(ctx, &corev1.ListPullRequestsRequest{GithubServer: companyID}); err != nil {
		t.Fatal(err)
	}
	listed, err := client.ListGitHubRepositories(ctx, &corev1.ListGitHubRepositoriesRequest{GithubServer: companyID})
	if err != nil || listed.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_OK {
		t.Fatalf("repositories = %v, %v", listed, err)
	}
	for _, token := range companyTokens() {
		if token != "ghp_company" {
			t.Fatalf("the Enterprise API saw %q", token)
		}
	}
	for _, token := range dotcomTokens() {
		if token != "ghu_dotcom" {
			t.Fatalf("github.com saw %q", token)
		}
	}
	if len(dotcomTokens()) != 1 || len(companyTokens()) < 4 {
		t.Fatalf("calls: company %d, github.com %d", len(companyTokens()), len(dotcomTokens()))
	}

	// GetGitHubOrigins names the server.
	origins, err := client.GetGitHubOrigins(ctx, &corev1.GetGitHubOriginsRequest{Paths: []string{opened.Repository.Path}})
	if err != nil || len(origins.Origins) != 1 || origins.Origins[0].GithubServerId != companyID {
		t.Fatalf("origins = %v, %v", origins, err)
	}

	// An unknown server is signed out; forgetting the server makes the
	// working tree's origin unknown again.
	unknown, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{GithubRepository: "o/r", GithubServer: "2c9d6bcd-bbfd-4b2d-9b5d-ab8dfbbd4bed"})
	if err != nil || unknown.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT {
		t.Fatalf("unknown server = %v, %v", unknown, err)
	}
	if _, err := client.ClearGitHubCredential(ctx, &corev1.ClearGitHubCredentialRequest{ServerId: companyID}); err != nil {
		t.Fatal(err)
	}
	gone, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{RepositoryId: opened.Repository.Id})
	if err != nil || gone.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE {
		t.Fatalf("after removal = %v, %v", gone, err)
	}
	// github.com's token is untouched.
	health, err := client.HealthCheck(ctx, &corev1.HealthCheckRequest{})
	if err != nil || !health.GithubCredentialSet {
		t.Fatalf("health = %v, %v", health, err)
	}
}

func TestEnterpriseRejectedTokenIsForgottenOnlyThere(t *testing.T) {
	dotcom, _ := fakeAPI(t)
	rejecting := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer rejecting.Close()
	path := socketPath(t)
	stop := startWith(t, path, Options{GitHubBaseURL: dotcom.URL})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghu_dotcom"}); err != nil {
		t.Fatal(err)
	}
	server := &corev1.GithubServer{Id: companyID, ApiUrl: rejecting.URL, WebHost: "github.company.com"}
	if _, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghp_old", Server: server}); err != nil {
		t.Fatal(err)
	}
	rejected, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{GithubRepository: "o/r", GithubServer: companyID})
	if err != nil || rejected.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_TOKEN_REJECTED {
		t.Fatalf("rejected = %v, %v", rejected, err)
	}
	again, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{GithubRepository: "o/r", GithubServer: companyID})
	if err != nil || again.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT {
		t.Fatalf("after rejection = %v, %v", again, err)
	}
	dotcomRuns, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{GithubRepository: "o/r"})
	if err != nil || dotcomRuns.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_OK {
		t.Fatalf("github.com after the Enterprise rejection = %v, %v", dotcomRuns, err)
	}
}

func TestEnterpriseServerMustBeValid(t *testing.T) {
	path := socketPath(t)
	stop := startWith(t, path, Options{})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	bad := &corev1.GithubServer{Id: companyID, ApiUrl: "http://github.company.com/api/v3", WebHost: "github.company.com"}
	_, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghp_x", Server: bad})
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("http off loopback: %v", err)
	}
	_, err = client.CheckGitHubToken(ctx, &corev1.CheckGitHubTokenRequest{Token: "ghp_x", Server: bad})
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("check against a bad server: %v", err)
	}
}
