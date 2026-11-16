//go:build darwin

package localrun

import (
	"runtime"

	"golang.org/x/sys/unix"
)

// hostResources is the Mac's performance cores (every physical core of an
// Intel Mac) and its memory.
func hostResources() (int, uint64) {
	cores := runtime.NumCPU()
	if n, err := unix.SysctlUint32("hw.perflevel0.physicalcpu"); err == nil && n > 0 {
		cores = int(n)
	} else if n, err := unix.SysctlUint32("hw.physicalcpu"); err == nil && n > 0 {
		cores = int(n)
	}
	memory, err := unix.SysctlUint64("hw.memsize")
	if err != nil {
		memory = 0
	}
	return cores, memory
}
