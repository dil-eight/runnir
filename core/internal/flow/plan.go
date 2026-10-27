package flow

import (
	"sort"
	"strings"
)

// Kind is what happens to the change in a scenario.
type Kind int

const (
	PullRequest Kind = iota + 1
	Push
	Merge
	Tag
	Manual
	Schedule
)

// Scenario is an event that happens to the current branch's change, with
// its target: the base of a pull request, the branch pushed or merged into,
// the tag; empty for a manual start (on the current branch) and the schedule.
type Scenario struct {
	Kind   Kind
	Target string
}

// Title is how the picker names the scenario.
func (s Scenario) Title() string {
	switch s.Kind {
	case PullRequest:
		return "Pull request → " + s.Target
	case Push:
		return "Push to " + s.Target
	case Merge:
		return "Merge into " + s.Target
	case Tag:
		return "Tag " + s.Target
	case Manual:
		return "Manual start"
	case Schedule:
		return "Schedule"
	}
	return ""
}

// Repo is what the planner knows of the working tree besides its files.
type Repo struct {
	CurrentBranch string
	DefaultBranch string
	// PullRequestBase is the base of the current branch's open pull request;
	// empty without one.
	PullRequestBase string
}

// Scenarios lists what can happen to the current branch's change, given the
// events the workflows react to. The first one is the default.
func Scenarios(workflows []Workflow, repo Repo) []Scenario {
	has := func(names ...string) bool {
		for _, w := range workflows {
			for _, name := range names {
				if _, ok := w.Events[name]; ok {
					return true
				}
			}
		}
		return false
	}
	var out []Scenario
	add := func(s Scenario) {
		for _, known := range out {
			if known == s {
				return
			}
		}
		out = append(out, s)
	}
	// Bases and merge targets: branches the workflows name exactly, the most
	// named first, then the default branch, then patterns.
	targets := func(events ...string) []string {
		count := map[string]int{}
		var patterns []string
		for _, w := range workflows {
			for _, name := range events {
				e, ok := w.Events[name]
				if !ok {
					continue
				}
				for _, b := range e.Branches {
					if literalName(b) {
						count[b]++
					} else if !strings.HasPrefix(b, "!") && !contains(patterns, b) {
						patterns = append(patterns, b)
					}
				}
			}
		}
		names := make([]string, 0, len(count))
		for name := range count {
			names = append(names, name)
		}
		sort.Slice(names, func(i, j int) bool {
			if count[names[i]] != count[names[j]] {
				return count[names[i]] > count[names[j]]
			}
			return names[i] < names[j]
		})
		if repo.DefaultBranch != "" && !contains(names, repo.DefaultBranch) {
			names = append(names, repo.DefaultBranch)
		}
		return append(names, patterns...)
	}
	pullRequests := has("pull_request", "pull_request_target")
	pushes := has("push")
	// The default comes first: the open pull request's base, a push on the
	// default branch, else a pull request into the default branch.
	switch {
	case pullRequests && repo.PullRequestBase != "":
		add(Scenario{PullRequest, repo.PullRequestBase})
	case pushes && repo.CurrentBranch != "" && repo.CurrentBranch == repo.DefaultBranch:
		add(Scenario{Push, repo.CurrentBranch})
	case pullRequests && repo.DefaultBranch != "":
		add(Scenario{PullRequest, repo.DefaultBranch})
	}
	if pullRequests {
		for _, base := range targets("pull_request", "pull_request_target") {
			if base != repo.CurrentBranch {
				add(Scenario{PullRequest, base})
			}
		}
	}
	if pushes && repo.CurrentBranch != "" {
		add(Scenario{Push, repo.CurrentBranch})
	}
	if pushes {
		for _, into := range targets("push") {
			if into != repo.CurrentBranch {
				add(Scenario{Merge, into})
			}
		}
	}
	if tag := tagTarget(workflows); tag != "" {
		add(Scenario{Tag, tag})
	}
	if has("workflow_dispatch") {
		add(Scenario{Manual, ""})
	}
	if has("schedule") {
		add(Scenario{Schedule, ""})
	}
	return out
}

// tagTarget is the tag a Tag scenario stands for: the first tag pattern a
// push names, or "release" when only releases start workflows.
func tagTarget(workflows []Workflow) string {
	release := false
	for _, w := range workflows {
		if e, ok := w.Events["push"]; ok && len(e.Tags) > 0 {
			for _, t := range e.Tags {
				if !strings.HasPrefix(t, "!") {
					return t
				}
			}
		}
		_, has := w.Events["release"]
		release = release || has
	}
	if release {
		return "release"
	}
	return ""
}

