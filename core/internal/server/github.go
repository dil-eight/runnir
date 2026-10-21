package server

import (
	"context"
	"errors"
	"path/filepath"
	"strings"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/scanner"
)

// githubTarget resolves a request's repository to its github.com owner and
// name: githubRepository ("owner/name") when set, for a repository without a
// local clone, otherwise the origin of the open repository repositoryID. A
// missing remote is a status, not an error; an unknown id is NOT_FOUND and a
// malformed name INVALID_ARGUMENT.
func (s *service) githubTarget(repositoryID, githubRepository string) (owner, name string, problem *corev1.GitHubStatus, err error) {
	if githubRepository != "" {
		if !github.ValidRepository(githubRepository) {
			return "", "", nil, status.Error(codes.InvalidArgument, "github_repository must be owner/name")
		}
		owner, name, _ = strings.Cut(githubRepository, "/")
		return owner, name, nil, nil
	}
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
	case errors.Is(err, github.ErrPermissionMissing):
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_PERMISSION_MISSING}, nil
	case errors.As(err, &rateLimit):
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED, RetryAfter: timestamppb.New(rateLimit.Reset)}, nil
	default:
		return &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE}, nil
	}
}

// ListGitHubRepositories lists the repositories the user's token reaches.
func (s *service) ListGitHubRepositories(ctx context.Context, _ *corev1.ListGitHubRepositoriesRequest) (*corev1.ListGitHubRepositoriesResponse, error) {
	account, fetchErr := s.github.AccountRepositories(ctx)
	result, err := s.githubStatus(fetchErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.ListGitHubRepositoriesResponse{Status: result, Truncated: account.Truncated,
		CredentialKind: credentialKind(s.credential.Kind())}
	for _, i := range account.Installations {
		out.Installations = append(out.Installations, installationMessage(i))
	}
	for _, r := range account.Repositories {
		out.Repositories = append(out.Repositories, &corev1.GitHubAccountRepository{
			FullName: r.FullName, Owner: r.Owner, Name: r.Name, Description: r.Description, Visibility: r.Visibility,
			DefaultBranch: r.DefaultBranch, HtmlUrl: r.HTMLURL, PushedAt: timestamp(r.PushedAt),
			Archived: r.Archived, Fork: r.Fork, CanPush: r.CanPush, InstallationId: r.InstallationID,
		})
	}
	return out, nil
}

func (s *service) ListGitHubWorkflows(ctx context.Context, request *corev1.ListGitHubWorkflowsRequest) (*corev1.ListGitHubWorkflowsResponse, error) {
	owner, name, problem, err := s.githubTarget(request.GetRepositoryId(), request.GetGithubRepository())
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

func (s *service) GetGitHubRepository(ctx context.Context, request *corev1.GetGitHubRepositoryRequest) (*corev1.GetGitHubRepositoryResponse, error) {
	owner, name, problem, err := s.githubTarget(request.GetRepositoryId(), request.GetGithubRepository())
	if err != nil || problem != nil {
		return &corev1.GetGitHubRepositoryResponse{Status: problem}, err
	}
	repository, fetchErr := s.github.Repository(ctx, owner, name)
	result, err := s.githubStatus(fetchErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.GetGitHubRepositoryResponse{
		Status: result, FullName: repository.FullName, Visibility: repository.Visibility,
		DefaultBranch: repository.DefaultBranch, HtmlUrl: repository.HTMLURL, CanPush: repository.CanPush,
	}
	// The owner's installation says whether permissions wait for an owner
	// to accept them; a failed lookup leaves it out.
	if installation, found, err := s.github.InstallationFor(ctx, owner); err == nil && found {
		out.Installation = installationMessage(installation)
	}
	return out, nil
}

func installationMessage(i github.Installation) *corev1.GitHubInstallation {
	return &corev1.GitHubInstallation{
		Id: i.ID, Account: i.Account, AccountType: i.AccountType, RepositorySelection: i.RepositorySelection, HtmlUrl: i.HTMLURL,
		MissingPermissions: i.MissingPermissions, Suspended: i.Suspended,
	}
}

func (s *service) ListWorkflowRuns(ctx context.Context, request *corev1.ListWorkflowRunsRequest) (*corev1.ListWorkflowRunsResponse, error) {
	if request.GetLimit() > 100 {
		return nil, status.Error(codes.InvalidArgument, "limit must be 100 or less")
	}
	owner, name, problem, err := s.githubTarget(request.GetRepositoryId(), request.GetGithubRepository())
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
	owner, name, problem, err := s.githubTarget(request.GetRepositoryId(), request.GetGithubRepository())
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

const maxOriginPaths = 500

// GetGitHubOrigins reads the github.com origin of each working tree without
// opening it.
func (s *service) GetGitHubOrigins(ctx context.Context, request *corev1.GetGitHubOriginsRequest) (*corev1.GetGitHubOriginsResponse, error) {
	if len(request.GetPaths()) > maxOriginPaths {
		return nil, status.Errorf(codes.InvalidArgument, "at most %d paths", maxOriginPaths)
	}
	out := &corev1.GetGitHubOriginsResponse{}
	for _, path := range request.GetPaths() {
		if err := ctx.Err(); err != nil {
			return nil, status.FromContextError(err).Err()
		}
		if !filepath.IsAbs(path) {
			continue
		}
		if name := scanner.GitHubOrigin(filepath.Clean(path)); name != "" {
			out.Origins = append(out.Origins, &corev1.GitHubOrigin{Path: path, GithubRepository: name})
		}
	}
	return out, nil
}

// CheckGitHubToken reports what a token can do without holding it; the
// token the Core holds is left as it is, even when GitHub refuses this one.
func (s *service) CheckGitHubToken(ctx context.Context, request *corev1.CheckGitHubTokenRequest) (*corev1.CheckGitHubTokenResponse, error) {
	check, err := s.github.CheckToken(ctx, request.GetToken())
	var rateLimit *github.RateLimitError
	switch {
	case errors.Is(err, github.ErrInvalidToken):
		return nil, status.Error(codes.InvalidArgument, "not a valid GitHub token")
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return nil, status.FromContextError(err).Err()
	case errors.Is(err, github.ErrUnauthorized):
		return &corev1.CheckGitHubTokenResponse{Status: &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_TOKEN_REJECTED},
			Kind: credentialKind(github.KindOf(request.GetToken()))}, nil
	case errors.As(err, &rateLimit):
		return &corev1.CheckGitHubTokenResponse{Status: &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED,
			RetryAfter: timestamppb.New(rateLimit.Reset)}}, nil
	case err != nil:
		return &corev1.CheckGitHubTokenResponse{Status: &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_UNAVAILABLE}}, nil
	}
	out := &corev1.CheckGitHubTokenResponse{
		Status: &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_OK},
		Kind:   credentialKind(check.Kind), Login: check.Login, Scopes: check.Scopes,
		Repositories: int32(check.Repositories), Suitable: check.Suitable,
	}
	if !check.ExpiresAt.IsZero() {
		out.ExpiresAt = timestamppb.New(check.ExpiresAt)
	}
	for _, item := range check.Checks {
		state := corev1.GithubTokenCheckState_GITHUB_TOKEN_CHECK_STATE_PASSED
		switch item.State {
		case github.CheckMissing:
			state = corev1.GithubTokenCheckState_GITHUB_TOKEN_CHECK_STATE_MISSING
		case github.CheckUnknown:
			state = corev1.GithubTokenCheckState_GITHUB_TOKEN_CHECK_STATE_UNKNOWN
		}
		out.Checks = append(out.Checks, &corev1.GitHubTokenCheck{Name: item.Name, State: state, Detail: item.Detail})
	}
	return out, nil
}

func credentialKind(kind github.TokenKind) corev1.GithubCredentialKind {
	switch kind {
	case github.TokenAppUser:
		return corev1.GithubCredentialKind_GITHUB_CREDENTIAL_KIND_APP_USER
	case github.TokenClassic:
		return corev1.GithubCredentialKind_GITHUB_CREDENTIAL_KIND_CLASSIC
	case github.TokenFineGrained:
		return corev1.GithubCredentialKind_GITHUB_CREDENTIAL_KIND_FINE_GRAINED
	case github.TokenOAuth:
		return corev1.GithubCredentialKind_GITHUB_CREDENTIAL_KIND_OAUTH
	default:
		return corev1.GithubCredentialKind_GITHUB_CREDENTIAL_KIND_OTHER
	}
}
