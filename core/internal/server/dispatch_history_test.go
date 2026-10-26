//go:build !windows

package server

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// historyRig is dispatchRig with the repository opened as a workspace, which
// is what a dispatch history belongs to.
func historyRig(t *testing.T) (corev1.RunnirCoreClient, string, *fakeDispatchGitHub, context.Context) {
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
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: linkedRepository(t, "https://github.com/o/r.git"), WorkspaceId: testWorkspace})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := client.SetGitHubCredential(ctx, &corev1.SetGitHubCredentialRequest{Token: "ghu_test"}); err != nil {
		t.Fatal(err)
	}
	return client, opened.Repository.Id, fake, ctx
}

func sendDispatch(t *testing.T, client corev1.RunnirCoreClient, ctx context.Context, id, ref string, inputs map[string]string) *corev1.ConfirmWorkflowDispatchResponse {
	t.Helper()
	prepared, err := client.PrepareWorkflowDispatch(ctx, &corev1.PrepareWorkflowDispatchRequest{RepositoryId: id, WorkflowId: 7, Ref: ref, Inputs: inputs})
	if err != nil || prepared.DispatchId == "" {
		t.Fatalf("prepare = %v, %v", prepared, err)
	}
	confirmed, err := client.ConfirmWorkflowDispatch(ctx, &corev1.ConfirmWorkflowDispatchRequest{DispatchId: prepared.DispatchId})
	if err != nil {
		t.Fatal(err)
	}
	return confirmed
}

func TestAcceptedDispatchesAreKeptWithoutValuesThatLookSecret(t *testing.T) {
	client, id, fake, ctx := historyRig(t)

	first := sendDispatch(t, client, ctx, id, "main", map[string]string{"environment": "staging", "dry_run": "false"})
	if first.HistoryId == 0 {
		t.Fatalf("an accepted dispatch has a history entry: %v", first)
	}
	fake.mu.Lock()
	fake.runID = 4242
	fake.mu.Unlock()
	withToken := sendDispatch(t, client, ctx, id, "with-token", map[string]string{"environment": "production", "deploy_token": "ghp_supersecretvalue"})
	if withToken.HistoryId == 0 || withToken.HistoryId == first.HistoryId {
		t.Fatalf("second entry = %v", withToken)
	}

	history, err := client.ListDispatchHistory(ctx, &corev1.ListDispatchHistoryRequest{RepositoryId: id})
	if err != nil || len(history.Records) != 2 {
		t.Fatalf("history = %v, %v", history, err)
	}
	newest, older := history.Records[0], history.Records[1]
	if newest.Id != withToken.HistoryId || newest.Ref != "with-token" || newest.RunId != 4242 || newest.WorkflowPath != ".github/workflows/deploy.yml" ||
		newest.SentAt == nil || newest.Inputs["environment"] != "production" {
		t.Fatalf("newest = %v", newest)
	}
	if _, kept := newest.Inputs["deploy_token"]; kept || len(newest.OmittedInputs) != 1 || newest.OmittedInputs[0] != "deploy_token" {
		t.Fatalf("the token must be left out and named: %v", newest)
	}
	if strings.Contains(newest.String(), "ghp_supersecretvalue") {
		t.Fatal("the secret value reached the history")
	}
	if older.Id != first.HistoryId || older.RunId != 0 || older.Inputs["dry_run"] != "false" || len(older.OmittedInputs) != 0 {
		t.Fatalf("older = %v", older)
	}

	byWorkflow, _ := client.ListDispatchHistory(ctx, &corev1.ListDispatchHistoryRequest{RepositoryId: id, WorkflowPath: ".github/workflows/other.yml"})
	if len(byWorkflow.Records) != 0 {
		t.Fatalf("another workflow = %v", byWorkflow)
	}
	one, _ := client.ListDispatchHistory(ctx, &corev1.ListDispatchHistoryRequest{RepositoryId: id, Limit: 1})
	if len(one.Records) != 1 || one.Records[0].Id != withToken.HistoryId {
		t.Fatalf("limit 1 = %v", one)
	}
}

func TestARefusedDispatchLeavesNoHistory(t *testing.T) {
	client, id, fake, ctx := historyRig(t)
	fake.mu.Lock()
	fake.reject = "Workflow does not have 'workflow_dispatch' trigger"
	fake.mu.Unlock()
	rejected := sendDispatch(t, client, ctx, id, "main", map[string]string{"environment": "staging"})
	if rejected.Rejection == "" || rejected.HistoryId != 0 {
		t.Fatalf("rejected = %v", rejected)
	}
	if history, _ := client.ListDispatchHistory(ctx, &corev1.ListDispatchHistoryRequest{RepositoryId: id}); len(history.Records) != 0 {
		t.Fatalf("history = %v", history)
	}
}

func TestTheRunAFoundDispatchStartedCanBeLinkedOnce(t *testing.T) {
	client, id, _, ctx := historyRig(t)
	confirmed := sendDispatch(t, client, ctx, id, "main", map[string]string{"environment": "staging"})
	if _, err := client.LinkDispatchRun(ctx, &corev1.LinkDispatchRunRequest{RepositoryId: id, Id: confirmed.HistoryId, RunId: 555}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.LinkDispatchRun(ctx, &corev1.LinkDispatchRunRequest{RepositoryId: id, Id: confirmed.HistoryId, RunId: 777}); err != nil {
		t.Fatal(err)
	}
	history, _ := client.ListDispatchHistory(ctx, &corev1.ListDispatchHistoryRequest{RepositoryId: id})
	if len(history.Records) != 1 || history.Records[0].RunId != 555 {
		t.Fatalf("history = %v", history)
	}
	if _, err := client.LinkDispatchRun(ctx, &corev1.LinkDispatchRunRequest{RepositoryId: id, Id: confirmed.HistoryId}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("no run = %v", err)
	}
}

func TestAHistoryNeedsAWorkspace(t *testing.T) {
	client, id, _, ctx := dispatchRig(t) // opened without a workspace
	if confirmed := sendDispatch(t, client, ctx, id, "main", map[string]string{"environment": "staging"}); confirmed.HistoryId != 0 || confirmed.DispatchedAt == nil {
		t.Fatalf("without a workspace nothing is kept, the dispatch still goes: %v", confirmed)
	}
	if _, err := client.ListDispatchHistory(ctx, &corev1.ListDispatchHistoryRequest{RepositoryId: id}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("list = %v", err)
	}
}
