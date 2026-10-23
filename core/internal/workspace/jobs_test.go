package workspace

import (
	"context"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

const jobsPath = "/repos/o/r/actions/runs/7/jobs"

func TestJobsOfAFinishedRunAreReadOnce(t *testing.T) {
	fake, accounts := newFake(t)
	// Only the finished-run rule applies.
	r := startRuntimeWith(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil, func(c *config) { c.intervals.JobsReuse = 0 })
	waitRefresh(t, r)
	for i := 0; i < 3; i++ {
		jobs, access, _, err := r.Jobs(context.Background(), 7)
		if err != nil || access != corev1.GithubAccess_GITHUB_ACCESS_OK || len(jobs) != 1 || len(jobs[0].Steps) != 1 {
			t.Fatalf("jobs = %v %v %v", jobs, access, err)
		}
	}
	if n := fake.count(jobsPath); n != 1 {
		t.Fatalf("jobs requests = %d", n)
	}
}

func TestConcurrentJobReadsShareOneRequest(t *testing.T) {
	fake, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	waitRefresh(t, r)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if jobs, _, _, err := r.Jobs(context.Background(), 7); err != nil || len(jobs) != 1 {
				t.Errorf("jobs = %v %v", jobs, err)
			}
		}()
	}
	wg.Wait()
	if n := fake.count(jobsPath); n != 1 {
		t.Fatalf("jobs requests = %d", n)
	}
}

func TestKeptLogsFollowTheSetting(t *testing.T) {
	_, accounts := newFake(t)
	var keep atomic.Bool
	r := startRuntimeWith(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil, func(c *config) { c.keepLogs = keep.Load })
	ctx := context.Background()
	r.KeepLog(ctx, 11, []byte("log"), store.LogMeta{})
	if _, _, ok := r.KeptLog(ctx, 11); ok {
		t.Fatal("kept with the setting off")
	}
	keep.Store(true)
	r.KeepLog(ctx, 11, []byte("log"), store.LogMeta{})
	if data, _, ok := r.KeptLog(ctx, 11); !ok || string(data) != "log" {
		t.Fatalf("kept = %q %v", data, ok)
	}
	keep.Store(false)
	if _, _, ok := r.KeptLog(ctx, 11); ok {
		t.Fatal("served with the setting off")
	}
}

func TestLogDownloadsAreShared(t *testing.T) {
	_, accounts := newFake(t)
	r := startRuntime(t, t.TempDir(), fixedResolver(accounts, "o", "r"), nil)
	var mu sync.Mutex
	calls := 0
	release := make(chan struct{})
	fetch := func(context.Context) (github.JobLog, error) {
		mu.Lock()
		calls++
		mu.Unlock()
		<-release
		return github.JobLog{Data: []byte("x")}, nil
	}
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if log, err := r.SharedLog(context.Background(), 11, time.Minute, fetch); err != nil || string(log.Data) != "x" {
				t.Errorf("log = %v %v", log, err)
			}
		}()
	}
	time.Sleep(50 * time.Millisecond)
	close(release)
	wg.Wait()
	if calls != 1 {
		t.Fatalf("downloads = %d", calls)
	}
}
