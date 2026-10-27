package flow

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

func TestGitHubFilterPatterns(t *testing.T) {
	cases := []struct {
		pattern, value string
		want           bool
	}{
		{"main", "main", true}, {"main", "mainline", false},
		{"feature/*", "feature/login", true}, {"feature/*", "feature/a/b", false},
		{"feature/**", "feature/a/b", true}, {"**", "anything/at/all", true},
		{"v[12].*", "v1.4", true}, {"v[12].*", "v3.0", false},
		{"apps/**", "apps/macos/Runnir/App.swift", true}, {"apps/**", "core/main.go", false},
		{"**.go", "core/internal/x.go", true}, {"*.md", "docs/a.md", false},
		{"v2?.0", "v.0", true}, {"v2?.0", "v2.0", true}, {"ab+c", "abbbc", true},
		{"release.1", "releaseX1", false},
		{"releases/**-alpha", "releases/beta/3-alpha", true},
		{"v[12].[0-9]+.[0-9]+", "v1.10.1", true}, {"v[12].[0-9]+.[0-9]+", "v3.1.1", false},
		{"v2*", "v2", true}, {"v1.?", "v1.", true}, {"v1.?", "v1", true},
		{"*.js", "js/app.js", false}, {"**.js", "js/app.js", true},
		{`\*`, "*", true}, {`\*`, "a", false}, {`docs/\*\*`, "docs/**", true}, {`docs/\*\*`, "docs/a", false},
		{"a+", "aaa", true}, {"ab+", "a", false}, {"[", "[", true},
	}
	for _, c := range cases {
		if got := globMatch(c.pattern, c.value); got != c.want {
			t.Errorf("%q ~ %q = %v, want %v", c.pattern, c.value, got, c.want)
		}
	}
	if in, by := decide([]string{"release/**", "!release/old/**"}, "release/old/1"); in || by != "!release/old/**" {
		t.Fatalf("the last pattern decides: %v %q", in, by)
	}
	again := []string{"releases/**", "!releases/**-alpha", "releases/keep-alpha"}
	for value, want := range map[string]bool{"releases/1": true, "releases/1-alpha": false, "releases/keep-alpha": true, "main": false} {
		if in, _ := decide(again, value); in != want {
			t.Errorf("a later pattern takes %q back: %v, want %v", value, in, want)
		}
	}
	for name, want := range map[string]bool{"main": true, "feature/x-1.2": true, "release/*": false, "v[0-9]": false, "!old": false, "": false} {
		if literalName(name) != want {
			t.Errorf("literalName(%q) = %v", name, !want)
		}
	}
	if ok, _, reason := refFilter([]string{"main"}, nil, "dev", "branch"); ok || reason != "branch dev does not match main" {
		t.Fatalf("reason = %q", reason)
	}
	if ok, _, reason := refFilter(nil, []string{"docs/**"}, "docs/x", "branch"); ok || reason != "branches-ignore docs/**" {
		t.Fatalf("ignore reason = %q", reason)
	}
	if ok, reason := pathFilter(nil, []string{"**.md"}, []string{"README.md", "docs/a.md"}); ok || !strings.Contains(reason, "every changed file") {
		t.Fatalf("paths-ignore = %v %q", ok, reason)
	}
}

