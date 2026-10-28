# Why A Job Was Skipped (B35) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The run graph says why each skipped job did not run (a need that did not succeed, a condition false for the run, a condition Runnir cannot decide) and marks nodes a finished run has no job for as "not in this run", with a panel under the node on click.

**Architecture:** The Core explains: `flow` gets a condition reader that reports what it read and a pure `ExplainSkips` over the workflow file, the run's facts and its jobs; `GetRunWorkflow` builds the facts (the run, the workspace's pull requests, local refs), reads the jobs (cached once the run is finished) and returns `JobSkip`s. The app maps them, writes the reason on the node and draws the panel under it as part of the graph's layout.

**Tech Stack:** Go 1.27 (pure Go, `CGO_ENABLED=0`), protobuf/gRPC (buf, swift-protobuf, grpc-swift-protobuf), Swift 6, SwiftUI, Observation, Swift Testing.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-10-27-why-a-job-was-skipped-design.md`. Pen: `docs/design/runnir.pen`, journey D, Row — Why a job was skipped (B35).
- Contract changes in place: no versions, aliases or migrations (AGENTS.md, before the first release tag).
- No new dependencies in Go or Swift. No telemetry. No credentials on disk or in notes.
- A condition Runnir cannot decide is shown as text with what Runnir does not know; never guessed.
- Nothing more is asked of GitHub than the run and its jobs, and neither again once the run is finished.
- UI text in English. No AI attribution in commits, code, docs or PRs (no `Co-Authored-By`, no "Generated with").
- Xcode builds need Go 1.27.3 on the PATH: `export PATH="$HOME/go/pkg/mod/golang.org/toolchain@v0.0.1-go1.27.3.darwin-arm64/bin:$PATH"` before `xcodebuild`.
- Contract generation needs the Swift plugins on the PATH: `export PATH="$HOME/go/bin:/private/tmp/claude-502/-Users-dilbarov-projects-runnir/90db4574-3499-4323-929d-0cc810dcb80e/scratchpad/protoc-plugins/swift-protobuf/.build/out/Products/Release:/private/tmp/claude-502/-Users-dilbarov-projects-runnir/90db4574-3499-4323-929d-0cc810dcb80e/scratchpad/protoc-plugins/grpc-swift-protobuf/.build/out/Products/Release:$PATH"` then `scripts/generate-contracts.sh`. If that folder is gone, build the plugins as the script's header says.

## File Structure

- `core/internal/flow/expr.go` — `Read` (truth plus the names read and not known); status functions from the context.
- `core/internal/flow/skipped.go` (new) — `RunJob`, `RunFacts`, `SkipKind`, `Skip`, `ExplainSkips`, `SourceNote`, the run-job matching.
- `core/internal/flow/git.go` — `Branches`; `maxTags` becomes `maxRefs`.
- `core/internal/flow/flow_test.go` — tests of the three above.
- `contracts/grpc/runnir/core/v1/runnir_core.proto` — `SkipKind`, `ConditionValue`, `JobSkip`, `GetRunWorkflowResponse.skips` and `.source_note`.
- `core/internal/server/skips.go` (new) — the run's facts and the explanations for `GetRunWorkflow`.
- `core/internal/server/github.go` — `GetRunWorkflow` parses with `flow.Parse`, keeps the run and jobs of a finished run with the file, adds the explanations.
- `core/internal/server/dispatch_test.go`, `dispatch_history_test.go` — the fake GitHub's runs 35 and 36 with jobs; the server test.
- `apps/macos/Runnir/IPC/CoreGitHubModels.swift`, `GRPCCoreService.swift` — `CoreJobSkip`, the mapping.
- `apps/macos/Runnir/Features/Desktop/RunGraphViews.swift` — reasons on nodes, `SkippedJobPanel`, the layer's open panel.
- `apps/macos/Runnir/Features/Desktop/RunInspectorView.swift` — the workflow read again when the run finishes.
- `apps/macos/RunnirTests/RunGraphTests.swift` — app tests.
- Docs: the spec's status, `docs/product/mvp-implementation-checklist.md`, `docs/architecture/grpc-api.md`, `docs/design/screens-and-states.md`.

---

### Task 1: A Condition Says What It Read

**Files:**
- Modify: `core/internal/flow/expr.go`
- Test: `core/internal/flow/flow_test.go`

**Interfaces:**
- Produces: `type Value struct{ Name, Value string }`; `type Reading struct { Truth Truth; Read []Value; Unknown []string }`; `func Read(condition string, ctx Context) Reading`. `Evaluate(condition, ctx)` stays and returns `Read(...).Truth`. A context may hold `"success()"`, `"failure()"`, `"cancelled()"` (bool) for a run; without them `success()` and `always()` hold and `failure()` and `cancelled()` are unknown, as today.

- [ ] **Step 1: Write the failing test** (append to `flow_test.go`)

```go
func TestAConditionSaysWhatItRead(t *testing.T) {
	run := Context{"github.event_name": "push", "github.ref": "refs/heads/main", "success()": false, "failure()": true, "cancelled()": false}
	r := Read("github.event_name == 'pull_request' && vars.RELEASE_NOTES == 'true'", run)
	if r.Truth != False || !reflect.DeepEqual(r.Read, []Value{{"github.event_name", "push"}}) || !reflect.DeepEqual(r.Unknown, []string{"vars.RELEASE_NOTES"}) {
		t.Fatalf("read = %+v", r)
	}
	if r := Read("${{ failure() && github.ref == 'refs/heads/main' }}", run); r.Truth != True ||
		!reflect.DeepEqual(r.Read, []Value{{"failure()", "true"}, {"github.ref", "refs/heads/main"}}) {
		t.Fatalf("status = %+v", r)
	}
	if r := Read("success()", run); r.Truth != False {
		t.Fatalf("a run's success() = %+v", r)
	}
	if r := Read("github['event_name'] == 'push' && github.event_name == 'push'", run); r.Truth != True || len(r.Read) != 1 {
		t.Fatalf("a name read twice is listed once: %+v", r)
	}
	// Without a run the plan's defaults hold.
	if r := Read("success() && always()", Context{}); r.Truth != True {
		t.Fatalf("plan success = %+v", r)
	}
	if r := Read("cancelled()", Context{}); r.Truth != Unknown || !reflect.DeepEqual(r.Unknown, []string{"cancelled()"}) {
		t.Fatalf("plan cancelled = %+v", r)
	}
	if r := Read("github.event_name == ", run); r.Truth != Unknown {
		t.Fatalf("broken = %+v", r)
	}
	if r := Read("", run); r.Truth != True {
		t.Fatalf("empty = %+v", r)
	}
}
```

- [ ] **Step 2: Run it to see it fail**

Run (from `core/`): `go test ./internal/flow/ -run TestAConditionSaysWhatItRead`
Expected: FAIL, `undefined: Read` and `undefined: Value`.

- [ ] **Step 3: Implement**

In `expr.go`, replace `Evaluate` and its comment with:

```go
// Value is a name a condition read, with the value the context gave it.
type Value struct{ Name, Value string }

// Reading is what a condition says for a context and what it read: the
// names it found, with their values, and the names it could not know, each
// once and as written, in the order it read them.
type Reading struct {
	Truth   Truth
	Read    []Value
	Unknown []string
}

// Evaluate reads a condition as GitHub would for the scenario: literals,
// comparisons (strings without regard to case), !, && and ||, parentheses,
// startsWith, endsWith, contains and format, and the contexts the scenario
// knows. Status functions come from the context ("success()" and the
// others) for a run; without them the plan shows the run in which the jobs
// before succeed: success() and always() hold, failure() and cancelled()
// are unknown.
func Evaluate(condition string, ctx Context) Truth { return Read(condition, ctx).Truth }

