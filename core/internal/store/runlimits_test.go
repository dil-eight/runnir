package store

import (
	"context"
	"testing"
	"time"
)

func TestRunLimitsAreKeptUntilForgotten(t *testing.T) {
	s, err := Open("", Options{})
	if err != nil {
		t.Fatal(err)
	}
	defer s.Close()
	ctx := context.Background()
	if _, ok, err := s.RunLimits(ctx); ok || err != nil {
		t.Fatalf("a new store has none: %v %v", ok, err)
	}
	want := RunLimits{CPUs: 6, MemoryBytes: 4 << 30, Timeout: time.Hour}
	if err := s.SetRunLimits(ctx, &want); err != nil {
		t.Fatal(err)
	}
	if err := s.ClearCache(ctx); err != nil {
		t.Fatal(err)
	}
	if got, ok, _ := s.RunLimits(ctx); !ok || got != want {
		t.Fatalf("after Clear Cache = %+v %v", got, ok)
	}
	changed := RunLimits{CPUs: 2, MemoryBytes: 1 << 30, Timeout: 5 * time.Minute}
	if err := s.SetRunLimits(ctx, &changed); err != nil {
		t.Fatal(err)
	}
	if got, _, _ := s.RunLimits(ctx); got != changed {
		t.Fatalf("changed = %+v", got)
	}
	if err := s.SetRunLimits(ctx, nil); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := s.RunLimits(ctx); ok {
		t.Fatal("forgotten limits came back")
	}
}
