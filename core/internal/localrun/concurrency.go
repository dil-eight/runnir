package localrun

// jobMemory is the memory one job of a local run is counted to need: a
// container may take DefaultMemoryBytes.
const jobMemory = DefaultMemoryBytes

// ConcurrentJobs is how many jobs of one workflow act runs at once: half the
// performance cores, at most one for each 8 GB of memory, at least one. act's
// own default, one job per logical CPU, let a matrix of builds fill the
// Mac's memory and slow everything on it.
func ConcurrentJobs(performanceCores int, memoryBytes uint64) int {
	jobs := performanceCores / 2
	if memoryBytes > 0 {
		jobs = min(jobs, int(memoryBytes/jobMemory))
	}
	return max(jobs, 1)
}

// HostConcurrentJobs is ConcurrentJobs for this computer.
func HostConcurrentJobs() int {
	return ConcurrentJobs(hostResources())
}
