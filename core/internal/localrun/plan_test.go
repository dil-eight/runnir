package localrun

import (
	"errors"
	"slices"
	"strings"
	"testing"

	"runnir/core/internal/flow"
	"runnir/core/internal/tools"
)

func readyReport() tools.Report {
	return tools.Report{
		BundledAct:   tools.Tool{State: tools.Found, Version: "0.2.89", Path: "/App/Helpers/act"},
		InstalledAct: tools.Tool{State: tools.Missing},
		DockerCLI:    tools.Tool{State: tools.Found, Version: "29.0.1", Path: "/usr/local/bin/docker"},
		Engine:       tools.Engine{State: tools.Found, Name: "OrbStack", Local: true, Architecture: "aarch64", CPUs: 10, MemoryBytes: 16 << 30},
	}
}

const ciWorkflow = `name: CI
on:
  push:
  workflow_dispatch:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: echo ${{ secrets.NPM_TOKEN }}
  unit-tests:
    needs: lint
    runs-on: ubuntu-22.04
    services:
      db:
        image: postgres:16
    steps:
      - uses: docker://alpine:3.20
  build-ios:
    needs: unit-tests
    runs-on: macos-latest
    steps:
      - run: xcodebuild
`

// plan plans ciWorkflow-like source as the one lane of a push: every job
// the scenario runs, or the job given and what it needs.
func plan(t *testing.T, source, job string, report tools.Report, present func(string) bool) Plan {
	t.Helper()
	lane := LaneInput{WorkflowID: ".github/workflows/ci.yml", Source: []byte(source), Kind: Direct, Event: "push", Why: "push"}
	request := Request{Scenario: flow.Scenario{Kind: flow.Push, Target: "main"}, Lanes: []LaneInput{lane}}
	if job != "" {
		request.Lanes[0].Selected, request.Chosen = []string{job}, true
	}
	p, err := NewPlan(request, report, false, present, Choose(nil, CeilingFor(report.Engine)))
	if err != nil {
		t.Fatalf("NewPlan = %v", err)
	}
	return p
}

// selected lists the ticked jobs of a lane.
func selected(lane Lane) []string {
	var ids []string
	for _, job := range lane.Jobs {
		if job.Selected {
			ids = append(ids, job.ID)
		}
	}
	return ids
}

func TestWholeWorkflowPlan(t *testing.T) {
	p := plan(t, ciWorkflow, "", readyReport(), func(ref string) bool { return ref == "postgres:16" })
	lane := p.Lanes[0]
	if !p.Runnable() || lane.Event != "push" || lane.WorkflowName != "CI" || !lane.Dispatchable {
		t.Fatalf("plan = %+v", p)
	}
	if len(lane.Jobs) != 3 || lane.Jobs[0].ID != "lint" || lane.Jobs[1].ID != "unit-tests" || lane.Jobs[2].ID != "build-ios" {
		t.Fatalf("jobs = %+v", lane.Jobs)
	}
	if !slices.Equal(lane.Jobs[1].Needs, []string{"lint"}) {
		t.Fatalf("needs = %v", lane.Jobs[1].Needs)
	}
	if lane.Jobs[0].Image != "catthehacker/ubuntu:act-latest" || lane.Jobs[0].Support != Supported {
		t.Fatalf("lint = %+v", lane.Jobs[0])
	}
	if lane.Jobs[2].Support != Unsupported || lane.Jobs[2].Reason != "Not supported locally: macOS runner" {
		t.Fatalf("build-ios = %+v", lane.Jobs[2])
	}
	// A job no local image runs is not ticked by default.
	if !slices.Equal(selected(lane), []string{"lint", "unit-tests"}) {
		t.Fatalf("ticked = %v", selected(lane))
	}
	images := map[string]bool{}
	for _, image := range p.Images {
		images[image.Ref] = image.Present
	}
	want := map[string]bool{"catthehacker/ubuntu:act-latest": false, "catthehacker/ubuntu:act-22.04": false, "postgres:16": true, "alpine:3.20": false}
	if len(images) != len(want) {
		t.Fatalf("images = %+v", p.Images)
	}
	for ref, present := range want {
		if got, ok := images[ref]; !ok || got != present {
			t.Fatalf("image %s = %v %v", ref, got, ok)
		}
	}
	if !slices.Equal(p.Secrets, []string{"NPM_TOKEN"}) || len(p.Variables) != 0 || p.UnnamedSecrets {
		t.Fatalf("secrets = %v variables = %v unnamed = %v", p.Secrets, p.Variables, p.UnnamedSecrets)
	}
	notes := strings.Join(p.Notes, "\n")
	for _, want := range []string{"linux/arm64", "service containers: db"} {
		if !strings.Contains(notes, want) {
			t.Fatalf("notes lack %q: %s", want, notes)
		}
	}
	if p.Limits.CPUs != 4 || p.Limits.MemoryBytes != DefaultMemoryBytes || p.Limits.Timeout != DefaultTimeout {
		t.Fatalf("limits = %+v", p.Limits)
	}
	if len(lane.Digest) != 64 || strings.Contains(string(lane.Copy), "build-ios") || !strings.Contains(string(lane.Copy), "unit-tests") {
		t.Fatalf("digest = %q copy = %s", lane.Digest, lane.Copy)
	}
}

