//go:build !windows

package store

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWorkspaceIDsAreNormalized(t *testing.T) {
	id, ok := NormalizeWorkspaceID("5CE88FF0-5C16-43B3-8F20-8E33E852B019")
	if !ok || id != "5ce88ff0-5c16-43b3-8f20-8e33e852b019" {
		t.Fatalf("id = %q, %v", id, ok)
	}
	for _, bad := range []string{"", "..", "5ce88ff0", "5ce88ff0-5c16-43b3-8f20-8e33e852b01g", "../5ce88ff0-5c16-43b3-8f20-8e33e852b019"} {
		if _, ok := NormalizeWorkspaceID(bad); ok {
			t.Fatalf("%q accepted", bad)
		}
	}
}

func TestWorkspacesListsOnlyWorkspaceDirectories(t *testing.T) {
	data := t.TempDir()
	id := "5ce88ff0-5c16-43b3-8f20-8e33e852b019"
	_ = os.MkdirAll(WorkspaceDir(data, id), 0o700)
	_ = os.MkdirAll(filepath.Join(data, "repositories", "not-an-id"), 0o700)
	_ = os.WriteFile(filepath.Join(data, "repositories", "6ce88ff0-5c16-43b3-8f20-8e33e852b019"), nil, 0o600)
	ids, err := Workspaces(data)
	if err != nil || len(ids) != 1 || ids[0] != id {
		t.Fatalf("ids = %v, %v", ids, err)
	}
	if ids, err := Workspaces(filepath.Join(data, "missing")); err != nil || len(ids) != 0 {
		t.Fatalf("missing = %v, %v", ids, err)
	}
}

func TestDeleteWorkspaceRemovesOnlyItsDirectory(t *testing.T) {
	data := t.TempDir()
	id := "5ce88ff0-5c16-43b3-8f20-8e33e852b019"
	outside := filepath.Join(t.TempDir(), "keep.txt")
	_ = os.WriteFile(outside, []byte("x"), 0o600)
	dir := WorkspaceDir(data, id)
	_ = os.MkdirAll(dir, 0o700)
	_ = os.Symlink(outside, filepath.Join(dir, "link"))
	if err := DeleteWorkspace(data, id); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(dir); !os.IsNotExist(err) {
		t.Fatal("directory kept")
	}
	if _, err := os.Stat(outside); err != nil {
		t.Fatal("followed a symlink")
	}
	if err := DeleteWorkspace(data, id); err != nil {
		t.Fatal("deleting a missing workspace must succeed")
	}
	if err := DeleteWorkspace(data, "../x"); err == nil {
		t.Fatal("invalid id accepted")
	}
}
