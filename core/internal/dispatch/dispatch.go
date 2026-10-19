// Package dispatch is the Core's approval step for starting workflows: a
// dispatch is first prepared (validated against the workflow at the chosen
// ref) and only runs when that exact preparation is confirmed, once, before it
// expires. A client cannot start a workflow in a single call.
package dispatch

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"maps"
	"slices"
	"strconv"
	"sync"
	"time"

	"runnir/core/internal/scanner"
)

var (
	// ErrUnknown: no such preparation, or it was already confirmed.
	ErrUnknown = errors.New("this confirmation is unknown or was already used")
	ErrExpired = errors.New("this confirmation has expired")
	ErrTooMany = errors.New("too many dispatches are waiting for confirmation")
)

const (
	DefaultTTL     = 2 * time.Minute
	maxPending     = 20
	maxInputs      = 25
	maxValueLength = 65535
)

// Request is exactly what will be sent to GitHub when confirmed.
type Request struct {
	RepositoryID string
	Owner        string
	Name         string
	WorkflowID   int64
	WorkflowPath string
	Ref          string
	Inputs       map[string]string
}

type Pending struct {
	ID        string
	Request   Request
	ExpiresAt time.Time
}

// Store keeps prepared dispatches in memory. Safe for concurrent use.
type Store struct {
	mu      sync.Mutex
	pending map[string]Pending
	ttl     time.Duration
	now     func() time.Time
}

func NewStore(ttl time.Duration, now func() time.Time) *Store {
	if ttl <= 0 {
		ttl = DefaultTTL
	}
	if now == nil {
		now = time.Now
	}
	return &Store{pending: map[string]Pending{}, ttl: ttl, now: now}
}

// Prepare records a validated request and returns its single-use id.
func (s *Store) Prepare(request Request) (Pending, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return Pending{}, fmt.Errorf("generate dispatch id: %w", err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	for id, p := range s.pending {
		if !now.Before(p.ExpiresAt) {
			delete(s.pending, id)
		}
	}
	if len(s.pending) >= maxPending {
		return Pending{}, ErrTooMany
	}
	request.Inputs = maps.Clone(request.Inputs)
	pending := Pending{ID: "dispatch_" + hex.EncodeToString(raw[:]), Request: request, ExpiresAt: now.Add(s.ttl)}
	s.pending[pending.ID] = pending
	return pending, nil
}

// Confirm consumes a preparation. It succeeds at most once per id.
func (s *Store) Confirm(id string) (Request, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	pending, ok := s.pending[id]
	if !ok {
		return Request{}, ErrUnknown
	}
	delete(s.pending, id)
	if !s.now().Before(pending.ExpiresAt) {
		return Request{}, ErrExpired
	}
	return pending.Request, nil
}

// Validate checks inputs against the workflow_dispatch definition the way
// GitHub will, and returns readable problems; none means the request is valid.
func Validate(definition scanner.DispatchDefinition, ref string, inputs map[string]string) []string {
	var problems []string
	if !definition.Dispatchable {
		return []string{fmt.Sprintf("This workflow has no workflow_dispatch trigger on %s.", ref)}
	}
	if len(inputs) > maxInputs {
		problems = append(problems, fmt.Sprintf("At most %d inputs can be sent.", maxInputs))
	}
	known := map[string]scanner.DispatchInput{}
	for _, input := range definition.Inputs {
		known[input.Name] = input
	}
	for _, name := range slices.Sorted(maps.Keys(inputs)) {
		value := inputs[name]
		input, ok := known[name]
		if !ok {
			problems = append(problems, fmt.Sprintf("%q is not an input of this workflow on %s.", name, ref))
			continue
		}
		if len(value) > maxValueLength {
			problems = append(problems, fmt.Sprintf("%q is too long.", name))
			continue
		}
		switch input.Type {
		case "boolean":
			if value != "true" && value != "false" {
				problems = append(problems, fmt.Sprintf("%q must be true or false.", name))
			}
		case "number":
			if _, err := strconv.ParseFloat(value, 64); err != nil && value != "" {
				problems = append(problems, fmt.Sprintf("%q must be a number.", name))
			}
		case "choice":
			if value != "" && !slices.Contains(input.Options, value) {
				problems = append(problems, fmt.Sprintf("%q must be one of: %s.", name, joinOptions(input.Options)))
			}
		}
	}
	for _, input := range definition.Inputs {
		if input.Required && inputs[input.Name] == "" && input.Default == "" {
			problems = append(problems, fmt.Sprintf("%q is required.", input.Name))
		}
	}
	return problems
}

func joinOptions(options []string) string {
	out := ""
	for i, option := range options {
		if i > 0 {
			out += ", "
		}
		out += option
	}
	return out
}
