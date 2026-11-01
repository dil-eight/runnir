// Package parallel runs a number of calls on goroutines, a bounded number
// at a time.
package parallel

import "sync"

// Each calls do for every i from 0 to n-1, at most limit at once (at least
// one), and returns when every call has returned.
func Each(n, limit int, do func(i int)) {
	var wg sync.WaitGroup
	slots := make(chan struct{}, max(limit, 1))
	for i := range n {
		wg.Add(1)
		go func() {
			defer wg.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			do(i)
		}()
	}
	wg.Wait()
}
