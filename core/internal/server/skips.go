package server

import (
	"context"
	"strconv"
	"strings"

	"runnir/core/internal/flow"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/workspace"
)

// explainSkips explains the jobs a run skipped. A finished attempt's
// reasons are kept with the run's file until the caller knows a later
// attempt; until then the run and its jobs are read on each request. When
// they cannot be read, the reasons told last for the attempt stand.
func (s *service) explainSkips(ctx context.Context, request *corev1.GetRunWorkflowRequest, target githubRepo, key workflowFileKey,
	file workflowFile, fresh bool) ([]*corev1.JobSkip, string) {
	kept, attempt := file.skips, request.GetRunAttempt()
	known := kept != nil && attempt > 0 && attempt <= kept.attempt
	if known && kept.final {
		return kept.skips, kept.note
	}
	last := func() ([]*corev1.JobSkip, string) {
		if known {
			return kept.skips, kept.note
		}
		return nil, ""
	}
	run := file.run
	if !fresh {
		read, err := target.account.Client.Run(ctx, target.owner, target.name, request.GetRunId())
		if err != nil {
			return last()
		}
		run = read
	}
	var rt *workspace.Runtime
	if request.GetGithubRepository() == "" {
		rt, _ = s.workspaces.ForRepository(request.GetRepositoryId())
	}
	var jobs []github.Job
	var err error
	if rt != nil {
		// The workspace's jobs, unless they were read before this attempt
		// or before the run finished: then once more from GitHub.
		var access corev1.GithubAccess
		jobs, access, _, err = rt.Jobs(ctx, request.GetRunId())
		if err == nil && access != corev1.GithubAccess_GITHUB_ACCESS_OK {
			return last()
		}
	}
	if rt == nil || err == nil && !jobsOf(run, jobs) {
		jobs, err = target.account.Client.Jobs(ctx, target.owner, target.name, request.GetRunId())
	}
	if err != nil {
		return last()
	}
	repository := strings.ToLower(target.owner + "/" + target.name)
	var defaultBranch string
	var pull *github.RepositoryPullRequest
	var refs func() (map[string]bool, map[string]bool)
	if rt != nil {
		if saved, err := rt.Saved(ctx); err == nil {
			defaultBranch = saved.DefaultBranch
			for i, p := range saved.PullRequests {
				if len(run.PullRequests) > 0 && p.Number == run.PullRequests[0] {
					pull = &saved.PullRequests[i]
				}
			}
		}
		if info, err := s.repositories.Get(request.GetRepositoryId()); err == nil {
			git := flow.Git{Path: s.git(), Root: info.Path}
			refs = func() (map[string]bool, map[string]bool) { return git.Tags(ctx), git.Branches(ctx) }
		}
	}
	runJobs := make([]flow.RunJob, 0, len(jobs))
	for _, j := range jobs {
		runJobs = append(runJobs, flow.RunJob{Name: j.Name, Result: runJobResult(j)})
	}
	var out []*corev1.JobSkip
	for _, skip := range flow.ExplainSkips(file.workflow, runFacts(run, repository, defaultBranch, pull, refs), runJobs) {
		out = append(out, skipMessage(skip))
	}
	note := flow.SourceNote(run.Event)
	if latest, ok := s.workflowFiles.get(key); ok {
		// A run that does not say is in its first attempt.
		latest.skips = &runSkips{attempt: max(run.RunAttempt, 1), final: run.Status == "completed" && jobsOf(run, jobs), skips: out, note: note}
		s.workflowFiles.put(key, latest)
	}
	return out, note
}