// Changes are the files the change touches, for paths filters.
type Changes struct {
	Files []string
	// Known: git said which files changed. Without it paths filters are unknown.
	Known bool
	// Against is what the files were compared with: "origin/main".
	Against string
	// Note says why the files are not known.
	Note string
}

// LaneKind says why a workflow is in the scenario.
type LaneKind int

const (
	// Direct: the scenario's event starts it.
	Direct LaneKind = iota + 1
	// Chained: workflow_run starts it after another lane.
	Chained
	// ByHand: it starts only by hand, outside the scenario.
	ByHand
)

// PlannedJob is a job of a lane.
type PlannedJob struct {
	Job
	// Column is the job's depth by needs.
	Column int
	// Condition is the if it depends on, when the scenario cannot tell.
	Condition string
	// Skipped says why the job does not run in the scenario; empty when it runs.
	Skipped string
}

// Lane is one workflow of the scenario.
type Lane struct {
	Path, Name string
	Kind       LaneKind
	// After names the lane a chained lane follows.
	After string
	// AfterPath is that lane's file.
	AfterPath string
	// Why says what starts it: "pull_request · branches main · paths ✓".
	Why        string
	Jobs       []PlannedJob
	ParseError string
}

// SkippedWorkflow is a workflow the scenario does not start, with the reason.
type SkippedWorkflow struct {
	Path, Name, Reason string
}

// Flow is the plan of one scenario.
type Flow struct {
	Scenario Scenario
	Changes  Changes
	// PathsApply: the scenario's event reads paths filters (a tag, a manual
	// start and the schedule do not).
	PathsApply bool
	Lanes      []Lane
	Skipped    []SkippedWorkflow
}

// Plan works out what the scenario starts.
func Plan(s Scenario, workflows []Workflow, repo Repo, changes Changes) Flow {
	f := Flow{Scenario: s, Changes: changes, PathsApply: s.Kind == PullRequest || s.Kind == Push || s.Kind == Merge}
	in := map[string]bool{}
	var direct []Lane
	for _, w := range workflows {
		if w.ParseError != "" && len(w.Events) == 0 {
			f.Skipped = append(f.Skipped, SkippedWorkflow{w.Path, w.Name, "does not parse: " + w.ParseError})
			continue
		}
		lane, reason := match(s, w, repo, changes)
		if reason == "" {
			lane.Jobs = plannedJobs(w, runContext(s, repo, lane.Why, false))
			direct = append(direct, lane)
			in[w.Path] = true
		}
	}
	// Chained lanes go right after the lane they follow, their own chains after them.
	var lanes []Lane
	var chain func(source Lane, branch string)
	chain = func(source Lane, branch string) {
		for _, w := range workflows {
			if in[w.Path] {
				continue
			}
			e, ok := w.Events["workflow_run"]
			if !ok || !contains(e.Workflows, source.Name) || !completes(e.Types) {
				continue
			}
			if ok, _, _ := refFilter(e.Branches, e.BranchesIgnore, branch, "branch"); !ok {
				continue
			}
			lane := Lane{Path: w.Path, Name: w.Name, Kind: Chained, After: source.Name, AfterPath: source.Path, Why: "workflow_run", ParseError: w.ParseError}
			lane.Jobs = plannedJobs(w, runContext(s, repo, "workflow_run", true))
			in[w.Path] = true
			lanes = append(lanes, lane)
			chain(lane, branch)
		}
	}
	for _, lane := range direct {
		lanes = append(lanes, lane)
		chain(lane, refName(s, repo))
	}
	// Workflows started only by hand close every scenario but the manual one,
	// where they are direct lanes already.
	for _, w := range workflows {
		if in[w.Path] || !w.OnlyDispatch() || s.Kind == Manual {
			continue
		}
		lane := Lane{Path: w.Path, Name: w.Name, Kind: ByHand, Why: "workflow_dispatch", ParseError: w.ParseError}
		lane.Jobs = plannedJobs(w, runContext(Scenario{Manual, ""}, repo, "workflow_dispatch", false))
		in[w.Path] = true
		lanes = append(lanes, lane)
	}
	f.Lanes = lanes
	for _, w := range workflows {
		if in[w.Path] || (w.ParseError != "" && len(w.Events) == 0) {
			continue
		}
		_, reason := match(s, w, repo, changes)
		if reason == "" {
			// It matched but sits behind a chain: it is in.
			continue
		}
		if e, ok := w.Events["workflow_run"]; ok && len(w.Events) == 1 {
			reason = "after " + strings.Join(e.Workflows, ", ") + ", which " + plural(len(e.Workflows), "is", "are") + " not in this scenario"
		}
		f.Skipped = append(f.Skipped, SkippedWorkflow{w.Path, w.Name, reason})
	}
	return f
}

