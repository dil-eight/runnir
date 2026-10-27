package server

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/scanner"
	"runnir/core/internal/workspace"
)

// githubRepo is a repository on one server, with that server's account.
type githubRepo struct {
	account     *github.Account
	owner, name string
}

// githubTarget resolves a request's repository: githubRepository
// ("owner/name") on serverID ("" is github.com) for a repository without a
// local clone, otherwise the origin of the open repository repositoryID on
// the server whose web host it names. An unknown server is SIGNED_OUT and
// an origin on no known server NO_REMOTE, both statuses; an unknown
// repository id is NOT_FOUND and a malformed name INVALID_ARGUMENT.
func (s *service) githubTarget(repositoryID, serverID, githubRepository string) (githubRepo, *corev1.GitHubStatus, error) {
	if githubRepository != "" {
		if !github.ValidRepository(githubRepository) {
			return githubRepo{}, nil, status.Error(codes.InvalidArgument, "github_repository must be owner/name")
		}
		account, ok := s.accounts.Get(serverID)
		if !ok {
			return githubRepo{}, &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT}, nil
		}
		owner, name, _ := strings.Cut(githubRepository, "/")
		return githubRepo{account: account, owner: owner, name: name}, nil, nil
	}
	info, err := s.repositories.Get(repositoryID)
	if err != nil {
		return githubRepo{}, nil, rpcError(err)
	}
	owner, name, ok := strings.Cut(info.OriginRepository, "/")
	account, known := s.accounts.ForHost(info.OriginHost)
	if !ok || owner == "" || name == "" || !known {
		return githubRepo{}, &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE}, nil
	}
	return githubRepo{account: account, owner: owner, name: name}, nil, nil
}

// githubStatus maps a client error to the status returned to the app, and
// forgets the token of the account GitHub rejected. Context errors stay
// call errors.
func (s *service) githubStatus(account *github.Account, err error) (*corev1.GitHubStatus, error) {
	access, retry, cancelled := workspace.Access(account, err)
	if cancelled != nil {
		return nil, status.FromContextError(cancelled).Err()
	}
	return statusMessage(access, retry), nil
}

// statusMessage is a GitHub outcome for the app; retry only when rate limited.
func statusMessage(access corev1.GithubAccess, retry time.Time) *corev1.GitHubStatus {
	out := &corev1.GitHubStatus{Access: access}
	if access == corev1.GithubAccess_GITHUB_ACCESS_RATE_LIMITED && !retry.IsZero() {
		out.RetryAfter = timestamppb.New(retry)
	}
	return out
}

// ListGitHubRepositories lists the repositories the user's token reaches.
func (s *service) ListGitHubRepositories(ctx context.Context, request *corev1.ListGitHubRepositoriesRequest) (*corev1.ListGitHubRepositoriesResponse, error) {
	account, ok := s.accounts.Get(request.GetGithubServer())
	if !ok {
		return &corev1.ListGitHubRepositoriesResponse{Status: &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT}}, nil
	}
	listing, fetchErr := account.Client.AccountRepositories(ctx)
	result, err := s.githubStatus(account, fetchErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.ListGitHubRepositoriesResponse{Status: result, Truncated: listing.Truncated,
		CredentialKind: credentialKind(account.Credential.Kind())}
	for _, i := range listing.Installations {
		out.Installations = append(out.Installations, installationMessage(i))
	}
	for _, r := range listing.Repositories {
		out.Repositories = append(out.Repositories, &corev1.GitHubAccountRepository{
			FullName: r.FullName, Owner: r.Owner, Name: r.Name, Description: r.Description, Visibility: r.Visibility,
			DefaultBranch: r.DefaultBranch, HtmlUrl: r.HTMLURL, PushedAt: timestamp(r.PushedAt),
			Archived: r.Archived, Fork: r.Fork, CanPush: r.CanPush, InstallationId: r.InstallationID,
		})
	}
	return out, nil
}

