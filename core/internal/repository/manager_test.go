package repository

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type fakeScanner struct {
	calls atomic.Int32
	scan  func(ctx context.Context, root string) (Snapshot, error)
}

func (f *fakeScanner) Scan(ctx context.Context, root string) (Snapshot, error) {
	f.calls.Add(1)
	if f.scan != nil {
		return f.scan(ctx, root)
	}
	return Snapshot{Branch: "main"}, nil
}

func newManager(scanner Scanner) (*Manager, *eventLog) {
	log := &eventLog{}
	return New(scanner, log.record), log
}

type eventLog struct {
	mu     sync.Mutex
	events []Event
}

func (l *eventLog) record(e Event) { l.mu.Lock(); l.events = append(l.events, e); l.mu.Unlock() }
func (l *eventLog) types() []EventType {
	l.mu.Lock()
	defer l.mu.Unlock()
	out := make([]EventType, len(l.events))
	for i, e := range l.events {
		out[i] = e.Type
	}
	return out
}

func dir(t *testing.T) string {
	t.Helper()
	path, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return path
}

func TestOpenIsIdempotentUnderConcurrency(t *testing.T) {
	scanner := &fakeScanner{}
	m, log := newManager(scanner)
	path := dir(t)

	const workers = 50
	ids := make([]string, workers)
	var wg sync.WaitGroup
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			info, err := m.Open(context.Background(), path)
			if err != nil {
				t.Error(err)
				return
			}
			ids[i] = info.ID
		}()
	}
	wg.Wait()

	for _, id := range ids {
		if id == "" || id != ids[0] {
			t.Fatalf("ids differ: %v", ids)
		}
	}
	if m.Count() != 1 {
		t.Fatalf("count = %d, want 1", m.Count())
	}
	if scanner.calls.Load() != 1 {
		t.Fatalf("initial scan ran %d times, want 1", scanner.calls.Load())
	}
	if got := log.types(); len(got) != 1 || got[0] != RepositoryOpened {
		t.Fatalf("events = %v, want one opened", got)
	}
}

func TestSymlinkSpellingResolvesToSameRepository(t *testing.T) {
	m, _ := newManager(&fakeScanner{})
	real := dir(t)
	link := filepath.Join(dir(t), "link")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	a, err := m.Open(context.Background(), real)
	if err != nil {
		t.Fatal(err)
	}
	b, err := m.Open(context.Background(), link)
	if err != nil {
		t.Fatal(err)
	}
	if a.ID != b.ID || m.Count() != 1 {
		t.Fatalf("symlink opened a second context: %q vs %q, count %d", a.ID, b.ID, m.Count())
	}
}

func TestManyRepositoriesAreIndependent(t *testing.T) {
	m, _ := newManager(&fakeScanner{})
	seen := map[string]bool{}
	for i := 0; i < 10; i++ {
		info, err := m.Open(context.Background(), dir(t))
		if err != nil {
			t.Fatal(err)
		}
		if seen[info.ID] {
			t.Fatalf("duplicate id %s", info.ID)
		}
		seen[info.ID] = true
	}
	if m.Count() != 10 {
		t.Fatalf("count = %d", m.Count())
	}
}

