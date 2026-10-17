package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
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
		fmt.Fprintln(diagnostics, "usage: runnir version | rpc | serve --socket PATH")
		return 2
	}
	var err error
	switch args[0] {
	case "version":
		err = json.NewEncoder(output).Encode(buildinfo.Current())
	case "rpc":
		err = ipc.Serve(input, output, handle)
	default:
		fmt.Fprintln(diagnostics, "unknown command; usage: runnir version | rpc | serve --socket PATH")
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
func serve(args []string, input io.Reader, diagnostics io.Writer) int {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	socket := flags.String("socket", "", "Unix domain socket path")
	exitOnEOF := flags.Bool("exit-on-stdin-eof", false, "stop when stdin closes")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 || *socket == "" {
		fmt.Fprintln(diagnostics, "usage: runnir serve --socket PATH [--exit-on-stdin-eof]")
		return 2
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if *exitOnEOF {
		go func() { _, _ = io.Copy(io.Discard, input); stop() }()
	}
	return finishServe(server.Run(ctx, *socket), diagnostics)
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
