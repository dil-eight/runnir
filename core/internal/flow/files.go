package flow

import (
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const (
	maxFileBytes = 1 << 20
	maxFiles     = 200
)

// ReadWorkflows reads the workflow files of a working tree, sorted by name:
// regular files only (no symlinks), at most 200 of 1 MiB each, as the
// scanner reads them.
func ReadWorkflows(root string) ([]Workflow, error) {
	dir := filepath.Join(root, ".github", "workflows")
	entries, err := os.ReadDir(dir)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		name := e.Name()
		if e.Type().IsRegular() && (strings.HasSuffix(name, ".yml") || strings.HasSuffix(name, ".yaml")) {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	if len(names) > maxFiles {
		names = names[:maxFiles]
	}
	var out []Workflow
	for _, name := range names {
		path := ".github/workflows/" + name
		data, err := readBounded(filepath.Join(dir, name))
		if err != nil {
			out = append(out, Workflow{Path: path, Name: path, ParseError: "could not be read", Events: map[string]Event{}})
			continue
		}
		out = append(out, Parse(path, data))
	}
	return out, nil
}

func readBounded(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > maxFileBytes {
		return nil, os.ErrInvalid
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return io.ReadAll(io.LimitReader(f, maxFileBytes+1))
}
