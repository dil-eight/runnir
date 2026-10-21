//go:build !windows

package server

import (
	"context"
	"encoding/json"
	"io"
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

const deployWorkflow = `name: Deploy
on:
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        required: true
        options: [staging, production]
      dry_run:
        type: boolean
        default: true
jobs: {}
`

type fakeDispatchGitHub struct {
	mu         sync.Mutex
	dispatches []map[string]any
	reject     string
	runID      int64
}

func (f *fakeDispatchGitHub) handler(t *testing.T) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/repos/o/r":
			_, _ = w.Write([]byte(`{"full_name":"O/r","private":true,"visibility":"private","default_branch":"main","html_url":"https://github.com/O/r"}`))
		case r.URL.Path == "/repos/o/hidden":
			w.WriteHeader(http.StatusNotFound)
		case r.URL.Path == "/repos/o/r/branches":
			_, _ = w.Write([]byte(`[{"name":"main"},{"name":"release/1.0"}]`))
		case r.URL.Path == "/repos/o/r/tags":
			_, _ = w.Write([]byte(`[{"name":"v1.0.0"}]`))
		case r.URL.Path == "/repos/o/r/actions/workflows/7":
			_, _ = w.Write([]byte(`{"id":7,"path":".github/workflows/deploy.yml"}`))
		case r.URL.Path == "/repos/o/r/contents/.github/workflows/deploy.yml":
			if r.Header.Get("Accept") != "application/vnd.github.raw+json" {
				t.Errorf("accept = %q", r.Header.Get("Accept"))
			}
			switch r.URL.Query().Get("ref") {
			case "main":
				_, _ = w.Write([]byte(deployWorkflow))
			case "broken":
				_, _ = w.Write([]byte("on: [workflow_dispatch\n"))
			default:
				w.WriteHeader(http.StatusNotFound)
			}
		case r.URL.Path == "/repos/o/r/actions/workflows/7/dispatches" && r.Method == http.MethodPost:
			body, _ := io.ReadAll(r.Body)
			var decoded map[string]any
			_ = json.Unmarshal(body, &decoded)
			f.mu.Lock()
			f.dispatches = append(f.dispatches, decoded)
			reject, runID := f.reject, f.runID
			f.mu.Unlock()
			if reject != "" {
				w.WriteHeader(http.StatusUnprocessableEntity)
				_, _ = w.Write([]byte(`{"message":"` + reject + `"}`))
				return
			}
			if runID > 0 {
				_, _ = w.Write([]byte(`{"workflow_run_id":` + itoa(runID) + `}`))
				return
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}
}

func itoa(v int64) string { b, _ := json.Marshal(v); return string(b) }

