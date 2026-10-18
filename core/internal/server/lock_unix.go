//go:build !windows

package server

import (
	"errors"
	"fmt"
	"os"
	"syscall"
)

// ErrAlreadyRunning means another Core holds the instance lock.
var ErrAlreadyRunning = errors.New("another runnir core is already running")

type instanceLock struct{ file *os.File }

// acquireLock takes an advisory, non-blocking lock. The OS drops it when the
// process dies, so a crash never leaves a lock that blocks restart.
func acquireLock(path string) (*instanceLock, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, fmt.Errorf("open lock file: %w", err)
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, ErrAlreadyRunning
		}
		return nil, fmt.Errorf("lock file: %w", err)
	}
	return &instanceLock{file: file}, nil
}

func (l *instanceLock) release() { _ = l.file.Close() }
