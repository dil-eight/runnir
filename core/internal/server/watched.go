package server

import (
	"context"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/watch"
)

// maxWatchedRequest bounds the repositories of one ListWatchedRuns call.
const maxWatchedRequest = 1000

// ListWatchedRuns answers the user's failed and running runs of each
// repository the app watches (B39).
func (s *service) ListWatchedRuns(ctx context.Context, request *corev1.ListWatchedRunsRequest) (*corev1.ListWatchedRunsResponse, error) {
	sent := request.GetRepositories()
	if len(sent) > maxWatchedRequest {
		return nil, status.Error(codes.InvalidArgument, "at most 1000 repositories")
	}
	repositories := make([]watch.Repository, len(sent))
	for i, r := range sent {
		repositories[i] = watch.Repository{ServerID: r.GetGithubServer(), Name: r.GetRepository(), WorkspaceIDs: r.GetWorkspaceIds()}
	}
	answers, pauses, err := s.watcher.List(ctx, repositories, request.GetRefresh())
	if err != nil {
		return nil, status.FromContextError(err).Err()
	}
	out := &corev1.ListWatchedRunsResponse{}
	for i, a := range answers {
		item := &corev1.WatchedRuns{Repository: sent[i], Status: statusMessage(a.Access, a.RetryAfter), Watched: a.Watched,
			Failed: runMessages(a.Failed), Running: runMessages(a.Running), ReadAt: timestamp(a.ReadAt)}
		withStarts(item.Failed, a.Starts)
		withStarts(item.Running, a.Starts)
		out.Repositories = append(out.Repositories, item)
	}
	for _, p := range pauses {
		out.Pauses = append(out.Pauses, &corev1.ServerPause{GithubServer: p.ServerID, Until: timestamppb.New(p.Until)})
	}
	return out, nil
}

func runMessages(runs []github.Run) []*corev1.WorkflowRun {
	out := make([]*corev1.WorkflowRun, len(runs))
	for i, r := range runs {
		out[i] = runMessage(r)
	}
	return out
}
