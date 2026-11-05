//go:build darwin

package analytics

import (
	"strings"
	"syscall"
)

// osVersion is macOS's major.minor, for example "26.1".
func osVersion() string {
	version, err := syscall.Sysctl("kern.osproductversion")
	if err != nil {
		return ""
	}
	if parts := strings.SplitN(version, ".", 3); len(parts) >= 2 {
		return parts[0] + "." + parts[1]
	}
	return version
}
