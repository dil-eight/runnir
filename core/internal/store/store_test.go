//go:build !windows

// Workspace databases on disk are a macOS feature (see lock_windows.go):
// on Windows every store is in memory, so these tests run elsewhere.
package store

import (
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"testing"
	"time"

	"modernc.org/sqlite"
)

func fixedNow() time.Time { return time.Date(2026, 10, 22, 12, 0, 0, 0, time.UTC) }

func openTest(t *testing.T, dir string) *Store {
	t.Helper()
	s, err := Open(dir, Options{Now: fixedNow})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = s.Close() })
	return s
}

func TestANewStoreIsCreatedPrivateAndReopened(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "ws")
	s := openTest(t, dir)
	if r := s.Report(); r.State != Persistent || r.Note != "" {
		t.Fatalf("report = %+v", r)
	}
	if v, err := s.userVersion(); err != nil || v != len(migrations) {
		t.Fatalf("version = %d, %v", v, err)
	}
	info, err := os.Stat(dir)
	if err != nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("dir mode = %v, %v", info.Mode(), err)
	}
	if info, err := os.Stat(filepath.Join(dir, "state.sqlite")); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("db mode = %v, %v", info, err)
	}
	if err := s.Close(); err != nil {
		t.Fatal(err)
	}
	again := openTest(t, dir)
	if again.Report().State != Persistent {
		t.Fatalf("reopen = %+v", again.Report())
	}
}

func TestEmptyDirMeansMemory(t *testing.T) {
	s := openTest(t, "")
	if s.Report().State != MemoryOnly || s.Report().Note != "" || s.Dir() != "" {
		t.Fatalf("report = %+v", s.Report())
	}
	if v, err := s.userVersion(); err != nil || v != len(migrations) {
		t.Fatalf("memory schema = %d, %v", v, err)
	}
}

func TestASecondOpenerFallsBackToMemory(t *testing.T) {
	dir := t.TempDir()
	openTest(t, dir)
	second := openTest(t, dir)
	if r := second.Report(); r.State != MemoryOnly || r.Note != "In use by another copy of Runnir." {
		t.Fatalf("second = %+v", r)
	}
}

func TestANewerSchemaIsLeftUntouched(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	if _, err := s.db.Exec("PRAGMA user_version = 99"); err != nil {
		t.Fatal(err)
	}
	_ = s.Close()
	before, _ := os.ReadFile(filepath.Join(dir, "state.sqlite"))
	again := openTest(t, dir)
	if r := again.Report(); r.State != MemoryOnly || r.Note != "Made by a newer version of Runnir (schema 99)." {
		t.Fatalf("report = %+v", r)
	}
	_ = again.Close()
	after, _ := os.ReadFile(filepath.Join(dir, "state.sqlite"))
	if string(before) != string(after) {
		t.Fatal("the newer database was changed")
	}
}

func TestASymlinkedDatabaseIsRefused(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(t.TempDir(), "elsewhere.sqlite")
	_ = os.WriteFile(target, nil, 0o600)
	if err := os.Symlink(target, filepath.Join(dir, "state.sqlite")); err != nil {
		t.Fatal(err)
	}
	s := openTest(t, dir)
	if r := s.Report(); r.State != MemoryOnly || r.Note != "The workspace database is not a regular file." {
		t.Fatalf("report = %+v", r)
	}
}

func TestEveryMemoryConnectionHasTheSchema(t *testing.T) {
	inner, err := sqlite.NewConnector("file::memory:")
	if err != nil {
		t.Fatal(err)
	}
	db := sql.OpenDB(memoryConnector{inner: inner})
	defer db.Close()
	db.SetMaxOpenConns(2)
	ctx := context.Background()
	first, _ := db.Conn(ctx)
	second, _ := db.Conn(ctx) // a second, separate memory database
	defer first.Close()
	defer second.Close()
	for _, conn := range []*sql.Conn{first, second} {
		var version, tables int
		if err := conn.QueryRowContext(ctx, "PRAGMA user_version").Scan(&version); err != nil || version != len(migrations) {
			t.Fatalf("version = %d, %v", version, err)
		}
		if err := conn.QueryRowContext(ctx, "SELECT COUNT(*) FROM local_runs").Scan(&tables); err != nil {
			t.Fatalf("no schema: %v", err)
		}
	}
}