// Read evaluates a condition as Evaluate does and says what it read.
func Read(condition string, ctx Context) Reading {
	text := strings.TrimSpace(unwrap(condition))
	if text == "" {
		return Reading{Truth: True}
	}
	p := &parser{tokens: tokenize(text), ctx: ctx}
	v := p.or()
	out := Reading{Read: p.read, Unknown: p.unknown}
	switch {
	case p.failed || p.pos != len(p.tokens) || v.unknown:
		out.Truth = Unknown
	case truthy(v.value):
		out.Truth = True
	default:
		out.Truth = False
	}
	return out
}
```

Add two fields to `parser` and a method after `expect`:

```go
type parser struct {
	tokens  []token
	pos     int
	ctx     Context
	failed  bool
	read    []Value
	unknown []string
}

// note keeps a name the condition read, once: with its value when the
// context has it, as not known otherwise.
func (p *parser) note(name string, v any, known bool) {
	if known {
		for _, r := range p.read {
			if r.Name == name {
				return
			}
		}
		shown := str(v)
		if v == nil {
			shown = "null"
		}
		p.read = append(p.read, Value{name, shown})
		return
	}
	for _, u := range p.unknown {
		if u == name {
			return
		}
	}
	p.unknown = append(p.unknown, name)
}
```

In `primary`, replace the index loop and the lookup (from `// An index by a string` to the end of the function) with:

```go
	// An index by a string, github['event_name'], reads as a property; any
	// other index, and a key with a dot, which no property name the plan
	// knows has, is beyond what the plan knows.
	name, shown, known := strings.ToLower(t.text), t.text, true
	for p.peek("[") {
		p.pos++
		key := p.or()
		p.expect("]")
		s, ok := key.value.(string)
		known = known && ok && !key.unknown && !strings.Contains(s, ".")
		name += "." + strings.ToLower(s)
		shown += "." + s
		if p.pos < len(p.tokens) && p.tokens[p.pos].kind == "ident" && strings.HasPrefix(p.tokens[p.pos].text, ".") {
			name += strings.ToLower(p.tokens[p.pos].text)
			shown += p.tokens[p.pos].text
			p.pos++
		}
	}
	if v, ok := p.ctx[name]; ok && known {
		p.note(shown, v, true)
		return val{value: v}
	}
	p.note(shown, nil, false)
	return val{unknown: true}
```

The index test of Task 1 reads `github['event_name']` and `github.event_name`: both are noted, as `github.event_name` once because `shown` is `github.event_name` for both (`"github" + "." + "event_name"`).

In `call`, replace

```go
	switch strings.ToLower(name) {
	case "success", "always":
		return val{value: true}
	case "failure", "cancelled":
		return val{unknown: true}
	}
```

with

```go
	switch fn := strings.ToLower(name); fn {
	case "success", "always", "failure", "cancelled":
		if v, ok := p.ctx[fn+"()"]; ok {
			p.note(fn+"()", v, true)
			return val{value: v}
		}
		if fn == "success" || fn == "always" {
			return val{value: true}
		}
		p.note(fn+"()", nil, false)
		return val{unknown: true}
	}
```

- [ ] **Step 4: Run the flow tests**

Run (from `core/`): `go test ./internal/flow/`
Expected: `ok` (the existing condition table keeps passing: `!cancelled()` is still Unknown without a run).

- [ ] **Step 5: Commit**

```bash
git add core/internal/flow/expr.go core/internal/flow/flow_test.go
git commit -m "Core: a condition says what it read and what it could not know; a run's status functions (B35)"
```

### Task 2: Explain The Jobs A Run Skipped

**Files:**
- Create: `core/internal/flow/skipped.go`
- Test: `core/internal/flow/flow_test.go`

**Interfaces:**
- Consumes: `Read`, `Value` (Task 1); `Workflow`, `Job`, `Parse` (existing).
- Produces:
  - `type RunJob struct{ Name, Result string }` — Result is `success`, `failure`, `cancelled`, `skipped`, or empty while the job goes on.
  - `type RunFacts struct { Context Context; Event string; Active, Cancelled bool }`.
  - `type SkipKind int` with `SkipNeeds`, `SkipConditionFalse`, `SkipNotKnown`, `SkipNotInRun`.
  - `type Skip struct { JobID string; Kind SkipKind; Need, NeedResult, Condition string; Values []Value; Unknown []string; Note string }`.
  - `func ExplainSkips(w Workflow, facts RunFacts, jobs []RunJob) []Skip` — in the file's job order.
  - `func SourceNote(event string) string`.

- [ ] **Step 1: Write the failing test** (append to `flow_test.go`)

```go
const skipsWorkflow = `name: CI
on: [push, pull_request]
jobs:
  lint: {runs-on: x, steps: [{run: x}]}
  build:
    needs: lint
    runs-on: x
    steps: [{run: x}]
  test:
    needs: lint
    strategy:
      matrix:
        os: [a, b, c]
        exclude: [{os: c}]
    runs-on: x
    steps: [{run: x}]
  publish:
    needs: build
    runs-on: x
    steps: [{run: x}]
  deploy:
    needs: publish
    runs-on: x
    steps: [{run: x}]
  docs:
    if: github.event_name == 'pull_request'
    runs-on: x
    steps: [{run: x}]
  changelog:
    if: vars.RELEASE_NOTES == 'true'
    runs-on: x
    steps: [{run: x}]
  report:
    needs: build
    if: always()
    runs-on: x
    steps: [{run: x}]
  notify:
    needs: lint
    if: github.event_name == 'push'
    runs-on: x
    steps: [{run: x}]
  call:
    if: github.ref == 'refs/heads/release'
    uses: ./.github/workflows/lib.yml
  after-test:
    needs: test
    runs-on: x
    steps: [{run: x}]
  preview:
    runs-on: x
    steps: [{run: x}]
