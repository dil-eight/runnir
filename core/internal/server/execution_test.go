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

	"runnir/core/internal/execution"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func startWith(t *testing.T, path string, options Options) (stop func() error) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() { result <- RunWithOptions(ctx, path, options) }()
	waitForSocket(t, path, result)
	return func() error { cancel(); return <-result }
}

func repoWithWorkflows(t *testing.T, files map[string]string) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".github", "workflows"), 0o755); err != nil {
		t.Fatal(err)
	}
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(root, ".github", "workflows", name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func collect(t *testing.T, stream corev1.RunnirCore_SubscribeEventsClient, want int) []*corev1.CoreEvent {
	t.Helper()
	var out []*corev1.CoreEvent
	for len(out) < want {
		e, err := stream.Recv()
		if err != nil {
			t.Fatalf("recv after %d events: %v", len(out), err)
		}
		out = append(out, e)
	}
	return out
}

func TestStartWorkflowWithStubRunnerFailsHonestly(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	root := repoWithWorkflows(t, map[string]string{"ci.yml": "on: push\njobs:\n  a: {}\n", "bad.yml": "on: [push\n"})
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	id := opened.Repository.Id
	stream, err := client.SubscribeEvents(ctx, &corev1.SubscribeEventsRequest{RepositoryIds: []string{id}})
	if err != nil {
		t.Fatal(err)
	}
	next(t, stream) // CORE_READY

	response, err := client.StartWorkflow(ctx, &corev1.StartWorkflowRequest{RepositoryId: id, WorkflowId: ".github/workflows/ci.yml", Ref: "main"})
	if err != nil {
		t.Fatal(err)
	}
	if response.ExecutionId == "" || response.RepositoryId != id || response.State != corev1.ExecutionState_EXECUTION_STATE_RUNNING {
		t.Fatalf("response = %v", response)
	}
	got := collect(t, stream, 2)
	if got[0].Type != corev1.CoreEventType_CORE_EVENT_TYPE_WORKFLOW_STARTED || got[0].ExecutionId != response.ExecutionId {
		t.Fatalf("first = %v", got[0])
	}
	if got[1].Type != corev1.CoreEventType_CORE_EVENT_TYPE_WORKFLOW_FAILED || got[1].Message != execution.ErrEngineUnavailable.Error() {
		t.Fatalf("second = %v", got[1])
	}
}

func TestStartWorkflowRejectsBadRequests(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	root := repoWithWorkflows(t, map[string]string{"bad.yml": "on: [push\n"})
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	for name, tc := range map[string]struct {
		request *corev1.StartWorkflowRequest
		want    codes.Code
	}{
		"unknown repository": {&corev1.StartWorkflowRequest{RepositoryId: "repo_nope", WorkflowId: "x"}, codes.NotFound},
		"unknown workflow":   {&corev1.StartWorkflowRequest{RepositoryId: opened.Repository.Id, WorkflowId: "x"}, codes.NotFound},
		"parse error":        {&corev1.StartWorkflowRequest{RepositoryId: opened.Repository.Id, WorkflowId: ".github/workflows/bad.yml"}, codes.FailedPrecondition},
	} {
		if _, err := client.StartWorkflow(ctx, tc.request); status.Code(err) != tc.want {
			t.Errorf("%s: %v, want %v", name, err, tc.want)
		}
	}
}

func TestExecutionLimitQueueAndCancelOnRepositoryClose(t *testing.T) {
	path := socketPath(t)
	hold := execution.RunnerFunc(func(ctx context.Context, _ execution.Job) error {
		<-ctx.Done()
		return ctx.Err()
	})
	stop := startWith(t, path, Options{MaxExecutions: 3, Runner: hold})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	root := repoWithWorkflows(t, map[string]string{"ci.yml": "on: push\njobs:\n  a: {}\n"})
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	id := opened.Repository.Id
	stream, err := client.SubscribeEvents(ctx, &corev1.SubscribeEventsRequest{RepositoryIds: []string{id}})
	if err != nil {
		t.Fatal(err)
	}
	next(t, stream)

	var states []corev1.ExecutionState
	for i := 0; i < 5; i++ {
		r, err := client.StartWorkflow(ctx, &corev1.StartWorkflowRequest{RepositoryId: id, WorkflowId: ".github/workflows/ci.yml"})
		if err != nil {
			t.Fatal(err)
		}
		states = append(states, r.State)
	}
	for i, state := range states {
		want := corev1.ExecutionState_EXECUTION_STATE_RUNNING
		if i >= 3 {
			want = corev1.ExecutionState_EXECUTION_STATE_QUEUED
		}
		if state != want {
			t.Fatalf("execution %d: %v, want %v", i, state, want)
		}
	}

	if _, err := client.CloseRepository(ctx, &corev1.CloseRepositoryRequest{RepositoryId: id}); err != nil {
		t.Fatal(err)
	}
	// Per execution: 3 started, 2 queued; closing cancels all 5. Count the
	// cancellations and the closed event, ignoring the order between them.
	cancelled, closed := 0, 0
	for cancelled < 5 || closed < 1 {
		e, err := stream.Recv()
		if err != nil {
			t.Fatalf("recv: %v (cancelled=%d closed=%d)", err, cancelled, closed)
		}
		switch {
		case e.ExecutionState == corev1.ExecutionState_EXECUTION_STATE_CANCELLED:
			cancelled++
		case e.Type == corev1.CoreEventType_CORE_EVENT_TYPE_REPOSITORY_CLOSED:
			closed++
		}
	}
}
