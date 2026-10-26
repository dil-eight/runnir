//go:build !windows

package localrun

import (
	"os"
	"syscall"
	"testing"
	"time"
)

func TestFinishEndsAWriteBlockedOnAFullPipe(t *testing.T) {
	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	// Another holder of the read end that never reads, as a process act
	// left behind would be.
	held, err := syscall.Dup(int(read.Fd()))
	if err != nil {
		t.Fatal(err)
	}
	defer syscall.Close(held)
	feed := &valueFeed{read: read, write: write, data: make([]byte, 1<<20), done: make(chan struct{})}
	feed.send()
	finished := make(chan struct{})
	go func() { feed.finish(); close(finished) }()
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		t.Fatal("finish did not end the blocked write")
	}
}
