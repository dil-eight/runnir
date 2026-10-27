package localrun

import (
	"fmt"
	"time"

	"runnir/core/internal/tools"
)

// Bounds and steps of a run's limits.
const (
	MinMemoryBytes = 1 << 30
	MemoryStep     = 512 << 20
	MinTimeout     = 5 * time.Minute
	MaxTimeout     = 6 * time.Hour
	TimeoutStep    = 5 * time.Minute
	lowMemory      = 2 << 30
)

// Ceiling is the most a run can get here: the engine's CPUs and memory (zero
// when the engine did not say) and 6 hours, GitHub's limit for one job.
type Ceiling struct {
	CPUs        int
	MemoryBytes uint64
	Timeout     time.Duration
}

func CeilingFor(engine tools.Engine) Ceiling {
	return Ceiling{CPUs: max(engine.CPUs, 0), MemoryBytes: engine.MemoryBytes, Timeout: MaxTimeout}
}

// Choose turns what was asked (nil: the defaults) into a run's limits: whole
// CPUs from 1, memory in steps of 512 MiB from 1 GB, a timeout in steps of 5
// minutes from 5 minutes, none above the ceiling.
func Choose(asked *Limits, ceiling Ceiling) Limits {
	l := Limits{CPUs: DefaultCPUs, MemoryBytes: DefaultMemoryBytes, Timeout: DefaultTimeout}
	if asked != nil {
		l = *asked
	}
	l.CPUs = max(l.CPUs, 1)
	if ceiling.CPUs > 0 {
		l.CPUs = min(l.CPUs, ceiling.CPUs)
	}
	if asked != nil {
		l.MemoryBytes = max(l.MemoryBytes/MemoryStep*MemoryStep, MinMemoryBytes)
	}
	if ceiling.MemoryBytes > 0 && l.MemoryBytes > ceiling.MemoryBytes {
		l.MemoryBytes = ceiling.MemoryBytes
	}
	l.Timeout = min(max(l.Timeout/TimeoutStep*TimeoutStep, MinTimeout), ceiling.Timeout)
	return l
}

// Warnings says what limits the person asked for risk on this engine. The
// defaults capped at a small engine get Note instead.
func Warnings(l Limits, ceiling Ceiling, asked bool) []string {
	var out []string
	if ceiling.CPUs > 1 && l.CPUs >= ceiling.CPUs {
		out = append(out, fmt.Sprintf("Every CPU of the engine (%d): the Mac and other containers slow down while the run goes on.", ceiling.CPUs))
	}
	if asked && ceiling.MemoryBytes > 0 && l.MemoryBytes*10 >= ceiling.MemoryBytes*9 {
		out = append(out, fmt.Sprintf("%s of %s memory: the engine and other containers may run out of memory, and a job can be killed (exit 137).",
			gigabytes(l.MemoryBytes), gigabytes(ceiling.MemoryBytes)))
	}
	if l.MemoryBytes < lowMemory {
		out = append(out, "Under 2 GB of memory many builds do not fit and stop with exit 137.")
	}
	return out
}

// Note is the line under the limits worth reading without opening them: an
// engine that did not say what it has, or one smaller than a default.
func Note(ceiling Ceiling, engineName string, asked bool) string {
	if engineName == "" {
		engineName = "The engine"
	}
	switch {
	case ceiling.CPUs == 0 && ceiling.MemoryBytes == 0:
		return "The container engine does not answer, so its CPUs and memory are unknown: the limits can be changed once it does."
	case !asked && ceiling.MemoryBytes > 0 && ceiling.MemoryBytes < DefaultMemoryBytes:
		return fmt.Sprintf("%s has %s, so memory is capped there. Give the engine more in its settings to raise it.", engineName, gigabytes(ceiling.MemoryBytes))
	}
	return ""
}

// gigabytes words bytes as "5.85 GB", as the app shows memory.
func gigabytes(b uint64) string {
	return fmt.Sprintf("%.3g GB", float64(b)/(1<<30))
}
