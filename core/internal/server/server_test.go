//go:build !windows

package server

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	"runnir/core/internal/buildinfo"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// Unix socket paths are short-limited and t.TempDir() is long on macOS.
func socketPath(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "rn")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, "core.sock")
}

func start(t *testing.T, path string) (stop func() error) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() { result <- Run(ctx, path) }()
	waitForSocket(t, path, result)
	return func() error { cancel(); return <-result }
}

func waitForSocket(t *testing.T, path string, result chan error) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case err := <-result:
			result <- err
			return
		default:
		}
		if info, err := os.Stat(path); err == nil && info.Mode()&os.ModeSocket != 0 {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("socket did not appear")
}

func TestHealthCheckOverUnixSocket(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	defer stop()

	conn, err := grpc.NewClient("unix://"+path, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	response, err := corev1.NewRunnirCoreClient(conn).HealthCheck(ctx, &corev1.HealthCheckRequest{})
	if err != nil {
		t.Fatal(err)
	}
	if response.ProcessId != uint32(os.Getpid()) {
		t.Fatalf("process id = %d, want %d", response.ProcessId, os.Getpid())
	}
	if response.CoreVersion != buildinfo.Version || response.ProtocolVersion != buildinfo.ProtocolVersion {
		t.Fatalf("unexpected response: %v", response)
	}
}

func TestSecondInstanceIsRefused(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	defer stop()

	err := Run(context.Background(), path)
	if !errors.Is(err, ErrAlreadyRunning) {
		t.Fatalf("want ErrAlreadyRunning, got %v", err)
	}
	// The refused attempt must not disturb the running Core.
	if _, statErr := os.Stat(path); statErr != nil {
		t.Fatalf("running core lost its socket: %v", statErr)
	}
}

func TestStaleSocketIsReplaced(t *testing.T) {
	path := socketPath(t)
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	stop := start(t, path)
	if err := stop(); err != nil {
		t.Fatal(err)
	}
}

func TestShutdownRemovesSocketAndReleasesLock(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	if err := stop(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("socket should be removed, stat err = %v", err)
	}
	// Restart works because the advisory lock was released.
	stop = start(t, path)
	if err := stop(); err != nil {
		t.Fatal(err)
	}
}

func TestSocketIsOwnerOnly(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	defer stop()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm&0o077 != 0 {
		t.Fatalf("socket permissions too open: %v", perm)
	}
}

func TestOverlongSocketPathIsRejected(t *testing.T) {
	err := Run(context.Background(), "/tmp/"+strings.Repeat("a", MaxSocketPathBytes))
	if err == nil || !strings.Contains(err.Error(), "limit") {
		t.Fatalf("want length error, got %v", err)
	}
}

func connect(t *testing.T, path string) corev1.RunnirCoreClient {
	t.Helper()
	conn, err := grpc.NewClient("unix://"+path, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	return corev1.NewRunnirCoreClient(conn)
}

func TestRepositoryLifecycleOverGRPC(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	repoDir, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	first, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repoDir})
	if err != nil {
		t.Fatal(err)
	}
	second, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repoDir})
	if err != nil {
		t.Fatal(err)
	}
	if first.Repository.Id == "" || first.Repository.Id != second.Repository.Id {
		t.Fatalf("open is not idempotent: %q vs %q", first.Repository.Id, second.Repository.Id)
	}
	health, err := client.HealthCheck(ctx, &corev1.HealthCheckRequest{})
	if err != nil || health.OpenRepositoryCount != 1 {
		t.Fatalf("health = %v, %v", health, err)
	}
	id := first.Repository.Id
	if _, err := client.RefreshRepository(ctx, &corev1.RefreshRepositoryRequest{RepositoryId: id}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.CloseRepository(ctx, &corev1.CloseRepositoryRequest{RepositoryId: id}); err != nil {
		t.Fatal(err)
	}
	_, err = client.RefreshRepository(ctx, &corev1.RefreshRepositoryRequest{RepositoryId: id})
	if status.Code(err) != codes.NotFound {
		t.Fatalf("refresh after close = %v, want NotFound", err)
	}
	_, err = client.CloseRepository(ctx, &corev1.CloseRepositoryRequest{RepositoryId: id})
	if status.Code(err) != codes.NotFound {
		t.Fatalf("second close = %v, want NotFound", err)
	}
}

func TestOpenRepositoryRejectsInvalidPath(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	defer stop()
	_, err := connect(t, path).OpenRepository(context.Background(), &corev1.OpenRepositoryRequest{Path: "relative"})
	if status.Code(err) != codes.InvalidArgument {
		t.Fatalf("err = %v, want InvalidArgument", err)
	}
}

func TestListWorkflowsAndBranchOverGRPC(t *testing.T) {
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
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(root, ".git"), 0o755))
	must(os.WriteFile(filepath.Join(root, ".git", "HEAD"), []byte("ref: refs/heads/main\n"), 0o644))
	must(os.MkdirAll(filepath.Join(root, ".github", "workflows"), 0o755))
	workflow := filepath.Join(root, ".github", "workflows", "ci.yml")
	must(os.WriteFile(workflow, []byte("name: CI\non: push\njobs:\n  build: {}\n  test:\n    needs: build\n"), 0o644))

	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	if opened.Repository.Branch != "main" || opened.Repository.WorkflowCount != 1 {
		t.Fatalf("repository = %v", opened.Repository)
	}
	listed, err := client.ListWorkflows(ctx, &corev1.ListWorkflowsRequest{RepositoryId: opened.Repository.Id})
	if err != nil || len(listed.Workflows) != 1 {
		t.Fatalf("list = %v, %v", listed, err)
	}
	w := listed.Workflows[0]
	if w.Name != "CI" || len(w.Jobs) != 2 || w.Jobs[1].Needs[0] != "build" {
		t.Fatalf("workflow = %v", w)
	}

	// An external edit is picked up only by an explicit refresh.
	must(os.WriteFile(filepath.Join(root, ".git", "HEAD"), []byte("ref: refs/heads/dev\n"), 0o644))
	must(os.WriteFile(filepath.Join(root, ".github", "workflows", "extra.yml"), []byte("on: push\njobs: {}\n"), 0o644))
	again, err := client.ListWorkflows(ctx, &corev1.ListWorkflowsRequest{RepositoryId: opened.Repository.Id})
	if err != nil || len(again.Workflows) != 1 {
		t.Fatalf("list before refresh = %v, %v", again, err)
	}
	refreshed, err := client.RefreshRepository(ctx, &corev1.RefreshRepositoryRequest{RepositoryId: opened.Repository.Id})
	if err != nil || refreshed.Repository.Branch != "dev" || refreshed.Repository.WorkflowCount != 2 {
		t.Fatalf("refresh = %v, %v", refreshed, err)
	}

	_, err = client.ListWorkflows(ctx, &corev1.ListWorkflowsRequest{RepositoryId: "repo_nope"})
	if status.Code(err) != codes.NotFound {
		t.Fatalf("unknown id = %v", err)
	}
}
