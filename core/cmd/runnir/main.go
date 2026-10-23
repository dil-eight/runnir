package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"runnir/core/internal/buildinfo"
	"runnir/core/internal/ipc"
	"runnir/core/internal/server"
)

func main() { os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr)) }

func run(args []string, input io.Reader, output, diagnostics io.Writer) int {
	if len(args) > 0 && args[0] == "serve" {
		return serve(args[1:], input, diagnostics)
	}
	if len(args) != 1 {
		fmt.Fprintln(diagnostics, "usage: runnir version | rpc | serve --socket PATH [--data-dir PATH]")
		return 2
	}
	var err error
	switch args[0] {
	case "version":
		err = json.NewEncoder(output).Encode(buildinfo.Current())
	case "rpc":
		err = ipc.Serve(input, output, handle)
	default:
		fmt.Fprintln(diagnostics, "unknown command; usage: runnir version | rpc | serve --socket PATH [--data-dir PATH]")
		return 2
	}
	if err != nil {
		// Diagnostics never echo request bodies or credentials.
		fmt.Fprintln(diagnostics, "runnir: command failed")
		return 1
	}
	return 0
}

func handle(method string, params json.RawMessage) (any, *ipc.Error) {
	if method != "core.v1.version" {
		return nil, &ipc.Error{Code: -32601, Message: "Method not found"}
	}
	if len(params) != 0 {
		var object map[string]json.RawMessage
		var array []json.RawMessage
		emptyObject := json.Unmarshal(params, &object) == nil && object != nil && len(object) == 0
		emptyArray := json.Unmarshal(params, &array) == nil && array != nil && len(array) == 0
		if !emptyObject && !emptyArray {
			return nil, &ipc.Error{Code: -32602, Message: "Invalid params"}
		}
	}
	return buildinfo.Current(), nil
}

// serve runs the local gRPC server until SIGINT/SIGTERM or, with
// --exit-on-stdin-eof, until the parent closes our stdin (including by dying).
// With --client-secret-stdin the first stdin line is a per-launch secret that
// every call except HealthCheck must present; it never appears in argv or env.
// --data-dir is the app's support folder, where workspace databases live;
// without it nothing is written to disk.
func serve(args []string, input io.Reader, diagnostics io.Writer) int {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	socket := flags.String("socket", "", "Unix domain socket path")
	exitOnEOF := flags.Bool("exit-on-stdin-eof", false, "stop when stdin closes")
	secretOnStdin := flags.Bool("client-secret-stdin", false, "read the client secret from the first stdin line")
	dataDir := flags.String("data-dir", "", "the app's support folder for workspace databases")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || *socket == "" || (*dataDir != "" && !filepath.IsAbs(*dataDir)) {
		fmt.Fprintln(diagnostics, "usage: runnir serve --socket PATH [--data-dir PATH] [--exit-on-stdin-eof] [--client-secret-stdin]")
		return 2
	}
	reader := bufio.NewReaderSize(input, 512)
	options := server.Options{BundledAct: bundledAct(), DataDir: *dataDir}
	if *secretOnStdin {
		secret, err := readSecret(reader)
		if err != nil {
			fmt.Fprintln(diagnostics, "runnir: a client secret is required on stdin")
			return 2
		}
		options.ClientSecret = secret
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if *exitOnEOF {
		go func() { _, _ = io.Copy(io.Discard, reader); stop() }()
	}
	return finishServe(server.RunWithOptions(ctx, *socket, options), diagnostics)
}

// bundledAct is where the app ships act: next to the Core. The tool check
// reports it missing when it is not there.
func bundledAct() string {
	executable, err := os.Executable()
	if err != nil {
		return ""
	}
	name := "act"
	if runtime.GOOS == "windows" {
		name = "act.exe"
	}
	return filepath.Join(filepath.Dir(executable), name)
}

// readSecret reads one line of 32 to 128 hex characters.
func readSecret(reader *bufio.Reader) ([]byte, error) {
	line, err := reader.ReadSlice('\n')
	if err != nil {
		return nil, err
	}
	secret := strings.TrimSpace(string(line))
	if len(secret) < 32 || len(secret) > 128 || strings.Trim(secret, "0123456789abcdefABCDEF") != "" {
		return nil, errors.New("malformed client secret")
	}
	return []byte(secret), nil
}

func finishServe(err error, diagnostics io.Writer) int {
	switch {
	case err == nil:
		return 0
	case errors.Is(err, server.ErrAlreadyRunning):
		fmt.Fprintln(diagnostics, "runnir: another core is already running")
		return 3
	default:
		fmt.Fprintln(diagnostics, "runnir: serve failed:", err)
		return 1
	}
}