func TestConditionsReadWhatTheScenarioKnows(t *testing.T) {
	pr := Context{"github.event_name": "pull_request", "github.ref": "refs/pull/0/merge", "github.head_ref": "Release/2.0",
		"github.base_ref": "main", "github.event.pull_request.draft": false}
	cases := map[string]Truth{
		"github.event_name == 'push'":                                             False,
		"${{ github.event_name == 'pull_request' }}":                              True,
		"github.event_name == 'pull_request' && !github.event.pull_request.draft": True,
		"startsWith(github.ref, 'refs/tags/')":                                    False,
		"contains(github.head_ref, 'release')":                                    True,
		"needs.build.result == 'success'":                                         Unknown,
		"always()":                                                                True,
		"success() && github.event_name == 'push'":                                False,
		"failure()": Unknown,
		"github.event_name == 'push' || inputs.force":         Unknown,
		"github.event_name == 'pull_request' || inputs.force": True,
		"format('{0}-{1}', 'a', 'b') == 'A-B'":                True,
		"1 < 2 && null == false":                              True, // GitHub compares null and false as numbers: 0 == 0
		"github.event['x']":                                   Unknown,
		"github.event_name == ":                               Unknown,
		// GitHub compares strings ignoring case.
		"github.event_name == 'PULL_REQUEST'":                               True,
		"github.event_name != 'push'":                                       True,
		"endsWith(github.ref, '/merge')":                                    True,
		"github.event.pull_request.draft == false":                          True,
		"github.repository == 'o/r'":                                        Unknown,
		"github.repository == 'o/r' && github.event_name == 'push'":         False,
		"github.repository == 'o/r' || github.event_name == 'pull_request'": True,
		"!cancelled()": Unknown,
		"github.event['pull_request'].draft == false":                                    True,
		"github['event_name'] == 'pull_request'":                                         True,
		"format('{0}/{1}', github.base_ref, 'x') == 'main/x'":                            True,
		"github.event_name == 'workflow_dispatch' && inputs.environment == 'production'": False,
		"vars.ENABLED == 'true'":                                                         Unknown,
		"'' ":                                                                            False,
		"(":                                                                              Unknown,
	}
	for condition, want := range cases {
		if got := Evaluate(condition, pr); got != want {
			t.Errorf("%q = %v, want %v", condition, got, want)
		}
	}
}

func TestMatrixSizes(t *testing.T) {
	file := func(matrix string) int {
		w := Parse(".github/workflows/m.yml", []byte("on: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n    strategy:\n      matrix:\n"+matrix+"    steps: [{run: x}]\n"))
		return w.Jobs[0].Matrix
	}
	if n := file("        os: [ubuntu, macos]\n        node: [18, 20, 22]\n"); n != 6 {
		t.Fatalf("product = %d", n)
	}
	if n := file("        os: [ubuntu, macos]\n        node: [18, 20]\n        exclude:\n          - os: macos\n            node: 18\n"); n != 3 {
		t.Fatalf("exclude = %d", n)
	}
	if n := file("        os: [ubuntu]\n        include:\n          - os: ubuntu\n            extra: x\n          - os: windows\n"); n != 2 {
		t.Fatalf("include = %d", n)
	}
	if n := file("        ${{ fromJSON(needs.plan.outputs.matrix) }}\n"); n != -1 {
		t.Fatalf("dynamic = %d", n)
	}
	if n := file("        os: [a, b]\n        go: [1, 2]\n        include:\n          - os: a\n            x: y\n"); n != 4 {
		t.Fatalf("an include that extends a combination = %d", n)
	}
	if n := file("        include:\n          - os: a\n          - os: b\n"); n != 2 {
		t.Fatalf("include alone = %d", n)
	}
	if n := file("        os: '${{ fromJSON(needs.plan.outputs.os) }}'\n"); n != -1 {
		t.Fatalf("a dynamic dimension = %d", n)
	}
}

