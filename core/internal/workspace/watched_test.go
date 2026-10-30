//go:build !windows

package workspace

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"runnir/core/internal/store"
)

const wsSecond = "9ce88ff0-5c16-43b3-8f20-8e33e852b019"

func TestOpenRunsComeFromAnOpenWorkspaceOfTheRepository(t *testing.T) {
	f, accounts := newFake(t)
	f.set(func(f *fakeGitHub) {
		f.runs = `{"workflow_runs":[{"id":7,"workflow_id":3,"name":"CI","run_number":1,"run_attempt":1,"status":"in_progress","actor":{"login":"ana"},"created_at":"2026-10-28T10:00:00Z","updated_at":"2026-10-28T10:01:00Z"},
{"id":6,"workflow_id":3,"name":"CI","run_number":1,"run_attempt":1,"status":"completed","conclusion":"failure","actor":{"login":"bo"},"created_at":"2026-10-28T09:00:00Z","updated_at":"2026-10-28T09:01:00Z"}]}`
	})
	data := t.TempDir()
	m := newRuntimes(t, data)
	r, _ := m.Attach(wsA, "repo_1", fixedResolver(accounts, "o", "r"))
	waitRefresh(t, r)
	source := store.Source{Repository: "o/r"}

	runs, readAt, ok := m.OpenRuns(context.Background(), []string{wsClosed, wsA}, source, "ana", 50)
	if !ok || len(runs) != 1 || runs[0].ID != 7 || readAt.IsZero() {
		t.Fatalf("open runs = %+v, %v, %v", runs, readAt, ok)
	}
	if _, _, ok := m.OpenRuns(context.Background(), []string{wsA}, store.Source{Repository: "o/other"}, "ana", 50); ok {
		t.Fatal("another repository's data is not this one's")
	}
	if _, _, ok := m.OpenRuns(context.Background(), []string{wsClosed}, source, "ana", 50); ok {
		t.Fatal("a closed workspace is not open")
	}
}

func TestStartsAreJoinedFromOpenAndClosedWorkspacesReadOnly(t *testing.T) {
	_, accounts := newFake(t)
	data := t.TempDir()
	source := store.Source{Repository: "o/r"}
	at := time.Date(2026, 10, 28, 9, 0, 0, 0, time.UTC)

	// A closed workspace left a start of run 7 on disk.
	closed, err := store.Open(store.WorkspaceDir(data, wsClosed), store.Options{})
	if err != nil {
		t.Fatal(err)
	}
	if err := closed.RecordStart(context.Background(), store.RunStart{Source: source, RunID: 7, Attempt: 1, Kind: store.StartDispatch, SentAt: at}); err != nil {
		t.Fatal(err)
	}
	_ = closed.Close()
	file := filepath.Join(store.WorkspaceDir(data, wsClosed), "state.sqlite")
	before, _ := os.ReadFile(file)

	m := newRuntimes(t, data)
	open, _ := m.Attach(wsA, "repo_1", fixedResolver(accounts, "o", "r"))
	if err := open.Store().RecordStart(context.Background(), store.RunStart{Source: source, RunID: 7, Attempt: 2, Kind: store.StartRerun, SentAt: at.Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	// A third one's folder holds a file that is not a database.
	damaged := store.WorkspaceDir(data, wsSecond)
	_ = os.MkdirAll(damaged, 0o700)
	_ = os.WriteFile(filepath.Join(damaged, "state.sqlite"), []byte("not a database"), 0o600)

	starts := m.Starts(context.Background(), []string{wsA, wsClosed, wsSecond, "not-an-id"}, source)
	got := starts[7]
	if len(got) != 2 || got[0].Attempt != 1 || got[0].Kind != store.StartDispatch || got[1].Attempt != 2 {
		t.Fatalf("starts = %+v", starts)
	}
	if after, _ := os.ReadFile(file); len(before) == 0 || !bytes.Equal(before, after) {
		t.Fatal("the closed workspace's database was changed")
	}
}
