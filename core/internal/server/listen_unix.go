//go:build !windows

package server

import (
	"net"
	"syscall"
)

// listenOwnerOnly creates the socket with mode 0600 from the start, instead
// of restricting it after creation, so no other user can connect in between.
// The process-wide umask is changed only around the bind, before the server
// starts any other work.
func listenOwnerOnly(path string) (net.Listener, error) {
	previous := syscall.Umask(0o177)
	defer syscall.Umask(previous)
	return net.Listen("unix", path)
}
