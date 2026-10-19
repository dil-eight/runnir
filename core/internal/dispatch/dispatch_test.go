package dispatch

import (
	"errors"
	"strings"
	"sync"
	"testing"
	"time"

	"runnir/core/internal/scanner"
)

type clock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *clock) Now() time.Time      { c.mu.Lock(); defer c.mu.Unlock(); return c.now }
func (c *clock) add(d time.Duration) { c.mu.Lock(); c.now = c.now.Add(d); c.mu.Unlock() }

func request() Request {
	return Request{RepositoryID: "repo_1", Owner: "o", Name: "r", WorkflowID: 7, WorkflowPath: ".github/workflows/deploy.yml",
		Ref: "main", Inputs: map[string]string{"environment": "staging"}}
}

func TestAConfirmationWorksOnceAndCarriesTheExactRequest(t *testing.T) {
	store := NewStore(time.Minute, nil)
	original := request()
	pending, err := store.Prepare(original)
	if err != nil || !strings.HasPrefix(pending.ID, "dispatch_") {
		t.Fatalf("prepare = %+v, %v", pending, err)
	}
	original.Inputs["environment"] = "production" // the caller's map changing later must not matter
	confirmed, err := store.Confirm(pending.ID)
	if err != nil || confirmed.Inputs["environment"] != "staging" || confirmed.WorkflowID != 7 {
		t.Fatalf("confirm = %+v, %v", confirmed, err)
	}
	if _, err := store.Confirm(pending.ID); !errors.Is(err, ErrUnknown) {
		t.Fatalf("second confirm = %v, want ErrUnknown", err)
	}
	if _, err := store.Confirm("dispatch_made_up"); !errors.Is(err, ErrUnknown) {
		t.Fatalf("unknown = %v", err)
	}
}

func TestAConfirmationExpires(t *testing.T) {
	c := &clock{now: time.Unix(1_000, 0)}
	store := NewStore(time.Minute, c.Now)
	pending, _ := store.Prepare(request())
	c.add(time.Minute)
	if _, err := store.Confirm(pending.ID); !errors.Is(err, ErrExpired) {
		t.Fatalf("expired = %v", err)
	}
}

func TestPendingPreparationsAreBounded(t *testing.T) {
	c := &clock{now: time.Unix(1_000, 0)}
	store := NewStore(time.Minute, c.Now)
	for i := 0; i < maxPending; i++ {
		if _, err := store.Prepare(request()); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := store.Prepare(request()); !errors.Is(err, ErrTooMany) {
		t.Fatalf("over the limit = %v", err)
	}
	c.add(2 * time.Minute) // expired ones make room
	if _, err := store.Prepare(request()); err != nil {
		t.Fatalf("after expiry = %v", err)
	}
}

func TestValidationFollowsTheDefinition(t *testing.T) {
	definition := scanner.DispatchDefinition{Dispatchable: true, Inputs: []scanner.DispatchInput{
		{Name: "environment", Type: "choice", Required: true, Options: []string{"staging", "production"}},
		{Name: "dry_run", Type: "boolean", Default: "false"},
		{Name: "replicas", Type: "number"},
		{Name: "region", Type: "string", Required: true, Default: "eu"},
	}}
	if problems := Validate(definition, "main", map[string]string{"environment": "staging", "dry_run": "true", "replicas": "3"}); len(problems) != 0 {
		t.Fatalf("valid inputs: %v", problems)
	}
	problems := Validate(definition, "main", map[string]string{"environment": "qa", "dry_run": "yes", "replicas": "many", "extra": "x"})
	text := strings.Join(problems, "\n")
	for _, want := range []string{`"environment" must be one of: staging, production.`, `"dry_run" must be true or false.`, `"replicas" must be a number.`, `"extra" is not an input`} {
		if !strings.Contains(text, want) {
			t.Errorf("missing %q in %q", want, text)
		}
	}
	if problems := Validate(definition, "main", map[string]string{}); len(problems) != 1 || !strings.Contains(problems[0], `"environment" is required`) {
		t.Fatalf("required = %v", problems)
	}
	if problems := Validate(scanner.DispatchDefinition{}, "v1.0", nil); len(problems) != 1 || !strings.Contains(problems[0], "no workflow_dispatch trigger on v1.0") {
		t.Fatalf("not dispatchable = %v", problems)
	}
}
