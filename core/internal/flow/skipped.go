package flow

import "strings"

// RunJob is a job GitHub ran in a run, by its name, with its result:
// success, failure, cancelled or skipped; empty while it goes on.
type RunJob struct{ Name, Result string }

// RunFacts is what a run tells its jobs' conditions.
type RunFacts struct {
	// Context holds the github.* values the run gives.
	Context Context
	// Event is the run's event, for which file GitHub ran.
	Event string
	// Active: the run goes on, so a job without a run job is still to come.
	Active bool
	// Cancelled: the run was cancelled, for cancelled().
	Cancelled bool
}

// SkipKind says why a job of the file did not run.
type SkipKind int

const (
	// SkipNeeds: a job it needs did not succeed and its if checks no status.
	SkipNeeds SkipKind = iota + 1
	// SkipConditionFalse: its if is false for the run.
	SkipConditionFalse
	// SkipNotKnown: its if reads what Runnir does not know, or reads true
	// although GitHub skipped the job.
	SkipNotKnown
	// SkipNotInRun: the finished run has no job for it.
	SkipNotInRun
)

// Skip explains one job of the file that did not run.
type Skip struct {
	JobID string
	Kind  SkipKind
	// Need is the job it needs that did not succeed, with that job's result.
	Need, NeedResult string
	Condition        string
	// Values are what the condition read of the run; Unknown what it reads
	// that Runnir does not know.
	Values  []Value
	Unknown []string
	Note    string
}

const differs = "the file at this commit may differ from the one GitHub ran."

// ExplainSkips says why each job of the workflow GitHub skipped in the run
// was skipped, and which jobs a finished run has no job for, in the file's
// order. Jobs that ran, or are still to come, are left out.
func ExplainSkips(w Workflow, facts RunFacts, jobs []RunJob) []Skip {
	results := map[string]string{}
	ran := map[string]bool{}
	for _, j := range w.Jobs {
		matched := matchRunJobs(j, jobs, w.Jobs)
		ran[j.ID] = len(matched) > 0
		results[j.ID] = combined(matched)
	}
	var out []Skip
	for _, j := range w.Jobs {
		switch {
		case !ran[j.ID] && !facts.Active:
			out = append(out, Skip{JobID: j.ID, Kind: SkipNotInRun, Note: notInRunNote(facts.Event)})
		case ran[j.ID] && results[j.ID] == "skipped":
			out = append(out, explain(j, w, facts, results))
		}
	}
	return out
}

func explain(j Job, w Workflow, facts RunFacts, results map[string]string) Skip {
	skip := Skip{JobID: j.ID, Condition: j.If}
	// Without a status function GitHub adds success(): every need succeeded.
	if !statusCheck(j.If) {
		for _, need := range j.Needs {
			if r, ok := results[need]; ok && r != "success" {
				if r == "" {
					r = "skipped"
				}
				skip.Kind, skip.Need, skip.NeedResult = SkipNeeds, need, r
				return skip
			}
		}
	}
	if j.If == "" {
		skip.Kind, skip.Note = SkipNotKnown, "Its needs succeeded and it has no condition, yet GitHub skipped it: "+differs
		return skip
	}
	r := Read(j.If, jobContext(j, w, facts, results))
	skip.Values, skip.Unknown = r.Read, r.Unknown
	switch r.Truth {
	case False:
		skip.Kind = SkipConditionFalse
	case Unknown:
		skip.Kind = SkipNotKnown
	default:
		skip.Kind, skip.Note = SkipNotKnown, "Runnir reads its condition as true for this run, yet GitHub skipped it: "+differs
	}
	return skip
}

// jobContext is the run's context for one job: the needs it names, and the
// status functions over every job before it.
func jobContext(j Job, w Workflow, facts RunFacts, results map[string]string) Context {
	ctx := Context{}
	for k, v := range facts.Context {
		ctx[k] = v
	}
	for _, need := range j.Needs {
		if r := results[need]; r != "" {
			ctx["needs."+strings.ToLower(need)+".result"] = r
		}
	}
	success, failure := true, false
	for _, id := range before(j.ID, w) {
		switch results[id] {
		case "success":
		case "failure":
			success, failure = false, true
		default:
			success = false
		}
	}
	ctx["success()"], ctx["failure()"], ctx["cancelled()"] = success, failure, facts.Cancelled
	return ctx
}

// before lists the jobs a job needs, directly or through others.
func before(id string, w Workflow) []string {
	needs := map[string][]string{}
	for _, j := range w.Jobs {
		needs[j.ID] = j.Needs
	}
	seen := map[string]bool{}
	var out []string
	var walk func(string)
	walk = func(id string) {
		for _, n := range needs[id] {
			if !seen[n] {
				seen[n] = true
				out = append(out, n)
				walk(n)
			}
		}
	}
	walk(id)
	return out
}

// statusCheck: the condition calls a status function, so GitHub does not
// add success() to it.
func statusCheck(condition string) bool {
	c := strings.ToLower(strings.ReplaceAll(condition, " ", ""))
	for _, f := range []string{"success(", "failure(", "cancelled(", "always("} {
		if strings.Contains(c, f) {
			return true
		}
	}
	return false
}

// matchRunJobs finds a file job's jobs in the run as the app's run graph
// does (PipelineLayout.runJobs): its name or id, a matrix variant
// "name (…)", a called workflow's job "name / …", and for a name set by an
// expression the run jobs that start with its text before the expression
// and that no other job names.
func matchRunJobs(j Job, jobs []RunJob, all []Job) []RunJob {
	names := func(f Job, r RunJob) bool {
		for _, n := range []string{f.Name, f.ID} {
			if n != "" && !strings.Contains(n, "${{") &&
				(r.Name == n || strings.HasPrefix(r.Name, n+" (") || strings.HasPrefix(r.Name, n+" / ")) {
				return true
			}
		}
		return false
	}
	stem := ""
	if i := strings.Index(j.Name, "${{"); i >= 0 {
		stem = strings.TrimSpace(j.Name[:i])
	}
	var out []RunJob
	for _, r := range jobs {
		if names(j, r) {
			out = append(out, r)
			continue
		}
		if stem == "" || !strings.HasPrefix(r.Name, stem) {
			continue
		}
		claimed := false
		for _, f := range all {
			claimed = claimed || (f.ID != j.ID && names(f, r))
		}
		if !claimed {
			out = append(out, r)
		}
	}
	return out
}

// combined is a job's result over its run jobs (a matrix has several):
// failure first, then cancelled, one still going on, success, skipped.
func combined(runs []RunJob) string {
	has := map[string]bool{}
	for _, r := range runs {
		has[r.Result] = true
	}
	for _, r := range []string{"failure", "cancelled", "", "success", "skipped"} {
		if has[r] {
			return r
		}
	}
	return ""
}

// SourceNote says which file GitHub ran when it is not the file at the
// run's head commit; empty when it is.
func SourceNote(event string) string {
	switch event {
	case "pull_request":
		return "GitHub ran this file merged with the base, which may differ."
	case "pull_request_target":
		return "GitHub ran the file of the base branch, which may differ."
	}
	return ""
}

func notInRunNote(event string) string {
	switch event {
	case "pull_request":
		return "A pull request runs this workflow merged with the base branch, and that version may not have this job."
	case "pull_request_target":
		return "pull_request_target runs the workflow of the base branch, which may not have this job."
	}
	return "The file at this commit may differ from the one GitHub ran."
}
