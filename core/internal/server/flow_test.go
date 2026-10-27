//go:build !windows

package server

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func TestTheFlowOfAScenarioCarriesTheNewestRunOfEachLane(t *testing.T) {
	fake := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/repos/o/r":
			_, _ = w.Write([]byte(`{"full_name":"o/r","default_branch":"main"}`))
		case "/repos/o/r/actions/workflows":
			_, _ = w.Write([]byte(`{"total_count":2,"workflows":[{"id":3,"name":"CI","path":".github/workflows/ci.yml","state":"active"},{"id":4,"name":"Nightly","path":".github/workflows/nightly.yml","state":"active"}]}`))
		case "/repos/o/r/actions/runs":
			_, _ = w.Write([]byte(`{"workflow_runs":[
{"id":12,"workflow_id":4,"name":"Nightly","run_number":5,"event":"schedule","status":"completed","conclusion":"success","head_branch":"main","head_sha":"c3","created_at":"2026-10-20T03:00:00Z","updated_at":"2026-10-20T03:04:00Z"},
{"id":11,"workflow_id":3,"name":"CI","run_number":9,"event":"push","status":"completed","conclusion":"failure","head_branch":"main","head_sha":"b2","created_at":"2026-10-19T10:00:00Z","updated_at":"2026-10-19T10:04:00Z"},
{"id":10,"workflow_id":3,"name":"CI","run_number":8,"event":"pull_request","status":"completed","conclusion":"success","head_branch":"feature/retry","head_sha":"a1","created_at":"2026-10-18T10:00:00Z","updated_at":"2026-10-18T10:04:00Z"}]}`))
		case "/repos/o/r/pulls":
			_, _ = w.Write([]byte(`[]`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(fake.Close)
	client, stop, ctx := workspaceRig(t, t.TempDir(), fake.URL)
	defer stop()
	root := linkedRepository(t, "git@github.com:o/r.git")
	write := func(name, content string) {
		path := filepath.Join(root, name)
		_ = os.MkdirAll(filepath.Dir(path), 0o755)
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(".git/HEAD", "ref: refs/heads/feature/retry\n")
	write(".github/workflows/ci.yml", "name: CI\non:\n  pull_request:\n    branches: [main]\n  push:\n    branches: [main]\njobs:\n  lint: {runs-on: ubuntu-latest, steps: [{run: x}]}\n  build:\n    needs: lint\n    runs-on: ubuntu-latest\n    steps: [{run: x}]\n")
	write(".github/workflows/nightly.yml", "name: Nightly\non:\n  schedule: [{cron: '0 3 * * *'}]\njobs:\n  sweep: {runs-on: ubuntu-latest, steps: [{run: x}]}\n")
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root, WorkspaceId: testWorkspace})
	if err != nil {
		t.Fatal(err)
	}
	id := opened.Repository.Id
	if _, err := client.RefreshWorkspaceActivity(ctx, &corev1.RefreshWorkspaceActivityRequest{RepositoryId: id, Wait: true}); err != nil {
		t.Fatal(err)
	}

	got, err := client.GetFlow(ctx, &corev1.GetFlowRequest{RepositoryId: id})
	if err != nil {
		t.Fatal(err)
	}
	if got.Scenario.GetTitle() != "Pull request → main" || len(got.Scenarios) != 4 {
		t.Fatalf("scenarios = %v, chosen %v", got.Scenarios, got.Scenario)
	}
	if len(got.Lanes) != 1 || got.Lanes[0].WorkflowName != "CI" || got.Lanes[0].Run.GetId() != 10 ||
		got.Lanes[0].Jobs[1].Column != 1 || got.Lanes[0].Kind != corev1.LaneKind_LANE_KIND_DIRECT {
		t.Fatalf("lanes = %v", got.Lanes)
	}
	if len(got.Skipped) != 1 || got.Skipped[0].Reason != "runs on schedule" || !got.Changes.Applies {
		t.Fatalf("skipped = %v, changes = %v", got.Skipped, got.Changes)
	}

	merge, err := client.GetFlow(ctx, &corev1.GetFlowRequest{RepositoryId: id, Scenario: &corev1.Scenario{Kind: corev1.ScenarioKind_SCENARIO_KIND_MERGE, Target: "main"}})
	if err != nil || merge.Scenario.GetTitle() != "Merge into main" || merge.Lanes[0].Run.GetId() != 11 {
		t.Fatalf("merge = %v, %v", merge, err)
	}
	nightly, err := client.GetFlow(ctx, &corev1.GetFlowRequest{RepositoryId: id, Scenario: &corev1.Scenario{Kind: corev1.ScenarioKind_SCENARIO_KIND_SCHEDULE}})
	if err != nil || len(nightly.Lanes) != 1 || nightly.Lanes[0].Run.GetId() != 12 || nightly.Changes.Applies {
		t.Fatalf("schedule = %v, %v", nightly, err)
	}
	// A pull request without a base is no scenario: the default is planned.
	fallback, err := client.GetFlow(ctx, &corev1.GetFlowRequest{RepositoryId: id, Scenario: &corev1.Scenario{Kind: corev1.ScenarioKind_SCENARIO_KIND_PULL_REQUEST}})
	if err != nil || fallback.Scenario.GetTitle() != "Pull request → main" {
		t.Fatalf("fallback = %v, %v", fallback, err)
	}
	if _, err := client.GetFlow(ctx, &corev1.GetFlowRequest{RepositoryId: "repo_nope"}); err == nil {
		t.Fatal("an unknown repository is refused")
	}
}