// match says whether the scenario's event starts the workflow, and why not.
func match(s Scenario, w Workflow, repo Repo, changes Changes) (Lane, string) {
	lane := Lane{Path: w.Path, Name: w.Name, Kind: Direct, ParseError: w.ParseError}
	switch s.Kind {
	case Manual:
		if _, ok := w.Events["workflow_dispatch"]; ok {
			lane.Why = "workflow_dispatch"
			return lane, ""
		}
	case Schedule:
		if _, ok := w.Events["schedule"]; ok {
			lane.Why = "schedule"
			return lane, ""
		}
	case PullRequest:
		var firstReason string
		for _, name := range []string{"pull_request", "pull_request_target"} {
			e, ok := w.Events[name]
			if !ok {
				continue
			}
			why, reason := checkEvent(name, e, s.Target, "branch", true, changes)
			if reason == "" {
				if blocked := pullRequestTypes(e.Types); blocked != "" {
					reason = blocked
				}
			}
			if reason == "" {
				lane.Why = why
				return lane, ""
			}
			if firstReason == "" {
				firstReason = reason
			}
		}
		if firstReason != "" {
			return lane, firstReason
		}
	case Push, Merge:
		if e, ok := w.Events["push"]; ok {
			if (len(e.Tags) > 0 || len(e.TagsIgnore) > 0) && len(e.Branches) == 0 && len(e.BranchesIgnore) == 0 {
				return lane, "runs on tag pushes"
			}
			why, reason := checkEvent("push", e, s.Target, "branch", true, changes)
			if reason == "" {
				lane.Why = why
				return lane, ""
			}
			return lane, reason
		}
	case Tag:
		if e, ok := w.Events["push"]; ok && (len(e.Tags) > 0 || len(e.TagsIgnore) > 0) {
			if ok, decided, reason := refFilter(e.Tags, e.TagsIgnore, s.Target, "tag"); ok {
				lane.Why = joinWhy("push", tagsWhy(decided))
				return lane, ""
			} else {
				return lane, reason
			}
		}
		if _, ok := w.Events["release"]; ok {
			lane.Why = "release"
			return lane, ""
		}
	}
	return lane, runsOn(w)
}

// checkEvent applies an event's ref and paths filters.
func checkEvent(name string, e Event, ref, noun string, paths bool, changes Changes) (why, reason string) {
	ok, decided, reason := refFilter(e.Branches, e.BranchesIgnore, ref, noun)
	if !ok {
		return "", reason
	}
	parts := []string{name}
	if decided != "" {
		parts = append(parts, "branches "+decided)
	}
	if paths && (len(e.Paths) > 0 || len(e.PathsIgnore) > 0) {
		if !changes.Known {
			parts = append(parts, "paths unknown")
		} else if ok, reason := pathFilter(e.Paths, e.PathsIgnore, changes.Files); !ok {
			return "", reason
		} else {
			parts = append(parts, "paths ✓")
		}
	}
	return joinWhy(parts...), ""
}

func tagsWhy(decided string) string {
	if decided == "" {
		return ""
	}
	return "tags " + decided
}

func joinWhy(parts ...string) string {
	var kept []string
	for _, p := range parts {
		if p != "" {
			kept = append(kept, p)
		}
	}
	return strings.Join(kept, " · ")
}

// pullRequestTypes: a pull_request with types that leave out an update of
// the pull request (opened, synchronize, reopened) does not run on a push to it.
func pullRequestTypes(types []string) string {
	if len(types) == 0 {
		return ""
	}
	for _, t := range types {
		if t == "opened" || t == "synchronize" || t == "reopened" {
			return ""
		}
	}
	return "types: " + strings.Join(types, ", ")
}

// completes: workflow_run starts when the source completes, by default too.
func completes(types []string) bool {
	return len(types) == 0 || contains(types, "completed")
}