func dispatchRig(t *testing.T) (corev1.RunnirCoreClient, string, *fakeDispatchGitHub, context.Context) {
	t.Helper()
	fake := &fakeDispatchGitHub{}
	server := httptest.NewServer(fake.handler(t))
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

func TestRefsAndDispatchDefinitionAtARef(t *testing.T) {
	client, id, _, ctx := dispatchRig(t)
	refs, err := client.ListGitHubRefs(ctx, &corev1.ListGitHubRefsRequest{RepositoryId: id})
	if err != nil || refs.DefaultBranch != "main" || strings.Join(refs.Branches, ",") != "main,release/1.0" || strings.Join(refs.Tags, ",") != "v1.0.0" {
		t.Fatalf("refs = %v, %v", refs, err)
	}
	described, err := client.DescribeWorkflowDispatch(ctx, &corev1.DescribeWorkflowDispatchRequest{RepositoryId: id, WorkflowPath: ".github/workflows/deploy.yml", Ref: "main"})
	if err != nil || !described.Dispatchable || len(described.Inputs) != 2 ||
		described.Inputs[0].Type != corev1.DispatchInputType_DISPATCH_INPUT_TYPE_CHOICE || !described.Inputs[0].Required ||
		described.Inputs[1].DefaultValue != "true" {
		t.Fatalf("described = %v, %v", described, err)
	}
	missing, err := client.DescribeWorkflowDispatch(ctx, &corev1.DescribeWorkflowDispatchRequest{RepositoryId: id, WorkflowPath: ".github/workflows/deploy.yml", Ref: "old"})
	if err != nil || missing.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE {
		t.Fatalf("missing at ref = %v, %v", missing, err)
	}
	broken, err := client.DescribeWorkflowDispatch(ctx, &corev1.DescribeWorkflowDispatchRequest{RepositoryId: id, WorkflowPath: ".github/workflows/deploy.yml", Ref: "broken"})
	if err != nil || broken.ParseError == "" {
		t.Fatalf("broken = %v, %v", broken, err)
	}
}

func TestRepositoryDetailsComeFromGitHub(t *testing.T) {
	client, id, _, ctx := dispatchRig(t)
	repository, err := client.GetGitHubRepository(ctx, &corev1.GetGitHubRepositoryRequest{RepositoryId: id})
	if err != nil || repository.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_OK || repository.FullName != "O/r" ||
		repository.Visibility != "private" || repository.DefaultBranch != "main" || repository.HtmlUrl != "https://github.com/O/r" {
		t.Fatalf("repository = %v, %v", repository, err)
	}
	hidden, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "git@github.com:o/hidden.git")})
	if err != nil {
		t.Fatal(err)
	}
	notVisible, err := client.GetGitHubRepository(ctx, &corev1.GetGitHubRepositoryRequest{RepositoryId: hidden.Repository.Id})
	if err != nil || notVisible.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE || notVisible.FullName != "" {
		t.Fatalf("not visible = %v, %v", notVisible, err)
	}
	local, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "https://gitlab.com/o/r.git")})
	if err != nil {
		t.Fatal(err)
	}
	noRemote, err := client.GetGitHubRepository(ctx, &corev1.GetGitHubRepositoryRequest{RepositoryId: local.Repository.Id})
	if err != nil || noRemote.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE {
		t.Fatalf("no remote = %v, %v", noRemote, err)
	}
}

func TestADispatchRunsOnlyAfterItsSingleConfirmation(t *testing.T) {
	client, id, fake, ctx := dispatchRig(t)

	invalid, err := client.PrepareWorkflowDispatch(ctx, &corev1.PrepareWorkflowDispatchRequest{
		RepositoryId: id, WorkflowId: 7, Ref: "main", Inputs: map[string]string{"environment": "qa"},
	})
	if err != nil || invalid.DispatchId != "" || len(invalid.Problems) == 0 {
		t.Fatalf("invalid inputs = %v, %v", invalid, err)
	}

	prepared, err := client.PrepareWorkflowDispatch(ctx, &corev1.PrepareWorkflowDispatchRequest{
		RepositoryId: id, WorkflowId: 7, Ref: "main", Inputs: map[string]string{"environment": "staging"},
	})
	if err != nil || prepared.DispatchId == "" || prepared.WorkflowPath != ".github/workflows/deploy.yml" || prepared.ExpiresAt == nil {
		t.Fatalf("prepared = %v, %v", prepared, err)
	}
	fake.mu.Lock()
	sentBefore := len(fake.dispatches)
	fake.mu.Unlock()
	if sentBefore != 0 {
		t.Fatal("prepare must not dispatch")
	}

	confirmed, err := client.ConfirmWorkflowDispatch(ctx, &corev1.ConfirmWorkflowDispatchRequest{DispatchId: prepared.DispatchId})
	if err != nil || confirmed.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_OK || confirmed.DispatchedAt == nil || confirmed.Rejection != "" {
		t.Fatalf("confirmed = %v, %v", confirmed, err)
	}
	fake.mu.Lock()
	sent := fake.dispatches
	fake.mu.Unlock()
	if len(sent) != 1 || sent[0]["ref"] != "main" || sent[0]["inputs"].(map[string]any)["environment"] != "staging" {
		t.Fatalf("sent = %v", sent)
	}

	if _, err := client.ConfirmWorkflowDispatch(ctx, &corev1.ConfirmWorkflowDispatchRequest{DispatchId: prepared.DispatchId}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("second confirm = %v, want FailedPrecondition", err)
	}
}

