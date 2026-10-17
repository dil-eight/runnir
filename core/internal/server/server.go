// Package server hosts the local gRPC API of the single Runnir Core process.
package server

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"time"

	"google.golang.org/grpc"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/repository"
	"runnir/core/internal/scanner"
)

// MaxSocketPathBytes is the portable sockaddr_un.sun_path limit on macOS
// (104 bytes including the terminating NUL).
const MaxSocketPathBytes = 103

const shutdownGrace = 5 * time.Second

// Run serves gRPC on a Unix domain socket until ctx is cancelled, then stops
// gracefully and removes the socket. It returns ErrAlreadyRunning if another
// Core holds the lock for the same socket path.
func Run(ctx context.Context, socketPath string) error {
	if socketPath == "" {
		return errors.New("socket path is required")
	}
	if len(socketPath) > MaxSocketPathBytes {
		return fmt.Errorf("socket path is %d bytes; the limit is %d", len(socketPath), MaxSocketPathBytes)
	}
	lock, err := acquireLock(socketPath + ".lock")
	if err != nil {
		return err
	}
	defer lock.release()

	// Holding the lock proves no live Core owns this socket, so a leftover
	// file is stale and safe to remove.
	if err := os.Remove(socketPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove stale socket: %w", err)
	}
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	defer os.Remove(socketPath)
	if err := os.Chmod(socketPath, 0o600); err != nil {
		_ = listener.Close()
		return fmt.Errorf("restrict socket: %w", err)
	}

	repositories := repository.New(scanner.New(), nil)
	defer repositories.Shutdown()
	grpcServer := grpc.NewServer()
	corev1.RegisterRunnirCoreServer(grpcServer, &service{repositories: repositories})

	done := make(chan error, 1)
	go func() { done <- grpcServer.Serve(listener) }()

	select {
	case err := <-done:
		return err
	case <-ctx.Done():
	}
	stopped := make(chan struct{})
	go func() { grpcServer.GracefulStop(); close(stopped) }()
	select {
	case <-stopped:
	case <-time.After(shutdownGrace):
		grpcServer.Stop()
	}
	<-done
	return nil
}
