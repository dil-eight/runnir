//go:build !windows

package main

import (
	"os"
	"syscall"
)

func become(path string, args []string) {
	_ = syscall.Exec(path, args, os.Environ())
}
