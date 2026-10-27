package server

import (
	"context"
	"os"
	"strings"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"runnir/core/internal/flow"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
	"runnir/core/internal/tools"
)

func (s *service) GetFlow(ctx context.Context, request *corev1.GetFlowRequest) (*corev1.GetFlowResponse, error) {
	info, err := s.repositories.Get(request.GetRepositoryId())
	if err != nil {
		return nil, rpcError(err)
	}
	workflows, err := flow.ReadWorkflows(info.Path)
	if err != nil {
		return nil, status.Error(codes.PermissionDenied, "the workflow files could not be read")
	}
	repo := flow.Repo{CurrentBranch: info.Branch}
	var saved store.Activity
	if rt, ok := s.workspaces.ForRepository(request.GetRepositoryId()); ok {
		if a, err := rt.Saved(ctx); err == nil {
			saved = a
		}
	}
	repo.DefaultBranch = saved.DefaultBranch
	if repo.DefaultBranch == "" {
		repo.DefaultBranch = "main"
	}
	git := flow.Git{Path: s.git(), Root: info.Path}
	head := git.Head(ctx)
	// The branch's pull request, and where its head comes from: the
	// repository itself or the user's fork.
	headRepository := saved.Source.Repository
	if p, ok := branchPullRequest(saved.PullRequests, repo.CurrentBranch, saved.Source.Repository, head, git.UpstreamHead(ctx)); ok {
		repo.PullRequestBase = p.BaseRef
		if p.HeadRepository != "" {
			headRepository = p.HeadRepository
		}
	}
	scenarios := flow.Scenarios(workflows, repo)
	out := &corev1.GetFlowResponse{}
	for _, sc := range scenarios {
		out.Scenarios = append(out.Scenarios, scenarioMessage(sc))
	}
	chosen, ok := scenarioOf(request.GetScenario())
	if !ok {
		if len(scenarios) == 0 {
			return out, nil
		}
		chosen = scenarios[0]
	}
	changes := git.ChangesFor(ctx, chosen, repo)
	plan := flow.Plan(chosen, workflows, repo, changes)
	match := laneRuns{scenario: chosen, repo: repo, headRepository: headRepository}
	if chosen.Kind == flow.Tag {
		match.tags = git.Tags(ctx)
	}
	byPath := map[string]flow.Workflow{}
	for _, w := range workflows {
		byPath[w.Path] = w
	}
	out.Scenario = scenarioMessage(chosen)
	out.Changes = &corev1.FlowChanges{
		Applies: plan.PathsApply, Known: changes.Known, Count: uint32(len(changes.Files)), Against: changes.Against, Note: changes.Note,
	}
	ids := map[string]int64{}
	for _, w := range saved.Workflows {
		ids[w.Path] = w.ID
	}
	for _, lane := range plan.Lanes {
		message := &corev1.FlowLane{
			WorkflowPath: lane.Path, WorkflowName: lane.Name, Kind: laneKindMessage(lane.Kind), After: lane.After, AfterPath: lane.AfterPath,
			Why: lane.Why, ParseError: lane.ParseError,
		}
		for _, j := range lane.Jobs {
			message.Jobs = append(message.Jobs, &corev1.FlowJob{
				Id: j.ID, Name: j.Name, Needs: j.Needs, Column: int32(j.Column), Matrix: int32(j.Matrix), Environment: j.Environment,
				Condition: j.Condition, Skipped: j.Skipped, Manual: j.Manual, ManualInputs: j.ManualInputs, Uses: j.Uses,
			})
		}
		if id, ok := ids[lane.Path]; ok {
			if run, ok := match.newest(lane.Kind, byPath[lane.Path].PushesTagsOnly(), id, saved.Runs); ok {
				message.Run = runMessage(run)
				if ownChange(chosen, lane.Kind) && head != "" && run.HeadSHA != "" && run.HeadSHA != head {
					message.StatusesFrom = shortSHA(run.HeadSHA)
				}
			}
		}
		out.Lanes = append(out.Lanes, message)
	}
	for _, skipped := range plan.Skipped {
		out.Skipped = append(out.Skipped, &corev1.SkippedWorkflow{WorkflowPath: skipped.Path, WorkflowName: skipped.Name, Reason: skipped.Reason})
	}
	return out, nil
}

// git finds the git binary once; scenarios work without it, with paths
// filters unknown.
func (s *service) git() string {
	s.gitOnce.Do(func() { s.gitPath = flow.FindGit(tools.SearchDirs(s.home, os.Getenv("PATH"))) })
	return s.gitPath
}

// branchPullRequest is the current branch's open pull request: the one whose
// head is the commit checked out or last pushed, from the repository itself
// or the user's fork; else one from the repository itself. A fork's pull
// request from a branch of the same name with another head is someone else's.
func branchPullRequest(pulls []github.RepositoryPullRequest, branch, repository string, commits ...string) (github.RepositoryPullRequest, bool) {
	var own *github.RepositoryPullRequest
	for i, p := range pulls {
		if p.State != "open" || branch == "" || p.HeadRef != branch {
			continue
		}
		for _, c := range commits {
			if c != "" && p.HeadSHA == c {
				return p, true
			}
		}
		if own == nil && !github.OtherRepository(p.HeadRepository, repository) {
			own = &pulls[i]
		}
	}
	if own != nil {
		return *own, true
	}
	return github.RepositoryPullRequest{}, false
}

