// Package events fans Core events out to subscribers without ever blocking
// the publisher or growing memory: each subscriber has a fixed-size buffer,
// and one that falls behind is disconnected so it can resynchronize.
package events

import (
	"errors"
	"sync"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// DefaultBuffer is the per-subscriber queue length.
const DefaultBuffer = 256

// ErrOverflow is a subscription's Err when it was closed for falling behind.
var ErrOverflow = errors.New("subscriber fell behind and was disconnected")

type Event struct {
	// Sequence is assigned by the bus: monotonic per Core process, and
	// delivery order to every subscriber matches it.
	Sequence       uint64
	Type           corev1.CoreEventType
	RepositoryID   string // empty for events not tied to a repository
	ExecutionID    string
	ExecutionState corev1.ExecutionState
	Message        string // never contains credentials
	At             time.Time
}

// Bus is safe for concurrent use.
type Bus struct {
	buffer int

	mu     sync.Mutex
	seq    uint64
	closed bool
	subs   map[*Subscription]struct{}
}

func New(buffer int) *Bus {
	if buffer <= 0 {
		buffer = DefaultBuffer
	}
	return &Bus{buffer: buffer, subs: map[*Subscription]struct{}{}}
}

// Subscription delivers events on C. C is closed when the subscription ends;
// Err then tells why (nil for Close or bus shutdown, ErrOverflow otherwise).
type Subscription struct {
	C <-chan Event
	// Baseline is the sequence of the last event published before this
	// subscription began. Everything delivered has a greater sequence.
	Baseline uint64

	bus    *Bus
	ch     chan Event
	filter map[string]struct{}
	err    error
	done   bool
}

// Subscribe filters repository events to repositoryIDs; empty means all.
// Events without a repository (such as core errors) always pass.
func (b *Bus) Subscribe(repositoryIDs []string) *Subscription {
	ch := make(chan Event, b.buffer)
	s := &Subscription{C: ch, bus: b, ch: ch}
	if len(repositoryIDs) > 0 {
		s.filter = make(map[string]struct{}, len(repositoryIDs))
		for _, id := range repositoryIDs {
			s.filter[id] = struct{}{}
		}
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	s.Baseline = b.seq
	if b.closed {
		s.finish(nil)
		return s
	}
	b.subs[s] = struct{}{}
	return s
}

// Publish stamps and queues the event for matching subscribers. It never
// blocks: a subscriber whose buffer is full is closed with ErrOverflow.
func (b *Bus) Publish(e Event) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return
	}
	b.seq++
	e.Sequence = b.seq
	if e.At.IsZero() {
		e.At = time.Now()
	}
	for s := range b.subs {
		if !s.wants(e) {
			continue
		}
		select {
		case s.ch <- e:
		default:
			delete(b.subs, s)
			s.finish(ErrOverflow)
		}
	}
}

func (s *Subscription) wants(e Event) bool {
	if s.filter == nil || e.RepositoryID == "" {
		return true
	}
	_, ok := s.filter[e.RepositoryID]
	return ok
}

// finish must be called with bus.mu held.
func (s *Subscription) finish(err error) {
	if s.done {
		return
	}
	s.done, s.err = true, err
	close(s.ch)
}

// Err reports why C was closed; nil while open or after a plain Close.
func (s *Subscription) Err() error {
	s.bus.mu.Lock()
	defer s.bus.mu.Unlock()
	return s.err
}

// Close ends the subscription. It is idempotent.
func (s *Subscription) Close() {
	s.bus.mu.Lock()
	defer s.bus.mu.Unlock()
	delete(s.bus.subs, s)
	s.finish(nil)
}

// Subscribers reports the number of live subscriptions.
func (b *Bus) Subscribers() int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.subs)
}

// Close ends every subscription and ignores later publishes and subscribes.
func (b *Bus) Close() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.closed = true
	for s := range b.subs {
		delete(b.subs, s)
		s.finish(nil)
	}
}
