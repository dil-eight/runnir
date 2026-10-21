package server

import (
	"context"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
)

const maxClosedLookback = 7 * 24 * time.Hour

// ListPullRequests lists the signed-in user's open pull requests on one
// server with their CI, and those closed recently.
func (s *service) ListPullRequests(ctx context.Context, request *corev1.ListPullRequestsRequest) (*corev1.ListPullRequestsResponse, error) {
	now := time.Now()
	since := now.Add(-24 * time.Hour)
	if request.GetClosedSince() != nil {
		since = request.GetClosedSince().AsTime()
	}
	if since.Before(now.Add(-maxClosedLookback)) {
		since = now.Add(-maxClosedLookback)
	}
	account, ok := s.accounts.Get(request.GetGithubServer())
	if !ok {
		return &corev1.ListPullRequestsResponse{Status: &corev1.GitHubStatus{Access: corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT}}, nil
	}
	pulls, fetchErr := account.Client.MyPullRequests(ctx, since)
	result, err := s.githubStatus(account, fetchErr)
	if err != nil {
		return nil, err
	}
	out := &corev1.ListPullRequestsResponse{Status: result, HeadsUnreadable: pulls.HeadsUnreadable}
	for _, pr := range pulls.Open {
		out.Open = append(out.Open, pullRequestMessage(pr))
	}
	for _, pr := range pulls.Closed {
		out.Closed = append(out.Closed, pullRequestMessage(pr))
	}
	return out, nil
}

func pullRequestMessage(pr github.PullRequest) *corev1.PullRequest {
	return &corev1.PullRequest{
		Repository: pr.Repository, Number: pr.Number, Title: pr.Title, HtmlUrl: pr.HTMLURL, State: pr.State, Draft: pr.Draft,
		HeadBranch: pr.HeadBranch, UpdatedAt: timestamp(pr.UpdatedAt), ClosedAt: timestamp(pr.ClosedAt), Ci: pullRequestCI(pr.CI),
		CiRuns: int32(pr.CIRuns), CiFailed: int32(pr.CIFailed), CiRunning: int32(pr.CIRunning), CiUrl: pr.CIURL,
	}
}

func pullRequestCI(state github.CIState) corev1.PullRequestCi {
	switch state {
	case github.CINone:
		return corev1.PullRequestCi_PULL_REQUEST_CI_NONE
	case github.CIRunning:
		return corev1.PullRequestCi_PULL_REQUEST_CI_RUNNING
	case github.CIPassed:
		return corev1.PullRequestCi_PULL_REQUEST_CI_PASSED
	case github.CIFailed:
		return corev1.PullRequestCi_PULL_REQUEST_CI_FAILED
	case github.CICancelled:
		return corev1.PullRequestCi_PULL_REQUEST_CI_CANCELLED
	default:
		return corev1.PullRequestCi_PULL_REQUEST_CI_UNKNOWN
	}
}