func TestTriggersKeepTheirFilters(t *testing.T) {
	w := Parse(".github/workflows/ci.yml", []byte(`name: CI
on:
  push:
    branches: [main, 'release/**']
    tags: ['v*']
  pull_request:
    types: [opened, synchronize]
    paths-ignore: ['docs/**']
  workflow_run:
    workflows: [Build]
    types: [completed]
  schedule:
    - cron: '0 3 * * *'
  workflow_dispatch:
jobs:
  a: {runs-on: ubuntu-latest, steps: [{run: x}]}
`))
	if w.ParseError != "" || w.Name != "CI" {
		t.Fatalf("w = %+v", w)
	}
	push := w.Events["push"]
	if !reflect.DeepEqual(push.Branches, []string{"main", "release/**"}) || !reflect.DeepEqual(push.Tags, []string{"v*"}) ||
		push.Paths != nil || push.BranchesIgnore != nil {
		t.Fatalf("push = %+v", push)
	}
	if pr := w.Events["pull_request"]; !reflect.DeepEqual(pr.Types, []string{"opened", "synchronize"}) || !reflect.DeepEqual(pr.PathsIgnore, []string{"docs/**"}) {
		t.Fatalf("pull_request = %+v", pr)
	}
	if run := w.Events["workflow_run"]; !reflect.DeepEqual(run.Workflows, []string{"Build"}) {
		t.Fatalf("workflow_run = %+v", run)
	}
	for _, name := range []string{"schedule", "workflow_dispatch"} {
		if _, ok := w.Events[name]; !ok {
			t.Fatalf("no %s", name)
		}
	}
	for source, want := range map[string][]string{
		"on: push\n":                            {"push"},
		"on: [push, pull_request]\n":            {"pull_request", "push"},
		"on: {release: {types: [published]}}\n": {"release"},
	} {
		w := Parse(".github/workflows/x.yml", []byte(source+"jobs: {a: {runs-on: x, steps: [{run: x}]}}\n"))
		var got []string
		for name := range w.Events {
			got = append(got, name)
		}
		sort.Strings(got)
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%q: events %v", source, got)
		}
	}
}

func TestJobsKeepFileOrderNeedsEnvironmentsAndCalls(t *testing.T) {
	w := Parse(".github/workflows/ci.yml", []byte(`on: push
jobs:
  test:
    name: Test
    needs: lint
    if: ${{ github.event_name == 'push' }}
    runs-on: ubuntu-latest
    steps: [{run: x}]
  lint: {runs-on: ubuntu-latest, steps: [{run: x}]}
  deploy:
    needs: [test, lint]
    environment: production
    runs-on: ubuntu-latest
    steps: [{run: x}]
  docs:
    uses: ./.github/workflows/docs.yml
  preview:
    environment: {name: preview, url: 'https://example.com'}
    runs-on: ubuntu-latest
    steps: [{run: x}]
`))
	var ids []string
	for _, j := range w.Jobs {
		ids = append(ids, j.ID)
	}
	if w.ParseError != "" || !reflect.DeepEqual(ids, []string{"test", "lint", "deploy", "docs", "preview"}) {
		t.Fatalf("jobs = %v, %q", ids, w.ParseError)
	}
	if test := w.Jobs[0]; test.Name != "Test" || !reflect.DeepEqual(test.Needs, []string{"lint"}) || test.If != "github.event_name == 'push'" {
		t.Fatalf("test = %+v", test)
	}
	if deploy := w.Jobs[2]; deploy.Environment != "production" || !reflect.DeepEqual(deploy.Needs, []string{"test", "lint"}) {
		t.Fatalf("deploy = %+v", deploy)
	}
	if w.Jobs[3].Uses != "./.github/workflows/docs.yml" || w.Jobs[4].Environment != "preview" {
		t.Fatalf("docs, preview = %+v, %+v", w.Jobs[3], w.Jobs[4])
	}
}