func TestTickedJobBringsTheJobsItNeeds(t *testing.T) {
	p := plan(t, ciWorkflow, "unit-tests", readyReport(), nil)
	if got := selected(p.Lanes[0]); !slices.Equal(got, []string{"lint", "unit-tests"}) {
		t.Fatalf("ticked = %v", got)
	}
	if !strings.Contains(string(p.Lanes[0].Copy), "lint:") || strings.Contains(string(p.Lanes[0].Copy), "build-ios") {
		t.Fatalf("copy = %s", p.Lanes[0].Copy)
	}
}

func TestTickingOnlyAJobThatCannotRunHereBlocksTheRun(t *testing.T) {
	source := "on: push\njobs:\n  ios:\n    runs-on: macos-latest\n    steps: [{run: x}]\n"
	p := plan(t, source, "ios", readyReport(), nil)
	if p.Runnable() || !slices.Contains(p.Blockers, "None of the ticked jobs can run locally.") {
		t.Fatalf("blockers = %v", p.Blockers)
	}
}

func TestUnknownJobIsAnError(t *testing.T) {
	request := Request{Chosen: true, Lanes: []LaneInput{{WorkflowID: "ci.yml", Source: []byte(ciWorkflow), Kind: Direct, Event: "push", Selected: []string{"deploy"}}}}
	if _, err := NewPlan(request, readyReport(), false, nil, Limits{}); !errors.Is(err, ErrUnknownJob) {
		t.Fatalf("job err = %v", err)
	}
}

func TestScenarioLanesAreTickedAndTheOthersAreNot(t *testing.T) {
	deploy := "name: Deploy\non: workflow_dispatch\njobs:\n  ship:\n    runs-on: ubuntu-latest\n    steps: [{run: x}]\n"
	release := "on:\n  push:\n    tags: [v*]\njobs:\n  publish:\n    runs-on: ubuntu-latest\n    steps: [{run: x}]\n"
	notify := "on:\n  workflow_run:\n    workflows: [CI]\njobs:\n  tell:\n    runs-on: ubuntu-latest\n    steps: [{run: x}]\n"
	skippedJob := "on: push\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps: [{run: x}]\n  deploy:\n    needs: build\n    if: github.ref == 'refs/heads/main'\n    runs-on: ubuntu-latest\n    steps: [{run: x}]\n"
	request := Request{Scenario: flow.Scenario{Kind: flow.PullRequest, Target: "main"}, Lanes: []LaneInput{
		{WorkflowID: "ci.yml", Source: []byte(skippedJob), Kind: Direct, Event: "pull_request", Order: []string{"build", "deploy"},
			JobSkipped: map[string]string{"deploy": "if: github.ref == 'refs/heads/main' is false"}},
		{WorkflowID: "notify.yml", Source: []byte(notify), Kind: Chained, Event: "workflow_run", After: "ci.yml"},
		{WorkflowID: "deploy.yml", Source: []byte(deploy), Kind: Manual, Event: "workflow_dispatch"},
		{WorkflowID: "release.yml", Source: []byte(release), Kind: Outside, Event: "push", Skipped: "runs on tag pushes"},
	}}
	p, err := NewPlan(request, readyReport(), false, nil, Limits{})
	if err != nil {
		t.Fatal(err)
	}
	if got := selected(p.Lanes[0]); !slices.Equal(got, []string{"build"}) || p.Lanes[0].Jobs[1].Skipped == "" {
		t.Fatalf("ci = %v %+v", got, p.Lanes[0].Jobs)
	}
	if !p.Lanes[1].Selected() || p.Lanes[2].Selected() || p.Lanes[3].Selected() {
		t.Fatalf("lanes = %+v", p.Lanes)
	}
	if got := p.Selected(); len(got) != 2 || got[1].WorkflowID != "notify.yml" || got[1].After != "ci.yml" {
		t.Fatalf("selected = %+v", got)
	}
	if p.Lanes[3].Skipped != "runs on tag pushes" || p.Lanes[3].Copy != nil {
		t.Fatalf("release = %+v", p.Lanes[3])
	}

	// Ticks the user chose replace the default: a lane outside the scenario
	// runs, a lane without ticks does not.
	request.Chosen = true
	request.Lanes[3].Selected = []string{"publish"}
	if p, err = NewPlan(request, readyReport(), false, nil, Limits{}); err != nil {
		t.Fatal(err)
	}
	if got := p.Selected(); len(got) != 1 || got[0].WorkflowID != "release.yml" {
		t.Fatalf("selected = %+v", got)
	}
	request.Lanes[3].Selected = nil
	if p, _ = NewPlan(request, readyReport(), false, nil, Limits{}); p.Runnable() || !slices.Contains(p.Blockers, "Tick at least one job to run.") {
		t.Fatalf("blockers = %v", p.Blockers)
	}
}

