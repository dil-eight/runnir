//go:build !windows

package store

import (
	"context"
	"fmt"
	"io/fs"
	"path/filepath"
	"strings"
	"testing"

	"runnir/core/internal/github"
)

func TestClearCacheKeepsLocalRuns(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{run(1, 1, "completed"), run(2, 2, "completed")}, true))
	record(t, s, "exec_1", LocalSucceeded)
	u, err := s.Usage(ctx)
	if err != nil || u.CachedRuns != 2 || u.LocalRuns != 1 || u.DatabaseBytes == 0 {
		t.Fatalf("usage = %+v, %v", u, err)
	}
	if err := s.ClearCache(ctx); err != nil {
		t.Fatal(err)
	}
	a, _ := s.Activity(ctx, 50)
	if a.HasSource || len(a.Runs) != 0 || len(a.Workflows) != 0 || !a.SyncedAt.IsZero() {
		t.Fatalf("after clear = %+v", a)
	}
	if tags, _ := s.ETags(ctx, source); tags != (Tags{}) {
		t.Fatal("etags survived")
	}
	if u, _ := s.Usage(ctx); u.CachedRuns != 0 || u.LocalRuns != 1 {
		t.Fatalf("usage after clear = %+v", u)
	}
}

func TestPeekReadsAClosedWorkspaceWithoutChangingIt(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	_, _ = s.ApplySync(context.Background(), pass(0, []github.Run{run(1, 1, "completed")}, true))
	record(t, s, "exec_1", LocalRunning) // would become interrupted if opened
	_ = s.Close()
	before := snapshotTree(t, dir)
	u, report, ok := Peek(dir)
	if !ok || report.State != Persistent || u.CachedRuns != 1 || u.LocalRuns != 1 || u.DatabaseBytes == 0 {
		t.Fatalf("peek = %+v %+v %v", u, report, ok)
	}
	if after := snapshotTree(t, dir); after != before {
		t.Fatalf("peek changed files:\n%s\n%s", before, after)
	}
	if _, _, ok := Peek(filepath.Join(dir, "missing")); ok {
		t.Fatal("a missing workspace reported data")
	}
}

// snapshotTree lists every file under dir with its size and modification time.
func snapshotTree(t *testing.T, dir string) string {
	t.Helper()
	var out strings.Builder
	_ = filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			info, _ := d.Info()
			fmt.Fprintf(&out, "%s %d %d\n", path, info.Size(), info.ModTime().UnixNano())
		}
		return nil
	})
	return out.String()
}
