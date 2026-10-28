# Anonymous Analytics Implementation Plan (B21)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Count first launches, saved minutes and (with consent) section and action use in a ledger in the Go Core, and send every count to PostHog exactly once, as the [spec](../specs/2026-10-25-anonymous-analytics-design.md) describes.

**Architecture:** A new package `core/internal/analytics` keeps `analytics.sqlite` in the Core's data folder: the level (Off, Basic, Full), counters per UTC day, and an outbox of sealed batches, each with a random `batch_id`. A `Sender` goroutine in the server seals completed days and posts due batches to PostHog's `/batch/` endpoint, retrying with the same `batch_id`. The workspace runtime adds minute counters when a local run ends (next to B31's `AddSaving`) and when GitHub cancels runs the concurrency block cancelled; the server adds them on cancels and saves. The app reads and changes the level over three new RPCs, shows a consent banner once and Settings › Privacy, and records section and action counts through `CoreHub.recordUsage`, which does nothing below Full.

**Tech Stack:** Go 1.27 (pure Go, `CGO_ENABLED=0`, modernc.org/sqlite, net/http), protobuf/gRPC (buf), Swift 6, SwiftUI, Observation, Swift Testing.

## Global Constraints

- Working copy: a new branch from `main`; paths below are relative to the repository root. The plan was written against `main` at `a8cd36b` (2026-10-25), so check each file a task names before changing it: the app and the contract have changed since.
- No new dependencies in Go or Swift. No telemetry SDK. UUIDs come from `crypto/rand`.
- Contract changes in place: no versions, aliases or migrations (AGENTS.md, before the first release tag). The workspace schema change edits `schemaV1` in place, as B31 did.
- Destination: `https://us.i.posthog.com/batch/`. The PostHog key is set only in Release builds (`-ldflags`); without it nothing is sent.
- Every event: `$process_person_profile: false`, `$geoip_disable: true`, `$lib: "runnir-core"`, timestamp at midnight UTC of its day.
- Never sent: repository, owner, workflow, job, branch, tag or preset names, paths, SHAs, run/job/pull request numbers, hashes of these, error messages, logs, user text.
- UI text in English. No AI attribution anywhere (commits, code, docs).
- Commit after each task. Go checks run from `core/`: `go test ./...`, `go vet ./...`, `go build ./...`. App checks: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build` and `... test -only-testing:RunnirTests`.

## Changes To The Spec Made While Planning

Task 10 writes these into the spec:

- The consent prompt is a banner at the top of the first workspace window (above the content, like the Core banner), not a sheet: a sheet blocks the window.
- Section counters count clicks on the sidebar, the Workspace tabs and the Manager tabs; jumps made by other buttons are not counted. The Manager opening is not counted.
- `action_run_scenario_local` is left out until scenarios (B31's Scenarios spec) ship.
- A damaged ledger, or one with another schema, is replaced at level Off with the prompt unanswered, so a user who chose Off never sends because of a damaged file.
- The ledger takes its own file lock (`analytics.lock`); a second copy of Runnir keeps an in-memory ledger that never sends, and Settings says so.
- `app_build` comes from `CURRENT_PROJECT_VERSION` through `-ldflags`; `app_version`, `app_build`, `os_version` and `arch` are those of the build that sends.
- The payload check is the allowlist itself: `Ledger.Add` refuses any other name and `Body` refuses to build an event with one, so no repository data can reach a request; tests cover both instead of a scan for synthetic names.
- A failed send is logged to the Core's stderr (the log the app shows) as one line without the body.

---

### Task 1: Contract And Build Settings

**Files:**
- Modify: `contracts/grpc/runnir/core/v1/runnir_core.proto`
- Regenerate: `core/internal/gen/runnir/core/v1/*.go`, `apps/macos/Runnir/IPC/Generated/runnir/core/v1/*.swift`
- Modify: `core/internal/buildinfo/version.go` (the file holding `var Version`)
- Modify: `scripts/build-core-macos.sh`, `.github/workflows/release.yml`

**Interfaces:**
- Produces (Go): `corev1.AnalyticsLevel` (`ANALYTICS_LEVEL_OFF=1`, `_BASIC=2`, `_FULL=3`), `corev1.UsageEvent` (values below), messages `Analytics`, `AnalyticsCounter`, `GetAnalyticsRequest`, `SetAnalyticsLevelRequest`, `RecordUsageRequest`, `RecordUsageResponse`; server methods `GetAnalytics`, `SetAnalyticsLevel`, `RecordUsage`.
- Produces (Swift): `Runnir_Core_V1_Analytics`, `Runnir_Core_V1_AnalyticsLevel` (`.off/.basic/.full`), `Runnir_Core_V1_UsageEvent` (`.screenOverview` … `.actionReportBug`), client methods `getAnalytics`, `setAnalyticsLevel`, `recordUsage`.
- Produces: `buildinfo.Build`, `buildinfo.AnalyticsKey`.

- [ ] **Step 1: Add the RPCs** to `service RunnirCore`, after `SetStoragePreferences`:

```proto
  // The analytics level, whether the consent prompt was answered and the
  // counts waiting to be sent (docs/product/analytics-and-crash-reporting.md).
  rpc GetAnalytics(GetAnalyticsRequest) returns (Analytics);
  // Changes the level: a new analytics id for FULL; the id and section and
  // action counts dropped when leaving FULL; everything unsent dropped for OFF.
  rpc SetAnalyticsLevel(SetAnalyticsLevelRequest) returns (Analytics);
  // One more of a section or action; counted only at FULL.
  rpc RecordUsage(RecordUsageRequest) returns (RecordUsageResponse);
```

- [ ] **Step 2: Add the messages and enums** at the end of the file:

```proto
enum AnalyticsLevel {
  ANALYTICS_LEVEL_UNSPECIFIED = 0;
  // Nothing is counted or sent.
  ANALYTICS_LEVEL_OFF = 1;
  // first_launch and saved-minute counts, without an id. The default.
  ANALYTICS_LEVEL_BASIC = 2;
  // BASIC plus section and action counts, with a random analytics id.
  ANALYTICS_LEVEL_FULL = 3;
}

message AnalyticsCounter {
  string name = 1;
  uint64 value = 2;
}

message Analytics {
  AnalyticsLevel level = 1;
  bool prompt_answered = 2;
  // A Release build with the ledger on disk: batches are sent.
  bool sending_available = 3;
  // Set only at FULL.
  string analytics_id = 4;
  // Counts not sent yet, sealed or not, summed by name; an unsent
  // first_launch is "first_launch": 1. Sorted by name.
  repeated AnalyticsCounter pending = 5;
  // The ledger is kept on disk. False without a data folder or when another
  // copy of Runnir holds it; the app then offers no prompt and no level.
  bool persistent = 6;
}

message GetAnalyticsRequest {}

message SetAnalyticsLevelRequest {
  AnalyticsLevel level = 1;
  // The consent prompt's answer: it is not offered again.
  bool from_prompt = 2;
}

// Sections and actions counted at FULL. The counter is the lowercase name
// without the prefix, for example "screen_overview".
enum UsageEvent {
  USAGE_EVENT_UNSPECIFIED = 0;
  USAGE_EVENT_SCREEN_OVERVIEW = 1;
  USAGE_EVENT_SCREEN_WORKFLOWS = 2;
  USAGE_EVENT_SCREEN_RUNS = 3;
  USAGE_EVENT_SCREEN_WORKSPACE = 4;
  USAGE_EVENT_SCREEN_WORKSPACE_EDITOR = 5;
  USAGE_EVENT_SCREEN_WORKSPACE_LOCAL_RUN = 6;
  USAGE_EVENT_SCREEN_MANAGER_WORKSPACES = 7;
  USAGE_EVENT_SCREEN_MANAGER_GITHUB = 8;
  USAGE_EVENT_SCREEN_SETTINGS_ACCOUNT = 9;
  USAGE_EVENT_SCREEN_SETTINGS_RUNS = 10;
  USAGE_EVENT_SCREEN_SETTINGS_NOTIFICATIONS = 11;
  USAGE_EVENT_SCREEN_SETTINGS_PULL_REQUESTS = 12;
  USAGE_EVENT_SCREEN_SETTINGS_TOOLS = 13;
  USAGE_EVENT_SCREEN_SETTINGS_STORAGE = 14;
  USAGE_EVENT_SCREEN_SETTINGS_PRIVACY = 15;
  USAGE_EVENT_SCREEN_MENU_BAR = 16;
  USAGE_EVENT_ACTION_RUN_LOCAL = 17;
  USAGE_EVENT_ACTION_DISPATCH = 18;
  USAGE_EVENT_ACTION_CANCEL_RUN = 19;
  USAGE_EVENT_ACTION_RERUN = 20;
  USAGE_EVENT_ACTION_SAVE_WORKFLOW = 21;
  USAGE_EVENT_ACTION_CREATE_WORKFLOW = 22;
  USAGE_EVENT_ACTION_RENAME_WORKFLOW = 23;
  USAGE_EVENT_ACTION_VALIDATE = 24;
  USAGE_EVENT_ACTION_OPEN_LOG = 25;
  USAGE_EVENT_ACTION_SAVE_LOG = 26;
  USAGE_EVENT_ACTION_SAVE_PRESET = 27;
  USAGE_EVENT_ACTION_APPLY_PRESET = 28;
  USAGE_EVENT_ACTION_INSERT_CONCURRENCY = 29;
  USAGE_EVENT_ACTION_FAVORITE = 30;
  USAGE_EVENT_ACTION_OPEN_ON_GITHUB = 31;
  USAGE_EVENT_ACTION_REPORT_BUG = 32;
}

message RecordUsageRequest {
  UsageEvent event = 1;
}

message RecordUsageResponse {}
```

- [ ] **Step 3: Regenerate.** The Go plugins are in `~/go/bin`. If `protoc-gen-swift` and `protoc-gen-grpc-swift-2` are not on `PATH`, build them as the header of `scripts/generate-contracts.sh` says (apple/swift-protobuf 1.39.0, grpc/grpc-swift-protobuf 2.5.0, `swift build -c release --product <name>`) into a scratch `bin` folder and put it first on `PATH`.

Run: `PATH="$SCRATCH_BIN:$HOME/go/bin:$PATH" scripts/generate-contracts.sh`
Expected: `buf lint` prints nothing; `git status` shows the proto and the generated Go and Swift files changed.

- [ ] **Step 4: Add the build values** to `core/internal/buildinfo/version.go`, after `var Version`:

```go
// Build is the app's CFBundleVersion, set with -ldflags by the app build;
// empty for other builds.
var Build = ""

// AnalyticsKey is the PostHog project key, set with -ldflags only in
// Release builds of the app. Empty sends no analytics.
var AnalyticsKey = ""
```

- [ ] **Step 5: Pass them in `scripts/build-core-macos.sh`.** Before the first `for arch in $ARCHS` loop add:

```sh
# Analytics are sent only by Release builds that were given the key
# (RUNNIR_POSTHOG_KEY, a repository variable in the release workflow).
analytics_key=""
if [ "${CONFIGURATION:-}" = Release ]; then
    analytics_key="${RUNNIR_POSTHOG_KEY:-}"
fi
```

and replace the Core `go build` line with:

```sh
    go build -trimpath -ldflags "-X runnir/core/internal/buildinfo.Version=${MARKETING_VERSION} -X runnir/core/internal/buildinfo.Build=${CURRENT_PROJECT_VERSION:-} -X runnir/core/internal/buildinfo.AnalyticsKey=${analytics_key}" \
        -o "${DERIVED_FILE_DIR}/core/runnir-${arch}" ./cmd/runnir
```

- [ ] **Step 6: Give the release archive the key.** In `.github/workflows/release.yml`, add to the `Build archive` step (the one running `xcodebuild archive`):

```yaml
        env:
          RUNNIR_POSTHOG_KEY: ${{ vars.RUNNIR_POSTHOG_KEY }}
```

The standalone Core binaries built in `Build Core binaries` get no key and never send.

- [ ] **Step 7: Check and commit.**

Run (from `core/`): `go build ./... && go vet ./...` — Expected: no output.
Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build` — Expected: `** BUILD SUCCEEDED **`.

```bash
git add contracts core/internal/gen apps/macos/Runnir/IPC/Generated core/internal/buildinfo scripts/build-core-macos.sh .github/workflows/release.yml
git commit -m "Contract: analytics level, pending counts and usage events (B21)"
```

---

### Task 2: The Analytics Ledger

**Files:**
- Create: `core/internal/analytics/names.go`, `core/internal/analytics/ledger.go`, `core/internal/analytics/lock_unix.go`, `core/internal/analytics/lock_windows.go`
- Test: `core/internal/analytics/ledger_test.go`, `core/internal/analytics/names_test.go`

**Interfaces:**
- Consumes: `corev1.UsageEvent`, `corev1.UsageEvent_name`, `corev1.UsageEvent_value` (Task 1).
- Produces:
  - `type Level int` with `Off`, `Basic`, `Full`; `func (Level) String() string` ("off", "basic", "full").
  - `type Counts map[string]int64`; counter name constants (`LocalRuns`, `LocalBilledMinutes`, … `ConcurrencyMinutesEst`); `func IsMinuteCounter(string) bool`, `func IsUsageCounter(string) bool`, `func UsageCounter(corev1.UsageEvent) string`.
  - `var ErrNotAllowed`.
  - `type Options struct{ Now func() time.Time; NewID func() string }`.
  - `func Open(dir string, options Options) (*Ledger, error)`.
  - `(*Ledger).Add(at time.Time, counts Counts) error`, `Seal() error`, `SetLevel(level Level, fromPrompt bool) error`, `State() (State, error)`, `Due(limit int) ([]Batch, error)`, `Remove(ids []string) error`, `Failed(ids []string) error`, `NextAttempt() (time.Time, bool, error)`, `Persistent() bool`, `Close() error`.
  - `type State struct{ Level Level; PromptAnswered bool; ID string; Persistent bool; Pending Counts }`.
  - `type Batch struct{ ID, Day, Event string; Level Level; AnalyticsID string; Counts Counts }`; events `"first_launch"`, `"usage_day"`.
  - `func RetryDelay(attempts int) time.Duration`.

- [ ] **Step 1: Write the failing tests** in `core/internal/analytics/names_test.go`:

```go
package analytics

import (
	"strings"
	"testing"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func TestEveryUsageEventIsAScreenOrActionCounter(t *testing.T) {
	for value, name := range corev1.UsageEvent_name {
		counter := UsageCounter(corev1.UsageEvent(value))
		if value == 0 {
			if counter != "" {
				t.Fatalf("UNSPECIFIED → %q", counter)
			}
			continue
		}
		// SetLevel strips usage counters by these prefixes.
		prefixed := strings.HasPrefix(counter, "screen_") || strings.HasPrefix(counter, "action_")
		if !prefixed || !IsUsageCounter(counter) || IsMinuteCounter(counter) {
			t.Fatalf("%s → %q", name, counter)
		}
	}
	for _, name := range []string{"", "unspecified", "SCREEN_RUNS", "screen_nowhere", "local_runs"} {
		if IsUsageCounter(name) {
			t.Fatalf("%q is a usage counter", name)
		}
	}
	if !IsMinuteCounter(LocalBilledMinutes) || IsMinuteCounter("first_launch") {
		t.Fatal("minute counters are wrong")
	}
}
```

and `core/internal/analytics/ledger_test.go`:

```go
//go:build !windows

package analytics

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
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

func pending(t *testing.T, l *Ledger) Counts {
	t.Helper()
	s, err := l.State()
	must(t, err)
	return s.Pending
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
	s, err := l.State()
	if err != nil || s.Level != Basic || s.PromptAnswered || !s.Persistent || s.Pending["first_launch"] != 1 {
		t.Fatalf("fresh = %+v, %v", s, err)
	}
	batches := due(t, l)
	if len(batches) != 1 || batches[0].Event != "first_launch" || batches[0].ID != "id-1" || batches[0].Day != "2026-10-20" {
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
	if len(batches) != 1 || batches[0].Day != "2026-10-20" || batches[0].Event != "usage_day" ||
		batches[0].Counts[LocalBilledMinutes] != 7 || batches[0].Counts[LocalRuns] != 1 {
		t.Fatalf("sealed on day 1 = %+v", batches)
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
	must(t, l.Add(day(0), Counts{"screen_runs": 1, LocalRuns: 1}))
	if p := pending(t, l); p["screen_runs"] != 0 || p[LocalRuns] != 1 {
		t.Fatalf("basic counted %+v", p)
	}
	if err := l.Add(day(0), Counts{"repository_name": 1, LocalRuns: 1}); !errors.Is(err, ErrNotAllowed) {
		t.Fatalf("unknown name = %v", err)
	}
	if err := l.Add(day(0), Counts{LocalRuns: -1}); !errors.Is(err, ErrNotAllowed) {
		t.Fatalf("negative value = %v", err)
	}
	if p := pending(t, l); p[LocalRuns] != 1 {
		t.Fatalf("a refused call counted: %+v", p)
	}
	must(t, l.SetLevel(Full, true))
	must(t, l.Add(day(0), Counts{"screen_runs": 2}))
	if p := pending(t, l); p["screen_runs"] != 2 {
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
	s, err := l.State()
	if err != nil || s.Level != Off || s.PromptAnswered || len(s.Pending) != 0 || len(due(t, l)) != 0 {
		t.Fatalf("off = %+v, %v", s, err)
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
	s, err := l.State()
	if err != nil || s.Level != Full || !s.PromptAnswered || s.ID != "id-3" {
		t.Fatalf("full = %+v, %v", s, err)
	}
	batches := due(t, l)
	if len(batches) != 1 || batches[0].Level != Basic || batches[0].AnalyticsID != "" || batches[0].Counts[LocalBilledMinutes] != 3 {
		t.Fatalf("sealed at consent = %+v", batches)
	}
	must(t, l.Add(day(0), Counts{LocalBilledMinutes: 2, "action_run_local": 1}))
	c.t = day(1)
	must(t, l.Seal()) // id-4
	batches = due(t, l)
	if len(batches) != 2 || batches[1].ID != "id-4" || batches[1].Level != Full || batches[1].AnalyticsID != "id-3" ||
		batches[1].Counts["action_run_local"] != 1 {
		t.Fatalf("after consent = %+v", batches)
	}
	must(t, l.SetLevel(Basic, false))
	must(t, l.SetLevel(Full, false))
	if s, _ := l.State(); s.ID == "" || s.ID == "id-3" {
		t.Fatalf("a second consent reused or lost the id: %q", s.ID)
	}
}

func TestLeavingFullStripsTheIDAndUsageButKeepsTheBatchID(t *testing.T) {
	c := &clock{t: day(0)}
	l := openLedger(t, t.TempDir(), c, sequence())
	must(t, l.Remove([]string{"id-1"}))
	must(t, l.SetLevel(Full, true)) // analytics id id-2
	must(t, l.Add(day(0), Counts{LocalRuns: 1, "screen_overview": 4}))
	must(t, l.Add(day(1), Counts{"screen_runs": 1}))
	must(t, l.Add(day(2), Counts{"screen_runs": 1, LocalRuns: 1}))
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
	if p["screen_runs"] != 0 || p["screen_overview"] != 0 || p[LocalRuns] != 2 {
		t.Fatalf("pending = %+v", p)
	}
	if s, _ := l.State(); s.ID != "" {
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
	s, err := l.State()
	if err != nil || s.Level != Off || s.PromptAnswered || !s.Persistent || len(s.Pending) != 0 {
		t.Fatalf("replaced = %+v, %v", s, err)
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
```

- [ ] **Step 2: Run them to see them fail.**

Run (from `core/`): `go test ./internal/analytics/`
Expected: FAIL, `undefined: Open` (and the other names).

- [ ] **Step 3: Write `names.go`.**

```go
package analytics

import (
	"strings"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// Minute counters, counted at Basic and Full. Their meaning is in the
// metrics table of docs/product/analytics-and-crash-reporting.md.
const (
	LocalRuns                  = "local_runs"
	LocalBilledMinutes         = "local_billed_minutes"
	LocalJobsSucceeded         = "local_jobs_succeeded"
	LocalJobsFailed            = "local_jobs_failed"
	LocalJobsCancelled         = "local_jobs_cancelled"
	LocalJobSeconds            = "local_job_seconds"
	GHRefJobsMatched           = "gh_ref_jobs_matched"
	GHRefBilledMinutes         = "gh_ref_billed_minutes"
	LocalBilledMinutesMatched  = "local_billed_minutes_matched"
	LocalRunsCompleted         = "local_runs_completed"
	LocalRunWallSeconds        = "local_run_wall_seconds"
	GHRefRunsMatched           = "gh_ref_runs_matched"
	GHRefRunWallSeconds        = "gh_ref_run_wall_seconds"
	SupersededCancels          = "superseded_cancels"
	SupersededCancelMinutesEst = "superseded_cancel_minutes_est"
	ConcurrencyInserted        = "concurrency_inserted"
	ConcurrencyCancels         = "concurrency_cancels"
	ConcurrencyMinutesEst      = "concurrency_minutes_est"
)

var minuteCounters = map[string]bool{
	LocalRuns: true, LocalBilledMinutes: true, LocalJobsSucceeded: true, LocalJobsFailed: true,
	LocalJobsCancelled: true, LocalJobSeconds: true, GHRefJobsMatched: true, GHRefBilledMinutes: true,
	LocalBilledMinutesMatched: true, LocalRunsCompleted: true, LocalRunWallSeconds: true, GHRefRunsMatched: true,
	GHRefRunWallSeconds: true, SupersededCancels: true, SupersededCancelMinutesEst: true, ConcurrencyInserted: true,
	ConcurrencyCancels: true, ConcurrencyMinutesEst: true,
}

// Counts are increments by counter name.
type Counts map[string]int64

// IsMinuteCounter reports a saved-minute counter.
func IsMinuteCounter(name string) bool { return minuteCounters[name] }

// IsUsageCounter reports a section or action counter: a UsageEvent's
// lowercase name without its prefix.
func IsUsageCounter(name string) bool {
	if name == "" || strings.ToLower(name) != name {
		return false
	}
	value, ok := corev1.UsageEvent_value["USAGE_EVENT_"+strings.ToUpper(name)]
	return ok && value != 0
}

// UsageCounter is the counter of a section or action; "" for none.
func UsageCounter(event corev1.UsageEvent) string {
	name, ok := corev1.UsageEvent_name[int32(event)]
	if !ok || event == corev1.UsageEvent_USAGE_EVENT_UNSPECIFIED {
		return ""
	}
	return strings.ToLower(strings.TrimPrefix(name, "USAGE_EVENT_"))
}
```

- [ ] **Step 4: Write the file lock**, the same as the store's. `core/internal/analytics/lock_unix.go`:

```go
//go:build !windows

package analytics

import (
	"errors"
	"os"
	"syscall"
)

var errLocked = errors.New("locked by another process")

type fileLock struct{ file *os.File }

// acquireLock takes an advisory, non-blocking exclusive lock. The OS drops
// it when the process dies.
func acquireLock(path string) (*fileLock, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, errLocked
		}
		return nil, err
	}
	return &fileLock{file: file}, nil
}

func (l *fileLock) release() { _ = l.file.Close() }
```

`core/internal/analytics/lock_windows.go`:

```go
//go:build windows

package analytics

import "errors"

type fileLock struct{}

// The ledger is kept on disk on macOS only; elsewhere it is in memory.
func acquireLock(string) (*fileLock, error) {
	return nil, errors.New("the analytics ledger is not kept on disk on this platform")
}

func (l *fileLock) release() {}
```

- [ ] **Step 5: Write `ledger.go`.**

```go
// Package analytics keeps this Mac's analytics ledger and sends it to
// PostHog. Counts are added per UTC day and sealed, once the day is over,
// into batches with a random batch id; a batch is sent until PostHog
// accepts it and keeps its id when resent, and reads take one event per
// batch id, so every count is read once
// (docs/superpowers/specs/2026-10-25-anonymous-analytics-design.md).
package analytics

import (
	"crypto/rand"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"time"

	_ "modernc.org/sqlite"
)

// Level is what the ledger counts and sends.
type Level int

const (
	// Off counts and sends nothing.
	Off Level = iota + 1
	// Basic counts first_launch and minute counters, without an id.
	Basic
	// Full adds section and action counters and the analytics id.
	Full
)

func (l Level) String() string {
	switch l {
	case Off:
		return "off"
	case Basic:
		return "basic"
	case Full:
		return "full"
	}
	return "unknown"
}

const (
	eventFirstLaunch = "first_launch"
	eventUsageDay    = "usage_day"
)

const (
	ledgerName = "analytics.sqlite"
	lockName   = "analytics.lock"
	dayLayout  = "2006-01-02"
	// keepDays: older days are dropped, sent or not.
	keepDays = 7
	pragmas  = "_busy_timeout=5000&_journal_mode=WAL&_synchronous=FULL&_txlock=immediate"
)

// maxOutboxBytes bounds the outbox; tests lower it.
var maxOutboxBytes = 256 << 10

// ErrNotAllowed: a counter outside the allowlist, or a negative value.
var ErrNotAllowed = errors.New("not an allowed analytics count")

// schema is version 1 of analytics.sqlite. Before the first release tag it
// changes in place; a ledger with another user_version is replaced.
const schema = `
CREATE TABLE IF NOT EXISTS state (
	id INTEGER PRIMARY KEY CHECK (id = 1),
	level INTEGER NOT NULL,
	analytics_id TEXT NOT NULL DEFAULT '',
	prompt_answered INTEGER NOT NULL DEFAULT 0
);
-- Unsealed counts; day is the UTC date.
CREATE TABLE IF NOT EXISTS counters (
	day TEXT NOT NULL,
	name TEXT NOT NULL,
	value INTEGER NOT NULL,
	PRIMARY KEY (day, name)
);
-- Sealed batches, sent until accepted. counts is a JSON object; size
-- approximates the bytes a batch takes; next_attempt is Unix milliseconds.
CREATE TABLE IF NOT EXISTS outbox (
	batch_id TEXT PRIMARY KEY,
	day TEXT NOT NULL,
	event TEXT NOT NULL,
	level INTEGER NOT NULL,
	analytics_id TEXT NOT NULL,
	counts TEXT NOT NULL,
	size INTEGER NOT NULL,
	attempts INTEGER NOT NULL DEFAULT 0,
	next_attempt INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS outbox_order ON outbox (day, batch_id);
PRAGMA user_version = 1;
`

const schemaVersion = 1

// Options are for tests; the zero value uses the clock and random ids.
type Options struct {
	Now   func() time.Time
	NewID func() string
}

// Ledger is safe for concurrent use: one connection serializes the
// database, and mu serializes read-modify-write changes.
type Ledger struct {
	db         *sql.DB
	lock       *fileLock
	persistent bool
	now        func() time.Time
	newID      func() string

	mu        sync.Mutex
	closeOnce sync.Once
	closeErr  error
}

// State is what GetAnalytics reports.
type State struct {
	Level          Level
	PromptAnswered bool
	// ID is the analytics id; "" unless Full.
	ID         string
	Persistent bool
	// Pending sums unsealed and unsent counts by name; an unsent
	// first_launch is "first_launch": 1.
	Pending Counts
}

// Batch is one sealed event waiting in the outbox.
type Batch struct {
	ID          string
	Day         string
	Event       string
	Level       Level
	AnalyticsID string
	Counts      Counts
}

type start int

const (
	startFresh    start = iota + 1 // no ledger file: this is the first launch
	startReplaced                  // a damaged ledger or another schema, replaced
	startExisting
	startMemory
)

// Open opens the ledger in dir, creating it at Basic with a sealed
// first_launch when there is none. A damaged ledger is replaced at Off with
// the prompt unanswered. Without dir, or when another process holds the
// ledger, it lives in memory, never sends and Persistent is false. The error
// is set only when not even a memory database can be made.
func Open(dir string, options Options) (*Ledger, error) {
	l := &Ledger{now: options.Now, newID: options.NewID}
	if l.now == nil {
		l.now = time.Now
	}
	if l.newID == nil {
		l.newID = newUUID
	}
	if dir != "" {
		if db, lock, how, ok := openDisk(dir); ok {
			l.db, l.lock, l.persistent = db, lock, true
			if err := l.initialize(how); err == nil {
				return l, nil
			}
			_ = db.Close()
			lock.release()
			l.db, l.lock, l.persistent = nil, nil, false
		}
	}
	db, err := sql.Open("sqlite", "file::memory:")
	if err != nil {
		return nil, err
	}
	configurePool(db)
	if _, err := db.Exec(schema); err != nil {
		_ = db.Close()
		return nil, err
	}
	l.db = db
	if err := l.initialize(startMemory); err != nil {
		_ = db.Close()
		return nil, err
	}
	return l, nil
}

func openDisk(dir string) (*sql.DB, *fileLock, start, bool) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, nil, 0, false
	}
	lock, err := acquireLock(filepath.Join(dir, lockName))
	if err != nil {
		return nil, nil, 0, false
	}
	path := filepath.Join(dir, ledgerName)
	how := startExisting
	info, err := os.Lstat(path)
	switch {
	case errors.Is(err, os.ErrNotExist):
		how = startFresh
	case err != nil || !info.Mode().IsRegular():
		lock.release()
		return nil, nil, 0, false
	}
	if how == startExisting {
		if db, err := openFile(path); err == nil {
			if usable(db) {
				return db, lock, startExisting, true
			}
			_ = db.Close()
		}
		// Damaged, or made by another schema: what it held can go.
		for _, suffix := range []string{"", "-wal", "-shm"} {
			_ = os.Remove(path + suffix)
		}
		how = startReplaced
	}
	db, err := openFile(path)
	if err == nil {
		_, err = db.Exec(schema)
	}
	if err != nil {
		if db != nil {
			_ = db.Close()
		}
		lock.release()
		return nil, nil, 0, false
	}
	_ = os.Chmod(path, 0o600)
	return db, lock, how, true
}

func openFile(path string) (*sql.DB, error) {
	dsn := (&url.URL{Scheme: "file", Path: filepath.ToSlash(path), RawQuery: pragmas}).String()
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	configurePool(db)
	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, err
	}
	return db, nil
}

// configurePool keeps exactly one long-lived connection: a memory database
// lives with its connection, and one connection serializes the writes.
func configurePool(db *sql.DB) {
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(0)
	db.SetConnMaxIdleTime(0)
}

func usable(db *sql.DB) bool {
	var check string
	if err := db.QueryRow("PRAGMA quick_check").Scan(&check); err != nil || check != "ok" {
		return false
	}
	var version int
	if err := db.QueryRow("PRAGMA user_version").Scan(&version); err != nil {
		return false
	}
	return version == schemaVersion
}

func (l *Ledger) initialize(how start) error {
	if how == startExisting {
		return nil
	}
	level := Basic
	if how == startReplaced {
		// The user's choice went with the file: nothing is sent until they
		// choose again in the prompt.
		level = Off
	}
	return l.tx(func(tx *sql.Tx) error {
		if _, err := tx.Exec(`INSERT INTO state (id, level) VALUES (1, ?)`, level); err != nil {
			return err
		}
		if how != startFresh {
			return nil
		}
		return insertBatch(tx, Batch{ID: l.newID(), Day: l.day(l.now()), Event: eventFirstLaunch, Level: Basic})
	})
}

// Persistent reports a ledger kept on disk, which alone can send.
func (l *Ledger) Persistent() bool { return l.persistent }

// Close closes the database and releases the lock; calling it again does
// nothing.
func (l *Ledger) Close() error {
	l.closeOnce.Do(func() {
		l.closeErr = l.db.Close()
		if l.lock != nil {
			l.lock.release()
		}
	})
	return l.closeErr
}

// Add adds counts to the UTC day of at. A name outside the allowlist or a
// negative value refuses the whole call. Section and action counters count
// only at Full, minute counters at Basic and Full, nothing at Off.
func (l *Ledger) Add(at time.Time, counts Counts) error {
	for name, value := range counts {
		if value < 0 || (!IsMinuteCounter(name) && !IsUsageCounter(name)) {
			return fmt.Errorf("%w: %q", ErrNotAllowed, name)
		}
	}
	day := l.day(at)
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.tx(func(tx *sql.Tx) error {
		s, err := readState(tx)
		if err != nil || s.level == Off {
			return err
		}
		for name, value := range counts {
			if value == 0 || (IsUsageCounter(name) && s.level != Full) {
				continue
			}
			if _, err := tx.Exec(`INSERT INTO counters (day, name, value) VALUES (?, ?, ?)
ON CONFLICT (day, name) DO UPDATE SET value = counters.value + excluded.value`, day, name, value); err != nil {
				return err
			}
		}
		return nil
	})
}

// Seal turns each UTC day before today into one outbox batch, then drops
// what is older than seven days, and the oldest batches beyond the outbox's
// size.
func (l *Ledger) Seal() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.tx(func(tx *sql.Tx) error {
		s, err := readState(tx)
		if err != nil {
			return err
		}
		if err := l.sealBefore(tx, s, l.day(l.now())); err != nil {
			return err
		}
		return trim(tx, l.now())
	})
}

// SetLevel changes the level as the spec's Level Changes say; fromPrompt
// marks the consent prompt answered.
func (l *Ledger) SetLevel(level Level, fromPrompt bool) error {
	if level < Off || level > Full {
		return fmt.Errorf("unknown analytics level %d", level)
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.tx(func(tx *sql.Tx) error {
		s, err := readState(tx)
		if err != nil {
			return err
		}
		id := s.id
		if level != s.level {
			switch level {
			case Off:
				for _, statement := range []string{`DELETE FROM counters`, `DELETE FROM outbox`} {
					if _, err := tx.Exec(statement); err != nil {
						return err
					}
				}
				id = ""
			case Basic:
				if s.level == Full {
					if err := stripUsage(tx); err != nil {
						return err
					}
				}
				id = ""
			case Full:
				// What was counted without an id is sealed now, so the new id
				// never goes with it.
				if err := l.sealBefore(tx, s, ""); err != nil {
					return err
				}
				id = l.newID()
			}
		}
		_, err = tx.Exec(`UPDATE state SET level = ?, analytics_id = ?, prompt_answered = ? WHERE id = 1`,
			level, id, s.answered || fromPrompt)
		return err
	})
}

// State reads the level, the id and what waits to be sent.
func (l *Ledger) State() (State, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	s, err := readState(l.db)
	if err != nil {
		return State{}, err
	}
	out := State{Level: s.level, PromptAnswered: s.answered, ID: s.id, Persistent: l.persistent, Pending: Counts{}}
	rows, err := l.db.Query(`SELECT name, SUM(value) FROM counters GROUP BY name`)
	if err != nil {
		return State{}, err
	}
	for rows.Next() {
		var name string
		var value int64
		if err := rows.Scan(&name, &value); err != nil {
			_ = rows.Close()
			return State{}, err
		}
		out.Pending[name] += value
	}
	if err := rows.Close(); err != nil {
		return State{}, err
	}
	batches, err := queryBatches(l.db, "")
	if err != nil {
		return State{}, err
	}
	for _, b := range batches {
		if b.Event == eventFirstLaunch {
			out.Pending[eventFirstLaunch]++
		}
		for name, value := range b.Counts {
			out.Pending[name] += value
		}
	}
	return out, nil
}

// Due lists up to limit batches whose next attempt has come, oldest first.
func (l *Ledger) Due(limit int) ([]Batch, error) {
	return queryBatches(l.db, `WHERE next_attempt <= ? ORDER BY day, batch_id LIMIT ?`, l.now().UnixMilli(), limit)
}

// Remove deletes batches: sent, or never sendable.
func (l *Ledger) Remove(ids []string) error {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.tx(func(tx *sql.Tx) error {
		for _, id := range ids {
			if _, err := tx.Exec(`DELETE FROM outbox WHERE batch_id = ?`, id); err != nil {
				return err
			}
		}
		return nil
	})
}

// Failed counts an attempt on each batch and delays its next one.
func (l *Ledger) Failed(ids []string) error {
	now := l.now()
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.tx(func(tx *sql.Tx) error {
		for _, id := range ids {
			var attempts int
			err := tx.QueryRow(`SELECT attempts FROM outbox WHERE batch_id = ?`, id).Scan(&attempts)
			if errors.Is(err, sql.ErrNoRows) {
				continue
			} else if err != nil {
				return err
			}
			attempts++
			if _, err := tx.Exec(`UPDATE outbox SET attempts = ?, next_attempt = ? WHERE batch_id = ?`,
				attempts, now.Add(RetryDelay(attempts)).UnixMilli(), id); err != nil {
				return err
			}
		}
		return nil
	})
}

// RetryDelay is the wait after a batch's attempts-th failure: 1 minute,
// 5 minutes, 30 minutes, then 6 hours.
func RetryDelay(attempts int) time.Duration {
	switch {
	case attempts <= 1:
		return time.Minute
	case attempts == 2:
		return 5 * time.Minute
	case attempts == 3:
		return 30 * time.Minute
	}
	return 6 * time.Hour
}

// NextAttempt is the earliest next attempt in the outbox; false when empty.
func (l *Ledger) NextAttempt() (time.Time, bool, error) {
	var next sql.NullInt64
	if err := l.db.QueryRow(`SELECT MIN(next_attempt) FROM outbox`).Scan(&next); err != nil || !next.Valid {
		return time.Time{}, false, err
	}
	return time.UnixMilli(next.Int64), true, nil
}

func (l *Ledger) day(t time.Time) string { return t.UTC().Format(dayLayout) }

func (l *Ledger) tx(f func(*sql.Tx) error) error {
	tx, err := l.db.Begin()
	if err != nil {
		return err
	}
	if err := f(tx); err != nil {
		_ = tx.Rollback()
		return err
	}
	return tx.Commit()
}

// sealBefore seals the counters of days before limit, every day for "".
func (l *Ledger) sealBefore(tx *sql.Tx, s stateRow, limit string) error {
	where, args := "", []any{}
	if limit != "" {
		where, args = `WHERE day < ?`, []any{limit}
	}
	rows, err := tx.Query(`SELECT day, name, value FROM counters `+where+` ORDER BY day, name`, args...)
	if err != nil {
		return err
	}
	byDay := map[string]Counts{}
	var days []string
	for rows.Next() {
		var day, name string
		var value int64
		if err := rows.Scan(&day, &name, &value); err != nil {
			_ = rows.Close()
			return err
		}
		if byDay[day] == nil {
			byDay[day] = Counts{}
			days = append(days, day)
		}
		byDay[day][name] = value
	}
	if err := rows.Close(); err != nil {
		return err
	}
	if s.level != Off {
		for _, day := range days {
			b := Batch{ID: l.newID(), Day: day, Event: eventUsageDay, Level: s.level, Counts: byDay[day]}
			if s.level == Full {
				b.AnalyticsID = s.id
			}
			if err := insertBatch(tx, b); err != nil {
				return err
			}
		}
	}
	_, err = tx.Exec(`DELETE FROM counters `+where, args...)
	return err
}

// stripUsage removes section and action counts and the id: from counters,
// and from batches sealed at Full, which keep their batch id, so one
// already delivered is still read once. A batch left empty is dropped.
func stripUsage(tx *sql.Tx) error {
	if _, err := tx.Exec(`DELETE FROM counters WHERE substr(name, 1, 7) IN ('screen_', 'action_')`); err != nil {
		return err
	}
	batches, err := queryBatches(tx, `WHERE level = ?`, Full)
	if err != nil {
		return err
	}
	for _, b := range batches {
		for name := range b.Counts {
			if IsUsageCounter(name) {
				delete(b.Counts, name)
			}
		}
		if len(b.Counts) == 0 && b.Event == eventUsageDay {
			if _, err := tx.Exec(`DELETE FROM outbox WHERE batch_id = ?`, b.ID); err != nil {
				return err
			}
			continue
		}
		b.Level, b.AnalyticsID = Basic, ""
		counts, err := json.Marshal(b.Counts)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(`UPDATE outbox SET level = ?, analytics_id = '', counts = ?, size = ? WHERE batch_id = ?`,
			Basic, string(counts), batchSize(b, len(counts)), b.ID); err != nil {
			return err
		}
	}
	return nil
}

func trim(tx *sql.Tx, now time.Time) error {
	cutoff := now.UTC().AddDate(0, 0, -keepDays).Format(dayLayout)
	for _, statement := range []string{`DELETE FROM outbox WHERE day < ?`, `DELETE FROM counters WHERE day < ?`} {
		if _, err := tx.Exec(statement, cutoff); err != nil {
			return err
		}
	}
	for {
		var total int64
		if err := tx.QueryRow(`SELECT COALESCE(SUM(size), 0) FROM outbox`).Scan(&total); err != nil {
			return err
		}
		if total <= int64(maxOutboxBytes) {
			return nil
		}
		if _, err := tx.Exec(`DELETE FROM outbox WHERE batch_id = (SELECT batch_id FROM outbox ORDER BY day, batch_id LIMIT 1)`); err != nil {
			return err
		}
	}
}

type stateRow struct {
	level    Level
	id       string
	answered bool
}

type rowQuerier interface {
	QueryRow(query string, args ...any) *sql.Row
}

func readState(q rowQuerier) (stateRow, error) {
	var s stateRow
	err := q.QueryRow(`SELECT level, analytics_id, prompt_answered FROM state WHERE id = 1`).Scan(&s.level, &s.id, &s.answered)
	return s, err
}

type querier interface {
	Query(query string, args ...any) (*sql.Rows, error)
}

func queryBatches(q querier, tail string, args ...any) ([]Batch, error) {
	rows, err := q.Query(`SELECT batch_id, day, event, level, analytics_id, counts FROM outbox `+tail, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Batch
	for rows.Next() {
		var b Batch
		var counts string
		if err := rows.Scan(&b.ID, &b.Day, &b.Event, &b.Level, &b.AnalyticsID, &counts); err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(counts), &b.Counts); err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

func insertBatch(tx *sql.Tx, b Batch) error {
	if b.Counts == nil {
		b.Counts = Counts{}
	}
	counts, err := json.Marshal(b.Counts)
	if err != nil {
		return err
	}
	_, err = tx.Exec(`INSERT INTO outbox (batch_id, day, event, level, analytics_id, counts, size) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		b.ID, b.Day, b.Event, b.Level, b.AnalyticsID, string(counts), batchSize(b, len(counts)))
	return err
}

// batchSize approximates the bytes a batch takes in the outbox and on the
// wire: the event's fixed properties plus its ids and counts.
func batchSize(b Batch, countsBytes int) int { return 300 + len(b.ID) + len(b.AnalyticsID) + countsBytes }

// newUUID is a random (version 4) UUID.
func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:]) // never fails since Go 1.24
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
```

- [ ] **Step 6: Run the tests.**

Run (from `core/`): `go test ./internal/analytics/ && go vet ./internal/analytics/`
Expected: `ok  runnir/core/internal/analytics`. If `TestADamagedLedgerIsReplacedAndSendsNothingUntilAsked` fails because the driver opens the garbage file without error, check that `usable` returns false (the quick check fails with "file is not a database") rather than changing the test.

- [ ] **Step 7: Commit.**

```bash
git add core/internal/analytics
git commit -m "Core: analytics ledger with daily counts sealed into batches (B21)"
```

---

### Task 3: Events And The Sender

**Files:**
- Create: `core/internal/analytics/event.go`, `core/internal/analytics/env_darwin.go`, `core/internal/analytics/env_other.go`, `core/internal/analytics/sender.go`
- Test: `core/internal/analytics/sender_test.go`

**Interfaces:**
- Consumes: Task 2's `Ledger`, `Batch`, `Counts`, `IsMinuteCounter`, `IsUsageCounter`, `ErrNotAllowed`.
- Produces:
  - `const Endpoint = "https://us.i.posthog.com/batch/"`.
  - `type Env struct{ AppVersion, AppBuild, OSVersion, Arch string }`; `func CurrentEnv(appVersion, appBuild string) Env`.
  - `func Body(key string, env Env, batches []Batch) ([]byte, error)`.
  - `type Sender struct{ Ledger *Ledger; Endpoint, Key string; Env Env; Client *http.Client; Log io.Writer; Now func() time.Time }`; `(*Sender).Enabled() bool`, `Flush(ctx) error`, `Run(ctx, first, every time.Duration)`.

- [ ] **Step 1: Write the failing tests** in `core/internal/analytics/sender_test.go`:

```go
//go:build !windows

package analytics

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

type fakePostHog struct {
	*httptest.Server
	mu     sync.Mutex
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

var testEnv = Env{AppVersion: "0.2.0", AppBuild: "42", OSVersion: "26.1", Arch: "arm64"}

func sender(l *Ledger, ph *fakePostHog) *Sender {
	return &Sender{Ledger: l, Endpoint: ph.URL, Key: "phc_test", Env: testEnv}
}

func TestFirstLaunchIsSentWithoutAnID(t *testing.T) {
	c := &clock{t: day(0)}
	l := openLedger(t, t.TempDir(), c, sequence())
	ph := newPostHog(t)
	must(t, sender(l, ph).Flush(context.Background()))
	ph.mu.Lock()
	key := ph.bodies[0]["api_key"]
	ph.mu.Unlock()
	if key != "phc_test" {
		t.Fatalf("api_key = %v", key)
	}
	events := ph.events(t, 0)
	if len(events) != 1 {
		t.Fatalf("events = %+v", events)
	}
	e, props := events[0], events[0]["properties"].(map[string]any)
	want := map[string]any{"batch_id": "id-1", "app_version": "0.2.0", "app_build": "42", "os_version": "26.1", "arch": "arm64",
		"$process_person_profile": false, "$geoip_disable": true, "$lib": "runnir-core"}
	if e["event"] != "first_launch" || e["distinct_id"] != "id-1" || e["timestamp"] != "2026-10-20T00:00:00Z" || len(props) != len(want) {
		t.Fatalf("event = %+v", e)
	}
	for k, v := range want {
		if props[k] != v {
			t.Fatalf("%s = %v, want %v", k, props[k], v)
		}
	}
	if got := pending(t, l)["first_launch"]; got != 0 {
		t.Fatal("first_launch still pending after a 200")
	}
}

func TestAFailedSendIsRetriedWithTheSameBatchID(t *testing.T) {
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
	id := func(e map[string]any) any { return e["properties"].(map[string]any)["batch_id"] }
	if id(first) != "id-1" || id(second) != "id-1" || pending(t, l)["first_launch"] != 0 {
		t.Fatalf("retry = %v then %v", id(first), id(second))
	}
}

func TestUsageDaysCarryTheIDOnlyAtFull(t *testing.T) {
	c := &clock{t: day(0)}
	l := openLedger(t, t.TempDir(), c, sequence())
	must(t, l.Remove([]string{"id-1"}))
	must(t, l.Add(day(0), Counts{LocalBilledMinutes: 3}))
	must(t, l.SetLevel(Full, true)) // id-2 sealed without an id, id-3 the analytics id
	must(t, l.Add(day(0), Counts{LocalBilledMinutes: 2, "action_dispatch": 1}))
	c.t = day(1)
	ph := newPostHog(t)
	must(t, sender(l, ph).Flush(context.Background()))
	events := ph.events(t, 0)
	if len(events) != 2 {
		t.Fatalf("events = %+v", events)
	}
	basic, full := events[0], events[1]
	bp, fp := basic["properties"].(map[string]any), full["properties"].(map[string]any)
	if basic["distinct_id"] != "id-2" || bp["level"] != "basic" || bp["day"] != "2026-10-20" || bp[LocalBilledMinutes] != 3.0 {
		t.Fatalf("basic = %+v", basic)
	}
	if full["distinct_id"] != "id-3" || fp["level"] != "full" || fp["batch_id"] != "id-4" || fp["action_dispatch"] != 1.0 {
		t.Fatalf("full = %+v", full)
	}
}

func TestNothingIsSentWithoutAKeyOrAFolder(t *testing.T) {
	c := &clock{t: day(0)}
	ph := newPostHog(t)
	onDisk := openLedger(t, t.TempDir(), c, sequence())
	noKey := &Sender{Ledger: onDisk, Endpoint: ph.URL, Env: testEnv}
	inMemory := sender(openLedger(t, "", c, sequence()), ph)
	must(t, noKey.Flush(context.Background()))
	must(t, inMemory.Flush(context.Background()))
	if ph.requests() != 0 || noKey.Enabled() || inMemory.Enabled() {
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
	s := &Sender{Ledger: l, Endpoint: redirect.URL, Key: "phc_test", Env: testEnv}
	if err := s.Flush(context.Background()); err == nil {
		t.Fatal("a redirect counted as delivered")
	}
	if elsewhere.requests() != 0 || pending(t, l)["first_launch"] != 1 {
		t.Fatal("the redirect was followed or the batch dropped")
	}
}

func TestABodyHoldsOnlyAllowedCounters(t *testing.T) {
	_, err := Body("phc_test", testEnv, []Batch{{ID: "b", Day: "2026-10-20", Event: "usage_day", Level: Basic,
		Counts: Counts{"repository": 1}}})
	if !errors.Is(err, ErrNotAllowed) {
		t.Fatalf("unknown counter = %v", err)
	}
	_, err = Body("phc_test", testEnv, []Batch{{ID: "b", Day: "2026-10-20", Event: "usage_day", Level: Basic,
		Counts: Counts{"screen_runs": 1}}})
	if !errors.Is(err, ErrNotAllowed) {
		t.Fatalf("a usage counter at basic = %v", err)
	}
}
```

- [ ] **Step 2: Run them to see them fail.**

Run (from `core/`): `go test ./internal/analytics/`
Expected: FAIL, `undefined: Sender`, `undefined: Env`, `undefined: Body`.

- [ ] **Step 3: Write `env_darwin.go` and `env_other.go`.**

```go
//go:build darwin

package analytics

import (
	"strings"
	"syscall"
)

// osVersion is macOS's major.minor, for example "26.1".
func osVersion() string {
	version, err := syscall.Sysctl("kern.osproductversion")
	if err != nil {
		return ""
	}
	if parts := strings.SplitN(version, ".", 3); len(parts) >= 2 {
		return parts[0] + "." + parts[1]
	}
	return version
}
```

```go
//go:build !darwin

package analytics

func osVersion() string { return "" }
```

- [ ] **Step 4: Write `event.go`.**

```go
package analytics

import (
	"encoding/json"
	"fmt"
	"runtime"
	"time"
)

// Endpoint is PostHog Cloud US's batch capture.
const Endpoint = "https://us.i.posthog.com/batch/"

// Env is what every event says about the build that sends it.
type Env struct {
	AppVersion string
	AppBuild   string
	OSVersion  string
	Arch       string
}

// CurrentEnv is this process's Env.
func CurrentEnv(appVersion, appBuild string) Env {
	return Env{AppVersion: appVersion, AppBuild: appBuild, OSVersion: osVersion(), Arch: runtime.GOARCH}
}

type event struct {
	Event      string         `json:"event"`
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
func Body(key string, env Env, batches []Batch) ([]byte, error) {
	out := requestBody{APIKey: key, Batch: make([]event, 0, len(batches))}
	for _, b := range batches {
		day, err := time.Parse(dayLayout, b.Day)
		if err != nil {
			return nil, err
		}
		props := map[string]any{
			"batch_id": b.ID, "app_version": env.AppVersion, "app_build": env.AppBuild,
			"os_version": env.OSVersion, "arch": env.Arch,
			"$process_person_profile": false, "$geoip_disable": true, "$lib": "runnir-core",
		}
		distinct := b.ID
		switch b.Event {
		case eventFirstLaunch:
		case eventUsageDay:
			props["day"], props["level"] = b.Day, b.Level.String()
			for name, value := range b.Counts {
				if !IsMinuteCounter(name) && !(IsUsageCounter(name) && b.Level == Full) {
					return nil, fmt.Errorf("%w: %q", ErrNotAllowed, name)
				}
				props[name] = value
			}
			if b.Level == Full && b.AnalyticsID != "" {
				distinct = b.AnalyticsID
			}
		default:
			return nil, fmt.Errorf("unknown analytics event %q", b.Event)
		}
		out.Batch = append(out.Batch, event{Event: b.Event, DistinctID: distinct,
			Timestamp: day.UTC().Format(time.RFC3339), Properties: props})
	}
	return json.Marshal(out)
}
```

- [ ] **Step 5: Write `sender.go`.**

```go
package analytics

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"time"
)

const maxEventsPerRequest = 50

// Sender seals the ledger's completed days and sends due batches.
type Sender struct {
	Ledger   *Ledger
	Endpoint string
	// Key is the PostHog project key; empty sends nothing.
	Key string
	Env Env
	// Client sends requests; nil uses one with a 20-second timeout that
	// follows no redirect, so batches only go to Endpoint.
	Client *http.Client
	// Log gets one line per failed send, never the body; nil drops it.
	Log io.Writer
	// Now is the clock for Run; nil is time.Now.
	Now func() time.Time
}

// Enabled: a key, an endpoint and a ledger kept on disk.
func (s *Sender) Enabled() bool { return s.Key != "" && s.Endpoint != "" && s.Ledger.Persistent() }

// Flush seals completed days, then sends due batches, 50 per request, until
// none is due or a request fails. A failed request delays its batches.
func (s *Sender) Flush(ctx context.Context) error {
	if err := s.Ledger.Seal(); err != nil {
		return err
	}
	if !s.Enabled() {
		return nil
	}
	for ctx.Err() == nil {
		due, err := s.Ledger.Due(maxEventsPerRequest)
		if err != nil || len(due) == 0 {
			return err
		}
		ids := make([]string, len(due))
		for i, b := range due {
			ids[i] = b.ID
		}
		body, err := Body(s.Key, s.Env, due)
		if err != nil {
			// Never sendable: a counter this build no longer allows.
			_ = s.Ledger.Remove(ids)
			return err
		}
		if err := s.post(ctx, body); err != nil {
			_ = s.Ledger.Failed(ids)
			if s.Log != nil {
				fmt.Fprintf(s.Log, "analytics: %v; %d batches wait for the next send\n", err, len(ids))
			}
			return err
		}
		if err := s.Ledger.Remove(ids); err != nil {
			return err
		}
	}
	return ctx.Err()
}

// Run flushes after first, then every every, or sooner when a failed
// batch's retry comes first; it returns when ctx ends.
func (s *Sender) Run(ctx context.Context, first, every time.Duration) {
	now := s.Now
	if now == nil {
		now = time.Now
	}
	timer := time.NewTimer(first)
	defer timer.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-timer.C:
		}
		_ = s.Flush(ctx)
		wait := every
		if s.Enabled() {
			if next, ok, err := s.Ledger.NextAttempt(); err == nil && ok {
				if d := next.Sub(now()); d < wait {
					wait = max(d, time.Minute)
				}
			}
		}
		timer.Reset(wait)
	}
}

func (s *Sender) post(ctx context.Context, body []byte) error {
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, s.Endpoint, bytes.NewReader(body))
	if err != nil {
		return err
	}
	request.Header.Set("Content-Type", "application/json")
	client := s.Client
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second,
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	response, err := client.Do(request)
	if err != nil {
		return err
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return fmt.Errorf("the analytics endpoint answered %d", response.StatusCode)
	}
	return nil
}
```

- [ ] **Step 6: Run the tests.**

Run (from `core/`): `go test ./internal/analytics/ && go vet ./internal/analytics/`
Expected: `ok  runnir/core/internal/analytics`.

- [ ] **Step 7: Commit.**

```bash
git add core/internal/analytics
git commit -m "Core: send sealed analytics batches to PostHog, retrying with the same batch id (B21)"
```

---

### Task 4: Server Wiring And The Analytics RPCs

**Files:**
- Create: `core/internal/server/analytics.go`
- Modify: `core/internal/server/server.go` (Options, `RunWithOptions`), `core/internal/server/service.go` (struct fields)
- Test: `core/internal/server/analytics_test.go`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: `server.Options.AnalyticsEndpoint`, `AnalyticsKey`, `AnalyticsFirstSend`; `service.analytics *analytics.Ledger`, `service.analyticsSending bool`; RPC handlers; helpers `countSupersededCancel` and `noteConcurrencySaved` used in Task 6.

- [ ] **Step 1: Write the failing test** in `core/internal/server/analytics_test.go`:

```go
//go:build !windows

package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func startWith(t *testing.T, path string, options Options) corev1.RunnirCoreClient {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan error, 1)
	go func() { result <- RunWithOptions(ctx, path, options) }()
	waitForSocket(t, path, result)
	t.Cleanup(func() { cancel(); <-result })
	conn, err := grpc.NewClient("unix://"+path, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return corev1.NewRunnirCoreClient(conn)
}

func pendingCount(a *corev1.Analytics, name string) uint64 {
	for _, c := range a.GetPending() {
		if c.GetName() == name {
			return c.GetValue()
		}
	}
	return 0
}

func TestAnalyticsOverGRPC(t *testing.T) {
	var mu sync.Mutex
	var events []string
	posthog := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Batch []struct{ Event string } `json:"batch"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		mu.Lock()
		for _, e := range body.Batch {
			events = append(events, e.Event)
		}
		mu.Unlock()
	}))
	t.Cleanup(posthog.Close)
	client := startWith(t, socketPath(t), Options{DataDir: t.TempDir(), AnalyticsEndpoint: posthog.URL,
		AnalyticsKey: "phc_test", AnalyticsFirstSend: 10 * time.Millisecond})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	a, err := client.GetAnalytics(ctx, &corev1.GetAnalyticsRequest{})
	if err != nil || a.GetLevel() != corev1.AnalyticsLevel_ANALYTICS_LEVEL_BASIC || a.GetPromptAnswered() ||
		!a.GetPersistent() || !a.GetSendingAvailable() || a.GetAnalyticsId() != "" {
		t.Fatalf("first state = %+v, %v", a, err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		mu.Lock()
		sent := len(events) == 1 && events[0] == "first_launch"
		mu.Unlock()
		if sent {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("first_launch never reached PostHog")
		}
		time.Sleep(10 * time.Millisecond)
	}

	run := &corev1.RecordUsageRequest{Event: corev1.UsageEvent_USAGE_EVENT_SCREEN_RUNS}
	if _, err := client.RecordUsage(ctx, run); err != nil {
		t.Fatal(err)
	}
	a, _ = client.GetAnalytics(ctx, &corev1.GetAnalyticsRequest{})
	if pendingCount(a, "screen_runs") != 0 {
		t.Fatal("a section was counted at BASIC")
	}
	a, err = client.SetAnalyticsLevel(ctx, &corev1.SetAnalyticsLevelRequest{Level: corev1.AnalyticsLevel_ANALYTICS_LEVEL_FULL, FromPrompt: true})
	if err != nil || !a.GetPromptAnswered() || a.GetAnalyticsId() == "" {
		t.Fatalf("full = %+v, %v", a, err)
	}
	if _, err := client.RecordUsage(ctx, run); err != nil {
		t.Fatal(err)
	}
	if a, _ = client.GetAnalytics(ctx, &corev1.GetAnalyticsRequest{}); pendingCount(a, "screen_runs") != 1 {
		t.Fatalf("pending = %+v", a.GetPending())
	}
	if _, err := client.RecordUsage(ctx, &corev1.RecordUsageRequest{}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("no event = %v", err)
	}
	if _, err := client.SetAnalyticsLevel(ctx, &corev1.SetAnalyticsLevelRequest{}); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("no level = %v", err)
	}
}

func TestAnalyticsWithoutADataFolderStayInMemory(t *testing.T) {
	client := startWith(t, socketPath(t), Options{AnalyticsKey: "phc_test"})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	a, err := client.GetAnalytics(ctx, &corev1.GetAnalyticsRequest{})
	if err != nil || a.GetPersistent() || a.GetSendingAvailable() {
		t.Fatalf("memory = %+v, %v", a, err)
	}
}
```

- [ ] **Step 2: Run it to see it fail.**

Run (from `core/`): `go test ./internal/server/ -run Analytics`
Expected: FAIL to compile: `unknown field AnalyticsEndpoint in struct literal of type Options`.

- [ ] **Step 3: Add the options** to `Options` in `server.go`, after `DataDir`:

```go
	// AnalyticsEndpoint and AnalyticsKey replace analytics.Endpoint and
	// buildinfo.AnalyticsKey, for tests. An empty key sends nothing.
	AnalyticsEndpoint string
	AnalyticsKey      string
	// AnalyticsFirstSend is how long after start the first send waits;
	// 0 is one minute.
	AnalyticsFirstSend time.Duration
```

- [ ] **Step 4: Open the ledger and start the sender** in `RunWithOptions`. Right after the socket `os.Chmod` block and before `bus := events.New(...)`, add:

```go
	// Opened before the workspaces, so it closes after them: their
	// recorder may still add counts while shutting down.
	ledger, err := analytics.Open(options.DataDir, analytics.Options{})
	if err != nil {
		_ = listener.Close()
		return fmt.Errorf("analytics: %w", err)
	}
	defer ledger.Close()
```

The `workspaces := workspace.New(...)` line stays as it is; Task 5 gives it the ledger. After `defer workspaces.Shutdown()` add:

```go
	endpoint, key := options.AnalyticsEndpoint, options.AnalyticsKey
	if endpoint == "" {
		endpoint = analytics.Endpoint
	}
	if key == "" {
		key = buildinfo.AnalyticsKey
	}
	sender := &analytics.Sender{Ledger: ledger, Endpoint: endpoint, Key: key,
		Env: analytics.CurrentEnv(buildinfo.Version, buildinfo.Build), Log: os.Stderr}
	firstSend := options.AnalyticsFirstSend
	if firstSend <= 0 {
		firstSend = time.Minute
	}
	senderCtx, stopSender := context.WithCancel(context.Background())
	senderDone := make(chan struct{})
	go func() { defer close(senderDone); sender.Run(senderCtx, firstSend, 6*time.Hour) }()
	defer func() { stopSender(); <-senderDone }()
```

Add `analytics: ledger, analyticsSending: sender.Enabled(),` to the `&service{...}` literal, and `"runnir/core/internal/analytics"` to the imports.

- [ ] **Step 5: Add the fields** to `service` in `service.go`, after `localOutputs`:

```go
	// analytics is this Mac's ledger; nil only in tests that build a
	// service by hand.
	analytics        *analytics.Ledger
	analyticsSending bool
```

with the import `"runnir/core/internal/analytics"`.

- [ ] **Step 6: Write `core/internal/server/analytics.go`.**

```go
package server

import (
	"context"
	"sort"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"runnir/core/internal/analytics"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func (s *service) GetAnalytics(context.Context, *corev1.GetAnalyticsRequest) (*corev1.Analytics, error) {
	return s.analyticsMessage()
}

func (s *service) SetAnalyticsLevel(_ context.Context, request *corev1.SetAnalyticsLevelRequest) (*corev1.Analytics, error) {
	if s.analytics == nil {
		return nil, status.Error(codes.Unavailable, "analytics are not available")
	}
	var level analytics.Level
	switch request.GetLevel() {
	case corev1.AnalyticsLevel_ANALYTICS_LEVEL_OFF:
		level = analytics.Off
	case corev1.AnalyticsLevel_ANALYTICS_LEVEL_BASIC:
		level = analytics.Basic
	case corev1.AnalyticsLevel_ANALYTICS_LEVEL_FULL:
		level = analytics.Full
	default:
		return nil, status.Error(codes.InvalidArgument, "a known analytics level is required")
	}
	if err := s.analytics.SetLevel(level, request.GetFromPrompt()); err != nil {
		return nil, status.Error(codes.Internal, "the analytics level could not be changed")
	}
	return s.analyticsMessage()
}

func (s *service) RecordUsage(_ context.Context, request *corev1.RecordUsageRequest) (*corev1.RecordUsageResponse, error) {
	name := analytics.UsageCounter(request.GetEvent())
	if name == "" {
		return nil, status.Error(codes.InvalidArgument, "a known usage event is required")
	}
	if s.analytics != nil {
		if err := s.analytics.Add(time.Now(), analytics.Counts{name: 1}); err != nil {
			return nil, status.Error(codes.Internal, "the usage could not be counted")
		}
	}
	return &corev1.RecordUsageResponse{}, nil
}

func (s *service) analyticsMessage() (*corev1.Analytics, error) {
	if s.analytics == nil {
		return nil, status.Error(codes.Unavailable, "analytics are not available")
	}
	state, err := s.analytics.State()
	if err != nil {
		return nil, status.Error(codes.Internal, "the analytics ledger could not be read")
	}
	out := &corev1.Analytics{PromptAnswered: state.PromptAnswered, AnalyticsId: state.ID,
		Persistent: state.Persistent, SendingAvailable: s.analyticsSending}
	switch state.Level {
	case analytics.Off:
		out.Level = corev1.AnalyticsLevel_ANALYTICS_LEVEL_OFF
	case analytics.Full:
		out.Level = corev1.AnalyticsLevel_ANALYTICS_LEVEL_FULL
	default:
		out.Level = corev1.AnalyticsLevel_ANALYTICS_LEVEL_BASIC
	}
	names := make([]string, 0, len(state.Pending))
	for name := range state.Pending {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if value := state.Pending[name]; value > 0 {
			out.Pending = append(out.Pending, &corev1.AnalyticsCounter{Name: name, Value: uint64(value)})
		}
	}
	return out, nil
}
```

- [ ] **Step 7: Run the tests.**

Run (from `core/`): `go test ./internal/server/ && go vet ./... && go build ./...`
Expected: `ok  runnir/core/internal/server`, no vet output.

- [ ] **Step 8: Commit.**

```bash
git add core/internal/server
git commit -m "Core: analytics ledger, sender and level RPCs in the server (B21)"
```

---

### Task 5: Minute Counters From Local Runs

**Files:**
- Modify: `core/internal/localrun/output.go` (add `Summary`, `BilledJobMinutes`)
- Create: `core/internal/store/references.go`, `core/internal/workspace/analytics.go`
- Modify: `core/internal/workspace/runtimes.go` (Options, `ObserveExecution`), `core/internal/server/server.go` (the `workspace.New` line from Task 4)
- Test: `core/internal/localrun/output_test.go`, `core/internal/store/references_test.go`, `core/internal/workspace/analytics_test.go`

**Interfaces:**
- Consumes: `analytics.Counts` and the counter names (Task 2).
- Produces:
  - `localrun.Summary{WorkflowID string; WholeWorkflow bool; StartedAt, FinishedAt time.Time; Jobs []JobStatus}`; `(*Outputs).Summary(executionID string) (Summary, bool)`; `localrun.BilledJobMinutes(d time.Duration) int64`.
  - `(*store.Store).JobReferences(ctx, workflowPath string, names []string) (map[string]time.Duration, error)`, `RunReference(ctx, workflowPath string) (time.Duration, bool, error)`.
  - `workspace.Options.RunSummary func(string) (localrun.Summary, bool)`, `workspace.Options.Analytics func(time.Time, analytics.Counts)`.
  - `workspace.localRunCounts(ctx, st *store.Store, s localrun.Summary, state string, saved bool, billed int64) analytics.Counts`.

- [ ] **Step 1: Write the failing tests.**

Add to `core/internal/localrun/output_test.go`:

```go
func TestSummaryOfAFinishedRun(t *testing.T) {
	o := NewOutputs()
	o.Create("e1", "repo", Plan{WorkflowID: ".github/workflows/ci.yml", Jobs: []JobPlan{{ID: "lint", Name: "Lint", Support: Supported}}},
		"0.2.89", false, "OrbStack")
	start := time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)
	o.Observe(events.Event{ExecutionID: "e1", ExecutionState: corev1.ExecutionState_EXECUTION_STATE_RUNNING})
	o.update("e1", func(r *run) {
		r.consume(`{"jobID":"lint","msg":"start"}`, start, false)
		r.consume(`{"jobID":"lint","jobResult":"success","msg":"done"}`, start.Add(90*time.Second), false)
	})
	if _, ok := o.Summary("e1"); ok {
		t.Fatal("a run still going has a summary")
	}
	o.Observe(events.Event{ExecutionID: "e1", ExecutionState: corev1.ExecutionState_EXECUTION_STATE_SUCCEEDED})
	s, ok := o.Summary("e1")
	if !ok || s.WorkflowID != ".github/workflows/ci.yml" || !s.WholeWorkflow || len(s.Jobs) != 1 || s.Jobs[0].State != JobSucceeded {
		t.Fatalf("summary = %+v, %v", s, ok)
	}
	if BilledJobMinutes(90*time.Second) != 2 || BilledJobMinutes(0) != 1 || BilledJobMinutes(time.Minute) != 1 {
		t.Fatal("billed job minutes do not round up to at least one")
	}
}
```

Create `core/internal/store/references_test.go`:

```go
//go:build !windows

package store

import (
	"context"
	"testing"
	"time"

	"runnir/core/internal/github"
)

func TestJobAndRunReferencesComeFromTheLatestCompletedRuns(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	older, newer := run(7, 1, "completed"), run(8, 10, "completed")
	older.Conclusion, newer.Conclusion = "success", "failure"
	newer.UpdatedAt = newer.CreatedAt.Add(6 * time.Minute)
	running := run(9, 20, "in_progress")
	_, _ = s.ApplySync(ctx, pass(0, []github.Run{running, newer, older}, true))
	at := fixedNow()
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(s.PutJobs(ctx, 7, 1, at, []github.Job{{ID: 70, Name: "Lint", Status: "completed", Conclusion: "success",
		StartedAt: at, CompletedAt: at.Add(5 * time.Minute)}}))
	must(s.PutJobs(ctx, 8, 1, at, []github.Job{
		{ID: 80, Name: "Lint", Status: "completed", Conclusion: "failure", StartedAt: at.Add(time.Hour), CompletedAt: at.Add(time.Hour + 2*time.Minute)},
		{ID: 81, Name: "Skipped", Status: "completed", Conclusion: "skipped", StartedAt: at, CompletedAt: at},
	}))
	refs, err := s.JobReferences(ctx, ".github/workflows/ci.yml", []string{"Lint", "Skipped", "Missing"})
	if err != nil || len(refs) != 1 || refs["Lint"] != 2*time.Minute {
		t.Fatalf("job references = %+v, %v", refs, err)
	}
	if refs, _ := s.JobReferences(ctx, ".github/workflows/other.yml", []string{"Lint"}); len(refs) != 0 {
		t.Fatalf("another workflow's jobs matched: %+v", refs)
	}
	wall, ok, err := s.RunReference(ctx, ".github/workflows/ci.yml")
	if err != nil || !ok || wall != 6*time.Minute {
		t.Fatalf("run reference = %v, %v, %v", wall, ok, err)
	}
	if _, ok, _ := s.RunReference(ctx, ".github/workflows/other.yml"); ok {
		t.Fatal("a run reference for a workflow with no runs")
	}
}
```

Create `core/internal/workspace/analytics_test.go`:

```go
//go:build !windows

package workspace

import (
	"context"
	"sync"
	"testing"
	"time"

	"runnir/core/internal/analytics"
	"runnir/core/internal/events"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/github"
	"runnir/core/internal/localrun"
	"runnir/core/internal/store"
)

var t0 = time.Date(2026, 10, 25, 12, 0, 0, 0, time.UTC)

func job(name string, state localrun.JobState, seconds int) localrun.JobStatus {
	return localrun.JobStatus{ID: name, Name: name, State: state, StartedAt: t0, FinishedAt: t0.Add(time.Duration(seconds) * time.Second)}
}

func TestLocalRunCountsCompareWithGitHub(t *testing.T) {
	st, err := store.Open(t.TempDir(), store.Options{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = st.Close() })
	ctx := context.Background()
	gh := github.Run{ID: 7, WorkflowID: 3, Name: "CI", RunNumber: 1, RunAttempt: 1, Event: "push", Status: "completed",
		Conclusion: "success", Branch: "main", HeadSHA: "abc", CreatedAt: t0.Add(-time.Hour), UpdatedAt: t0.Add(-time.Hour + 10*time.Minute)}
	_, _ = st.ApplySync(ctx, store.Pass{Source: store.Source{Repository: "o/r"}, At: t0, OK: true, Access: 1,
		Runs:      &store.RunsUpdate{Runs: []github.Run{gh}, Complete: true},
		Workflows: &store.WorkflowsUpdate{Workflows: []github.Workflow{{ID: 3, Name: "CI", Path: ".github/workflows/ci.yml", State: "active"}}}})
	_ = st.PutJobs(ctx, 7, 1, t0, []github.Job{{ID: 70, Name: "lint", Status: "completed", Conclusion: "success",
		StartedAt: t0.Add(-time.Hour), CompletedAt: t0.Add(-time.Hour + 4*time.Minute + time.Second)}})

	summary := localrun.Summary{WorkflowID: ".github/workflows/ci.yml", WholeWorkflow: true, StartedAt: t0, FinishedAt: t0.Add(150 * time.Second),
		Jobs: []localrun.JobStatus{job("lint", localrun.JobSucceeded, 61), job("test", localrun.JobFailed, 120),
			job("deploy", localrun.JobCancelled, 5), {ID: "macos", Name: "macos", State: localrun.JobUnsupported}}}
	got := localRunCounts(ctx, st, summary, store.LocalFailed, true, 4)
	want := analytics.Counts{
		analytics.LocalRuns: 1, analytics.LocalBilledMinutes: 4,
		analytics.LocalJobsSucceeded: 1, analytics.LocalJobsFailed: 1, analytics.LocalJobsCancelled: 1,
		analytics.LocalJobSeconds: 186,
		// lint: 4m 1s on GitHub → 5; locally 1m 1s → 2.
		analytics.GHRefJobsMatched: 1, analytics.GHRefBilledMinutes: 5, analytics.LocalBilledMinutesMatched: 2,
		analytics.LocalRunsCompleted: 1, analytics.LocalRunWallSeconds: 150,
		analytics.GHRefRunsMatched: 1, analytics.GHRefRunWallSeconds: 600,
	}
	if len(got) != len(want) {
		t.Fatalf("counts = %+v, want %+v", got, want)
	}
	for name, value := range want {
		if got[name] != value {
			t.Fatalf("%s = %d, want %d (all: %+v)", name, got[name], value, got)
		}
	}
	// One job of a workflow, cancelled, nothing saved: only its jobs count.
	one := localrun.Summary{WorkflowID: ".github/workflows/ci.yml", Jobs: []localrun.JobStatus{job("lint", localrun.JobCancelled, 3)}}
	if got := localRunCounts(ctx, st, one, store.LocalCancelled, false, 0); len(got) != 2 || got[analytics.LocalJobsCancelled] != 1 {
		t.Fatalf("one cancelled job = %+v", got)
	}
}

func TestFinishedLocalRunsAreCountedForAnalytics(t *testing.T) {
	_, accounts := newFake(t)
	var mu sync.Mutex
	var counted []analytics.Counts
	m := New(Options{DataDir: t.TempDir(), Intervals: testIntervals(),
		BilledMinutes: func(string) int64 { return 2 },
		RunSummary: func(id string) (localrun.Summary, bool) {
			return localrun.Summary{WorkflowID: ".github/workflows/x.yml", Jobs: []localrun.JobStatus{job("a", localrun.JobSucceeded, 70)}}, id == "exec_1"
		},
		Analytics: func(_ time.Time, c analytics.Counts) { mu.Lock(); counted = append(counted, c); mu.Unlock() }})
	t.Cleanup(m.Shutdown)
	_, _ = m.Attach(wsA, "repo_1", fixedResolver(accounts, "o", "r"))
	m.RecordLocalRun("repo_1", store.LocalRun{ExecutionID: "exec_1", StartedAt: t0, State: store.LocalQueued})
	m.ObserveExecution(events.Event{ExecutionID: "exec_1", ExecutionState: corev1.ExecutionState_EXECUTION_STATE_SUCCEEDED, At: t0})
	m.ObserveExecution(events.Event{ExecutionID: "exec_1", ExecutionState: corev1.ExecutionState_EXECUTION_STATE_SUCCEEDED, At: t0})
	m.recorder.flush()
	mu.Lock()
	defer mu.Unlock()
	if len(counted) != 1 || counted[0][analytics.LocalRuns] != 1 || counted[0][analytics.LocalBilledMinutes] != 2 ||
		counted[0][analytics.LocalJobsSucceeded] != 1 || counted[0][analytics.LocalJobSeconds] != 70 {
		t.Fatalf("counted = %+v, want one run once", counted)
	}
}
```

- [ ] **Step 2: Run them to see them fail.**

Run (from `core/`): `go test ./internal/localrun/ ./internal/store/ ./internal/workspace/`
Expected: FAIL to compile: `o.Summary undefined`, `s.JobReferences undefined`, `undefined: localRunCounts`, `unknown field RunSummary`.

- [ ] **Step 3: Add `Summary` and `BilledJobMinutes`** to `core/internal/localrun/output.go`, replacing `billedMinutes`:

```go
// Summary is a finished run, for analytics: its workflow, whether every job
// of it was asked for, its span and its jobs.
type Summary struct {
	WorkflowID    string
	WholeWorkflow bool
	StartedAt     time.Time
	FinishedAt    time.Time
	Jobs          []JobStatus
}

// Summary returns a finished run's summary; false while it runs or once it
// was forgotten.
func (o *Outputs) Summary(executionID string) (Summary, bool) {
	o.mu.Lock()
	defer o.mu.Unlock()
	r := o.runs[executionID]
	if r == nil || r.snap.Phase != PhaseFinished {
		return Summary{}, false
	}
	return Summary{WorkflowID: r.snap.Plan.WorkflowID, WholeWorkflow: r.snap.Plan.JobID == "",
		StartedAt: r.snap.StartedAt, FinishedAt: r.snap.FinishedAt, Jobs: append([]JobStatus(nil), r.snap.Jobs...)}, true
}

// BilledJobMinutes is how GitHub bills a job on a hosted runner: its time
// rounded up to a whole minute, at least one.
func BilledJobMinutes(d time.Duration) int64 {
	return max(int64((max(d, 0)+time.Minute-1)/time.Minute), 1)
}

func billedMinutes(jobs []JobStatus) int64 {
	var total int64
	for _, job := range jobs {
		if (job.State != JobSucceeded && job.State != JobFailed) || job.StartedAt.IsZero() || job.FinishedAt.IsZero() {
			continue
		}
		total += BilledJobMinutes(job.FinishedAt.Sub(job.StartedAt))
	}
	return total
}
```

- [ ] **Step 4: Write `core/internal/store/references.go`.**

```go
package store

import (
	"context"
	"database/sql"
	"errors"
	"time"
)

// JobReferences finds, for each name, the GitHub duration of the latest
// completed job with that name (succeeded or failed) in a cached run of the
// workflow at path. Names without one are absent.
func (s *Store) JobReferences(ctx context.Context, workflowPath string, names []string) (map[string]time.Duration, error) {
	out := map[string]time.Duration{}
	if len(names) == 0 {
		return out, nil
	}
	want := map[string]bool{}
	for _, name := range names {
		want[name] = true
	}
	rows, err := s.db.QueryContext(ctx, `SELECT j.name, j.started_at, j.completed_at FROM run_jobs j
JOIN runs r ON r.id = j.run_id
JOIN remote_workflows w ON w.id = r.workflow_id
WHERE w.path = ? AND j.status = 'completed' AND j.conclusion IN ('success', 'failure')
	AND j.started_at > 0 AND j.completed_at >= j.started_at
ORDER BY j.completed_at DESC, j.id DESC`, workflowPath)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var name string
		var started, completed int64
		if err := rows.Scan(&name, &started, &completed); err != nil {
			return nil, err
		}
		if _, seen := out[name]; want[name] && !seen {
			out[name] = time.Duration(completed-started) * time.Millisecond
		}
	}
	return out, rows.Err()
}

// RunReference is the latest completed run (succeeded or failed) of the
// workflow at path: from its creation to its last update, queue included.
func (s *Store) RunReference(ctx context.Context, workflowPath string) (time.Duration, bool, error) {
	var created, updated int64
	err := s.db.QueryRowContext(ctx, `SELECT r.created_at, r.updated_at FROM runs r
JOIN remote_workflows w ON w.id = r.workflow_id
WHERE w.path = ? AND r.status = 'completed' AND r.conclusion IN ('success', 'failure') AND r.updated_at >= r.created_at
ORDER BY r.created_at DESC, r.id DESC LIMIT 1`, workflowPath).Scan(&created, &updated)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return time.Duration(updated-created) * time.Millisecond, true, nil
}
```

- [ ] **Step 5: Write `core/internal/workspace/analytics.go`.**

```go
package workspace

import (
	"context"
	"time"

	"runnir/core/internal/analytics"
	"runnir/core/internal/localrun"
	"runnir/core/internal/store"
)

// localRunCounts are a finished local run's minute counters (the metrics
// table in docs/product/analytics-and-crash-reporting.md). saved and billed
// are B31's: whether the run was added to the Saved total, and with how
// many minutes. Only names and durations are read; nothing of the
// repository is counted.
func localRunCounts(ctx context.Context, st *store.Store, s localrun.Summary, state string, saved bool, billed int64) analytics.Counts {
	c := analytics.Counts{}
	if saved {
		c[analytics.LocalRuns], c[analytics.LocalBilledMinutes] = 1, billed
	}
	var ended []localrun.JobStatus
	var names []string
	for _, job := range s.Jobs {
		switch job.State {
		case localrun.JobSucceeded:
			c[analytics.LocalJobsSucceeded]++
		case localrun.JobFailed:
			c[analytics.LocalJobsFailed]++
		case localrun.JobCancelled:
			c[analytics.LocalJobsCancelled]++
		default:
			continue
		}
		if job.StartedAt.IsZero() || job.FinishedAt.Before(job.StartedAt) {
			continue
		}
		c[analytics.LocalJobSeconds] += int64(job.FinishedAt.Sub(job.StartedAt) / time.Second)
		if job.State != localrun.JobCancelled {
			ended = append(ended, job)
			names = append(names, job.Name)
		}
	}
	if refs, err := st.JobReferences(ctx, s.WorkflowID, names); err == nil {
		for _, job := range ended {
			if ref, ok := refs[job.Name]; ok {
				c[analytics.GHRefJobsMatched]++
				c[analytics.GHRefBilledMinutes] += localrun.BilledJobMinutes(ref)
				c[analytics.LocalBilledMinutesMatched] += localrun.BilledJobMinutes(job.FinishedAt.Sub(job.StartedAt))
			}
		}
	}
	ran := (state == store.LocalSucceeded || state == store.LocalFailed) && s.WholeWorkflow &&
		!s.StartedAt.IsZero() && !s.FinishedAt.Before(s.StartedAt)
	if ran {
		c[analytics.LocalRunsCompleted]++
		c[analytics.LocalRunWallSeconds] += int64(s.FinishedAt.Sub(s.StartedAt) / time.Second)
		if wall, ok, err := st.RunReference(ctx, s.WorkflowID); err == nil && ok {
			c[analytics.GHRefRunsMatched]++
			c[analytics.GHRefRunWallSeconds] += int64(wall / time.Second)
		}
	}
	for name, value := range c {
		if value == 0 {
			delete(c, name)
		}
	}
	return c
}
```

- [ ] **Step 6: Hook it into `ObserveExecution`.** Add to `workspace.Options` in `runtimes.go`:

```go
	// RunSummary returns a finished local run's jobs and span; with
	// Analytics, its minute counters are added when it ends. nil counts
	// nothing.
	RunSummary func(executionID string) (localrun.Summary, bool)
	// Analytics adds counts to the analytics ledger; nil drops them.
	Analytics func(at time.Time, counts analytics.Counts)
```

(imports: `"runnir/core/internal/analytics"`, `"runnir/core/internal/localrun"`). In `ObserveExecution`, replace the block from `// Read now: the run's output is forgotten after later runs.` to the end of `m.recorder.add(...)` with:

```go
	// Read now: the run's output is forgotten after later runs.
	var minutes int64
	if (state == store.LocalSucceeded || state == store.LocalFailed) && m.opts.BilledMinutes != nil {
		minutes = m.opts.BilledMinutes(e.ExecutionID)
	}
	var summary localrun.Summary
	summarized := false
	if store.LocalTerminal(state) && m.opts.RunSummary != nil && m.opts.Analytics != nil {
		summary, summarized = m.opts.RunSummary(e.ExecutionID)
	}
	m.recorder.add(func() {
		ctx := context.Background()
		_ = rt.cfg.store.UpdateLocalRun(ctx, e.ExecutionID, state, at, e.Message)
		saved := minutes > 0 && rt.cfg.store.AddSaving(ctx, store.SavingLocalRuns, minutes, at) == nil
		if saved {
			rt.publish()
		}
		if summarized {
			m.opts.Analytics(at, localRunCounts(ctx, rt.cfg.store, summary, state, saved, minutes))
		}
	})
```

`store.LocalTerminal` does not exist yet: export the existing `terminal(state string) bool` in `core/internal/store/localruns.go` by adding

```go
// LocalTerminal reports a local run state that ends the run.
func LocalTerminal(state string) bool { return terminal(state) }
```

- [ ] **Step 7: Pass the hooks from the server.** In `server.go`, replace the `workspaces := workspace.New(...)` line with:

```go
	workspaces := workspace.New(workspace.Options{DataDir: options.DataDir, Publish: bus.Publish, BilledMinutes: outputs.BilledMinutes,
		RunSummary: outputs.Summary, Analytics: func(at time.Time, counts analytics.Counts) { _ = ledger.Add(at, counts) }})
```

- [ ] **Step 8: Run the tests.**

Run (from `core/`): `go test ./... && go vet ./... && go build ./...`
Expected: every package `ok`, including `TestFinishedLocalRunsAddTheirBilledMinutes` unchanged.

- [ ] **Step 9: Commit.**

```bash
git add core/internal
git commit -m "Core: minute counters for local runs, compared with GitHub's latest runs (B21)"
```

---

### Task 6: Cancel And Concurrency Counters

**Files:**
- Modify: `core/internal/scanner/concurrency.go` (export the check), `core/internal/store/schema.go`, `core/internal/workspace/runtime.go` (config, `pass`), `core/internal/workspace/runtimes.go` (`Attach` passes `analytics`), `core/internal/server/runs.go` (`ConfirmRunAction`), `core/internal/server/files.go` (`SaveWorkflowFile`), `core/internal/server/analytics.go`
- Create: `core/internal/store/cancels.go`, `core/internal/workspace/estimates.go`
- Test: `core/internal/scanner/concurrency_test.go`, `core/internal/store/cancels_test.go`, `core/internal/workspace/estimates_test.go`

**Interfaces:**
- Consumes: `changes.Analysis.SupersededBy`, `Runtime.Snapshot`, `analytics.Counts` and names.
- Produces:
  - `scanner.HasSuggestedConcurrency(content string) bool`.
  - `store.ConcurrencySave{WorkflowPath string; SavedAt time.Time}`; `(*Store).AddConcurrencySave(ctx, path string, at time.Time) error`, `ConcurrencySaves(ctx) ([]ConcurrencySave, error)`, `MarkCountedCancels(ctx, ids []int64) (map[int64]bool, error)`.
  - `workspace.medianDuration`, `estimateMinutes`, `cancelEstimate`, `concurrencyCancels`; `(*Runtime).CancelEstimate(ctx, runID int64, now time.Time) (bool, int64, error)`, `NoteConcurrencySaved(ctx, path string, at time.Time) error`, `countConcurrencyCancels()`.

- [ ] **Step 1: Write the failing tests.**

Add to `core/internal/scanner/concurrency_test.go`:

```go
func TestTheSuggestedBlockIsRecognizedInSavedText(t *testing.T) {
	edit := InsertConcurrency("on: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n")
	if edit.Refusal != ConcurrencyInserted || !HasSuggestedConcurrency(edit.Content) {
		t.Fatalf("inserted block not recognized: %+v", edit)
	}
	crlf := InsertConcurrency("on: push\r\njobs:\r\n  a:\r\n    runs-on: ubuntu-latest\r\n")
	if !HasSuggestedConcurrency(crlf.Content) {
		t.Fatal("CRLF text not recognized")
	}
	if HasSuggestedConcurrency("concurrency:\n  group: ci\njobs: {}\n") {
		t.Fatal("a hand-written block counted as the suggestion")
	}
}
```

Create `core/internal/store/cancels_test.go`:

```go
//go:build !windows

package store

import (
	"context"
	"testing"
	"time"
)

func TestConcurrencySavesKeepTheFirstAndCancelsAreCountedOnce(t *testing.T) {
	s := openTest(t, t.TempDir())
	ctx := context.Background()
	first := fixedNow()
	if err := s.AddConcurrencySave(ctx, ".github/workflows/ci.yml", first); err != nil {
		t.Fatal(err)
	}
	_ = s.AddConcurrencySave(ctx, ".github/workflows/ci.yml", first.Add(time.Hour))
	saves, err := s.ConcurrencySaves(ctx)
	if err != nil || len(saves) != 1 || !saves[0].SavedAt.Equal(first) {
		t.Fatalf("saves = %+v, %v", saves, err)
	}
	fresh, err := s.MarkCountedCancels(ctx, []int64{7, 8})
	if err != nil || !fresh[7] || !fresh[8] {
		t.Fatalf("first mark = %+v, %v", fresh, err)
	}
	fresh, _ = s.MarkCountedCancels(ctx, []int64{8, 9})
	if fresh[8] || !fresh[9] {
		t.Fatalf("second mark = %+v, want only 9 new", fresh)
	}
	// Clear Cache keeps both: they are this Mac's, not GitHub's.
	if err := s.ClearCache(ctx); err != nil {
		t.Fatal(err)
	}
	if saves, _ := s.ConcurrencySaves(ctx); len(saves) != 1 {
		t.Fatal("Clear Cache removed a concurrency save")
	}
	if fresh, _ := s.MarkCountedCancels(ctx, []int64{7}); fresh[7] {
		t.Fatal("Clear Cache forgot a counted cancel")
	}
}
```

Create `core/internal/workspace/estimates_test.go`:

```go
package workspace

import (
	"testing"
	"time"

	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

func ghRun(id, workflow int64, conclusion string, created time.Time, minutes int) github.Run {
	return github.Run{ID: id, WorkflowID: workflow, Status: "completed", Conclusion: conclusion,
		CreatedAt: created, UpdatedAt: created.Add(time.Duration(minutes) * time.Minute)}
}

func TestCancelEstimatesUseTheMedianSuccessfulRun(t *testing.T) {
	base := time.Date(2026, 10, 25, 10, 0, 0, 0, time.UTC)
	runs := []github.Run{
		{ID: 9, WorkflowID: 3, Status: "in_progress", CreatedAt: base.Add(3 * time.Hour)},
		ghRun(6, 3, "success", base.Add(2*time.Hour), 10),
		ghRun(5, 3, "failure", base.Add(time.Hour), 2),
		ghRun(4, 3, "success", base, 6),
		ghRun(3, 3, "success", base.Add(-time.Hour), 8),
		ghRun(2, 4, "success", base, 60),
	}
	if median, ok := medianDuration(runs, 3); !ok || median != 8*time.Minute {
		t.Fatalf("median = %v, %v", median, ok)
	}
	if _, ok := medianDuration(runs, 99); ok {
		t.Fatal("a median for a workflow without runs")
	}
	if estimateMinutes(8*time.Minute, 2*time.Minute+time.Second) != 6 || estimateMinutes(8*time.Minute, 9*time.Minute) != 0 {
		t.Fatal("estimates do not round up or go below zero")
	}
	superseded := map[int64]int64{9: 10}
	if ok, minutes := cancelEstimate(runs, superseded, 9, base.Add(3*time.Hour+3*time.Minute)); !ok || minutes != 5 {
		t.Fatalf("superseded cancel = %v, %d", ok, minutes)
	}
	if ok, _ := cancelEstimate(runs, superseded, 6, base); ok {
		t.Fatal("a run that is not superseded counted")
	}
}

func TestConcurrencyCancelsCountRunsAfterTheSaveOnly(t *testing.T) {
	saved := time.Date(2026, 10, 25, 10, 0, 0, 0, time.UTC)
	cancelled := func(id int64, created time.Time, minutes int) github.Run {
		return ghRun(id, 3, "cancelled", created, minutes)
	}
	runs := []github.Run{
		cancelled(20, saved.Add(time.Hour), 3),       // after the save, superseded: counted, 10-3 = 7
		cancelled(21, saved.Add(2*time.Hour), 1),     // after the save, not superseded: not counted
		cancelled(19, saved.Add(-time.Hour), 1),      // before the save: not counted
		ghRun(18, 3, "success", saved.Add(-2*time.Hour), 10),
		{ID: 30, WorkflowID: 4, Status: "completed", Conclusion: "cancelled", CreatedAt: saved.Add(time.Hour)}, // another workflow
	}
	workflows := []github.Workflow{{ID: 3, Path: ".github/workflows/ci.yml"}, {ID: 4, Path: ".github/workflows/other.yml"}}
	saves := []store.ConcurrencySave{{WorkflowPath: ".github/workflows/ci.yml", SavedAt: saved}}
	superseded := map[int64]int64{20: 22, 19: 20, 30: 31}
	got := concurrencyCancels(saves, runs, workflows, superseded)
	if len(got) != 1 || got[0].RunID != 20 || got[0].Minutes != 7 {
		t.Fatalf("cancels = %+v", got)
	}
}
```

- [ ] **Step 2: Run them to see them fail.**

Run (from `core/`): `go test ./internal/scanner/ ./internal/store/ ./internal/workspace/`
Expected: FAIL to compile: `undefined: HasSuggestedConcurrency`, `s.AddConcurrencySave undefined`, `undefined: medianDuration`.

- [ ] **Step 3: Export the check in `concurrency.go`.** Split the block's group line into its own constant and add the function:

```go
// concurrencyGroup is the block's group line; no hand-written block has it.
const concurrencyGroup = "  group: ${{ github.workflow }}-${{ github.event.pull_request.number || (github.event_name == 'push' && github.ref != format('refs/heads/{0}', github.event.repository.default_branch) && github.ref) || github.run_id }}"

// concurrencyBlock is what InsertConcurrency adds. Pull requests group by
// number and pushes to other branches than the default by ref, so a newer
// commit cancels the older run in progress; everything else gets a group
// of its own (run_id) and is never cancelled or queued.
const concurrencyBlock = "# Newer commits on a pull request or branch cancel its older runs; runs on the default branch, scheduled and manual runs are never cancelled.\n" +
	"concurrency:\n" +
	concurrencyGroup + "\n" +
	"  cancel-in-progress: true"

// HasSuggestedConcurrency reports text holding the block InsertConcurrency
// adds, whatever its line endings.
func HasSuggestedConcurrency(content string) bool { return strings.Contains(content, concurrencyGroup) }
```

- [ ] **Step 4: Add the tables** to the end of `schemaV1` in `core/internal/store/schema.go` (in place, as B31 did; a development database made before keeps working without them and counts nothing until Settings › Storage deletes it):

```sql
-- local: workflow files this Mac saved with Runnir's suggested concurrency
-- block (the first save), for the analytics of runs that block cancels.
CREATE TABLE concurrency_saves (
	workflow_path TEXT PRIMARY KEY,
	saved_at INTEGER NOT NULL
);
-- local: runs already counted as cancelled by that block; the newest
-- 10,000 ids are kept. Clear Cache keeps them, so a sync after it does not
-- count the same runs again.
CREATE TABLE counted_cancels (
	run_id INTEGER PRIMARY KEY
);
```

- [ ] **Step 5: Write `core/internal/store/cancels.go`.**

```go
package store

import (
	"context"
	"time"
)

// ConcurrencySave is a workflow file this Mac first saved with Runnir's
// suggested concurrency block.
type ConcurrencySave struct {
	WorkflowPath string
	SavedAt      time.Time
}

// AddConcurrencySave keeps the first save of the block into a workflow
// file; later saves change nothing.
func (s *Store) AddConcurrencySave(ctx context.Context, workflowPath string, at time.Time) error {
	_, err := s.db.ExecContext(ctx, `INSERT INTO concurrency_saves (workflow_path, saved_at) VALUES (?, ?)
ON CONFLICT (workflow_path) DO NOTHING`, workflowPath, millis(at))
	return err
}

func (s *Store) ConcurrencySaves(ctx context.Context) ([]ConcurrencySave, error) {
	rows, err := s.db.QueryContext(ctx, `SELECT workflow_path, saved_at FROM concurrency_saves ORDER BY workflow_path`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []ConcurrencySave
	for rows.Next() {
		var v ConcurrencySave
		var at int64
		if err := rows.Scan(&v.WorkflowPath, &at); err != nil {
			return nil, err
		}
		v.SavedAt = fromMillis(at)
		out = append(out, v)
	}
	return out, rows.Err()
}

// MarkCountedCancels records runs counted as cancelled by the block and
// returns those not recorded before.
func (s *Store) MarkCountedCancels(ctx context.Context, ids []int64) (map[int64]bool, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	fresh := map[int64]bool{}
	for _, id := range ids {
		result, err := tx.ExecContext(ctx, `INSERT OR IGNORE INTO counted_cancels (run_id) VALUES (?)`, id)
		if err != nil {
			_ = tx.Rollback()
			return nil, err
		}
		if n, _ := result.RowsAffected(); n == 1 {
			fresh[id] = true
		}
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM counted_cancels WHERE run_id NOT IN
(SELECT run_id FROM counted_cancels ORDER BY run_id DESC LIMIT 10000)`); err != nil {
		_ = tx.Rollback()
		return nil, err
	}
	return fresh, tx.Commit()
}
```

- [ ] **Step 6: Write `core/internal/workspace/estimates.go`.**

```go
package workspace

import (
	"context"
	"slices"
	"time"

	"runnir/core/internal/analytics"
	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

// medianDuration is the median time from creation to last update of the
// workflow's newest 20 successful runs; runs are newest first.
func medianDuration(runs []github.Run, workflowID int64) (time.Duration, bool) {
	var durations []time.Duration
	for _, r := range runs {
		if r.WorkflowID != workflowID || r.Status != "completed" || r.Conclusion != "success" || r.UpdatedAt.Before(r.CreatedAt) {
			continue
		}
		durations = append(durations, r.UpdatedAt.Sub(r.CreatedAt))
		if len(durations) == 20 {
			break
		}
	}
	if len(durations) == 0 {
		return 0, false
	}
	slices.Sort(durations)
	return durations[len(durations)/2], true
}

// estimateMinutes is what was left of a typical run when one stopped after
// ran, rounded up; never below zero.
func estimateMinutes(median, ran time.Duration) int64 {
	left := median - ran
	if left <= 0 {
		return 0
	}
	return int64((left + time.Minute - 1) / time.Minute)
}

// cancelEstimate says whether a run is superseded and, if so, the minutes
// cancelling it at now saves.
func cancelEstimate(runs []github.Run, superseded map[int64]int64, runID int64, now time.Time) (bool, int64) {
	if superseded[runID] == 0 {
		return false, 0
	}
	for _, r := range runs {
		if r.ID != runID {
			continue
		}
		if median, ok := medianDuration(runs, r.WorkflowID); ok {
			return true, estimateMinutes(median, now.Sub(r.CreatedAt))
		}
		break
	}
	return true, 0
}

type concurrencyCancel struct {
	RunID   int64
	Minutes int64
}

// concurrencyCancels finds runs the block this Mac saved cancelled: runs of
// that workflow created after the save that GitHub ended cancelled while
// superseded.
func concurrencyCancels(saves []store.ConcurrencySave, runs []github.Run, workflows []github.Workflow, superseded map[int64]int64) []concurrencyCancel {
	savedAt := map[int64]time.Time{}
	for _, w := range workflows {
		for _, save := range saves {
			if save.WorkflowPath == w.Path {
				savedAt[w.ID] = save.SavedAt
			}
		}
	}
	var out []concurrencyCancel
	for _, r := range runs {
		at, ok := savedAt[r.WorkflowID]
		if !ok || !r.CreatedAt.After(at) || r.Status != "completed" || r.Conclusion != "cancelled" || superseded[r.ID] == 0 {
			continue
		}
		var minutes int64
		if median, ok := medianDuration(runs, r.WorkflowID); ok {
			minutes = estimateMinutes(median, r.UpdatedAt.Sub(r.CreatedAt))
		}
		out = append(out, concurrencyCancel{RunID: r.ID, Minutes: minutes})
	}
	return out
}

// CancelEstimate is cancelEstimate over this workspace's cache.
func (r *Runtime) CancelEstimate(ctx context.Context, runID int64, now time.Time) (bool, int64, error) {
	snap, err := r.Snapshot(ctx, 0)
	if err != nil {
		return false, 0, err
	}
	superseded, minutes := cancelEstimate(snap.Runs, snap.Analysis.SupersededBy, runID, now)
	return superseded, minutes, nil
}

// NoteConcurrencySaved remembers that this Mac saved the suggested block
// into a workflow file, so the runs it cancels are counted here only.
func (r *Runtime) NoteConcurrencySaved(ctx context.Context, workflowPath string, at time.Time) error {
	return r.cfg.store.AddConcurrencySave(ctx, workflowPath, at)
}

// countConcurrencyCancels counts, once each, runs the saved block
// cancelled. Called after a pass that reached GitHub.
func (r *Runtime) countConcurrencyCancels() {
	if r.cfg.analytics == nil {
		return
	}
	saves, err := r.cfg.store.ConcurrencySaves(r.ctx)
	if err != nil || len(saves) == 0 {
		return
	}
	snap, err := r.Snapshot(r.ctx, 0)
	if err != nil {
		return
	}
	found := concurrencyCancels(saves, snap.Runs, snap.Workflows, snap.Analysis.SupersededBy)
	if len(found) == 0 {
		return
	}
	ids := make([]int64, len(found))
	for i, f := range found {
		ids[i] = f.RunID
	}
	fresh, err := r.cfg.store.MarkCountedCancels(r.ctx, ids)
	if err != nil {
		return
	}
	counts := analytics.Counts{}
	for _, f := range found {
		if fresh[f.RunID] {
			counts[analytics.ConcurrencyCancels]++
			counts[analytics.ConcurrencyMinutesEst] += f.Minutes
		}
	}
	if len(counts) > 0 {
		r.cfg.analytics(r.cfg.now(), counts)
	}
}
```

- [ ] **Step 7: Wire the runtime.** In `runtime.go` add to `config`:

```go
	// analytics adds counts to the ledger; nil drops them.
	analytics func(time.Time, analytics.Counts)
```

(import `"runnir/core/internal/analytics"`). In `runtimes.go` `Attach`, add `analytics: m.opts.Analytics` to the `config{...}` literal. In `Runtime.pass`, inside `if r.ctx.Err() == nil {`, after the `if p.OK && target != nil { ... }` block, add:

```go
		if p.OK {
			r.countConcurrencyCancels()
		}
```

- [ ] **Step 8: Count in the server.** Add to `core/internal/server/analytics.go`:

```go
// countSupersededCancel counts a cancel GitHub accepted for a superseded
// run, with the minutes it saved by the workflow's median run.
func (s *service) countSupersededCancel(ctx context.Context, repositoryID string, runID int64, at time.Time) {
	if s.analytics == nil || s.workspaces == nil {
		return
	}
	rt, ok := s.workspaces.ForRepository(repositoryID)
	if !ok {
		return
	}
	superseded, minutes, err := rt.CancelEstimate(ctx, runID, at)
	if err != nil || !superseded {
		return
	}
	_ = s.analytics.Add(at, analytics.Counts{analytics.SupersededCancels: 1, analytics.SupersededCancelMinutesEst: minutes})
}

// noteConcurrencySaved counts a save that added Runnir's suggested
// concurrency block to a workflow file that had none.
func (s *service) noteConcurrencySaved(ctx context.Context, repositoryID, workflowPath string, at time.Time) {
	if s.analytics == nil || s.workspaces == nil {
		return
	}
	rt, ok := s.workspaces.ForRepository(repositoryID)
	if !ok || rt.NoteConcurrencySaved(ctx, workflowPath, at) != nil {
		return
	}
	_ = s.analytics.Add(at, analytics.Counts{analytics.ConcurrencyInserted: 1})
}
```

In `runs.go` `ConfirmRunAction`, before the final `return out, nil`, add:

```go
	if sendErr == nil && prepared.Action == corev1.RunAction_RUN_ACTION_CANCEL {
		s.countSupersededCancel(ctx, prepared.RepositoryID, prepared.RunID, acceptedAt)
	}
```

In `files.go` `SaveWorkflowFile`, inside `if !result.Conflict {` after the refresh, add:

```go
		if !workflow.Concurrency && scanner.HasSuggestedConcurrency(request.GetContent()) {
			s.noteConcurrencySaved(ctx, info.ID, workflow.ID, time.Now())
		}
```

(import `"time"` in `files.go`).

- [ ] **Step 9: Run every Core check.**

Run (from `core/`): `go test ./... && go vet ./... && go build ./...`
Expected: every package `ok`, no vet output.

- [ ] **Step 10: Commit.**

```bash
git add core/internal
git commit -m "Core: count superseded cancels and runs the saved concurrency block cancels (B21)"
```

---

### Task 7: Analytics In The App's IPC And CoreHub

**Files:**
- Modify: `apps/macos/Runnir/IPC/CoreWorkspaceModels.swift` (models), `apps/macos/Runnir/IPC/CoreService.swift` (protocol), `apps/macos/Runnir/IPC/GRPCCoreService.swift` (calls), `apps/macos/Runnir/IPC/CoreHub.swift` (state, load, set, record)
- Modify: `apps/macos/RunnirTests/CoreHubTests.swift` (`FakeCore`), `apps/macos/RunnirTests/CoreProcessSupervisorTests.swift` (`FakeService`)
- Create: `apps/macos/RunnirTests/AnalyticsTests.swift`, and `apps/macos/Runnir/Features/Settings/PrivacySettings.swift` with only `import SwiftUI` (Task 8 fills it)
- Modify: `apps/macos/Runnir.xcodeproj/project.pbxproj` (the two new files)

**Interfaces:**
- Consumes: the generated Swift types of Task 1.
- Produces:
  - `enum CoreAnalyticsLevel: CaseIterable { case off, basic, full }`, `struct CoreAnalyticsCounter { name: String; value: UInt64 }`, `struct CoreAnalytics { level; promptAnswered; sendingAvailable; persistent; analyticsID: String?; pending: [CoreAnalyticsCounter] }`.
  - `enum UsageEvent: Int, CaseIterable` (raw values are the proto numbers).
  - `CoreServicing.analytics()`, `setAnalyticsLevel(_:fromPrompt:)`, `recordUsage(_:)`.
  - `CoreHub.analytics: CoreAnalytics?`, `loadAnalytics() async`, `setAnalyticsLevel(_:fromPrompt:) async -> Bool`, `recordUsage(_:)`.

- [ ] **Step 1: Add the models** at the end of `CoreWorkspaceModels.swift`:

```swift
/// Settings › Privacy's levels (docs/product/analytics-and-crash-reporting.md).
enum CoreAnalyticsLevel: Equatable, Sendable, CaseIterable {
    /// Nothing is counted or sent.
    case off
    /// first_launch and saved-minute counts, without an id.
    case basic
    /// Basic plus section and action counts, with a random analytics id.
    case full
}

struct CoreAnalyticsCounter: Equatable, Sendable {
    let name: String
    let value: UInt64
}

/// The Core's analytics ledger, as `GetAnalytics` reports it.
struct CoreAnalytics: Equatable, Sendable {
    let level: CoreAnalyticsLevel
    let promptAnswered: Bool
    /// A Release build with the ledger on disk: batches are sent.
    let sendingAvailable: Bool
    /// The ledger is on disk; without it there is no prompt and no level to choose.
    let persistent: Bool
    /// Set only at `.full`.
    let analyticsID: String?
    /// Counts waiting to be sent, by name.
    let pending: [CoreAnalyticsCounter]
}

/// A section or action counted at the Usage analytics level. Raw values are
/// the proto's `UsageEvent` numbers.
enum UsageEvent: Int, CaseIterable, Sendable {
    case screenOverview = 1, screenWorkflows, screenRuns, screenWorkspace, screenWorkspaceEditor, screenWorkspaceLocalRun,
         screenManagerWorkspaces, screenManagerGithub, screenSettingsAccount, screenSettingsRuns, screenSettingsNotifications,
         screenSettingsPullRequests, screenSettingsTools, screenSettingsStorage, screenSettingsPrivacy, screenMenuBar,
         actionRunLocal, actionDispatch, actionCancelRun, actionRerun, actionSaveWorkflow, actionCreateWorkflow,
         actionRenameWorkflow, actionValidate, actionOpenLog, actionSaveLog, actionSavePreset, actionApplyPreset,
         actionInsertConcurrency, actionFavorite, actionOpenOnGithub, actionReportBug
}
```

- [ ] **Step 2: Extend `CoreServicing`** in `CoreService.swift`, before `func events(`:

```swift
    /// The analytics level, whether the consent prompt was answered and what
    /// waits to be sent.
    func analytics() async throws -> CoreAnalytics
    /// Changes the level; `fromPrompt` marks the consent prompt answered.
    func setAnalyticsLevel(_ level: CoreAnalyticsLevel, fromPrompt: Bool) async throws -> CoreAnalytics
    /// Counts one section or action; the Core ignores it below `.full`.
    func recordUsage(_ event: UsageEvent) async throws
```

- [ ] **Step 3: Implement them** in `GRPCCoreService.swift`, after `setStoragePreferences`:

```swift
    func analytics() async throws -> CoreAnalytics {
        let response = try await call { try await client.getAnalytics(.init(), options: Self.options(Self.callTimeout)) }
        return Self.map(response)
    }

    func setAnalyticsLevel(_ level: CoreAnalyticsLevel, fromPrompt: Bool) async throws -> CoreAnalytics {
        let response = try await call {
            try await client.setAnalyticsLevel(.with {
                $0.level = Self.map(level)
                $0.fromPrompt = fromPrompt
            }, options: Self.options(Self.callTimeout))
        }
        return Self.map(response)
    }

    func recordUsage(_ event: UsageEvent) async throws {
        _ = try await call {
            try await client.recordUsage(.with { $0.event = Runnir_Core_V1_UsageEvent(rawValue: event.rawValue) ?? .unspecified },
                                         options: Self.options(Self.callTimeout))
        }
    }

    static func map(_ response: Runnir_Core_V1_Analytics) -> CoreAnalytics {
        let level: CoreAnalyticsLevel = switch response.level {
        case .off: .off
        case .full: .full
        default: .basic
        }
        return CoreAnalytics(level: level, promptAnswered: response.promptAnswered, sendingAvailable: response.sendingAvailable,
                             persistent: response.persistent, analyticsID: response.analyticsID.isEmpty ? nil : response.analyticsID,
                             pending: response.pending.map { CoreAnalyticsCounter(name: $0.name, value: $0.value) })
    }

    static func map(_ level: CoreAnalyticsLevel) -> Runnir_Core_V1_AnalyticsLevel {
        switch level {
        case .off: .off
        case .basic: .basic
        case .full: .full
        }
    }
```

- [ ] **Step 4: Teach the fakes.** In `CoreHubTests.swift`'s `FakeCore`, next to the storage members:

```swift
    private var _analytics = CoreAnalytics(level: .basic, promptAnswered: false, sendingAvailable: true, persistent: true,
                                           analyticsID: nil, pending: [])
    private var _levelCalls: [(level: CoreAnalyticsLevel, fromPrompt: Bool)] = []
    private var _usage: [UsageEvent] = []
    var analyticsState: CoreAnalytics {
        get { lock.withLock { _analytics } }
        set { lock.withLock { _analytics = newValue } }
    }
    var levelCalls: [(level: CoreAnalyticsLevel, fromPrompt: Bool)] { lock.withLock { _levelCalls } }
    var usage: [UsageEvent] { lock.withLock { _usage } }
    func analytics() async throws -> CoreAnalytics { lock.withLock { _analytics } }
    func setAnalyticsLevel(_ level: CoreAnalyticsLevel, fromPrompt: Bool) async throws -> CoreAnalytics {
        lock.withLock {
            _levelCalls.append((level, fromPrompt))
            _analytics = CoreAnalytics(level: level, promptAnswered: _analytics.promptAnswered || fromPrompt,
                                       sendingAvailable: _analytics.sendingAvailable, persistent: _analytics.persistent,
                                       analyticsID: level == .full ? "id-\(_levelCalls.count)" : nil, pending: _analytics.pending)
            return _analytics
        }
    }
    func recordUsage(_ event: UsageEvent) async throws { lock.withLock { _usage.append(event) } }
```

In `CoreProcessSupervisorTests.swift`'s `FakeService`:

```swift
    func analytics() async throws -> CoreAnalytics { throw CoreServiceError.unavailable }
    func setAnalyticsLevel(_ level: CoreAnalyticsLevel, fromPrompt: Bool) async throws -> CoreAnalytics { throw CoreServiceError.unavailable }
    func recordUsage(_ event: UsageEvent) async throws { throw CoreServiceError.unavailable }
```

- [ ] **Step 5: Add the two new files to the project.** The project lists files explicitly, and the prefix `G` is unused. Create `apps/macos/Runnir/Features/Settings/PrivacySettings.swift` containing only `import SwiftUI` and an empty `apps/macos/RunnirTests/AnalyticsTests.swift`, then run:

```bash
python3 - <<'EOF'
p = "apps/macos/Runnir.xcodeproj/project.pbxproj"
s = open(p).read()
build = ("\t\tG00000000000000000010001 = {isa = PBXBuildFile; fileRef = G00000000000000000000001; };\n"
         "\t\tG00000000000000000010002 = {isa = PBXBuildFile; fileRef = G00000000000000000000002; };\n")
refs = ("\t\tG00000000000000000000001 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Runnir/Features/Settings/PrivacySettings.swift; sourceTree = SOURCE_ROOT; };\n"
        "\t\tG00000000000000000000002 = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RunnirTests/AnalyticsTests.swift; sourceTree = SOURCE_ROOT; };\n")
anchor_build = "\t\tI00000000000000000010005 = {isa = PBXBuildFile; fileRef = I00000000000000000000005; };\n"
anchor_ref = "I00000000000000000000005 = {isa = PBXFileReference;"
app_phase = "A00000000000000000070001 /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ("
test_phase = "A00000000000000000070002 /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ("
group_end = '); name = "Core IPC";'
for anchor in (anchor_build, anchor_ref, app_phase, test_phase, group_end):
    assert s.count(anchor) == 1, anchor
s = s.replace(anchor_build, anchor_build + build)
i = s.index(anchor_ref); j = s.index("\n", i) + 1
s = s[:j] + refs + s[j:]
s = s.replace(group_end, ', G00000000000000000000001, G00000000000000000000002' + group_end)
s = s.replace(app_phase, app_phase + "G00000000000000000010001, ")
s = s.replace(test_phase, test_phase + "G00000000000000000010002, ")
open(p, "w").write(s)
EOF
grep -c "G000000000000000000" apps/macos/Runnir.xcodeproj/project.pbxproj
```

Expected: `7` (two build files, two file references, the group line, the app Sources line, the test Sources line). Then run `xcodebuild -project apps/macos/Runnir.xcodeproj -list` — Expected: it lists the Runnir scheme without a parse error.

- [ ] **Step 6: Write the failing tests** in `apps/macos/RunnirTests/AnalyticsTests.swift`:

```swift
import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite struct AnalyticsHubTests {
    private func readyHub(_ state: CoreAnalytics? = nil) async -> (CoreHub, FakeProvider) {
        let provider = FakeProvider()
        if let state { provider.core.analyticsState = state }
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.analytics != nil }
        return (hub, provider)
    }

    @Test func theLedgerIsReadWhenTheCoreStarts() async {
        let (hub, provider) = await readyHub()
        #expect(hub.analytics == provider.core.analyticsState)
    }

    @Test func sectionsAndActionsAreSentOnlyAtUsageAnalytics() async {
        let (hub, provider) = await readyHub()
        hub.recordUsage(.screenRuns)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(provider.core.usage.isEmpty)
        #expect(await hub.setAnalyticsLevel(.full, fromPrompt: false))
        hub.recordUsage(.screenRuns)
        #expect(await eventually { provider.core.usage == [.screenRuns] })
    }

    @Test func changingTheLevelUpdatesTheHub() async {
        let (hub, provider) = await readyHub()
        #expect(await hub.setAnalyticsLevel(.full, fromPrompt: true))
        #expect(hub.analytics?.level == .full)
        #expect(hub.analytics?.promptAnswered == true)
        #expect(provider.core.levelCalls.map(\.fromPrompt) == [true])
    }

    @Test func usageEventsMatchTheContract() {
        let generated = Runnir_Core_V1_UsageEvent.allCases.filter { $0 != .unspecified }
        #expect(generated.count == UsageEvent.allCases.count)
        for event in UsageEvent.allCases {
            let wire = Runnir_Core_V1_UsageEvent(rawValue: event.rawValue)
            #expect(wire.map { String(describing: $0) } == String(describing: event), "\(event)")
        }
    }
}
```

- [ ] **Step 7: Run them to see them fail.**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/AnalyticsHubTests`
Expected: build failure, `value of type 'CoreHub' has no member 'analytics'`.

- [ ] **Step 8: Add the state to `CoreHub`.** After the `// MARK: Storage` members add:

```swift
    // MARK: Analytics

    /// The Core's analytics ledger as last read; nil before the Core answered.
    private(set) var analytics: CoreAnalytics?

    /// Reads the ledger; at each Core start and when Settings › Privacy opens.
    func loadAnalytics() async {
        guard isReady, let service = try? await provider.service(), let state = try? await service.analytics() else { return }
        analytics = state
    }

    /// Changes the analytics level; false when the Core could not.
    @discardableResult
    func setAnalyticsLevel(_ level: CoreAnalyticsLevel, fromPrompt: Bool) async -> Bool {
        guard isReady, let service = try? await provider.service(),
              let state = try? await service.setAnalyticsLevel(level, fromPrompt: fromPrompt) else { return false }
        analytics = state
        return true
    }

    /// Counts a section or action at the Usage analytics level; below it
    /// nothing leaves the app.
    func recordUsage(_ event: UsageEvent) {
        guard analytics?.level == .full else { return }
        let provider = provider
        Task {
            guard let service = try? await provider.service() else { return }
            try? await service.recordUsage(event)
        }
    }
```

In `handle(_:)`, case `.running`, after `Task { await pushStoragePreferences() }` add `Task { await loadAnalytics() }`.

- [ ] **Step 9: Run the app tests.**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests`
Expected: `** TEST SUCCEEDED **`, including `AnalyticsHubTests`.

- [ ] **Step 10: Commit.**

```bash
git add apps/macos/Runnir/IPC apps/macos/RunnirTests apps/macos/Runnir/Features/Settings/PrivacySettings.swift apps/macos/Runnir.xcodeproj/project.pbxproj
git commit -m "App: analytics level, pending counts and usage through CoreHub (B21)"
```

---

### Task 8: Consent Banner And Settings › Privacy

**Files:**
- Modify: `apps/macos/Runnir/Features/Settings/PrivacySettings.swift` (created with only its import in Task 7)
- Modify: `apps/macos/Runnir/App/Desktop/DesktopCoordinator.swift` (prompt claim, answer, release)
- Modify: `apps/macos/Runnir/Features/Desktop/DesktopViews.swift` (banner in `DesktopWorkspaceView`)
- Modify: `apps/macos/Runnir/Features/Settings/SettingsOverlay.swift` (Privacy section)
- Test: `apps/macos/RunnirTests/AnalyticsTests.swift`

**Interfaces:**
- Consumes: Task 7's hub API.
- Produces: `DesktopCoordinator.analyticsPromptWindowID: UUID?`, `offerAnalyticsPrompt(windowID:)`, `answerAnalyticsPrompt(_:) async`, `releaseAnalyticsPrompt(windowID:)`; views `AnalyticsConsentBanner(desktop:)`, `PrivacySettingsSection(hub:)`.

- [ ] **Step 1: Add the failing coordinator tests** to `AnalyticsTests.swift`:

```swift
@MainActor
@Suite struct AnalyticsPromptTests {
    private func coordinator(_ state: CoreAnalytics? = nil) async -> (DesktopCoordinator, FakeProvider) {
        let provider = FakeProvider()
        if let state { provider.core.analyticsState = state }
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.analytics != nil }
        return (DesktopCoordinator(core: hub), provider)
    }

    @Test func thePromptGoesToTheFirstWindowOnly() async {
        let (desktop, _) = await coordinator()
        let first = UUID(), second = UUID()
        desktop.offerAnalyticsPrompt(windowID: first)
        desktop.offerAnalyticsPrompt(windowID: second)
        #expect(desktop.analyticsPromptWindowID == first)
        desktop.releaseAnalyticsPrompt(windowID: first)
        desktop.offerAnalyticsPrompt(windowID: second)
        #expect(desktop.analyticsPromptWindowID == second)
    }

    @Test func anAnswerSetsTheLevelAndHidesThePrompt() async {
        let (desktop, provider) = await coordinator()
        let window = UUID()
        desktop.offerAnalyticsPrompt(windowID: window)
        await desktop.answerAnalyticsPrompt(.basic)
        #expect(desktop.analyticsPromptWindowID == nil)
        #expect(provider.core.levelCalls.first.map { $0.level == .basic && $0.fromPrompt } == true)
        desktop.offerAnalyticsPrompt(windowID: window)
        #expect(desktop.analyticsPromptWindowID == nil, "answered: never offered again")
    }

    @Test func noPromptWithoutALedgerOnDisk() async {
        let (desktop, _) = await coordinator(CoreAnalytics(level: .basic, promptAnswered: false, sendingAvailable: false,
                                                           persistent: false, analyticsID: nil, pending: []))
        desktop.offerAnalyticsPrompt(windowID: UUID())
        #expect(desktop.analyticsPromptWindowID == nil)
    }
}
```

- [ ] **Step 2: Run them to see them fail.**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/AnalyticsPromptTests`
Expected: build failure, `value of type 'DesktopCoordinator' has no member 'offerAnalyticsPrompt'`.

- [ ] **Step 3: Add the prompt to `DesktopCoordinator`**, after `showSettingsInFrontWindow`:

```swift
    // MARK: Analytics prompt

    /// The window showing the analytics consent banner; at most one.
    private(set) var analyticsPromptWindowID: UUID?

    /// Shows the consent banner in this window while the prompt is
    /// unanswered, the ledger is on disk and no other window shows it.
    func offerAnalyticsPrompt(windowID: UUID) {
        guard analyticsPromptWindowID == nil, let analytics = core?.analytics,
              analytics.persistent, !analytics.promptAnswered else { return }
        analyticsPromptWindowID = windowID
    }

    /// A window closed or changed: another one may show the banner later.
    func releaseAnalyticsPrompt(windowID: UUID) {
        if analyticsPromptWindowID == windowID { analyticsPromptWindowID = nil }
    }

    func answerAnalyticsPrompt(_ level: CoreAnalyticsLevel) async {
        guard await core?.setAnalyticsLevel(level, fromPrompt: true) == true else { return }
        analyticsPromptWindowID = nil
    }
```

- [ ] **Step 4: Write `PrivacySettings.swift`.**

```swift
import AppKit
import SwiftUI

extension CoreAnalyticsLevel {
    var title: String {
        switch self {
        case .off: "Off"
        case .basic: "Basic counts"
        case .full: "Usage analytics"
        }
    }

    var detail: String {
        switch self {
        case .off: "Nothing is counted or sent."
        case .basic: "That Runnir was installed, and how many minutes local runs and cancelled runs saved. No id."
        case .full: "Basic counts, plus which sections and actions you use, with a random id not linked to you, your Mac or GitHub."
        }
    }
}

/// The analytics consent prompt (O10): once, in the first workspace window,
/// above the content, without blocking work.
struct AnalyticsConsentBanner: View {
    let desktop: DesktopCoordinator
    @State private var answering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised").foregroundStyle(RunnirTheme.primary)
            VStack(alignment: .leading, spacing: 6) {
                Text("Help improve Runnir").font(.system(size: 13, weight: .semibold))
                Text("Runnir sends a few anonymous counts: that it was installed, and how many minutes local runs and cancelled runs saved. They carry no id.")
                Text("With your permission, Runnir also counts which sections and actions you use, with a random id that is not linked to you, your Mac or GitHub. This shows how many people use each feature.")
                Text("Runnir never sends code, repository, workflow or branch names, paths, logs or anything you type. Data is stored by PostHog in the United States. You can change this or turn everything off in Settings › Privacy.")
                    .foregroundStyle(RunnirTheme.secondaryForeground)
                HStack(spacing: 8) {
                    Button("Basic Counts Only") { answer(.basic) }
                    Button("Share Usage Analytics") { answer(.full) }
                }
                .disabled(answering)
                .padding(.top, 2)
            }
            .font(.system(size: 12))
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RunnirTheme.surface)
        .overlay(alignment: .bottom) { DesignDivider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("analytics-consent")
    }

    private func answer(_ level: CoreAnalyticsLevel) {
        answering = true
        Task {
            await desktop.answerAnalyticsPrompt(level)
            answering = false
        }
    }
}

/// Settings › Privacy: the analytics level, what waits to be sent and the
/// analytics id.
struct PrivacySettingsSection: View {
    let hub: CoreHub?

    var body: some View {
        Section("Analytics") {
            if let analytics = hub?.analytics {
                Picker("Share", selection: Binding(get: { analytics.level },
                                                   set: { level in Task { await hub?.setAnalyticsLevel(level, fromPrompt: false) } })) {
                    ForEach(CoreAnalyticsLevel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .disabled(!analytics.persistent)
                Text(analytics.level.detail).font(.caption).foregroundStyle(RunnirTheme.secondaryForeground)
                if !analytics.persistent {
                    Text("Another copy of Runnir that is running keeps the analytics settings.")
                        .font(.caption).foregroundStyle(RunnirTheme.secondaryForeground)
                } else if !analytics.sendingAvailable {
                    Text("Sending is off in this build.").font(.caption).foregroundStyle(RunnirTheme.secondaryForeground)
                }
                if let id = analytics.analyticsID {
                    LabeledContent("Analytics ID") {
                        HStack(spacing: 8) {
                            Text(id).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(id, forType: .string)
                            }
                        }
                    }
                }
                DisclosureGroup("What is sent") {
                    if analytics.pending.isEmpty {
                        Text("Nothing is waiting to be sent.").foregroundStyle(RunnirTheme.secondaryForeground)
                    } else {
                        ForEach(analytics.pending, id: \.name) { LabeledContent($0.name, value: "\($0.value)") }
                    }
                }
            } else {
                Text("Runnir Core is not running.").foregroundStyle(RunnirTheme.secondaryForeground)
            }
            Text("Runnir never sends code, repository, workflow or branch names, paths, logs or anything you type. Data is stored by PostHog in the United States.")
                .font(.caption).foregroundStyle(RunnirTheme.secondaryForeground)
        }
        .task { await hub?.loadAnalytics() }
    }
}
```

- [ ] **Step 5: Use them.** In `SettingsOverlay.swift`, replace the `case .privacy:` block (the "Telemetry" section) with:

```swift
            case .privacy:
                PrivacySettingsSection(hub: desktop.core)
```

In `DesktopViews.swift`, `DesktopWorkspaceView.body`: after `coreBanner` add

```swift
                    if desktop.analyticsPromptWindowID == windowID { AnalyticsConsentBanner(desktop: desktop) }
```

and next to the other `.onChange` modifiers add

```swift
        .onChange(of: desktop.core?.analytics, initial: true) { _, _ in desktop.offerAnalyticsPrompt(windowID: windowID) }
        .onDisappear { desktop.releaseAnalyticsPrompt(windowID: windowID) }
```

- [ ] **Step 6: Run the app tests.**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests`
Expected: `** TEST SUCCEEDED **`, including `AnalyticsHubTests` and `AnalyticsPromptTests`.

- [ ] **Step 7: Commit.**

```bash
git add apps/macos
git commit -m "App: analytics consent banner and Settings › Privacy (B21)"
```

---

### Task 9: Section And Action Counters

**Files:**
- Modify: `apps/macos/Runnir/Features/Settings/PrivacySettings.swift` (environment values, URL hook, section mappings)
- Modify: `apps/macos/Runnir/Features/Settings/SettingsOverlay.swift` (`settingsOverlay` sets them)
- Modify: `apps/macos/Runnir/App/Desktop/DesktopCoordinator.swift` (`showSettings`, `noteOpened`)
- Modify: `apps/macos/Runnir/IPC/CoreHub.swift` (local run, dispatch, save, create, rename, concurrency)
- Modify: `apps/macos/Runnir/Features/Desktop/DesktopViews.swift`, `RunInspectorView.swift`, `RunWorkflowSheet.swift`, `OverviewViews.swift`, `GitHubActivityViews.swift`, `GitHubRepositoriesView.swift`, `PullRequestsViews.swift`
- Test: `apps/macos/RunnirTests/AnalyticsTests.swift`

**Interfaces:**
- Consumes: `CoreHub.recordUsage`, `UsageEvent`.
- Produces: `EnvironmentValues.recordUsage`, `View.usageAnalytics(desktop:)`, `AppSection.usageEvent`, `SettingsSection.usageEvent`, `DesktopCoordinator.noteOpened(_:)`.

Where each counter is recorded (one call each, all through `CoreHub.recordUsage`, which drops them below Full):

| Counter | Place |
| --- | --- |
| `screen_overview`, `_workflows`, `_runs`, `_workspace` | The sidebar button in `DesktopWorkspaceView` (`DesktopViews.swift`, `ForEach(AppSection.sidebarSections)`) |
| `screen_workspace_editor`, `_local_run` | The two tab buttons in `DesktopWorkspaceView.workspaceTabs` |
| `screen_manager_workspaces`, `_github` | The two tab buttons in `WorkspaceManagerView` |
| `screen_settings_*` | `DesktopCoordinator.showSettings(in:section:)` when Settings open or change section |
| `screen_menu_bar` | `PullRequestsMenu` `.onAppear` |
| `action_run_local` | `CoreHub.startLocalRun` on `.started` |
| `action_dispatch` | `CoreHub.confirmDispatch(target:dispatchID:)` when `dispatchedAt` is set |
| `action_cancel_run`, `action_rerun` | `RunActionModel.send` after `phase = .requested(action)` |
| `action_save_workflow`, `_create_workflow`, `_rename_workflow` | `CoreHub.saveWorkflowFile` on `.saved`, `createWorkflowFile` and `renameWorkflowFile` on `.done` |
| `action_validate` | The toolbar Validate button and the diagnostics panel's `validate:` closure in `DesktopWorkspaceView` |
| `action_open_log` | `JobLogView`'s `.task`, once per job id |
| `action_save_log` | `JobLogView.openInEditor` when the file opens |
| `action_save_preset`, `action_apply_preset` | `DispatchFormModel.saveAsPreset` on success, `DispatchFormModel.apply` |
| `action_insert_concurrency` | `CoreHub.insertWorkflowConcurrency` on `.inserted` |
| `action_favorite` | The workflow star buttons (`OverviewViews.swift`, `GitHubActivityViews.swift`) and the repository star (`GitHubRepositoriesView.swift`), when the item becomes starred |
| `action_open_on_github`, `action_report_bug` | The `openURL` hook: a URL on github.com or a known Enterprise server; the new-issue page is Report a Bug |

- [ ] **Step 1: Write the failing tests** in `AnalyticsTests.swift`:

```swift
@MainActor
@Suite struct UsageCounterTests {
    private func fullDesktop() async -> (DesktopCoordinator, FakeProvider) {
        let provider = FakeProvider()
        provider.core.analyticsState = CoreAnalytics(level: .full, promptAnswered: true, sendingAvailable: true, persistent: true,
                                                     analyticsID: "id", pending: [])
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.analytics?.level == .full }
        return (DesktopCoordinator(core: hub), provider)
    }

    @Test func openingOrSwitchingSettingsCountsTheSection() async {
        let (desktop, provider) = await fullDesktop()
        let window = UUID()
        desktop.showSettings(in: window, section: .storage)
        desktop.showSettingsSection(.storage) // same section: not again
        desktop.showSettingsSection(.privacy)
        // Each count is its own task, so their order is not fixed.
        #expect(await eventually { provider.core.usage.count == 2 })
        #expect(Set(provider.core.usage) == [.screenSettingsStorage, .screenSettingsPrivacy])
    }

    @Test func gitHubLinksAndTheIssuePageAreCounted() async {
        let (desktop, provider) = await fullDesktop()
        desktop.noteOpened(URL(string: "https://github.com/o/r/actions/runs/1")!)
        desktop.noteOpened(BugReportDraft.newIssue)
        desktop.noteOpened(URL(string: "https://docs.docker.com/desktop/")!)
        desktop.noteOpened(URL(fileURLWithPath: "/tmp/log.txt"))
        #expect(await eventually { provider.core.usage.count == 2 })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(provider.core.usage.count == 2 && Set(provider.core.usage) == [.actionOpenOnGithub, .actionReportBug])
    }

    @Test func everySidebarAndSettingsSectionHasACounter() {
        #expect(AppSection.sidebarSections.allSatisfy { $0.usageEvent != nil })
        #expect(Set(SettingsSection.allCases.map(\.usageEvent)).count == SettingsSection.allCases.count)
    }
}
```

- [ ] **Step 2: Run them to see them fail.**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/UsageCounterTests`
Expected: build failure, `value of type 'DesktopCoordinator' has no member 'noteOpened'`.

- [ ] **Step 3: Add the environment, the hook and the mappings** at the end of `PrivacySettings.swift`:

```swift
extension EnvironmentValues {
    /// Counts a section or action for usage analytics; dropped below the
    /// Usage analytics level. Set by `usageAnalytics(desktop:)`; unset
    /// outside Runnir's windows.
    @Entry var recordUsage: (@MainActor (UsageEvent) -> Void)? = nil
}

extension View {
    /// Lets views inside count sections and actions, and counts links they
    /// open on GitHub.
    func usageAnalytics(desktop: DesktopCoordinator) -> some View {
        environment(\.recordUsage) { desktop.core?.recordUsage($0) }
            .environment(\.openURL, OpenURLAction { url in
                // SwiftUI opens links on the main thread.
                MainActor.assumeIsolated { desktop.noteOpened(url) }
                return .systemAction
            })
    }
}

extension AppSection {
    var usageEvent: UsageEvent? {
        switch self {
        case .dashboard: .screenOverview
        case .workflows: .screenWorkflows
        case .runs: .screenRuns
        case .workspace: .screenWorkspace
        case .repositories, .artifacts: nil
        }
    }
}

extension SettingsSection {
    var usageEvent: UsageEvent {
        switch self {
        case .account: .screenSettingsAccount
        case .runs: .screenSettingsRuns
        case .notifications: .screenSettingsNotifications
        case .pullRequests: .screenSettingsPullRequests
        case .tools: .screenSettingsTools
        case .storage: .screenSettingsStorage
        case .privacy: .screenSettingsPrivacy
        }
    }
}
```

In `SettingsOverlay.swift`'s `settingsOverlay(desktop:windowID:)`, append `.usageAnalytics(desktop: desktop)` after the `.environment(\.openRunnirSettings)` line. In `PullRequestsViews.swift`, on `PullRequestsMenu.body` (after `.task { ... }`) and on the root of `PullRequestsWindowView.body`, add:

```swift
        .usageAnalytics(desktop: desktop)
```

and on `PullRequestsMenu.body` also `.onAppear { desktop.core?.recordUsage(.screenMenuBar) }` (check live that it runs at each opening of the menu bar window; if `.task`/`.onAppear` runs only once, note it in the checklist instead of guessing another hook).

- [ ] **Step 4: Count in `DesktopCoordinator`.** In `showSettings(in:section:)`, before `settings = SettingsPresentation(...)`, add:

```swift
        if settings?.section != section { core?.recordUsage(section.usageEvent) }
```

and after the analytics prompt methods add:

```swift
    /// Counts a URL opened on GitHub: the new-issue page as Report a Bug,
    /// anything else on github.com or an Enterprise server as Open on GitHub.
    func noteOpened(_ url: URL) {
        guard url.scheme == "https" || url.scheme == "http", let host = url.host()?.lowercased() else { return }
        let enterprise = Set((enterpriseServers?.servers ?? []).map(\.ref.webHost))
        guard host == "github.com" || enterprise.contains(host) else { return }
        core?.recordUsage(url.path() == BugReportDraft.newIssue.path() ? .actionReportBug : .actionOpenOnGithub)
    }
```

- [ ] **Step 5: Count in `CoreHub`.** Make these one-line additions:
  - `startLocalRun`: before `return .started(model)` add `recordUsage(.actionRunLocal)`.
  - `confirmDispatch(target:dispatchID:)`: before `return result` add `if result.dispatchedAt != nil { recordUsage(.actionDispatch) }`.
  - `saveWorkflowFile`: replace `return result.conflict ? .conflict : .saved(result.sha256)` with

    ```swift
            if result.conflict { return .conflict }
            recordUsage(.actionSaveWorkflow)
            return .saved(result.sha256)
    ```
  - `createWorkflowFile`: replace the `return .done(try await ...)` line with

    ```swift
            let id = try await service.createWorkflowFile(repositoryID: coreID, fileName: fileName, content: content)
            recordUsage(.actionCreateWorkflow)
            return .done(id)
    ```
  - `renameWorkflowFile`: the same shape with `renameWorkflowFile(...)` and `.actionRenameWorkflow`.
  - `insertWorkflowConcurrency`: replace the body's last line with

    ```swift
        let insertion = try? await service.insertWorkflowConcurrency(repositoryID: coreID, content: content)
        if case .inserted = insertion { recordUsage(.actionInsertConcurrency) }
        return insertion
    ```

- [ ] **Step 6: Count in the views and models.**
  - `DesktopViews.swift`, sidebar: `Button { state.selectedSection = section; if let event = section.usageEvent { desktop.core?.recordUsage(event) } } label: {`.
  - Workspace tabs: `Button("Editor") { state.workspaceTab = .editor; desktop.core?.recordUsage(.screenWorkspaceEditor) }` and `Button { state.workspaceTab = .localRun; desktop.core?.recordUsage(.screenWorkspaceLocalRun) } label: {`.
  - Manager tabs: `Button("Workspaces") { tab = .workspaces; desktop.core?.recordUsage(.screenManagerWorkspaces) }` and `Button("GitHub") { tab = .github; desktop.core?.recordUsage(.screenManagerGithub) }`.
  - Validate: the toolbar `Button(...) { validateWorkflows(); desktop.core?.recordUsage(.actionValidate) }`, and in `LocalWorkflowBrowser(... validate: validateWorkflows, ...)` pass `validate: { validateWorkflows(); desktop.core?.recordUsage(.actionValidate) }`.
  - `RunInspectorView.swift`, `RunActionModel.send`: after `phase = .requested(action)` add `hub.recordUsage(action == .cancel ? .actionCancelRun : .actionRerun)`.
  - `JobLogView`: add `@State private var countedJobID: Int64?`; at the top of the `.task(id:)` closure add `if countedJobID != job.id { countedJobID = job.id; hub.recordUsage(.actionOpenLog) }`; in `openInEditor`, change the last case to `if let file = saved.file { LogEditor.open(file); hub.recordUsage(.actionSaveLog) } else { ... }`.
  - `RunWorkflowSheet.swift`, `DispatchFormModel`: in `apply(_:)` after `presetNotes = []` add `hub.recordUsage(.actionApplyPreset)`; in `saveAsPreset(named:)` before `return true` add `hub.recordUsage(.actionSavePreset)`.
  - `OverviewViews.swift` (`WorkspaceOverview`) and `GitHubActivityViews.swift` (`WorkspaceWorkflowsView`): add `@Environment(\.recordUsage) private var recordUsage`; change each star button's action to toggle, then `if favorites.isFavorite(<path>, workspaceID: <id>) { recordUsage?(.actionFavorite) }` with the same path and workspace id the button already uses.
  - `GitHubRepositoriesView.swift`: `toggleStar: { desktop.repositoryFavorites.toggle(ref.key); if desktop.repositoryFavorites.isFavorite(ref.key) { desktop.core?.recordUsage(.actionFavorite) } }`.

- [ ] **Step 7: Run every app check.**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`.
Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit.**

```bash
git add apps/macos
git commit -m "App: count sections and actions at the Usage analytics level (B21)"
```

---

### Task 10: Documents And Final Verification

**Files:**
- Modify: `AGENTS.md`, `README.md`, `SECURITY.md`, `docs/product/specification.md`, `docs/legal/security-privacy-policy.md`, `docs/design/screens-and-states.md`, `docs/product/mvp-implementation-checklist.md`, `docs/architecture/grpc-api.md`, `docs/architecture/workspace-persistence.md`, `docs/product/analytics-and-crash-reporting.md`, `docs/superpowers/specs/2026-10-25-anonymous-analytics-design.md`, `apps/macos/Runnir/Features/Settings/SettingsOverlay.swift`, `apps/macos/Runnir/Features/Desktop/GlobalSearch.swift` (check that nothing else promises no telemetry with the grep of Step 8)

- [ ] **Step 1: AGENTS.md.** Replace the line that starts `- Do not add telemetry by default.` (with its note on this design) with:

```markdown
- Analytics follow docs/product/analytics-and-crash-reporting.md: anonymous counts without an id (first launch, saved minutes) are on by default, said so in the consent prompt and can be turned off; anything else needs consent. No other telemetry.
```

- [ ] **Step 2: Specification.** In `docs/product/specification.md`: in FR-07 replace "Invite users to help improve the app through separately controlled, off-by-default analytics." with "Basic anonymous counts (first launch, saved minutes) are on by default and disclosed; section and action counts with a random id need consent; everything can be turned off." Replace "No runtime capability is implemented yet." with "Analytics are implemented (B21); crash reporting is not." In the non-goals line, replace "No telemetry by default" with "No telemetry beyond the disclosed anonymous counts". In the line "No telemetry is enabled by default; identifier-free counters do not establish exact unique or weekly active users." write "Only the disclosed anonymous counts are on by default; identifier-free counters do not establish exact unique or weekly active users."

- [ ] **Step 3: Privacy policy.** In `docs/legal/security-privacy-policy.md`, replace the first sentence of the analytics bullet ("Do not collect or transmit personal data by default. Optional analytics must use explicit consent and a strict non-content allowlist;") with: "Analytics: Basic (default) sends first_launch and saved-minute counts without an id; Usage analytics (consent) adds section and action counts with a random analytics id; Off sends nothing. Data goes to PostHog Cloud US; the project discards client IP addresses and GeoIP is off; events are kept as long as the PostHog project's retention setting, which is named here before the first Release build that sends. A deletion request names the analytics id shown in Settings › Privacy. A strict non-content allowlist applies;" and keep the rest of the bullet.

- [ ] **Step 4: Screens.** In `docs/design/screens-and-states.md`, replace the O10 row's middle and last cells with "A banner at the top of the first workspace window: Help improve Runnir, what Basic sends, what Usage analytics adds, what is never sent, PostHog in the US" and "Basic Counts Only / Share Usage Analytics, equal weight; shown once, again in a later window only if unanswered". In the FR-07 paragraph replace "analytics off/on/withdrawn" with "analytics Off / Basic counts / Usage analytics, what waits to be sent, the analytics id with Copy" and "A separate optional analytics invitation has Not Now and Enable; no preselection or effect on crash sharing." with "The consent banner has Basic Counts Only and Share Usage Analytics; no preselection or effect on crash sharing."

- [ ] **Step 5: Checklist and API docs.**
  - `docs/product/mvp-implementation-checklist.md`: add a B21 row to the implemented table: "Analytics ([spec](../superpowers/specs/2026-10-25-anonymous-analytics-design.md)): a ledger in the Core (`analytics.sqlite`, own lock) with Off / Basic / Full; first_launch once; minute counters from local runs (with GitHub references), superseded cancels and the saved concurrency block; section and action counts at Full; daily batches with a batch id sent to PostHog US with retries; consent banner and Settings › Privacy; covered by Core and app tests" with the open column "A Release build sending to the real PostHog project; the menu bar counter checked live; PostHog insights deduplicated by batch_id". Tick B21 in the backlog list and point B18 to the banner and Privacy section.
  - `docs/architecture/grpc-api.md`: add rows for `GetAnalytics`, `SetAnalyticsLevel(level, from_prompt)` and `RecordUsage(event)` with their meaning from the proto comments and errors (`INVALID_ARGUMENT` for an unknown level or event, `UNAVAILABLE` without a ledger).
  - `docs/architecture/workspace-persistence.md`: in the schema line, add "`concurrency_saves` and `counted_cancels` (only on this Mac: for the analytics of runs the saved concurrency block cancels; Clear Cache keeps them)", and add a line: "Analytics: `analytics.sqlite` beside `repositories/`, with its own lock; disposable: a damaged one is replaced at Off."

- [ ] **Step 6: The analytics product doc and the spec.** In `docs/product/analytics-and-crash-reporting.md`: change the status line to say analytics are implemented (B21) and remove "AGENTS.md, README, SECURITY.md, FR-07, the privacy policy and the app's Settings texts still say 'no telemetry by default' and change with the implementation."; update the consent paragraph to the banner; in the section and action paragraph say sidebar, Workspace tab and Manager tab clicks; add the damaged-ledger rule. In the spec: set the status to "design approved and implemented on <date> ([plan](../plans/2026-10-25-anonymous-analytics.md))" followed by the list from "Changes To The Spec Made While Planning" above, and remove `action_run_scenario_local` from the click table and "Manager opens on it".

- [ ] **Step 7: README, SECURITY.md and the Settings search entry.**
  - `README.md`: in the list of what Runnir does, after the Settings line, add: "- Analytics: anonymous counts without an id are on by default (the first launch, once, and per day the GitHub Actions minutes local runs saved), said so in a banner in the first window and turned off in Settings › Privacy; counts of sections and actions with a random analytics id only with consent. They go to PostHog Cloud US; no code, repository, workflow, log or GitHub identity is sent. See [analytics](docs/product/analytics-and-crash-reporting.md)." In the documents list, rename the link "Optional analytics, crash reports and public GitHub link" to "Analytics, crash reports and public GitHub link".
  - `SECURITY.md`: replace "- No telemetry by default." with "- No telemetry beyond the disclosed anonymous counts (first launch, saved minutes), which Settings › Privacy turns off; counts of sections and actions need consent."
  - `apps/macos/Runnir/Features/Desktop/GlobalSearch.swift`: the `telemetry` settings item becomes title "Analytics", detail "Anonymous counts by default (first launch, saved minutes), usage counts only with consent; turn them off here", with the same keywords.

- [ ] **Step 8: Final verification.** Run each and read the output:

Run (from `core/`): `go test ./... && go vet ./... && go build ./...` — Expected: every package `ok`, no vet output.
Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build` — Expected: `** BUILD SUCCEEDED **`.
Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests` — Expected: `** TEST SUCCEEDED **`.
Run: `grep -rniE "telemetry by default|no telemetry|optional analytics|does not enable telemetry" --include='*.md' --include='*.swift' . | grep -v worktrees` — Expected: no line that still says analytics are off by default or optional (plans and specs of other features that say "No telemetry" for themselves stay).

- [ ] **Step 9: Commit.**

```bash
git add AGENTS.md README.md SECURITY.md docs apps/macos/Runnir/Features/Settings/SettingsOverlay.swift apps/macos/Runnir/Features/Desktop/GlobalSearch.swift
git commit -m "Docs: analytics levels, consent banner and metrics as built (B21)"
```

## Manual Steps For The Account Owner (Not Part Of The Code)

- In PostHog (US project): turn on "Discard client IP data"; note the event retention for the privacy policy.
- In GitHub: add the repository variable `RUNNIR_POSTHOG_KEY` with the project's key (`phc_…`).
- In PostHog: build the saved-minutes and usage insights so every sum takes one event per `batch_id` (for example in SQL: `SELECT sum(toInt(properties.local_billed_minutes)) FROM (SELECT argMax(properties, timestamp) AS properties FROM events WHERE event = 'usage_day' GROUP BY properties.batch_id)`).