`

func TestWhyJobsWereSkipped(t *testing.T) {
	w := Parse(".github/workflows/ci.yml", []byte(skipsWorkflow))
	jobs := []RunJob{
		{"lint", "success"}, {"build", "failure"}, {"test (a)", "success"}, {"test (b)", "cancelled"},
		{"publish", "skipped"}, {"deploy", "skipped"}, {"docs", "skipped"}, {"changelog", "skipped"}, {"report", "success"},
		{"notify", "skipped"}, {"call", "skipped"}, {"after-test", "skipped"},
	}
	facts := RunFacts{Context: Context{"github.event_name": "push", "github.ref": "refs/heads/main"}, Event: "push"}
	got := map[string]Skip{}
	var order []string
	for _, s := range ExplainSkips(w, facts, jobs) {
		got[s.JobID] = s
		order = append(order, s.JobID)
	}
	if want := []string{"publish", "deploy", "docs", "changelog", "notify", "call", "after-test", "preview"}; !reflect.DeepEqual(order, want) {
		t.Fatalf("explained = %v (a matrix with exclude, and always() after a failure, are no skips)", order)
	}
	if s := got["publish"]; s.Kind != SkipNeeds || s.Need != "build" || s.NeedResult != "failure" {
		t.Fatalf("publish = %+v", s)
	}
	if s := got["deploy"]; s.Kind != SkipNeeds || s.Need != "publish" || s.NeedResult != "skipped" {
		t.Fatalf("deploy = %+v", s)
	}
	if s := got["after-test"]; s.Kind != SkipNeeds || s.Need != "test" || s.NeedResult != "cancelled" {
		t.Fatalf("a matrix with a cancelled variant = %+v", s)
	}
	if s := got["docs"]; s.Kind != SkipConditionFalse || s.Condition != "github.event_name == 'pull_request'" ||
		!reflect.DeepEqual(s.Values, []Value{{"github.event_name", "push"}}) {
		t.Fatalf("docs = %+v", s)
	}
	if s := got["changelog"]; s.Kind != SkipNotKnown || !reflect.DeepEqual(s.Unknown, []string{"vars.RELEASE_NOTES"}) || s.Note != "" {
		t.Fatalf("changelog = %+v", s)
	}
	if s := got["notify"]; s.Kind != SkipNotKnown || !strings.Contains(s.Note, "reads its condition as true") {
		t.Fatalf("a condition read as true while GitHub skipped the job = %+v", s)
	}
	if s := got["call"]; s.Kind != SkipConditionFalse || !reflect.DeepEqual(s.Values, []Value{{"github.ref", "refs/heads/main"}}) {
		t.Fatalf("a reusable workflow node = %+v", s)
	}
	if s := got["preview"]; s.Kind != SkipNotInRun || s.Note != "The file at this commit may differ from the one GitHub ran." {
		t.Fatalf("preview = %+v", s)
	}

	// While the run goes on, a node without a job is still to come.
	facts.Active = true
	for _, s := range ExplainSkips(w, facts, jobs) {
		if s.Kind == SkipNotInRun {
			t.Fatalf("active run explains %q", s.JobID)
		}
	}

	pr := RunFacts{Context: Context{"github.event_name": "pull_request"}, Event: "pull_request"}
	for _, s := range ExplainSkips(w, pr, jobs) {
		if s.JobID == "preview" && !strings.Contains(s.Note, "merged with the base branch") {
			t.Fatalf("pull request note = %q", s.Note)
		}
	}
	if SourceNote("pull_request") != "GitHub ran this file merged with the base, which may differ." ||
		SourceNote("pull_request_target") != "GitHub ran the file of the base branch, which may differ." || SourceNote("push") != "" {
		t.Fatal("source notes")
	}
}
```

- [ ] **Step 2: Run it to see it fail**

Run (from `core/`): `go test ./internal/flow/ -run TestWhyJobsWereSkipped`
Expected: FAIL, `undefined: RunJob`.

- [ ] **Step 3: Implement** `core/internal/flow/skipped.go`

```go
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
```

- [ ] **Step 4: Run the flow tests**

Run (from `core/`): `go test ./internal/flow/ && go vet ./internal/flow/`
Expected: `ok`, no vet output.

- [ ] **Step 5: Commit**

```bash
git add core/internal/flow/skipped.go core/internal/flow/flow_test.go
git commit -m "Core: why each job of a run was skipped, from its file, the run and its jobs (B35)"
```

### Task 3: The Contract And GetRunWorkflow

**Files:**
- Modify: `contracts/grpc/runnir/core/v1/runnir_core.proto`, `core/internal/flow/git.go`, `core/internal/server/github.go`, `core/internal/server/dispatch_test.go`, `core/internal/server/dispatch_history_test.go`, `core/internal/flow/flow_test.go`, `docs/architecture/grpc-api.md`
- Create: `core/internal/server/skips.go`
- Regenerated: `core/internal/gen/runnir/core/v1/*.go`, `apps/macos/Runnir/IPC/Generated/runnir/core/v1/*.swift`

**Interfaces:**
- Consumes: `flow.ExplainSkips`, `flow.SourceNote`, `flow.RunFacts`, `flow.RunJob`, `flow.Skip`, `flow.Parse` (Tasks 1–2).
- Produces: proto `enum SkipKind { SKIP_KIND_UNSPECIFIED = 0; SKIP_KIND_NEEDS = 1; SKIP_KIND_CONDITION_FALSE = 2; SKIP_KIND_NOT_KNOWN = 3; SKIP_KIND_NOT_IN_RUN = 4; }`, `message ConditionValue { string name = 1; string value = 2; }`, `message JobSkip { string job_id = 1; SkipKind kind = 2; string need = 3; string need_result = 4; string condition = 5; repeated ConditionValue values = 6; repeated string unknown = 7; string note = 8; }`, `GetRunWorkflowResponse.skips = 5`, `GetRunWorkflowResponse.source_note = 6`. In Swift: `Runnir_Core_V1_JobSkip` (`jobID`, `kind`, `need`, `needResult`, `condition`, `values`, `unknown`, `note`), `Runnir_Core_V1_SkipKind` (`.needs`, `.conditionFalse`, `.notKnown`, `.notInRun`), `response.skips`, `response.sourceNote`. `flow.Git.Branches(ctx) map[string]bool`.

- [ ] **Step 1: The contract.** In `runnir_core.proto`, replace `GetRunWorkflowResponse` with the following and add the three types after it:

```proto
message GetRunWorkflowResponse {
  GitHubStatus status = 1;
  // ".github/workflows/<file>", empty when it was not found.
  string workflow_path = 2;
  repeated Job jobs = 3;
  // Why there are no jobs; empty when the file was read and parsed.
  string problem = 4;
  // Why each job the run skipped was skipped, and the jobs a finished run
  // has no job for, in the file's order (B35). Empty when the run or its
  // jobs could not be read.
  repeated JobSkip skips = 5;
  // Which file GitHub ran when it is not the one read: a pull request's
  // merged with its base, pull_request_target's of the base branch.
  string source_note = 6;
}

enum SkipKind {
  SKIP_KIND_UNSPECIFIED = 0;
  // A job it needs did not succeed and its if checks no status.
  SKIP_KIND_NEEDS = 1;
  // Its if is false for the run.
  SKIP_KIND_CONDITION_FALSE = 2;
  // Its if reads what Runnir does not know, or reads true although GitHub
  // skipped the job.
  SKIP_KIND_NOT_KNOWN = 3;
  // The finished run has no job for it.
  SKIP_KIND_NOT_IN_RUN = 4;
}

message ConditionValue {
  // As the condition writes it: "github.event_name", "failure()".
  string name = 1;
  string value = 2;
}

message JobSkip {
  // The job's id in the workflow file.
  string job_id = 1;
  SkipKind kind = 2;
  // For NEEDS: the job it needs that did not succeed, and its result
  // (failure, cancelled or skipped).
  string need = 3;
  string need_result = 4;
  // The job's if, without ${{ }}; empty without one.
  string condition = 5;
  // What the condition read of the run, in the order it read it.
  repeated ConditionValue values = 6;
  // What the condition reads that Runnir does not know.
  repeated string unknown = 7;
  // A sentence for NOT_KNOWN when GitHub disagrees, and for NOT_IN_RUN.
  string note = 8;
}
```

Regenerate (with the PATH of Global Constraints): `scripts/generate-contracts.sh`
Expected: no errors; `git status` shows the four generated files changed.

- [ ] **Step 2: Local branches.** In `core/internal/flow/git.go` rename `maxTags` to `maxRefs` (comment: "maxRefs bounds the refs read.") and use it in `Tags`; add after `Tags`:

