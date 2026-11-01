package parallel

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestEachCallsEveryIndexAtMostLimitAtOnce(t *testing.T) {
	var running, most atomic.Int32
	var mu sync.Mutex
	seen := map[int]int{}
	Each(20, 3, func(i int) {
		now := running.Add(1)
		for {
			if old := most.Load(); now <= old || most.CompareAndSwap(old, now) {
				break
			}
		}
		time.Sleep(time.Millisecond)
		running.Add(-1)
		mu.Lock()
		seen[i]++
		mu.Unlock()
	})
	if len(seen) != 20 || most.Load() > 3 {
		t.Fatalf("seen %d indexes, at most %d at once", len(seen), most.Load())
	}
	for i, n := range seen {
		if n != 1 {
			t.Fatalf("index %d called %d times", i, n)
		}
	}
	calls := 0
	Each(2, 0, func(int) { calls++ }) // a limit below one is one
	if calls != 2 {
		t.Fatalf("calls = %d", calls)
	}
}
