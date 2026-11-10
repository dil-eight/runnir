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
	"runnir/core/internal/mcptools"
)

type fakeBridge struct {
	mu    sync.Mutex
	calls []*corev1.McpBridgeCallToolRequest
	err   error
	// answer is the result of every call; nil echoes the arguments.
	answer *corev1.McpBridgeCallToolResponse
	block  chan struct{}
	// cancelled closes when a blocked call sees its context end.
	cancelled chan struct{}
}

func (f *fakeBridge) CallTool(ctx context.Context, r *corev1.McpBridgeCallToolRequest) (*corev1.McpBridgeCallToolResponse, error) {
	f.mu.Lock()
	f.calls = append(f.calls, r)
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
	if f.err != nil {
		return nil, f.err
	}
	if f.answer != nil {
		return f.answer, nil
	}
	return &corev1.McpBridgeCallToolResponse{Text: r.ArgumentsJson, StructuredJson: `{"tool":"` + r.Tool + `"}`}, nil
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
	if len(listed.Tools) != len(mcptools.Catalog) {
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

func TestToolCallsGoToTheCoreAsTheyAre(t *testing.T) {
	bridge := &fakeBridge{}
	answers, _ := exchange(t, bridge, initialize,
		`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"runnir_list_runs","arguments":{"repository":"/Users/me/shop","status":"failed"}}}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"runnir_list_workspaces"}}`)
	out := result(t, answers["2"])
	if out.IsError || out.Content[0].Text != `{"repository":"/Users/me/shop","status":"failed"}` || string(out.StructuredContent) != `{"tool":"runnir_list_runs"}` {
		t.Fatalf("result = %+v", out)
	}
	for _, got := range bridge.calls {
		if got.Client != "codex-mcp-client" || (got.Tool != "runnir_list_runs" && got.Tool != "runnir_list_workspaces") {
			t.Fatalf("bridge got %v", got)
		}
	}
	if out := result(t, answers["3"]); out.Content[0].Text != "{}" {
		t.Fatalf("no arguments = %+v", out)
	}
}

func TestTheCoresRefusalsAndAnAbsentRunnirAreToolErrors(t *testing.T) {
	bridge := &fakeBridge{answer: &corev1.McpBridgeCallToolResponse{Text: "Cancelled in Runnir.", IsError: true}}
	answers, _ := exchange(t, bridge, initialize,
		`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"runnir_set_values","arguments":{"repository":"/r","set":"Repository","variables":{"A":"b"}}}}`)
	if out := result(t, answers["2"]); !out.IsError || out.Content[0].Text != "Cancelled in Runnir." || out.StructuredContent != nil {
		t.Fatalf("refusal = %+v", out)
	}
	answers, _ = exchange(t, &fakeBridge{err: status.Error(codes.Unavailable, "connection refused")}, initialize,
		`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"runnir_list_workspaces","arguments":{}}}`)
	if out := result(t, answers["2"]); !out.IsError || !strings.Contains(out.Content[0].Text, "Runnir is not running") {
		t.Fatalf("absent = %+v", out)
	}
	answers, _ = exchange(t, &fakeBridge{err: status.Error(codes.Unimplemented, "unknown service")}, initialize,
		`{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"runnir_list_workspaces","arguments":{}}}`)
	if out := result(t, answers["2"]); !out.IsError || !strings.Contains(out.Content[0].Text, "update Runnir") {
		t.Fatalf("old = %+v", out)
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

func TestAWaitingCallDoesNotHoldOtherCallsAndCanBeCancelled(t *testing.T) {
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
