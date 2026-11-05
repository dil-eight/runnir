//go:build windows

package analytics

import "errors"

type fileLock struct{}

// The ledger is kept on disk on macOS only; elsewhere it is in memory.
func acquireLock(string) (*fileLock, error) {
	return nil, errors.New("the analytics ledger is not kept on disk on this platform")
}

func (l *fileLock) release() {}
