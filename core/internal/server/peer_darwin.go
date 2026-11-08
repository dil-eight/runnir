package server

import (
	"net"
	"os"

	"golang.org/x/sys/unix"
)

// peerIsThisUser reads the peer's credentials of a Unix socket connection
// (LOCAL_PEERCRED) and compares its uid with ours.
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
		credentials, err := unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
		same = err == nil && int(credentials.Uid) == os.Getuid()
	})
	return same
}
