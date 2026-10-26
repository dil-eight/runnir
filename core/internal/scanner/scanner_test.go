package scanner

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"strings"
	"testing"
	"unicode/utf8"

	"runnir/core/internal/repository"
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

func scan(t *testing.T, root string) repository.Snapshot {
	t.Helper()
	snapshot, err := New().Scan(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func byID(snapshot repository.Snapshot, id string) *repository.Workflow {
	for i := range snapshot.Workflows {
		if snapshot.Workflows[i].ID == id {
			return &snapshot.Workflows[i]
		}
	}
	return nil
}

const ciWorkflow = `name: CI
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:
jobs:
  build:
    name: Build app
    runs-on: macos-15
    steps:
      - run: echo ${{ github.sha }}
  test:
    needs: build
    runs-on: ubuntu-latest
  release:
    needs: [build, test]
    runs-on: ubuntu-latest
`

func TestParsesNameTriggersAndJobGraphInOrder(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".github/workflows/ci.yml", ciWorkflow)
	snapshot := scan(t, root)

	if len(snapshot.Workflows) != 1 {
		t.Fatalf("workflows = %+v", snapshot.Workflows)
	}
	w := snapshot.Workflows[0]
	if w.ID != ".github/workflows/ci.yml" || w.Name != "CI" || w.ParseError != "" {
		t.Fatalf("workflow = %+v", w)
	}
	if got := strings.Join(w.Triggers, ","); got != "push,pull_request,workflow_dispatch" {
		t.Fatalf("triggers = %q", got)
	}
	want := []repository.Job{
		{ID: "build", Name: "Build app"},
		{ID: "test", Name: "test", Needs: []string{"build"}},
		{ID: "release", Name: "release", Needs: []string{"build", "test"}},
	}
	if len(w.Jobs) != len(want) {
		t.Fatalf("jobs = %+v", w.Jobs)
	}
	for i, job := range want {
		got := w.Jobs[i]
		if got.ID != job.ID || got.Name != job.Name || strings.Join(got.Needs, ",") != strings.Join(job.Needs, ",") {
			t.Errorf("job %d = %+v, want %+v", i, got, job)
		}
	}
}

func TestTriggerForms(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".github/workflows/a.yml", "on: push\njobs: {}\n")
	write(t, root, ".github/workflows/b.yaml", "on: [push, pull_request]\njobs: {}\n")
	write(t, root, ".github/workflows/c.yml", "on:\n  schedule:\n    - cron: '0 0 * * *'\njobs: {}\n")
	snapshot := scan(t, root)
	for id, want := range map[string]string{
		".github/workflows/a.yml":  "push",
		".github/workflows/b.yaml": "push,pull_request",
		".github/workflows/c.yml":  "schedule",
	} {
		w := byID(snapshot, id)
		if w == nil || strings.Join(w.Triggers, ",") != want {
			t.Errorf("%s = %+v, want triggers %q", id, w, want)
		}
	}
}

func TestNameFallsBackToPathAndOrderIsDeterministic(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".github/workflows/zeta.yml", "on: push\njobs: {}\n")
	write(t, root, ".github/workflows/alpha.yml", "on: push\njobs: {}\n")
	snapshot := scan(t, root)
	if len(snapshot.Workflows) != 2 || snapshot.Workflows[0].ID != ".github/workflows/alpha.yml" {
		t.Fatalf("order = %+v", snapshot.Workflows)
	}
	if snapshot.Workflows[0].Name != ".github/workflows/alpha.yml" {
		t.Fatalf("name = %q", snapshot.Workflows[0].Name)
	}
}

