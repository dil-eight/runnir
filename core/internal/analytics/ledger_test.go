//go:build !windows

package analytics

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time      { return c.t }
func (c *clock) add(d time.Duration) { c.t = c.t.Add(d) }

func sequence() func() string {
	n := 0
	return func() string { n++; return fmt.Sprintf("id-%d", n) }
}

// day(0) is 2026-10-20 at noon UTC.
func day(n int) time.Time { return time.Date(2026, 10, 20+n, 12, 0, 0, 0, time.UTC) }

var (
	screenRuns     = UsageCounter(corev1.UsageEvent_USAGE_EVENT_SCREEN_RUNS_LIST)
	screenOverview = UsageCounter(corev1.UsageEvent_USAGE_EVENT_SCREEN_OVERVIEW_PAGE)
	actionRunLocal = UsageCounter(corev1.UsageEvent_USAGE_EVENT_ACTION_LOCAL_RUN_RUN)
)

func openLedger(t *testing.T, dir string, c *clock, ids func() string) *Ledger {
	t.Helper()
	l, err := Open(dir, Options{Now: c.now, NewID: ids})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = l.Close() })
	return l
}

func must(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func state(t *testing.T, l *Ledger) State {
	t.Helper()
	s, err := l.State()
	must(t, err)
	return s
}

// pending is every count not sent yet, sealed or not.
func pending(t *testing.T, l *Ledger) Counts {
	t.Helper()
	s := state(t, l)
	out := Counts{}
	for _, counts := range []Counts{s.Sealed, s.Unsealed} {
		for name, value := range counts {
			out[name] += value
		}
	}
	return out
}

func due(t *testing.T, l *Ledger) []Batch {
	t.Helper()
	b, err := l.Due(100)
	must(t, err)
	return b
}

func TestFirstLaunchIsSealedOnceAcrossRestarts(t *testing.T) {
	dir := t.TempDir()
	c := &clock{t: day(0)}
	l := openLedger(t, dir, c, sequence())
	s := state(t, l)
	if s.Level != Basic || s.PromptAnswered || !s.Persistent || s.Sealed["first_launch"] != 1 || len(s.Unsealed) != 0 {
		t.Fatalf("fresh = %+v", s)
	}
	batches := due(t, l)
	if len(batches) != 1 || batches[0].Event != eventFirstLaunch || batches[0].ID != "id-1" || batches[0].Day != "2026-10-20" {
		t.Fatalf("outbox = %+v", batches)
	}
	must(t, l.Close())
	again := openLedger(t, dir, c, sequence())
	if got := pending(t, again)["first_launch"]; got != 1 {
		t.Fatalf("first_launch after a restart = %d, want 1", got)
	}
	must(t, again.Remove([]string{"id-1"}))
	must(t, again.Close())
	third := openLedger(t, dir, c, sequence())
	if got := pending(t, third)["first_launch"]; got != 0 {
		t.Fatalf("first_launch came back after delivery: %d", got)
	}
}

func TestEveryIncrementIsSealedIntoExactlyOneBatch(t *testing.T) {
	c := &clock{t: day(0)}
	l := openLedger(t, t.TempDir(), c, sequence())
	must(t, l.Remove([]string{"id-1"})) // first_launch
	must(t, l.Add(day(0), Counts{LocalRuns: 1, LocalBilledMinutes: 4}))
	must(t, l.Add(day(0).Add(time.Hour), Counts{LocalBilledMinutes: 3}))
	must(t, l.Add(day(1), Counts{LocalRuns: 1, LocalBilledMinutes: 2}))
	c.t = day(1)
	must(t, l.Seal())
	batches := due(t, l)
	if len(batches) != 1 || batches[0].Day != "2026-10-20" || batches[0].Event != eventDay ||
		batches[0].Counts[LocalBilledMinutes] != 7 || batches[0].Counts[LocalRuns] != 1 {
		t.Fatalf("sealed on day 1 = %+v", batches)
	}
	if s := state(t, l); s.Sealed[LocalBilledMinutes] != 7 || s.Unsealed[LocalBilledMinutes] != 2 {
		t.Fatalf("state on day 1 = %+v", s)
	}
	// Day 1 is today: not sealed yet; sealing again adds nothing.
	must(t, l.Seal())
	if got := len(due(t, l)); got != 1 {
		t.Fatalf("batches after a second seal = %d", got)
	}
	c.t = day(2)
	must(t, l.Seal())
	batches = due(t, l)
	if len(batches) != 2 || batches[1].Day != "2026-10-21" || batches[1].Counts[LocalBilledMinutes] != 2 {
		t.Fatalf("sealed on day 2 = %+v", batches)
	}
	if p := pending(t, l); p[LocalBilledMinutes] != 9 || p[LocalRuns] != 2 {
		t.Fatalf("pending = %+v, want every count once", p)
	}
}

func TestUsageCountsOnlyAtFullAndUnknownNamesAreRefused(t *testing.T) {
	c := &clock{t: day(0)}
	l := openLedger(t, t.TempDir(), c, sequence())
	must(t, l.Add(day(0), Counts{screenRuns: 1, LocalRuns: 1}))
	must(t, l.Record(day(0), corev1.UsageEvent_USAGE_EVENT_ACTION_LOCAL_RUN_RUN))
	if p := pending(t, l); p[screenRuns] != 0 || p[actionRunLocal] != 0 || p[LocalRuns] != 1 {
		t.Fatalf("basic counted %+v", p)
	}
	if err := l.Add(day(0), Counts{"repository_name": 1, LocalRuns: 1}); !errors.Is(err, ErrNotAllowed) {
		t.Fatalf("unknown name = %v", err)
	}
	if err := l.Add(day(0), Counts{LocalRuns: -1}); !errors.Is(err, ErrNotAllowed) {
		t.Fatalf("negative value = %v", err)
	}
	if err := l.Record(day(0), corev1.UsageEvent_USAGE_EVENT_UNSPECIFIED); !errors.Is(err, ErrNotAllowed) {
		t.Fatalf("unspecified event = %v", err)
	}
	if p := pending(t, l); p[LocalRuns] != 1 {
		t.Fatalf("a refused call counted: %+v", p)
	}
	must(t, l.SetLevel(Full, true))
	must(t, l.Add(day(0), Counts{screenRuns: 2}))
	must(t, l.Record(day(0), corev1.UsageEvent_USAGE_EVENT_ACTION_LOCAL_RUN_RUN))
	if p := pending(t, l); p[screenRuns] != 2 || p[actionRunLocal] != 1 {
		t.Fatalf("full did not count usage: %+v", p)
	}
}

func TestOffCountsNothingAndEmptiesEverything(t *testing.T) {
	c := &clock{t: day(1)}
	l := openLedger(t, t.TempDir(), c, sequence())
	must(t, l.Add(day(0), Counts{LocalRuns: 1}))
	must(t, l.Add(day(1), Counts{LocalRuns: 1}))
	must(t, l.Seal())
	must(t, l.SetLevel(Off, false))
	must(t, l.Add(day(1), Counts{LocalRuns: 5}))
	s := state(t, l)
	if s.Level != Off || s.PromptAnswered || len(s.Sealed) != 0 || len(s.Unsealed) != 0 || len(due(t, l)) != 0 {
		t.Fatalf("off = %+v", s)
	}
	must(t, l.SetLevel(Basic, false))
	if got := pending(t, l)["first_launch"]; got != 0 {
		t.Fatal("first_launch came back after Off")
	}
}

func TestEachConsentGetsANewIDThatOnlyLaterCountsCarry(t *testing.T) {
	c := &clock{t: day(0)}
	l := openLedger(t, t.TempDir(), c, sequence())
	must(t, l.Remove([]string{"id-1"}))
	must(t, l.Add(day(0), Counts{LocalBilledMinutes: 3}))
	must(t, l.SetLevel(Full, true)) // seals id-2 without an id, then makes id-3
	s := state(t, l)
	if s.Level != Full || !s.PromptAnswered || s.ID != "id-3" {
		t.Fatalf("full = %+v", s)
	}
	batches := due(t, l)
	if len(batches) != 1 || batches[0].Level != Basic || batches[0].AnalyticsID != "" || batches[0].Counts[LocalBilledMinutes] != 3 {
		t.Fatalf("sealed at consent = %+v", batches)
	}
	must(t, l.Add(day(0), Counts{LocalBilledMinutes: 2, actionRunLocal: 1}))
	c.t = day(1)
	must(t, l.Seal()) // id-4
	batches = due(t, l)
	if len(batches) != 2 || batches[1].ID != "id-4" || batches[1].Level != Full || batches[1].AnalyticsID != "id-3" ||
		batches[1].Counts[actionRunLocal] != 1 {
		t.Fatalf("after consent = %+v", batches)
	}
	must(t, l.SetLevel(Basic, false))
	must(t, l.SetLevel(Full, false))
	if s := state(t, l); s.ID == "" || s.ID == "id-3" {
		t.Fatalf("a second consent reused or lost the id: %q", s.ID)
	}
}

func TestLeavingFullStripsTheIDAndUsageButKeepsTheBatchID(t *testing.T) {
	c := &clock{t: day(0)}
	l := openLedger(t, t.TempDir(), c, sequence())
	must(t, l.Remove([]string{"id-1"}))
	must(t, l.SetLevel(Full, true)) // analytics id id-2
	must(t, l.Add(day(0), Counts{LocalRuns: 1, screenOverview: 4}))
	must(t, l.Add(day(1), Counts{screenRuns: 1}))
	must(t, l.Add(day(2), Counts{screenRuns: 1, LocalRuns: 1}))
	c.t = day(2)
	must(t, l.Seal()) // id-3 (day 0) and id-4 (day 1, usage only)
	sealed := due(t, l)
	if len(sealed) != 2 {
		t.Fatalf("sealed = %+v", sealed)
	}
	must(t, l.SetLevel(Basic, false))
	batches := due(t, l)
	if len(batches) != 1 || batches[0].ID != sealed[0].ID || batches[0].Level != Basic || batches[0].AnalyticsID != "" ||
		len(batches[0].Counts) != 1 || batches[0].Counts[LocalRuns] != 1 {
		t.Fatalf("stripped = %+v (was %+v)", batches, sealed)
	}
	p := pending(t, l)
	if p[screenRuns] != 0 || p[screenOverview] != 0 || p[LocalRuns] != 2 {
		t.Fatalf("pending = %+v", p)
	}
	if s := state(t, l); s.ID != "" {
		t.Fatalf("id kept: %q", s.ID)
	}
}

func TestFailedBatchesWaitAndKeepTheirID(t *testing.T) {
	c := &clock{t: day(0)}
	l := openLedger(t, t.TempDir(), c, sequence())
	must(t, l.Failed([]string{"id-1"}))
	if got := len(due(t, l)); got != 0 {
		t.Fatalf("due right after a failure: %d", got)
	}
	next, ok, err := l.NextAttempt()
	if err != nil || !ok || !next.Equal(day(0).Add(time.Minute)) {
		t.Fatalf("next = %v, %v, %v", next, ok, err)
	}
	c.add(time.Minute)
	if b := due(t, l); len(b) != 1 || b[0].ID != "id-1" {
		t.Fatalf("retry = %+v", b)
	}
	for i, want := range []time.Duration{time.Minute, 5 * time.Minute, 30 * time.Minute, 6 * time.Hour, 6 * time.Hour} {
		if got := RetryDelay(i + 1); got != want {
			t.Fatalf("RetryDelay(%d) = %v, want %v", i+1, got, want)
		}
	}
}

func TestTheOutboxKeepsSevenDays(t *testing.T) {
	c := &clock{t: day(0)}
	l := openLedger(t, t.TempDir(), c, sequence())
	c.t = day(8)
	must(t, l.Seal())
	if got := len(due(t, l)); got != 0 {
		t.Fatalf("an 8-day-old first_launch was kept: %d", got)
	}
}

func TestTheOutboxDropsTheOldestBeyondItsSize(t *testing.T) {
	old := maxOutboxBytes
	maxOutboxBytes = 1000
	t.Cleanup(func() { maxOutboxBytes = old })
	c := &clock{t: day(0)}
	l := openLedger(t, t.TempDir(), c, sequence())
	must(t, l.Remove([]string{"id-1"}))
	for d := 1; d <= 6; d++ {
		must(t, l.Add(day(d), Counts{LocalRuns: 1, LocalBilledMinutes: 1}))
	}
	c.t = day(7)
	must(t, l.Seal())
	batches := due(t, l)
	if len(batches) != 2 || batches[0].Day != "2026-10-25" || batches[1].Day != "2026-10-26" {
		t.Fatalf("kept = %+v, want the two newest days", batches)
	}
}

func TestADamagedLedgerIsReplacedAndSendsNothingUntilAsked(t *testing.T) {
	dir := t.TempDir()
	must(t, os.WriteFile(filepath.Join(dir, "analytics.sqlite"), []byte("not a database"), 0o600))
	l := openLedger(t, dir, &clock{t: day(0)}, sequence())
	s := state(t, l)
	if s.Level != Off || s.PromptAnswered || !s.Persistent || len(s.Sealed) != 0 || len(s.Unsealed) != 0 {
		t.Fatalf("replaced = %+v", s)
	}
}

func TestWithoutAFolderOrWhenLockedTheLedgerIsInMemory(t *testing.T) {
	c := &clock{t: day(0)}
	memory := openLedger(t, "", c, sequence())
	if memory.Persistent() || pending(t, memory)["first_launch"] != 0 {
		t.Fatal("a ledger without a folder is on disk or has a first_launch")
	}
	dir := t.TempDir()
	first := openLedger(t, dir, c, sequence())
	second := openLedger(t, dir, c, sequence())
	if !first.Persistent() || second.Persistent() {
		t.Fatalf("persistent = %v, %v; want only the first", first.Persistent(), second.Persistent())
	}
}
