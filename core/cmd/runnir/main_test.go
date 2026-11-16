package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"runnir/core/internal/buildinfo"
)

func TestVersion(t *testing.T) {
	var out, diagnostics bytes.Buffer
	if code := run([]string{"version"}, strings.NewReader(""), &out, &diagnostics); code != 0 {
		t.Fatalf("exit %d: %s", code, &diagnostics)
	}
	var info struct {
		Version         string
		ProtocolVersion int
	}
	if err := json.Unmarshal(out.Bytes(), &info); err != nil || info.Version == "" || info.ProtocolVersion != 1 {
		t.Fatalf("invalid version: %s (%v)", &out, err)
	}
}

func TestRPC(t *testing.T) {
	cases := []struct {
		name, input  string
		code         int
		notification bool
	}{
		{"version", `{"jsonrpc":"2.0","id":"test","method":"core.v1.version"}`, 0, false},
		{"empty spaced params", `{"jsonrpc":"2.0","id":"test","method":"core.v1.version","params":{ }}`, 0, false},
		{"unknown", `{"jsonrpc":"2.0","id":"test","method":"shell.exec"}`, -32601, false},
		{"protocol", `{"jsonrpc":"1.0","id":"test","method":"core.v1.version"}`, -32600, false},
		{"malformed", `{`, -32700, false},
		{"invalid id", `{"jsonrpc":"2.0","id":true,"method":"core.v1.version"}`, -32600, false},
		{"params", `{"jsonrpc":"2.0","id":"test","method":"core.v1.version","params":{"token":"secret"}}`, -32602, false},
		{"notification", `{"jsonrpc":"2.0","method":"core.v1.version"}`, 0, true},
		{"batch unsupported", `[]`, -32600, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var out, diagnostics bytes.Buffer
			if code := run([]string{"rpc"}, strings.NewReader(tc.input+"\n"), &out, &diagnostics); code != 0 {
				t.Fatalf("exit %d", code)
			}
			if tc.notification {
				if out.Len() != 0 {
					t.Fatal("notification produced response")
				}
				return
			}
			var reply struct {
				JSONRPC string
				ID      any
				Result  any
				Error   *struct{ Code int }
			}
			if err := json.Unmarshal(out.Bytes(), &reply); err != nil {
				t.Fatal(err)
			}
			if reply.JSONRPC != "2.0" {
				t.Fatal("invalid response version")
			}
			if tc.code == 0 {
				if reply.Error != nil || reply.Result == nil || reply.ID != "test" {
					t.Fatalf("bad success: %s", &out)
				}
			} else if reply.Error == nil || reply.Error.Code != tc.code || reply.Result != nil {
				t.Fatalf("bad error: %s", &out)
			}
			if strings.Contains(out.String(), "secret") {
				t.Fatal("request leaked")
			}
		})
	}
}

func TestRPCMultipleFramesAndOversize(t *testing.T) {
	var out, diagnostics bytes.Buffer
	frame := "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"core.v1.version\"}\n"
	if run([]string{"rpc"}, strings.NewReader(frame+frame), &out, &diagnostics) != 0 || strings.Count(out.String(), "\n") != 2 {
		t.Fatal("stream failed")
	}
	out.Reset()
	if run([]string{"rpc"}, strings.NewReader(strings.Repeat("x", 70000)), &out, &diagnostics) != 1 {
		t.Fatal("oversize frame accepted")
	}
}

func TestLicensesPrintsRunnirsLicenseAndTheNotices(t *testing.T) {
	var out, diagnostics bytes.Buffer
	if code := run([]string{"licenses"}, strings.NewReader(""), &out, &diagnostics); code != 0 || diagnostics.Len() != 0 {
		t.Fatalf("licenses = %d, %q", code, diagnostics.String())
	}
	text := out.String()
	if !strings.HasPrefix(strings.TrimSpace(text), "Apache License") || !strings.Contains(text, "google.golang.org/grpc ") {
		t.Fatalf("licenses printed %.60q…", text)
	}
}

func TestUnknownCommand(t *testing.T) {
	var out, diagnostics bytes.Buffer
	if run([]string{"bogus"}, strings.NewReader(""), &out, &diagnostics) != 2 || out.Len() != 0 {
		t.Fatal("unknown command accepted")
	}
}

func TestMcpUsage(t *testing.T) {
	for _, args := range [][]string{{"mcp", "--data-dir"}, {"mcp", "--data-dir", "relative"}, {"mcp", "--data-dir", "/tmp/x", "extra"}, {"mcp", "extra"}} {
		var out, diagnostics bytes.Buffer
		if code := run(args, strings.NewReader(""), &out, &diagnostics); code != 2 || out.Len() != 0 {
			t.Fatalf("%v: code=%d out=%q", args, code, out.String())
		}
	}
}

