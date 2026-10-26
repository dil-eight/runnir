package server

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	"runnir/core/internal/dispatch"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/scanner"
	"runnir/core/internal/store"
	"runnir/core/internal/workspace"
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
		SecretInputs: secretInputs(definition, request.GetInputs()),
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
		out.HistoryId = s.recordDispatch(ctx, prepared, sentAt, runID)
	}
	return out, nil
}

// secretInputs names the inputs with a value that looks secret: by the
// input's name or description, or by the shape of the value itself (a token
// pasted into "notes"). The value is still sent; the history never keeps it.
func secretInputs(definition scanner.DispatchDefinition, inputs map[string]string) []string {
	var out []string
	for _, input := range definition.Inputs {
		value := inputs[input.Name]
		if value != "" && (dispatch.LooksSecret(input.Name, input.Description) || dispatch.LooksSecretValue(value)) {
			out = append(out, input.Name)
		}
	}
	return out
}

// recordDispatch keeps an accepted dispatch in its workspace's history and
// returns the entry's id, or 0 when nothing was kept: a repository named
// directly or opened without a workspace has no database. A failure to
// write the history never fails a dispatch that GitHub already accepted.
func (s *service) recordDispatch(ctx context.Context, prepared dispatch.Request, sentAt time.Time, runID int64) int64 {
	if prepared.RepositoryID == "" {
		return 0
	}
	rt, ok := s.workspaces.ForRepository(prepared.RepositoryID)
	if !ok {
		return 0
	}
	kept := map[string]string{}
	for name, value := range prepared.Inputs {
		if !slices.Contains(prepared.SecretInputs, name) {
			kept[name] = value
		}
	}
	omitted := slices.Clone(prepared.SecretInputs)
	slices.Sort(omitted)
	id, _ := rt.Store().RecordDispatch(ctx, store.DispatchRecord{
		Source:       store.Source{ServerID: prepared.ServerID, Repository: strings.ToLower(prepared.Owner + "/" + prepared.Name)},
		WorkflowPath: prepared.WorkflowPath, Ref: prepared.Ref, Inputs: kept, Omitted: omitted, SentAt: sentAt, RunID: runID,
	})
	return id
}

func (s *service) ListDispatchHistory(ctx context.Context, request *corev1.ListDispatchHistoryRequest) (*corev1.ListDispatchHistoryResponse, error) {
	rt, source, err := s.historyScope(request.GetRepositoryId())
	if err != nil {
		return nil, err
	}
	out := &corev1.ListDispatchHistoryResponse{}
	if rt == nil {
		return out, nil // no GitHub remote now, so no history to show
	}
	records, err := rt.Store().DispatchHistory(ctx, source, request.GetWorkflowPath(), int(request.GetLimit()))
	if err != nil {
		return nil, status.Error(codes.Internal, "could not read the dispatch history")
	}
	for _, r := range records {
		out.Records = append(out.Records, &corev1.DispatchRecord{
			Id: r.ID, WorkflowPath: r.WorkflowPath, Ref: r.Ref, Inputs: r.Inputs, OmittedInputs: r.Omitted,
			SentAt: timestamppb.New(r.SentAt), RunId: r.RunID,
		})
	}
	return out, nil
}

// historyScope is the workspace of a repository and the GitHub repository its
// origin points at now, which the history is kept for. The runtime is nil
// when the origin names none.
func (s *service) historyScope(repositoryID string) (*workspace.Runtime, store.Source, error) {
	rt, err := s.runtimeFor(repositoryID)
	if err != nil {
		return nil, store.Source{}, err
	}
	target, problem, err := s.githubTarget(repositoryID, "", "")
	if err != nil {
		return nil, store.Source{}, err
	}
	if problem != nil {
		return nil, store.Source{}, nil
	}
	return rt, store.Source{ServerID: target.account.Server.ID, Repository: strings.ToLower(target.owner + "/" + target.name)}, nil
}

func (s *service) ClearDispatchHistory(ctx context.Context, request *corev1.ClearDispatchHistoryRequest) (*corev1.ClearDispatchHistoryResponse, error) {
	rt, source, err := s.historyScope(request.GetRepositoryId())
	if err != nil {
		return nil, err
	}
	if rt == nil {
		return &corev1.ClearDispatchHistoryResponse{}, nil
	}
	removed, err := rt.Store().ClearDispatchHistory(ctx, source)
	if err != nil {
		return nil, status.Error(codes.Internal, "could not clear the dispatch history")
	}
	return &corev1.ClearDispatchHistoryResponse{Removed: uint32(removed)}, nil
}

func (s *service) LinkDispatchRun(ctx context.Context, request *corev1.LinkDispatchRunRequest) (*corev1.LinkDispatchRunResponse, error) {
	if request.GetId() <= 0 || request.GetRunId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "id and run_id are required")
	}
	rt, err := s.runtimeFor(request.GetRepositoryId())
	if err != nil {
		return nil, err
	}
	if err := rt.Store().LinkDispatchRun(ctx, request.GetId(), request.GetRunId()); err != nil {
		return nil, status.Error(codes.Internal, "could not save the run of the dispatch")
	}
	return &corev1.LinkDispatchRunResponse{}, nil
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
