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
	// One save at a time, so two windows saving the same file cannot both
	// pass the check for the version they started from.
	s.saveMu.Lock()
	result, err := scanner.SaveWorkflowFile(info.Path, workflow.ID, []byte(request.GetContent()),
		request.GetBaseSha256(), request.GetOverwrite())
	s.saveMu.Unlock()
	switch {
	case errors.Is(err, scanner.ErrReadOnly):
		return nil, status.Error(codes.FailedPrecondition, "the workflow file or its folder is read-only")
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

// CreateWorkflowFile adds a workflow file, then scans the repository again
// so the new file is listed.
func (s *service) CreateWorkflowFile(ctx context.Context, request *corev1.CreateWorkflowFileRequest) (*corev1.CreateWorkflowFileResponse, error) {
	info, err := s.repositories.Get(request.GetRepositoryId())
	if err != nil {
		return nil, rpcError(err)
	}
	s.saveMu.Lock()
	id, err := scanner.CreateWorkflowFile(info.Path, request.GetFileName(), []byte(request.GetContent()))
	s.saveMu.Unlock()
	if err != nil {
		return nil, fileError(err, "the workflow file could not be created")
	}
	_, _ = s.repositories.Refresh(ctx, info.ID)
	return &corev1.CreateWorkflowFileResponse{WorkflowId: id}, nil
}

// RenameWorkflowFile renames a workflow file, then scans the repository
// again so it is listed under its new name.
func (s *service) RenameWorkflowFile(ctx context.Context, request *corev1.RenameWorkflowFileRequest) (*corev1.RenameWorkflowFileResponse, error) {
	info, err := s.repositories.Get(request.GetRepositoryId())
	if err != nil {
		return nil, rpcError(err)
	}
	workflow, err := s.workflow(info.ID, request.GetWorkflowId())
	if err != nil {
		return nil, err
	}
	s.saveMu.Lock()
	id, err := scanner.RenameWorkflowFile(info.Path, workflow.ID, request.GetNewFileName())
	s.saveMu.Unlock()
	if err != nil {
		return nil, fileError(err, "the workflow file could not be renamed")
	}
	_, _ = s.repositories.Refresh(ctx, info.ID)
	return &corev1.RenameWorkflowFileResponse{WorkflowId: id}, nil
}

// fileError maps the scanner's write errors to gRPC status; the messages are
// shown to the user.
func fileError(err error, fallback string) error {
	switch {
	case errors.Is(err, scanner.ErrBadFileName):
		return status.Error(codes.InvalidArgument, "use letters, digits, dots, dashes and underscores, start with a letter or digit, and end the name in .yml or .yaml (at most 100 characters)")
	case errors.Is(err, scanner.ErrExists):
		return status.Error(codes.AlreadyExists, "a file with that name already exists in .github/workflows")
	case errors.Is(err, scanner.ErrTooManyFiles):
		return status.Error(codes.FailedPrecondition, "this repository already has 200 workflow files, as many as Runnir reads")
	case errors.Is(err, scanner.ErrReadOnly):
		return status.Error(codes.FailedPrecondition, "the workflows folder is read-only")
	case errors.Is(err, scanner.ErrTooLargeToSave):
		return status.Error(codes.InvalidArgument, "the workflow file would be larger than 1 MiB")
	case errors.Is(err, scanner.ErrNotText):
		return status.Error(codes.InvalidArgument, "the workflow file must be UTF-8 text")
	case errors.Is(err, scanner.ErrNoWorkflowFile):
		return status.Error(codes.FailedPrecondition, "the workflows folder or file cannot be written; refresh the repository")
	default:
		return status.Error(codes.Internal, fallback)
	}
}
