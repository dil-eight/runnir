//go:build !windows

package server

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/scanner"
)

func TestSaveWorkflowFileOverGRPC(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	original := "name: CI\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps: [{run: echo}]\n"
	root := repoWithWorkflows(t, map[string]string{"ci.yml": original})
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	repo := opened.Repository.Id
	file := filepath.Join(root, ".github", "workflows", "ci.yml")

	edited := "name: Renamed\non: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps: [{run: echo}]\n"
	saved, err := client.SaveWorkflowFile(ctx, &corev1.SaveWorkflowFileRequest{
		RepositoryId: repo, WorkflowId: ".github/workflows/ci.yml", Content: edited, BaseSha256: scanner.SHA256([]byte(original)),
	})
	if err != nil || saved.Conflict || saved.Sha256 != scanner.SHA256([]byte(edited)) {
		t.Fatalf("save = %v, %v", saved, err)
	}
	if data, _ := os.ReadFile(file); string(data) != edited {
		t.Fatalf("file = %q", data)
	}
	// The repository was scanned again: the workflow has its new name.
	listed, err := client.ListWorkflows(ctx, &corev1.ListWorkflowsRequest{RepositoryId: repo})
	if err != nil || len(listed.Workflows) != 1 || listed.Workflows[0].Name != "Renamed" {
		t.Fatalf("workflows = %v, %v", listed, err)
	}

	// A second save from the old version is a conflict and changes nothing.
	again, err := client.SaveWorkflowFile(ctx, &corev1.SaveWorkflowFileRequest{
		RepositoryId: repo, WorkflowId: ".github/workflows/ci.yml", Content: "stale\n", BaseSha256: scanner.SHA256([]byte(original)),
	})
	if err != nil || !again.Conflict || again.Sha256 != scanner.SHA256([]byte(edited)) {
		t.Fatalf("stale save = %v, %v", again, err)
	}
	if data, _ := os.ReadFile(file); string(data) != edited {
		t.Fatalf("file changed on conflict: %q", data)
	}

	for name, tc := range map[string]struct {
		request *corev1.SaveWorkflowFileRequest
		want    codes.Code
	}{
		"unknown repository": {&corev1.SaveWorkflowFileRequest{RepositoryId: "repo_nope", WorkflowId: ".github/workflows/ci.yml"}, codes.NotFound},
		"unknown workflow":   {&corev1.SaveWorkflowFileRequest{RepositoryId: repo, WorkflowId: "../outside.yml"}, codes.NotFound},
	} {
		if _, err := client.SaveWorkflowFile(ctx, tc.request); status.Code(err) != tc.want {
			t.Errorf("%s: %v, want %v", name, err, tc.want)
		}
	}
	if err := os.Chmod(file, 0o444); err != nil {
		t.Fatal(err)
	}
	if _, err := client.SaveWorkflowFile(ctx, &corev1.SaveWorkflowFileRequest{
		RepositoryId: repo, WorkflowId: ".github/workflows/ci.yml", Content: "x\n", Overwrite: true,
	}); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("read-only = %v", err)
	}
}

func TestCreateAndRenameWorkflowFilesOverGRPC(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	repo := opened.Repository.Id

	// A repository without workflows gets the folders and a starter.
	created, err := client.CreateWorkflowFile(ctx, &corev1.CreateWorkflowFileRequest{RepositoryId: repo, FileName: "deploy.yml"})
	if err != nil || created.WorkflowId != ".github/workflows/deploy.yml" {
		t.Fatalf("create = %v, %v", created, err)
	}
	listed, err := client.ListWorkflows(ctx, &corev1.ListWorkflowsRequest{RepositoryId: repo})
	if err != nil || len(listed.Workflows) != 1 || listed.Workflows[0].Name != "deploy" || listed.Workflows[0].ParseError != "" {
		t.Fatalf("workflows = %v, %v", listed, err)
	}
	// The starter passes actionlint.
	report, err := client.ValidateWorkflows(ctx, &corev1.ValidateWorkflowsRequest{RepositoryId: repo})
	if err != nil || len(report.Workflows) != 1 || len(report.Workflows[0].Diagnostics) != 0 || report.Workflows[0].Problem != "" {
		t.Fatalf("validation = %v, %v", report, err)
	}

	renamed, err := client.RenameWorkflowFile(ctx, &corev1.RenameWorkflowFileRequest{
		RepositoryId: repo, WorkflowId: ".github/workflows/deploy.yml", NewFileName: "release.yml",
	})
	if err != nil || renamed.WorkflowId != ".github/workflows/release.yml" {
		t.Fatalf("rename = %v, %v", renamed, err)
	}
	listed, err = client.ListWorkflows(ctx, &corev1.ListWorkflowsRequest{RepositoryId: repo})
	if err != nil || len(listed.Workflows) != 1 || listed.Workflows[0].Id != ".github/workflows/release.yml" {
		t.Fatalf("after rename = %v, %v", listed, err)
	}

	if _, err := client.CreateWorkflowFile(ctx, &corev1.CreateWorkflowFileRequest{RepositoryId: repo, FileName: "ci.yml"}); err != nil {
		t.Fatal(err)
	}
	for name, tc := range map[string]struct {
		call func() error
		want codes.Code
	}{
		"taken name": {func() error {
			_, err := client.CreateWorkflowFile(ctx, &corev1.CreateWorkflowFileRequest{RepositoryId: repo, FileName: "release.yml"})
			return err
		}, codes.AlreadyExists},
		"rename onto another file": {func() error {
			_, err := client.RenameWorkflowFile(ctx, &corev1.RenameWorkflowFileRequest{RepositoryId: repo, WorkflowId: ".github/workflows/ci.yml", NewFileName: "release.yml"})
			return err
		}, codes.AlreadyExists},
		"bad name": {func() error {
			_, err := client.CreateWorkflowFile(ctx, &corev1.CreateWorkflowFileRequest{RepositoryId: repo, FileName: "../x.yml"})
			return err
		}, codes.InvalidArgument},
		"unknown workflow": {func() error {
			_, err := client.RenameWorkflowFile(ctx, &corev1.RenameWorkflowFileRequest{RepositoryId: repo, WorkflowId: ".github/workflows/gone.yml", NewFileName: "x.yml"})
			return err
		}, codes.NotFound},
		"unknown repository": {func() error {
			_, err := client.CreateWorkflowFile(ctx, &corev1.CreateWorkflowFileRequest{RepositoryId: "repo_nope", FileName: "x.yml"})
			return err
		}, codes.NotFound},
	} {
		if err := tc.call(); status.Code(err) != tc.want {
			t.Errorf("%s: %v, want %v", name, err, tc.want)
		}
	}
}
