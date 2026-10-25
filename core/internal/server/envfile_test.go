//go:build !windows

package server

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func TestReadEnvFile(t *testing.T) {
	path := socketPath(t)
	stop := startWith(t, path, Options{})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	dir := t.TempDir()
	file := filepath.Join(dir, ".env")
	_ = os.WriteFile(file, []byte("npm_token=abc\nSEALED=encrypted:xyz\nbad line\n"), 0o600)
	read, err := client.ReadEnvFile(ctx, &corev1.ReadEnvFileRequest{Path: file})
	if err != nil {
		t.Fatal(err)
	}
	if len(read.Entries) != 2 || read.Entries[0].Name != "NPM_TOKEN" || read.Entries[0].Value != "abc" || read.Entries[0].Line != 1 ||
		!read.Entries[1].Encrypted || read.Entries[1].Value != "" || len(read.Problems) != 1 || read.Problems[0].Line != 3 {
		t.Fatalf("read = %v", read)
	}

	big := filepath.Join(dir, "big.env")
	_ = os.WriteFile(big, []byte("A="+strings.Repeat("x", 1<<20)), 0o600)
	binary := filepath.Join(dir, "binary.env")
	_ = os.WriteFile(binary, []byte{'A', '=', 0xff, 0xfe}, 0o600)
	for _, bad := range []string{big, binary, dir, filepath.Join(dir, "missing"), "relative.env"} {
		if _, err := client.ReadEnvFile(ctx, &corev1.ReadEnvFileRequest{Path: bad}); status.Code(err) != codes.InvalidArgument {
			t.Errorf("%s: %v", bad, err)
		}
	}
}
