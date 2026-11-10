package mcpbridge

import (
	"context"
	"errors"
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// app answers every request it receives with answer(request).
func app(t *testing.T, b *Broker, answer func(*corev1.McpRequest) *corev1.AnswerMcpRequestRequest) func() {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	requests, stop := b.Subscribe(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		for request := range requests {
			if a := answer(request); a != nil {
				a.Id = request.Id
				if err := b.Answer(a); err != nil {
					t.Errorf("answer: %v", err)
				}
			}
		}
	}()
	return func() { stop(); cancel(); <-done }
}

func setRequest() *corev1.McpRequest {
	return &corev1.McpRequest{Client: "claude-code", Repository: "/Users/me/r", Set: "production",
		Secrets: values("API_KEY", "s3cr3t-VALUE"), Variables: values("REGION", "eu-west-1")}
}

func TestAListIsAnsweredByTheApp(t *testing.T) {
	b := NewBroker(time.Second)
	var seen *corev1.McpRequest
	defer app(t, b, func(r *corev1.McpRequest) *corev1.AnswerMcpRequestRequest {
		seen = r
		return &corev1.AnswerMcpRequestRequest{Answer: &corev1.AnswerMcpRequestRequest_Sets{Sets: &corev1.McpValueSets{Workspace: "r"}}}
	})()
	sets, err := b.List(context.Background(), "codex", "/Users/me/r")
	if err != nil || sets.Workspace != "r" {
		t.Fatalf("sets = %v, %v", sets, err)
	}
	if seen.Tool != corev1.McpTool_MCP_TOOL_LIST_VALUE_SETS || seen.Client != "codex" || seen.Repository != "/Users/me/r" || seen.Id == "" {
		t.Fatalf("request = %v", seen)
	}
}

func TestASetIsAnsweredByTheApp(t *testing.T) {
	b := NewBroker(time.Second)
	var seen *corev1.McpRequest
	defer app(t, b, func(r *corev1.McpRequest) *corev1.AnswerMcpRequestRequest {
		seen = r
		return &corev1.AnswerMcpRequestRequest{Answer: &corev1.AnswerMcpRequestRequest_Saved{Saved: &corev1.McpSavedValues{
			Workspace: "r", Set: "production", Secrets: []string{"API_KEY"}, Variables: []string{"REGION"}}}}
	})()
	saved, err := b.Set(context.Background(), setRequest())
	if err != nil || saved.Secrets[0] != "API_KEY" {
		t.Fatalf("saved = %v, %v", saved, err)
	}
	if seen.Tool != corev1.McpTool_MCP_TOOL_SET_VALUES || seen.Set != "production" || seen.Secrets[0].Value != "s3cr3t-VALUE" || !seen.Action {
		t.Fatalf("request = %v", seen)
	}
}

func TestARefusalReachesTheCaller(t *testing.T) {
	b := NewBroker(time.Second)
	defer app(t, b, func(*corev1.McpRequest) *corev1.AnswerMcpRequestRequest {
		return &corev1.AnswerMcpRequestRequest{Answer: &corev1.AnswerMcpRequestRequest_Refusal{Refusal: "Cancelled in Runnir."}}
	})()
	_, err := b.Set(context.Background(), setRequest())
	var refusal Refusal
	if !errors.As(err, &refusal) || string(refusal) != "Cancelled in Runnir." {
		t.Fatalf("err = %v", err)
	}
}

func TestACheckFailsBeforeTheAppIsAsked(t *testing.T) {
	b := NewBroker(time.Second)
	asked := false
	defer app(t, b, func(*corev1.McpRequest) *corev1.AnswerMcpRequestRequest { asked = true; return nil })()
	request := setRequest()
	request.Secrets = values("GITHUB_SHA", "x")
	if _, err := b.Set(context.Background(), request); err == nil {
		t.Fatal("no refusal")
	}
	if asked {
		t.Fatal("the app was asked")
	}
}

func TestWithoutTheAppNothingWaits(t *testing.T) {
	b := NewBroker(time.Minute)
	if _, err := b.List(context.Background(), "c", "/r"); !errors.Is(err, ErrNoApp) {
		t.Fatalf("err = %v", err)
	}
}

func TestAnUnansweredRequestTimesOut(t *testing.T) {
	b := NewBroker(50 * time.Millisecond)
	defer app(t, b, func(*corev1.McpRequest) *corev1.AnswerMcpRequestRequest { return nil })()
	if _, err := b.Set(context.Background(), setRequest()); !errors.Is(err, ErrSetTimeout) {
		t.Fatalf("err = %v", err)
	}
}

func TestOneSetWaitsAtATime(t *testing.T) {
	b := NewBroker(time.Second)
	arrived := make(chan *corev1.McpRequest, 2)
	defer app(t, b, func(r *corev1.McpRequest) *corev1.AnswerMcpRequestRequest { arrived <- r; return nil })()
	first := make(chan error, 1)
	go func() { _, err := b.Set(context.Background(), setRequest()); first <- err }()
	waiting := <-arrived
	if _, err := b.Set(context.Background(), setRequest()); !errors.Is(err, ErrBusy) {
		t.Fatalf("second = %v", err)
	}
	// A list still goes through while a set waits.
	go func() { _, _ = b.List(context.Background(), "c", "/r") }()
	if r := <-arrived; r.Tool != corev1.McpTool_MCP_TOOL_LIST_VALUE_SETS {
		t.Fatalf("got %v", r)
	}
	if err := b.Answer(&corev1.AnswerMcpRequestRequest{Id: waiting.Id, Answer: &corev1.AnswerMcpRequestRequest_Refusal{Refusal: "no"}}); err != nil {
		t.Fatal(err)
	}
	<-first
	// The first answered, a new set may wait.
	go func() { _, _ = b.Set(context.Background(), setRequest()) }()
	if r := <-arrived; r.Tool != corev1.McpTool_MCP_TOOL_SET_VALUES {
		t.Fatalf("got %v", r)
	}
}

func TestACallerThatLeavesRemovesItsRequest(t *testing.T) {
	b := NewBroker(time.Minute)
	arrived := make(chan *corev1.McpRequest, 1)
	defer app(t, b, func(r *corev1.McpRequest) *corev1.AnswerMcpRequestRequest { arrived <- r; return nil })()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { _, err := b.Set(ctx, setRequest()); done <- err }()
	r := <-arrived
	cancel()
	if err := <-done; !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v", err)
	}
	if err := b.Answer(&corev1.AnswerMcpRequestRequest{Id: r.Id, Answer: &corev1.AnswerMcpRequestRequest_Refusal{Refusal: "late"}}); !errors.Is(err, ErrUnknownRequest) {
		t.Fatalf("late answer = %v", err)
	}
}

