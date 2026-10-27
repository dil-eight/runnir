package server

import (
	"context"
	"errors"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"runnir/core/internal/changes"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/store"
	"runnir/core/internal/workspace"
)

const defaultActivityRuns = 200

// workspaceResolver gives a workspace's runtime the GitHub repository its
// open repository's origin points at now.
func (s *service) workspaceResolver(repositoryID string) workspace.Resolver {
	return func() (workspace.Target, corev1.GithubAccess) {
		target, problem, err := s.githubTarget(repositoryID, "", "")
		if err != nil {
			return workspace.Target{}, corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE
		}
		if problem != nil {
			return workspace.Target{}, problem.Access
		}
		return workspace.Target{Account: target.account, Owner: target.owner, Name: target.name}, corev1.GithubAccess_GITHUB_ACCESS_OK
	}
}

func (s *service) runtimeFor(repositoryID string) (*workspace.Runtime, error) {
	if _, err := s.repositories.Get(repositoryID); err != nil {
		return nil, rpcError(err)
	}
	rt, ok := s.workspaces.ForRepository(repositoryID)
	if !ok {
		return nil, status.Error(codes.FailedPrecondition, "the repository was opened without a workspace")
	}
	return rt, nil
}

func activityLimit(limit uint32) (int, error) {
	switch {
	case limit == 0:
		return defaultActivityRuns, nil
	case int(limit) > store.MaxRuns:
		return 0, status.Errorf(codes.InvalidArgument, "limit must be %d or less", store.MaxRuns)
	default:
		return int(limit), nil
	}
}

func (s *service) GetWorkspaceActivity(ctx context.Context, request *corev1.GetWorkspaceActivityRequest) (*corev1.WorkspaceActivity, error) {
	limit, err := activityLimit(request.GetLimit())
	if err != nil {
		return nil, err
	}
	rt, err := s.runtimeFor(request.GetRepositoryId())
	if err != nil {
		return nil, err
	}
	return s.snapshotMessage(ctx, rt, limit, request.GetRepositoryId())
}

func (s *service) RefreshWorkspaceActivity(ctx context.Context, request *corev1.RefreshWorkspaceActivityRequest) (*corev1.WorkspaceActivity, error) {
	limit, err := activityLimit(request.GetLimit())
	if err != nil {
		return nil, err
	}
	rt, err := s.runtimeFor(request.GetRepositoryId())
	if err != nil {
		return nil, err
	}
	if err := rt.Refresh(ctx, request.GetWait()); errors.Is(err, workspace.ErrClosed) {
		return nil, status.Error(codes.NotFound, "repository not found")
	} else if err != nil {
		return nil, status.FromContextError(err).Err()
	}
	return s.snapshotMessage(ctx, rt, limit, request.GetRepositoryId())
}

func (s *service) snapshotMessage(ctx context.Context, rt *workspace.Runtime, limit int, repositoryID string) (*corev1.WorkspaceActivity, error) {
	snap, err := rt.Snapshot(ctx, limit)
	if err != nil {
		if ctx.Err() != nil {
			return nil, status.FromContextError(ctx.Err()).Err()
		}
		return nil, status.Error(codes.Internal, "the workspace's activity could not be read")
	}
	freshness := &corev1.ActivityFreshness{
		Source: activitySource(snap.Provenance), Syncing: snap.Syncing,
		CheckedAt: timestamp(snap.CheckedAt), SyncedAt: timestamp(snap.SyncedAt), ChangedAt: timestamp(snap.ChangedAt),
		PullRequestsAccess: snap.PullRequestsAccess,
	}
	if snap.Access != corev1.GithubAccess_GITHUB_ACCESS_UNSPECIFIED {
		freshness.Status = statusMessage(snap.Access, snap.RetryAfter)
	}
	out := &corev1.WorkspaceActivity{Freshness: freshness, CachedRuns: uint32(snap.CachedRuns), HistoryComplete: snap.HistoryComplete}
	for _, r := range snap.Runs {
		message := runMessage(r)
		message.Link = linkMessage(snap.Analysis.Links[r.ID])
		message.SupersededBy = snap.Analysis.SupersededBy[r.ID]
		out.Runs = append(out.Runs, message)
	}
	for _, w := range snap.Workflows {
		out.Workflows = append(out.Workflows, &corev1.GitHubWorkflow{Id: w.ID, Name: w.Name, Path: w.Path, State: w.State, HtmlUrl: w.HTMLURL})
	}
	out.Changes = changeMessages(snap.Changes)
	out.ConcurrencyHints = hintMessages(changes.Hints(snap.Analysis, snap.Workflows, s.localWorkflows(repositoryID)))
	out.Savings = savingMessages(snap.Savings)
	return out, nil
}

