package server

import (
	"context"
	"errors"
	"os"
	"runtime"
	"sync"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	"runnir/core/internal/approval"
	"runnir/core/internal/buildinfo"
	"runnir/core/internal/dispatch"
	"runnir/core/internal/events"
	"runnir/core/internal/execution"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/localrun"
	"runnir/core/internal/repository"
	"runnir/core/internal/validate"
)

// service implements the RunnirCore RPCs. Unimplemented methods return
// codes.Unimplemented until their phase lands.
type service struct {
	corev1.UnimplementedRunnirCoreServer
	repositories *repository.Manager
	events       *events.Bus
	executions   *execution.Coordinator
	// accounts holds github.com and the Enterprise servers, each with its
	// own token and client.
	accounts     *github.Accounts
	dispatches   *dispatch.Store
	runActions   *approval.Store[runAction]
	tools        toolChecker
	localRuns    *approval.Store[localRunApproval]
	localOutputs *localrun.Outputs
	// home is the user's home directory and actCache act's cache of
	// actions, kept between runs.
	home     string
	actCache string
	// saveMu serializes workflow file saves.
	saveMu sync.Mutex
}

func (s *service) HealthCheck(context.Context, *corev1.HealthCheckRequest) (*corev1.HealthCheckResponse, error) {
	var memory runtime.MemStats
	runtime.ReadMemStats(&memory)
	return &corev1.HealthCheckResponse{
		CoreVersion:         buildinfo.Version,
		ProtocolVersion:     buildinfo.ProtocolVersion,
		OpenRepositoryCount: uint32(s.repositories.Count()),
		ProcessId:           uint32(os.Getpid()),
		GithubCredentialSet: s.hasCredential(),
		// Go runtime's total memory obtained from the OS; a coarse stand-in
		// for resident size until the diagnostics phase.
		ResidentMemoryBytes: memory.Sys,
	}, nil
}

// hasCredential reports github.com's token, as before Enterprise servers.
func (s *service) hasCredential() bool {
	dotcom, _ := s.accounts.Get("")
	_, ok := dotcom.Credential.Token()
	return ok
}

// serverFrom reads a request's server; nil or an empty id is github.com.
func serverFrom(message *corev1.GithubServer) github.Server {
	if message.GetId() == "" {
		return github.Server{}
	}
	return github.Server{ID: message.GetId(), APIURL: message.GetApiUrl(), WebHost: message.GetWebHost()}
}

func (s *service) SetGitHubCredential(_ context.Context, request *corev1.SetGitHubCredentialRequest) (*corev1.SetGitHubCredentialResponse, error) {
	account, err := s.accounts.Set(serverFrom(request.GetServer()), request.GetToken())
	switch {
	case errors.Is(err, github.ErrInvalidServer):
		return nil, status.Error(codes.InvalidArgument, "not a valid GitHub server")
	case errors.Is(err, github.ErrTooManyServers):
		return nil, status.Errorf(codes.ResourceExhausted, "at most %d Enterprise servers", github.MaxEnterpriseServers)
	case err != nil:
		return nil, status.Error(codes.InvalidArgument, "not a valid GitHub token")
	}
	return &corev1.SetGitHubCredentialResponse{Kind: credentialKind(account.Credential.Kind())}, nil
}

func (s *service) ClearGitHubCredential(_ context.Context, request *corev1.ClearGitHubCredentialRequest) (*corev1.ClearGitHubCredentialResponse, error) {
	s.accounts.Clear(request.GetServerId())
	return &corev1.ClearGitHubCredentialResponse{}, nil
}

func (s *service) OpenRepository(ctx context.Context, request *corev1.OpenRepositoryRequest) (*corev1.RepositoryResponse, error) {
	info, err := s.repositories.Open(ctx, request.GetPath())
	if err != nil {
		return nil, rpcError(err)
	}
	return &corev1.RepositoryResponse{Repository: s.repositoryMessage(info)}, nil
}

