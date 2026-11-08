package mcpbridge

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

type safeBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *safeBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *safeBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

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

func setRequest() *corev1.McpBridgeSetValuesRequest {
	return &corev1.McpBridgeSetValuesRequest{Client: "claude-code", Repository: "/Users/me/r", Set: "production",
		Secrets: values("API_KEY", "s3cr3t-VALUE"), Variables: values("REGION", "eu-west-1")}
}

func TestAListIsAnsweredByTheApp(t *testing.T) {
	log := &safeBuffer{}
	b := NewBroker(time.Second, log)
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
	if !strings.Contains(log.String(), "list_value_sets") {
		t.Fatalf("log = %q", log.String())
	}
}

func TestASetIsAnsweredAndLoggedWithoutValues(t *testing.T) {
	log := &safeBuffer{}
	b := NewBroker(time.Second, log)
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
	if seen.Tool != corev1.McpTool_MCP_TOOL_SET_VALUES || seen.Set != "production" || seen.Secrets[0].Value != "s3cr3t-VALUE" {
		t.Fatalf("request = %v", seen)
	}
	got := log.String()
	if strings.Contains(got, "s3cr3t") || strings.Contains(got, "eu-west-1") || !strings.Contains(got, "API_KEY") || !strings.Contains(got, "saved") {
		t.Fatalf("log = %q", got)
	}
}

func TestARefusalReachesTheCaller(t *testing.T) {
	b := NewBroker(time.Second, nil)
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
	b := NewBroker(time.Second, nil)
	asked := false
	defer app(t, b, func(*corev1.McpRequest) *corev1.AnswerMcpRequestRequest { asked = true; return nil })()
	request := setRequest()
	request.Secrets = values("GITHUB_TOKEN", "x")
	if _, err := b.Set(context.Background(), request); err == nil {
		t.Fatal("no refusal")
	}
	if asked {
		t.Fatal("the app was asked")
	}
}

func TestWithoutTheAppNothingWaits(t *testing.T) {
	b := NewBroker(time.Minute, nil)
	if _, err := b.List(context.Background(), "c", "/r"); !errors.Is(err, ErrNoApp) {
		t.Fatalf("err = %v", err)
	}
}

func TestAnUnansweredRequestTimesOut(t *testing.T) {
	b := NewBroker(50*time.Millisecond, nil)
	defer app(t, b, func(*corev1.McpRequest) *corev1.AnswerMcpRequestRequest { return nil })()
	if _, err := b.Set(context.Background(), setRequest()); !errors.Is(err, ErrTimeout) {
		t.Fatalf("err = %v", err)
	}
}

func TestOneSetWaitsAtATime(t *testing.T) {
	b := NewBroker(time.Second, nil)
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
	b := NewBroker(time.Minute, nil)
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
	b := NewBroker(time.Minute, nil)
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
	b := NewBroker(time.Second, nil)
	defer app(t, b, func(*corev1.McpRequest) *corev1.AnswerMcpRequestRequest {
		return &corev1.AnswerMcpRequestRequest{Answer: &corev1.AnswerMcpRequestRequest_Saved{Saved: &corev1.McpSavedValues{}}}
	})()
	if _, err := b.List(context.Background(), "c", "/r"); err == nil {
		t.Fatal("no error")
	}
}