// savingMessages leaves out kinds this Core does not know.
func savingMessages(savings []store.Saving) []*corev1.Saving {
	var out []*corev1.Saving
	for _, v := range savings {
		var kind corev1.SavingKind
		switch v.Kind {
		case store.SavingLocalRuns:
			kind = corev1.SavingKind_SAVING_KIND_LOCAL_RUNS
		default:
			continue
		}
		out = append(out, &corev1.Saving{Kind: kind, Minutes: uint64(max(v.Minutes, 0)), Count: uint32(max(v.Count, 0)), Since: timestamp(v.Since)})
	}
	return out
}

func activitySource(p workspace.Provenance) corev1.ActivitySource {
	switch p {
	case workspace.Live:
		return corev1.ActivitySource_ACTIVITY_SOURCE_LIVE
	case workspace.Cached:
		return corev1.ActivitySource_ACTIVITY_SOURCE_CACHE
	default:
		return corev1.ActivitySource_ACTIVITY_SOURCE_NONE
	}
}

func storageMessages(usage []workspace.Usage) []*corev1.WorkspaceStorage {
	out := make([]*corev1.WorkspaceStorage, 0, len(usage))
	for _, u := range usage {
		state := corev1.StorageState_STORAGE_STATE_ABSENT
		switch u.State {
		case store.Persistent:
			state = corev1.StorageState_STORAGE_STATE_PERSISTENT
		case store.MemoryOnly:
			state = corev1.StorageState_STORAGE_STATE_MEMORY_ONLY
		}
		out = append(out, &corev1.WorkspaceStorage{
			WorkspaceId: u.WorkspaceID, State: state, Note: u.Note, Open: u.Open,
			DatabaseBytes: u.DatabaseBytes, LogBytes: u.LogBytes, CachedRuns: uint32(u.CachedRuns),
			LocalRuns: uint32(u.LocalRuns), RecoveryCopies: uint32(u.RecoveryCopies), IndexedRuns: uint32(u.IndexedRuns),
		})
	}
	return out
}

func storageError(err error) error {
	switch {
	case errors.Is(err, store.ErrInvalidWorkspace):
		return status.Error(codes.InvalidArgument, "workspace ids must be UUIDs")
	case errors.Is(err, workspace.ErrOpen):
		return status.Error(codes.FailedPrecondition, "close the workspace's windows first")
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return status.FromContextError(err).Err()
	default:
		return status.Error(codes.Internal, "workspace data could not be changed")
	}
}

func (s *service) GetStorageUsage(ctx context.Context, request *corev1.GetStorageUsageRequest) (*corev1.GetStorageUsageResponse, error) {
	usage, err := s.workspaces.Usage(ctx, request.GetWorkspaceIds())
	if err != nil {
		return nil, storageError(err)
	}
	return &corev1.GetStorageUsageResponse{Workspaces: storageMessages(usage), KeepJobLogs: s.workspaces.KeepLogs()}, nil
}

func (s *service) ClearWorkspaceCache(ctx context.Context, request *corev1.ClearWorkspaceCacheRequest) (*corev1.ClearWorkspaceCacheResponse, error) {
	usage, err := s.workspaces.ClearCache(ctx, request.GetWorkspaceIds())
	if err != nil {
		return nil, storageError(err)
	}
	return &corev1.ClearWorkspaceCacheResponse{Workspaces: storageMessages(usage)}, nil
}

func (s *service) DeleteWorkspaceData(_ context.Context, request *corev1.DeleteWorkspaceDataRequest) (*corev1.DeleteWorkspaceDataResponse, error) {
	if err := s.workspaces.Delete(request.GetWorkspaceId()); err != nil {
		return nil, storageError(err)
	}
	return &corev1.DeleteWorkspaceDataResponse{}, nil
}

func (s *service) SetStoragePreferences(_ context.Context, request *corev1.SetStoragePreferencesRequest) (*corev1.SetStoragePreferencesResponse, error) {
	if err := s.workspaces.SetKeepLogs(request.GetKeepJobLogs(), request.GetDeleteKeptLogs()); err != nil {
		return nil, status.Error(codes.Internal, "kept logs could not all be deleted")
	}
	return &corev1.SetStoragePreferencesResponse{}, nil
}
