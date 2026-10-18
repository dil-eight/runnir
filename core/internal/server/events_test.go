//go:build !windows

package server

import (
	"context"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"runnir/core/internal/events"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/repository"
)

func next(t *testing.T, stream corev1.RunnirCore_SubscribeEventsClient) *corev1.CoreEvent {
	t.Helper()
	event, err := stream.Recv()
	if err != nil {
		t.Fatalf("recv: %v", err)
	}
	return event
}

func TestEventStreamReportsRepositoryLifecycle(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	stream, err := client.SubscribeEvents(ctx, &corev1.SubscribeEventsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	ready := next(t, stream)
	if ready.Type != corev1.CoreEventType_CORE_EVENT_TYPE_CORE_READY {
		t.Fatalf("first event = %v, want CORE_READY", ready)
	}

	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	id := opened.Repository.Id
	if _, err := client.RefreshRepository(ctx, &corev1.RefreshRepositoryRequest{RepositoryId: id}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.CloseRepository(ctx, &corev1.CloseRepositoryRequest{RepositoryId: id}); err != nil {
		t.Fatal(err)
	}

	last := ready.Sequence
	for _, want := range []corev1.CoreEventType{
		corev1.CoreEventType_CORE_EVENT_TYPE_REPOSITORY_OPENED,
		corev1.CoreEventType_CORE_EVENT_TYPE_REPOSITORY_REFRESHED,
		corev1.CoreEventType_CORE_EVENT_TYPE_REPOSITORY_CLOSED,
	} {
		e := next(t, stream)
		if e.Type != want || e.RepositoryId != id || e.Sequence <= last || e.OccurredAt == nil {
			t.Fatalf("event = %v, want %v for %s after sequence %d", e, want, id, last)
		}
		last = e.Sequence
	}
}

func TestEventStreamFiltersByRepository(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	other, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	watched := t.TempDir()
	// Ids are derived from paths, so the watched id is known only after open;
	// subscribe to the other repository's id and expect silence for the rest.
	stream, err := client.SubscribeEvents(ctx, &corev1.SubscribeEventsRequest{RepositoryIds: []string{other.Repository.Id}})
	if err != nil {
		t.Fatal(err)
	}
	next(t, stream) // CORE_READY

	if _, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: watched}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.RefreshRepository(ctx, &corev1.RefreshRepositoryRequest{RepositoryId: other.Repository.Id}); err != nil {
		t.Fatal(err)
	}
	e := next(t, stream)
	if e.RepositoryId != other.Repository.Id || e.Type != corev1.CoreEventType_CORE_EVENT_TYPE_REPOSITORY_REFRESHED {
		t.Fatalf("got %v; events of the unwatched repository leaked", e)
	}
}

func TestShutdownEndsOpenStreamsPromptly(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	stream, err := client.SubscribeEvents(ctx, &corev1.SubscribeEventsRequest{})
	if err != nil {
		t.Fatal(err)
	}
	next(t, stream)

	began := time.Now()
	if err := stop(); err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(began); elapsed > 3*time.Second {
		t.Fatalf("shutdown took %v with an open stream", elapsed)
	}
	if _, err := stream.Recv(); status.Code(err) != codes.Unavailable {
		t.Fatalf("recv after shutdown = %v, want Unavailable", err)
	}
}

// blockingStream stands in for a client that stopped reading.
type blockingStream struct {
	grpc.ServerStream
	ctx   context.Context
	gate  chan struct{}
	mu    sync.Mutex
	sends int
}

func (s *blockingStream) Context() context.Context { return s.ctx }
func (s *blockingStream) Send(*corev1.CoreEvent) error {
	s.mu.Lock()
	s.sends++
	first := s.sends == 1
	s.mu.Unlock()
	if !first {
		<-s.gate
	}
	return nil
}

func TestSlowSubscriberIsDisconnectedWithResourceExhausted(t *testing.T) {
	bus := events.New(2)
	svc := &service{repositories: repository.New(nil, nil), events: bus}
	stream := &blockingStream{ctx: context.Background(), gate: make(chan struct{})}

	result := make(chan error, 1)
	go func() { result <- svc.SubscribeEvents(&corev1.SubscribeEventsRequest{}, stream) }()
	for bus.Subscribers() == 0 {
		time.Sleep(time.Millisecond)
	}
	for i := 0; i < 50; i++ {
		bus.Publish(events.Event{Type: corev1.CoreEventType_CORE_EVENT_TYPE_CORE_ERROR})
	}
	close(stream.gate)

	select {
	case err := <-result:
		if status.Code(err) != codes.ResourceExhausted {
			t.Fatalf("err = %v, want ResourceExhausted", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("handler did not return after the subscriber overflowed")
	}
	if bus.Subscribers() != 0 {
		t.Fatal("overflowed subscriber was not removed")
	}
}
