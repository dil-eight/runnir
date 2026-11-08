package mcp

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

type fakeBridge struct {
	mu      sync.Mutex
	lists   []*corev1.McpBridgeListValueSetsRequest
	sets    []*corev1.McpBridgeSetValuesRequest
	listErr error
	setErr  error
	block   chan struct{}
	// cancelled closes when a blocked SetValues sees its context end.
	cancelled chan struct{}
}

func (f *fakeBridge) ListValueSets(_ context.Context, r *corev1.McpBridgeListValueSetsRequest) (*corev1.McpValueSets, error) {
	f.mu.Lock()
	f.lists = append(f.lists, r)
	f.mu.Unlock()
	if f.listErr != nil {
		return nil, f.listErr
	}
	return &corev1.McpValueSets{Workspace: "fintropy", Sets: []*corev1.McpValueSet{
		{Name: "Repository", Names: []*corev1.McpValueName{
			{Name: "GHCR_TOKEN", Secret: true, State: corev1.McpValueState_MCP_VALUE_STATE_SAVED},
			{Name: "DO_APP_ID", State: corev1.McpValueState_MCP_VALUE_STATE_SAVED, Value: "app-1"},
		}},
		{Name: "production", Names: []*corev1.McpValueName{
			{Name: "DEPLOY_SSH_KEY", Secret: true, State: corev1.McpValueState_MCP_VALUE_STATE_MISSING},
			{Name: "GHCR_TOKEN", Secret: true, State: corev1.McpValueState_MCP_VALUE_STATE_FROM_REPOSITORY},
		}},
		{Name: "old", Stale: true},
	}}, nil
}

func (f *fakeBridge) SetValues(ctx context.Context, r *corev1.McpBridgeSetValuesRequest) (*corev1.McpSavedValues, error) {
	f.mu.Lock()
	f.sets = append(f.sets, r)
	block := f.block
	f.mu.Unlock()
	if block != nil {
		select {
		case <-block:
		case <-ctx.Done():
			close(f.cancelled)
			return nil, ctx.Err()
		}
	}
	if f.setErr != nil {
		return nil, f.setErr
	}
	out := &corev1.McpSavedValues{Workspace: "fintropy", Set: r.Set}
	for _, v := range r.Secrets {
		out.Secrets = append(out.Secrets, v.Name)
	}
	for _, v := range r.Variables {
		out.Variables = append(out.Variables, v.Name)
	}
	return out, nil
}

type response struct {
	ID     json.RawMessage `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    int    `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

// exchange sends the lines to a server and returns its answers by id.
func exchange(t *testing.T, bridge Bridge, lines ...string) (map[string]response, string) {
	t.Helper()
	var out bytes.Buffer
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := Serve(ctx, strings.NewReader(strings.Join(lines, "\n")+"\n"), &out, bridge); err != nil {
		t.Fatal(err)
	}
	answers := map[string]response{}
	for _, line := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		if line == "" {
			continue
		}
		var r response
		if err := json.Unmarshal([]byte(line), &r); err != nil {
			t.Fatalf("not JSON: %q", line)
		}
		answers[string(r.ID)] = r
	}
	return answers, out.String()
}

const initialize = `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"codex-mcp-client","version":"0.50.0"}}}`

func TestInitializeAnswersTheClientsVersionOrTheNewest(t *testing.T) {
	answers, _ := exchange(t, &fakeBridge{}, initialize,
		`{"jsonrpc":"2.0","method":"notifications/initialized"}`,
		`{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01","capabilities":{},"clientInfo":{"name":"x"}}}`,
		`{"jsonrpc":"2.0","id":3,"method":"ping"}`)
	var first struct {
		ProtocolVersion string `json:"protocolVersion"`
		Capabilities    struct {
			Tools *struct{} `json:"tools"`
		} `json:"capabilities"`
		ServerInfo struct {
			Name    string `json:"name"`
			Version string `json:"version"`
		} `json:"serverInfo"`
		Instructions string `json:"instructions"`
	}
	if err := json.Unmarshal(answers["1"].Result, &first); err != nil {
		t.Fatal(err)
	}
	if first.ProtocolVersion != "2025-06-18" || first.Capabilities.Tools == nil || first.ServerInfo.Name != "runnir" || first.Instructions == "" {
		t.Fatalf("initialize = %s", answers["1"].Result)
	}
	if !strings.Contains(string(answers["2"].Result), `"protocolVersion":"2025-11-25"`) {
		t.Fatalf("unknown version = %s", answers["2"].Result)
	}
	if string(answers["3"].Result) != "{}" {
		t.Fatalf("ping = %s", answers["3"].Result)
	}
	if len(answers) != 3 {
		t.Fatalf("a notification was answered: %v", answers)
	}
}

