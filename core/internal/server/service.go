package server

import (
	"context"
	"errors"
	"runtime"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	"runnir/core/internal/buildinfo"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/repository"
)

// service implements the RunnirCore RPCs. Unimplemented methods return
// codes.Unimplemented until their phase lands.
type service struct {
	corev1.UnimplementedRunnirCoreServer
	repositories *repository.Manager
}

func (s *service) HealthCheck(context.Context, *corev1.HealthCheckRequest) (*corev1.HealthCheckResponse, error) {
	var memory runtime.MemStats
	runtime.ReadMemStats(&memory)
	return &corev1.HealthCheckResponse{
		CoreVersion:         buildinfo.Version,
		ProtocolVersion:     buildinfo.ProtocolVersion,
		OpenRepositoryCount: uint32(s.repositories.Count()),
		// Go runtime's total memory obtained from the OS; a coarse stand-in
		// for resident size until the diagnostics phase.
		ResidentMemoryBytes: memory.Sys,
	}, nil
}

func (s *service) OpenRepository(ctx context.Context, request *corev1.OpenRepositoryRequest) (*corev1.RepositoryResponse, error) {
	info, err := s.repositories.Open(ctx, request.GetPath())
	if err != nil {
		return nil, rpcError(err)
	}
	return &corev1.RepositoryResponse{Repository: toProto(info)}, nil
}

func (s *service) RefreshRepository(ctx context.Context, request *corev1.RefreshRepositoryRequest) (*corev1.RepositoryResponse, error) {
	info, err := s.repositories.Refresh(ctx, request.GetRepositoryId())
	if err != nil {
		return nil, rpcError(err)
	}
	return &corev1.RepositoryResponse{Repository: toProto(info)}, nil
}

func (s *service) CloseRepository(_ context.Context, request *corev1.CloseRepositoryRequest) (*corev1.CloseRepositoryResponse, error) {
	if err := s.repositories.Close(request.GetRepositoryId()); err != nil {
		return nil, rpcError(err)
	}
	return &corev1.CloseRepositoryResponse{}, nil
}

func (s *service) ListWorkflows(_ context.Context, request *corev1.ListWorkflowsRequest) (*corev1.ListWorkflowsResponse, error) {
	workflows, err := s.repositories.Workflows(request.GetRepositoryId())
	if err != nil {
		return nil, rpcError(err)
	}
	out := &corev1.ListWorkflowsResponse{Workflows: make([]*corev1.Workflow, 0, len(workflows))}
	for _, w := range workflows {
		item := &corev1.Workflow{Id: w.ID, Name: w.Name, Triggers: w.Triggers, ParseError: w.ParseError}
		for _, j := range w.Jobs {
			item.Jobs = append(item.Jobs, &corev1.Job{Id: j.ID, Name: j.Name, Needs: j.Needs})
		}
		out.Workflows = append(out.Workflows, item)
	}
	return out, nil
}

func toProto(info repository.Info) *corev1.Repository {
	out := &corev1.Repository{
		Id:            info.ID,
		Path:          info.Path,
		Branch:        info.Branch,
		WorkflowCount: uint32(info.WorkflowCount),
	}
	if !info.LastRefresh.IsZero() {
		out.LastRefresh = timestamppb.New(info.LastRefresh)
	}
	return out
}

// rpcError maps domain errors to gRPC codes. Messages never echo scan
// internals, only the caller's own input.
func rpcError(err error) error {
	switch {
	case errors.Is(err, repository.ErrInvalidPath):
		return status.Error(codes.InvalidArgument, err.Error())
	case errors.Is(err, repository.ErrNotFound):
		return status.Error(codes.NotFound, "repository not found")
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return status.FromContextError(err).Err()
	default:
		return status.Error(codes.Internal, "repository operation failed")
	}
}
