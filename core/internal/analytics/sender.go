package analytics

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// maxBatchesPerRequest bounds a request; a day at Full is a few dozen
// events.
const maxBatchesPerRequest = 20

// Sender seals the ledger's completed days and sends due batches.
type Sender struct {
	Ledger *Ledger
	// Host is PostHog's, for example https://us.i.posthog.com; events go
	// to its /batch/.
	Host string
	// Token is the PostHog project token; empty sends nothing.
	Token string
	Env   Env
	// Client sends requests; nil uses one with a 20-second timeout that
	// follows no redirect, so batches only go to Host.
	Client *http.Client
	// Log gets one line per failed send, never the body; nil drops it.
	Log io.Writer
	// Now is the clock for Run; nil is time.Now.
	Now func() time.Time
}

// Enabled: a token, a host and a ledger kept on disk.
func (s *Sender) Enabled() bool { return s.Token != "" && s.Host != "" && s.Ledger.Persistent() }

// Flush seals completed days, then sends due batches until none is due or
// a request fails. A failed request delays its batches.
func (s *Sender) Flush(ctx context.Context) error {
	if err := s.Ledger.Seal(); err != nil {
		return err
	}
	if !s.Enabled() {
		return nil
	}
	for ctx.Err() == nil {
		due, err := s.Ledger.Due(maxBatchesPerRequest)
		if err != nil || len(due) == 0 {
			return err
		}
		ids := make([]string, len(due))
		for i, b := range due {
			ids[i] = b.ID
		}
		body, err := Body(s.Token, s.Env, due)
		if err != nil {
			// Never sendable: a counter this build no longer allows.
			_ = s.Ledger.Remove(ids)
			return err
		}
		if err := s.post(ctx, body); err != nil {
			_ = s.Ledger.Failed(ids)
			if s.Log != nil {
				fmt.Fprintf(s.Log, "analytics: %v; %d batches wait for the next send\n", err, len(ids))
			}
			return err
		}
		if err := s.Ledger.Remove(ids); err != nil {
			return err
		}
	}
	return ctx.Err()
}

// Run flushes after first, then every every, or sooner when a failed
// batch's retry comes first; it returns when ctx ends.
func (s *Sender) Run(ctx context.Context, first, every time.Duration) {
	now := s.Now
	if now == nil {
		now = time.Now
	}
	timer := time.NewTimer(first)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		_ = s.Flush(ctx)
		wait := every
		if s.Enabled() {
			if next, ok, err := s.Ledger.NextAttempt(); err == nil && ok {
				if d := next.Sub(now()); d < wait {
					wait = max(d, time.Minute)
				}
			}
		}
		timer.Reset(wait)
	}
}

func (s *Sender) post(ctx context.Context, body []byte) error {
	endpoint := strings.TrimRight(s.Host, "/") + "/batch/"
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	client := s.Client
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return fmt.Errorf("the analytics endpoint answered %d", response.StatusCode)
	}
	return nil
}
