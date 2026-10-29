//go:build !windows

package store

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func recordStart(t *testing.T, s *Store, r RunStart) {
	t.Helper()
	if err := s.RecordStart(context.Background(), r); err != nil {
		t.Fatal(err)
	}
}

func TestAStartIsKeptOncePerAttempt(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	at := fixedNow()
	recordStart(t, s, RunStart{Source: testSource, RunID: 21, Attempt: 2, Kind: StartRerunFailed, SentAt: at})
	// The first record of an attempt stands.
	recordStart(t, s, RunStart{Source: testSource, RunID: 21, Attempt: 2, Kind: StartRerun, SentAt: at.Add(time.Minute)})
	recordStart(t, s, RunStart{Source: testSource, RunID: 21, Attempt: 1, Kind: StartDispatch, SentAt: at.Add(-time.Hour)})
	recordStart(t, s, RunStart{Source: testSource, RunID: 30, Attempt: 3, Kind: StartRerunJob, SentAt: at})

	got, err := s.RunStarts(ctx, testSource)
	if err != nil {
		t.Fatal(err)
	}
	run := got[21]
	if len(run) != 2 || run[0].Attempt != 1 || run[0].Kind != StartDispatch || run[1].Attempt != 2 || run[1].Kind != StartRerunFailed ||
		!run[1].SentAt.Equal(at) || run[1].Source != testSource {
		t.Fatalf("run 21 = %+v", run)
	}
	if len(got[30]) != 1 || got[30][0].Kind != StartRerunJob {
		t.Fatalf("run 30 = %+v", got[30])
	}
	if err := s.RecordStart(ctx, RunStart{Source: testSource, RunID: 21}); err == nil {
		t.Fatal("attempt 0 is not an attempt")
	}
}

func TestStartsBelongToTheRepositoryTheyWereSentTo(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	recordStart(t, s, RunStart{Source: testSource, RunID: 21, Attempt: 1, Kind: StartDispatch, SentAt: fixedNow()})
	other := Source{ServerID: "ghe", Repository: "o/r"}
	recordStart(t, s, RunStart{Source: other, RunID: 21, Attempt: 2, Kind: StartRerun, SentAt: fixedNow()})
	if got, _ := s.RunStarts(ctx, testSource); len(got[21]) != 1 || got[21][0].Attempt != 1 {
		t.Fatalf("this repository = %+v", got)
	}
	if got, _ := s.RunStarts(ctx, other); len(got[21]) != 1 || got[21][0].Attempt != 2 {
		t.Fatalf("the other server = %+v", got)
	}
}

func TestADispatchIsAStartOnceItsRunIsKnown(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	at := fixedNow()
	if _, err := s.RecordDispatch(ctx, DispatchRecord{Source: testSource, WorkflowPath: ".github/workflows/deploy.yml", Ref: "main", SentAt: at, RunID: 4242}); err != nil {
		t.Fatal(err)
	}
	waiting := recordDispatch(t, s, ".github/workflows/deploy.yml", "dev", nil, at.Add(time.Minute))
	got, _ := s.RunStarts(ctx, testSource)
	if len(got) != 1 || len(got[4242]) != 1 || got[4242][0].Attempt != 1 || got[4242][0].Kind != StartDispatch || !got[4242][0].SentAt.Equal(at) {
		t.Fatalf("a dispatch GitHub named the run of = %+v", got)
	}

	// The app finds the run of the other one; a later guess changes nothing.
	if err := s.LinkDispatchRun(ctx, waiting, 5555); err != nil {
		t.Fatal(err)
	}
	if err := s.LinkDispatchRun(ctx, waiting, 6666); err != nil {
		t.Fatal(err)
	}
	got, _ = s.RunStarts(ctx, testSource)
	if len(got[5555]) != 1 || !got[5555][0].SentAt.Equal(at.Add(time.Minute)) || len(got[6666]) != 0 {
		t.Fatalf("after the link = %+v", got)
	}

	// Clear history and Clear Cache keep them.
	if _, err := s.ClearDispatchHistory(ctx, testSource); err != nil {
		t.Fatal(err)
	}
	if err := s.ClearCache(ctx); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.RunStarts(ctx, testSource); len(got) != 2 {
		t.Fatalf("after clearing = %+v", got)
	}
}

func TestOnlyTheNewestStartsAreKept(t *testing.T) {
	defer func(n int) { maxRunStarts = n }(maxRunStarts)
	maxRunStarts = 3
	s := openTest(t, t.TempDir())
	for i := int64(1); i <= 5; i++ {
		recordStart(t, s, RunStart{Source: testSource, RunID: i, Attempt: 2, Kind: StartRerun, SentAt: fixedNow().Add(time.Duration(i) * time.Minute)})
	}
	got, _ := s.RunStarts(context.Background(), testSource)
	if len(got) != 3 || got[1] != nil || got[2] != nil || got[5] == nil {
		t.Fatalf("kept = %+v", got)
	}
}

func TestStartsAreRestoredWithTheDatabase(t *testing.T) {
	dir := t.TempDir()
	s := openTest(t, dir)
	recordStart(t, s, RunStart{Source: testSource, RunID: 21, Attempt: 2, Kind: StartRerunFailed, SentAt: fixedNow()})
	_ = s.Close()
	for _, name := range []string{"state.sqlite", "state.sqlite-wal", "state.sqlite-shm"} {
		_ = os.Remove(filepath.Join(dir, name))
	}
	again := openTest(t, dir)
	if got, _ := again.RunStarts(context.Background(), testSource); len(got[21]) != 1 || got[21][0].Kind != StartRerunFailed {
		t.Fatalf("restored = %+v", got)
	}
}

func TestSalvagedStartsAreMergedWithTheBackup(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	recordStart(t, s, RunStart{Source: testSource, RunID: 21, Attempt: 2, Kind: StartRerunFailed, SentAt: fixedNow()})
	// The damaged file had a start the backup lacks.
	if _, err := s.restoreLocal(ctx, localData{starts: []RunStart{
		{Source: testSource, RunID: 30, Attempt: 1, Kind: StartDispatch, SentAt: fixedNow().Add(time.Hour)},
	}}); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.RunStarts(ctx, testSource); len(got[21]) != 1 || len(got[30]) != 1 {
		t.Fatalf("merged = %+v", got)
	}
}

func TestRestoredStartsKeepToTheBudget(t *testing.T) {
	defer func(n int) { maxRunStarts = n }(maxRunStarts)
	maxRunStarts = 2
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	recordStart(t, s, RunStart{Source: testSource, RunID: 1, Attempt: 2, Kind: StartRerun, SentAt: fixedNow()})
	recordStart(t, s, RunStart{Source: testSource, RunID: 2, Attempt: 2, Kind: StartRerun, SentAt: fixedNow().Add(time.Minute)})
	if _, err := s.restoreLocal(ctx, localData{starts: []RunStart{
		{Source: testSource, RunID: 3, Attempt: 2, Kind: StartRerun, SentAt: fixedNow().Add(time.Hour)},
	}}); err != nil {
		t.Fatal(err)
	}
	if got, _ := s.RunStarts(ctx, testSource); len(got) != 2 || got[1] != nil || got[3] == nil {
		t.Fatalf("kept = %+v", got)
	}
}
