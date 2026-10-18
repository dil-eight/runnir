package events

import (
	"errors"
	"sync"
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func opened(repo string) Event {
	return Event{Type: corev1.CoreEventType_CORE_EVENT_TYPE_REPOSITORY_OPENED, RepositoryID: repo}
}

func recv(t *testing.T, s *Subscription) Event {
	t.Helper()
	select {
	case e, ok := <-s.C:
		if !ok {
			t.Fatalf("subscription closed: %v", s.Err())
		}
		return e
	case <-time.After(2 * time.Second):
		t.Fatal("no event")
		return Event{}
	}
}

func TestDeliversInOrderWithMonotonicSequence(t *testing.T) {
	bus := New(16)
	sub := bus.Subscribe(nil)
	defer sub.Close()
	for _, repo := range []string{"a", "b", "c"} {
		bus.Publish(opened(repo))
	}
	var last uint64
	for _, want := range []string{"a", "b", "c"} {
		e := recv(t, sub)
		if e.RepositoryID != want || e.Sequence <= last || e.At.IsZero() {
			t.Fatalf("event = %+v (last seq %d)", e, last)
		}
		last = e.Sequence
	}
}

func TestBaselineMarksTheLastPublishedSequence(t *testing.T) {
	bus := New(16)
	bus.Publish(opened("a"))
	bus.Publish(opened("b"))
	sub := bus.Subscribe(nil)
	defer sub.Close()
	if sub.Baseline != 2 {
		t.Fatalf("baseline = %d, want 2", sub.Baseline)
	}
	bus.Publish(opened("c"))
	if e := recv(t, sub); e.Sequence != 3 {
		t.Fatalf("first event after subscribe has sequence %d, want 3", e.Sequence)
	}
}

func TestFilterKeepsRepositoryEventsScopedButNotGlobalOnes(t *testing.T) {
	bus := New(16)
	only := bus.Subscribe([]string{"a"})
	defer only.Close()
	bus.Publish(opened("b"))
	bus.Publish(Event{Type: corev1.CoreEventType_CORE_EVENT_TYPE_CORE_ERROR, Message: "global"})
	bus.Publish(opened("a"))

	if e := recv(t, only); e.Message != "global" {
		t.Fatalf("want the global event first, got %+v", e)
	}
	if e := recv(t, only); e.RepositoryID != "a" {
		t.Fatalf("want repository a, got %+v", e)
	}
	select {
	case e := <-only.C:
		t.Fatalf("leaked event for another repository: %+v", e)
	default:
	}
}

func TestSlowSubscriberOverflowsAloneAndPublishNeverBlocks(t *testing.T) {
	bus := New(4)
	slow := bus.Subscribe(nil)
	fast := bus.Subscribe(nil)
	defer fast.Close()

	done := make(chan struct{})
	go func() {
		for i := 0; i < 100; i++ {
			bus.Publish(opened("a"))
			for len(fast.C) > 0 {
				<-fast.C
			}
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Publish blocked on a slow subscriber")
	}

	drained := 0
	for range slow.C {
		drained++
	}
	if drained > 4 {
		t.Fatalf("buffer held %d events, cap is 4", drained)
	}
	if !errors.Is(slow.Err(), ErrOverflow) {
		t.Fatalf("slow.Err() = %v, want ErrOverflow", slow.Err())
	}
	if fast.Err() != nil {
		t.Fatalf("fast subscriber was affected: %v", fast.Err())
	}
	bus.Publish(opened("z"))
	if recv(t, fast).RepositoryID != "z" {
		t.Fatal("fast subscriber stopped receiving")
	}
}

func TestCloseUnsubscribesAndIsIdempotent(t *testing.T) {
	bus := New(4)
	sub := bus.Subscribe(nil)
	sub.Close()
	sub.Close()
	if _, ok := <-sub.C; ok {
		t.Fatal("channel should be closed")
	}
	if sub.Err() != nil {
		t.Fatalf("explicit close is not an error: %v", sub.Err())
	}
	if bus.Subscribers() != 0 {
		t.Fatalf("subscribers = %d", bus.Subscribers())
	}
	bus.Publish(opened("a")) // must not panic on a closed channel
}

func TestBusCloseEndsAllSubscriptionsAndRejectsNewOnes(t *testing.T) {
	bus := New(4)
	a, b := bus.Subscribe(nil), bus.Subscribe(nil)
	bus.Close()
	for _, s := range []*Subscription{a, b} {
		if _, ok := <-s.C; ok {
			t.Fatal("subscription still open after bus close")
		}
	}
	late := bus.Subscribe(nil)
	if _, ok := <-late.C; ok {
		t.Fatal("a subscription on a closed bus must be closed")
	}
	bus.Publish(opened("a"))
}

func TestConcurrentPublishSubscribeCloseIsRaceFree(t *testing.T) {
	bus := New(8)
	var wg sync.WaitGroup
	for p := 0; p < 4; p++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				bus.Publish(opened("a"))
			}
		}()
	}
	for s := 0; s < 8; s++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 50; i++ {
				sub := bus.Subscribe(nil)
				select {
				case <-sub.C:
				default:
				}
				sub.Close()
			}
		}()
	}
	wg.Wait()
	if bus.Subscribers() != 0 {
		t.Fatalf("subscribers = %d", bus.Subscribers())
	}
}

func TestSequenceIsUniqueUnderConcurrentPublish(t *testing.T) {
	bus := New(4096)
	sub := bus.Subscribe(nil)
	defer sub.Close()
	var wg sync.WaitGroup
	for p := 0; p < 8; p++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 200; i++ {
				bus.Publish(opened("a"))
			}
		}()
	}
	wg.Wait()
	var last uint64
	for i := 0; i < 1600; i++ {
		e := recv(t, sub)
		if e.Sequence != last+1 {
			t.Fatalf("sequence %d after %d: delivery order must match sequence", e.Sequence, last)
		}
		last = e.Sequence
	}
}
