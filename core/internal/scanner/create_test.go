package scanner

import (
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"testing"
)

func TestCreateMakesTheFoldersAndAStarterThatRunsByHand(t *testing.T) {
	root := t.TempDir()
	id, err := CreateWorkflowFile(root, "deploy.yml", nil)
	if err != nil || id != ".github/workflows/deploy.yml" {
		t.Fatalf("create = %q, %v", id, err)
	}
	data, err := ReadWorkflowFile(root, id)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != string(StarterWorkflow("deploy.yml")) || !strings.Contains(string(data), "workflow_dispatch") ||
		!strings.HasPrefix(string(data), `name: "deploy"`) {
		t.Fatalf("starter = %q", data)
	}
	files, err := ReadWorkflowFiles(t.Context(), root)
	if err != nil || len(files) != 1 {
		t.Fatalf("listed %v, %v; no temporary file may be left", files, err)
	}
	entries, _ := os.ReadDir(filepath.Join(root, ".github", "workflows"))
	if len(entries) != 1 {
		t.Fatalf("left behind: %v", entries)
	}

	// Given content is written as it is.
	if _, err := CreateWorkflowFile(root, "lint.yaml", []byte("name: Lint\n")); err != nil {
		t.Fatal(err)
	}
	if data, _ := ReadWorkflowFile(root, ".github/workflows/lint.yaml"); string(data) != "name: Lint\n" {
		t.Fatalf("lint = %q", data)
	}
}

func TestCreateNeverReplacesAFile(t *testing.T) {
	root, file, original := saveFixture(t)
	if _, err := CreateWorkflowFile(root, "ci.yml", []byte("mine\n")); !errors.Is(err, ErrExists) {
		t.Fatalf("err = %v", err)
	}
	if data, _ := os.ReadFile(file); string(data) != string(original) {
		t.Fatalf("file replaced: %q", data)
	}
	entries, _ := os.ReadDir(filepath.Dir(file))
	if len(entries) != 1 {
		t.Fatalf("left behind: %v", entries)
	}
}

func TestCreateRefusesWhatItMustNotWrite(t *testing.T) {
	root, _, _ := saveFixture(t)
	for name, tc := range map[string]struct {
		file    string
		content []byte
		want    error
	}{
		"folder":       {"sub/ci.yml", nil, ErrBadFileName},
		"climbing out": {"../ci.yml", nil, ErrBadFileName},
		"hidden":       {".ci.yml", nil, ErrBadFileName},
		"not yaml":     {"ci.json", nil, ErrBadFileName},
		"spaces":       {"my ci.yml", nil, ErrBadFileName},
		"too long":     {strings.Repeat("a", 97) + ".yml", nil, ErrBadFileName},
		"too large":    {"big.yml", []byte(strings.Repeat("a", maxFileBytes+1)), ErrTooLargeToSave},
		"not text":     {"bin.yml", []byte{0xff, 0xfe}, ErrNotText},
	} {
		if _, err := CreateWorkflowFile(root, tc.file, tc.content); !errors.Is(err, tc.want) {
			t.Errorf("%s: %v, want %v", name, err, tc.want)
		}
	}
	if !ValidNewFileName(strings.Repeat("a", 96)+".yml") || !ValidNewFileName("Release_v2.YAML") || ValidNewFileName(strings.Repeat("a", 96)+".yaml") {
		t.Fatal("valid names refused")
	}
	if entries, _ := os.ReadDir(filepath.Join(root, ".github", "workflows")); len(entries) != 1 {
		t.Fatalf("written: %v", entries)
	}
}

