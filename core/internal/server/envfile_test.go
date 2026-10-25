//go:build !windows

package server

import (
	"context"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func TestParseEnvFile(t *testing.T) {
	path := socketPath(t)
	stop := startWith(t, path, Options{})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

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
