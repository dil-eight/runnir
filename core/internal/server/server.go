// Package server hosts the local gRPC API of the single Runnir Core process.
package server

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"google.golang.org/grpc"

	"runnir/core/internal/approval"
	"runnir/core/internal/buildinfo"
	"runnir/core/internal/dispatch"
	"runnir/core/internal/events"
	"runnir/core/internal/execution"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/localrun"
	"runnir/core/internal/repository"
	"runnir/core/internal/scanner"
	"runnir/core/internal/tools"
	"runnir/core/internal/watch"
	"runnir/core/internal/workspace"
)

// MaxSocketPathBytes is the portable sockaddr_un.sun_path limit on macOS
// (104 bytes including the terminating NUL).
const MaxSocketPathBytes = 103

const shutdownGrace = 5 * time.Second

// executionShutdownGrace lets a local run stop act and remove its
// containers before the Core exits.
const executionShutdownGrace = 20 * time.Second

// Options tunes a server; the zero value uses production defaults.
type Options struct {
	// ClientSecret, when set, is required on every call except HealthCheck.
	ClientSecret []byte
	// GitHubBaseURL overrides https://api.github.com, for tests.
	GitHubBaseURL string
	// EventBuffer is the per-subscriber event queue length.
	EventBuffer int
	// MaxExecutions is the number of concurrent workflow executions. The
	// default is 1: act names containers after the workflow and job, so two
	// local runs at once could replace each other's containers.
	MaxExecutions int
	// Runner executes workflows; nil uses act for approved local runs.
	Runner execution.Runner
	// BundledAct is the act shipped with the app; empty when there is none.
	BundledAct string
	// Home is the user's home directory; empty uses os.UserHomeDir.
	Home string
	// ActCache keeps act's clones of actions; empty uses the user cache
	// directory.
	ActCache string
	// Tools overrides the tool detector, for tests.
	Tools toolChecker
	// DataDir is the app's support folder; each workspace keeps its database
	// in DataDir/repositories/<workspaceId>. Empty keeps everything in memory.
	DataDir string
}

// Run serves gRPC on a Unix domain socket until ctx is cancelled, then stops
// gracefully and removes the socket. It returns ErrAlreadyRunning if another
// Core holds the lock for the same socket path.
func Run(ctx context.Context, socketPath string) error {
	return RunWithOptions(ctx, socketPath, Options{})
}

// RunWithOptions is Run with explicit options.
func RunWithOptions(ctx context.Context, socketPath string, options Options) error {
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
	listener, err := listenOwnerOnly(socketPath)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	defer os.Remove(socketPath)
	// Still restricted explicitly, for platforms without a creation mask.
	if err := os.Chmod(socketPath, 0o600); err != nil {
		_ = listener.Close()
		return fmt.Errorf("restrict socket: %w", err)
	}

	bus := events.New(options.EventBuffer)
	outputs := localrun.NewOutputs()
	workspaces := workspace.New(workspace.Options{DataDir: options.DataDir, Publish: bus.Publish, BilledMinutes: outputs.BilledMinutes})
	// Registered before repositories.Shutdown, so it runs after it: closing
	// the repositories detaches their runtimes first.
	defer workspaces.Shutdown()
	runner := options.Runner
	if runner == nil {
		runner = localrun.NewRunner(outputs)
	}
	limit := options.MaxExecutions
	if limit <= 0 {
		limit = 1
	}
	executions := execution.New(runner, execution.Options{Limit: limit}, func(e events.Event) {
		outputs.Observe(e)
		workspaces.ObserveExecution(e)
		bus.Publish(e)
	})
	home := options.Home
	if home == "" {
		home, _ = os.UserHomeDir()
	}
	actCache := options.ActCache
	if actCache == "" {
		if cache, err := os.UserCacheDir(); err == nil {
			actCache = filepath.Join(cache, "Runnir", "act")
		}
	}
	checker := options.Tools
	if checker == nil {
		checker = tools.NewDetector(home, options.BundledAct, os.Getenv("PATH"))
	}
	repositories := repository.New(scanner.New(), func(e repository.Event) {
		if e.Type == repository.RepositoryClosed {
			executions.CancelRepository(e.RepositoryID)
			workspaces.Detach(e.RepositoryID)
		}
		bus.Publish(fromRepository(e))
	})
	defer repositories.Shutdown()
	grpcServer := grpc.NewServer(
		grpc.UnaryInterceptor(authUnary(options.ClientSecret)),
		grpc.StreamInterceptor(authStream(options.ClientSecret)),
	)
	accounts := github.NewAccounts(options.GitHubBaseURL, buildinfo.Version)
	corev1.RegisterRunnirCoreServer(grpcServer, &service{
		repositories: repositories, events: bus, executions: executions, workspaces: workspaces,
		accounts:     accounts,
		watcher:      watch.New(accounts, workspaces, time.Now),
		dispatches:   dispatch.NewStore(0, nil),
		runActions:   approval.NewStore[runAction]("action_", 0, nil),
		tools:        checker,
		localRuns:    approval.NewStore[localRunApproval]("local_", 0, nil),
		localOutputs: outputs,
		home:         home,
		actCache:     actCache,
	})

	done := make(chan error, 1)
	go func() { done <- grpcServer.Serve(listener) }()

	var serveErr error
	serverEnded := false
	select {
	case serveErr = <-done:
		serverEnded = true
	case <-ctx.Done():
	}
	// Running executions are cancelled first so their final events reach
	// subscribers; then event streams are closed, because they never end on
	// their own and would hold up the graceful stop. This also runs when the
	// server failed on its own.
	stopCtx, stopCancel := context.WithTimeout(context.Background(), executionShutdownGrace)
	executions.Shutdown(stopCtx)
	stopCancel()
	bus.Close()
	if serverEnded {
		return serveErr
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
