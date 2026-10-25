package localrun

import (
	"slices"
	"testing"
)

func TestMasksForSecrets(t *testing.T) {
	masks := masksFor(map[string]string{"A": "longer-secret", "B": "{\n  \"key\": \"value-line\"\n}", "C": ""})
	want := []string{"{\n  \"key\": \"value-line\"\n}", "\"key\": \"value-line\"", "longer-secret"}
	if !slices.Equal(masks, want) {
		t.Fatalf("masks = %q", masks)
	}
	if got := mask("x longer-secret y \"key\": \"value-line\"", masks); got != "x *** y ***" {
		t.Fatalf("mask = %q", got)
	}
}