func TestTheAppLeavingFailsWaitingRequests(t *testing.T) {
	b := NewBroker(time.Minute)
	arrived := make(chan *corev1.McpRequest, 1)
	stop := app(t, b, func(r *corev1.McpRequest) *corev1.AnswerMcpRequestRequest { arrived <- r; return nil })
	done := make(chan error, 1)
	go func() { _, err := b.Set(context.Background(), setRequest()); done <- err }()
	<-arrived
	stop()
	if err := <-done; !errors.Is(err, ErrNoApp) {
		t.Fatalf("err = %v", err)
	}
}

func TestAWrongKindOfAnswerIsARefusal(t *testing.T) {
	b := NewBroker(time.Second)
	defer app(t, b, func(*corev1.McpRequest) *corev1.AnswerMcpRequestRequest {
		return &corev1.AnswerMcpRequestRequest{Answer: &corev1.AnswerMcpRequestRequest_Saved{Saved: &corev1.McpSavedValues{}}}
	})()
	if _, err := b.List(context.Background(), "c", "/r"); err == nil {
		t.Fatal("no error")
	}
}

func TestClosingEndsTheSubscription(t *testing.T) {
	b := NewBroker(time.Minute)
	requests, _ := b.Subscribe(context.Background())
	b.Close()
	if _, ok := <-requests; ok {
		t.Fatal("still open")
	}
	later, _ := b.Subscribe(context.Background())
	if _, ok := <-later; ok {
		t.Fatal("a later subscription is open")
	}
	if _, err := b.List(context.Background(), "c", "/r"); !errors.Is(err, ErrNoApp) {
		t.Fatalf("err = %v", err)
	}
}

func TestTheAppListsOpensAndStarts(t *testing.T) {
	b := NewBroker(time.Second)
	var seen []*corev1.McpRequest
	defer app(t, b, func(r *corev1.McpRequest) *corev1.AnswerMcpRequestRequest {
		seen = append(seen, r)
		switch r.Tool {
		case corev1.McpTool_MCP_TOOL_LIST_WORKSPACES:
			return &corev1.AnswerMcpRequestRequest{Answer: &corev1.AnswerMcpRequestRequest_Workspaces{Workspaces: &corev1.McpWorkspaces{
				Workspaces: []*corev1.McpWorkspace{{Name: "r", Path: "/Users/me/r"}}}}}
		case corev1.McpTool_MCP_TOOL_OPEN_WORKSPACE:
			return &corev1.AnswerMcpRequestRequest{Answer: &corev1.AnswerMcpRequestRequest_Workspace{Workspace: &corev1.McpOpenedWorkspace{
				Workspace: &corev1.McpWorkspace{Name: "r"}, RepositoryId: "repo_1", Branch: "main"}}}
		default:
			return &corev1.AnswerMcpRequestRequest{Answer: &corev1.AnswerMcpRequestRequest_Started{Started: &corev1.McpLocalRunStarted{ExecutionId: "exec_1"}}}
		}
	})()
	workspaces, err := b.Workspaces(context.Background(), "codex")
	if err != nil || workspaces.Workspaces[0].Path != "/Users/me/r" {
		t.Fatalf("workspaces = %v, %v", workspaces, err)
	}
	opened, err := b.Open(context.Background(), "codex", "/Users/me/r/sub", true)
	if err != nil || opened.RepositoryId != "repo_1" {
		t.Fatalf("opened = %v, %v", opened, err)
	}
	started, err := b.Start(context.Background(), "codex", "r", &corev1.McpLocalRunStart{AllowMissingValues: true})
	if err != nil || started.ExecutionId != "exec_1" {
		t.Fatalf("started = %v, %v", started, err)
	}
	if !seen[1].Action || seen[1].Repository != "/Users/me/r/sub" || !seen[2].Action || !seen[2].Start.AllowMissingValues || seen[0].Action {
		t.Fatalf("requests = %v", seen)
	}
}

func TestAnEmptyAnswerIsARefusal(t *testing.T) {
	b := NewBroker(time.Second)
	defer app(t, b, func(*corev1.McpRequest) *corev1.AnswerMcpRequestRequest {
		return &corev1.AnswerMcpRequestRequest{Answer: &corev1.AnswerMcpRequestRequest_Workspace{}}
	})()
	var refusal Refusal
	if _, err := b.Open(context.Background(), "c", "/r", false); !errors.As(err, &refusal) {
		t.Fatalf("err = %v", err)
	}
}