func (s *service) ListGitHubWorkflows(ctx context.Context, request *corev1.ListGitHubWorkflowsRequest) (*corev1.ListGitHubWorkflowsResponse, error) {
	target, problem, err := s.githubTarget(request.GetRepositoryId(), request.GetGithubServer(), request.GetGithubRepository())
	if err != nil || problem != nil {
		return &corev1.ListGitHubWorkflowsResponse{Status: problem}, err
	}
	workflows, fetchErr := target.account.Client.Workflows(ctx, target.owner, target.name)
	result, err := s.githubStatus(target.account, fetchErr)
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
	target, problem, err := s.githubTarget(request.GetRepositoryId(), request.GetGithubServer(), request.GetGithubRepository())
	if err != nil || problem != nil {
		return &corev1.GetGitHubRepositoryResponse{Status: problem}, err
	}
	repository, fetchErr := target.account.Client.Repository(ctx, target.owner, target.name)
	result, err := s.githubStatus(target.account, fetchErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.GetGitHubRepositoryResponse{
		Status: result, FullName: repository.FullName, Visibility: repository.Visibility,
		DefaultBranch: repository.DefaultBranch, HtmlUrl: repository.HTMLURL, CanPush: repository.CanPush,
	}
	// The owner's installation says whether permissions wait for an owner
	// to accept them; a failed lookup leaves it out.
	if installation, found, err := target.account.Client.InstallationFor(ctx, target.owner); err == nil && found {
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
	target, problem, err := s.githubTarget(request.GetRepositoryId(), request.GetGithubServer(), request.GetGithubRepository())
	if err != nil || problem != nil {
		return &corev1.ListWorkflowRunsResponse{Status: problem}, err
	}
	runs, fetchErr := target.account.Client.Runs(ctx, target.owner, target.name, request.GetBranch(), int(request.GetLimit()))
	result, err := s.githubStatus(target.account, fetchErr)
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
	// An open workspace's runtime serves its jobs: from the cache when they
	// cannot have changed, otherwise one read shared by every window.
	if request.GetGithubRepository() == "" {
		if _, err := s.repositories.Get(request.GetRepositoryId()); err != nil {
			return nil, rpcError(err)
		}
		if rt, ok := s.workspaces.ForRepository(request.GetRepositoryId()); ok {
			jobs, access, retry, err := rt.Jobs(ctx, request.GetRunId())
			if err != nil {
				return nil, status.FromContextError(err).Err()
			}
			out := &corev1.ListRunJobsResponse{Status: statusMessage(access, retry)}
			for _, j := range jobs {
				out.Jobs = append(out.Jobs, jobMessage(j))
			}
			return out, nil
		}
	}
	target, problem, err := s.githubTarget(request.GetRepositoryId(), request.GetGithubServer(), request.GetGithubRepository())
	if err != nil || problem != nil {
		return &corev1.ListRunJobsResponse{Status: problem}, err
	}
	jobs, fetchErr := target.account.Client.Jobs(ctx, target.owner, target.name, request.GetRunId())
	result, err := s.githubStatus(target.account, fetchErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.ListRunJobsResponse{Status: result}
	for _, j := range jobs {
		out.Jobs = append(out.Jobs, jobMessage(j))
	}
	return out, nil
}

// GetRunWorkflow reads the workflow file a run used at the run's commit and
// returns its jobs with their needs. Anything that stops it (a commit or file
// GitHub does not serve, a file that does not parse) is a problem to show,
// not an error: the app lists the run's jobs without their order instead.
func (s *service) GetRunWorkflow(ctx context.Context, request *corev1.GetRunWorkflowRequest) (*corev1.GetRunWorkflowResponse, error) {
	if request.GetRunId() <= 0 {
		return nil, status.Error(codes.InvalidArgument, "run_id is required")
	}
	target, problem, err := s.githubTarget(request.GetRepositoryId(), request.GetGithubServer(), request.GetGithubRepository())
	if err != nil || problem != nil {
		return &corev1.GetRunWorkflowResponse{Status: problem}, err
	}
	client := target.account.Client
	key := workflowFileKey{server: target.account.Server.ID, owner: target.owner, name: target.name, runID: request.GetRunId()}
	file, cached := s.workflowFiles.get(key)
	var fetchErr error
	if cached && file.missing {
		fetchErr = github.ErrNotVisible
	} else if !cached {
		file, fetchErr = readRunWorkflow(ctx, client, target.owner, target.name, request.GetRunId())
		switch {
		case fetchErr == nil:
			s.workflowFiles.put(key, file)
		case errors.Is(fetchErr, github.ErrNotVisible) && file.path != "":
			// The run was read and its file is not at its commit: that stays so.
			s.workflowFiles.put(key, workflowFile{path: file.path, missing: true})
		}
	}
	path, data := file.path, file.data
	result, err := s.githubStatus(target.account, fetchErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.GetRunWorkflowResponse{Status: result}
	switch {
	case errors.Is(fetchErr, github.ErrNotVisible):
		out.Problem = "GitHub does not serve the workflow file at this run's commit."
		// The commit or the file is gone: a lookup that finds nothing, not a refused read.
		out.Status = statusMessage(corev1.GithubAccess_GITHUB_ACCESS_OK, time.Time{})
		return out, nil
	case fetchErr != nil:
		return out, nil
	}
	workflow := scanner.ParseWorkflow(path, data)
	out.WorkflowPath = path
	if workflow.ParseError != "" {
		out.Problem = "The workflow file at this run's commit does not parse: " + workflow.ParseError
		return out, nil
	}
	for _, j := range workflow.Jobs {
		out.Jobs = append(out.Jobs, &corev1.Job{Id: j.ID, Name: j.Name, Needs: j.Needs, Manual: j.Manual, ManualInputs: j.ManualInputs})
	}
	if len(out.Jobs) == 0 {
		out.Problem = "The workflow file at this run's commit has no jobs."
	}
	return out, nil
}

// readRunWorkflow reads the workflow file a run used, at the run's commit.
// The path is the run's own; a run that does not say has the workflow's
// current path, which a file renamed since may not have at that commit.
// A file GitHub does not serve comes back with its path and ErrNotVisible.
func readRunWorkflow(ctx context.Context, client *github.Client, owner, name string, runID int64) (workflowFile, error) {
	run, err := client.Run(ctx, owner, name, runID)
	if err != nil {
		return workflowFile{}, err
	}
	path := run.WorkflowPath
	if !strings.HasPrefix(path, ".github/workflows/") {
		if path, err = client.WorkflowPath(ctx, owner, name, run.WorkflowID); err != nil {
			return workflowFile{}, err
		}
	}
	data, err := client.File(ctx, owner, name, path, run.HeadSHA)
	return workflowFile{path: path, data: data}, err
}

// workflowFileKey names the workflow file of one run: the file at the run's
// commit cannot change (a re-run uses the same commit), so the app can ask
// for it every time the run is selected without reading GitHub again.
type workflowFileKey struct {
	server, owner, name string
	runID               int64
}

type workflowFile struct {
	path string
	data []byte
	// missing: GitHub does not serve the file at the run's commit.
	missing bool
}

// workflowFileCache keeps the newest few workflow files read for run graphs.
type workflowFileCache struct {
	mu    sync.Mutex
	files map[workflowFileKey]workflowFile
	order []workflowFileKey
}

const maxWorkflowFiles = 64

func (c *workflowFileCache) get(key workflowFileKey) (workflowFile, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	file, ok := c.files[key]
	return file, ok
}

func (c *workflowFileCache) put(key workflowFileKey, file workflowFile) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.files == nil {
		c.files = map[workflowFileKey]workflowFile{}
	}
	if _, ok := c.files[key]; !ok {
		c.order = append(c.order, key)
		if len(c.order) > maxWorkflowFiles {
			delete(c.files, c.order[0])
			c.order = c.order[1:]
		}
	}
	c.files[key] = file
}

func jobMessage(j github.Job) *corev1.RunJob {
	job := &corev1.RunJob{
		Id: j.ID, Name: j.Name, Status: j.Status, Conclusion: j.Conclusion, HtmlUrl: j.HTMLURL,
		StartedAt: timestamp(j.StartedAt), CompletedAt: timestamp(j.CompletedAt),
	}
	for _, step := range j.Steps {
		job.Steps = append(job.Steps, &corev1.RunStep{Number: step.Number, Name: step.Name, Status: step.Status, Conclusion: step.Conclusion,
			StartedAt: timestamp(step.StartedAt), CompletedAt: timestamp(step.CompletedAt)})
	}
	return job
}

const maxOriginPaths = 500

// GetGitHubOrigins reads the origin of each working tree, on github.com or
// an Enterprise server the Core holds, without opening it.
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
		host, name := scanner.Origin(filepath.Clean(path))
		if account, ok := s.accounts.ForHost(host); ok && name != "" {
			out.Origins = append(out.Origins, &corev1.GitHubOrigin{Path: path, GithubRepository: name, GithubServerId: account.Server.ID})
		}
	}
	return out, nil
}

// CheckGitHubToken reports what a token can do without holding it; the
// token the Core holds is left as it is, even when GitHub refuses this one.
func (s *service) CheckGitHubToken(ctx context.Context, request *corev1.CheckGitHubTokenRequest) (*corev1.CheckGitHubTokenResponse, error) {
	checker, err := s.accounts.Checker(serverFrom(request.GetServer()))
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "not a valid GitHub server")
	}
	check, err := checker.CheckToken(ctx, request.GetToken())
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
