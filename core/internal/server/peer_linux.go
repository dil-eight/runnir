package server

import (
	"net"
	"os"
	"syscall"
)

// peerIsThisUser reads the peer's credentials of a Unix socket connection
// (SO_PEERCRED) and compares its uid with ours.
func peerIsThisUser(conn net.Conn) bool {
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return false
	}
	raw, err := unixConn.SyscallConn()
	if err != nil {
		return false
	}
	same := false
	_ = raw.Control(func(fd uintptr) {
		credentials, err := syscall.GetsockoptUcred(int(fd), syscall.SOL_SOCKET, syscall.SO_PEERCRED)
		same = err == nil && int(credentials.Uid) == os.Getuid()
	})
	return same
}
