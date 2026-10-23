//go:build windows

package store

import "errors"

var errLocked = errors.New("locked by another process")

type fileLock struct{}

// Workspace databases are a macOS feature; other platforms keep every
// store in memory.
func acquireLock(string) (*fileLock, error) {
	return nil, errors.New("workspace databases are not supported on this platform")
}

func (l *fileLock) release() {}
