package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/localrun"
	"runnir/core/internal/mcpbridge"
	"runnir/core/internal/mcptools"
	"runnir/core/internal/scanner"
)

// McpSocketName is the socket `runnir mcp` reaches the app's Core on, in
// the data folder.
const McpSocketName = "mcp.sock"

// startMcp serves McpBridge, and nothing else, on DataDir/mcp.sock: mode
// 0600 and, where the platform tells, only for peers of this user. It is
// left out, with a line in log, when the path is too long for a socket or
// another Core of the same data folder holds it. stop ends it.
func startMcp(dataDir string, tools *mcptools.Tools, log io.Writer) (stop func()) {
	nothing := func() {}
	if dataDir == "" {
		return nothing
	}
	path := filepath.Join(dataDir, McpSocketName)
	if len(path) > MaxSocketPathBytes {
		fmt.Fprintf(log, "mcp: the socket path is %d bytes, over %d; MCP clients cannot reach Runnir\n", len(path), MaxSocketPathBytes)
		return nothing
	}
	lock, err := acquireLock(path + ".lock")
	if err != nil {
		fmt.Fprintln(log, "mcp: another Runnir Core of this data folder serves MCP clients")
		return nothing
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		lock.release()
		fmt.Fprintln(log, "mcp: a stale socket could not be removed")
		return nothing
	}
	listener, err := listenOwnerOnly(path)
	if err != nil {
		lock.release()
		fmt.Fprintln(log, "mcp: the socket could not be opened")
		return nothing
	}
	if err := os.Chmod(path, 0o600); err != nil {
		_ = listener.Close()
		lock.release()
		fmt.Fprintln(log, "mcp: the socket could not be restricted")
		return nothing
	}
	// A call carries up to 100 values of 48 KiB; an answer a bounded log.
	server := grpc.NewServer(grpc.MaxRecvMsgSize(16 << 20))
	corev1.RegisterMcpBridgeServer(server, &mcpBridge{tools: tools})
	done := make(chan struct{})
	go func() { defer close(done); _ = server.Serve(samePeerUser{listener}) }()
	return func() {
		server.Stop()
		<-done
		_ = os.Remove(path)
		lock.release()
	}
}

// samePeerUser closes connections from other users' processes.
type samePeerUser struct{ net.Listener }

func (l samePeerUser) Accept() (net.Conn, error) {
	for {
		conn, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		if peerIsThisUser(conn) {
			return conn, nil
		}
		_ = conn.Close()
	}
}

type mcpBridge struct {
	corev1.UnimplementedMcpBridgeServer
	tools *mcptools.Tools
}

// CallTool runs one tool of an MCP client; its refusals are results.
func (m *mcpBridge) CallTool(ctx context.Context, request *corev1.McpBridgeCallToolRequest) (*corev1.McpBridgeCallToolResponse, error) {
	result := m.tools.Call(ctx, request.GetClient(), request.GetTool(), json.RawMessage(request.GetArgumentsJson()))
	out := &corev1.McpBridgeCallToolResponse{Text: result.Text, IsError: result.IsError}
	if result.Structured != nil {
		data, err := json.Marshal(result.Structured)
		if err != nil {
			return nil, status.Error(codes.Internal, "the result could not be encoded")
		}
		out.StructuredJson = string(data)
	}
	return out, nil
}

// mcpCore is the service as the tools use it, with the reads that have no
// RPC.
type mcpCore struct{ *service }

func (c mcpCore) WorkflowSource(repositoryID, path string) ([]byte, error) {
	info, err := c.repositories.Get(repositoryID)
	if err != nil {
		return nil, err
	}
	return scanner.ReadWorkflowFile(info.Path, path)
}

// LocalRuns merges the workspace's history with the runs the Core holds:
// the history knows every run, the Core who started the recent ones.
func (c mcpCore) LocalRuns(ctx context.Context, repositoryID string, limit int) ([]mcptools.LocalRunSummary, error) {
	held := map[string]localrun.Snapshot{}
	for _, snap := range c.localOutputs.Recent(repositoryID) {
		held[snap.ExecutionID] = snap
	}
	var out []mcptools.LocalRunSummary
	if rt, ok := c.workspaces.ForRepository(repositoryID); ok {
		history, err := rt.Store().LocalRuns(ctx, limit)
		if err != nil {
			return nil, status.Error(codes.Internal, "the workspace's local runs could not be read")
		}
		for _, h := range history {
			summary := mcptools.LocalRunSummary{ExecutionID: h.ExecutionID, Scenario: h.Scenario, Workflows: h.Workflows,
				State: h.State, Message: h.Message, StartedAt: h.StartedAt, FinishedAt: h.FinishedAt}
			if snap, ok := held[h.ExecutionID]; ok {
				summary.StartedBy = snap.StartedBy
				delete(held, h.ExecutionID)
			}
			out = append(out, summary)
		}
	}
	for _, snap := range held {
		var workflows []string
		for _, lane := range snap.Plan.Selected() {
			workflows = append(workflows, lane.WorkflowID)
		}
		out = append(out, mcptools.LocalRunSummary{ExecutionID: snap.ExecutionID, Scenario: snap.Plan.Scenario.Title(), Workflows: workflows,
			State: strings.ToLower(strings.TrimPrefix(snap.State.String(), "EXECUTION_STATE_")), Message: snap.Message,
			StartedAt: snap.StartedAt, FinishedAt: snap.FinishedAt, StartedBy: snap.StartedBy})
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].StartedAt.After(out[j].StartedAt) })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// SubscribeMcpRequests streams the calls of MCP clients to the app until
// it goes away, another subscriber replaces it or the Core stops.
func (s *service) SubscribeMcpRequests(_ *corev1.SubscribeMcpRequestsRequest, stream corev1.RunnirCore_SubscribeMcpRequestsServer) error {
	if s.mcp == nil {
		return status.Error(codes.Unavailable, "MCP is not served")
	}
	requests, stop := s.mcp.Subscribe(stream.Context())
	defer stop()
	for {
		select {
		case <-stream.Context().Done():
			return status.FromContextError(stream.Context().Err()).Err()
		case request, ok := <-requests:
			if !ok {
				return status.Error(codes.Unavailable, "another subscriber took MCP requests, or the Core is shutting down")
			}
			if err := stream.Send(request); err != nil {
				return err
			}
		}
	}
}

func (s *service) ClaimMcpRequest(_ context.Context, request *corev1.ClaimMcpRequestRequest) (*corev1.ClaimMcpRequestResponse, error) {
	if s.mcp == nil {
		return nil, status.Error(codes.Unavailable, "MCP is not served")
	}
	if err := s.mcp.Claim(request.GetId()); errors.Is(err, mcpbridge.ErrUnknownRequest) {
		return nil, status.Error(codes.NotFound, "the request is no longer waiting")
	} else if err != nil {
		return nil, status.Error(codes.Internal, "the request could not be claimed")
	}
	return &corev1.ClaimMcpRequestResponse{}, nil
}

func (s *service) AnswerMcpRequest(_ context.Context, request *corev1.AnswerMcpRequestRequest) (*corev1.AnswerMcpRequestResponse, error) {
	if s.mcp == nil {
		return nil, status.Error(codes.Unavailable, "MCP is not served")
	}
	if err := s.mcp.Answer(request); errors.Is(err, mcpbridge.ErrUnknownRequest) {
		return nil, status.Error(codes.NotFound, "the request is no longer waiting")
	} else if err != nil {
		return nil, status.Error(codes.Internal, "the answer could not be delivered")
	}
	return &corev1.AnswerMcpRequestResponse{}, nil
}