func TestOpenRejectsBadPaths(t *testing.T) {
	m, _ := newManager(&fakeScanner{})
	file := filepath.Join(dir(t), "f")
	if err := os.WriteFile(file, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{"", "relative/path", filepath.Join(dir(t), "missing"), file} {
		if _, err := m.Open(context.Background(), path); !errors.Is(err, ErrInvalidPath) {
			t.Errorf("Open(%q) = %v, want ErrInvalidPath", path, err)
		}
	}
	if m.Count() != 0 {
		t.Fatal("failed opens must not register contexts")
	}
}

func TestFailedInitialScanIsNotRegisteredAndCanRetry(t *testing.T) {
	boom := errors.New("scan failed")
	var fail atomic.Bool
	fail.Store(true)
	scanner := &fakeScanner{scan: func(context.Context, string) (Snapshot, error) {
		if fail.Load() {
			return Snapshot{}, boom
		}
		return Snapshot{Branch: "main"}, nil
	}}
	m, log := newManager(scanner)
	path := dir(t)

	if _, err := m.Open(context.Background(), path); !errors.Is(err, boom) {
		t.Fatalf("err = %v, want scan error", err)
	}
	if m.Count() != 0 {
		t.Fatal("failed open left a context behind")
	}
	fail.Store(false)
	if _, err := m.Open(context.Background(), path); err != nil {
		t.Fatalf("retry failed: %v", err)
	}
	if got := log.types(); len(got) != 1 || got[0] != RepositoryOpened {
		t.Fatalf("events = %v", got)
	}
}

func TestRefreshOfOneRepositoryDoesNotBlockAnother(t *testing.T) {
	slowRoot := dir(t)
	release := make(chan struct{})
	entered := make(chan struct{})
	var armed atomic.Bool
	scanner := &fakeScanner{scan: func(_ context.Context, root string) (Snapshot, error) {
		if armed.Load() && root == slowRoot {
			close(entered)
			<-release
		}
		return Snapshot{Branch: "main"}, nil
	}}
	m, _ := newManager(scanner)
	slow, err := m.Open(context.Background(), slowRoot)
	if err != nil {
		t.Fatal(err)
	}
	fast, err := m.Open(context.Background(), dir(t))
	if err != nil {
		t.Fatal(err)
	}
	armed.Store(true)

	done := make(chan error, 1)
	go func() { _, err := m.Refresh(context.Background(), slow.ID); done <- err }()
	<-entered

	if _, err := m.Refresh(context.Background(), fast.ID); err != nil {
		t.Fatalf("fast refresh: %v", err)
	}
	if _, err := m.Open(context.Background(), dir(t)); err != nil {
		t.Fatalf("open of a third repository: %v", err)
	}
	if _, err := m.Get(slow.ID); err != nil {
		t.Fatalf("reads must not block on a running refresh: %v", err)
	}
	select {
	case <-done:
		t.Fatal("slow refresh finished before release")
	default:
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestCloseCancelsRunningRefresh(t *testing.T) {
	started := make(chan struct{})
	var armed atomic.Bool
	scanner := &fakeScanner{scan: func(ctx context.Context, _ string) (Snapshot, error) {
		if !armed.Load() {
			return Snapshot{}, nil
		}
		close(started)
		<-ctx.Done()
		return Snapshot{}, ctx.Err()
	}}
	m, log := newManager(scanner)
	info, err := m.Open(context.Background(), dir(t))
	if err != nil {
		t.Fatal(err)
	}
	armed.Store(true)

	done := make(chan error, 1)
	go func() { _, err := m.Refresh(context.Background(), info.ID); done <- err }()
	<-started
	if err := m.Close(info.ID); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if !errors.Is(err, ErrNotFound) {
			t.Fatalf("refresh after close = %v, want ErrNotFound", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("refresh was not cancelled by Close")
	}
	got := log.types()
	if got[len(got)-1] != RepositoryClosed {
		t.Fatalf("events = %v, want closed last and no refreshed after close", got)
	}
	for _, e := range got {
		if e == RepositoryRefreshed {
			t.Fatalf("cancelled refresh must not publish: %v", got)
		}
	}
}

func TestRefreshUpdatesSnapshotAndConcurrentRefreshesSerialize(t *testing.T) {
	var running, peak atomic.Int32
	var branch atomic.Value
	branch.Store("main")
	scanner := &fakeScanner{scan: func(context.Context, string) (Snapshot, error) {
		n := running.Add(1)
		for {
			p := peak.Load()
			if n <= p || peak.CompareAndSwap(p, n) {
				break
			}
		}
		time.Sleep(2 * time.Millisecond)
		running.Add(-1)
		return Snapshot{Branch: branch.Load().(string), Workflows: []Workflow{{ID: ".github/workflows/ci.yml"}}}, nil
	}}
	m, _ := newManager(scanner)
	info, err := m.Open(context.Background(), dir(t))
	if err != nil {
		t.Fatal(err)
	}
	branch.Store("feature")
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := m.Refresh(context.Background(), info.ID); err != nil {
				t.Error(err)
			}
		}()
	}
	wg.Wait()
	if peak.Load() != 1 {
		t.Fatalf("refreshes of one repository overlapped (peak %d)", peak.Load())
	}
	got, _ := m.Get(info.ID)
	if got.Branch != "feature" || got.WorkflowCount != 1 || got.LastRefresh.IsZero() {
		t.Fatalf("snapshot not updated: %+v", got)
	}
	workflows, err := m.Workflows(info.ID)
	if err != nil || len(workflows) != 1 {
		t.Fatalf("workflows = %v, %v", workflows, err)
	}
}

func TestRefreshWaitHonorsCallerContext(t *testing.T) {
	block := make(chan struct{})
	var armed atomic.Bool
	scanner := &fakeScanner{scan: func(ctx context.Context, _ string) (Snapshot, error) {
		if armed.Load() {
			<-block
		}
		return Snapshot{}, nil
	}}
	m, _ := newManager(scanner)
	info, _ := m.Open(context.Background(), dir(t))
	armed.Store(true)
	go m.Refresh(context.Background(), info.ID)
	time.Sleep(20 * time.Millisecond)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	if _, err := m.Refresh(ctx, info.ID); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want deadline exceeded", err)
	}
	close(block)
}

func TestUnknownIDsAndReopenAfterClose(t *testing.T) {
	m, _ := newManager(&fakeScanner{})
	if err := m.Close("repo_nope"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Close unknown = %v", err)
	}
	if _, err := m.Refresh(context.Background(), "repo_nope"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Refresh unknown = %v", err)
	}
	if _, err := m.Workflows("repo_nope"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("Workflows unknown = %v", err)
	}
	path := dir(t)
	first, _ := m.Open(context.Background(), path)
	if err := m.Close(first.ID); err != nil {
		t.Fatal(err)
	}
	second, err := m.Open(context.Background(), path)
	if err != nil || second.ID != first.ID {
		t.Fatalf("reopen = %+v, %v; id must be stable", second, err)
	}
}

func TestConcurrentOpenCloseRefreshMix(t *testing.T) {
	m, _ := newManager(&fakeScanner{})
	paths := []string{dir(t), dir(t), dir(t)}
	var wg sync.WaitGroup
	for i := 0; i < 60; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			path := paths[i%len(paths)]
			info, err := m.Open(context.Background(), path)
			if errors.Is(err, ErrNotFound) {
				return // another goroutine closed it while it was opening
			}
			if err != nil {
				t.Error(err)
				return
			}
			switch i % 3 {
			case 0:
				_, _ = m.Refresh(context.Background(), info.ID)
			case 1:
				_ = m.Close(info.ID)
			default:
				_, _ = m.Get(info.ID)
			}
		}()
	}
	wg.Wait()
	if m.Count() > len(paths) {
		t.Fatalf("count %d exceeds distinct paths", m.Count())
	}
}

