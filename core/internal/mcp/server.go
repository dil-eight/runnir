// Package mcp serves Runnir's MCP tools over stdio (JSON-RPC 2.0, one
// message per line) for MCP clients such as Claude Code and Codex. It is a
// thin adapter: it lists mcptools.Catalog and sends each tool call to the
// app's Core over McpBridge, which runs it
// (docs/superpowers/specs/2026-11-09-mcp-full-control-design.md).
package mcp

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"sync"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	"runnir/core/internal/buildinfo"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/mcpbridge"
	"runnir/core/internal/mcptools"
)

// Bridge is the app's Core as `runnir mcp` reaches it.
type Bridge interface {
	CallTool(context.Context, *corev1.McpBridgeCallToolRequest) (*corev1.McpBridgeCallToolResponse, error)
}

// protocolVersions are the MCP versions this server speaks, newest first.
var protocolVersions = []string{"2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"}

// maxMessage bounds one message: 100 values of 48 KiB fit with room.
const maxMessage = 16 << 20

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type server struct {
	bridge Bridge

	writeMu sync.Mutex
	out     io.Writer

	mu       sync.Mutex
	client   string
	inflight map[string]context.CancelFunc
	wg       sync.WaitGroup
}

// Serve answers MCP messages from in on out until in ends, then waits for
// the calls still running.
func Serve(ctx context.Context, in io.Reader, out io.Writer, bridge Bridge) error {
	s := &server{bridge: bridge, out: out, inflight: map[string]context.CancelFunc{}}
	reader := bufio.NewReaderSize(in, 64*1024)
	defer s.wg.Wait()
	for {
		line, err := readLine(reader)
		if len(bytes.TrimSpace(line)) > 0 {
			s.handle(ctx, line)
		}
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

func readLine(reader *bufio.Reader) ([]byte, error) {
	var line []byte
	for {
		chunk, err := reader.ReadSlice('\n')
		line = append(line, chunk...)
		if len(line) > maxMessage {
			// Skip the rest of an oversized message.
			for errors.Is(err, bufio.ErrBufferFull) {
				_, err = reader.ReadSlice('\n')
			}
			return []byte("{}"), err
		}
		if !errors.Is(err, bufio.ErrBufferFull) {
			return line, err
		}
	}
}

func (s *server) handle(ctx context.Context, line []byte) {
	var r request
	if err := json.Unmarshal(line, &r); err != nil {
		s.fail(json.RawMessage("null"), -32700, "Parse error")
		return
	}
	notification := len(r.ID) == 0 || string(r.ID) == "null"
	if r.JSONRPC != "2.0" || r.Method == "" {
		if !notification {
			s.fail(r.ID, -32600, "Invalid Request")
		}
		return
	}
	if notification {
		s.notify(r)
		return
	}
	switch r.Method {
	case "initialize":
		s.reply(r.ID, s.initialize(r.Params))
	case "ping":
		s.reply(r.ID, struct{}{})
	case "tools/list":
		s.reply(r.ID, map[string]any{"tools": mcptools.Catalog})
	case "tools/call":
		s.call(ctx, r)
	default:
		s.fail(r.ID, -32601, "Method not found")
	}
}

func (s *server) notify(r request) {
	if r.Method != "notifications/cancelled" {
		return
	}
	var params struct {
		RequestID json.RawMessage `json:"requestId"`
	}
	if json.Unmarshal(r.Params, &params) != nil {
		return
	}
	s.mu.Lock()
	cancel := s.inflight[string(params.RequestID)]
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (s *server) initialize(params json.RawMessage) any {
	var p struct {
		ProtocolVersion string `json:"protocolVersion"`
		ClientInfo      struct {
			Name string `json:"name"`
		} `json:"clientInfo"`
	}
	_ = json.Unmarshal(params, &p)
	s.mu.Lock()
	s.client = p.ClientInfo.Name
	s.mu.Unlock()
	version := protocolVersions[0]
	for _, known := range protocolVersions {
		if known == p.ProtocolVersion {
			version = known
		}
	}
	return map[string]any{
		"protocolVersion": version,
		"capabilities":    map[string]any{"tools": map[string]any{"listChanged": false}},
		"serverInfo":      map[string]any{"name": "runnir", "title": "Runnir", "version": buildinfo.Version},
		"instructions":    mcptools.Instructions,
	}
}

func (s *server) call(ctx context.Context, r request) {
	var params struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(r.Params, &params); err != nil {
		s.fail(r.ID, -32602, "Invalid params")
		return
	}
	if !mcptools.Known(params.Name) {
		s.fail(r.ID, -32602, "Unknown tool: "+params.Name)
		return
	}
	callCtx, cancel := context.WithCancel(ctx)
	key := string(r.ID)
	s.mu.Lock()
	s.inflight[key] = cancel
	client := s.client
	s.mu.Unlock()
	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		defer func() {
			s.mu.Lock()
			delete(s.inflight, key)
			s.mu.Unlock()
			cancel()
		}()
		result := s.forward(callCtx, client, params.Name, params.Arguments)
		// A cancelled request gets no answer.
		if callCtx.Err() != nil && ctx.Err() == nil {
			return
		}
		s.reply(r.ID, result)
	}()
}

// forward runs a tool in the app's Core and answers its result.
func (s *server) forward(ctx context.Context, client, name string, arguments json.RawMessage) any {
	if len(arguments) == 0 || string(arguments) == "null" {
		arguments = json.RawMessage("{}")
	}
	out, err := s.bridge.CallTool(ctx, &corev1.McpBridgeCallToolRequest{Client: client, Tool: name, ArgumentsJson: string(arguments)})
	if err != nil {
		return toolError(bridgeMessage(err))
	}
	result := map[string]any{"content": []any{textContent(out.GetText())}}
	if out.GetIsError() {
		result["isError"] = true
	}
	if structured := out.GetStructuredJson(); structured != "" && json.Valid([]byte(structured)) {
		result["structuredContent"] = json.RawMessage(structured)
	}
	return result
}

// bridgeMessage says why a call to the app's Core failed, without detail
// from the transport.
func bridgeMessage(err error) string {
	st, ok := status.FromError(err)
	if !ok {
		return "Runnir could not answer."
	}
	switch st.Code() {
	case codes.Unavailable:
		return mcpbridge.ErrNoApp.Error()
	case codes.DeadlineExceeded:
		return "Runnir did not answer in time."
	case codes.Canceled:
		return "The call was cancelled."
	case codes.Unimplemented:
		return "This Runnir does not serve MCP tools; update Runnir."
	default:
		return "Runnir could not answer."
	}
}

func textContent(text string) map[string]any { return map[string]any{"type": "text", "text": text} }

func toolError(text string) any {
	return map[string]any{"content": []any{textContent(text)}, "isError": true}
}

func (s *server) reply(id json.RawMessage, result any) {
	s.write(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
}

func (s *server) fail(id json.RawMessage, code int, message string) {
	s.write(map[string]any{"jsonrpc": "2.0", "id": id, "error": rpcError{Code: code, Message: message}})
}

func (s *server) write(message any) {
	data, err := json.Marshal(message)
	if err != nil {
		data = []byte(`{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}`)
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_, _ = s.out.Write(append(data, '\n'))
}

// DialBridge reaches the app's Core on its MCP socket, anew for each call,
// so a Runnir opened after the client started is found.
func DialBridge(socketPath string) Bridge { return dialed{path: socketPath} }

type dialed struct{ path string }

func (d dialed) connect() (*grpc.ClientConn, corev1.McpBridgeClient, error) {
	conn, err := grpc.NewClient("unix://"+d.path, grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithDefaultCallOptions(grpc.MaxCallSendMsgSize(maxMessage), grpc.MaxCallRecvMsgSize(maxMessage)))
	if err != nil {
		return nil, nil, status.Error(codes.Unavailable, fmt.Sprint(err))
	}
	return conn, corev1.NewMcpBridgeClient(conn), nil
}

func (d dialed) CallTool(ctx context.Context, r *corev1.McpBridgeCallToolRequest) (*corev1.McpBridgeCallToolResponse, error) {
	conn, client, err := d.connect()
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	return client.CallTool(ctx, r)
}
