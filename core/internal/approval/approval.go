// Package approval is the Core's two-step confirmation for consequential
// GitHub operations: a request is first prepared (validated by the caller)
// and only runs when that exact preparation is confirmed, once, before it
// expires. A client cannot change anything on GitHub in a single call.
package approval

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"sync"
	"time"
)

var (
	// ErrUnknown: no such preparation, or it was already confirmed.
	ErrUnknown = errors.New("this confirmation is unknown or was already used")
	ErrExpired = errors.New("this confirmation has expired")
	ErrTooMany = errors.New("too many requests are waiting for confirmation")
)

const (
	DefaultTTL = 2 * time.Minute
	MaxPending = 20
)

type Pending[T any] struct {
	ID        string
	Request   T
	ExpiresAt time.Time
}

// Store keeps prepared requests in memory. Safe for concurrent use. The
// caller owns the request value: it must not share mutable state (maps,
// slices) with anything the caller changes later.
type Store[T any] struct {
	mu      sync.Mutex
	pending map[string]Pending[T]
	prefix  string
	ttl     time.Duration
	now     func() time.Time
}

// NewStore issues ids that start with prefix, for example "dispatch_".
func NewStore[T any](prefix string, ttl time.Duration, now func() time.Time) *Store[T] {
	if ttl <= 0 {
		ttl = DefaultTTL
	}
	if now == nil {
		now = time.Now
	}
	return &Store[T]{pending: map[string]Pending[T]{}, prefix: prefix, ttl: ttl, now: now}
}

// Prepare records a validated request and returns its single-use id.
func (s *Store[T]) Prepare(request T) (Pending[T], error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return Pending[T]{}, fmt.Errorf("generate confirmation id: %w", err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for id, p := range s.pending {
		if !now.Before(p.ExpiresAt) {
			delete(s.pending, id)
		}
	}
	if len(s.pending) >= MaxPending {
		return Pending[T]{}, ErrTooMany
	}
	pending := Pending[T]{ID: s.prefix + hex.EncodeToString(raw[:]), Request: request, ExpiresAt: now.Add(s.ttl)}
	s.pending[pending.ID] = pending
	return pending, nil
}

// Confirm consumes a preparation. It succeeds at most once per id.
func (s *Store[T]) Confirm(id string) (T, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var zero T
	pending, ok := s.pending[id]
	if !ok {
		return zero, ErrUnknown
	}
	delete(s.pending, id)
	if !s.now().Before(pending.ExpiresAt) {
		return zero, ErrExpired
	}
	return pending.Request, nil
}
