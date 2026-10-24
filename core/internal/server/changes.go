package server

import (
	"context"
	"errors"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"runnir/core/internal/changes"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/scanner"
	"runnir/core/internal/workspace"
)

func linkMessage(link changes.Link) *corev1.RunLink {
	kind := corev1.RunLinkKind_RUN_LINK_KIND_NONE
	switch link.Kind {
	case changes.LinkPullRequest:
		kind = corev1.RunLinkKind_RUN_LINK_KIND_PULL_REQUEST
	case changes.LinkAfterMerge:
		kind = corev1.RunLinkKind_RUN_LINK_KIND_AFTER_MERGE
	}
	return &corev1.RunLink{Kind: kind, PullRequest: link.PullRequest}
}

func changeMessages(list []changes.Change) []*corev1.RunChange {
	out := make([]*corev1.RunChange, 0, len(list))
	for _, c := range list {
		message := &corev1.RunChange{Id: c.ID, Status: pullRequestCI(c.Status), LatestAt: timestamp(c.LatestAt),
			OlderRunIds: c.OlderRunIDs, OlderCommits: uint32(c.OlderCommits)}
		if p := c.PullRequest; p != nil {
			message.PullRequest = &corev1.ChangePullRequest{Number: p.Number, Title: p.Title, State: p.State, Draft: p.Draft,
				Author: p.Author, HtmlUrl: p.HTMLURL, HeadBranch: p.HeadBranch, BaseBranch: p.BaseBranch, MergedAt: timestamp(p.MergedAt)}
		}
		for _, s := range c.Sections {
			message.Sections = append(message.Sections, &corev1.RunChangeSection{Kind: sectionKind(s.Kind), HeadSha: s.HeadSHA,
				Branch: s.Branch, CommitTitle: s.CommitTitle, RunIds: s.RunIDs, RepeatRunIds: s.RepeatRunIDs})
		}
		out = append(out, message)
	}
	return out
}

func sectionKind(kind changes.SectionKind) corev1.RunChangeSectionKind {
	switch kind {
	case changes.SectionAfterMerge:
		return corev1.RunChangeSectionKind_RUN_CHANGE_SECTION_KIND_AFTER_MERGE
	case changes.SectionLatestCommit:
		return corev1.RunChangeSectionKind_RUN_CHANGE_SECTION_KIND_LATEST_COMMIT
	default:
		return corev1.RunChangeSectionKind_RUN_CHANGE_SECTION_KIND_COMMIT
	}
}

func hintMessages(hints []changes.Hint) []*corev1.ConcurrencyHint {
	out := make([]*corev1.ConcurrencyHint, 0, len(hints))
	for _, h := range hints {
		out = append(out, &corev1.ConcurrencyHint{WorkflowId: h.WorkflowID, Path: h.Path, Runs: uint32(h.Runs),
			OverlapMinutes: uint32(h.OverlapMinutes), RunIds: h.RunIDs, PullRequests: h.PullRequests})
	}
	return out
}

// localWorkflows are the working tree's workflow files as last scanned;
// none when the repository is not open.
func (s *service) localWorkflows(repositoryID string) []changes.LocalWorkflow {
	workflows, err := s.repositories.Workflows(repositoryID)
	if err != nil {
		return nil
	}
	out := make([]changes.LocalWorkflow, 0, len(workflows))
	for _, w := range workflows {
		out = append(out, changes.LocalWorkflow{Path: w.ID, Triggers: w.Triggers, Concurrency: w.Concurrency, ParseError: w.ParseError})
	}
	return out
}

func (s *service) LoadOlderRuns(ctx context.Context, request *corev1.LoadOlderRunsRequest) (*corev1.LoadOlderRunsResponse, error) {
	rt, err := s.runtimeFor(request.GetRepositoryId())
	if err != nil {
		return nil, err
	}
	result, err := rt.LoadOlderRuns(ctx)
	switch {
	case errors.Is(err, workspace.ErrClosed):
		return nil, status.Error(codes.NotFound, "repository not found")
	case ctx.Err() != nil:
		return nil, status.FromContextError(ctx.Err()).Err()
	case err != nil:
		return nil, status.Error(codes.Internal, "older runs could not be stored")
	}
	return &corev1.LoadOlderRunsResponse{Status: statusMessage(result.Access, result.RetryAfter), Added: uint32(result.Added),
		HistoryComplete: result.HistoryComplete, BudgetReached: result.BudgetReached}, nil
}

func (s *service) InsertWorkflowConcurrency(_ context.Context, request *corev1.InsertWorkflowConcurrencyRequest) (*corev1.InsertWorkflowConcurrencyResponse, error) {
	if _, err := s.repositories.Get(request.GetRepositoryId()); err != nil {
		return nil, rpcError(err)
	}
	edit := scanner.InsertConcurrency(request.GetContent())
	out := &corev1.InsertWorkflowConcurrencyResponse{Refusal: concurrencyRefusal(edit.Refusal)}
	if edit.Refusal == scanner.ConcurrencyInserted {
		out.Content, out.FirstLine, out.LastLine = edit.Content, uint32(edit.FirstLine), uint32(edit.LastLine)
	}
	return out, nil
}

func concurrencyRefusal(refusal scanner.ConcurrencyRefusal) corev1.ConcurrencyRefusal {
	switch refusal {
	case scanner.ConcurrencyAlreadyPresent:
		return corev1.ConcurrencyRefusal_CONCURRENCY_REFUSAL_ALREADY_PRESENT
	case scanner.ConcurrencyNoJobs:
		return corev1.ConcurrencyRefusal_CONCURRENCY_REFUSAL_NO_JOBS
	case scanner.ConcurrencyNotBlockMapping:
		return corev1.ConcurrencyRefusal_CONCURRENCY_REFUSAL_NOT_BLOCK_MAPPING
	case scanner.ConcurrencyParseError:
		return corev1.ConcurrencyRefusal_CONCURRENCY_REFUSAL_PARSE_ERROR
	case scanner.ConcurrencyTooLarge:
		return corev1.ConcurrencyRefusal_CONCURRENCY_REFUSAL_TOO_LARGE
	default:
		return corev1.ConcurrencyRefusal_CONCURRENCY_REFUSAL_NONE
	}
}
