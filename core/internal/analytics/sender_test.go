//go:build !windows

package analytics

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"regexp"
	"sync"
	"testing"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

type fakePostHog struct {
	*httptest.Server
	mu     sync.Mutex
	paths  []string
	bodies []map[string]any
	status []int // answers in order, then 200
}

func newPostHog(t *testing.T, status ...int) *fakePostHog {
	t.Helper()
	f := &fakePostHog{status: status}
	f.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		f.paths = append(f.paths, r.URL.Path)
		f.bodies = append(f.bodies, body)
		code := http.StatusOK
		if len(f.status) > 0 {
			code, f.status = f.status[0], f.status[1:]
		}
		f.mu.Unlock()
		w.WriteHeader(code)
	}))
	t.Cleanup(f.Close)
	return f
}

func (f *fakePostHog) requests() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.bodies)
}

// events are the batch of request i.
func (f *fakePostHog) events(t *testing.T, i int) []map[string]any {
	t.Helper()
	f.mu.Lock()
	defer f.mu.Unlock()
	if i >= len(f.bodies) {
		t.Fatalf("request %d of %d", i, len(f.bodies))
	}
	var out []map[string]any
	for _, e := range f.bodies[i]["batch"].([]any) {
		out = append(out, e.(map[string]any))
	}
	return out
}

var testEnv = Env{AppVersion: "0.2.0-alpha.1", OSVersion: "26.1", Arch: "arm64"}

var uuidForm = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

func sender(l *Ledger, ph *fakePostHog) *Sender {
	return &Sender{Ledger: l, Host: ph.URL + "/", Token: "phc_test", Env: testEnv}
}

func props(e map[string]any) map[string]any { return e["properties"].(map[string]any) }

func TestFirstLaunchIsSentWithoutAnID(t *testing.T) {
	c := &clock{t: day(0)}
	l := openLedger(t, t.TempDir(), c, sequence())
	ph := newPostHog(t)
	must(t, sender(l, ph).Flush(context.Background()))
	ph.mu.Lock()
	key, path := ph.bodies[0]["api_key"], ph.paths[0]
	ph.mu.Unlock()
	if key != "phc_test" || path != "/batch/" {
		t.Fatalf("api_key = %v, path = %q", key, path)
	}
	events := ph.events(t, 0)
	if len(events) != 1 {
		t.Fatalf("events = %+v", events)
	}
	e, p := events[0], props(events[0])
	want := map[string]any{"batch_id": "id-1", "day": "2026-10-20", "level": "basic", "app_version": "0.2.0-alpha.1",
		"os_version": "26.1", "arch": "arm64", "$process_person_profile": false, "$geoip_disable": true, "$lib": "runnir-core"}
	if e["event"] != "first_launch" || e["distinct_id"] != "id-1" || e["timestamp"] != "2026-10-20T00:00:00Z" ||
		!uuidForm.MatchString(e["uuid"].(string)) || len(p) != len(want) {
		t.Fatalf("event = %+v", e)
	}
	for k, v := range want {
		if p[k] != v {
			t.Fatalf("%s = %v, want %v", k, p[k], v)
		}
	}
	if got := pending(t, l)["first_launch"]; got != 0 {
		t.Fatalf("first_launch still pending after a 200: %d", got)
	}
}

func TestAFailedSendIsRetriedWithTheSameBatchIDAndUUID(t *testing.T) {
	c := &clock{t: day(0)}
	l := openLedger(t, t.TempDir(), c, sequence())
	ph := newPostHog(t, http.StatusServiceUnavailable)
	s := sender(l, ph)
	if err := s.Flush(context.Background()); err == nil {
		t.Fatal("a 503 was not an error")
	}
	must(t, s.Flush(context.Background())) // not due yet: nothing sent
	if ph.requests() != 1 || pending(t, l)["first_launch"] != 1 {
		t.Fatalf("requests = %d, pending = %+v", ph.requests(), pending(t, l))
	}
	c.add(time.Minute)
	must(t, s.Flush(context.Background()))
	first, second := ph.events(t, 0)[0], ph.events(t, 1)[0]
	if props(first)["batch_id"] != "id-1" || props(second)["batch_id"] != "id-1" || first["uuid"] != second["uuid"] ||
		pending(t, l)["first_launch"] != 0 {
		t.Fatalf("retry = %+v then %+v", first, second)
	}
}

