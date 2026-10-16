package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"

	"runnir/core/internal/buildinfo"
	"runnir/core/internal/ipc"
)

func main() { os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr)) }

func run(args []string, input io.Reader, output, diagnostics io.Writer) int {
	if len(args) != 1 {
		fmt.Fprintln(diagnostics, "usage: runnir version | rpc")
		return 2
	}
	var err error
	switch args[0] {
	case "version":
		err = json.NewEncoder(output).Encode(buildinfo.Current())
	case "rpc":
		err = ipc.Serve(input, output, handle)
	default:
		fmt.Fprintln(diagnostics, "unknown command; usage: runnir version | rpc")
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
