package server

import (
	"context"
	"errors"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/scanner"
)

// SaveWorkflowFile writes an edited workflow file when it is still the
// version the editor loaded, then scans the repository again so workflow
// lists and validation see the new file.
func (s *service) SaveWorkflowFile(ctx context.Context, request *corev1.SaveWorkflowFileRequest) (*corev1.SaveWorkflowFileResponse, error) {
	info, err := s.repositories.Get(request.GetRepositoryId())
	if err != nil {
		return nil, rpcError(err)
	}
	workflow, err := s.workflow(info.ID, request.GetWorkflowId())
	if err != nil {
		return nil, err
	}
	result, err := scanner.SaveWorkflowFile(info.Path, workflow.ID, []byte(request.GetContent()),
		request.GetBaseSha256(), request.GetOverwrite())
	switch {
	case errors.Is(err, scanner.ErrReadOnly):
		return nil, status.Error(codes.FailedPrecondition, "the workflow file is read-only")
	case errors.Is(err, scanner.ErrTooLargeToSave):
		return nil, status.Error(codes.InvalidArgument, "the workflow file would be larger than 1 MiB")
	case errors.Is(err, scanner.ErrNotText):
		return nil, status.Error(codes.InvalidArgument, "the workflow file must be UTF-8 text")
	case errors.Is(err, scanner.ErrNoWorkflowFile):
		return nil, status.Error(codes.FailedPrecondition, "the workflow file cannot be written; refresh the repository")
	case err != nil:
		return nil, status.Error(codes.Internal, "the workflow file could not be saved")
	}
	if !result.Conflict {
		// A failed rescan keeps the last snapshot; the save itself stands.
		_, _ = s.repositories.Refresh(ctx, info.ID)
	}
	return &corev1.SaveWorkflowFileResponse{Sha256: result.SHA256, Conflict: result.Conflict}, nil
}