func TestALaneThatDoesNotParseIsNotTicked(t *testing.T) {
	request := Request{Lanes: []LaneInput{
		{WorkflowID: "broken.yml", Source: []byte("on: push\njobs:\n  a:\n    runs-on: [\n"), Kind: Direct, Event: "push"},
		{WorkflowID: "ci.yml", Source: []byte(ciWorkflow), Kind: Direct, Event: "push"},
	}}
	p, err := NewPlan(request, readyReport(), false, nil, Limits{})
	if err != nil {
		t.Fatal(err)
	}
	if p.Lanes[0].Selected() || !strings.Contains(p.Lanes[0].ParseError, "syntax error") || !p.Runnable() {
		t.Fatalf("plan = %+v", p)
	}
	if !slices.Contains(p.Notes, "broken.yml cannot run: fix the syntax errors in the Workspace first.") {
		t.Fatalf("notes = %v", p.Notes)
	}
}

func TestMissingToolsBlockTheRun(t *testing.T) {
	report := readyReport()
	report.Engine = tools.Engine{State: tools.Stopped, Name: "OrbStack", Local: true, Detail: "OrbStack is not running or does not answer."}
	p := plan(t, ciWorkflow, "lint", report, func(string) bool { t.Fatal("asked the engine for images"); return false })
	if p.Runnable() || p.Blockers[0] != "OrbStack is not running or does not answer." {
		t.Fatalf("blockers = %v", p.Blockers)
	}

	report = readyReport()
	report.BundledAct = tools.Tool{State: tools.Missing, Detail: "This build of Runnir has no bundled act."}
	p = plan(t, ciWorkflow, "lint", report, nil)
	if p.Runnable() || p.Blockers[0] != "act is not available: this build of Runnir has no bundled act." {
		t.Fatalf("blockers = %v", p.Blockers)
	}

	report = readyReport()
	report.Engine.Local = false
	p = plan(t, ciWorkflow, "lint", report, nil)
	if p.Runnable() {
		t.Fatal("a remote engine was accepted")
	}
}

