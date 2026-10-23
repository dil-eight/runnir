package store

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var workspaceIDPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

// ErrInvalidWorkspace means an id is not a workspace UUID.
var ErrInvalidWorkspace = errors.New("not a workspace id")

// NormalizeWorkspaceID lowercases a registry UUID and reports whether it is one.
func NormalizeWorkspaceID(id string) (string, bool) {
	id = strings.ToLower(id)
	return id, workspaceIDPattern.MatchString(id)
}

// WorkspaceDir is a workspace's directory under the Core's data directory.
// id must be normalized.
func WorkspaceDir(dataDir, id string) string {
	return filepath.Join(dataDir, "repositories", id)
}

// Workspaces lists the ids of the workspace directories under dataDir.
func Workspaces(dataDir string) ([]string, error) {
	entries, err := os.ReadDir(filepath.Join(dataDir, "repositories"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var ids []string
	for _, entry := range entries {
		if entry.IsDir() && workspaceIDPattern.MatchString(entry.Name()) {
			ids = append(ids, entry.Name())
		}
	}
	return ids, nil
}

// DeleteWorkspace removes a workspace's directory and everything in it,
// without following symlinks. The caller makes sure it is not open.
func DeleteWorkspace(dataDir, id string) error {
	id, ok := NormalizeWorkspaceID(id)
	if !ok {
		return ErrInvalidWorkspace
	}
	dir := WorkspaceDir(dataDir, id)
	info, err := os.Lstat(dir)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return os.Remove(dir)
	}
	return os.RemoveAll(dir)
}