// files is a repository like the one drawn on the Overview.
var files = map[string]string{
	".github/workflows/ci.yml": `name: CI
on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
jobs:
  lint: {runs-on: ubuntu-latest, steps: [{run: x}]}
  unit-tests: {runs-on: ubuntu-latest, steps: [{run: x}]}
  build:
    needs: [lint, unit-tests]
    runs-on: ubuntu-latest
    steps: [{run: x}]
  publish:
    if: github.event_name == 'push'
    needs: build
    runs-on: ubuntu-latest
    steps: [{run: x}]
  announce:
    needs: publish
    runs-on: ubuntu-latest
    steps: [{run: x}]
`,
	".github/workflows/core.yml": `name: Go Core
on:
  pull_request:
    paths: ["core/**", "contracts/**"]
jobs:
  native-tests:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-15, windows-latest]
    runs-on: ${{ matrix.os }}
    steps: [{run: x}]
  cross-build:
    needs: native-tests
    if: needs.native-tests.result == 'success'
    runs-on: ubuntu-latest
    steps: [{run: x}]
`,
	".github/workflows/app.yml": `name: App Build
on:
  pull_request:
    paths: ["apps/**"]
jobs:
  unsigned-app: {runs-on: macos-15, steps: [{run: x}]}
`,
	".github/workflows/report.yml": `name: Report
on:
  workflow_run:
    workflows: [CI]
    types: [completed]
jobs:
  summary: {runs-on: ubuntu-latest, steps: [{run: x}]}
`,
	".github/workflows/deploy.yml": `name: Deploy
on: workflow_dispatch
jobs:
  build-image: {runs-on: ubuntu-latest, steps: [{run: x}]}
  deploy-production:
    needs: build-image
    environment: production
    runs-on: ubuntu-latest
    steps: [{run: x}]
`,
	".github/workflows/release.yml": `name: Release
on:
  push:
    tags: ["v*"]
jobs:
  publish: {runs-on: ubuntu-latest, steps: [{run: x}]}
`,
	".github/workflows/nightly.yml": `name: Nightly
on:
  schedule: [{cron: "0 3 * * *"}]
jobs:
  sweep: {runs-on: ubuntu-latest, steps: [{run: x}]}
`,
}

func workflows() []Workflow {
	var out []Workflow
	for _, path := range []string{".github/workflows/app.yml", ".github/workflows/ci.yml", ".github/workflows/core.yml",
		".github/workflows/deploy.yml", ".github/workflows/nightly.yml", ".github/workflows/release.yml", ".github/workflows/report.yml"} {
		out = append(out, Parse(path, []byte(files[path])))
	}
	return out
}

func TestScenariosOfABranch(t *testing.T) {
	repo := Repo{CurrentBranch: "feature/retry", DefaultBranch: "main", PullRequestBase: "main"}
	var titles []string
	for _, s := range Scenarios(workflows(), repo) {
		titles = append(titles, s.Title())
	}
	want := []string{"Pull request → main", "Push to feature/retry", "Merge into main", "Tag v*", "Manual start", "Schedule"}
	if !reflect.DeepEqual(titles, want) {
		t.Fatalf("scenarios = %v", titles)
	}
	onMain := Scenarios(workflows(), Repo{CurrentBranch: "main", DefaultBranch: "main"})
	if onMain[0] != (Scenario{Push, "main"}) {
		t.Fatalf("on the default branch the default is a push to it: %v", onMain[0])
	}
	for _, s := range onMain {
		if s.Kind == Merge && s.Target == "main" {
			t.Fatalf("a merge of main into itself: %v", onMain)
		}
	}
	open := Scenarios(workflows(), Repo{CurrentBranch: "feature/retry", DefaultBranch: "main", PullRequestBase: "release"})
	if open[0] != (Scenario{PullRequest, "release"}) || open[1] != (Scenario{PullRequest, "main"}) {
		t.Fatalf("the open pull request's base comes first: %v", open)
	}
	if none := Scenarios(nil, repo); len(none) != 0 {
		t.Fatalf("no workflows, no scenarios: %v", none)
	}
}

func TestTargetsComeByNameThenTheDefaultThenPatterns(t *testing.T) {
	ws := []Workflow{
		Parse(".github/workflows/a.yml", []byte("on:\n  pull_request:\n    branches: [develop, 'release/**', '!release/old']\njobs: {a: {runs-on: x, steps: [{run: x}]}}\n")),
		Parse(".github/workflows/b.yml", []byte("on:\n  pull_request:\n    branches: [develop, stable]\njobs: {a: {runs-on: x, steps: [{run: x}]}}\n")),
	}
	var titles []string
	for _, s := range Scenarios(ws, Repo{CurrentBranch: "feature/x", DefaultBranch: "main"}) {
		titles = append(titles, s.Title())
	}
	// The default comes first, then names by how many workflows name them; !release/old is no target.
	if want := []string{"Pull request → main", "Pull request → develop", "Pull request → stable", "Pull request → release/**"}; !reflect.DeepEqual(titles, want) {
		t.Fatalf("titles = %v", titles)
	}
}

