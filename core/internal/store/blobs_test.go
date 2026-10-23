//go:build !windows

package store

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestALogIsKeptAndReadBack(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	ctx := context.Background()
	data := []byte("line one\nline two\n")
	if err := s.PutLog(ctx, 11, data, LogMeta{DroppedLines: 3, Truncated: true}); err != nil {
		t.Fatal(err)
	}
	got, meta, ok, err := s.Log(ctx, 11)
	if err != nil || !ok || !bytes.Equal(got, data) || meta.DroppedLines != 3 || !meta.Truncated {
		t.Fatalf("log = %q %+v %v %v", got, meta, ok, err)
	}
	entries, _ := os.ReadDir(filepath.Join(dir, "blobs"))
	if len(entries) != 1 || len(entries[0].Name()) != 64+len(".log") {
		t.Fatalf("blobs = %v", entries)
	}
	info, _ := os.Stat(filepath.Join(dir, "blobs", entries[0].Name()))
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", info.Mode())
	}
	if u, _ := s.Usage(ctx); u.LogBytes != uint64(len(data)) {
		t.Fatalf("usage = %+v", u)
	}
}

func TestAChangedOrReplacedBlobIsNotTrusted(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	ctx := context.Background()
	_ = s.PutLog(ctx, 11, []byte("original"), LogMeta{})
	entries, _ := os.ReadDir(filepath.Join(dir, "blobs"))
	path := filepath.Join(dir, "blobs", entries[0].Name())
	_ = os.WriteFile(path, []byte("tampered"), 0o600)
	if _, _, ok, _ := s.Log(ctx, 11); ok {
		t.Fatal("tampered blob served")
	}
	_ = s.PutLog(ctx, 12, []byte("second"), LogMeta{})
	entries, _ = os.ReadDir(filepath.Join(dir, "blobs"))
	path = filepath.Join(dir, "blobs", entries[0].Name())
	outside := filepath.Join(t.TempDir(), "secret")
	_ = os.WriteFile(outside, []byte("second"), 0o600)
	_ = os.Remove(path)
	_ = os.Symlink(outside, path)
	if _, _, ok, _ := s.Log(ctx, 12); ok {
		t.Fatal("symlinked blob served")
	}
}

func TestLogsStayWithinTheBudgetOldestUseFirst(t *testing.T) {
	saved := logBudgetBytes
	logBudgetBytes = 25
	t.Cleanup(func() { logBudgetBytes = saved })
	// A clock that moves on every reading, so uses are ordered.
	tick := fixedNow()
	s, err := Open(t.TempDir(), Options{Now: func() time.Time { tick = tick.Add(time.Second); return tick }})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	ctx := context.Background()
	_ = s.PutLog(ctx, 1, bytes.Repeat([]byte("a"), 10), LogMeta{})
	_ = s.PutLog(ctx, 2, bytes.Repeat([]byte("b"), 10), LogMeta{})
	_, _, _, _ = s.Log(ctx, 1) // 1 is now used more recently than 2
	_ = s.PutLog(ctx, 3, bytes.Repeat([]byte("c"), 10), LogMeta{})
	if _, _, ok, _ := s.Log(ctx, 2); ok {
		t.Fatal("least recently used log kept")
	}
	if _, _, ok, _ := s.Log(ctx, 1); !ok {
		t.Fatal("recently used log dropped")
	}
	if err := s.PutLog(ctx, 4, make([]byte, maxBlobBytes+1), LogMeta{}); err != ErrBlobTooLarge {
		t.Fatalf("oversize = %v", err)
	}
}

func TestOrphansAreCleanedAndLogsDeleted(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	ctx := context.Background()
	_ = s.PutLog(ctx, 1, []byte("kept"), LogMeta{})
	stray := filepath.Join(dir, "blobs", "stray.tmp")
	_ = os.WriteFile(stray, []byte("x"), 0o600)
	_ = s.Close()
	again := openTest(t, dir)
	if _, err := os.Stat(stray); !os.IsNotExist(err) {
		t.Fatal("stray file kept")
	}
	if _, _, ok, _ := again.Log(ctx, 1); !ok {
		t.Fatal("valid blob removed")
	}
	if err := again.DeleteLogs(ctx); err != nil {
		t.Fatal(err)
	}
	if entries, _ := os.ReadDir(filepath.Join(dir, "blobs")); len(entries) != 0 {
		t.Fatalf("left %v", entries)
	}
	if _, _, ok, _ := again.Log(ctx, 1); ok {
		t.Fatal("deleted log served")
	}
}

func TestMemoryStoresKeepNoLogs(t *testing.T) {
	s := openTest(t, "")
	ctx := context.Background()
	if err := s.PutLog(ctx, 1, []byte("x"), LogMeta{}); err != nil {
		t.Fatal(err)
	}
	if _, _, ok, _ := s.Log(ctx, 1); ok {
		t.Fatal("memory store kept a log")
	}
}

func TestKeptLogsOfAClosedWorkspaceAreDeleted(t *testing.T) {
	data := t.TempDir()
	id := "5ce88ff0-5c16-43b3-8f20-8e33e852b019"
	s := openTest(t, WorkspaceDir(data, id))
	_ = s.PutLog(context.Background(), 1, []byte("x"), LogMeta{})
	_ = s.Close()
	if err := DeleteKeptLogs(data, id); err != nil {
		t.Fatal(err)
	}
	if entries, _ := os.ReadDir(filepath.Join(WorkspaceDir(data, id), "blobs")); len(entries) != 0 {
		t.Fatalf("left %v", entries)
	}
	again := openTest(t, WorkspaceDir(data, id))
	if u, _ := again.Usage(context.Background()); u.LogBytes != 0 {
		t.Fatalf("rows kept: %+v", u)
	}
}
