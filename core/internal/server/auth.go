package server

import (
	"context"
	"crypto/subtle"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// The app that launched the Core proves itself with a per-launch secret it
// passed on stdin, sent as "authorization: Bearer <secret>" on every call.
// Only HealthCheck is open, so a supervisor can see whether a Core answers
// before connecting for real; it returns no repository data or credentials.

const authorizationHeader = "authorization"

func authorize(ctx context.Context, secret []byte, method string) error {
	if len(secret) == 0 || method == corev1.RunnirCore_HealthCheck_FullMethodName {
		return nil
	}
	values := metadata.ValueFromIncomingContext(ctx, authorizationHeader)
	if len(values) != 1 {
		return status.Error(codes.Unauthenticated, "this client is not allowed to use the Core")
	}
	presented, ok := strings.CutPrefix(values[0], "Bearer ")
	if !ok || subtle.ConstantTimeCompare([]byte(presented), secret) != 1 {
		return status.Error(codes.Unauthenticated, "this client is not allowed to use the Core")
	}
	return nil
}

func authUnary(secret []byte) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		if err := authorize(ctx, secret, info.FullMethod); err != nil {
			return nil, err
		}
		return handler(ctx, req)
	}
}

func authStream(secret []byte) grpc.StreamServerInterceptor {
	return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		if err := authorize(ss.Context(), secret, info.FullMethod); err != nil {
			return err
		}
		return handler(srv, ss)
	}
}