// laneRuns tells a lane's runs apart from the other runs of its workflow.
type laneRuns struct {
	scenario flow.Scenario
	repo     flow.Repo
	// headRepository is where the branch's pull request comes from; runs
	// of another fork's branch of the same name are someone else's.
	headRepository string
	// tags are the local tags, read for a Tag scenario: GitHub names a push
	// run by its ref only, so a run on a ref of the tag's pattern is a tag's
	// when the tag is known here, or when the workflow pushes only tags. The
	// runs of a tag not fetched yet are left out.
	tags map[string]bool
}

// newest is the newest saved run of a lane's workflow that belongs to the
// scenario: on the branch's pull request, a push to the branch or the target,
// a tag, a manual start on the branch, the schedule; workflow_run for a chain.
// The runs are newest first.
func (m laneRuns) newest(kind flow.LaneKind, tagsOnly bool, workflowID int64, runs []github.Run) (github.Run, bool) {
	belongs := func(r github.Run) bool {
		switch kind {
		case flow.Chained:
			return r.Event == "workflow_run"
		case flow.ByHand:
			return r.Event == "workflow_dispatch" && r.Branch == m.repo.CurrentBranch
		}
		switch m.scenario.Kind {
		case flow.PullRequest:
			return (r.Event == "pull_request" || r.Event == "pull_request_target") && r.Branch == m.repo.CurrentBranch &&
				!github.OtherRepository(r.HeadRepository, m.headRepository)
		case flow.Push:
			return r.Event == "push" && r.Branch == m.repo.CurrentBranch
		case flow.Merge:
			return r.Event == "push" && r.Branch == m.scenario.Target
		case flow.Tag:
			return r.Event == "release" || r.Event == "push" && flow.MatchesTag(m.scenario.Target, r.Branch) && (tagsOnly || m.tags[r.Branch])
		case flow.Manual:
			return r.Event == "workflow_dispatch" && r.Branch == m.repo.CurrentBranch
		case flow.Schedule:
			return r.Event == "schedule"
		}
		return false
	}
	for _, r := range runs {
		if r.WorkflowID == workflowID && belongs(r) {
			return r, true
		}
	}
	return github.Run{}, false
}

// ownChange: the lane's run is of the commit checked out here, so another
// commit's statuses are worth a word.
func ownChange(sc flow.Scenario, kind flow.LaneKind) bool {
	return kind != flow.ByHand && (sc.Kind == flow.PullRequest || sc.Kind == flow.Push)
}

func shortSHA(sha string) string {
	if len(sha) > 7 {
		return sha[:7]
	}
	return sha
}

func scenarioMessage(sc flow.Scenario) *corev1.Scenario {
	kinds := map[flow.Kind]corev1.ScenarioKind{
		flow.PullRequest: corev1.ScenarioKind_SCENARIO_KIND_PULL_REQUEST, flow.Push: corev1.ScenarioKind_SCENARIO_KIND_PUSH,
		flow.Merge: corev1.ScenarioKind_SCENARIO_KIND_MERGE, flow.Tag: corev1.ScenarioKind_SCENARIO_KIND_TAG,
		flow.Manual: corev1.ScenarioKind_SCENARIO_KIND_MANUAL, flow.Schedule: corev1.ScenarioKind_SCENARIO_KIND_SCHEDULE,
	}
	return &corev1.Scenario{Kind: kinds[sc.Kind], Target: sc.Target, Title: sc.Title()}
}

func scenarioOf(m *corev1.Scenario) (flow.Scenario, bool) {
	kinds := map[corev1.ScenarioKind]flow.Kind{
		corev1.ScenarioKind_SCENARIO_KIND_PULL_REQUEST: flow.PullRequest, corev1.ScenarioKind_SCENARIO_KIND_PUSH: flow.Push,
		corev1.ScenarioKind_SCENARIO_KIND_MERGE: flow.Merge, corev1.ScenarioKind_SCENARIO_KIND_TAG: flow.Tag,
		corev1.ScenarioKind_SCENARIO_KIND_MANUAL: flow.Manual, corev1.ScenarioKind_SCENARIO_KIND_SCHEDULE: flow.Schedule,
	}
	kind, ok := kinds[m.GetKind()]
	if !ok {
		return flow.Scenario{}, false
	}
	target := strings.TrimSpace(m.GetTarget())
	if target == "" && kind != flow.Manual && kind != flow.Schedule {
		return flow.Scenario{}, false
	}
	return flow.Scenario{Kind: kind, Target: target}, true
}

func laneKindMessage(kind flow.LaneKind) corev1.LaneKind {
	switch kind {
	case flow.Chained:
		return corev1.LaneKind_LANE_KIND_CHAINED
	case flow.ByHand:
		return corev1.LaneKind_LANE_KIND_BY_HAND
	default:
		return corev1.LaneKind_LANE_KIND_DIRECT
	}
}