func TestMalformedFilesReportParseErrorsWithoutFailingTheScan(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".github/workflows/good.yml", "on: push\njobs:\n  a: {}\n")
	write(t, root, ".github/workflows/bad.yml", "on: [push\njobs: {\n")
	write(t, root, ".github/workflows/list.yml", "- a\n- b\n")
	write(t, root, ".github/workflows/empty.yml", "")
	write(t, root, ".github/workflows/huge.yml", "# "+strings.Repeat("x", maxFileBytes)+"\n")
	snapshot := scan(t, root)

	if w := byID(snapshot, ".github/workflows/good.yml"); w == nil || w.ParseError != "" {
		t.Fatalf("good = %+v", w)
	}
	for _, id := range []string{"bad.yml", "list.yml", "empty.yml", "huge.yml"} {
		w := byID(snapshot, ".github/workflows/"+id)
		if w == nil || w.ParseError == "" {
			t.Errorf("%s should carry a parse error: %+v", id, w)
		}
	}
}

func TestIgnoresOtherFilesSubdirectoriesAndSymlinks(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	write(t, outside, "secret.yml", "name: leaked\non: push\njobs: {}\n")
	write(t, root, ".github/workflows/ci.yml", "on: push\njobs: {}\n")
	write(t, root, ".github/workflows/README.md", "docs")
	write(t, root, ".github/workflows/nested/inner.yml", "on: push\njobs: {}\n")
	if err := os.Symlink(filepath.Join(outside, "secret.yml"), filepath.Join(root, ".github/workflows/link.yml")); err != nil {
		t.Fatal(err)
	}
	snapshot := scan(t, root)
	if len(snapshot.Workflows) != 1 || snapshot.Workflows[0].ID != ".github/workflows/ci.yml" {
		t.Fatalf("workflows = %+v", snapshot.Workflows)
	}
}

func TestSymlinkedWorkflowsDirectoryIsNotFollowed(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	write(t, outside, "x.yml", "on: push\njobs: {}\n")
	if err := os.MkdirAll(filepath.Join(root, ".github"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, ".github/workflows")); err != nil {
		t.Fatal(err)
	}
	if got := scan(t, root); len(got.Workflows) != 0 {
		t.Fatalf("followed symlinked directory: %+v", got.Workflows)
	}
}

func TestNoWorkflowDirectoryIsNotAnError(t *testing.T) {
	snapshot := scan(t, t.TempDir())
	if len(snapshot.Workflows) != 0 || snapshot.Branch != "" {
		t.Fatalf("snapshot = %+v", snapshot)
	}
}

func TestFileCountIsBounded(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < maxWorkflowFiles+20; i++ {
		write(t, root, filepath.ToSlash(filepath.Join(".github/workflows", strings.Repeat("a", 1)+string(rune('a'+i%26))+strings.Repeat("b", i/26)+".yml")), "on: push\njobs: {}\n")
	}
	if got := scan(t, root); len(got.Workflows) != maxWorkflowFiles {
		t.Fatalf("workflows = %d, want cap %d", len(got.Workflows), maxWorkflowFiles)
	}
}

func TestBranchResolution(t *testing.T) {
	cases := map[string]string{
		"ref: refs/heads/main\n":                     "main",
		"ref: refs/heads/feature/new-ui\n":           "feature/new-ui",
		"0123456789abcdef0123456789abcdef01234567\n": "",
		"ref: refs/remotes/origin/main\n":            "",
		"":                                           "",
		"garbage":                                    "",
	}
	for head, want := range cases {
		root := t.TempDir()
		write(t, root, ".git/HEAD", head)
		if got := scan(t, root).Branch; got != want {
			t.Errorf("HEAD %q: branch = %q, want %q", head, got, want)
		}
	}
}

func TestBranchFromWorktreeGitFile(t *testing.T) {
	main := t.TempDir()
	gitdir := filepath.Join(main, ".git", "worktrees", "wt")
	write(t, main, ".git/worktrees/wt/HEAD", "ref: refs/heads/topic\n")

	worktree := t.TempDir()
	write(t, worktree, ".git", "gitdir: "+gitdir+"\n")
	write(t, main, ".git/worktrees/wt/gitdir", filepath.Join(worktree, ".git")+"\n")
	if got := scan(t, worktree).Branch; got != "topic" {
		t.Fatalf("absolute gitdir: branch = %q", got)
	}

	relative := filepath.Join(main, "wt-rel")
	write(t, main, ".git/worktrees/rel/HEAD", "ref: refs/heads/other\n")
	write(t, main, ".git/worktrees/rel/gitdir", filepath.Join(relative, ".git")+"\n")
	write(t, relative, ".git", "gitdir: ../.git/worktrees/rel\n")
	if got := scan(t, relative).Branch; got != "other" {
		t.Fatalf("relative gitdir: branch = %q", got)
	}
}

