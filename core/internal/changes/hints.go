package changes

import (
	"math"

	"runnir/core/internal/github"
)

// MinOverlappingRuns is how many superseded runs of a workflow must have
// kept going before a hint shows.
const MinOverlappingRuns = 2

// LocalWorkflow is a workflow file in the working tree as the scanner read it.
type LocalWorkflow struct {
	Path        string
	Triggers    []string
	Concurrency bool
	ParseError  string
}

// Hint suggests a concurrency block for one workflow.
type Hint struct {
	WorkflowID     int64
	Path           string
	Runs           int
	OverlapMinutes int
	RunIDs         []int64
	PullRequests   []int64
}

// Hints suggest a concurrency block where superseded runs kept going and the
// working tree's file has none, is readable and runs on pull requests or pushes.
func Hints(a Analysis, remote []github.Workflow, local []LocalWorkflow) []Hint {
	files := make(map[string]LocalWorkflow, len(local))
	for _, w := range local {
		files[w.Path] = w
	}
	var out []Hint
	for _, w := range remote {
		o, ok := a.Overlaps[w.ID]
		if !ok || len(o.RunIDs) < MinOverlappingRuns {
			continue
		}
		file, ok := files[w.Path]
		if !ok || file.ParseError != "" || file.Concurrency || !runsOnChanges(file.Triggers) {
			continue
		}
		out = append(out, Hint{WorkflowID: w.ID, Path: w.Path, Runs: len(o.RunIDs),
			OverlapMinutes: int(math.Ceil(o.Duration.Minutes())), RunIDs: o.RunIDs, PullRequests: o.PullRequests})
	}
	return out
}

func runsOnChanges(triggers []string) bool {
	for _, t := range triggers {
		if t == "pull_request" || t == "push" {
			return true
		}
	}
	return false
}