func TestAPullRequestIntoMain(t *testing.T) {
	repo := Repo{CurrentBranch: "feature/retry", DefaultBranch: "main", PullRequestBase: "main"}
	f := Plan(Scenario{PullRequest, "main"}, workflows(), repo, Changes{Known: true, Files: []string{"core/internal/x.go", "README.md"}})
	var lanes []string
	for _, l := range f.Lanes {
		lanes = append(lanes, l.Name+":"+l.Why)
	}
	want := []string{"CI:pull_request · branches main", "Report:workflow_run", "Go Core:pull_request · paths ✓", "Deploy:workflow_dispatch"}
	if !reflect.DeepEqual(lanes, want) {
		t.Fatalf("lanes = %v", lanes)
	}
	if f.Lanes[1].Kind != Chained || f.Lanes[1].After != "CI" || f.Lanes[3].Kind != ByHand {
		t.Fatalf("kinds = %+v", f.Lanes)
	}
	skipped := map[string]string{}
	for _, s := range f.Skipped {
		skipped[s.Name] = s.Reason
	}
	if skipped["App Build"] != "paths apps/**: no changed file matches" || skipped["Release"] != "runs on push" || skipped["Nightly"] != "runs on schedule" {
		t.Fatalf("skipped = %v", skipped)
	}
	jobs := map[string]PlannedJob{}
	for _, j := range f.Lanes[0].Jobs {
		jobs[j.ID] = j
	}
	if jobs["lint"].Column != 0 || jobs["unit-tests"].Column != 0 || jobs["build"].Column != 1 {
		t.Fatalf("columns = %+v", jobs)
	}
	if jobs["publish"].Skipped != "if: github.event_name == 'push'" || jobs["announce"].Skipped != "needs publish, which does not run" {
		t.Fatalf("skipped jobs = %q, %q", jobs["publish"].Skipped, jobs["announce"].Skipped)
	}
	core := f.Lanes[2]
	if core.Jobs[0].Matrix != 3 || core.Jobs[1].Condition != "needs.native-tests.result == 'success'" {
		t.Fatalf("core jobs = %+v", core.Jobs)
	}
	deploy := f.Lanes[3]
	if deploy.Jobs[1].Environment != "production" || deploy.Jobs[1].Column != 1 {
		t.Fatalf("deploy jobs = %+v", deploy.Jobs)
	}
}

func TestPathsUnknownWithoutGitKeepTheLane(t *testing.T) {
	repo := Repo{CurrentBranch: "feature/retry", DefaultBranch: "main"}
	f := Plan(Scenario{PullRequest, "main"}, workflows(), repo, Changes{Note: "git not found"})
	whys := map[string]string{}
	for _, l := range f.Lanes {
		whys[l.Name] = l.Why
	}
	if whys["Go Core"] != "pull_request · paths unknown" || whys["App Build"] != "pull_request · paths unknown" {
		t.Fatalf("whys = %v", whys)
	}
}