func TestBranchFromWorktreeOfABareRepository(t *testing.T) {
	bare := filepath.Join(t.TempDir(), "project.git")
	worktree := t.TempDir()
	write(t, bare, "worktrees/feature/HEAD", "ref: refs/heads/feature\n")
	write(t, bare, "worktrees/feature/gitdir", filepath.Join(worktree, ".git")+"\n")
	write(t, worktree, ".git", "gitdir: "+filepath.Join(bare, "worktrees", "feature")+"\n")
	if got := scan(t, worktree).Branch; got != "feature" {
		t.Fatalf("branch = %q, want feature", got)
	}
}

func TestGitFilePointingElsewhereIsNotFollowed(t *testing.T) {
	outside := t.TempDir()
	write(t, outside, "HEAD", "ref: refs/heads/leaked\n")
	// Right layout but the git directory belongs to another worktree.
	other := t.TempDir()
	write(t, other, ".git/worktrees/wt/HEAD", "ref: refs/heads/leaked\n")
	write(t, other, ".git/worktrees/wt/gitdir", "/somewhere/else/.git\n")

	for name, target := range map[string]string{
		"arbitrary directory": outside,
		"foreign worktree":    filepath.Join(other, ".git", "worktrees", "wt"),
		"relative escape":     "../../" + filepath.Base(outside),
	} {
		repo := t.TempDir()
		write(t, repo, ".git", "gitdir: "+target+"\n")
		if got := scan(t, repo).Branch; got != "" {
			t.Errorf("%s: branch = %q, want nothing read outside the repository", name, got)
		}
	}
}

func TestCancelledContextStopsTheScan(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".github/workflows/ci.yml", "on: push\njobs: {}\n")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := New().Scan(ctx, root); err == nil {
		t.Fatal("want context error")
	}
}

func TestUnevaluatedExpressionsAreKeptVerbatim(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".github/workflows/m.yml", "name: Deploy ${{ vars.ENV }}\non: push\njobs:\n  j:\n    name: Build ${{ matrix.os }}\n    runs-on: x\n")
	w := scan(t, root).Workflows[0]
	if w.Name != "Deploy ${{ vars.ENV }}" || w.Jobs[0].Name != "Build ${{ matrix.os }}" {
		t.Fatalf("workflow = %+v", w)
	}
}

func TestAliasBombIsNotExpanded(t *testing.T) {
	var b strings.Builder
	b.WriteString("a: &a [x,x,x,x,x,x,x,x,x]\n")
	prev := "a"
	for i := 0; i < 12; i++ {
		cur := string(rune('b' + i))
		refs := strings.Repeat("*"+prev+",", 9)
		b.WriteString(cur + ": &" + cur + " [" + strings.TrimSuffix(refs, ",") + "]\n")
		prev = cur
	}
	b.WriteString("on: push\njobs:\n  j:\n    needs: *" + prev + "\n")
	root := t.TempDir()
	write(t, root, ".github/workflows/bomb.yml", b.String())
	snapshot := scan(t, root)
	w := byID(snapshot, ".github/workflows/bomb.yml")
	if w == nil || strings.Join(w.Triggers, ",") != "push" || len(w.Jobs) != 1 {
		t.Fatalf("bomb workflow = %+v", w)
	}
}

func TestUnreadableFolderIsAnErrorNotAnEmptyRepository(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("permission bits are not enforced here")
	}
	root := t.TempDir()
	write(t, root, ".github/workflows/ci.yml", "on: push\njobs: {}\n")
	if err := os.Chmod(root, 0); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(root, 0o755)
	_, err := New().Scan(context.Background(), root)
	if !errors.Is(err, repository.ErrAccessDenied) {
		t.Fatalf("err = %v, want ErrAccessDenied", err)
	}
}

