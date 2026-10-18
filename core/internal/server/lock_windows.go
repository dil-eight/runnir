//go:build windows

package server

import "errors"

var ErrAlreadyRunning = errors.New("another runnir core is already running")

type instanceLock struct{}

// The local gRPC server is a macOS feature; other platforms only build.
func acquireLock(string) (*instanceLock, error) {
	return nil, errors.New("serve is not supported on this platform")
}

func (l *instanceLock) release() {}
