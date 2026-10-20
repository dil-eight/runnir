package validate

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func write(t *testing.T, root, rel, content string) {
	t.Helper()
	path := filepath.Join(root, filepath.FromSlash(rel))
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func repo(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	return root
}

const valid = `name: CI
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - run: echo hi
`

const brokenNeeds = `name: Release
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    needs: [test]
    steps:
      - run: echo hi
`

func result(t *testing.T, report Report, id string) Result {
	t.Helper()
	for _, r := range report.Results {
		if r.WorkflowID == id {
			return r
		}
	}
	t.Fatalf("no result for %s in %+v", id, report)
	return Result{}
}

func TestDiagnosticsPointAtTheProblem(t *testing.T) {
	root := repo(t)
	write(t, root, ".github/workflows/ci.yml", valid)
	write(t, root, ".github/workflows/release.yml", brokenNeeds)
	report, err := Workflows(context.Background(), root, "")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(report.Validator, "actionlint") {
		t.Errorf("validator = %q", report.Validator)
	}
	if ci := result(t, report, ".github/workflows/ci.yml"); len(ci.Diagnostics) != 0 || ci.Problem != "" {
		t.Errorf("valid workflow = %+v", ci)
	}
	release := result(t, report, ".github/workflows/release.yml")
	if len(release.Diagnostics) != 1 {
		t.Fatalf("release = %+v", release)
	}
	d := release.Diagnostics[0]
	if d.Line != 4 || d.Column != 3 || d.Kind != "job-needs" || !strings.Contains(d.Message, `"test"`) {
		t.Errorf("diagnostic = %+v", d)
	}

	only, err := Workflows(context.Background(), root, ".github/workflows/release.yml")
	if err != nil || len(only.Results) != 1 || only.Results[0].WorkflowID != ".github/workflows/release.yml" {
		t.Fatalf("only one = %+v, %v", only, err)
	}
	if _, err := Workflows(context.Background(), root, ".github/workflows/missing.yml"); !errors.Is(err, ErrUnknownWorkflow) {
		t.Fatalf("missing = %v", err)
	}
}

func TestTheRepositoryConfigIsUsedAndABadOneIsReported(t *testing.T) {
	root := repo(t)
	write(t, root, ".github/workflows/ci.yml", strings.Replace(valid, "ubuntu-latest", "build-box", 1))
	unknownLabel := func() bool {
		t.Helper()
		report, err := Workflows(context.Background(), root, "")
		if err != nil {
			t.Fatal(err)
		}
		for _, d := range result(t, report, ".github/workflows/ci.yml").Diagnostics {
			if d.Kind == "runner-label" {
				return true
			}
		}
		return false
	}
	if !unknownLabel() {
		t.Fatal("a custom runner label without config should be reported")
	}
	write(t, root, ".github/actionlint.yaml", "self-hosted-runner:\n  labels: [build-box]\n")
	if unknownLabel() {
		t.Fatal("the config's runner labels were not used")
	}
	write(t, root, ".github/actionlint.yaml", "self-hosted-runner: [not, a, mapping\n")
	report, err := Workflows(context.Background(), root, "")
	if err != nil || !strings.Contains(report.ConfigProblem, "actionlint.yaml") || strings.Contains(report.ConfigProblem, os.TempDir()) {
		t.Fatalf("bad config = %q, %v", report.ConfigProblem, err)
	}
}

func TestASymlinkedConfigIsNotFollowed(t *testing.T) {
	root := repo(t)
	outside := t.TempDir()
	write(t, outside, "actionlint.yaml", "self-hosted-runner:\n  labels: [build-box]\n")
	write(t, root, ".github/workflows/ci.yml", strings.Replace(valid, "ubuntu-latest", "build-box", 1))
	if err := os.Symlink(filepath.Join(outside, "actionlint.yaml"), filepath.Join(root, ".github", "actionlint.yaml")); err != nil {
		t.Fatal(err)
	}
	report, err := Workflows(context.Background(), root, "")
	if err != nil || report.ConfigProblem == "" {
		t.Fatalf("symlinked config = %q, %v", report.ConfigProblem, err)
	}
}

func TestLocalReusableWorkflowsResolveButNothingOutsideIsRead(t *testing.T) {
	root := repo(t)
	write(t, root, ".github/workflows/called.yml", `on:
  workflow_call:
    inputs:
      target: {type: string, required: true}
jobs:
  run:
    runs-on: ubuntu-latest
    steps:
      - run: echo ${{ inputs.target }}
`)
	write(t, root, ".github/workflows/caller.yml", `on: push
jobs:
  call:
    uses: ./.github/workflows/called.yml
`)
	// A secret file next to the repository that a ".." path would reach.
	write(t, filepath.Dir(root), "secret.yml", "on:\n  workflow_call:\n    inputs:\n      outside_only: {type: string, required: true}\n")
	write(t, root, ".github/workflows/escape.yml", `on: push
jobs:
  call:
    uses: ./../`+filepath.Base(filepath.Dir(root))+`/secret.yml
`)
	report, err := Workflows(context.Background(), root, "")
	if err != nil {
		t.Fatal(err)
	}
	caller := result(t, report, ".github/workflows/caller.yml")
	if len(caller.Diagnostics) != 1 || !strings.Contains(caller.Diagnostics[0].Message, `"target"`) {
		t.Fatalf("the missing required input of the local reusable workflow should be found: %+v", caller)
	}
	for _, d := range result(t, report, ".github/workflows/escape.yml").Diagnostics {
		// Read, the file outside would make its required input an error here.
		if strings.Contains(d.Message, "outside_only") || strings.Contains(d.Message, os.TempDir()) {
			t.Fatalf("the escaping path was followed: %+v", d)
		}
	}
}

func TestUnreadableFilesAreReportedNotChecked(t *testing.T) {
	root := repo(t)
	write(t, root, ".github/workflows/big.yml", "on: push\n# "+strings.Repeat("x", 1<<20)+"\n")
	report, err := Workflows(context.Background(), root, "")
	if err != nil {
		t.Fatal(err)
	}
	if big := result(t, report, ".github/workflows/big.yml"); big.Problem == "" || len(big.Diagnostics) != 0 {
		t.Fatalf("big = %+v", big)
	}
	empty := repo(t)
	none, err := Workflows(context.Background(), empty, "")
	if err != nil || len(none.Results) != 0 {
		t.Fatalf("no workflows = %+v, %v", none, err)
	}
}

func TestAFileCheckedWithoutAProjectFindsNoneAboveTheCopies(t *testing.T) {
	// The temporary directory sits inside a repository that a project
	// lookup walking up from the copies would find and use.
	host := repo(t)
	write(t, host, ".github/workflows/host.yml", valid)
	write(t, host, ".github/workflows/hosted.yml", "on:\n  workflow_call:\n    inputs:\n      host_only: {type: string, required: true}\n")
	t.Setenv("TMPDIR", filepath.Join(host, "tmp"))
	if err := os.MkdirAll(filepath.Join(host, "tmp"), 0o755); err != nil {
		t.Fatal(err)
	}
	root := repo(t)
	write(t, root, ".github/workflows/escape.yml", `on: push
jobs:
  call:
    uses: ./../x.yml
  other:
    uses: ./.github/workflows/hosted.yml
`)
	report, err := Workflows(context.Background(), root, "")
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range result(t, report, ".github/workflows/escape.yml").Diagnostics {
		if strings.Contains(d.Message, "host_only") {
			t.Fatalf("the repository around the temporary directory was used: %+v", d)
		}
	}
}

func TestClimbingOutIsDetectedAnywhere(t *testing.T) {
	cases := map[string]bool{
		"jobs:\n  a:\n    uses: ./../x.yml\n":                          true,
		"jobs:\n  a:\n    steps:\n      - uses: ./sub/../../x\n":       true,
		"jobs:\n  a:\n    steps:\n      - uses: ./actions/build\n":     false,
		"jobs:\n  a:\n    uses: ./.github/workflows/b.yml\n":           false,
		"jobs:\n  a:\n    steps:\n      - uses: actions/checkout@v4\n": false,
		"x: &u ./../y\njobs:\n  a:\n    steps:\n      - uses: *u\n":    true,
		"not: [valid": false,
	}
	for doc, want := range cases {
		if got := climbsOut([]byte(doc)); got != want {
			t.Errorf("climbsOut(%q) = %v, want %v", doc, got, want)
		}
	}
}

func TestAnUnwritableTemporaryDirectoryIsAPrepareError(t *testing.T) {
	root := repo(t)
	write(t, root, ".github/workflows/ci.yml", valid)
	t.Setenv("TMPDIR", filepath.Join(root, "does-not-exist"))
	if _, err := Workflows(context.Background(), root, ""); !errors.Is(err, ErrPrepare) {
		t.Fatalf("err = %v, want ErrPrepare", err)
	}
}

func TestAnAliasBombStaysCheap(t *testing.T) {
	root := repo(t)
	var b strings.Builder
	b.WriteString("on: push\na0: &a0 [x, x, x, x, x, x, x, x, x]\n")
	for i := 1; i < 9; i++ {
		b.WriteString("a" + strconv.Itoa(i) + ": &a" + strconv.Itoa(i) + " [" +
			strings.TrimSuffix(strings.Repeat("*a"+strconv.Itoa(i-1)+", ", 9), ", ") + "]\n")
	}
	b.WriteString("jobs:\n  build:\n    runs-on: ubuntu-latest\n    env:\n      X: *a8\n    steps:\n      - run: echo hi\n")
	write(t, root, ".github/workflows/bomb.yml", b.String())
	done := make(chan error, 1)
	go func() {
		_, err := Workflows(context.Background(), root, "")
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("nine levels of nine aliases were expanded")
	}
}