func TestEmptyReadableFolderIsNotAnError(t *testing.T) {
	if _, err := New().Scan(context.Background(), t.TempDir()); err != nil {
		t.Fatal(err)
	}
}

func TestUnreadableWorkflowsDirectoryIsAnError(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("permission bits are not enforced here")
	}
	root := t.TempDir()
	write(t, root, ".github/workflows/ci.yml", "on: push\njobs: {}\n")
	dir := filepath.Join(root, ".github", "workflows")
	if err := os.Chmod(dir, 0); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(dir, 0o755)
	if _, err := New().Scan(context.Background(), root); !errors.Is(err, repository.ErrAccessDenied) {
		t.Fatalf("err = %v, want ErrAccessDenied", err)
	}
}

func TestNeedsAcceptsOnlyScalarsOrSequences(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".github/workflows/n.yml", "on: push\njobs:\n  a: {}\n  b:\n    needs: {a: 1}\n  c:\n    needs: [a, b]\n")
	jobs := scan(t, root).Workflows[0].Jobs
	if len(jobs[1].Needs) != 0 || strings.Join(jobs[2].Needs, ",") != "a,b" {
		t.Fatalf("jobs = %+v", jobs)
	}
}

func TestParseOrigin(t *testing.T) {
	cases := []struct{ remote, host, repository string }{
		{"https://github.com/dil-eight/runnir.git", "github.com", "dil-eight/runnir"},
		{"https://github.com/dil-eight/runnir", "github.com", "dil-eight/runnir"},
		{"https://x-access-token:secret@github.com/o/r.git", "github.com", "o/r"},
		{"git@github.com:dil-eight/runnir.git", "github.com", "dil-eight/runnir"},
		{"ssh://git@github.com/dil-eight/runnir.git", "github.com", "dil-eight/runnir"},
		{"ssh://git@github.com:22/o/r", "github.com", "o/r"},
		{"https://GitHub.com/o/r.git/", "github.com", "o/r"},
		{"git@GitHub.Company.com:org/app.git", "github.company.com", "org/app"},
		{"ssh://git@github.company.com:2222/org/app.git", "github.company.com", "org/app"},
		{"https://company.ghe.com/org/app.git", "company.ghe.com", "org/app"},
		{"https://github.com.evil.test/o/r", "github.com.evil.test", "o/r"},
		{"https://gitlab.com/o/r.git", "gitlab.com", "o/r"},
		{"git@gitlab.com:o/r.git", "gitlab.com", "o/r"},
		{"https://github.com/o", "", ""},
		{"https://github.com/o/r/extra", "", ""},
		{"file:///Users/me/repo", "", ""},
		{"git@github.com:../r.git", "", ""},
		{"git@:o/r.git", "", ""},
		{"", "", ""},
	}
	for _, c := range cases {
		host, repository := parseOrigin(c.remote)
		if host != c.host || repository != c.repository {
			t.Errorf("parseOrigin(%q) = %q, %q; want %q, %q", c.remote, host, repository, c.host, c.repository)
		}
	}
}

func TestOriginIsReadFromTheRepositoryConfigOnly(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".git/HEAD", "ref: refs/heads/main\n")
	write(t, root, ".git/config", `[core]
	bare = false
[remote "upstream"]
	url = https://github.com/someone/else.git
[remote "origin"]
	url = git@github.com:dil-eight/runnir.git
	fetch = +refs/heads/*:refs/remotes/origin/*
`)
	snapshot := scan(t, root)
	if snapshot.OriginHost != "github.com" || snapshot.OriginRepository != "dil-eight/runnir" || snapshot.Branch != "main" {
		t.Fatalf("snapshot = %+v", snapshot)
	}

	// Any host is reported; the Core decides which ones are GitHub servers.
	other := t.TempDir()
	write(t, other, ".git/HEAD", "ref: refs/heads/main\n")
	write(t, other, ".git/config", "[remote \"origin\"]\n\turl = https://gitlab.com/o/r.git\n")
	if got := scan(t, other); got.OriginHost != "gitlab.com" || got.OriginRepository != "o/r" {
		t.Fatalf("other host = %+v", got)
	}
}

