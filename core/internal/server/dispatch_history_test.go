//go:build !windows

package server

import (
	"context"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
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
	withToken := sendDispatch(t, client, ctx, id, "with-token", map[string]string{
		"environment": "production", "deploy_token": "ghp_supersecretvalue", "notes": "use AKIAABCDEFGHIJKLMNOP for this one",
	})
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
	// "notes" does not sound secret, but its value is an AWS access key.
	if _, kept := newest.Inputs["deploy_token"]; kept || !slices.Equal(newest.OmittedInputs, []string{"deploy_token", "notes"}) {
		t.Fatalf("the token must be left out and named: %v", newest)
	}
	if strings.Contains(newest.String(), "ghp_supersecretvalue") || strings.Contains(newest.String(), "AKIAABCDEFGHIJKLMNOP") {
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

func TestClearingTheHistoryForgetsItsEntries(t *testing.T) {
	client, id, _, ctx := historyRig(t)
	sendDispatch(t, client, ctx, id, "main", map[string]string{"environment": "staging"})
	sendDispatch(t, client, ctx, id, "main", map[string]string{"environment": "production"})
	cleared, err := client.ClearDispatchHistory(ctx, &corev1.ClearDispatchHistoryRequest{RepositoryId: id})
	if err != nil || cleared.Removed != 2 {
		t.Fatalf("cleared = %v, %v", cleared, err)
	}
	if history, _ := client.ListDispatchHistory(ctx, &corev1.ListDispatchHistoryRequest{RepositoryId: id}); len(history.Records) != 0 {
		t.Fatalf("history = %v", history)
	}
	if again, err := client.ClearDispatchHistory(ctx, &corev1.ClearDispatchHistoryRequest{RepositoryId: id}); err != nil || again.Removed != 0 {
		t.Fatalf("clearing nothing = %v, %v", again, err)
	}
}

func TestARunsWorkflowIsReadAtItsCommit(t *testing.T) {
	client, id, fake, ctx := historyRig(t)
	reads := func() int {
		fake.mu.Lock()
		defer fake.mu.Unlock()
		return fake.workflowReads
	}
	got, err := client.GetRunWorkflow(ctx, &corev1.GetRunWorkflowRequest{RepositoryId: id, RunId: 31})
	if err != nil || got.Problem != "" || got.WorkflowPath != ".github/workflows/deploy.yml" {
		t.Fatalf("workflow = %v, %v", got, err)
	}
	if len(got.Jobs) != 3 || got.Jobs[2].Id != "build" || len(got.Jobs[2].Needs) != 2 || got.Jobs[1].Name != "unit-tests" {
		t.Fatalf("jobs = %v", got.Jobs)
	}
	// A commit GitHub no longer serves is a problem to show, not a failure.
	gone, err := client.GetRunWorkflow(ctx, &corev1.GetRunWorkflowRequest{RepositoryId: id, RunId: 32})
	if err != nil || gone.Problem == "" || len(gone.Jobs) != 0 || gone.Status.GetAccess() != corev1.GithubAccess_GITHUB_ACCESS_OK {
		t.Fatalf("gone = %v, %v", gone, err)
	}
	broken, err := client.GetRunWorkflow(ctx, &corev1.GetRunWorkflowRequest{RepositoryId: id, RunId: 33})
	if err != nil || !strings.Contains(broken.Problem, "does not parse") {
		t.Fatalf("broken = %v, %v", broken, err)
	}
	if _, err := client.GetRunWorkflow(ctx, &corev1.GetRunWorkflowRequest{RepositoryId: id}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("no run = %v", err)
	}

	// The run's own path counts: a file renamed since is read where the run found it.
	renamed, err := client.GetRunWorkflow(ctx, &corev1.GetRunWorkflowRequest{RepositoryId: id, RunId: 34})
	if err != nil || renamed.Problem != "" || renamed.WorkflowPath != ".github/workflows/old-deploy.yml" || len(renamed.Jobs) != 3 {
		t.Fatalf("renamed = %v, %v", renamed, err)
	}

	// Selecting a run again reads nothing from GitHub, whether its file was there or not.
	before := reads()
	for _, run := range []int64{31, 32, 34} {
		again, err := client.GetRunWorkflow(ctx, &corev1.GetRunWorkflowRequest{RepositoryId: id, RunId: run})
		if err != nil || (run == 32) != (again.Problem != "") {
			t.Fatalf("run %d again = %v, %v", run, again, err)
		}
	}
	if after := reads(); after != before {
		t.Fatalf("a run read again made %d GitHub requests", after-before)
	}
}

func TestARunsSkippedJobsAreExplained(t *testing.T) {
	client, id, fake, ctx := historyRig(t)
	reads := func() int {
		fake.mu.Lock()
		defer fake.mu.Unlock()
		return fake.workflowReads
	}
	got, err := client.GetRunWorkflow(ctx, &corev1.GetRunWorkflowRequest{RepositoryId: id, RunId: 35})
	if err != nil || got.Problem != "" || got.SourceNote != "" {
		t.Fatalf("workflow = %v, %v", got, err)
	}
	skips := map[string]*corev1.JobSkip{}
	for _, s := range got.Skips {
		skips[s.JobId] = s
	}
	if s := skips["publish"]; s.GetKind() != corev1.SkipKind_SKIP_KIND_NEEDS || s.Need != "build" || s.NeedResult != "failure" {
		t.Fatalf("publish = %v", s)
	}
	if s := skips["docs"]; s.GetKind() != corev1.SkipKind_SKIP_KIND_CONDITION_FALSE || len(s.Values) != 1 ||
		s.Values[0].Name != "github.event_name" || s.Values[0].Value != "push" {
		t.Fatalf("docs = %v", s)
	}
	if s := skips["changelog"]; s.GetKind() != corev1.SkipKind_SKIP_KIND_NOT_KNOWN || len(s.Unknown) != 1 || s.Unknown[0] != "vars.RELEASE_NOTES" {
		t.Fatalf("changelog = %v", s)
	}
	if s := skips["preview"]; s.GetKind() != corev1.SkipKind_SKIP_KIND_NOT_IN_RUN || s.Note == "" {
		t.Fatalf("preview = %v", s)
	}
	if len(got.Skips) != 4 {
		t.Fatalf("skips = %v", got.Skips)
	}

	// A finished run's run and jobs are kept with its file: asked again, nothing is read.
	before := reads()
	if again, err := client.GetRunWorkflow(ctx, &corev1.GetRunWorkflowRequest{RepositoryId: id, RunId: 35}); err != nil || len(again.Skips) != 4 {
		t.Fatalf("again = %v, %v", again, err)
	}
	if after := reads(); after != before {
		t.Fatalf("a finished run read again made %d GitHub requests", after-before)
	}

	pr, err := client.GetRunWorkflow(ctx, &corev1.GetRunWorkflowRequest{RepositoryId: id, RunId: 36})
	if err != nil || pr.SourceNote != "GitHub ran this file merged with the base, which may differ." {
		t.Fatalf("pull request = %v, %v", pr, err)
	}
	for _, s := range pr.Skips {
		if s.JobId == "docs" && (s.GetKind() != corev1.SkipKind_SKIP_KIND_NOT_KNOWN || !strings.Contains(s.Note, "reads its condition as true")) {
			t.Fatalf("docs on a pull request = %v", s)
		}
	}
}

func TestARunsFactsNameItsRef(t *testing.T) {
	refs := func() (map[string]bool, map[string]bool) {
		return map[string]bool{"v1.0": true, "both": true}, map[string]bool{"main": true, "both": true}
	}
	ref := func(run github.Run) any { return runFacts(run, "o/r", "main", nil, refs).Context["github.ref"] }
	if got := ref(github.Run{Event: "push", Branch: "v1.0"}); got != "refs/tags/v1.0" {
		t.Fatalf("tag = %v", got)
	}
	if got := ref(github.Run{Event: "push", Branch: "main"}); got != "refs/heads/main" {
		t.Fatalf("branch = %v", got)
	}
	for _, name := range []string{"both", "gone"} {
		if got, ok := runFacts(github.Run{Event: "push", Branch: name}, "o/r", "main", nil, refs).Context["github.ref"]; ok {
			t.Fatalf("%s is a tag and a branch, or neither, so github.ref is unknown: %v", name, got)
		}
	}
	if got := ref(github.Run{Event: "pull_request", Branch: "feature", PullRequests: []int64{12}}); got != "refs/pull/12/merge" {
		t.Fatalf("pull request = %v", got)
	}
	pull := &github.RepositoryPullRequest{Number: 12, BaseRef: "release", Draft: true}
	facts := runFacts(github.Run{Event: "pull_request_target", Branch: "feature", PullRequests: []int64{12}}, "o/r", "main", pull, refs)
	if facts.Context["github.ref"] != "refs/heads/release" || facts.Context["github.base_ref"] != "release" || facts.Context["github.event.pull_request.draft"] != true {
		t.Fatalf("pull_request_target = %v", facts.Context)
	}
	if got := ref(github.Run{Event: "workflow_run", Branch: "feature"}); got != "refs/heads/main" {
		t.Fatalf("workflow_run runs on the default branch: %v", got)
	}
	if f := runFacts(github.Run{Event: "push", Status: "in_progress"}, "o/r", "", nil, nil); !f.Active || f.Cancelled {
		t.Fatalf("active = %+v", f)
	}
	if f := runFacts(github.Run{Event: "push", Status: "completed", Conclusion: "cancelled"}, "o/r", "", nil, nil); f.Active || !f.Cancelled {
		t.Fatalf("cancelled = %+v", f)
	}
}
