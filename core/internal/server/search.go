package server

import (
	"context"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/runsearch"
	"runnir/core/internal/workspace"
)

const defaultSearchLimit, maxSearchLimit = 200, 1000

func (s *service) SearchRuns(ctx context.Context, request *corev1.SearchRunsRequest) (*corev1.SearchRunsResponse, error) {
	rt, err := s.runtimeFor(request.GetRepositoryId())
	if err != nil {
		return nil, err
	}
	limit := int(request.GetLimit())
	if limit <= 0 {
		limit = defaultSearchLimit
	}
	limit = min(limit, maxSearchLimit)
	q := runsearch.Parse(request.GetQuery())
	found, err := rt.SearchSaved(ctx, q, limit)
	if err != nil {
		return nil, status.Error(codes.Internal, "the saved runs could not be searched")
	}
	out := &corev1.SearchRunsResponse{
		CachedRunIds: found.Cached, CachedSearched: uint32(found.CachedSearched), IndexedSearched: uint32(found.IndexedSearched),
		Problems: q.Problems,
	}
	for _, run := range found.Indexed {
		out.IndexedRuns = append(out.IndexedRuns, runMessage(run))
	}
	return out, nil
}

func (s *service) SearchRunsOnGitHub(ctx context.Context, request *corev1.SearchRunsOnGitHubRequest) (*corev1.SearchRunsOnGitHubResponse, error) {
	rt, err := s.runtimeFor(request.GetRepositoryId())
	if err != nil {
		return nil, err
	}
	q := runsearch.Parse(request.GetQuery())
	if !q.Active() {
		return nil, status.Error(codes.InvalidArgument, "query is required")
	}
	var cursor time.Time
	if request.GetCursor() != nil {
		cursor = request.GetCursor().AsTime()
	}
	step, err := rt.SearchGitHub(ctx, q, cursor, int(request.GetPages()))
	if err != nil {
		return nil, status.FromContextError(err).Err()
	}
	out := &corev1.SearchRunsOnGitHubResponse{
		Status:     statusMessage(step.Access, step.RetryAfter),
		NextCursor: timestamp(step.Next), LookedBackTo: timestamp(step.LookedBack),
		Pages: uint32(step.Pages), RunsRead: uint32(step.Read), Problems: q.Problems,
		Stop: stopMessage(step.Stop),
	}
	for _, run := range step.Runs {
		out.Runs = append(out.Runs, runMessage(run))
	}
	return out, nil
}

func stopMessage(stop workspace.GitHubSearchStop) corev1.SearchStop {
	switch stop {
	case workspace.SearchDone:
		return corev1.SearchStop_SEARCH_STOP_DONE
	case workspace.SearchBudget:
		return corev1.SearchStop_SEARCH_STOP_BUDGET
	case workspace.SearchRateLimited:
		return corev1.SearchStop_SEARCH_STOP_RATE_LIMITED
	case workspace.SearchBusy:
		return corev1.SearchStop_SEARCH_STOP_BUSY
	default:
		return corev1.SearchStop_SEARCH_STOP_UNAVAILABLE
	}
}

func (s *service) ClearRunIndex(ctx context.Context, request *corev1.ClearRunIndexRequest) (*corev1.ClearRunIndexResponse, error) {
	usage, err := s.workspaces.ClearRunIndex(ctx, request.GetWorkspaceIds())
	if err != nil {
		return nil, storageError(err)
	}
	return &corev1.ClearRunIndexResponse{Workspaces: storageMessages(usage)}, nil
}

func (s *service) SearchWorkspaces(ctx context.Context, request *corev1.SearchWorkspacesRequest) (*corev1.SearchWorkspacesResponse, error) {
	q := runsearch.Parse(request.GetQuery())
	found, err := s.workspaces.SearchAll(ctx, request.GetWorkspaceIds(), request.GetQuery(), int(request.GetLimitPerKind()))
	if err != nil {
		return nil, storageError(err)
	}
	out := &corev1.SearchWorkspacesResponse{Problems: q.Problems, Words: q.Words}
	for _, w := range found {
		hits := &corev1.WorkspaceSearchHits{
			WorkspaceId: w.WorkspaceID, Open: w.Open, Repository: w.Repository, SavedAt: timestamp(w.SavedAt), Problem: w.Problem,
			RunsMatched: uint32(w.RunsMatched), PullRequestsMatched: uint32(w.PullRequestsMatched),
			WorkflowsMatched: uint32(w.WorkflowsMatched), LocalRunsMatched: uint32(w.LocalRunsMatched),
		}
		for _, run := range w.Runs {
			hits.Runs = append(hits.Runs, runMessage(run))
		}
		for _, p := range w.PullRequests {
			hits.PullRequests = append(hits.PullRequests, &corev1.SearchedPullRequest{
				Number: p.Number, Title: p.Title, State: p.State, Draft: p.Draft, Author: p.Author, HeadRef: p.HeadRef,
				BaseRef: p.BaseRef, HtmlUrl: p.HTMLURL, UpdatedAt: timestamp(p.UpdatedAt),
			})
		}
		for _, wf := range w.Workflows {
			hits.Workflows = append(hits.Workflows, &corev1.GitHubWorkflow{Id: wf.ID, Name: wf.Name, Path: wf.Path, State: wf.State, HtmlUrl: wf.HTMLURL})
		}
		for _, r := range w.LocalRuns {
			hits.LocalRuns = append(hits.LocalRuns, &corev1.SearchedLocalRun{
				ExecutionId: r.ExecutionID, WorkflowPath: r.WorkflowPath, JobId: r.JobID, Event: r.Event, State: r.State,
				Message: r.Message, StartedAt: timestamp(r.StartedAt),
			})
		}
		out.Workspaces = append(out.Workspaces, hits)
	}
	return out, nil
}