func TestRunnerKinds(t *testing.T) {
	source := `on: push
jobs:
  matrix:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    steps: [{run: echo}]
  selfhosted:
    runs-on: [self-hosted, linux]
    steps: [{run: echo}]
  windows:
    runs-on: windows-latest
    steps: [{run: echo}]
  container:
    runs-on: ubuntu-latest
    container:
      image: node:22
      options: --cpus 1
    steps: [{run: echo}]
  reusable:
    uses: ./.github/workflows/other.yml
`
	p := plan(t, source, "", readyReport(), nil)
	byID := map[string]JobPlan{}
	for _, job := range p.Lanes[0].Jobs {
		byID[job.ID] = job
	}
	for id, want := range map[string]Support{"matrix": Unknown, "selfhosted": Unsupported, "windows": Unsupported, "container": Supported, "reusable": Unknown} {
		if byID[id].Support != want {
			t.Errorf("%s = %+v, want support %v", id, byID[id], want)
		}
	}
	if byID["container"].Image != "node:22" {
		t.Errorf("container image = %q", byID["container"].Image)
	}
	if !strings.Contains(strings.Join(p.Notes, " "), "container runs in its own container image") {
		t.Errorf("notes = %v", p.Notes)
	}
}

func TestLimitsFollowTheEngine(t *testing.T) {
	limits := Choose(nil, CeilingFor(tools.Engine{CPUs: 2, MemoryBytes: 4 << 30}))
	if limits.CPUs != 2 || limits.MemoryBytes != 4<<30 {
		t.Fatalf("limits = %+v", limits)
	}
	limits = Choose(nil, CeilingFor(tools.Engine{}))
	if limits.CPUs != DefaultCPUs || limits.MemoryBytes != DefaultMemoryBytes {
		t.Fatalf("limits = %+v", limits)
	}
}

// A lane's event reaches act's command line, so a workflow cannot smuggle
// flags in through it.
func TestOddEventNamesNeverReachAct(t *testing.T) {
	request := Request{Lanes: []LaneInput{{WorkflowID: "ci.yml", Source: []byte(ciWorkflow), Kind: Direct, Event: "--bind"}}}
	p, err := NewPlan(request, readyReport(), false, nil, Limits{})
	if err != nil || p.Runnable() || !slices.Contains(p.Blockers, "ci.yml has no event act can run it with.") {
		t.Fatalf("plan = %v, %v", p.Blockers, err)
	}
}

func TestTickedJobsAreFoundWhateverTheirCase(t *testing.T) {
	source := "on: push\njobs:\n  Lint:\n    runs-on: ubuntu-latest\n    steps: [{run: echo}]\n"
	p := plan(t, source, "lint", readyReport(), nil)
	if p.Lanes[0].Jobs[0].ID != "Lint" || !p.Lanes[0].Jobs[0].Selected || !p.Runnable() {
		t.Fatalf("jobs = %+v blockers = %v", p.Lanes[0].Jobs, p.Blockers)
	}
}

func TestPlanNotesSecretsReadAsAWhole(t *testing.T) {
	source := "on: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo '${{ toJSON(secrets) }}' ${{ vars.stage }}\n"
	p := plan(t, source, "", readyReport(), nil)
	if !p.UnnamedSecrets || !slices.Equal(p.Variables, []string{"STAGE"}) {
		t.Fatalf("plan = %+v", p)
	}
	if !slices.Contains(p.Notes, "A workflow of this run reads secrets it does not name; only the listed ones are passed.") {
		t.Fatalf("notes = %v", p.Notes)
	}
}

