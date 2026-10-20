package localrun

import (
	"errors"
	"strings"
	"testing"

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

func plan(t *testing.T, source, job, event string, report tools.Report, present func(string) bool) Plan {
	t.Helper()
	p, err := NewPlan(Request{WorkflowID: ".github/workflows/ci.yml", Source: []byte(source), JobID: job, Event: event}, report, false, present)
	if err != nil {
		t.Fatalf("NewPlan = %v", err)
	}
	return p
}

func TestWholeWorkflowPlan(t *testing.T) {
	p := plan(t, ciWorkflow, "", "", readyReport(), func(ref string) bool { return ref == "postgres:16" })
	if !p.Runnable() || p.Event != "push" || p.WorkflowName != "CI" || len(p.Events) != 2 {
		t.Fatalf("plan = %+v", p)
	}
	if len(p.Jobs) != 3 || p.Jobs[0].ID != "lint" || p.Jobs[1].ID != "unit-tests" || p.Jobs[2].ID != "build-ios" {
		t.Fatalf("jobs = %+v", p.Jobs)
	}
	if p.Jobs[0].Image != "catthehacker/ubuntu:act-latest" || p.Jobs[0].Support != Supported {
		t.Fatalf("lint = %+v", p.Jobs[0])
	}
	if p.Jobs[2].Support != Unsupported || p.Jobs[2].Reason != "Not supported locally: macOS runner" {
		t.Fatalf("build-ios = %+v", p.Jobs[2])
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
	if len(p.Secrets) != 1 || p.Secrets[0] != "NPM_TOKEN" {
		t.Fatalf("secrets = %v", p.Secrets)
	}
	notes := strings.Join(p.Notes, "\n")
	for _, want := range []string{"NPM_TOKEN", "linux/arm64", "service containers: db"} {
		if !strings.Contains(notes, want) {
			t.Fatalf("notes lack %q: %s", want, notes)
		}
	}
	if p.Limits.CPUs != 4 || p.Limits.MemoryBytes != DefaultMemoryBytes || p.Limits.Timeout != DefaultTimeout {
		t.Fatalf("limits = %+v", p.Limits)
	}
	if len(p.Digest) != 64 {
		t.Fatalf("digest = %q", p.Digest)
	}
}

func TestChosenJobBringsTheJobsItNeeds(t *testing.T) {
	p := plan(t, ciWorkflow, "unit-tests", "workflow_dispatch", readyReport(), nil)
	if len(p.Jobs) != 2 || p.Jobs[0].ID != "lint" || p.Jobs[1].ID != "unit-tests" || p.Event != "workflow_dispatch" || p.JobID != "unit-tests" {
		t.Fatalf("plan = %+v", p)
	}
}

func TestChoosingAnUnsupportedJobBlocksTheRun(t *testing.T) {
	p := plan(t, ciWorkflow, "build-ios", "", readyReport(), nil)
	if p.Runnable() || !strings.Contains(strings.Join(p.Blockers, " "), "Job build-ios can't run locally: not supported locally: macOS runner") {
		t.Fatalf("blockers = %v", p.Blockers)
	}
}

func TestUnknownJobAndEventAreErrors(t *testing.T) {
	report := readyReport()
	if _, err := NewPlan(Request{Source: []byte(ciWorkflow), JobID: "deploy"}, report, false, nil); !errors.Is(err, ErrUnknownJob) {
		t.Fatalf("job err = %v", err)
	}
	if _, err := NewPlan(Request{Source: []byte(ciWorkflow), Event: "release"}, report, false, nil); !errors.Is(err, ErrUnknownEvent) {
		t.Fatalf("event err = %v", err)
	}
}

func TestMissingToolsBlockTheRun(t *testing.T) {
	report := readyReport()
	report.Engine = tools.Engine{State: tools.Stopped, Name: "OrbStack", Local: true, Detail: "OrbStack is not running or does not answer."}
	p := plan(t, ciWorkflow, "lint", "", report, func(string) bool { t.Fatal("asked the engine for images"); return false })
	if p.Runnable() || p.Blockers[0] != "OrbStack is not running or does not answer." {
		t.Fatalf("blockers = %v", p.Blockers)
	}

	report = readyReport()
	report.BundledAct = tools.Tool{State: tools.Missing, Detail: "This build of Runnir has no bundled act."}
	p = plan(t, ciWorkflow, "lint", "", report, nil)
	if p.Runnable() || p.Blockers[0] != "act is not available: this build of Runnir has no bundled act." {
		t.Fatalf("blockers = %v", p.Blockers)
	}

	report = readyReport()
	report.Engine.Local = false
	p = plan(t, ciWorkflow, "lint", "", report, nil)
	if p.Runnable() {
		t.Fatal("a remote engine was accepted")
	}
}

func TestSyntaxErrorsBlockTheRun(t *testing.T) {
	p := plan(t, "on: push\njobs:\n  a:\n    runs-on: [\n", "", "", readyReport(), nil)
	if p.Runnable() || !strings.Contains(p.Blockers[0], "syntax error") {
		t.Fatalf("blockers = %v", p.Blockers)
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
	p := plan(t, source, "", "", readyReport(), nil)
	byID := map[string]JobPlan{}
	for _, job := range p.Jobs {
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
	limits := LimitsFor(tools.Engine{CPUs: 2, MemoryBytes: 4 << 30})
	if limits.CPUs != 2 || limits.MemoryBytes != 4<<30 {
		t.Fatalf("limits = %+v", limits)
	}
	limits = LimitsFor(tools.Engine{})
	if limits.CPUs != DefaultCPUs || limits.MemoryBytes != DefaultMemoryBytes {
		t.Fatalf("limits = %+v", limits)
	}
}
