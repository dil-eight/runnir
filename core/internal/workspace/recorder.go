package workspace

import "sync"

// recorder runs local-history writes in order on one goroutine, so event
// callbacks that must not block only queue work.
type recorder struct {
	mu     sync.Mutex
	cond   *sync.Cond
	queue  []func()
	busy   bool
	closed bool
	signal chan struct{}
	done   chan struct{}
}

func newRecorder() *recorder {
	q := &recorder{signal: make(chan struct{}, 1), done: make(chan struct{})}
	q.cond = sync.NewCond(&q.mu)
	go q.run()
	return q
}

func (q *recorder) add(task func()) {
	q.mu.Lock()
	if q.closed {
		q.mu.Unlock()
		return
	}
	q.queue = append(q.queue, task)
	q.mu.Unlock()
	select {
	case q.signal <- struct{}{}:
	default:
	}
}

func (q *recorder) run() {
	defer close(q.done)
	for range q.signal {
		for {
			q.mu.Lock()
			if len(q.queue) == 0 {
				q.busy = false
				q.cond.Broadcast()
				q.mu.Unlock()
				break
			}
			task := q.queue[0]
			q.queue = q.queue[1:]
			q.busy = true
			q.mu.Unlock()
			task()
		}
	}
}

// flush waits until every queued write ran.
func (q *recorder) flush() {
	q.mu.Lock()
	for len(q.queue) > 0 || q.busy {
		q.cond.Wait()
	}
	q.mu.Unlock()
}

func (q *recorder) close() {
	q.flush()
	q.mu.Lock()
	if !q.closed {
		q.closed = true
		close(q.signal)
	}
	q.mu.Unlock()
	<-q.done
}
