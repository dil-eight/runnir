//go:build !windows

package server

import (
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/store"
)

func TestSavingsLeaveOutKindsThisCoreDoesNotKnow(t *testing.T) {
	since := time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)
	got := savingMessages([]store.Saving{
		{Kind: "cache_hits", Minutes: 40, Count: 3, Since: since},
		{Kind: store.SavingLocalRuns, Minutes: 12, Count: 5, Since: since},
	})
	if len(got) != 1 {
		t.Fatalf("savings = %v", got)
	}
	if v := got[0]; v.Kind != corev1.SavingKind_SAVING_KIND_LOCAL_RUNS || v.Minutes != 12 || v.Count != 5 || !v.Since.AsTime().Equal(since) {
		t.Fatalf("saving = %v", v)
	}
}
