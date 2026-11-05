package analytics

import (
	"strings"
	"testing"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func TestEveryUsageEventHasACategoryAndAnArea(t *testing.T) {
	for value, name := range corev1.UsageEvent_name {
		counter := UsageCounter(corev1.UsageEvent(value))
		if value == 0 {
			if counter != "" {
				t.Fatalf("UNSPECIFIED → %q", counter)
			}
			continue
		}
		u, ok := usageOf(counter)
		if counter == "" || !ok || !IsUsageCounter(counter) || IsMinuteCounter(counter) {
			t.Fatalf("%s → %q: not USAGE_EVENT_<CATEGORY>_<AREA>_<NAME> with a known category and area", name, counter)
		}
		// The name reads back as the proto value, so no part was lost.
		back := "USAGE_EVENT_" + strings.ToUpper(string(u.Category)+"_"+strings.ReplaceAll(u.Name, ".", "_"))
		if back != name || !strings.HasPrefix(u.Name, u.Area+".") {
			t.Fatalf("%s → %+v", name, u)
		}
	}
	if got := UsageCounter(corev1.UsageEvent_USAGE_EVENT_OVERLAY_SETTINGS_PRIVACY); got != "overlay:settings.privacy" {
		t.Fatalf("settings privacy → %q", got)
	}
	if got := UsageCounter(corev1.UsageEvent_USAGE_EVENT_ASYNC_LOCAL_RUN_FAILED); got != "async:local_run.failed" {
		t.Fatalf("local run failed → %q", got)
	}
	for _, name := range []string{"", "unspecified", "screen:nowhere.page", "screen_runs", "local_runs", "SCREEN:RUNS.LIST"} {
		if IsUsageCounter(name) {
			t.Fatalf("%q is a usage counter", name)
		}
	}
	if !IsMinuteCounter(LocalBilledMinutes) || IsMinuteCounter("first_launch") {
		t.Fatal("minute counters are wrong")
	}
}
