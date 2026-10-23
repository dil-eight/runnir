package server

import (
	"context"
	"errors"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	"runnir/core/internal/dispatch"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/scanner"
)

func (s *service) ListGitHubRefs(ctx context.Context, request *corev1.ListGitHubRefsRequest) (*corev1.ListGitHubRefsResponse, error) {
	target, problem, err := s.githubTarget(request.GetRepositoryId(), request.GetGithubServer(), request.GetGithubRepository())
	if err != nil || problem != nil {
		return &corev1.ListGitHubRefsResponse{Status: problem}, err
	}
	refs, fetchErr := target.account.Client.Refs(ctx, target.owner, target.name)
	result, err := s.githubStatus(target.account, fetchErr)
	if err != nil {
		return nil, err
	}
	return &corev1.ListGitHubRefsResponse{Status: result, DefaultBranch: refs.DefaultBranch, Branches: refs.Branches, Tags: refs.Tags}, nil
}

func (s *service) DescribeWorkflowDispatch(ctx context.Context, request *corev1.DescribeWorkflowDispatchRequest) (*corev1.DescribeWorkflowDispatchResponse, error) {
	if request.GetWorkflowPath() == "" || request.GetRef() == "" {
		return nil, status.Error(codes.InvalidArgument, "workflow_path and ref are required")
	}
	target, problem, err := s.githubTarget(request.GetRepositoryId(), request.GetGithubServer(), request.GetGithubRepository())
	if err != nil || problem != nil {
		return &corev1.DescribeWorkflowDispatchResponse{Status: problem}, err
	}
	data, fetchErr := target.account.Client.File(ctx, target.owner, target.name, request.GetWorkflowPath(), request.GetRef())
	result, err := s.githubStatus(target.account, fetchErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.DescribeWorkflowDispatchResponse{Status: result}
	if fetchErr != nil {
		return out, nil
	}
	definition, parseErr := scanner.ParseDispatch(data)
	if parseErr != nil {
		out.ParseError = "The workflow file on this ref is not valid YAML."
		return out, nil
	}
	out.Dispatchable = definition.Dispatchable
	for _, input := range definition.Inputs {
		out.Inputs = append(out.Inputs, dispatchInputMessage(input))
	}
	return out, nil
}

func dispatchInputMessage(input scanner.DispatchInput) *corev1.DispatchInput {
	return &corev1.DispatchInput{
		Name: input.Name, Description: input.Description, Type: inputType(input.Type),
		Required: input.Required, DefaultValue: input.Default, Options: input.Options,
	}
}

func (s *service) PrepareWorkflowDispatch(ctx context.Context, request *corev1.PrepareWorkflowDispatchRequest) (*corev1.PrepareWorkflowDispatchResponse, error) {
	if request.GetWorkflowId() <= 0 || request.GetRef() == "" {
		return nil, status.Error(codes.InvalidArgument, "workflow_id and ref are required")
	}
	target, problem, err := s.githubTarget(request.GetRepositoryId(), request.GetGithubServer(), request.GetGithubRepository())
	if err != nil || problem != nil {
		return &corev1.PrepareWorkflowDispatchResponse{Status: problem}, err
	}
	// Validate against the definition GitHub will run: the workflow's own file
	// at the requested ref.
	path, fetchErr := target.account.Client.WorkflowPath(ctx, target.owner, target.name, request.GetWorkflowId())
	var data []byte
	if fetchErr == nil {
		data, fetchErr = target.account.Client.File(ctx, target.owner, target.name, path, request.GetRef())
	}
	result, err := s.githubStatus(target.account, fetchErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.PrepareWorkflowDispatchResponse{Status: result, WorkflowPath: path}
	if fetchErr != nil {
		return out, nil
	}
	definition, parseErr := scanner.ParseDispatch(data)
	if parseErr != nil {
		out.Problems = []string{"The workflow file on " + request.GetRef() + " is not valid YAML."}
		return out, nil
	}
	if problems := dispatch.Validate(definition, request.GetRef(), request.GetInputs()); len(problems) > 0 {
		out.Problems = problems
		return out, nil
	}
	// A dispatch for a repository named directly belongs to no open repository.
	repositoryID := request.GetRepositoryId()
	if request.GetGithubRepository() != "" {
		repositoryID = ""
	}
	pending, err := s.dispatches.Prepare(dispatch.Request{
		RepositoryID: repositoryID, ServerID: target.account.Server.ID, Owner: target.owner, Name: target.name,
		WorkflowID: request.GetWorkflowId(), WorkflowPath: path, Ref: request.GetRef(), Inputs: request.GetInputs(),
	})
	if errors.Is(err, dispatch.ErrTooMany) {
		return nil, status.Error(codes.ResourceExhausted, err.Error())
	} else if err != nil {
		return nil, status.Error(codes.Internal, "could not prepare the dispatch")
	}
	out.DispatchId = pending.ID
	out.ExpiresAt = timestamppb.New(pending.ExpiresAt)
	return out, nil
}

func (s *service) ConfirmWorkflowDispatch(ctx context.Context, request *corev1.ConfirmWorkflowDispatchRequest) (*corev1.ConfirmWorkflowDispatchResponse, error) {
	prepared, err := s.dispatches.Confirm(request.GetDispatchId())
	if err != nil {
		return nil, status.Error(codes.FailedPrecondition, "this confirmation expired or was already used; review the run again")
	}
	// An open repository it was prepared for must still be open: a closed
	// one may have been relinked. One named directly has none.
	if prepared.RepositoryID != "" {
		if _, err := s.repositories.Get(prepared.RepositoryID); err != nil {
			return nil, rpcError(err)
		}
	}
	// The server it was prepared for; one removed since is signed out.
	account, ok := s.accounts.Get(prepared.ServerID)
	if !ok {
		return &corev1.ConfirmWorkflowDispatchResponse{Status: &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT}}, nil
	}
	sentAt := time.Now()
	runID, sendErr := account.Client.Dispatch(ctx, prepared.Owner, prepared.Name, prepared.WorkflowID, prepared.Ref, prepared.Inputs)
	var rejected *github.RejectedError
	if errors.As(sendErr, &rejected) {
		return &corev1.ConfirmWorkflowDispatchResponse{
			Status:    &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_OK},
			Rejection: rejected.Message,
		}, nil
	}
	result, err := s.githubStatus(account, sendErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.ConfirmWorkflowDispatchResponse{Status: result}
	if sendErr == nil {
		out.DispatchedAt = timestamppb.New(sentAt)
		out.RunId = runID
	}
	return out, nil
}

func inputType(name string) corev1.DispatchInputType {
	switch name {
	case "boolean":
		return corev1.DispatchInputType_DISPATCH_INPUT_TYPE_BOOLEAN
	case "choice":
		return corev1.DispatchInputType_DISPATCH_INPUT_TYPE_CHOICE
	case "number":
		return corev1.DispatchInputType_DISPATCH_INPUT_TYPE_NUMBER
	case "environment":
		return corev1.DispatchInputType_DISPATCH_INPUT_TYPE_ENVIRONMENT
	default:
		return corev1.DispatchInputType_DISPATCH_INPUT_TYPE_STRING
	}
}
