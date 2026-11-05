package analytics

import (
	"crypto/sha1"
	"encoding/json"
	"fmt"
	"runtime"
	"sort"
	"time"
)

// Env is what every event says about the build that sends it.
type Env struct {
	AppVersion string
	OSVersion  string
	Arch       string
}

// CurrentEnv is this process's Env.
func CurrentEnv(appVersion string) Env {
	return Env{AppVersion: appVersion, OSVersion: osVersion(), Arch: runtime.GOARCH}
}

// The events a sealed day becomes (the spec's Events).
const (
	eventMinutesSaved        = "minutes_saved"
	eventLocalRuns           = "local_runs"
	eventConcurrencyInserted = "concurrency_inserted"
)

// usageEvents are the PostHog events of the usage categories.
var usageEvents = map[Category]string{
	Screen:  "screen_viewed",
	Overlay: "overlay_viewed",
	Action:  "action_used",
	Async:   "async_event",
}

// savingSources are the minute counters of each minutes_saved source. The
// sources do not overlap: local_run is the local runs less those without
// dispatch, so a sum over every source is the total.
var savingSources = []struct{ source, minutes, runs, less, lessRuns string }{
	{"local_run", LocalBilledMinutes, LocalRuns, LocalBilledMinutesWithoutDispatch, LocalRunsWithoutDispatch},
	{"local_run_without_dispatch", LocalBilledMinutesWithoutDispatch, LocalRunsWithoutDispatch, "", ""},
	{"superseded_cancel", SupersededCancelMinutesEst, SupersededCancels, "", ""},
	{"concurrency_cancel", ConcurrencyMinutesEst, ConcurrencyCancels, "", ""},
}

// localRunProperties are local_runs' properties and their counters.
var localRunProperties = []struct{ property, counter string }{
	{"jobs_succeeded", LocalJobsSucceeded},
	{"jobs_failed", LocalJobsFailed},
	{"jobs_cancelled", LocalJobsCancelled},
	{"job_seconds", LocalJobSeconds},
	{"workflow_runs", LocalRunsCompleted},
	{"workflow_wall_seconds", LocalRunWallSeconds},
	{"gh_ref_jobs_matched", GHRefJobsMatched},
	{"gh_ref_billed_minutes", GHRefBilledMinutes},
	{"local_billed_minutes_matched", LocalBilledMinutesMatched},
	{"gh_ref_runs_matched", GHRefRunsMatched},
	{"gh_ref_run_wall_seconds", GHRefRunWallSeconds},
}

type event struct {
	Event      string         `json:"event"`
	UUID       string         `json:"uuid"`
	DistinctID string         `json:"distinct_id"`
	Timestamp  string         `json:"timestamp"`
	Properties map[string]any `json:"properties"`
}

type requestBody struct {
	APIKey string  `json:"api_key"`
	Batch  []event `json:"batch"`
}

// Body is the /batch/ request for batches. It refuses any counter outside
// the allowlist for the batch's level, so nothing else can leave. PostHog
// answers 200 even to events it drops, so this check comes first.
func Body(token string, env Env, batches []Batch) ([]byte, error) {
	out := requestBody{APIKey: token, Batch: []event{}}
	for _, b := range batches {
		events, err := batchEvents(env, b)
		if err != nil {
			return nil, err
		}
		out.Batch = append(out.Batch, events...)
	}
	return json.Marshal(out)
}

// batchEvents are a batch's events, in a fixed order.
func batchEvents(env Env, b Batch) ([]event, error) {
	day, err := time.Parse(dayLayout, b.Day)
	if err != nil {
		return nil, err
	}
	distinct := b.ID
	if b.Level == Full && b.AnalyticsID != "" {
		distinct = b.AnalyticsID
	}
	var out []event
	// add appends an event of kind, the batch's part that names it.
	add := func(name, kind string, own map[string]any) {
		props := map[string]any{
			"batch_id": b.ID, "day": b.Day, "level": b.Level.String(),
			"app_version": env.AppVersion, "os_version": env.OSVersion, "arch": env.Arch,
			"$process_person_profile": false, "$geoip_disable": true, "$lib": "runnir-core",
		}
		for k, v := range own {
			props[k] = v
		}
		out = append(out, event{Event: name, UUID: nameUUID(b.ID + "/" + kind), DistinctID: distinct,
			Timestamp: day.UTC().Format(time.RFC3339), Properties: props})
	}
	switch b.Event {
	case eventFirstLaunch:
		add(eventFirstLaunch, eventFirstLaunch, nil)
		return out, nil
	case eventDay:
	default:
		return nil, fmt.Errorf("unknown analytics batch %q", b.Event)
	}

	used := map[string]bool{}
	take := func(counter string) int64 {
		if counter == "" {
			return 0
		}
		used[counter] = true
		return b.Counts[counter]
	}
	for _, s := range savingSources {
		minutes, runs := max(take(s.minutes)-take(s.less), 0), max(take(s.runs)-take(s.lessRuns), 0)
		if minutes != 0 || runs != 0 {
			add(eventMinutesSaved, eventMinutesSaved+"/"+s.source,
				map[string]any{"source": s.source, "minutes": minutes, "runs": runs})
		}
	}
	local, counted := map[string]any{}, false
	for _, p := range localRunProperties {
		value := take(p.counter)
		local[p.property], counted = value, counted || value != 0
	}
	if counted {
		add(eventLocalRuns, eventLocalRuns, local)
	}
	if count := take(ConcurrencyInserted); count != 0 {
		add(eventConcurrencyInserted, eventConcurrencyInserted, map[string]any{"count": count})
	}

	var counters []string
	for counter := range b.Counts {
		if !used[counter] {
			counters = append(counters, counter)
		}
	}
	sort.Strings(counters)
	for _, counter := range counters {
		u, ok := usageOf(counter)
		if !ok || b.Level != Full {
			return nil, fmt.Errorf("%w: %q", ErrNotAllowed, counter)
		}
		if count := b.Counts[counter]; count != 0 {
			add(usageEvents[u.Category], counter, map[string]any{"area": u.Area, "name": u.Name, "count": count})
		}
	}
	return out, nil
}

// analyticsNamespace makes the events' name-based UUIDs.
var analyticsNamespace = [16]byte{0x6c, 0x0e, 0x51, 0x2b, 0x8f, 0x3a, 0x4d, 0x17, 0x9a, 0x5c, 0x2e, 0x71, 0x0b, 0xd4, 0x63, 0x88}

// nameUUID is the version 5 UUID of name: the same batch and kind always
// give the same event uuid, so PostHog merges a resent event.
func nameUUID(name string) string {
	h := sha1.New()
	h.Write(analyticsNamespace[:])
	h.Write([]byte(name))
	b := h.Sum(nil)[:16]
	b[6] = b[6]&0x0f | 0x50
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