```go
// Branches are the names of the local and remote-tracking branches
// ("origin/main" as "main"); nil when git cannot say.
func (g Git) Branches(ctx context.Context) map[string]bool {
	if g.Path == "" {
		return nil
	}
	out, err := g.run(ctx, "for-each-ref", "--format=%(refname)", "--count="+strconv.Itoa(maxRefs), "refs/heads", "refs/remotes")
	if err != nil {
		return nil
	}
	branches := map[string]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if name, ok := strings.CutPrefix(line, "refs/heads/"); ok && name != "" {
			branches[name] = true
		} else if rest, ok := strings.CutPrefix(line, "refs/remotes/"); ok {
			if _, name, ok := strings.Cut(rest, "/"); ok && name != "" && name != "HEAD" {
				branches[name] = true
			}
		}
	}
	return branches
}
```

In `TestGitListsTheFilesOfTheChange` (flow_test.go), after the `Tags` check, add:

```go
	if branches := g.Branches(context.Background()); !branches["main"] || !branches["feature"] || branches["v1.0"] {
		t.Fatalf("branches = %v", branches)
	}
```

(`refs/remotes/origin/main` is in that repository too; it reads as `main`.)

- [ ] **Step 3: The fake GitHub serves runs with skipped jobs.** In `dispatch_test.go`, add after `pipelineWorkflow`:

```go
// skipsWorkflow has a job for each reason a job is skipped (B35).
const skipsWorkflow = `name: Deploy
on: [push, pull_request]
jobs:
  lint: {runs-on: x, steps: []}
  build:
    needs: lint
    runs-on: x
    steps: []
  publish:
    needs: build
    runs-on: x
    steps: []
  docs:
    if: github.event_name == 'pull_request'
    runs-on: x
    steps: []
  changelog:
    if: vars.RELEASE_NOTES == 'true'
    runs-on: x
    steps: []
  preview:
    runs-on: x
    steps: []
`

const skipsJobs = `{"total_count":5,"jobs":[
{"id":1,"name":"lint","status":"completed","conclusion":"success"},
{"id":2,"name":"build","status":"completed","conclusion":"failure"},
{"id":3,"name":"publish","status":"completed","conclusion":"skipped"},
{"id":4,"name":"docs","status":"completed","conclusion":"skipped"},
{"id":5,"name":"changelog","status":"completed","conclusion":"skipped"}]}`
```

In the handler's `switch`, before `case r.URL.Path == "/repos/o/r/actions/runs/31":`, add (the jobs cases first: their paths start like the runs'):

```go
		case r.URL.Path == "/repos/o/r/actions/runs/31/jobs" || r.URL.Path == "/repos/o/r/actions/runs/34/jobs":
			_, _ = w.Write([]byte(`{"total_count":3,"jobs":[{"id":1,"name":"lint","status":"completed","conclusion":"success"},{"id":2,"name":"unit-tests","status":"completed","conclusion":"success"},{"id":3,"name":"build","status":"completed","conclusion":"success"}]}`))
		case r.URL.Path == "/repos/o/r/actions/runs/35/jobs" || r.URL.Path == "/repos/o/r/actions/runs/36/jobs":
			_, _ = w.Write([]byte(skipsJobs))
		case r.URL.Path == "/repos/o/r/actions/runs/35":
			_, _ = w.Write([]byte(`{"id":35,"workflow_id":7,"name":"Deploy","event":"push","head_branch":"main","head_sha":"skips","status":"completed","conclusion":"failure","actor":{"login":"eugene"}}`))
		case r.URL.Path == "/repos/o/r/actions/runs/36":
			_, _ = w.Write([]byte(`{"id":36,"workflow_id":7,"name":"Deploy","event":"pull_request","head_branch":"feature","head_sha":"skips","status":"completed","conclusion":"failure","pull_requests":[{"number":12,"base":{"repo":{"url":"https://api.github.com/repos/o/r"}}}]}`))
```

and in the `deploy.yml` contents `switch` add `case "skips": _, _ = w.Write([]byte(skipsWorkflow))`.

These bodies use the keys `runJSON` in `core/internal/github/client.go` reads: `actor.login`, and `pull_requests[].number` with `base.repo.url` ending in `/repos/o/r` (a pull request of another repository is dropped).

- [ ] **Step 4: Write the failing server test** (append to `dispatch_history_test.go`)

```go
func TestARunsSkippedJobsAreExplained(t *testing.T) {
	client, id, fake, ctx := historyRig(t)
	reads := func() int {
		fake.mu.Lock()
		defer fake.mu.Unlock()
		return fake.workflowReads
	}
	got, err := client.GetRunWorkflow(ctx, &corev1.GetRunWorkflowRequest{RepositoryId: id, RunId: 35})
	if err != nil || got.Problem != "" || got.SourceNote != "" {
		t.Fatalf("workflow = %v, %v", got, err)
	}
	skips := map[string]*corev1.JobSkip{}
	for _, s := range got.Skips {
		skips[s.JobId] = s
	}
	if s := skips["publish"]; s.GetKind() != corev1.SkipKind_SKIP_KIND_NEEDS || s.Need != "build" || s.NeedResult != "failure" {
		t.Fatalf("publish = %v", s)
	}
	if s := skips["docs"]; s.GetKind() != corev1.SkipKind_SKIP_KIND_CONDITION_FALSE || len(s.Values) != 1 ||
		s.Values[0].Name != "github.event_name" || s.Values[0].Value != "push" {
		t.Fatalf("docs = %v", s)
	}
	if s := skips["changelog"]; s.GetKind() != corev1.SkipKind_SKIP_KIND_NOT_KNOWN || len(s.Unknown) != 1 || s.Unknown[0] != "vars.RELEASE_NOTES" {
		t.Fatalf("changelog = %v", s)
	}
	if s := skips["preview"]; s.GetKind() != corev1.SkipKind_SKIP_KIND_NOT_IN_RUN || s.Note == "" {
		t.Fatalf("preview = %v", s)
	}
	if len(got.Skips) != 4 {
		t.Fatalf("skips = %v", got.Skips)
	}

	// A finished run's run and jobs are kept with its file: asked again, nothing is read.
	before := reads()
	if again, err := client.GetRunWorkflow(ctx, &corev1.GetRunWorkflowRequest{RepositoryId: id, RunId: 35}); err != nil || len(again.Skips) != 4 {
		t.Fatalf("again = %v, %v", again, err)
	}
	if after := reads(); after != before {
		t.Fatalf("a finished run read again made %d GitHub requests", after-before)
	}

	pr, err := client.GetRunWorkflow(ctx, &corev1.GetRunWorkflowRequest{RepositoryId: id, RunId: 36})
	if err != nil || pr.SourceNote != "GitHub ran this file merged with the base, which may differ." {
		t.Fatalf("pull request = %v, %v", pr, err)
	}
	for _, s := range pr.Skips {
		if s.JobId == "docs" {
			t.Fatalf("docs ran its condition true on a pull request, yet was skipped: %v", s)
		}
	}
}
```

The last loop asserts that on run 36 (`pull_request`), docs' condition reads true, so docs is NOT_KNOWN with the "reads its condition as true" note rather than CONDITION_FALSE. Replace the loop with that check:

```go
	for _, s := range pr.Skips {
		if s.JobId == "docs" && (s.GetKind() != corev1.SkipKind_SKIP_KIND_NOT_KNOWN || !strings.Contains(s.Note, "reads its condition as true")) {
			t.Fatalf("docs on a pull request = %v", s)
		}
	}
```

Run (from `core/`): `go test ./internal/server/ -run 'TestARunsSkippedJobsAreExplained|TestARunsWorkflowIsReadAtItsCommit'`
Expected: FAIL to compile (`got.Skips` undefined) before Step 1's generation, then FAIL on `publish = <nil>`.

- [ ] **Step 5: The run's facts.** Create `core/internal/server/skips.go`:

