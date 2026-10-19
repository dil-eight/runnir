// Package dispatch is the Core's approval step for starting workflows: a
// dispatch is first prepared (validated against the workflow at the chosen
// ref) and only runs when that exact preparation is confirmed, once, before it
// expires. A client cannot start a workflow in a single call.
package dispatch

import (
	"fmt"
	"maps"
	"slices"
	"strconv"
	"time"

	"runnir/core/internal/approval"
	"runnir/core/internal/scanner"
)

var (
	// ErrUnknown: no such preparation, or it was already confirmed.
	ErrUnknown = approval.ErrUnknown
	ErrExpired = approval.ErrExpired
	ErrTooMany = approval.ErrTooMany
)

const (
	DefaultTTL     = approval.DefaultTTL
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

type Pending = approval.Pending[Request]

// Store keeps prepared dispatches in memory. Safe for concurrent use.
type Store struct {
	store *approval.Store[Request]
}

func NewStore(ttl time.Duration, now func() time.Time) *Store {
	return &Store{store: approval.NewStore[Request]("dispatch_", ttl, now)}
}

// Prepare records a validated request and returns its single-use id. The
// inputs are copied, so later changes to the caller's map do not matter.
func (s *Store) Prepare(request Request) (Pending, error) {
	request.Inputs = maps.Clone(request.Inputs)
	return s.store.Prepare(request)
}

// Confirm consumes a preparation. It succeeds at most once per id.
func (s *Store) Confirm(id string) (Request, error) {
	return s.store.Confirm(id)
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
