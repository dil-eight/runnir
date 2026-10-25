//go:build !windows

package store

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func addSaving(t *testing.T, s *Store, minutes int64, at time.Time) {
	t.Helper()
	if err := s.AddSaving(context.Background(), SavingLocalRuns, minutes, at); err != nil {
		t.Fatal(err)
	}
}

func TestSavingsAddUpAndKeepTheFirstTime(t *testing.T) {
	s := openTest(t, t.TempDir())
	if got, err := s.Savings(context.Background()); err != nil || len(got) != 0 {
		t.Fatalf("savings = %v, %v", got, err)
	}
	addSaving(t, s, 3, fixedNow())
	addSaving(t, s, 5, fixedNow().Add(time.Hour))
	got, err := s.Savings(context.Background())
	if err != nil || len(got) != 1 {
		t.Fatalf("savings = %v, %v", got, err)
	}
	if v := got[0]; v.Kind != SavingLocalRuns || v.Minutes != 8 || v.Count != 2 || !v.Since.Equal(fixedNow()) {
		t.Fatalf("saving = %+v", v)
	}
}

func TestClearCacheKeepsSavings(t *testing.T) {
	s := openTest(t, t.TempDir())
	addSaving(t, s, 4, fixedNow())
	if err := s.ClearCache(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.Savings(context.Background()); len(got) != 1 || got[0].Minutes != 4 {
		t.Fatalf("savings = %v", got)
	}
}

func TestSavingsOutliveTheLocalRunBudget(t *testing.T) {
	s := openTest(t, t.TempDir())
	for i := 0; i < maxLocalRuns+1; i++ {
		record(t, s, fmt.Sprintf("exec_%03d", i), LocalSucceeded)
		addSaving(t, s, 1, fixedNow())
	}
	if got, _ := s.Savings(context.Background()); len(got) != 1 || got[0].Count != maxLocalRuns+1 {
		t.Fatalf("savings = %v", got)
	}
}

func TestSavingsAreRestoredWithTheDatabase(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	addSaving(t, s, 7, fixedNow())
	_ = s.Close()
	for _, name := range []string{"state.sqlite", "state.sqlite-wal", "state.sqlite-shm"} {
		_ = os.Remove(filepath.Join(dir, name))
	}
	again := openTest(t, dir)
	if got, _ := again.Savings(context.Background()); len(got) != 1 || got[0].Minutes != 7 || got[0].Count != 1 {
		t.Fatalf("savings = %v", got)
	}
}

func TestRestoringKeepsTheLargerTotal(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	addSaving(t, s, 2, fixedNow())
	// The damaged file has counted one more run than the backup.
	if _, err := s.restoreLocal(context.Background(), localData{savings: []Saving{
		{Kind: SavingLocalRuns, Minutes: 9, Count: 2, Since: fixedNow()},
	}}); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.Savings(context.Background()); len(got) != 1 || got[0].Minutes != 9 {
		t.Fatalf("savings = %v", got)
	}
	if _, err := s.restoreLocal(context.Background(), localData{savings: []Saving{
		{Kind: SavingLocalRuns, Minutes: 1, Count: 0, Since: fixedNow()},
	}}); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.Savings(context.Background()); len(got) != 1 || got[0].Minutes != 2 {
		t.Fatalf("a smaller salvaged total replaced the backup: %v", got)
	}
}
