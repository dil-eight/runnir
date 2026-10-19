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
			_, _ = w.Write([]byte(`{"default_branch":"main"}`))
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