func TestLinkedWorktreeUsesTheMainRepositoryConfig(t *testing.T) {
	main := t.TempDir()
	worktree := t.TempDir()
	write(t, main, ".git/config", "[remote \"origin\"]\n\turl = https://github.com/o/r.git\n")
	write(t, main, ".git/worktrees/wt/HEAD", "ref: refs/heads/topic\n")
	write(t, main, ".git/worktrees/wt/commondir", "../..\n")
	write(t, main, ".git/worktrees/wt/gitdir", filepath.Join(worktree, ".git")+"\n")
	write(t, worktree, ".git", "gitdir: "+filepath.Join(main, ".git", "worktrees", "wt")+"\n")
	snapshot := scan(t, worktree)
	if snapshot.OriginRepository != "o/r" || snapshot.Branch != "topic" {
		t.Fatalf("snapshot = %+v", snapshot)
	}
}

func TestCutParseErrorsStayValidUTF8(t *testing.T) {
	for _, size := range []int{maxErrorChars - 1, maxErrorChars, maxErrorChars + 1} {
		message := strings.Repeat("a", size%2) + strings.Repeat("я", size)
		if cut := truncate(message); !utf8.ValidString(cut) || len(cut) > maxErrorChars {
			t.Fatalf("truncate(%d runes) = %d bytes, valid %v", size, len(cut), utf8.ValidString(cut))
		}
	}
	if cut := truncate("bad \xff byte"); cut != "bad \uFFFD byte" {
		t.Fatalf("invalid byte = %q", cut)
	}
	// Replacement characters are longer than the bytes they replace.
	if cut := truncate(strings.Repeat("\xff", maxErrorChars)); !utf8.ValidString(cut) || len(cut) > maxErrorChars {
		t.Fatalf("all invalid = %d bytes, valid %v", len(cut), utf8.ValidString(cut))
	}
}

func TestCommonDirIsFollowedOnlyForALinkedWorktree(t *testing.T) {
	other := t.TempDir()
	write(t, other, ".git/config", "[remote \"origin\"]\n\turl = https://github.com/other/secret.git\n")
	repo := t.TempDir()
	write(t, repo, ".git/config", "[remote \"origin\"]\n\turl = https://github.com/o/r.git\n")
	write(t, repo, ".git/commondir", filepath.Join(other, ".git")+"\n")
	if got := scan(t, repo).OriginRepository; got != "o/r" {
		t.Fatalf("a plain repository read %q through its commondir file", got)
	}

	// A worktree whose commondir points away from the git dir holding it.
	main := t.TempDir()
	worktree := t.TempDir()
	write(t, main, ".git/config", "[remote \"origin\"]\n\turl = https://github.com/o/r.git\n")
	write(t, main, ".git/worktrees/wt/HEAD", "ref: refs/heads/topic\n")
	write(t, main, ".git/worktrees/wt/commondir", filepath.Join(other, ".git")+"\n")
	write(t, main, ".git/worktrees/wt/gitdir", filepath.Join(worktree, ".git")+"\n")
	write(t, worktree, ".git", "gitdir: "+filepath.Join(main, ".git", "worktrees", "wt")+"\n")
	if got := scan(t, worktree); got.OriginRepository != "" || got.Branch != "topic" {
		t.Fatalf("worktree with a foreign commondir = %+v", got)
	}
}

