package dotenv

import (
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
)

// Bounds of Find: a repository's .env files sit near its root, and a large
// tree must not hold the menu up.
const (
	maxDepth   = 6
	maxFound   = 100
	maxEntries = 50000
)

// Find lists the .env files of a working tree as slash paths from root,
// nearer the root first: files named .env or .env.*, not templates
// (.example, .sample). It looks into neither .git, node_modules nor another
// repository inside this one (a submodule or a worktree), and follows no
// symbolic link. None when root cannot be read.
func Find(root string) []string {
	var found []string
	entries := 0
	level := []string{""}
	for depth := 0; depth <= maxDepth && len(level) > 0; depth++ {
		var next []string
		for _, dir := range level {
			items, err := os.ReadDir(filepath.Join(root, filepath.FromSlash(dir)))
			if err != nil {
				continue
			}
			entries += len(items)
			if dir != "" && containsGit(items) {
				continue
			}
			for _, item := range items {
				name := item.Name()
				switch {
				case item.IsDir():
					if name != ".git" && name != "node_modules" {
						next = append(next, path.Join(dir, name))
					}
				case item.Type().IsRegular() && isEnvFile(name):
					found = append(found, path.Join(dir, name))
				}
			}
			if len(found) >= maxFound || entries >= maxEntries {
				return sorted(found)
			}
		}
		level = next
	}
	return sorted(found)
}

func containsGit(items []os.DirEntry) bool {
	for _, item := range items {
		if item.Name() == ".git" {
			return true
		}
	}
	return false
}

func isEnvFile(name string) bool {
	lower := strings.ToLower(name)
	if lower != ".env" && !strings.HasPrefix(lower, ".env.") {
		return false
	}
	return !strings.HasSuffix(lower, ".example") && !strings.HasSuffix(lower, ".sample")
}

// sorted orders paths by depth, then by name; at most maxFound.
func sorted(paths []string) []string {
	sort.SliceStable(paths, func(i, j int) bool {
		di, dj := strings.Count(paths[i], "/"), strings.Count(paths[j], "/")
		if di != dj {
			return di < dj
		}
		return paths[i] < paths[j]
	})
	if len(paths) > maxFound {
		paths = paths[:maxFound]
	}
	return paths
}
