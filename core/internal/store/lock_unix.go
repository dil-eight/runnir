//go:build !windows

package store

import (
	"errors"
	"os"
	"syscall"
)

var errLocked = errors.New("locked by another process")

type fileLock struct{ file *os.File }

// acquireLock takes an advisory, non-blocking exclusive lock. The OS drops
// it when the process dies, so a crash never leaves a workspace locked.
func acquireLock(path string) (*fileLock, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, errLocked
		}
		return nil, err
	}
	return &fileLock{file: file}, nil
}

func (l *fileLock) release() { _ = l.file.Close() }