func TestToolsListMatchesTheCatalog(t *testing.T) {
	answers, _ := exchange(t, &fakeBridge{}, initialize, `{"jsonrpc":"2.0","id":2,"method":"tools/list"}`)
	var listed struct {
		Tools []struct {
			Name        string          `json:"name"`
			Description string          `json:"description"`
			InputSchema json.RawMessage `json:"inputSchema"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(answers["2"].Result, &listed); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(filepath.Join("..", "..", "..", "mcp", "runnir-tools.json"))
	if err != nil {
		t.Fatal(err)
	}
	var catalog struct {
		Tools []struct {
			Name        string          `json:"name"`
			Description string          `json:"description"`
			InputSchema json.RawMessage `json:"inputSchema"`
		} `json:"tools"`
	}
	if err := json.Unmarshal(raw, &catalog); err != nil {
		t.Fatal(err)
	}
	if len(listed.Tools) != 2 {
		t.Fatalf("tools = %v", listed.Tools)
	}
	for _, tool := range listed.Tools {
		found := false
		for _, entry := range catalog.Tools {
			if entry.Name != tool.Name {
				continue
			}
			found = true
			if entry.Description != tool.Description || !sameJSON(t, entry.InputSchema, tool.InputSchema) {
				t.Errorf("%s differs from mcp/runnir-tools.json", tool.Name)
			}
		}
		if !found {
			t.Errorf("%s is not in the catalog", tool.Name)
		}
	}
}

func sameJSON(t *testing.T, a, b json.RawMessage) bool {
	t.Helper()
	var x, y any
	if json.Unmarshal(a, &x) != nil || json.Unmarshal(b, &y) != nil {
		return false
	}
	ja, _ := json.Marshal(x)
	jb, _ := json.Marshal(y)
	return string(ja) == string(jb)
}

type toolResult struct {
	Content []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	} `json:"content"`
	StructuredContent json.RawMessage `json:"structuredContent"`
	IsError           bool            `json:"isError"`
}

func result(t *testing.T, r response) toolResult {
	t.Helper()
	if r.Error != nil {
		t.Fatalf("error %d %s", r.Error.Code, r.Error.Message)
	}
	var out toolResult
	if err := json.Unmarshal(r.Result, &out); err != nil || len(out.Content) == 0 {
		t.Fatalf("result = %s", r.Result)
	}
	return out
}

func TestListValueSets(t *testing.T) {
	bridge := &fakeBridge{}
	answers, _ := exchange(t, bridge, initialize,
		`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"runnir_list_value_sets","arguments":{"repository":"/Users/me/projects/fintropy"}}}`)
	out := result(t, answers["2"])
	if out.IsError {
		t.Fatalf("error: %s", out.Content[0].Text)
	}
	var sets struct {
		Workspace string `json:"workspace"`
		Sets      []struct {
			Name    string `json:"name"`
			Stale   bool   `json:"stale"`
			Secrets []struct {
				Name  string `json:"name"`
				State string `json:"state"`
			} `json:"secrets"`
			Variables []struct {
				Name  string `json:"name"`
				State string `json:"state"`
				Value string `json:"value"`
			} `json:"variables"`
		} `json:"sets"`
	}
	if err := json.Unmarshal(out.StructuredContent, &sets); err != nil {
		t.Fatal(err)
	}
	if sets.Workspace != "fintropy" || len(sets.Sets) != 3 || sets.Sets[0].Secrets[0].State != "saved" ||
		sets.Sets[0].Variables[0].Value != "app-1" || sets.Sets[1].Secrets[0].State != "missing" ||
		sets.Sets[1].Secrets[1].State != "from_repository" || !sets.Sets[2].Stale {
		t.Fatalf("sets = %s", out.StructuredContent)
	}
	if !json.Valid([]byte(out.Content[0].Text)) {
		t.Fatalf("text = %q", out.Content[0].Text)
	}
	if bridge.lists[0].Client != "codex-mcp-client" || bridge.lists[0].Repository != "/Users/me/projects/fintropy" {
		t.Fatalf("bridge got %v", bridge.lists[0])
	}
}

func TestSetValues(t *testing.T) {
	bridge := &fakeBridge{}
	answers, raw := exchange(t, bridge, initialize,
		`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"runnir_set_values","arguments":{"repository":"fintropy","set":"production","secrets":{"DEPLOY_SSH_KEY":"s3cr3t-VALUE"},"variables":{"DO_APP_ID":"app-2"}}}}`)
	out := result(t, answers["2"])
	if out.IsError || !strings.Contains(out.Content[0].Text, "DEPLOY_SSH_KEY") || !strings.Contains(out.Content[0].Text, "production") {
		t.Fatalf("result = %+v", out)
	}
	if strings.Contains(raw, "s3cr3t") {
		t.Fatal("a secret value was written out")
	}
	got := bridge.sets[0]
	if got.Client != "codex-mcp-client" || got.Set != "production" || got.Secrets[0].Name != "DEPLOY_SSH_KEY" ||
		got.Secrets[0].Value != "s3cr3t-VALUE" || got.Variables[0].Value != "app-2" {
		t.Fatalf("bridge got %v", got)
	}
}

func TestInvalidArgumentsAreToolErrors(t *testing.T) {
	bridge := &fakeBridge{}
	answers, raw := exchange(t, bridge, initialize,
		`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"runnir_list_value_sets","arguments":{}}}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"runnir_list_value_sets","arguments":{"repository":"/r","extra":1}}}`,
		`{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"runnir_set_values","arguments":{"repository":"/r","set":"Repository","secrets":{"GITHUB_TOKEN":"s3cr3t-VALUE"}}}}`,
		`{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"runnir_set_values","arguments":{"repository":"/r","set":"Repository","secrets":{"A":5}}}}`,
		`{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"runnir_set_values","arguments":{"repository":"/r","set":"Repository"}}}`)
	for _, id := range []string{"2", "3", "4", "5", "6"} {
		if out := result(t, answers[id]); !out.IsError {
			t.Errorf("%s: not an error: %+v", id, out)
		}
	}
	if len(bridge.lists)+len(bridge.sets) != 0 {
		t.Fatal("the bridge was called")
	}
	if strings.Contains(raw, "s3cr3t") {
		t.Fatal("a secret value was written out")
	}
}

func TestBridgeErrorsAreToolErrors(t *testing.T) {
	bridge := &fakeBridge{listErr: status.Error(codes.Unavailable, "connection refused"),
		setErr: status.Error(codes.FailedPrecondition, "Cancelled in Runnir.")}
	answers, _ := exchange(t, bridge, initialize,
		`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"runnir_list_value_sets","arguments":{"repository":"/r"}}}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"runnir_set_values","arguments":{"repository":"/r","set":"Repository","variables":{"A":"b"}}}}`)
	if out := result(t, answers["2"]); !out.IsError || !strings.Contains(out.Content[0].Text, "Runnir is not running") {
		t.Fatalf("list = %+v", out)
	}
	if out := result(t, answers["3"]); !out.IsError || out.Content[0].Text != "Cancelled in Runnir." {
		t.Fatalf("set = %+v", out)
	}
}

func TestProtocolErrors(t *testing.T) {
	answers, _ := exchange(t, &fakeBridge{}, initialize,
		`{not json`,
		`{"jsonrpc":"2.0","id":2,"method":"resources/list"}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"runnir_nope","arguments":{}}}`,
		`{"jsonrpc":"2.0","method":"notifications/whatever"}`)
	if answers["null"].Error == nil || answers["null"].Error.Code != -32700 {
		t.Fatalf("parse error = %+v", answers["null"])
	}
	if answers["2"].Error == nil || answers["2"].Error.Code != -32601 {
		t.Fatalf("unknown method = %+v", answers["2"])
	}
	if answers["3"].Error == nil || answers["3"].Error.Code != -32602 {
		t.Fatalf("unknown tool = %+v", answers["3"])
	}
}

func TestAWaitingSetDoesNotHoldOtherCallsAndCanBeCancelled(t *testing.T) {
	bridge := &fakeBridge{block: make(chan struct{}), cancelled: make(chan struct{})}
	inputReader, inputWriter := io.Pipe()
	out := &lockedBuffer{}
	done := make(chan error, 1)
	go func() { done <- Serve(context.Background(), inputReader, out, bridge) }()
	send := func(line string) { _, _ = inputWriter.Write([]byte(line + "\n")) }
	send(initialize)
	send(`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"runnir_set_values","arguments":{"repository":"/r","set":"Repository","variables":{"A":"b"}}}}`)
	send(`{"jsonrpc":"2.0","id":3,"method":"ping"}`)
	waitFor(t, out, `"id":3`)
	send(`{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":2,"reason":"user"}}`)
	select {
	case <-bridge.cancelled:
	case <-time.After(5 * time.Second):
		t.Fatal("the bridge call was not cancelled")
	}
	send(`{"jsonrpc":"2.0","id":4,"method":"ping"}`)
	waitFor(t, out, `"id":4`)
	_ = inputWriter.Close()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String(), `"id":2`) {
		t.Fatal("a cancelled request was answered")
	}
}

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func waitFor(t *testing.T, out *lockedBuffer, text string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if strings.Contains(out.String(), text) {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("no %s in %q", text, out.String())
}