```go
package server

import (
	"strconv"
	"strings"

	"runnir/core/internal/flow"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
)

// runFacts is what a run tells its jobs' conditions: its event and refs,
// actor, repository and workflow; the pull request's base and draft when
// the workspace has read it; whether a pushed ref is a tag or a branch as
// the local repository knows it (refs is nil without one).
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
		if pull != nil {
			ctx["github.base_ref"] = pull.BaseRef
			ctx["github.event.pull_request.draft"] = pull.Draft
			ctx["github.event.pull_request.number"] = float64(pull.Number)
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
```

- [ ] **Step 5b: Test the facts.** Append to `core/internal/server/dispatch_history_test.go` (the file has the server package's imports; add `runnir/core/internal/github` if missing):

```go
func TestARunsFactsNameItsRef(t *testing.T) {
	refs := func() (map[string]bool, map[string]bool) {
		return map[string]bool{"v1.0": true, "both": true}, map[string]bool{"main": true, "both": true}
	}
	ref := func(run github.Run) any { return runFacts(run, "o/r", "main", nil, refs).Context["github.ref"] }
	if got := ref(github.Run{Event: "push", Branch: "v1.0"}); got != "refs/tags/v1.0" {
		t.Fatalf("tag = %v", got)
	}
	if got := ref(github.Run{Event: "push", Branch: "main"}); got != "refs/heads/main" {
		t.Fatalf("branch = %v", got)
	}
	for _, name := range []string{"both", "gone"} {
		if got, ok := runFacts(github.Run{Event: "push", Branch: name}, "o/r", "main", nil, refs).Context["github.ref"]; ok {
			t.Fatalf("%s is a tag and a branch, or neither, so github.ref is unknown: %v", name, got)
		}
	}
	if got := ref(github.Run{Event: "pull_request", Branch: "feature", PullRequests: []int64{12}}); got != "refs/pull/12/merge" {
		t.Fatalf("pull request = %v", got)
	}
	pull := &github.RepositoryPullRequest{Number: 12, BaseRef: "release", Draft: true}
	facts := runFacts(github.Run{Event: "pull_request_target", Branch: "feature", PullRequests: []int64{12}}, "o/r", "main", pull, refs)
	if facts.Context["github.ref"] != "refs/heads/release" || facts.Context["github.base_ref"] != "release" || facts.Context["github.event.pull_request.draft"] != true {
		t.Fatalf("pull_request_target = %v", facts.Context)
	}
	if got := ref(github.Run{Event: "workflow_run", Branch: "feature"}); got != "refs/heads/main" {
		t.Fatalf("workflow_run runs on the default branch: %v", got)
	}
	if f := runFacts(github.Run{Event: "push", Status: "in_progress"}, "o/r", "", nil, nil); !f.Active || f.Cancelled {
		t.Fatalf("active = %+v", f)
	}
	if f := runFacts(github.Run{Event: "push", Status: "completed", Conclusion: "cancelled"}, "o/r", "", nil, nil); f.Active || !f.Cancelled {
		t.Fatalf("cancelled = %+v", f)
	}
}
```

Run (from `core/`): `go test ./internal/server/ -run TestARunsFactsNameItsRef` — Expected: PASS once `skips.go` exists.

- [ ] **Step 6: GetRunWorkflow explains.** In `core/internal/server/github.go`:

1. `workflowFile` keeps the run and its jobs:

```go
type workflowFile struct {
	path string
	data []byte
	// missing: GitHub does not serve the file at the run's commit.
	missing bool
	// run as read with the file; run and jobs stay once final (the run
	// finished and its jobs were read after), as neither changes then.
	run   github.Run
	jobs  []github.Job
	final bool
}
```

2. `readRunWorkflow` returns the run it read: `return workflowFile{path: path, data: data, run: run}, err`.

3. In `GetRunWorkflow`, track whether this call read the file (`fresh := !cached` before the read), replace `workflow := scanner.ParseWorkflow(path, data)` with `workflow := flow.Parse(path, data)`, keep the response's jobs as they are (`flow.Job` has `ID`, `Name`, `Needs`, `Manual`, `ManualInputs`), and before the final `return out, nil` add:

```go
	if len(out.Jobs) > 0 {
		out.Skips, out.SourceNote = s.explainSkips(ctx, request, target, key, file, fresh, workflow)
	}
```

4. Add the method (in `skips.go`):

```go
// explainSkips explains the jobs a run skipped. The run and its jobs are
// read again until the run is finished, then kept with its file. Nothing is
// explained when they cannot be read.
func (s *service) explainSkips(ctx context.Context, request *corev1.GetRunWorkflowRequest, target githubRepo, key workflowFileKey,
	file workflowFile, fresh bool, w flow.Workflow) ([]*corev1.JobSkip, string) {
	run, jobs := file.run, file.jobs
	var rt *workspace.Runtime
	if request.GetGithubRepository() == "" {
		rt, _ = s.workspaces.ForRepository(request.GetRepositoryId())
	}
	if !file.final {
		if !fresh {
			read, err := target.account.Client.Run(ctx, target.owner, target.name, request.GetRunId())
			if err != nil {
				return nil, ""
			}
			run = read
		}
		var err error
		if rt != nil {
			var access corev1.GithubAccess
			jobs, access, _, err = rt.Jobs(ctx, request.GetRunId())
			if err == nil && access != corev1.GithubAccess_GITHUB_ACCESS_OK {
				return nil, ""
			}
		} else {
			jobs, err = target.account.Client.Jobs(ctx, target.owner, target.name, request.GetRunId())
		}
		if err != nil {
			return nil, ""
		}
		if run.Status == "completed" {
			file.run, file.jobs, file.final = run, jobs, true
			s.workflowFiles.put(key, file)
		}
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
	for _, skip := range flow.ExplainSkips(w, runFacts(run, repository, defaultBranch, pull, refs), runJobs) {
		out = append(out, skipMessage(skip))
	}
	return out, flow.SourceNote(run.Event)
}
```

Add the imports `context` and `runnir/core/internal/workspace` to `skips.go`: `s.workspaces.ForRepository` returns `(*workspace.Runtime, bool)`. Remove the `scanner` import from `github.go` if nothing else there uses it.

- [ ] **Step 7: Run the Core checks**

Run (from `core/`): `go test ./... && go vet ./... && go build ./...`
Expected: every package `ok`; `TestARunsWorkflowIsReadAtItsCommit` still passes (runs 31 and 34 are finished, their jobs are served, so a second ask reads nothing).

- [ ] **Step 8: The API doc.** In `docs/architecture/grpc-api.md`, extend the `GetRunWorkflow(run_id)` row's meaning with: "; with `skips`, why each job the run skipped was skipped (a need that did not succeed, a condition false for the run with the values it read, a condition Runnir cannot decide with what it does not know) and the jobs a finished run has no job for, and `source_note` when GitHub ran another version of the file (a pull request's merge, `pull_request_target`'s base). The run and its jobs are read until the run is finished, then kept (B35)".

- [ ] **Step 9: Commit**

```bash
git add contracts core apps/macos/Runnir/IPC/Generated docs/architecture/grpc-api.md
git commit -m "Core: GetRunWorkflow explains the jobs a run skipped, from the run, its jobs, the workspace's pull requests and local refs (B35)"
```

### Task 4: The App Reads The Explanations

**Files:**
- Modify: `apps/macos/Runnir/IPC/CoreGitHubModels.swift`, `apps/macos/Runnir/IPC/GRPCCoreService.swift`, `apps/macos/Runnir/Features/Desktop/RunGraphViews.swift` (the `RunGraph` enum and `RunLayerModel` only), `apps/macos/Runnir/Features/Desktop/RunInspectorView.swift`
- Test: `apps/macos/RunnirTests/RunGraphTests.swift`

**Interfaces:**
- Consumes: the generated `Runnir_Core_V1_JobSkip`, `Runnir_Core_V1_SkipKind`, `response.skips`, `response.sourceNote` (Task 3).
- Produces: `struct CoreJobSkip` (below); `CoreRunWorkflow.skips: [CoreJobSkip]`, `.sourceNote: String`, `func skip(for jobID: String) -> CoreJobSkip?`; `RunGraph.reason(_:)`, `.resultWord(_:)`, `.resultOutcome(_:)`, `.panelTitle(job:_:)`, `.panelSentence(_:)`, `.sourceLine(path:sha:note:)`, `.panelLeading(nodeMinX:columnsWidth:panelWidth:)`; `RunLayerModel.skipJobID: String?`, `toggleSkip(_:)`.

- [ ] **Step 1: Write the failing tests** (add to `RunGraphTests`)

```swift
    private func skip(_ kind: CoreJobSkip.Kind, need: String = "", result: String = "", note: String = "") -> CoreJobSkip {
        CoreJobSkip(jobID: "publish", kind: kind, need: need, needResult: result, condition: "github.event_name == 'pull_request'",
                    values: [.init(name: "github.event_name", value: "push")], unknown: [], note: note)
    }

    @Test func aSkippedNodeSaysWhy() {
        #expect(RunGraph.reason(skip(.needs, need: "build", result: "failure")) == "need failed")
        #expect(RunGraph.reason(skip(.needs, need: "build", result: "cancelled")) == "need cancelled")
        #expect(RunGraph.reason(skip(.needs, need: "build", result: "skipped")) == "need skipped")
        #expect(RunGraph.reason(skip(.conditionFalse)) == "condition false")
        #expect(RunGraph.reason(skip(.notKnown)) == "not known")
        #expect(RunGraph.reason(skip(.notInRun)) == "not in this run")
        #expect(RunGraph.resultOutcome("failure") == .failed && RunGraph.resultOutcome("cancelled") == .cancelled)
    }

    @Test func thePanelSaysWhyAndWhereItWasRead() {
        #expect(RunGraph.panelTitle(job: "publish", skip(.needs, need: "build", result: "failure")) == "Why publish was skipped")
        #expect(RunGraph.panelTitle(job: "preview", skip(.notInRun)) == "preview is not in this run")
        #expect(RunGraph.panelSentence(skip(.conditionFalse)) == "Its condition is false for this run.")
        #expect(RunGraph.panelSentence(skip(.notKnown)) == "Its condition reads something only the run knew, so Runnir cannot tell.")
        #expect(RunGraph.panelSentence(skip(.notKnown, note: "Runnir reads its condition as true.")) == "Runnir reads its condition as true.")
        #expect(RunGraph.sourceLine(path: ".github/workflows/ios-release.yml", sha: "a3f9c21dd", note: "")
                == "Read from ios-release.yml at a3f9c21, the file this run used.")
        #expect(RunGraph.sourceLine(path: ".github/workflows/ci.yml", sha: "a3f9c21dd", note: "GitHub ran this file merged with the base, which may differ.")
                == "Read from ci.yml at a3f9c21; GitHub ran this file merged with the base, which may differ.")
    }

    @Test func thePanelStaysUnderItsNodeAndInsideTheColumns() {
        #expect(RunGraph.panelLeading(nodeMinX: 0, columnsWidth: 596, panelWidth: 360) == 0)
        #expect(RunGraph.panelLeading(nodeMinX: 210, columnsWidth: 596, panelWidth: 360) == 210)
        #expect(RunGraph.panelLeading(nodeMinX: 420, columnsWidth: 596, panelWidth: 360) == 236, "the last column's panel ends with it")
        #expect(RunGraph.panelLeading(nodeMinX: 0, columnsWidth: 176, panelWidth: 360) == 0)
    }

    @Test func oneWhyPanelIsOpenAtATime() async {
        let model = RunLayerModel(hub: CoreHub(provider: FakeProvider()), workspaceID: UUID())
        model.show(run: 1)
        model.toggleSkip("docs")
        #expect(model.skipJobID == "docs")
        model.toggleSkip("publish")
        #expect(model.skipJobID == "publish", "another skipped node moves the panel there")
        model.toggleSkip("publish")
        #expect(model.skipJobID == nil, "the same node closes it")
        model.toggleSkip("docs")
        model.open(runJob(5, "build"))
        #expect(model.skipJobID == nil, "a job's log closes the panel")
        model.toggleSkip("docs")
        model.show(run: 2)
        #expect(model.skipJobID == nil)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run (with the PATH of Global Constraints): `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/RunGraphTests`
Expected: build failure, `cannot find type 'CoreJobSkip'`.

- [ ] **Step 3: The model.** In `CoreGitHubModels.swift`, add before `CoreRunWorkflow`:

```swift
/// Why a job of a run did not run, as the Core read it from the file at the
/// run's commit, the run and its jobs (B35).
struct CoreJobSkip: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case needs, conditionFalse, notKnown, notInRun }

    struct Value: Equatable, Sendable {
        let name: String
        let value: String
    }

    let jobID: String
    let kind: Kind
    /// For `.needs`: the job it needs that did not succeed, and its result
    /// ("failure", "cancelled" or "skipped").
    let need: String
    let needResult: String
    let condition: String
    /// What the condition read of the run, in the order it read it.
    let values: [Value]
    /// What the condition reads that Runnir does not know.
    let unknown: [String]
    let note: String
}
```

and in `CoreRunWorkflow`, after `problem`:

```swift
    /// Why each skipped job was skipped, and the jobs a finished run has no job for.
    var skips: [CoreJobSkip] = []
    /// Which file GitHub ran when it is not the one read; empty when it is.
    var sourceNote = ""

    func skip(for jobID: String) -> CoreJobSkip? { skips.first { $0.jobID == jobID } }