func TestOtherScenarios(t *testing.T) {
	repo := Repo{CurrentBranch: "feature/retry", DefaultBranch: "main"}
	names := func(f Flow) []string {
		var out []string
		for _, l := range f.Lanes {
			out = append(out, l.Name)
		}
		return out
	}
	push := Plan(Scenario{Push, "feature/retry"}, workflows(), repo, Changes{Known: true})
	if got := names(push); !reflect.DeepEqual(got, []string{"Deploy"}) {
		t.Fatalf("a push to a feature branch starts only what is run by hand: %v", got)
	}
	merge := Plan(Scenario{Merge, "main"}, workflows(), repo, Changes{Known: true, Files: []string{"apps/x.swift"}})
	if got := names(merge); !reflect.DeepEqual(got, []string{"CI", "Report", "Deploy"}) {
		t.Fatalf("merge = %v", got)
	}
	ci := merge.Lanes[0]
	if ci.Jobs[3].Skipped != "" || ci.Jobs[4].Skipped != "" {
		t.Fatalf("a push runs publish and announce: %+v", ci.Jobs)
	}
	tag := Plan(Scenario{Tag, "v1.2.0"}, workflows(), repo, Changes{Known: true})
	if got := names(tag); !reflect.DeepEqual(got, []string{"Release", "Deploy"}) || tag.Lanes[0].Why != "push · tags v*" {
		t.Fatalf("tag = %v %q", got, tag.Lanes[0].Why)
	}
	manual := Plan(Scenario{Manual, ""}, workflows(), repo, Changes{Known: true})
	if got := names(manual); !reflect.DeepEqual(got, []string{"Deploy"}) || manual.Lanes[0].Kind != Direct {
		t.Fatalf("manual = %v", got)
	}
	nightly := Plan(Scenario{Schedule, ""}, workflows(), repo, Changes{Known: true})
	if got := names(nightly); !reflect.DeepEqual(got, []string{"Nightly", "Deploy"}) {
		t.Fatalf("schedule = %v", got)
	}
}

func TestAPullRequestReadsEveryFilter(t *testing.T) {
	job := "jobs: {a: {runs-on: x, steps: [{run: x}]}}\n"
	ws := []Workflow{
		Parse(".github/workflows/a.yml", []byte("name: CI\non:\n  pull_request:\n    branches: [main]\n"+job)),
		Parse(".github/workflows/b.yml", []byte("name: Docs\non:\n  pull_request:\n    paths-ignore: ['apps/**']\n"+job)),
		Parse(".github/workflows/c.yml", []byte("name: Other\non:\n  pull_request:\n    branches: ['release/**', '!release/old/**']\n"+job)),
		Parse(".github/workflows/d.yml", []byte("name: Target\non:\n  pull_request_target:\n    branches-ignore: [main]\n"+job)),
		Parse(".github/workflows/e.yml", []byte("name: Closed\non:\n  pull_request:\n    types: [closed]\n"+job)),
		Parse(".github/workflows/f.yml", []byte("name: Labeled\non:\n  pull_request:\n    types: [labeled, synchronize]\n"+job)),
	}
	repo := Repo{CurrentBranch: "feature/x", DefaultBranch: "main"}
	skippedOf := func(f Flow) map[string]string {
		out := map[string]string{}
		for _, s := range f.Skipped {
			out[s.Name] = s.Reason
		}
		return out
	}
	f := Plan(Scenario{PullRequest, "main"}, ws, repo, Changes{Known: true, Files: []string{"apps/x.swift"}})
	if len(f.Lanes) != 2 || f.Lanes[0].Name != "CI" || f.Lanes[1].Name != "Labeled" {
		t.Fatalf("lanes = %+v", f.Lanes)
	}
	want := map[string]string{
		"Docs":   "paths-ignore: every changed file is ignored",
		"Other":  "branch main does not match release/**, !release/old/**",
		"Target": "branches-ignore main",
		"Closed": "types: closed",
	}
	if got := skippedOf(f); !reflect.DeepEqual(got, want) {
		t.Fatalf("skipped = %v", got)
	}
	old := Plan(Scenario{PullRequest, "release/old/1"}, ws, repo, Changes{Known: true, Files: []string{"apps/x.swift"}})
	if got := skippedOf(old)["Other"]; got != "excluded by !release/old/**" {
		t.Fatalf("excluded = %q", got)
	}
}

