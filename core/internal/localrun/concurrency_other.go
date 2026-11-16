//go:build !darwin

package localrun

import "runtime"

// hostResources is the logical CPUs; the memory is not read here.
func hostResources() (int, uint64) {
	return runtime.NumCPU(), 0
}
