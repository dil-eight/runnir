package changes

import (
	"sort"
	"time"

	"runnir/core/internal/github"
)

var t0 = time.Date(2026, 10, 20, 10, 0, 0, 0, time.UTC)

func at(minute int) time.Time { return t0.Add(time.Duration(minute) * time.Minute) }

type option func(*github.Run)

// mk is a successful first attempt from o/r that took five minutes.
func mk(id, workflow int64, event, branch, sha string, minute int, options ...option) github.Run {
	r := github.Run{ID: id, WorkflowID: workflow, Name: "W", DisplayTitle: "Title", Event: event, Status: "completed",
		Conclusion: "success", Branch: branch, HeadSHA: sha, HeadRepository: "o/r", RunAttempt: 1,
		CreatedAt: at(minute), UpdatedAt: at(minute + 5)}
	for _, o := range options {
		o(&r)
	}
	return r
}

func lists(numbers ...int64) option      { return func(r *github.Run) { r.PullRequests = numbers } }
func fromRepository(name string) option  { return func(r *github.Run) { r.HeadRepository = name } }
func endsAt(minute int) option           { return func(r *github.Run) { r.UpdatedAt = at(minute) } }
func stillRunning() option               { return func(r *github.Run) { r.Status, r.Conclusion = "in_progress", "" } }
func concluded(conclusion string) option { return func(r *github.Run) { r.Conclusion = conclusion } }
func attempt(n int64) option             { return func(r *github.Run) { r.RunAttempt = n } }
func titled(title string) option         { return func(r *github.Run) { r.DisplayTitle = title } }

// newestFirst orders runs as the store returns them.
func newestFirst(runs ...github.Run) []github.Run {
	sort.SliceStable(runs, func(i, j int) bool {
		if runs[i].CreatedAt.Equal(runs[j].CreatedAt) {
			return runs[i].ID > runs[j].ID
		}
		return runs[i].CreatedAt.After(runs[j].CreatedAt)
	})
	return runs
}

// retryPR is #142: opened at minute 0 from retry, last pushed as c3,
// merged at minute 60 as m1.
func retryPR() github.RepositoryPullRequest {
	return github.RepositoryPullRequest{Number: 142, Title: "Add retry to deploy", State: "closed", Author: "octocat",
		HTMLURL: "https://github.com/o/r/pull/142", HeadRef: "retry", HeadSHA: "c3", HeadRepository: "o/r", BaseRef: "main",
		MergeCommitSHA: "m1", CreatedAt: at(0), UpdatedAt: at(60), ClosedAt: at(60), MergedAt: at(60)}
}

// example is the spec's example: CI on three pushes to #142, the merge,
// CI on the merge commit and Deploy started by hand on it. Run 1 is linked
// by its branch, run 2 by GitHub's list, run 3 by the pull request's head.
func example() Input {
	return Input{
		Runs: newestFirst(
			mk(1, 1, "pull_request", "retry", "c1", 1, endsAt(20)),
			mk(2, 1, "pull_request", "retry", "c2", 10, lists(142), endsAt(25)),
			mk(3, 1, "pull_request", "retry", "c3", 20),
			mk(4, 1, "push", "main", "m1", 61),
			mk(5, 2, "workflow_dispatch", "main", "m1", 70),
		),
		PullRequests:  []github.RepositoryPullRequest{retryPR()},
		DefaultBranch: "main", Repository: "o/r", RepositoryURL: "https://github.com/o/r", Now: at(100),
	}
}