func TestATagStartsPushesWithoutRefFilters(t *testing.T) {
	job := "jobs: {a: {runs-on: x, steps: [{run: x}]}}\n"
	ws := []Workflow{
		Parse(".github/workflows/a.yml", []byte("name: Main\non:\n  push:\n    branches: [main]\n"+job)),
		Parse(".github/workflows/b.yml", []byte("name: Tags\non:\n  push:\n    tags: ['v*']\n"+job)),
		Parse(".github/workflows/c.yml", []byte("name: Release\non:\n  release:\n    types: [published]\n"+job)),
		Parse(".github/workflows/d.yml", []byte("name: Every push\non: push\n"+job)),
		Parse(".github/workflows/e.yml", []byte("name: Go\non:\n  push:\n    paths: ['core/**']\n"+job)),
	}
	repo := Repo{CurrentBranch: "feature/x", DefaultBranch: "main"}
	tag := Plan(Scenario{Tag, "v1.0"}, ws, repo, Changes{Known: true})
	var lanes []string
	for _, l := range tag.Lanes {
		lanes = append(lanes, l.Name+":"+l.Why)
	}
	// A tag push reads no paths filters.
	if want := []string{"Tags:push · tags v*", "Release:release", "Every push:push", "Go:push"}; !reflect.DeepEqual(lanes, want) {
		t.Fatalf("lanes = %v", lanes)
	}
	if len(tag.Skipped) != 1 || tag.Skipped[0].Name != "Main" || tag.Skipped[0].Reason != "runs on branch pushes" {
		t.Fatalf("skipped = %+v", tag.Skipped)
	}
	merge := Plan(Scenario{Merge, "main"}, ws, repo, Changes{Known: true, Files: []string{"README.md"}})
	var names []string
	for _, l := range merge.Lanes {
		names = append(names, l.Name)
	}
	if !reflect.DeepEqual(names, []string{"Main", "Every push"}) {
		t.Fatalf("merge = %v, skipped %+v", names, merge.Skipped)
	}
}

func TestChainsFollowTheirSourceOnItsBranch(t *testing.T) {
	job := "jobs: {a: {runs-on: x, steps: [{run: x}]}}\n"
	ws := []Workflow{
		Parse(".github/workflows/a.yml", []byte("name: CI\non: pull_request\n"+job)),
		Parse(".github/workflows/b.yml", []byte("name: Report\non:\n  workflow_run:\n    workflows: [CI]\n    types: [completed]\n"+job)),
		Parse(".github/workflows/c.yml", []byte("name: Notify\non:\n  workflow_run:\n    workflows: [Report]\n"+job)),
		Parse(".github/workflows/d.yml", []byte("name: Main only\non:\n  workflow_run:\n    workflows: [CI]\n    branches: [main]\n"+job)),
		Parse(".github/workflows/e.yml", []byte("name: Requested\non:\n  workflow_run:\n    workflows: [CI]\n    types: [requested]\n"+job)),
		Parse(".github/workflows/f.yml", []byte("name: Nowhere\non:\n  workflow_run:\n    workflows: [Build]\n"+job)),
		Parse(".github/workflows/g.yml", []byte("name: Lib\non: workflow_call\n"+job)),
	}
	f := Plan(Scenario{PullRequest, "main"}, ws, Repo{CurrentBranch: "feature/x", DefaultBranch: "main"}, Changes{Known: true})
	var lanes []string
	for _, l := range f.Lanes {
		lanes = append(lanes, l.Name+"<"+l.After+":"+l.Why)
	}
	// requested starts with CI rather than after it, but in the scenario all the same.
	if want := []string{"CI<:pull_request", "Report<CI:workflow_run", "Notify<Report:workflow_run", "Requested<CI:workflow_run · types requested"}; !reflect.DeepEqual(lanes, want) {
		t.Fatalf("lanes = %v", lanes)
	}
	skipped := map[string]string{}
	for _, s := range f.Skipped {
		skipped[s.Name] = s.Reason
	}
	want := map[string]string{
		"Main only": "after CI: branch feature/x does not match main",
		"Nowhere":   "after Build, which is not in this scenario",
		"Lib":       "called by other workflows",
	}
	if !reflect.DeepEqual(skipped, want) {
		t.Fatalf("skipped = %v", skipped)
	}
}

