package localrun

import (
	"strings"
	"testing"
	"time"

	"runnir/core/internal/tools"
)

const gib = 1 << 30

func TestChooseKeepsWithinTheEngineAndTheSteps(t *testing.T) {
	ceiling := CeilingFor(tools.Engine{CPUs: 8, MemoryBytes: 6 * gib})
	if ceiling.Timeout != MaxTimeout {
		t.Fatalf("ceiling = %+v", ceiling)
	}
	if got := Choose(nil, ceiling); got != (Limits{CPUs: 4, MemoryBytes: 6 * gib, Timeout: 30 * time.Minute}) {
		t.Fatalf("defaults = %+v", got)
	}
	asked := &Limits{CPUs: 12, MemoryBytes: 1<<30 + 100, Timeout: 7 * time.Hour}
	if got := Choose(asked, ceiling); got != (Limits{CPUs: 8, MemoryBytes: gib, Timeout: MaxTimeout}) {
		t.Fatalf("capped and stepped = %+v", got)
	}
	if got := Choose(&Limits{CPUs: 0, MemoryBytes: 0, Timeout: time.Minute}, ceiling); got != (Limits{CPUs: 1, MemoryBytes: MinMemoryBytes, Timeout: MinTimeout}) {
		t.Fatalf("floors = %+v", got)
	}
	if got := Choose(&Limits{CPUs: 6, MemoryBytes: 3*gib + 700<<20, Timeout: 42 * time.Minute}, ceiling); got != (Limits{CPUs: 6, MemoryBytes: 3*gib + 512<<20, Timeout: 40 * time.Minute}) {
		t.Fatalf("rounded down to a step = %+v", got)
	}
	unknown := CeilingFor(tools.Engine{})
	if got := Choose(&Limits{CPUs: 16, MemoryBytes: 32 * gib, Timeout: time.Hour}, unknown); got.CPUs != 16 || got.MemoryBytes != 32*gib {
		t.Fatalf("an engine that did not say caps nothing: %+v", got)
	}
}

func TestWarningsAndTheNote(t *testing.T) {
	ceiling := CeilingFor(tools.Engine{CPUs: 8, MemoryBytes: 6 * gib})
	all := Warnings(Limits{CPUs: 8, MemoryBytes: 6 * gib, Timeout: time.Hour}, ceiling, true)
	if len(all) != 2 || !strings.Contains(all[0], "Every CPU") || !strings.Contains(all[1], "exit 137") {
		t.Fatalf("overload = %q", all)
	}
	if low := Warnings(Limits{CPUs: 2, MemoryBytes: 1536 << 20, Timeout: time.Hour}, ceiling, true); len(low) != 1 || !strings.Contains(low[0], "Under 2 GB") {
		t.Fatalf("low memory = %q", low)
	}
	// Defaults capped at a small engine get the note, not a warning about memory.
	if w := Warnings(Choose(nil, ceiling), ceiling, false); len(w) != 0 {
		t.Fatalf("defaults warned: %q", w)
	}
	if note := Note(ceiling, "OrbStack", false); !strings.Contains(note, "OrbStack has 6 GB") {
		t.Fatalf("note = %q", note)
	}
	if note := Note(CeilingFor(tools.Engine{}), "OrbStack", false); !strings.Contains(note, "does not answer") {
		t.Fatalf("unknown engine note = %q", note)
	}
	if note := Note(CeilingFor(tools.Engine{CPUs: 8, MemoryBytes: 16 * gib}), "OrbStack", false); note != "" {
		t.Fatalf("a big engine needs no note: %q", note)
	}
}
