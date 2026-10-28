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
// order. Jobs that ran, or are still to come, are left out, and so is a job
// named only by an expression, whose run jobs Runnir cannot find.
func ExplainSkips(w Workflow, facts RunFacts, jobs []RunJob) []Skip {
	names := make([]string, len(jobs))
	for i, r := range jobs {
		names[i] = r.Name
	}
	matched := map[string][]RunJob{}
	for i, id := range RunJobNodes(w, names) {
		if id != "" {
			matched[id] = append(matched[id], jobs[i])
		}
	}
	// The results of the jobs Runnir can find; the others are lost.
	results := map[string]string{}
	lost := map[string]bool{}
	for _, j := range w.Jobs {
		if findable(j) {
			results[j.ID] = combined(matched[j.ID])
		} else {
			lost[j.ID] = true
		}
	}
	var out []Skip
	for _, j := range w.Jobs {
		switch {
		case lost[j.ID]:
		case len(matched[j.ID]) == 0 && !facts.Active:
			out = append(out, Skip{JobID: j.ID, Kind: SkipNotInRun, Note: notInRunNote(facts.Event)})
		case results[j.ID] == "skipped":
			out = append(out, explain(j, w, facts, results, lost))
		}
	}
	return out
}

func explain(j Job, w Workflow, facts RunFacts, results map[string]string, lost map[string]bool) Skip {
	skip := Skip{JobID: j.ID, Condition: j.If}
	// Without a status function GitHub adds success(): every need succeeded.
	// With one, the status functions read every job before it.
	status := checksStatus(j.If)
	read := before(j.ID, w)
	if !status {
		read = j.Needs
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
	for _, id := range read {
		if lost[id] {
			skip.Kind, skip.Note = SkipNotKnown, "Runnir cannot tell how "+id+" ended in this run: its name is set by an expression."
			return skip
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
		switch {
		case r.Unreadable:
			skip.Note = "Runnir cannot read this condition, so it cannot tell."
		case len(r.Unsupported) > 0:
			skip.Note = "Runnir does not evaluate " + strings.Join(r.Unsupported, ", ") + " yet, so it cannot tell."
		}
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

// RunJobNodes says which job of the file each run job, by its name, belongs
// to: the job named by its name or id, also as a matrix variant "name (…)"
// or a called workflow's job "name / …"; else the first job whose name set
// by an expression starts like it ("Build ${{ matrix.os }}"). Empty for a
// run job no job of the file claims. The app's run graph and Overview use
// these for their jobs (through ListRunJobs).
func RunJobNodes(w Workflow, names []string) []string {
	out := make([]string, len(names))
	for i, name := range names {
		for _, j := range w.Jobs {
			if namedBy(j, name) {
				out[i] = j.ID
				break
			}
		}
		if out[i] != "" {
			continue
		}
		for _, j := range w.Jobs {
			if stem := nameStem(j.Name); stem != "" && strings.HasPrefix(name, stem) {
				out[i] = j.ID
				break
			}
		}
	}
	return out
}

func namedBy(j Job, name string) bool {
	for _, n := range []string{j.Name, j.ID} {
		if n != "" && !strings.Contains(n, "${{") && (name == n || strings.HasPrefix(name, n+" (") || strings.HasPrefix(name, n+" / ")) {
			return true
		}
	}
	return false
}

// nameStem is a name's text before its expression; empty without one.
func nameStem(name string) string {
	if i := strings.Index(name, "${{"); i >= 0 {
		return strings.TrimSpace(name[:i])
	}
	return ""
}

// findable: Runnir can find the job's run jobs, so a run without one has
// none. A name that is only an expression is known only to the run.
func findable(j Job) bool {
	return !strings.Contains(j.Name, "${{") || nameStem(j.Name) != ""
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
