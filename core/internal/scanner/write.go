package scanner

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"strings"
	"unicode/utf8"
)

var (
	// ErrReadOnly: the file's permissions do not allow writing it.
	ErrReadOnly = errors.New("the workflow file is read-only")
	// ErrTooLargeToSave: the new content is over the 1 MiB file limit.
	ErrTooLargeToSave = errors.New("the workflow file would be larger than 1 MiB")
	// ErrNotText: the new content is not UTF-8 text.
	ErrNotText = errors.New("the workflow file must be UTF-8 text")
)

// SaveResult says what SaveWorkflowFile did.
type SaveResult struct {
	// SHA256 of the file now on disk: the saved content, or, on a
	// conflict, the content that was left in place.
	SHA256 string
	// Conflict: the file on disk no longer matches baseSHA256 and nothing
	// was written.
	Conflict bool
}

// SHA256 is the hex digest the editor and the Core compare.
func SHA256(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

// SaveWorkflowFile replaces an existing workflow file with content, with the
// rules ReadWorkflowFile reads by: a regular file directly in a
// .github/workflows directory, no symlinks, at most 1 MiB. The file is only
// written while it still has baseSHA256, the digest of what the editor
// loaded, unless overwrite is set. The new content goes to a temporary file
// next to it first and replaces the file in one rename, so a reader never
// sees half a file; the file keeps its permissions.
func SaveWorkflowFile(root, id string, content []byte, baseSHA256 string, overwrite bool) (SaveResult, error) {
	name, err := workflowName(id)
	if err != nil {
		return SaveResult{}, err
	}
	if len(content) > maxFileBytes {
		return SaveResult{}, ErrTooLargeToSave
	}
	if !utf8.Valid(content) {
		return SaveResult{}, ErrNotText
	}
	repo, err := os.OpenRoot(root)
	if err != nil {
		return SaveResult{}, ErrNoWorkflowFile
	}
	defer repo.Close()
	for _, dir := range []string{".github", workflowsDir} {
		info, err := repo.Lstat(dir)
		if err != nil || !info.IsDir() {
			return SaveResult{}, ErrNoWorkflowFile
		}
	}
	target := path.Join(workflowsDir, name)
	info, err := repo.Lstat(target)
	if err != nil || !info.Mode().IsRegular() {
		return SaveResult{}, ErrNoWorkflowFile
	}
	if info.Mode().Perm()&0o200 == 0 {
		return SaveResult{}, ErrReadOnly
	}

	current, err := currentDigest(repo, target)
	if err != nil {
		return SaveResult{}, err
	}
	if !overwrite && current != baseSHA256 {
		return SaveResult{SHA256: current, Conflict: true}, nil
	}

	temporary, err := writeTemporary(repo, name, content, info.Mode().Perm())
	if err != nil {
		return SaveResult{}, err
	}
	// Check once more right before replacing, so a change made while the
	// temporary file was written is not lost either.
	if !overwrite {
		if now, err := currentDigest(repo, target); err != nil || now != baseSHA256 {
			_ = repo.Remove(temporary)
			if err != nil {
				return SaveResult{}, err
			}
			return SaveResult{SHA256: now, Conflict: true}, nil
		}
	}
	if err := repo.Rename(temporary, target); err != nil {
		_ = repo.Remove(temporary)
		return SaveResult{}, fmt.Errorf("replace the workflow file: %w", err)
	}
	if dir, err := repo.Open(workflowsDir); err == nil {
		_ = dir.Sync()
		_ = dir.Close()
	}
	return SaveResult{SHA256: SHA256(content)}, nil
}

// workflowName returns the file name of a workflow id such as
// ".github/workflows/ci.yml", or ErrNoWorkflowFile.
func workflowName(id string) (string, error) {
	name, found := strings.CutPrefix(id, workflowsDir+"/")
	ext := strings.ToLower(path.Ext(name))
	if !found || name == "" || strings.ContainsAny(name, "/\\") || name == "." || name == ".." || strings.HasPrefix(name, ".") ||
		(ext != ".yml" && ext != ".yaml") {
		return "", ErrNoWorkflowFile
	}
	return name, nil
}

func currentDigest(repo *os.Root, target string) (string, error) {
	file, err := repo.Open(target)
	if err != nil {
		return "", ErrNoWorkflowFile
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxFileBytes+1))
	if err != nil {
		return "", ErrNoWorkflowFile
	}
	return SHA256(data), nil
}

func writeTemporary(repo *os.Root, name string, content []byte, perm fs.FileMode) (string, error) {
	var suffix [6]byte
	if _, err := rand.Read(suffix[:]); err != nil {
		return "", fmt.Errorf("name the temporary file: %w", err)
	}
	temporary := path.Join(workflowsDir, "."+name+".runnir-"+hex.EncodeToString(suffix[:])+".tmp")
	file, err := repo.OpenFile(temporary, os.O_WRONLY|os.O_CREATE|os.O_EXCL, perm)
	if err != nil {
		return "", fmt.Errorf("create the temporary file: %w", err)
	}
	_, writeErr := file.Write(content)
	syncErr := file.Sync()
	closeErr := file.Close()
	if err := errors.Join(writeErr, syncErr, closeErr); err != nil {
		_ = repo.Remove(temporary)
		return "", fmt.Errorf("write the temporary file: %w", err)
	}
	// The creation mask may have taken permission bits away.
	if err := repo.Chmod(temporary, perm); err != nil {
		_ = repo.Remove(temporary)
		return "", fmt.Errorf("set the file's permissions: %w", err)
	}
	return temporary, nil
}