func (s *service) RefreshRepository(ctx context.Context, request *corev1.RefreshRepositoryRequest) (*corev1.RepositoryResponse, error) {
	info, err := s.repositories.Refresh(ctx, request.GetRepositoryId())
	if err != nil {
		return nil, rpcError(err)
	}
	return &corev1.RepositoryResponse{Repository: s.repositoryMessage(info)}, nil
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

// ValidateWorkflows checks workflow files with the built-in actionlint.
func (s *service) ValidateWorkflows(ctx context.Context, request *corev1.ValidateWorkflowsRequest) (*corev1.ValidateWorkflowsResponse, error) {
	info, err := s.repositories.Get(request.GetRepositoryId())
	if err != nil {
		return nil, rpcError(err)
	}
	report, err := validate.Workflows(ctx, info.Path, request.GetWorkflowId())
	switch {
	case errors.Is(err, validate.ErrUnknownWorkflow):
		return nil, status.Error(codes.NotFound, "workflow not found")
	case errors.Is(err, validate.ErrPrepare):
		return nil, status.Error(codes.Internal, "the check could not be prepared in the Core's temporary directory")
	case err != nil:
		return nil, rpcError(err)
	}
	out := &corev1.ValidateWorkflowsResponse{Validator: report.Validator, ConfigProblem: report.ConfigProblem}
	for _, result := range report.Results {
		item := &corev1.WorkflowValidation{WorkflowId: result.WorkflowID, Problem: result.Problem, Truncated: result.Truncated}
		for _, d := range result.Diagnostics {
			item.Diagnostics = append(item.Diagnostics, &corev1.WorkflowDiagnostic{
				Line: int32(d.Line), Column: int32(d.Column), Kind: d.Kind, Message: d.Message,
			})
		}
		out.Workflows = append(out.Workflows, item)
	}
	return out, nil
}

// StartWorkflow starts or queues an execution of the latest scanned workflow.
// The execution works on a copy taken now; refreshes do not change it.
func (s *service) StartWorkflow(_ context.Context, request *corev1.StartWorkflowRequest) (*corev1.ExecutionResponse, error) {
	info, err := s.repositories.Get(request.GetRepositoryId())
	if err != nil {
		return nil, rpcError(err)
	}
	workflows, err := s.repositories.Workflows(info.ID)
	if err != nil {
		return nil, rpcError(err)
	}
	for _, w := range workflows {
		if w.ID != request.GetWorkflowId() {
			continue
		}
		if w.ParseError != "" {
			return nil, status.Error(codes.FailedPrecondition, "workflow has a parse error and cannot run")
		}
		started, err := s.executions.Start(info.ID, info.Path, w, request.GetRef())
		if err != nil {
			return nil, rpcError(err)
		}
		return &corev1.ExecutionResponse{ExecutionId: started.ID, RepositoryId: started.RepositoryID, State: started.State}, nil
	}
	return nil, status.Error(codes.NotFound, "workflow not found")
}

// SubscribeEvents streams events until the client goes away, the Core shuts
// down (Unavailable) or the client falls behind (ResourceExhausted). The first
// message is CORE_READY carrying the baseline sequence; a client that sees
// ResourceExhausted or a gap in sequences should resubscribe and reload state.
// A client that stops reading keeps this goroutine blocked in Send until it
// disconnects, but the queue behind it stays bounded.
func (s *service) SubscribeEvents(request *corev1.SubscribeEventsRequest, stream corev1.RunnirCore_SubscribeEventsServer) error {
	subscription := s.events.Subscribe(request.GetRepositoryIds())
	defer subscription.Close()

	ready := events.Event{Sequence: subscription.Baseline, Type: corev1.CoreEventType_CORE_EVENT_TYPE_CORE_READY, At: time.Now()}
	if err := stream.Send(eventToProto(ready)); err != nil {
		return err
	}
	for {
		select {
		case <-stream.Context().Done():
			return status.FromContextError(stream.Context().Err()).Err()
		case e, ok := <-subscription.C:
			if !ok {
				if errors.Is(subscription.Err(), events.ErrOverflow) {
					return status.Error(codes.ResourceExhausted, "subscriber fell behind; resubscribe and reload state")
				}
				return status.Error(codes.Unavailable, "core is shutting down")
			}
			if err := stream.Send(eventToProto(e)); err != nil {
				return err
			}
		}
	}
}

func eventToProto(e events.Event) *corev1.CoreEvent {
	return &corev1.CoreEvent{
		Sequence:       e.Sequence,
		Type:           e.Type,
		RepositoryId:   e.RepositoryID,
		ExecutionId:    e.ExecutionID,
		ExecutionState: e.ExecutionState,
		Message:        e.Message,
		OccurredAt:     timestamppb.New(e.At),
	}
}

func fromRepository(e repository.Event) events.Event {
	out := events.Event{RepositoryID: e.RepositoryID}
	switch e.Type {
	case repository.RepositoryOpened:
		out.Type = corev1.CoreEventType_CORE_EVENT_TYPE_REPOSITORY_OPENED
	case repository.RepositoryRefreshed:
		out.Type = corev1.CoreEventType_CORE_EVENT_TYPE_REPOSITORY_REFRESHED
	case repository.RepositoryClosed:
		out.Type = corev1.CoreEventType_CORE_EVENT_TYPE_REPOSITORY_CLOSED
	}
	return out
}

// repositoryMessage is a repository as the app sees it. github_repository
// is set only for an origin on a GitHub server the Core knows.
func (s *service) repositoryMessage(info repository.Info) *corev1.Repository {
	out := &corev1.Repository{
		Id: info.ID, Path: info.Path, Branch: info.Branch, WorkflowCount: uint32(info.WorkflowCount),
		OriginHost: info.OriginHost,
	}
	if account, ok := s.accounts.ForHost(info.OriginHost); ok && info.OriginRepository != "" {
		out.GithubRepository = info.OriginRepository
		out.GithubServerId = account.Server.ID
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
	case errors.Is(err, repository.ErrAccessDenied):
		return status.Error(codes.PermissionDenied, "the Core cannot read this folder")
	case errors.Is(err, repository.ErrNotFound):
		return status.Error(codes.NotFound, "repository not found")
	case errors.Is(err, execution.ErrQueueFull):
		return status.Error(codes.ResourceExhausted, "execution queue is full")
	case errors.Is(err, execution.ErrShutdown):
		return status.Error(codes.Unavailable, "core is shutting down")
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return status.FromContextError(err).Err()
	default:
		return status.Error(codes.Internal, "repository operation failed")
	}
}

// timestamp leaves zero times unset rather than sending the Unix epoch.
func timestamp(t time.Time) *timestamppb.Timestamp {
	if t.IsZero() {
		return nil
	}
	return timestamppb.New(t)
}
