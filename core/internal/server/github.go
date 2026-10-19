package server

import (
	"context"
	"errors"
	"strings"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
)

// githubTarget resolves an open repository to its github.com owner and name.
// A missing remote is a status, not an error; an unknown id is NOT_FOUND.
func (s *service) githubTarget(repositoryID string) (owner, name string, problem *corev1.GitHubStatus, err error) {
	info, err := s.repositories.Get(repositoryID)
	if err != nil {
		return "", "", nil, rpcError(err)
	}
	owner, name, ok := strings.Cut(info.GitHubRepository, "/")
	if !ok || owner == "" || name == "" {
		return "", "", &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE}, nil
	}
	return owner, name, nil, nil
}

// githubStatus maps a client error to the status returned to the app, and
// forgets a token GitHub rejected. Context errors stay call errors.
func (s *service) githubStatus(err error) (*corev1.GitHubStatus, error) {
	var rateLimit *github.RateLimitError
	switch {
	case err == nil:
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_OK}, nil
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return nil, status.FromContextError(err).Err()
	case errors.Is(err, github.ErrNoCredential):
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT}, nil
	case errors.Is(err, github.ErrUnauthorized):
		s.credential.Clear()
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_TOKEN_REJECTED}, nil
	case errors.Is(err, github.ErrNotVisible):
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE}, nil
	case errors.As(err, &rateLimit):
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED, RetryAfter: timestamppb.New(rateLimit.Reset)}, nil
	default:
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE}, nil
	}
}

func (s *service) ListGitHubWorkflows(ctx context.Context, request *corev1.ListGitHubWorkflowsRequest) (*corev1.ListGitHubWorkflowsResponse, error) {
	owner, name, problem, err := s.githubTarget(request.GetRepositoryId())
	if err != nil || problem != nil {
		return &corev1.ListGitHubWorkflowsResponse{Status: problem}, err
	}
	workflows, fetchErr := s.github.Workflows(ctx, owner, name)
	result, err := s.githubStatus(fetchErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.ListGitHubWorkflowsResponse{Status: result}
	for _, w := range workflows {
		out.Workflows = append(out.Workflows, &corev1.GitHubWorkflow{Id: w.ID, Name: w.Name, Path: w.Path, State: w.State, HtmlUrl: w.HTMLURL})
	}
	return out, nil
}

func (s *service) ListWorkflowRuns(ctx context.Context, request *corev1.ListWorkflowRunsRequest) (*corev1.ListWorkflowRunsResponse, error) {
	if request.GetLimit() > 100 {
		return nil, status.Error(codes.InvalidArgument, "limit must be 100 or less")
	}
	owner, name, problem, err := s.githubTarget(request.GetRepositoryId())
	if err != nil || problem != nil {
		return &corev1.ListWorkflowRunsResponse{Status: problem}, err
	}
	runs, fetchErr := s.github.Runs(ctx, owner, name, request.GetBranch(), int(request.GetLimit()))
	result, err := s.githubStatus(fetchErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.ListWorkflowRunsResponse{Status: result}
	for _, r := range runs {
		out.Runs = append(out.Runs, runMessage(r))
	}
	return out, nil
}

func (s *service) ListRunJobs(ctx context.Context, request *corev1.ListRunJobsRequest) (*corev1.ListRunJobsResponse, error) {
	if request.GetRunId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "run_id is required")
	}
	owner, name, problem, err := s.githubTarget(request.GetRepositoryId())
	if err != nil || problem != nil {
		return &corev1.ListRunJobsResponse{Status: problem}, err
	}
	jobs, fetchErr := s.github.Jobs(ctx, owner, name, request.GetRunId())
	result, err := s.githubStatus(fetchErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.ListRunJobsResponse{Status: result}
	for _, j := range jobs {
		job := &corev1.RunJob{
			Id: j.ID, Name: j.Name, Status: j.Status, Conclusion: j.Conclusion, HtmlUrl: j.HTMLURL,
			StartedAt: timestamp(j.StartedAt), CompletedAt: timestamp(j.CompletedAt),
		}
		for _, step := range j.Steps {
			job.Steps = append(job.Steps, &corev1.RunStep{Number: step.Number, Name: step.Name, Status: step.Status, Conclusion: step.Conclusion,
				StartedAt: timestamp(step.StartedAt), CompletedAt: timestamp(step.CompletedAt)})
		}
		out.Jobs = append(out.Jobs, job)
	}
	return out, nil
}
