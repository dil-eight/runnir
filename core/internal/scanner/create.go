package scanner

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path"
	"regexp"
	"strings"
	"unicode/utf8"
)

var (
	// ErrBadFileName: the name is not one Runnir gives a new or renamed
	// workflow file.
	ErrBadFileName = errors.New("use letters, digits, dots, dashes and underscores, start with a letter or digit, end in .yml or .yaml, at most 100 characters")
	// ErrExists: another file already has the name.
	ErrExists = errors.New("a file with that name already exists in .github/workflows")
	// ErrTooManyFiles: the folder already has as many workflow files as are read.
	ErrTooManyFiles = errors.New("the repository already has 200 workflow files")
)

// newFileName is the shape of names for new and renamed workflow files:
// one that needs no quoting in a shell, YAML or a URL. ValidNewFileName
// also bounds the length.
var newFileName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*\.(?i:yml|yaml)$`)

// ValidNewFileName reports whether name can be given to a new or renamed
// workflow file.
func ValidNewFileName(name string) bool {
	return len(name) <= 100 && newFileName.MatchString(name)
}

// StarterWorkflow is the file CreateWorkflowFile writes when it is given no
// content: one job that runs by hand, on GitHub or locally with act, and
// passes actionlint.
func StarterWorkflow(fileName string) []byte {
	stem := strings.TrimSuffix(fileName, path.Ext(fileName))
	return fmt.Appendf(nil, `name: %q

on:
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - name: Say hello
        run: echo "Hello from %s"
`, stem, stem)
}

// CreateWorkflowFile adds a workflow file named fileName to
// .github/workflows, making the folders when they are missing, and returns
// its id. It never replaces a file: a name that is taken is ErrExists. The
// folders follow the rules ReadWorkflowFile reads by (real folders, no
// symlinks) and every write stays inside root. Empty content writes
// StarterWorkflow.
func CreateWorkflowFile(root, fileName string, content []byte) (string, error) {
	if !ValidNewFileName(fileName) {
		return "", ErrBadFileName
	}
	if len(content) == 0 {
		content = StarterWorkflow(fileName)
	}
	if len(content) > maxFileBytes {
		return "", ErrTooLargeToSave
	}
	if !utf8.Valid(content) {
		return "", ErrNotText
	}
	repo, err := os.OpenRoot(root)
	if err != nil {
		return "", ErrNoWorkflowFile
	}
	defer repo.Close()
	for _, dir := range []string{".github", workflowsDir} {
		info, err := repo.Lstat(dir)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			if err := repo.Mkdir(dir, 0o755); err != nil && !errors.Is(err, fs.ErrExist) {
				return "", writeError(err, "make the workflows folder")
			}
		case err != nil || !info.IsDir():
			return "", ErrNoWorkflowFile
		}
	}
	if count, err := workflowFileCount(repo); err != nil {
		return "", ErrNoWorkflowFile
	} else if count >= maxWorkflowFiles {
		return "", ErrTooManyFiles
	}

	target := path.Join(workflowsDir, fileName)
	// Written next to it first and linked into place: the link fails when
	// the name is taken, even by a file made a moment ago, and a reader
	// never sees half a file.
	temporary, err := writeTemporary(repo, fileName, content, 0o644)
	if err != nil {
		return "", err
	}
	defer repo.Remove(temporary)
	switch err := repo.Link(temporary, target); {
	case errors.Is(err, fs.ErrExist):
		return "", ErrExists
	case err == nil:
	case errors.Is(err, fs.ErrPermission):
		return "", ErrReadOnly
	default:
		// A file system without hard links: create the name exclusively.
		if err := createExclusive(repo, target, content); err != nil {
			return "", err
		}
	}
	syncWorkflowsDir(repo)
	return target, nil
}

// RenameWorkflowFile gives the workflow file id the name newName in the same
// folder and returns its new id. It never replaces another file; changing
// only the case of the name works on a file system that ignores case.
func RenameWorkflowFile(root, id, newName string) (string, error) {
	name, err := workflowName(id)
	if err != nil {
		return "", err
	}
	if !ValidNewFileName(newName) {
		return "", ErrBadFileName
	}
	target := path.Join(workflowsDir, newName)
	if newName == name {
		return target, nil
	}
	repo, err := os.OpenRoot(root)
	if err != nil {
		return "", ErrNoWorkflowFile
	}
	defer repo.Close()
	for _, dir := range []string{".github", workflowsDir} {
		if info, err := repo.Lstat(dir); err != nil || !info.IsDir() {
			return "", ErrNoWorkflowFile
		}
	}
	source := path.Join(workflowsDir, name)
	info, err := repo.Lstat(source)
	if err != nil || !info.Mode().IsRegular() {
		return "", ErrNoWorkflowFile
	}

	if existing, err := repo.Lstat(target); err == nil {
		if !os.SameFile(info, existing) {
			return "", ErrExists
		}
		// The same file under another case of its name.
		if err := repo.Rename(source, target); err != nil {
			return "", writeError(err, "rename the workflow file")
		}
		syncWorkflowsDir(repo)
		return target, nil
	}
	// A link to the new name fails when the name is taken, so a file made
	// there meanwhile is never replaced; then the old name goes.
	switch err := repo.Link(source, target); {
	case errors.Is(err, fs.ErrExist):
		return "", ErrExists
	case err == nil:
		if err := repo.Remove(source); err != nil {
			_ = repo.Remove(target)
			return "", writeError(err, "remove the old name")
		}
	case errors.Is(err, fs.ErrPermission):
		return "", ErrReadOnly
	default:
		// A file system without hard links; the name was free just now.
		if err := repo.Rename(source, target); err != nil {
			return "", writeError(err, "rename the workflow file")
		}
	}
	syncWorkflowsDir(repo)
	return target, nil
}

func workflowFileCount(repo *os.Root) (int, error) {
	dir, err := repo.Open(workflowsDir)
	if err != nil {
		return 0, err
	}
	defer dir.Close()
	entries, err := dir.ReadDir(-1)
	if err != nil {
		return 0, err
	}
	count := 0
	for _, entry := range entries {
		ext := strings.ToLower(path.Ext(entry.Name()))
		if entry.Type().IsRegular() && (ext == ".yml" || ext == ".yaml") {
			count++
		}
	}
	return count, nil
}

func createExclusive(repo *os.Root, target string, content []byte) error {
	file, err := repo.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o644)
	if errors.Is(err, fs.ErrExist) {
		return ErrExists
	} else if err != nil {
		return writeError(err, "create the workflow file")
	}
	_, writeErr := file.Write(content)
	syncErr := file.Sync()
	closeErr := file.Close()
	if err := errors.Join(writeErr, syncErr, closeErr); err != nil {
		_ = repo.Remove(target)
		return fmt.Errorf("write the workflow file: %w", err)
	}
	return nil
}

func writeError(err error, action string) error {
	if errors.Is(err, fs.ErrPermission) {
		return ErrReadOnly
	}
	return fmt.Errorf("%s: %w", action, err)
}

func syncWorkflowsDir(repo *os.Root) {
	if dir, err := repo.Open(workflowsDir); err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}
}
