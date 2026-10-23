//go:build !windows

package workspace

import (
	"context"
	"net/http"
	"sync"
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

const runsPath = "/repos/o/r/actions/runs"

func waitRefresh(t *testing.T, r *Runtime) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := r.Refresh(ctx, true); err != nil {
		t.Fatal(err)
	}
}

func TestTheFirstPassStoresActivityAndMakesItLive(t *testing.T) {
	_, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	snap, err := r.Snapshot(context.Background(), 50)
	if err != nil || snap.Provenance != Live || len(snap.Runs) != 1 || len(snap.Workflows) != 1 ||
		snap.Access != corev1.GithubAccess_GITHUB_ACCESS_OK || snap.SyncedAt.IsZero() {
		t.Fatalf("snapshot = %+v, %v", snap, err)
	}
}

func TestConcurrentRefreshesShareOnePass(t *testing.T) {
	fake, accounts := newFake(t)
	gate := make(chan struct{})
	fake.set(func(f *fakeGitHub) { f.gate = gate })
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	// The opening pass is held at the gate; five windows ask meanwhile.
	deadline := time.Now().Add(5 * time.Second)
	for fake.count(runsPath) == 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); waitRefresh(t, r) }()
	}
	time.Sleep(50 * time.Millisecond)
	close(gate)
	wg.Wait()
	if n := fake.count(runsPath); n != 2 {
		t.Fatalf("runs requests = %d, want the opening pass and one merged pass", n)
	}
}

func TestANotModifiedPassKeepsChangedAt(t *testing.T) {
	_, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	first, _ := r.Snapshot(context.Background(), 50)
	time.Sleep(5 * time.Millisecond)
	waitRefresh(t, r)
	second, _ := r.Snapshot(context.Background(), 50)
	if !second.ChangedAt.Equal(first.ChangedAt) || !second.SyncedAt.After(first.SyncedAt) || len(second.Runs) != 1 {
		t.Fatalf("first %+v second %+v", first, second)
	}
}

func TestLosingAccessKeepsTheCache(t *testing.T) {
	fake, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	fake.set(func(f *fakeGitHub) { f.status = http.StatusUnauthorized })
	waitRefresh(t, r)
	snap, _ := r.Snapshot(context.Background(), 50)
	if snap.Access != corev1.GithubAccess_GITHUB_ACCESS_TOKEN_REJECTED || len(snap.Runs) != 1 || snap.Provenance != Live {
		t.Fatalf("snapshot = %+v", snap)
	}
	account, _ := accounts.Get("")
	if _, ok := account.Credential.Token(); ok {
		t.Fatal("rejected token kept")
	}
}

func TestCachedActivityIsServedBeforeAnyPass(t *testing.T) {
	dir := t.TempDir()
	fake, accounts := newFake(t)
	first := startRuntime(t, dir, fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, first)
	first.Close()
	_ = first.Store().Close()

	gate := make(chan struct{})
	t.Cleanup(func() { close(gate) })
	fake.set(func(f *fakeGitHub) { f.gate = gate })
	second := startRuntime(t, dir, fixedResolver(accounts, "o", "r"), nil)
	snap, err := second.Snapshot(context.Background(), 50)
	if err != nil || snap.Provenance != Cached || len(snap.Runs) != 1 || !snap.Syncing && snap.CheckedAt.IsZero() {
		t.Fatalf("snapshot = %+v, %v", snap, err)
	}
}

func TestAnotherOriginNeverShowsTheOldRepository(t *testing.T) {
	fake, accounts := newFake(t)
	var mu sync.Mutex
	name := "r"
	resolve := func() (Target, corev1.GithubAccess) {
		mu.Lock()
		defer mu.Unlock()
		account, _ := accounts.Get("")
		return Target{Account: account, Owner: "o", Name: name}, corev1.GithubAccess_GITHUB_ACCESS_OK
	}
	r := startRuntime(t, t.TempDir(), resolve, nil)
	waitRefresh(t, r)
	mu.Lock()
	name = "other" // the fake answers 404 for it
	mu.Unlock()
	waitRefresh(t, r)
	snap, _ := r.Snapshot(context.Background(), 50)
	if snap.Provenance != NoData || len(snap.Runs) != 0 || snap.Access != corev1.GithubAccess_GITHUB_ACCESS_NOT_VISIBLE {
		t.Fatalf("snapshot = %+v", snap)
	}
	_ = fake
}

func TestNoRemoteMeansNoRequests(t *testing.T) {
	fake, _ := newFake(t)
	r := startRuntime(t, t.TempDir(), func() (Target, corev1.GithubAccess) {
		return Target{}, corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE
	}, nil)
	waitRefresh(t, r)
	snap, _ := r.Snapshot(context.Background(), 50)
	if snap.Access != corev1.GithubAccess_GITHUB_ACCESS_NO_REMOTE || fake.count(runsPath) != 0 {
		t.Fatalf("snapshot = %+v, requests %d", snap, fake.count(runsPath))
	}
}

func TestACredentialChangeStartsAPass(t *testing.T) {
	fake, accounts := newFake(t)
	accounts.Clear("") // signed out
	log := &eventLog{}
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), log)
	waitRefresh(t, r)
	if snap, _ := r.Snapshot(context.Background(), 50); snap.Access != corev1.GithubAccess_GITHUB_ACCESS_SIGNED_OUT {
		t.Fatalf("signed out = %+v", snap)
	}
	_, _ = accounts.Set(github.Server{}, "ghu_test")
	before := log.count.Load()
	r.credentialChanged("")
	deadline := time.Now().Add(5 * time.Second)
	for fake.count(runsPath) == 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if fake.count(runsPath) != 1 || log.count.Load() <= before {
		t.Fatalf("requests %d, events %d -> %d", fake.count(runsPath), before, log.count.Load())
	}
}

func TestEveryPassAnnouncesItselfForItsRepository(t *testing.T) {
	_, accounts := newFake(t)
	log := &eventLog{}
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), log)
	waitRefresh(t, r)
	log.mu.Lock()
	defer log.mu.Unlock()
	if len(log.events) < 2 {
		t.Fatalf("events = %v", log.events)
	}
	for _, e := range log.events {
		if e.Type != corev1.CoreEventType_CORE_EVENT_TYPE_ACTIVITY_CHANGED || e.RepositoryID != "repo_1" {
			t.Fatalf("event = %+v", e)
		}
	}
}

func TestClosingStopsTheLoop(t *testing.T) {
	_, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	r.Close()
	if err := r.Refresh(context.Background(), true); err != ErrClosed {
		t.Fatalf("refresh after close = %v", err)
	}
}

func TestClearCacheEmptiesAndSyncsAgain(t *testing.T) {
	fake, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	if err := r.ClearCache(context.Background()); err != nil {
		t.Fatal(err)
	}
	waitRefresh(t, r)
	snap, _ := r.Snapshot(context.Background(), 50)
	if len(snap.Runs) != 1 || fake.count(runsPath) < 2 {
		t.Fatalf("snapshot = %+v", snap)
	}
	_ = store.Source{}
}