func TestADayBecomesEventsShapedForInsights(t *testing.T) {
	c := &clock{t: day(0)}
	l := openLedger(t, t.TempDir(), c, sequence())
	must(t, l.Remove([]string{"id-1"}))
	must(t, l.SetLevel(Full, true)) // analytics id id-2
	must(t, l.Add(day(0), Counts{LocalRuns: 2, LocalBilledMinutes: 9, LocalRunsWithoutDispatch: 1, LocalBilledMinutesWithoutDispatch: 4,
		LocalJobsSucceeded: 3, LocalJobSeconds: 412,
		SupersededCancels: 1, SupersededCancelMinutesEst: 6, ConcurrencyInserted: 1, screenRuns: 3, actionRunLocal: 2}))
	// A zero count makes no event.
	must(t, l.Add(day(0), Counts{UsageCounter(corev1.UsageEvent_USAGE_EVENT_OVERLAY_RUNS_DISPATCH): 0}))
	c.t = day(1)
	ph := newPostHog(t)
	must(t, sender(l, ph).Flush(context.Background()))
	type row struct {
		event  string
		own    map[string]any
		absent string
	}
	want := []row{
		{"minutes_saved", map[string]any{"source": "local_run", "minutes": 5.0, "runs": 1.0}, ""},
		{"minutes_saved", map[string]any{"source": "local_run_without_dispatch", "minutes": 4.0, "runs": 1.0}, ""},
		{"minutes_saved", map[string]any{"source": "superseded_cancel", "minutes": 6.0, "runs": 1.0}, ""},
		{"local_runs", map[string]any{"jobs_succeeded": 3.0, "job_seconds": 412.0, "jobs_failed": 0.0, "gh_ref_run_wall_seconds": 0.0}, "source"},
		{"concurrency_inserted", map[string]any{"count": 1.0}, ""},
		{"action_used", map[string]any{"area": "local_run", "name": "local_run.run", "count": 2.0}, ""},
		{"screen_viewed", map[string]any{"area": "runs", "name": "runs.list", "count": 3.0}, ""},
	}
	events := ph.events(t, 0)
	if len(events) != len(want) {
		t.Fatalf("events = %+v", events)
	}
	uuids := map[any]bool{}
	for i, w := range want {
		e, p := events[i], props(events[i])
		if e["event"] != w.event || e["distinct_id"] != "id-2" || p["level"] != "full" || p["batch_id"] != "id-3" || p[w.absent] != nil {
			t.Fatalf("event %d = %+v, want %s", i, e, w.event)
		}
		for k, v := range w.own {
			if p[k] != v {
				t.Fatalf("event %d (%s): %s = %v, want %v", i, w.event, k, p[k], v)
			}
		}
		uuids[e["uuid"]] = true
	}
	if len(uuids) != len(want) {
		t.Fatalf("events share a uuid: %v", uuids)
	}
}

func TestDaysCarryTheIDOnlyAtFull(t *testing.T) {
	c := &clock{t: day(0)}
	l := openLedger(t, t.TempDir(), c, sequence())
	must(t, l.Remove([]string{"id-1"}))
	must(t, l.Add(day(0), Counts{LocalBilledMinutes: 3}))
	must(t, l.SetLevel(Full, true)) // id-2 sealed without an id, id-3 the analytics id
	must(t, l.Add(day(0), Counts{LocalBilledMinutes: 2}))
	c.t = day(1)
	ph := newPostHog(t)
	must(t, sender(l, ph).Flush(context.Background()))
	events := ph.events(t, 0)
	if len(events) != 2 {
		t.Fatalf("events = %+v", events)
	}
	basic, full := events[0], events[1]
	if basic["distinct_id"] != "id-2" || props(basic)["level"] != "basic" || props(basic)["minutes"] != 3.0 {
		t.Fatalf("basic = %+v", basic)
	}
	if full["distinct_id"] != "id-3" || props(full)["level"] != "full" || props(full)["batch_id"] != "id-4" {
		t.Fatalf("full = %+v", full)
	}
}

func TestNothingIsSentWithoutATokenOrAFolder(t *testing.T) {
	c := &clock{t: day(0)}
	ph := newPostHog(t)
	onDisk := openLedger(t, t.TempDir(), c, sequence())
	noToken := &Sender{Ledger: onDisk, Host: ph.URL, Env: testEnv}
	inMemory := sender(openLedger(t, "", c, sequence()), ph)
	must(t, noToken.Flush(context.Background()))
	must(t, inMemory.Flush(context.Background()))
	if ph.requests() != 0 || noToken.Enabled() || inMemory.Enabled() {
		t.Fatalf("requests = %d", ph.requests())
	}
}

func TestARedirectIsNotFollowed(t *testing.T) {
	elsewhere := newPostHog(t)
	redirect := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, elsewhere.URL, http.StatusTemporaryRedirect)
	}))
	t.Cleanup(redirect.Close)
	c := &clock{t: day(0)}
	l := openLedger(t, t.TempDir(), c, sequence())
	s := &Sender{Ledger: l, Host: redirect.URL, Token: "phc_test", Env: testEnv}
	if err := s.Flush(context.Background()); err == nil {
		t.Fatal("a redirect counted as delivered")
	}
	if elsewhere.requests() != 0 || pending(t, l)["first_launch"] != 1 {
		t.Fatal("the redirect was followed or the batch dropped")
	}
}

func TestABodyHoldsOnlyAllowedCounters(t *testing.T) {
	for _, b := range []Batch{
		{ID: "b", Day: "2026-10-20", Event: eventDay, Level: Full, Counts: Counts{"repository": 1}},
		{ID: "b", Day: "2026-10-20", Event: eventDay, Level: Basic, Counts: Counts{screenRuns: 1}},
	} {
		if _, err := Body("phc_test", testEnv, []Batch{b}); !errors.Is(err, ErrNotAllowed) {
			t.Fatalf("%+v = %v", b.Counts, err)
		}
	}
}