func TestGitHubRejectionsAndRunIDsAreReported(t *testing.T) {
	client, id, fake, ctx := dispatchRig(t)
	prepare := func() string {
		t.Helper()
		prepared, err := client.PrepareWorkflowDispatch(ctx, &corev1.PrepareWorkflowDispatchRequest{
			RepositoryId: id, WorkflowId: 7, Ref: "main", Inputs: map[string]string{"environment": "production"},
		})
		if err != nil || prepared.DispatchId == "" {
			t.Fatalf("prepare = %v, %v", prepared, err)
		}
		return prepared.DispatchId
	}

	fake.mu.Lock()
	fake.reject = "Workflow does not have 'workflow_dispatch' trigger"
	fake.mu.Unlock()
	rejected, err := client.ConfirmWorkflowDispatch(ctx, &corev1.ConfirmWorkflowDispatchRequest{DispatchId: prepare()})
	if err != nil || !strings.Contains(rejected.Rejection, "workflow_dispatch") || rejected.DispatchedAt != nil {
		t.Fatalf("rejected = %v, %v", rejected, err)
	}

	fake.mu.Lock()
	fake.reject, fake.runID = "", 4242
	fake.mu.Unlock()
	withRun, err := client.ConfirmWorkflowDispatch(ctx, &corev1.ConfirmWorkflowDispatchRequest{DispatchId: prepare()})
	if err != nil || withRun.RunId != 4242 {
		t.Fatalf("with run id = %v, %v", withRun, err)
	}

	// A closed repository cannot be dispatched with an older confirmation.
	pending := prepare()
	if _, err := client.CloseRepository(ctx, &corev1.CloseRepositoryRequest{RepositoryId: id}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.ConfirmWorkflowDispatch(ctx, &corev1.ConfirmWorkflowDispatchRequest{DispatchId: pending}); status.Code(err) != codes.NotFound {
		t.Fatalf("closed repository = %v", err)
	}
}

func TestDispatchNeedsASignIn(t *testing.T) {
	client, id, _, ctx := dispatchRig(t)
	if _, err := client.ClearGitHubCredential(ctx, &corev1.ClearGitHubCredentialRequest{}); err != nil {
		t.Fatal(err)
	}
	prepared, err := client.PrepareWorkflowDispatch(ctx, &corev1.PrepareWorkflowDispatchRequest{RepositoryId: id, WorkflowId: 7, Ref: "main"})
	if err != nil || prepared.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT || prepared.DispatchId != "" {
		t.Fatalf("signed out = %v, %v", prepared, err)
	}
	if _, err := client.PrepareWorkflowDispatch(ctx, &corev1.PrepareWorkflowDispatchRequest{RepositoryId: id, Ref: "main"}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("missing workflow id = %v", err)
	}
}

func TestARepositoryWithoutALocalCloneIsReadAndRunByName(t *testing.T) {
	fake := &fakeDispatchGitHub{runID: 99}
	inner := fake.handler(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/user/installations":
			_, _ = w.Write([]byte(`{"total_count":1,"installations":[{"id":5,"account":{"login":"o","type":"Organization"},"repository_selection":"selected","html_url":"https://github.com/organizations/o/settings/installations/5","permissions":{"actions":"read","contents":"read","metadata":"read"}}]}`))
		case "/user/installations/5/repositories":
			_, _ = w.Write([]byte(`{"total_count":1,"repositories":[{"full_name":"o/r","name":"r","owner":{"login":"o"},"private":true,"default_branch":"main","html_url":"https://github.com/o/r","permissions":{"push":true}}]}`))
		case "/repos/o/r/actions/workflows":
			_, _ = w.Write([]byte(`{"total_count":1,"workflows":[{"id":7,"name":"Deploy","path":".github/workflows/deploy.yml","state":"active"}]}`))
		case "/repos/o/locked/actions/workflows":
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte(`{"message":"Resource not accessible by integration"}`))
		default:
			inner(w, r)
		}
	}))
	defer server.Close()

	path := socketPath(t)
	stop := startWith(t, path, Options{GitHubBaseURL: server.URL})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	listed, err := client.ListGitHubRepositories(ctx, &corev1.ListGitHubRepositoriesRequest{})
	if err != nil || listed.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT {
		t.Fatalf("signed out = %v, %v", listed, err)
	}
	if _, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghu_test"}); err != nil {
		t.Fatal(err)
	}
	listed, err = client.ListGitHubRepositories(ctx, &corev1.ListGitHubRepositoriesRequest{})
	if err != nil || listed.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_OK || len(listed.Repositories) != 1 ||
		listed.Repositories[0].FullName != "o/r" || !listed.Repositories[0].CanPush || len(listed.Installations) != 1 ||
		listed.Installations[0].RepositorySelection != "selected" {
		t.Fatalf("listed = %v, %v", listed, err)
	}

	workflows, err := client.ListGitHubWorkflows(ctx, &corev1.ListGitHubWorkflowsRequest{GithubRepository: "o/r"})
	if err != nil || workflows.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_OK || len(workflows.Workflows) != 1 {
		t.Fatalf("workflows = %v, %v", workflows, err)
	}
	refs, err := client.ListGitHubRefs(ctx, &corev1.ListGitHubRefsRequest{GithubRepository: "o/r"})
	if err != nil || refs.DefaultBranch != "main" || len(refs.Branches) != 2 {
		t.Fatalf("refs = %v, %v", refs, err)
	}
	described, err := client.DescribeWorkflowDispatch(ctx, &corev1.DescribeWorkflowDispatchRequest{GithubRepository: "o/r", WorkflowPath: ".github/workflows/deploy.yml", Ref: "main"})
	if err != nil || !described.Dispatchable || len(described.Inputs) != 2 {
		t.Fatalf("described = %v, %v", described, err)
	}
	prepared, err := client.PrepareWorkflowDispatch(ctx, &corev1.PrepareWorkflowDispatchRequest{
		GithubRepository: "o/r", WorkflowId: 7, Ref: "main", Inputs: map[string]string{"environment": "staging"},
	})
	if err != nil || prepared.DispatchId == "" {
		t.Fatalf("prepared = %v, %v", prepared, err)
	}
	confirmed, err := client.ConfirmWorkflowDispatch(ctx, &corev1.ConfirmWorkflowDispatchRequest{DispatchId: prepared.DispatchId})
	if err != nil || confirmed.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_OK || confirmed.RunId != 99 {
		t.Fatalf("confirmed = %v, %v", confirmed, err)
	}
	fake.mu.Lock()
	sent := fake.dispatches
	fake.mu.Unlock()
	if len(sent) != 1 || sent[0]["ref"] != "main" {
		t.Fatalf("dispatches = %v", sent)
	}
	// Still single use.
	if _, err := client.ConfirmWorkflowDispatch(ctx, &corev1.ConfirmWorkflowDispatchRequest{DispatchId: prepared.DispatchId}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("second confirm = %v", err)
	}

	// The owner's installation has not accepted Actions write yet.
	repository, err := client.GetGitHubRepository(ctx, &corev1.GetGitHubRepositoryRequest{GithubRepository: "o/r"})
	if err != nil || repository.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_OK || repository.CanPush ||
		repository.Installation == nil || strings.Join(repository.Installation.MissingPermissions, ",") != "actions: write" {
		t.Fatalf("repository = %v, %v", repository, err)
	}
	locked, err := client.ListGitHubWorkflows(ctx, &corev1.ListGitHubWorkflowsRequest{GithubRepository: "o/locked"})
	if err != nil || locked.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_PERMISSION_MISSING {
		t.Fatalf("locked = %v, %v", locked, err)
	}

	hidden, err := client.ListGitHubWorkflows(ctx, &corev1.ListGitHubWorkflowsRequest{GithubRepository: "o/hidden"})
	if err != nil || hidden.Status.Access != corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE {
		t.Fatalf("hidden = %v, %v", hidden, err)
	}
	for _, name := range []string{"o", "o/r/x", "../o/r", "o/..", "o/r?x"} {
		if _, err := client.ListWorkflowRuns(ctx, &corev1.ListWorkflowRunsRequest{GithubRepository: name}); status.Code(err) != codes.InvalidArgument {
			t.Errorf("%q: %v", name, err)
		}
	}
}