```

- [ ] **Step 4: The mapping.** In `GRPCCoreService.getRunWorkflow`, pass `skips: response.skips.compactMap(Self.map), sourceNote: response.sourceNote` to `CoreRunWorkflow(...)`, and add next to `static func map(_ job: Runnir_Core_V1_RunJob)`:

```swift
    static func map(_ skip: Runnir_Core_V1_JobSkip) -> CoreJobSkip? {
        let kind: CoreJobSkip.Kind
        switch skip.kind {
        case .needs: kind = .needs
        case .conditionFalse: kind = .conditionFalse
        case .notKnown: kind = .notKnown
        case .notInRun: kind = .notInRun
        default: return nil
        }
        return CoreJobSkip(jobID: skip.jobID, kind: kind, need: skip.need, needResult: skip.needResult, condition: skip.condition,
                           values: skip.values.map { .init(name: $0.name, value: $0.value) }, unknown: skip.unknown, note: skip.note)
    }
```

- [ ] **Step 5: The wording and the layer's panel.** In `RunGraphViews.swift`, add to `enum RunGraph` after `jobToOpen`:

```swift
    /// What a skipped node says in place of "skipped" (B35).
    static func reason(_ skip: CoreJobSkip) -> String {
        switch skip.kind {
        case .needs: "need \(resultWord(skip.needResult))"
        case .conditionFalse: "condition false"
        case .notKnown: "not known"
        case .notInRun: "not in this run"
        }
    }

    static func resultWord(_ result: String) -> String {
        switch result {
        case "failure": "failed"
        case "cancelled": "cancelled"
        default: "skipped"
        }
    }

    static func resultOutcome(_ result: String) -> CoreRunOutcome {
        switch result {
        case "failure": .failed
        case "cancelled": .cancelled
        default: .skipped
        }
    }

    static func panelTitle(job: String, _ skip: CoreJobSkip) -> String {
        skip.kind == .notInRun ? "\(job) is not in this run" : "Why \(job) was skipped"
    }

    static func panelSentence(_ skip: CoreJobSkip) -> String {
        switch skip.kind {
        case .needs: "A job it needs did not succeed, and its if has no status check, so GitHub held it back."
        case .conditionFalse: "Its condition is false for this run."
        case .notKnown: skip.note.isEmpty ? "Its condition reads something only the run knew, so Runnir cannot tell." : skip.note
        case .notInRun: "GitHub ran no job for it in this run."
        }
    }

    /// The panel's last line: which file and commit the reasons come from.
    static func sourceLine(path: String, sha: String, note: String) -> String {
        let file = URL(fileURLWithPath: path).lastPathComponent
        let commit = sha.prefix(7)
        return note.isEmpty ? "Read from \(file) at \(commit), the file this run used." : "Read from \(file) at \(commit); \(note)"
    }

    /// Where a node's panel starts: under the node, moved left so that it
    /// ends with the columns when the node is near their end.
    static func panelLeading(nodeMinX: CGFloat, columnsWidth: CGFloat, panelWidth: CGFloat) -> CGFloat {
        max(0, min(nodeMinX, columnsWidth - panelWidth))
    }