func TestShutdownClosesEverything(t *testing.T) {
	m, log := newManager(&fakeScanner{})
	for i := 0; i < 3; i++ {
		if _, err := m.Open(context.Background(), dir(t)); err != nil {
			t.Fatal(err)
		}
	}
	m.Shutdown()
	if m.Count() != 0 {
		t.Fatalf("count = %d after shutdown", m.Count())
	}
	closed := 0
	for _, e := range log.types() {
		if e == RepositoryClosed {
			closed++
		}
	}
	if closed != 3 {
		t.Fatalf("closed events = %d, want 3", closed)
	}
}

func TestConcurrentOpensShareAFailedInitialScan(t *testing.T) {
	boom := errors.New("scan failed")
	gate := make(chan struct{})
	scanner := &fakeScanner{scan: func(context.Context, string) (Snapshot, error) {
		<-gate
		return Snapshot{}, boom
	}}
	m, _ := newManager(scanner)
	path := dir(t)

	errs := make(chan error, 8)
	for i := 0; i < 8; i++ {
		go func() { _, err := m.Open(context.Background(), path); errs <- err }()
	}
	time.Sleep(30 * time.Millisecond)
	close(gate)
	for i := 0; i < 8; i++ {
		if err := <-errs; !errors.Is(err, boom) {
			t.Fatalf("open %d: %v, want scan error", i, err)
		}
	}
	if m.Count() != 0 {
		t.Fatal("failed open left a context behind")
	}
}

func TestCloseDuringInitialOpenReportsNotFound(t *testing.T) {
	scanning := make(chan struct{})
	scanner := &fakeScanner{scan: func(ctx context.Context, _ string) (Snapshot, error) {
		close(scanning)
		<-ctx.Done()
		return Snapshot{}, ctx.Err()
	}}
	m, _ := newManager(scanner)
	path := dir(t)
	result := make(chan error, 1)
	go func() { _, err := m.Open(context.Background(), path); result <- err }()
	<-scanning
	if err := m.Close(idFor(path)); err != nil {
		t.Fatal(err)
	}
	if err := <-result; !errors.Is(err, ErrNotFound) {
		t.Fatalf("open = %v, want ErrNotFound", err)
	}
}
