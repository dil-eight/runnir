//go:build !darwin && !linux

package server

import "net"

// peerIsThisUser cannot ask the platform; the socket's mode (0600) limits
// it to this user.
func peerIsThisUser(net.Conn) bool { return true }