// runFacts is what a run tells its jobs' conditions: its event and refs,
// actor, repository and workflow; the pull request's base and draft when
// the workspace read it unchanged since the run; whether a pushed ref is a
// tag or a branch as the local repository knows it (refs is nil without one).
func runFacts(run github.Run, repository, defaultBranch string, pull *github.RepositoryPullRequest, refs func() (tags, branches map[string]bool)) flow.RunFacts {
	ctx := flow.Context{
		"github.event_name": run.Event, "github.actor": run.Actor, "github.workflow": run.Name,
		"github.run_attempt": strconv.FormatInt(run.RunAttempt, 10),
	}
	if repository != "" {
		ctx["github.repository"] = repository
		ctx["github.repository_owner"], _, _ = strings.Cut(repository, "/")
	}
	branchRef := func(name string) {
		ctx["github.ref"], ctx["github.ref_name"], ctx["github.ref_type"] = "refs/heads/"+name, name, "branch"
	}
	switch run.Event {
	case "pull_request", "pull_request_target":
		ctx["github.head_ref"] = run.Branch
		if len(run.PullRequests) > 0 {
			ctx["github.event.pull_request.number"] = float64(run.PullRequests[0])
		}
		// The pull request as the workspace read it is the one the run saw
		// only when it has not changed since: a draft can become ready, and
		// the base can change, with no new run.
		if pull != nil && (pull.UpdatedAt.IsZero() || pull.UpdatedAt.After(run.CreatedAt)) {
			pull = nil
		}
		if pull != nil {
			ctx["github.base_ref"] = pull.BaseRef
			ctx["github.event.pull_request.draft"] = pull.Draft
		}
		switch {
		case run.Event == "pull_request" && len(run.PullRequests) > 0:
			n := strconv.FormatInt(run.PullRequests[0], 10)
			ctx["github.ref"], ctx["github.ref_name"], ctx["github.ref_type"] = "refs/pull/"+n+"/merge", n+"/merge", "branch"
		case run.Event == "pull_request_target" && pull != nil:
			branchRef(pull.BaseRef)
		}
	default:
		ctx["github.head_ref"], ctx["github.base_ref"] = "", ""
		ctx["github.sha"] = run.HeadSHA
		switch {
		case run.Event == "schedule":
			branchRef(run.Branch)
		case run.Event == "workflow_run":
			ctx["github.event.workflow_run.head_branch"] = run.Branch
			if defaultBranch != "" {
				branchRef(defaultBranch)
			}
		case run.Branch != "":
			ctx["github.ref_name"] = run.Branch
			if refs != nil {
				tags, branches := refs()
				switch {
				case tags[run.Branch] && !branches[run.Branch]:
					ctx["github.ref"], ctx["github.ref_type"] = "refs/tags/"+run.Branch, "tag"
				case branches[run.Branch] && !tags[run.Branch]:
					branchRef(run.Branch)
				}
			}
		}
	}
	return flow.RunFacts{Context: ctx, Event: run.Event, Active: run.Status != "completed", Cancelled: run.Conclusion == "cancelled"}
}

// jobsOf: the jobs are of the run as read: the newest attempt among them is
// the run's (where GitHub says; a re-run of failed jobs keeps the jobs that
// passed with their earlier attempt), and all are finished when it is.
func jobsOf(run github.Run, jobs []github.Job) bool {
	var newest int64
	for _, j := range jobs {
		newest = max(newest, j.RunAttempt)
		if run.Status == "completed" && j.Status != "completed" {
			return false
		}
	}
	return newest == 0 || run.RunAttempt == 0 || newest == run.RunAttempt
}

// runJobResult is a job's result as needs.<id>.result names it; empty while
// it goes on.
func runJobResult(j github.Job) string {
	if j.Status != "completed" {
		return ""
	}
	switch j.Conclusion {
	case "failure", "timed_out", "startup_failure":
		return "failure"
	case "cancelled", "skipped":
		return j.Conclusion
	}
	return "success"
}

func skipMessage(s flow.Skip) *corev1.JobSkip {
	kinds := map[flow.SkipKind]corev1.SkipKind{
		flow.SkipNeeds: corev1.SkipKind_SKIP_KIND_NEEDS, flow.SkipConditionFalse: corev1.SkipKind_SKIP_KIND_CONDITION_FALSE,
		flow.SkipNotKnown: corev1.SkipKind_SKIP_KIND_NOT_KNOWN, flow.SkipNotInRun: corev1.SkipKind_SKIP_KIND_NOT_IN_RUN,
	}
	m := &corev1.JobSkip{JobId: s.JobID, Kind: kinds[s.Kind], Need: s.Need, NeedResult: s.NeedResult,
		Condition: s.Condition, Unknown: s.Unknown, Note: s.Note}
	for _, v := range s.Values {
		m.Values = append(m.Values, &corev1.ConditionValue{Name: v.Name, Value: v.Value})
	}
	return m
}
