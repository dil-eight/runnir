package localrun

import (
	"slices"
	"strings"
	"testing"
)

func TestConcurrentJobsFollowCoresAndMemory(t *testing.T) {
	const gb = 1 << 30
	for _, c := range []struct {
		cores  int
		memory uint64
		want   int
	}{
		{8, 24 * gb, 3},  // memory holds it back
		{8, 64 * gb, 4},  // half the performance cores
		{4, 8 * gb, 1},   // a small Mac runs jobs one by one
		{4, 4 * gb, 1},   // never none
		{12, 0, 6},       // memory unknown: the cores alone
		{0, 0, 1},        // nothing known
		{1, 128 * gb, 1}, // a single core
	} {
		if got := ConcurrentJobs(c.cores, c.memory); got != c.want {
			t.Errorf("ConcurrentJobs(%d, %d GB) = %d, want %d", c.cores, c.memory/gb, got, c.want)
		}
	}
	if HostConcurrentJobs() < 1 {
		t.Fatal("this computer runs no job at all")
	}
}

func TestArgsLimitConcurrentJobs(t *testing.T) {
	spec := &Spec{RepositoryPath: "/repo"}
	ci := lane(".github/workflows/ci.yml", "push")
	for _, arg := range Args(spec, ci, "e1", "/scratch") {
		if strings.HasPrefix(arg, "--concurrent-jobs") {
			t.Fatalf("a spec without a limit has %q", arg)
		}
	}
	spec.ConcurrentJobs = 3
	args := Args(spec, ci, "e1", "/scratch")
	at := slices.Index(args, "--concurrent-jobs=3")
	if at < 0 || at > slices.Index(args, "--") {
		t.Fatalf("args = %v", args)
	}
}