```

In `RunLayerModel`, after `var step: Int64?`:

```swift
    /// The skipped node whose panel is open, by its workflow job id (B35).
    var skipJobID: String?

    /// A click on a skipped node: opens its panel, moves it there from another
    /// node, or closes it when it is open there.
    func toggleSkip(_ id: String) {
        skipJobID = skipJobID == id ? nil : id
    }
```

and set `skipJobID = nil` in `show(run:)` (with the other resets) and in `open(_:step:)`.

- [ ] **Step 6: Read again when the run finishes.** In `RunInspectorView.swift`, replace the workflow task:

```swift
        // The workflow file is the file at the run's commit; it is asked for
        // again when the run finishes, for the reasons of its skipped jobs.
        .task(id: "\(run.id)-\(run.outcome.isActive)") {
            layer.show(run: run.id)
            let workflow = await hub.runWorkflow(workspaceID: workspaceID, runID: run.id)
            guard !Task.isCancelled, layer.runID == run.id else { return }
            layer.workflow = workflow
        }
```

- [ ] **Step 7: Run the tests**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/RunGraphTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add apps/macos/Runnir/IPC apps/macos/Runnir/Features/Desktop/RunGraphViews.swift apps/macos/Runnir/Features/Desktop/RunInspectorView.swift apps/macos/RunnirTests/RunGraphTests.swift
git commit -m "App: the run's skip reasons from the Core, their wording, and one why panel at a time (B35)"
```

### Task 5: The Reason On The Node And The Panel Under It

**Files:**
- Modify: `apps/macos/Runnir/Features/Desktop/RunGraphViews.swift`

**Interfaces:**
- Consumes: `CoreJobSkip`, `CoreRunWorkflow.skip(for:)`, `.sourceNote`, `RunGraph.reason`, `.resultWord`, `.resultOutcome`, `.panelTitle`, `.panelSentence`, `.sourceLine`, `.panelLeading`, `RunLayerModel.skipJobID`, `.toggleSkip` (Task 4).
- Produces: `struct SkippedJobPanel: View` with `static let width: CGFloat = 360`.

- [ ] **Step 1: The panel.** Add after `RunGraphView` in `RunGraphViews.swift`:

```swift
/// Why a job of the run did not run (B35): under its node, part of the
/// graph's layout, so nothing is drawn over it. Escape closes it.
struct SkippedJobPanel: View {
    static let width: CGFloat = 360

    let title: String
    let skip: CoreJobSkip
    let source: String
    let close: () -> Void
    @State private var escape: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: skip.kind == .notInRun ? "circle.dashed" : "forward.end.circle")
                    .font(.system(size: 13)).foregroundStyle(RunnirTheme.mutedForeground)
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(RunnirTheme.mutedForeground)
                        .frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.hit).help("Close").accessibilityLabel("Close")
            }
            Text(RunGraph.panelSentence(skip)).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                .fixedSize(horizontal: false, vertical: true)
            details
            Rectangle().fill(RunnirTheme.border).frame(height: 1)
            Text(source).font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(width: Self.width, alignment: .leading)
        .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(RunnirTheme.border))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 8)
        .onAppear(perform: watchEscape)
        .onDisappear(perform: stopWatching)
    }

    @ViewBuilder private var details: some View {
        switch skip.kind {
        case .needs:
            HStack(spacing: 8) {
                RunOutcomeIcon(outcome: RunGraph.resultOutcome(skip.needResult), size: 13)
                Text("needs \(skip.need)").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Text(RunGraph.resultWord(skip.needResult)).font(.system(size: 12))
                    .foregroundStyle(skip.needResult == "failure" ? RunnirTheme.destructive : RunnirTheme.secondaryForeground)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(RunnirTheme.editor, in: RoundedRectangle(cornerRadius: 6))
        case .conditionFalse, .notKnown:
            if !skip.condition.isEmpty {
                Text("if: \(skip.condition)").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RunnirTheme.editor, in: RoundedRectangle(cornerRadius: 6))
            }
            if skip.kind == .conditionFalse, !skip.values.isEmpty {
                names("This run had", skip.values.map { "\($0.name)  \($0.value)" })
            } else if skip.kind == .notKnown, !skip.unknown.isEmpty {
                names("Runnir does not know", skip.unknown)
            }
        case .notInRun:
            if !skip.note.isEmpty {
                Text(skip.note).font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func names(_ label: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(RunnirTheme.mutedForeground)
            ForEach(lines, id: \.self) { Text($0).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
        }
    }

    /// Escape closes the panel, not what is under it.
    private func watchEscape() {
        stopWatching()
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }
            MainActor.assumeIsolated { close() }
            return nil
        }
    }

    private func stopWatching() {
        if let escape { NSEvent.removeMonitor(escape) }
        escape = nil
    }
}
```

If the file does not import AppKit, add `import AppKit` at the top (NSEvent).

- [ ] **Step 2: The graph places it under its node.** In `RunGraphView`, add state and a coordinate space name:

```swift
    @State private var nodeMinX: [String: CGFloat] = [:]
    @State private var columnsWidth: CGFloat = 0
    private static let columnsSpace = "runGraphColumns"
```

Replace `graph(_:)` with:

```swift
    private func graph(_ layout: RunGraph.Layout) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 8) {
                ForEach(Array(layout.columns.enumerated()), id: \.offset) { index, column in
                    if index > 0 {
                        Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground)
                    }
                    VStack(spacing: 8) {
                        ForEach(column) { node in nodeButton(node) }
                    }
                }
            }
            .coordinateSpace(.named(Self.columnsSpace))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { columnsWidth = $0 }
            if let id = model.skipJobID, let workflow = model.workflow, let skip = workflow.skip(for: id),
               let node = layout.columns.joined().first(where: { $0.id == id }) {
                SkippedJobPanel(title: RunGraph.panelTitle(job: node.name, skip), skip: skip,
                                source: RunGraph.sourceLine(path: workflow.path, sha: run.headSHA, note: workflow.sourceNote),
                                close: { model.skipJobID = nil })
                    .padding(.leading, RunGraph.panelLeading(nodeMinX: nodeMinX[id] ?? 0, columnsWidth: columnsWidth,
                                                             panelWidth: SkippedJobPanel.width))
            }
            if !layout.others.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: "OTHER JOBS")
                    ForEach(layout.others) { job in jobNode(title: job.name, outcome: job.outcome, jobs: [job]) }
                }
            }
        }
    }
```