// runsOn says what does start a workflow the scenario does not.
func runsOn(w Workflow) string {
	if w.OnlyDispatch() {
		return "started by hand"
	}
	names := make([]string, 0, len(w.Events))
	for name := range w.Events {
		names = append(names, name)
	}
	sort.Strings(names)
	if len(names) == 1 && names[0] == "schedule" {
		return "runs on schedule"
	}
	if len(names) == 0 {
		return "has no trigger"
	}
	return "runs on " + strings.Join(names, ", ")
}

// refName is the branch or tag the scenario's runs are on.
func refName(s Scenario, repo Repo) string {
	switch s.Kind {
	case PullRequest, Push, Manual:
		return repo.CurrentBranch
	case Schedule:
		return repo.DefaultBranch
	}
	return s.Target
}

// runContext is the github context a scenario's run of a workflow sees.
func runContext(s Scenario, repo Repo, why string, chained bool) Context {
	ctx := Context{}
	event := strings.SplitN(why, " ", 2)[0]
	switch {
	case chained:
		ctx["github.event_name"] = "workflow_run"
		ctx["github.event.workflow_run.conclusion"] = "success"
	case event != "":
		ctx["github.event_name"] = event
	}
	switch s.Kind {
	case PullRequest:
		ctx["github.ref"] = "refs/pull/0/merge"
		ctx["github.ref_name"] = "0/merge"
		ctx["github.ref_type"] = "branch"
		ctx["github.base_ref"] = s.Target
		ctx["github.head_ref"] = repo.CurrentBranch
		ctx["github.event.pull_request.draft"] = false
	case Tag:
		ctx["github.ref"] = "refs/tags/" + s.Target
		ctx["github.ref_name"] = s.Target
		ctx["github.ref_type"] = "tag"
		ctx["github.base_ref"] = ""
		ctx["github.head_ref"] = ""
	default:
		branch := refName(s, repo)
		ctx["github.ref"] = "refs/heads/" + branch
		ctx["github.ref_name"] = branch
		ctx["github.ref_type"] = "branch"
		ctx["github.base_ref"] = ""
		ctx["github.head_ref"] = ""
	}
	return ctx
}

// plannedJobs lays out a workflow's jobs in columns by needs and reads their
// conditions: a false one skips the job and the jobs that need it.
func plannedJobs(w Workflow, ctx Context) []PlannedJob {
	byID := map[string]Job{}
	for _, j := range w.Jobs {
		byID[j.ID] = j
	}
	depth := map[string]int{}
	var level func(id string, visiting map[string]bool) int
	level = func(id string, visiting map[string]bool) int {
		if d, ok := depth[id]; ok {
			return d
		}
		job, ok := byID[id]
		if !ok || visiting[id] {
			return 0
		}
		visiting[id] = true
		d := 0
		for _, need := range job.Needs {
			if _, ok := byID[need]; ok {
				d = max(d, level(need, visiting)+1)
			}
		}
		delete(visiting, id)
		depth[id] = d
		return d
	}
	out := make([]PlannedJob, 0, len(w.Jobs))
	skipped := map[string]string{}
	// Jobs in order of depth, so a need is decided before the job that needs it.
	ordered := append([]Job(nil), w.Jobs...)
	for _, j := range ordered {
		level(j.ID, map[string]bool{})
	}
	sort.SliceStable(ordered, func(i, k int) bool { return depth[ordered[i].ID] < depth[ordered[k].ID] })
	planned := map[string]PlannedJob{}
	for _, j := range ordered {
		p := PlannedJob{Job: j, Column: depth[j.ID]}
		for _, need := range j.Needs {
			if _, ok := skipped[need]; ok && !alwaysRuns(j.If) {
				p.Skipped = "needs " + need + ", which does not run"
				break
			}
		}
		if p.Skipped == "" && j.If != "" {
			switch Evaluate(j.If, ctx) {
			case False:
				p.Skipped = "if: " + j.If
			case Unknown:
				p.Condition = j.If
			}
		}
		if p.Skipped != "" {
			skipped[j.ID] = p.Skipped
		}
		planned[j.ID] = p
	}
	for _, j := range w.Jobs {
		out = append(out, planned[j.ID])
	}
	return out
}

// alwaysRuns: a condition with always() runs also when a need did not.
func alwaysRuns(condition string) bool {
	return strings.Contains(strings.ToLower(condition), "always()")
}

func contains(list []string, value string) bool {
	for _, item := range list {
		if item == value {
			return true
		}
	}
	return false
}

func plural(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}
