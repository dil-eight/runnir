package dotenv

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestFindListsTheEnvFilesOfTheWorkingTree(t *testing.T) {
	root := t.TempDir()
	write := func(name string) {
		t.Helper()
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("A=1\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{
		".env", "apps/web/.env.local", "apps/page/.env", ".env.keys",
		// Templates, other files and folders left out.
		"apps/web/.env.example", ".env.sample", "apps/web/.env.local.EXAMPLE", ".envrc", "docs/env.md",
		"node_modules/pkg/.env", ".git/.env",
		// Another repository inside this one: a submodule or a worktree.
		"vendor/lib/.git", "vendor/lib/.env",
		// A folder whose name starts like a .env file is looked into, not listed.
		".env.d/conf/.env.local",
		"a/b/c/d/e/f/.env", "a/b/c/d/e/f/g/.env",
	} {
		write(name)
	}
	if err := os.Symlink(filepath.Join(root, ".env"), filepath.Join(root, "apps/.env")); err != nil {
		t.Fatal(err)
	}

	got := Find(root)
	// Nearer the root first; six folders deep at most.
	want := []string{".env", ".env.keys", ".env.d/conf/.env.local", "apps/page/.env", "apps/web/.env.local", "a/b/c/d/e/f/.env"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("found %q, want %q", got, want)
	}
}

func TestFindStopsAfterItsLimit(t *testing.T) {
	root := t.TempDir()
	for i := range maxFound + 5 {
		dir := filepath.Join(root, fmt.Sprintf("p%03d", i))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, ".env"), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if got := Find(root); len(got) != maxFound || got[0] != "p000/.env" {
		t.Fatalf("found %d, first %q", len(got), got[0])
	}
	if got := Find(filepath.Join(root, "missing")); got != nil {
		t.Fatalf("a missing folder: %q", got)
	}
}
