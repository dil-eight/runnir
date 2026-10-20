//go:build !windows

package server

import (
	"context"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func TestValidateWorkflowsReportsActionlintDiagnostics(t *testing.T) {
	root := repoWithWorkflows(t, map[string]string{
		"ci.yml":      "on: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo hi\n",
		"release.yml": "on: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    needs: [test]\n    steps:\n      - run: echo hi\n",
	})
	path := socketPath(t)
	stop := start(t, path)
	defer func() { _ = stop() }()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	id := opened.Repository.Id

	all, err := client.ValidateWorkflows(ctx, &corev1.ValidateWorkflowsRequest{RepositoryId: id})
	if err != nil || len(all.Workflows) != 2 || !strings.HasPrefix(all.Validator, "actionlint") {
		t.Fatalf("all = %v, %v", all, err)
	}
	release := all.Workflows[1]
	if release.WorkflowId != ".github/workflows/release.yml" || len(release.Diagnostics) != 1 ||
		release.Diagnostics[0].Kind != "job-needs" || release.Diagnostics[0].Line != 3 {
		t.Fatalf("release = %v", release)
	}
	if len(all.Workflows[0].Diagnostics) != 0 {
		t.Fatalf("ci = %v", all.Workflows[0])
	}

	one, err := client.ValidateWorkflows(ctx, &corev1.ValidateWorkflowsRequest{RepositoryId: id, WorkflowId: ".github/workflows/ci.yml"})
	if err != nil || len(one.Workflows) != 1 {
		t.Fatalf("one = %v, %v", one, err)
	}
	if _, err := client.ValidateWorkflows(ctx, &corev1.ValidateWorkflowsRequest{RepositoryId: id, WorkflowId: ".github/workflows/none.yml"}); status.Code(err) != codes.NotFound {
		t.Fatalf("unknown workflow = %v", err)
	}
	if _, err := client.ValidateWorkflows(ctx, &corev1.ValidateWorkflowsRequest{RepositoryId: "repo_missing"}); status.Code(err) != codes.NotFound {
		t.Fatalf("unknown repository = %v", err)
	}
}
