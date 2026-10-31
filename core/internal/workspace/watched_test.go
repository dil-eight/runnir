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