func TestMcpWithoutADataFolderUsesItsBuilds(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	config, err := os.UserConfigDir()
	if err != nil {
		t.Fatal(err)
	}
	if got, err := mcpDataDir(""); err != nil || got != filepath.Join(config, buildinfo.SupportFolder()) {
		t.Fatalf("default = %q, %v", got, err)
	}
	if got, err := mcpDataDir("/some/folder"); err != nil || got != "/some/folder" {
		t.Fatalf("given = %q, %v", got, err)
	}
	var out, diagnostics bytes.Buffer
	input := `{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"runnir_list_value_sets","arguments":{"repository":"/r"}}}` + "\n"
	if code := run([]string{"mcp"}, strings.NewReader(input), &out, &diagnostics); code != 0 || !strings.Contains(out.String(), "Runnir is not running") {
		t.Fatalf("code=%d out=%s %q", code, out.String(), diagnostics.String())
	}
}

func TestMcpWithoutRunnirAnswersTheProtocolAndSaysSo(t *testing.T) {
	var out, diagnostics bytes.Buffer
	input := strings.Join([]string{
		`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t"}}}`,
		`{"jsonrpc":"2.0","id":2,"method":"tools/list"}`,
		`{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"runnir_list_value_sets","arguments":{"repository":"/r"}}}`,
	}, "\n") + "\n"
	if code := run([]string{"mcp", "--data-dir", t.TempDir()}, strings.NewReader(input), &out, &diagnostics); code != 0 {
		t.Fatalf("code=%d %q", code, diagnostics.String())
	}
	text := out.String()
	if !strings.Contains(text, `"runnir_set_values"`) || !strings.Contains(text, "Runnir is not running") || !strings.Contains(text, `"isError":true`) {
		t.Fatalf("out = %s", text)
	}
}

func TestServeUsage(t *testing.T) {
	for _, args := range [][]string{{"serve"}, {"serve", "--socket"}, {"serve", "--socket", "/tmp/x", "extra"}, {"serve", "--bogus"}, {"serve", "--socket", "/tmp/x", "--data-dir", "relative/path"}, {"serve", "--socket", "/tmp/x", "--cache-dir", "relative/path"}} {
		var out, diagnostics bytes.Buffer
		if code := run(args, strings.NewReader(""), &out, &diagnostics); code != 2 || out.Len() != 0 {
			t.Fatalf("%v: code=%d out=%q", args, code, out.String())
		}
	}
}

func TestServeStopsWhenStdinCloses(t *testing.T) {
	serveUntilStdinCloses(t, nil)
}

func TestServeTakesACacheFolder(t *testing.T) {
	serveUntilStdinCloses(t, nil, "--cache-dir", t.TempDir())
}

func TestActKeepsItsCacheInTheCacheFolder(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "Runnir Dev")
	if got := actCache(dir); filepath.Dir(got) != dir || filepath.Base(got) != "act" {
		t.Fatalf("act cache = %q, want the act folder of %q", got, dir)
	}
	if got := actCache(""); got != "" {
		t.Fatalf("without --cache-dir the server's default is kept, got %q", got)
	}
}

func TestServeRequiresAWellFormedSecretWhenAsked(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("serve is not supported on windows")
	}
	for _, stdin := range []string{"", "short\n", strings.Repeat("z", 40) + "\n"} {
		var out, diagnostics bytes.Buffer
		code := run([]string{"serve", "--socket", "/tmp/rn-unused.sock", "--client-secret-stdin"}, strings.NewReader(stdin), &out, &diagnostics)
		if code != 2 {
			t.Errorf("stdin %q: exit %d, want 2", stdin, code)
		}
	}
}

func TestServeReadsTheSecretThenWatchesStdin(t *testing.T) {
	serveUntilStdinCloses(t, []byte("0123456789abcdef0123456789abcdef\n"), "--client-secret-stdin")
}

// serveUntilStdinCloses runs serve with --exit-on-stdin-eof and flags,
// writes secret to its stdin, waits for its socket, then closes stdin and
// expects it to stop with 0.
func serveUntilStdinCloses(t *testing.T, secret []byte, flags ...string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("serve is not supported on windows")
	}
	dir, err := os.MkdirTemp("/tmp", "rn")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "core.sock")
	reader, writer := io.Pipe()
	result := make(chan int, 1)
	go func() {
		var out, diagnostics bytes.Buffer
		result <- run(append([]string{"serve", "--socket", socket, "--exit-on-stdin-eof"}, flags...), reader, &out, &diagnostics)
	}()
	if secret != nil {
		if _, err := writer.Write(secret); err != nil {
			t.Fatal(err)
		}
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if info, err := os.Stat(socket); err == nil && info.Mode()&os.ModeSocket != 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("socket did not appear")
		}
		time.Sleep(10 * time.Millisecond)
	}
	writer.Close()
	select {
	case code := <-result:
		if code != 0 {
			t.Fatalf("exit code %d", code)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("serve did not stop after stdin closed")
	}
}