func TestAJobWithAlwaysRunsAfterASkippedNeed(t *testing.T) {
	w := Parse(".github/workflows/ci.yml", []byte(`on: [pull_request, push]
jobs:
  build:
    if: github.event_name == 'push'
    runs-on: x
    steps: [{run: x}]
  publish:
    needs: build
    runs-on: x
    steps: [{run: x}]
  report:
    needs: build
    if: always()
    runs-on: x
    steps: [{run: x}]
  deploy:
    if: vars.DEPLOY == 'true'
    runs-on: x
    steps: [{run: x}]
`))
	f := Plan(Scenario{PullRequest, "main"}, []Workflow{w}, Repo{CurrentBranch: "feature/x", DefaultBranch: "main"}, Changes{Known: true})
	jobs := map[string]PlannedJob{}
	for _, j := range f.Lanes[0].Jobs {
		jobs[j.ID] = j
	}
	if jobs["build"].Skipped == "" || jobs["publish"].Skipped != "needs build, which does not run" || jobs["report"].Skipped != "" ||
		jobs["deploy"].Condition != "vars.DEPLOY == 'true'" || jobs["deploy"].Skipped != "" {
		t.Fatalf("jobs = %+v", jobs)
	}
}

func TestAFileThatDoesNotParseIsSkippedWithItsError(t *testing.T) {
	broken := Parse(".github/workflows/broken.yml", []byte("on: [push\n"))
	f := Plan(Scenario{Push, "main"}, []Workflow{broken}, Repo{CurrentBranch: "main", DefaultBranch: "main"}, Changes{Known: true})
	if len(f.Lanes) != 0 || len(f.Skipped) != 1 || !strings.HasPrefix(f.Skipped[0].Reason, "does not parse") {
		t.Fatalf("flow = %+v", f)
	}
}

func TestGitListsTheFilesOfTheChange(t *testing.T) {
	git := FindGit(filepath.SplitList(os.Getenv("PATH")))
	if git == "" {
		t.Skip("git is not installed")
	}
	root := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		cmd := exec.Command(git, append([]string{"-C", root, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	write := func(name string) {
		path := filepath.Join(root, name)
		_ = os.MkdirAll(filepath.Dir(path), 0o755)
		if err := os.WriteFile(path, []byte(name), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	run("init", "-q", "-b", "main")
	write("README.md")
	run("add", ".")
	run("commit", "-q", "-m", "first")
	run("update-ref", "refs/remotes/origin/main", "HEAD")
	run("checkout", "-q", "-b", "feature")
	write("core/a.go")
	run("add", ".")
	run("commit", "-q", "-m", "change")
	write("apps/new.swift")
	if err := os.WriteFile(filepath.Join(root, "README.md"), []byte("edited"), 0o644); err != nil {
		t.Fatal(err)
	}
	g := Git{Path: git, Root: root}
	changes := g.Changes(context.Background(), "origin/main")
	if !changes.Known || !reflect.DeepEqual(changes.Files, []string{"README.md", "core/a.go", "apps/new.swift"}) {
		t.Fatalf("changes = %+v", changes)
	}
	if unknown := g.Changes(context.Background(), "origin/nope"); unknown.Known || unknown.Note == "" {
		t.Fatalf("an unknown base = %+v", unknown)
	}
	if head := g.Head(context.Background()); len(head) != 40 {
		t.Fatalf("head = %q", head)
	}
	if none := (Git{Root: root}).Changes(context.Background(), "origin/main"); none.Known || none.Note != "git not found, so paths filters are unknown" {
		t.Fatalf("without git = %+v", none)
	}
}