- [ ] **Step 3: The node says why and opens the panel.** Replace `nodeButton(_:)` and `jobNode(title:outcome:jobs:)` with:

```swift
    private func nodeButton(_ node: RunGraph.Node) -> some View {
        jobNode(title: node.title, outcome: node.outcome ?? RunGraph.absentOutcome(runActive: run.outcome.isActive), jobs: node.jobs,
                id: node.id, skip: model.workflow?.skip(for: node.id))
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(Self.columnsSpace)).minX } action: { nodeMinX[node.id] = $0 }
    }

    private func jobNode(title: String, outcome: CoreRunOutcome, jobs: [CoreRunJob], id: String? = nil, skip: CoreJobSkip? = nil) -> some View {
        let target = RunGraph.jobToOpen(jobs)
        let absent = skip?.kind == .notInRun
        let selected = (skip != nil && model.skipJobID == id) || (model.jobID != nil && jobs.contains { $0.id == model.jobID })
        return Button {
            if let id, skip != nil {
                model.toggleSkip(id)
            } else if let target {
                model.open(target)
            }
        } label: {
            HStack(spacing: 8) {
                if absent {
                    Image(systemName: "circle.dashed").font(.system(size: 13)).foregroundStyle(RunnirTheme.mutedForeground)
                } else {
                    RunOutcomeIcon(outcome: outcome, size: 14)
                }
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    .foregroundStyle(absent ? RunnirTheme.secondaryForeground : RunnirTheme.foreground)
                Spacer(minLength: 6)
                Text(skip.map(RunGraph.reason) ?? meta(outcome, jobs)).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
            }
            .padding(.horizontal, 12).frame(width: 220, height: 36)
            .background(absent ? Color.clear : RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? RunnirTheme.primary : (absent ? RunnirTheme.mutedForeground : outlineColor(outcome, selected: false)),
                                                              style: StrokeStyle(lineWidth: 1, dash: absent && !selected ? [4, 3] : [])))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.hit)
        .disabled(target == nil && skip == nil)
        .help(skip != nil ? "Why \(title) did not run" : (target == nil ? "This job has not started" : "Read the log of \(title)"))
        .accessibilityLabel(skip.map { "\(title), \(RunGraph.reason($0))" } ?? "\(title), \(outcome.label)")
        .contextMenu {
            if let target, !run.outcome.isActive, target.status == "completed" {
                Button("Re-run job") { Task { await model.actions.prepare(.rerunJob(id: target.id), for: run) } }
                    .disabled(model.actions.isBusy)
            }
        }
    }
```

`outlineColor(_:selected:)` keeps its body; it is now called with `selected: false` and the selection is decided above.

- [ ] **Step 3b: A run listed without its order says the reasons cannot be told.** In `flatList(_:)`, change the label's two texts to end with " Why jobs were skipped cannot be told either.":

```swift
                Label(workflow.problem.isEmpty
                      ? "Jobs are listed without their order: the workflow file could not be read at this commit. Why jobs were skipped cannot be told either."
                      : "Jobs are listed without their order. \(workflow.problem) Why jobs were skipped cannot be told either.", systemImage: "info.circle")
```

- [ ] **Step 4: Build and test**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build` then `... test -only-testing:RunnirTests`
Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **` (PointerCoverage passes: the panel's close button uses `.buttonStyle(.hit)`).

- [ ] **Step 5: Check against Pen.** Render the panel offscreen for the four states (a temporary test that writes `ImageRenderer(content: SkippedJobPanel(...)).nsImage` PNGs to the scratchpad), compare with the Pen frames of journey D (Row — Why a job was skipped (B35)), fix differences, then delete the temporary test. ImageRenderer does not draw `ScrollView`, so render the panel alone.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Runnir/Features/Desktop/RunGraphViews.swift
git commit -m "App: a skipped node says why, and a click opens the why panel under it (B35)"
```

### Task 6: Documents

**Files:**
- Modify: `docs/superpowers/specs/2026-10-27-why-a-job-was-skipped-design.md`, `docs/product/mvp-implementation-checklist.md`, `docs/design/screens-and-states.md`

- [ ] **Step 1: The spec's status.** Replace its `Status:` line with "Status: built (the Core's reasons in `GetRunWorkflow`, the reason on the node and the panel in the run graph), drawn in `runnir.pen` (journey D, Row — Why a job was skipped (B35)): option A, a panel on click, was chosen; a line under the node (B) and a list under the graph (C) were not. Not tried against real runs on GitHub."

- [ ] **Step 2: The checklist.** In `docs/product/mvp-implementation-checklist.md`, add after the B41 row of the implemented table: "| B35 | Why a job was skipped, in the run graph ([spec](../superpowers/specs/2026-10-27-why-a-job-was-skipped-design.md)): `GetRunWorkflow` explains each skipped job from the file at the run's commit, the run and its jobs (a need that did not succeed; a condition false for the run with the values it read; a condition Runnir cannot decide, shown as text with what it does not know) and marks the nodes a finished run has no job for as not in this run, saying which file GitHub ran for pull requests; a skipped node says its reason and a click opens the panel under it; covered by Core and app tests | Real runs on GitHub, in particular pull requests whose base changed the workflow |".

- [ ] **Step 3: Screens.** In `docs/design/screens-and-states.md`, in the S08 row: change "why a job was skipped (B35) and why a run stays queued (B36)" to "why a job was skipped: the reason on the node and a panel under it (built, B35), and why a run stays queued (B36)", and add to its states: "skipped node with its reason (need failed, condition false, not known), node not in this run, why panel open".

- [ ] **Step 4: Commit**

```bash
git add docs
git commit -m "Docs: why a job was skipped is built (B35)"
```

### Task 7: Final Verification And Pull Request

- [ ] **Step 1: Core.** Run (from `core/`): `go test ./... && go vet ./... && go build ./...` — Expected: every package `ok`, no vet output.
- [ ] **Step 2: App.** Run (with the Go PATH): `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build` — Expected: `** BUILD SUCCEEDED **`; then `... test -only-testing:RunnirTests` — Expected: `** TEST SUCCEEDED **`.
- [ ] **Step 3: Contracts.** Run `scripts/generate-contracts.sh` once more (with the plugins PATH) and `git status` — Expected: no changes.
- [ ] **Step 4: Push and open the pull request** (no AI attribution in the body):

```bash
git push -u origin dilbarov/why-skipped
gh pr create --base main --head dilbarov/why-skipped --title "Why a job was skipped, in the run graph (B35)" --body-file /path/to/body.md
```

The body: one paragraph on what the run graph now says (the reason on a skipped node, the panel under it, not in this run); one on the Core (`GetRunWorkflow` with `skips` and `source_note`, the run and jobs kept once the run is finished, local refs and the workspace's pull requests for the context); the B21 plan commit (README, SECURITY.md and the search entry added to its documents task); "Checked:" with the Core checks, the app build, RunnirTests and the offscreen render against Pen; "Not checked:" real runs on GitHub, pull requests whose base changed the workflow. Write it to the scratchpad, not the repository.