func TestPlanTakesTheEnvironmentOfItsJobs(t *testing.T) {
	source := `on: [push, workflow_dispatch]
jobs:
  build: {runs-on: ubuntu-latest, steps: [{run: x}]}
  staging:
    environment: staging
    runs-on: ubuntu-latest
    steps: [{run: x}]
  production:
    needs: build
    environment: {name: production}
    runs-on: ubuntu-latest
    steps: [{run: x}]
`
	sameValues := "act gives every job of this run the same values: production's, then the Repository's."
	if p := plan(t, source, "production", readyReport(), nil); p.Environment != "production" || !slices.Contains(p.Notes, sameValues) {
		t.Fatalf("production = %q, notes %v", p.Environment, p.Notes)
	}
	if p := plan(t, source, "staging", readyReport(), nil); p.Environment != "staging" || len(p.Notes) != 1 {
		t.Fatalf("staging = %q, notes %v", p.Environment, p.Notes)
	}
	if p := plan(t, source, "build", readyReport(), nil); p.Environment != "" || len(p.Notes) != 1 {
		t.Fatalf("build = %q, notes %v", p.Environment, p.Notes)
	}
	whole := plan(t, source, "", readyReport(), nil)
	if whole.Environment != "" || whole.EnvironmentChoice != "Jobs of this run deploy to production and staging, and act gives every job the same values." {
		t.Fatalf("whole = %q, choice %q", whole.Environment, whole.EnvironmentChoice)
	}

	picked := strings.Replace(source, "environment: staging", "environment: ${{ inputs.target }}", 1)
	if p := plan(t, picked, "staging", readyReport(), nil); p.Environment != "" ||
		p.EnvironmentChoice != "staging picks its environment with an expression, known only when it runs." {
		t.Fatalf("picked = %q, choice %q", p.Environment, p.EnvironmentChoice)
	}
	// An expression leaves the choice to the user even beside a named environment.
	if p := plan(t, picked, "", readyReport(), nil); p.Environment != "" ||
		p.EnvironmentChoice != "staging picks its environment with an expression, known only when it runs." {
		t.Fatalf("picked whole = %q, choice %q", p.Environment, p.EnvironmentChoice)
	}
	both := strings.Replace(picked, "environment: {name: production}", "environment: {name: '${{ inputs.target }}'}", 1)
	if p := plan(t, both, "", readyReport(), nil); p.EnvironmentChoice != "production and staging pick their environment with an expression, known only when they run." {
		t.Fatalf("both = %q", p.EnvironmentChoice)
	}
}

func TestMacJobsRunOnThisMacOnlyWhenTicked(t *testing.T) {
	defer func(saved string) { hostOS = saved }(hostOS)
	source := `on: push
jobs:
  lint:
    runs-on: ubuntu-latest
    steps: [{run: echo}]
  app:
    needs: lint
    runs-on: macos-26
    steps:
      - run: sudo xcode-select -s /Applications/Xcode.app
      - run: xcodebuild build
  odd:
    runs-on: [macos-latest, --privileged]
    steps: [{run: echo}]
`
	hostOS = "linux"
	if p := plan(t, source, "", readyReport(), nil); p.Lanes[0].Jobs[1].Support != Unsupported {
		t.Fatalf("on Linux, app = %+v", p.Lanes[0].Jobs[1])
	}

	hostOS = "darwin"
	p := plan(t, source, "", readyReport(), nil)
	app := p.Lanes[0].Jobs[1]
	if app.Support != Host || app.Selected || len(p.HostJobs) != 0 || len(p.Lanes[0].HostLabels) != 0 {
		t.Fatalf("a Mac job is never ticked by default: %+v %v", app, p.HostJobs)
	}
	p = plan(t, source, "app", readyReport(), nil)
	if !slices.Equal(p.HostJobs, []string{"ci.yml › app"}) || !slices.Equal(p.Lanes[0].HostLabels, []string{"macos-26"}) || !p.Runnable() {
		t.Fatalf("host jobs = %v labels = %v blockers = %v", p.HostJobs, p.Lanes[0].HostLabels, p.Blockers)
	}
	if !slices.ContainsFunc(p.Notes, func(note string) bool { return strings.HasPrefix(note, "app runs sudo.") }) ||
		slices.ContainsFunc(p.Notes, func(note string) bool { return strings.Contains(note, "xcodebuild test") }) {
		t.Fatalf("notes = %v", p.Notes)
	}
	tested := strings.Replace(source, "      - run: xcodebuild build\n", "      - run: xcodebuild build\n      - run: xcodebuild -scheme App -destination 'platform=macOS' test -only-testing:AppTests\n", 1)
	if p := plan(t, tested, "app", readyReport(), nil); !slices.ContainsFunc(p.Notes, func(note string) bool { return strings.HasPrefix(note, "app runs xcodebuild test,") }) {
		t.Fatalf("notes = %v", p.Notes)
	}
	// A label in another shape never reaches act's command line.
	p = plan(t, source, "odd", readyReport(), nil)
	if !slices.Equal(p.Lanes[0].HostLabels, []string{"macos-latest"}) {
		t.Fatalf("labels = %v", p.Lanes[0].HostLabels)
	}

	saved := SandboxExec
	SandboxExec = "/nonexistent/sandbox-exec"
	defer func() { SandboxExec = saved }()
	if p := plan(t, source, "app", readyReport(), nil); p.Runnable() {
		t.Fatal("a Mac job ran without the sandbox")
	}
}
