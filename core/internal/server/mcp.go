package server

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/mcpbridge"
)

// McpSocketName is the socket `runnir mcp` reaches the app's Core on, in
// the data folder.
const McpSocketName = "mcp.sock"

// startMcp serves McpBridge, and nothing else, on DataDir/mcp.sock: mode
// 0600 and, where the platform tells, only for peers of this user. It is
// left out, with a line in log, when the path is too long for a socket or
// another Core of the same data folder holds it. stop ends it.
func startMcp(dataDir string, broker *mcpbridge.Broker, log io.Writer) (stop func()) {
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
	server := grpc.NewServer()
	corev1.RegisterMcpBridgeServer(server, &mcpBridge{broker: broker})
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
	broker *mcpbridge.Broker
}

func (m *mcpBridge) ListValueSets(ctx context.Context, request *corev1.McpBridgeListValueSetsRequest) (*corev1.McpValueSets, error) {
	sets, err := m.broker.List(ctx, request.GetClient(), request.GetRepository())
	if err != nil {
		return nil, mcpError(err)
	}
	return sets, nil
}

func (m *mcpBridge) SetValues(ctx context.Context, request *corev1.McpBridgeSetValuesRequest) (*corev1.McpSavedValues, error) {
	saved, err := m.broker.Set(ctx, request)
	if err != nil {
		return nil, mcpError(err)
	}
	return saved, nil
}

func mcpError(err error) error {
	var refusal mcpbridge.Refusal
	switch {
	case errors.As(err, &refusal):
		return status.Error(codes.FailedPrecondition, refusal.Error())
	case errors.Is(err, mcpbridge.ErrNoApp):
		return status.Error(codes.Unavailable, err.Error())
	case errors.Is(err, mcpbridge.ErrBusy):
		return status.Error(codes.FailedPrecondition, err.Error())
	case errors.Is(err, mcpbridge.ErrTimeout):
		return status.Error(codes.DeadlineExceeded, err.Error())
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return status.FromContextError(err).Err()
	default:
		return status.Error(codes.Internal, "Runnir could not answer")
	}
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
