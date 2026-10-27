package flow

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
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
	}
	for _, c := range cases {
		if got := globMatch(c.pattern, c.value); got != c.want {
			t.Errorf("%q ~ %q = %v, want %v", c.pattern, c.value, got, c.want)
		}
	}
	if in, by := decide([]string{"release/**", "!release/old/**"}, "release/old/1"); in || by != "!release/old/**" {
		t.Fatalf("the last pattern decides: %v %q", in, by)
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
		"github.event.pull_request.draft": false}
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
	g := Git{Path: git, Root: root}
	changes := g.Changes(context.Background(), "origin/main")
	if !changes.Known || !reflect.DeepEqual(changes.Files, []string{"core/a.go", "apps/new.swift"}) {
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
