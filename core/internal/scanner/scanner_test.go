package scanner

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

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
	if got := scan(t, worktree).Branch; got != "topic" {
		t.Fatalf("absolute gitdir: branch = %q", got)
	}

	relative := filepath.Join(main, "wt-rel")
	write(t, relative, ".git", "gitdir: ../.git/worktrees/wt\n")
	if got := scan(t, relative).Branch; got != "topic" {
		t.Fatalf("relative gitdir: branch = %q", got)
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
