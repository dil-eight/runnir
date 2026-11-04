//go:build !windows

package server

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"runnir/core/internal/flow"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func TestParseEnvFile(t *testing.T) {
	client, ctx := servedWith(t, Options{})

	parsed, err := client.ParseEnvFile(ctx, &corev1.ParseEnvFileRequest{Content: []byte("npm_token=abc\nSEALED=encrypted:xyz\nbad line\n")})
	if err != nil {
		t.Fatal(err)
	}
	if len(parsed.Entries) != 2 || parsed.Entries[0].Name != "NPM_TOKEN" || parsed.Entries[0].Value != "abc" || parsed.Entries[0].Line != 1 ||
		!parsed.Entries[1].Encrypted || parsed.Entries[1].Value != "" || len(parsed.Problems) != 1 || parsed.Problems[0].Line != 3 {
		t.Fatalf("parsed = %v", parsed)
	}
	for _, bad := range [][]byte{[]byte("A=" + strings.Repeat("x", 1<<20)), {'A', '=', 0xff, 0xfe}} {
		if _, err := client.ParseEnvFile(ctx, &corev1.ParseEnvFileRequest{Content: bad}); status.Code(err) != codes.InvalidArgument {
			t.Errorf("%d bytes: %v", len(bad), err)
		}
	}
}

func TestListEnvFilesOfARepository(t *testing.T) {
	git := flow.FindGit(filepath.SplitList(os.Getenv("PATH")))
	if git == "" {
		t.Skip("git is not installed")
	}
	client, ctx := servedWith(t, Options{})
	root := t.TempDir()
	if out, err := exec.Command(git, "-C", root, "init", "-q").CombinedOutput(); err != nil {
		t.Fatalf("git init: %v\n%s", err, out)
	}
	for name, content := range map[string]string{".gitignore": ".env.local\n", ".env": "A=1\n", "apps/web/.env.local": "A=2\n", "apps/web/.env.example": "A=\n"} {
		path := filepath.Join(root, name)
		_ = os.MkdirAll(filepath.Dir(path), 0o755)
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}

	listed, err := client.ListEnvFiles(ctx, &corev1.ListEnvFilesRequest{RepositoryId: opened.Repository.Id})
	if err != nil {
		t.Fatal(err)
	}
	if len(listed.Files) != 2 || listed.Files[0].Path != ".env" || listed.Files[0].Ignored ||
		listed.Files[1].Path != "apps/web/.env.local" || !listed.Files[1].Ignored {
		t.Fatalf("files = %v", listed.Files)
	}
	if _, err := client.ListEnvFiles(ctx, &corev1.ListEnvFilesRequest{RepositoryId: "nope"}); status.Code(err) != codes.NotFound {
		t.Fatalf("an unknown repository: %v", err)
	}
}
