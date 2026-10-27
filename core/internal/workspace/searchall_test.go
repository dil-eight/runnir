//go:build !windows

package workspace

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

const (
	wsClosed  = "7ce88ff0-5c16-43b3-8f20-8e33e852b019"
	wsDamaged = "8ce88ff0-5c16-43b3-8f20-8e33e852b019"
)

// saveClosedWorkspace fills a workspace the way a past session left it.
func saveClosedWorkspace(t *testing.T, data, id string) {
	t.Helper()
	st, err := store.Open(store.WorkspaceDir(data, id), store.Options{})
	if err != nil {
		t.Fatal(err)
	}
	at := time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC)
	src := store.Source{ServerID: "github.com", Repository: "o/mobile-app"}
	_, err = st.ApplySync(context.Background(), store.Pass{
		Source: src, At: at, OK: true, DefaultBranch: "main",
		Runs: &store.RunsUpdate{Runs: []github.Run{
			{ID: 12, Name: "CI", DisplayTitle: "Fix flaky login test", RunNumber: 12, Status: "completed", Conclusion: "failure", Branch: "main", Actor: "ana", Event: "push", CreatedAt: at},
			{ID: 11, Name: "Deploy", DisplayTitle: "Release 4.2", RunNumber: 11, Status: "completed", Conclusion: "success", Branch: "main", Actor: "bo", Event: "push", CreatedAt: at.Add(-time.Hour)},
		}},
		Workflows: &store.WorkflowsUpdate{Workflows: []github.Workflow{
			{ID: 1, Name: "Deploy", Path: ".github/workflows/deploy.yml", State: "active"},
			{ID: 2, Name: "CI", Path: ".github/workflows/ci.yml", State: "active"},
		}},
		PullRequests: &store.PullRequestsUpdate{PullRequests: []github.RepositoryPullRequest{
			{Number: 7, Title: "Fix login redirect", State: "open", Author: "ana", HeadRef: "fix-login", BaseRef: "main", UpdatedAt: at},
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := st.RecordLocalRun(context.Background(), store.LocalRun{
		ExecutionID: "exec_1", WorkflowPath: ".github/workflows/deploy.yml", Event: "push", State: store.LocalFailed,
		StartedAt: at, Message: "Docker is not running",
	}); err != nil {
		t.Fatal(err)
	}
	if err := st.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestSearchAllReadsOpenAndClosedWorkspaces(t *testing.T) {
	f, accounts := newFake(t)
	f.set(func(f *fakeGitHub) {
		f.runs = `{"workflow_runs":[{"id":7,"workflow_id":3,"name":"CI","display_title":"Fix login on Safari","run_number":1,"run_attempt":1,"status":"completed","conclusion":"success","created_at":"2026-10-18T10:00:00Z","updated_at":"2026-10-18T10:04:00Z"}]}`
	})
	data := t.TempDir()
	m := newRuntimes(t, data)
	r, _ := m.Attach(wsA, "repo_1", fixedResolver(accounts, "o", "r"))
	waitRefresh(t, r)
	saveClosedWorkspace(t, data, wsClosed)

	hits, err := m.SearchAll(context.Background(), []string{wsA, wsClosed}, "login", 0)
	if err != nil || len(hits) != 2 {
		t.Fatalf("hits = %+v, %v", hits, err)
	}
	open, closed := hits[0], hits[1]
	if !open.Open || open.Repository != "o/r" || open.RunsMatched != 1 || open.Runs[0].ID != 7 {
		t.Fatalf("open = %+v", open)
	}
	if closed.Open || closed.Repository != "o/mobile-app" || closed.RunsMatched != 1 || closed.Runs[0].ID != 12 {
		t.Fatalf("closed runs = %+v", closed)
	}
	if closed.PullRequestsMatched != 1 || closed.PullRequests[0].Number != 7 {
		t.Fatalf("closed pull requests = %+v", closed.PullRequests)
	}
	if closed.WorkflowsMatched != 0 || closed.LocalRunsMatched != 0 {
		t.Fatalf("nothing about a login in workflows or local runs: %+v", closed)
	}
	if closed.SavedAt.IsZero() {
		t.Fatal("a closed workspace says how old its data is")
	}

	hits, _ = m.SearchAll(context.Background(), []string{wsClosed}, "deploy", 0)
	if c := hits[0]; c.WorkflowsMatched != 1 || c.Workflows[0].Path != ".github/workflows/deploy.yml" ||
		c.LocalRunsMatched != 1 || c.LocalRuns[0].ExecutionID != "exec_1" || c.RunsMatched != 1 || c.Runs[0].ID != 11 {
		t.Fatalf("deploy = %+v", c)
	}
	hits, _ = m.SearchAll(context.Background(), []string{wsClosed}, "#7", 0)
	if c := hits[0]; c.PullRequestsMatched != 1 || c.RunsMatched != 0 {
		t.Fatalf("#7 is the pull request number, not a run number: %+v", c)
	}
}

func TestSearchAllUsesTheRunGrammarForRunsAndSkipsOtherKindsForQualifiers(t *testing.T) {
	data := t.TempDir()
	saveClosedWorkspace(t, data, wsClosed)
	m := newRuntimes(t, data)
	hits, err := m.SearchAll(context.Background(), []string{wsClosed}, "status:failed", 0)
	if err != nil {
		t.Fatal(err)
	}
	if c := hits[0]; c.RunsMatched != 1 || c.Runs[0].ID != 12 || c.PullRequestsMatched+c.WorkflowsMatched+c.LocalRunsMatched != 0 {
		t.Fatalf("status:failed = %+v", c)
	}
	hits, _ = m.SearchAll(context.Background(), []string{wsClosed}, "author:bo release", 0)
	if c := hits[0]; c.RunsMatched != 1 || c.Runs[0].ID != 11 {
		t.Fatalf("author:bo release = %+v", c)
	}
	hits, _ = m.SearchAll(context.Background(), []string{wsClosed}, "   ", 0)
	if c := hits[0]; c.RunsMatched != 0 || c.Repository != "" {
		t.Fatalf("an empty query reads nothing: %+v", c)
	}
}

func TestSearchAllLeavesAClosedWorkspaceAsItWas(t *testing.T) {
	data := t.TempDir()
	saveClosedWorkspace(t, data, wsClosed)
	dir := store.WorkspaceDir(data, wsClosed)
	before := snapshotDir(t, dir)
	m := newRuntimes(t, data)
	if _, err := m.SearchAll(context.Background(), []string{wsClosed}, "login", 0); err != nil {
		t.Fatal(err)
	}
	if after := snapshotDir(t, dir); !equalFiles(before, after) {
		t.Fatalf("searching changed the workspace folder:\nbefore %v\nafter  %v", before, after)
	}
	// An open workspace holds the lock; a closed one is read without taking it.
	other, err := store.Open(dir, store.Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close()
	if other.Report().State != store.Persistent {
		t.Fatal("the lock was not free: the search kept it")
	}
}

func TestSearchAllSkipsAWorkspaceItCannotReadWithANote(t *testing.T) {
	data := t.TempDir()
	saveClosedWorkspace(t, data, wsClosed)
	dir := store.WorkspaceDir(data, wsDamaged)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "state.sqlite"), []byte("not a database at all"), 0o600); err != nil {
		t.Fatal(err)
	}
	m := newRuntimes(t, data)
	hits, err := m.SearchAll(context.Background(), []string{wsDamaged, wsClosed}, "login", 0)
	if err != nil || len(hits) != 2 {
		t.Fatalf("hits = %+v, %v", hits, err)
	}
	if hits[0].Problem == "" || hits[0].RunsMatched != 0 {
		t.Fatalf("damaged = %+v", hits[0])
	}
	if hits[1].Problem != "" || hits[1].RunsMatched != 1 {
		t.Fatalf("the other workspace is still searched: %+v", hits[1])
	}
}

func TestSearchAllLimitsEachKindAndCountsTheRest(t *testing.T) {
	data := t.TempDir()
	st, _ := store.Open(store.WorkspaceDir(data, wsClosed), store.Options{})
	at := time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC)
	var runs []github.Run
	for i := 30; i >= 1; i-- {
		runs = append(runs, github.Run{ID: int64(i), Name: "CI", DisplayTitle: "Build", RunNumber: int64(i), Status: "completed", Conclusion: "success", CreatedAt: at.Add(time.Duration(i) * time.Minute)})
	}
	src := store.Source{Repository: "o/r"}
	if _, err := st.ApplySync(context.Background(), store.Pass{Source: src, At: at, OK: true, Runs: &store.RunsUpdate{Runs: runs}}); err != nil {
		t.Fatal(err)
	}
	// Older runs only the index knows, more than one kind's limit.
	var older []github.Run
	for i := 100; i < 120; i++ {
		older = append(older, github.Run{ID: int64(i), Name: "CI", DisplayTitle: "Build", RunNumber: int64(i), Status: "completed", Conclusion: "success", CreatedAt: at.Add(-time.Duration(i) * time.Hour)})
	}
	if err := st.IndexRuns(context.Background(), src, older); err != nil {
		t.Fatal(err)
	}
	_ = st.Close()
	m := newRuntimes(t, data)
	hits, _ := m.SearchAll(context.Background(), []string{wsClosed}, "build", 5)
	if c := hits[0]; len(c.Runs) != 5 || c.RunsMatched != 50 || c.Runs[0].ID != 30 {
		t.Fatalf("limited = %d shown of %d, first %d; the index's matches beyond the limit are counted", len(c.Runs), c.RunsMatched, c.Runs[0].ID)
	}
}

func snapshotDir(t *testing.T, dir string) map[string]string {
	t.Helper()
	out := map[string]string{}
	err := filepath.WalkDir(dir, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(dir, path)
		out[rel] = info.ModTime().String() + "/" + fmt.Sprint(info.Size())
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func equalFiles(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}
