package scanner

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func saveFixture(t *testing.T) (root, file string, original []byte) {
	t.Helper()
	root = t.TempDir()
	dir := filepath.Join(root, ".github", "workflows")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	original = []byte("name: CI\non: push\n")
	file = filepath.Join(dir, "ci.yml")
	if err := os.WriteFile(file, original, 0o640); err != nil {
		t.Fatal(err)
	}
	return root, file, original
}

func TestSaveReplacesTheFileAndKeepsItsMode(t *testing.T) {
	root, file, original := saveFixture(t)
	content := []byte("name: CI\non: [push, pull_request]\n")
	result, err := SaveWorkflowFile(root, ".github/workflows/ci.yml", content, SHA256(original), false)
	if err != nil || result.Conflict || result.SHA256 != SHA256(content) {
		t.Fatalf("result = %+v, %v", result, err)
	}
	data, _ := os.ReadFile(file)
	if string(data) != string(content) {
		t.Fatalf("file = %q", data)
	}
	if runtime.GOOS != "windows" {
		if info, _ := os.Stat(file); info.Mode().Perm() != 0o640 {
			t.Fatalf("mode = %v", info.Mode().Perm())
		}
	}
	entries, _ := os.ReadDir(filepath.Dir(file))
	if len(entries) != 1 {
		t.Fatalf("left behind: %v", entries)
	}
}

func TestAChangedFileIsAConflictAndStaysAsItIs(t *testing.T) {
	root, file, original := saveFixture(t)
	elsewhere := []byte("name: CI\non: push\n# edited elsewhere\n")
	if err := os.WriteFile(file, elsewhere, 0o640); err != nil {
		t.Fatal(err)
	}
	result, err := SaveWorkflowFile(root, ".github/workflows/ci.yml", []byte("mine\n"), SHA256(original), false)
	if err != nil || !result.Conflict || result.SHA256 != SHA256(elsewhere) {
		t.Fatalf("result = %+v, %v", result, err)
	}
	if data, _ := os.ReadFile(file); string(data) != string(elsewhere) {
		t.Fatalf("file overwritten: %q", data)
	}

	result, err = SaveWorkflowFile(root, ".github/workflows/ci.yml", []byte("mine\n"), SHA256(original), true)
	if err != nil || result.Conflict {
		t.Fatalf("overwrite = %+v, %v", result, err)
	}
	if data, _ := os.ReadFile(file); string(data) != "mine\n" {
		t.Fatalf("file = %q", data)
	}
}

func TestSaveRefusesWhatItMustNotWrite(t *testing.T) {
	root, file, original := saveFixture(t)
	base := SHA256(original)
	for name, tc := range map[string]struct {
		id      string
		content []byte
		want    error
	}{
		"outside workflows": {"README.md", []byte("x"), ErrNoWorkflowFile},
		"climbing out":      {".github/workflows/../ci.yml", []byte("x"), ErrNoWorkflowFile},
		"not yaml":          {".github/workflows/ci.txt", []byte("x"), ErrNoWorkflowFile},
		"hidden":            {".github/workflows/.ci.yml", []byte("x"), ErrNoWorkflowFile},
		"missing file":      {".github/workflows/new.yml", []byte("x"), ErrNoWorkflowFile},
		"too large":         {".github/workflows/ci.yml", []byte(strings.Repeat("a", maxFileBytes+1)), ErrTooLargeToSave},
		"not text":          {".github/workflows/ci.yml", []byte{0xff, 0xfe, 0x00}, ErrNotText},
	} {
		if _, err := SaveWorkflowFile(root, tc.id, tc.content, base, false); !errors.Is(err, tc.want) {
			t.Errorf("%s: %v, want %v", name, err, tc.want)
		}
	}
	if data, _ := os.ReadFile(file); string(data) != string(original) {
		t.Fatalf("file changed: %q", data)
	}
}

func TestSaveRefusesAReadOnlyFile(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX permissions")
	}
	root, file, original := saveFixture(t)
	if err := os.Chmod(file, 0o444); err != nil {
		t.Fatal(err)
	}
	if _, err := SaveWorkflowFile(root, ".github/workflows/ci.yml", []byte("x\n"), SHA256(original), true); !errors.Is(err, ErrReadOnly) {
		t.Fatalf("err = %v", err)
	}
}

func TestSaveNeverFollowsSymlinks(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	outside := t.TempDir()
	victim := filepath.Join(outside, "victim.yml")
	if err := os.WriteFile(victim, []byte("keep\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// The workflow file itself is a symlink.
	root, file, _ := saveFixture(t)
	_ = os.Remove(file)
	if err := os.Symlink(victim, file); err != nil {
		t.Fatal(err)
	}
	if _, err := SaveWorkflowFile(root, ".github/workflows/ci.yml", []byte("x\n"), SHA256([]byte("keep\n")), true); !errors.Is(err, ErrNoWorkflowFile) {
		t.Fatalf("symlinked file: %v", err)
	}

	// The workflows directory is a symlink out of the repository.
	root2 := t.TempDir()
	_ = os.MkdirAll(filepath.Join(root2, ".github"), 0o755)
	_ = os.MkdirAll(filepath.Join(outside, "workflows"), 0o755)
	_ = os.WriteFile(filepath.Join(outside, "workflows", "ci.yml"), []byte("keep\n"), 0o644)
	if err := os.Symlink(filepath.Join(outside, "workflows"), filepath.Join(root2, ".github", "workflows")); err != nil {
		t.Fatal(err)
	}
	if _, err := SaveWorkflowFile(root2, ".github/workflows/ci.yml", []byte("x\n"), SHA256([]byte("keep\n")), true); !errors.Is(err, ErrNoWorkflowFile) {
		t.Fatalf("symlinked directory: %v", err)
	}
	for _, path := range []string{victim, filepath.Join(outside, "workflows", "ci.yml")} {
		if data, _ := os.ReadFile(path); string(data) != "keep\n" {
			t.Fatalf("%s was written: %q", path, data)
		}
	}
}

func TestSaveRefusesAReadOnlyFolder(t *testing.T) {
	if runtime.GOOS == "windows" || os.Getuid() == 0 {
		t.Skip("POSIX permissions as a normal user")
	}
	root, file, original := saveFixture(t)
	dir := filepath.Dir(file)
	if err := os.Chmod(dir, 0o555); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(dir, 0o755)
	if _, err := SaveWorkflowFile(root, ".github/workflows/ci.yml", []byte("x\n"), SHA256(original), false); !errors.Is(err, ErrReadOnly) {
		t.Fatalf("err = %v", err)
	}
	if data, _ := os.ReadFile(file); string(data) != string(original) {
		t.Fatalf("file changed: %q", data)
	}
}
