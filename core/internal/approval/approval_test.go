package approval

import (
	"errors"
	"strings"
	"testing"
	"time"
)

type action struct {
	RunID int64
	Kind  string
}

func TestAPreparationIsConfirmedOnceWithItsPrefix(t *testing.T) {
	store := NewStore[action]("action_", time.Minute, nil)
	pending, err := store.Prepare(action{RunID: 9, Kind: "cancel"})
	if err != nil || !strings.HasPrefix(pending.ID, "action_") {
		t.Fatalf("prepare = %+v, %v", pending, err)
	}
	got, err := store.Confirm(pending.ID)
	if err != nil || got != (action{RunID: 9, Kind: "cancel"}) {
		t.Fatalf("confirm = %+v, %v", got, err)
	}
	if _, err := store.Confirm(pending.ID); !errors.Is(err, ErrUnknown) {
		t.Fatalf("second confirm = %v, want ErrUnknown", err)
	}
}

func TestAnExpiredPreparationIsRefusedAndFreesItsSlot(t *testing.T) {
	now := time.Unix(1_000, 0)
	store := NewStore[action]("action_", time.Minute, func() time.Time { return now })
	first, _ := store.Prepare(action{RunID: 1})
	for i := 1; i < MaxPending; i++ {
		if _, err := store.Prepare(action{RunID: int64(i + 1)}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := store.Prepare(action{}); !errors.Is(err, ErrTooMany) {
		t.Fatalf("over the limit = %v", err)
	}
	now = now.Add(time.Minute)
	if _, err := store.Confirm(first.ID); !errors.Is(err, ErrExpired) {
		t.Fatalf("expired confirm = %v", err)
	}
	if _, err := store.Prepare(action{}); err != nil {
		t.Fatalf("after expiry = %v", err)
	}
}
