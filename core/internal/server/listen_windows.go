package server

import "net"

// listenOwnerOnly listens normally; Windows has no umask, and the socket is
// restricted right after creation.
func listenOwnerOnly(path string) (net.Listener, error) {
	return net.Listen("unix", path)
}