func TestCreateStopsAtTheFilesTheScannerReads(t *testing.T) {
	root, _, _ := saveFixture(t)
	dir := filepath.Join(root, ".github", "workflows")
	for i := 1; i < maxWorkflowFiles; i++ {
		if err := os.WriteFile(filepath.Join(dir, "w"+strconv.Itoa(i)+".yml"), []byte("x"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := CreateWorkflowFile(root, "one-more.yml", nil); !errors.Is(err, ErrTooManyFiles) {
		t.Fatalf("err = %v", err)
	}
}

func TestCreateNeverFollowsSymlinks(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("symlinks need privileges on Windows")
	}
	outside := t.TempDir()
	root := t.TempDir()
	_ = os.MkdirAll(filepath.Join(root, ".github"), 0o755)
	if err := os.Symlink(outside, filepath.Join(root, ".github", "workflows")); err != nil {
		t.Fatal(err)
	}
	if _, err := CreateWorkflowFile(root, "ci.yml", nil); !errors.Is(err, ErrNoWorkflowFile) {
		t.Fatalf("err = %v", err)
	}
	if entries, _ := os.ReadDir(outside); len(entries) != 0 {
		t.Fatalf("written outside: %v", entries)
	}
}

func TestRenameKeepsTheFileAndNeverReplacesAnother(t *testing.T) {
	root, file, original := saveFixture(t)
	id, err := RenameWorkflowFile(root, ".github/workflows/ci.yml", "build.yml")
	if err != nil || id != ".github/workflows/build.yml" {
		t.Fatalf("rename = %q, %v", id, err)
	}
	if _, err := os.Lstat(file); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("old name left: %v", err)
	}
	renamed := filepath.Join(filepath.Dir(file), "build.yml")
	if data, _ := os.ReadFile(renamed); string(data) != string(original) {
		t.Fatalf("content = %q", data)
	}
	if runtime.GOOS != "windows" {
		if info, _ := os.Stat(renamed); info.Mode().Perm() != 0o640 {
			t.Fatalf("mode = %v", info.Mode().Perm())
		}
	}

	if err := os.WriteFile(filepath.Join(filepath.Dir(file), "other.yml"), []byte("other\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := RenameWorkflowFile(root, ".github/workflows/build.yml", "other.yml"); !errors.Is(err, ErrExists) {
		t.Fatalf("taken name: %v", err)
	}
	if data, _ := os.ReadFile(filepath.Join(filepath.Dir(file), "other.yml")); string(data) != "other\n" {
		t.Fatalf("other replaced: %q", data)
	}
	if data, _ := os.ReadFile(renamed); string(data) != string(original) {
		t.Fatalf("source lost: %q", data)
	}

	// Only the case changes: works whether or not the file system ignores case.
	id, err = RenameWorkflowFile(root, ".github/workflows/build.yml", "Build.yml")
	if err != nil || id != ".github/workflows/Build.yml" {
		t.Fatalf("case rename = %q, %v", id, err)
	}
	entries, _ := os.ReadDir(filepath.Dir(file))
	names := []string{}
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	if strings.Join(names, ",") != "Build.yml,other.yml" {
		t.Fatalf("entries = %v", names)
	}
}

func TestRenameRefusesWhatItMustNotTouch(t *testing.T) {
	root, file, _ := saveFixture(t)
	for name, tc := range map[string]struct {
		id, name string
		want     error
	}{
		"bad new name":    {".github/workflows/ci.yml", "../ci.yml", ErrBadFileName},
		"outside":         {"README.md", "x.yml", ErrNoWorkflowFile},
		"missing":         {".github/workflows/gone.yml", "x.yml", ErrNoWorkflowFile},
		"other extension": {".github/workflows/ci.yml", "ci.txt", ErrBadFileName},
	} {
		if _, err := RenameWorkflowFile(root, tc.id, tc.name); !errors.Is(err, tc.want) {
			t.Errorf("%s: %v, want %v", name, err, tc.want)
		}
	}
	if runtime.GOOS == "windows" {
		return
	}
	// A symlink is not renamed, and its target is not touched.
	outside := filepath.Join(t.TempDir(), "victim.yml")
	_ = os.WriteFile(outside, []byte("keep\n"), 0o644)
	link := filepath.Join(filepath.Dir(file), "link.yml")
	if err := os.Symlink(outside, link); err != nil {
		t.Fatal(err)
	}
	if _, err := RenameWorkflowFile(root, ".github/workflows/link.yml", "moved.yml"); !errors.Is(err, ErrNoWorkflowFile) {
		t.Fatalf("symlink: %v", err)
	}
	if _, err := os.Lstat(link); err != nil {
		t.Fatalf("symlink moved: %v", err)
	}
}

func TestRenameInAReadOnlyFolder(t *testing.T) {
	if runtime.GOOS == "windows" || os.Getuid() == 0 {
		t.Skip("POSIX permissions as a normal user")
	}
	root, file, _ := saveFixture(t)
	dir := filepath.Dir(file)
	if err := os.Chmod(dir, 0o555); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(dir, 0o755)
	if _, err := RenameWorkflowFile(root, ".github/workflows/ci.yml", "build.yml"); !errors.Is(err, ErrReadOnly) {
		t.Fatalf("rename: %v", err)
	}
	if _, err := CreateWorkflowFile(root, "new.yml", nil); !errors.Is(err, ErrReadOnly) {
		t.Fatalf("create: %v", err)
	}
	if _, err := os.Stat(file); err != nil {
		t.Fatalf("file gone: %v", err)
	}
}