func TestScanReadsTheDispatchInputsOfEachWorkflow(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".github/workflows/deploy.yml", "on:\n  workflow_dispatch:\n    inputs:\n      value:\n        description: The password for staging\n      region:\n        type: choice\n        options: [eu, us]\njobs: {}\n")
	write(t, root, ".github/workflows/ci.yml", "on: push\njobs: {}\n")
	snapshot := scan(t, root)
	deploy := byID(snapshot, ".github/workflows/deploy.yml")
	want := []repository.DispatchInput{
		{Name: "value", Description: "The password for staging", Type: "string"},
		{Name: "region", Type: "choice", Options: []string{"eu", "us"}},
	}
	if deploy == nil || !reflect.DeepEqual(deploy.DispatchInputs, want) {
		t.Fatalf("deploy = %+v", deploy)
	}
	if ci := byID(snapshot, ".github/workflows/ci.yml"); ci == nil || len(ci.DispatchInputs) != 0 {
		t.Fatalf("ci = %+v", ci)
	}
}

func TestScanListsSecretsAndVariables(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".github/workflows/ci.yml", "name: CI\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ${{ secrets.npm_token }} ${{ vars.REGION }}\n")
	write(t, root, ".github/workflows/broken.yml", "name: [\n  ${{ secrets.STILL_FOUND }}\n")
	snapshot := scan(t, root)
	w := byID(snapshot, ".github/workflows/ci.yml")
	if w == nil || !slices.Equal(w.Secrets, []string{"NPM_TOKEN"}) || !slices.Equal(w.Variables, []string{"REGION"}) {
		t.Fatalf("workflow = %+v", w)
	}
	if broken := byID(snapshot, ".github/workflows/broken.yml"); broken == nil || broken.ParseError == "" || !slices.Equal(broken.Secrets, []string{"STILL_FOUND"}) {
		t.Fatalf("broken = %+v", broken)
	}
}

func TestScanMarksJobsStartedByHand(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".github/workflows/api.yml", `name: API
on:
  push:
  workflow_dispatch:
    inputs:
      Environment:
        type: choice
        options: [production, staging]
      dry_run:
        type: boolean
jobs:
  build:
    runs-on: ubuntu-latest
    steps: [{run: echo}]
  deploy-production:
    if: github.event_name == 'workflow_dispatch' && github.event.inputs.environment == 'production'
    runs-on: ubuntu-latest
    steps: [{run: echo}]
  deploy-staging:
    if: ${{ 'staging' == inputs.Environment && inputs.dry_run == false && github.event_name == 'workflow_dispatch' }}
    runs-on: ubuntu-latest
    steps: [{run: echo}]
  either:
    if: github.event_name == 'workflow_dispatch' || github.event_name == 'push'
    runs-on: ubuntu-latest
    steps: [{run: echo}]
`)
	write(t, root, ".github/workflows/no-dispatch.yml", "on: push\njobs:\n  a:\n    if: github.event_name == 'workflow_dispatch'\n    runs-on: ubuntu-latest\n    steps: [{run: echo}]\n")
	snapshot := scan(t, root)
	api := byID(snapshot, ".github/workflows/api.yml")
	if api == nil || len(api.Jobs) != 4 {
		t.Fatalf("api = %+v", api)
	}
	jobs := map[string]repository.Job{}
	for _, job := range api.Jobs {
		jobs[job.ID] = job
	}
	if jobs["build"].Manual || jobs["either"].Manual {
		t.Fatalf("jobs that also run on push are marked manual: %+v", jobs)
	}
	if production := jobs["deploy-production"]; !production.Manual || !reflect.DeepEqual(production.ManualInputs, map[string]string{"Environment": "production"}) {
		t.Fatalf("deploy-production = %+v", production)
	}
	if staging := jobs["deploy-staging"]; !staging.Manual || !reflect.DeepEqual(staging.ManualInputs, map[string]string{"Environment": "staging", "dry_run": "false"}) {
		t.Fatalf("deploy-staging = %+v", staging)
	}
	if other := byID(snapshot, ".github/workflows/no-dispatch.yml"); other == nil || other.Jobs[0].Manual {
		t.Fatalf("a workflow without workflow_dispatch has a manual job: %+v", other)
	}
}
