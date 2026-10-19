package joblog

import (
	"strings"
	"testing"
	"time"
)

func at(clock string) time.Time {
	t, err := time.Parse(time.RFC3339, "2026-10-19T"+clock+"Z")
	if err != nil {
		panic(err)
	}
	return t
}

func TestLinesLoseTimestampsColorsAndMarkers(t *testing.T) {
	log := "\xef\xbb\xbf2026-10-19T10:00:00.1000000Z ##[group]Run actions/checkout@v4\n" +
		"2026-10-19T10:00:00.2000000Z \x1b[36;1mgit version\x1b[0m\n" +
		"2026-10-19T10:00:00.3000000Z [command]/usr/bin/git version\n" +
		"2026-10-19T10:00:00.4000000Z ##[endgroup]\n" +
		"2026-10-19T10:00:01.0000000Z ##[warning]Node 16 is deprecated\n" +
		"2026-10-19T10:00:02.0000000Z   error: Provisioning profile expired\r\n" +
		"no timestamp on this continuation line\n" +
		"2026-10-19T10:00:03.0000000Z ##[error]Process completed with exit code 65.\n"
	lines := Parse([]byte(log), 1, nil)
	want := []struct {
		text string
		kind Kind
	}{
		{"Run actions/checkout@v4", Group},
		{"git version", Plain},
		{"/usr/bin/git version", Command},
		{"", EndGroup},
		{"Node 16 is deprecated", Warning},
		{"  error: Provisioning profile expired", Error},
		{"no timestamp on this continuation line", Plain},
		{"Process completed with exit code 65.", Error},
	}
	if len(lines) != len(want) {
		t.Fatalf("got %d lines: %+v", len(lines), lines)
	}
	for i, w := range want {
		if lines[i].Text != w.text || lines[i].Kind != w.kind || lines[i].Number != int64(i+1) {
			t.Errorf("line %d = %+v, want %q kind %d", i+1, lines[i], w.text, w.kind)
		}
	}
}

func TestLinesBelongToTheStepRunningWhenTheyWereWritten(t *testing.T) {
	steps := []Step{
		{Number: 1, StartedAt: at("10:00:00")},
		{Number: 2, StartedAt: at("10:00:05")},
		{Number: 3}, // skipped: never started
		{Number: 4, StartedAt: at("10:01:00")},
	}
	log := "2026-10-19T09:59:59.9000000Z before the first step\n" +
		"2026-10-19T10:00:04.9990000Z set up\n" +
		"2026-10-19T10:00:05.0000001Z checkout\n" +
		"continued\n" +
		"2026-10-19T10:00:59.5000000Z still checkout\n" +
		"2026-10-19T10:01:00.2000000Z archive\n"
	lines := Parse([]byte(log), 400, steps)
	wantSteps := []int64{1, 1, 2, 2, 2, 4}
	for i, step := range wantSteps {
		if lines[i].Step != step {
			t.Errorf("line %q step = %d, want %d", lines[i].Text, lines[i].Step, step)
		}
	}
	if lines[0].Number != 400 || lines[5].Number != 405 {
		t.Errorf("numbering = %d..%d, want 400..405", lines[0].Number, lines[5].Number)
	}
}

func TestLongAndInvalidLinesAreBounded(t *testing.T) {
	long := strings.Repeat("é", MaxLineBytes) // two bytes per rune
	lines := Parse([]byte(long+"\n\xff\xfebroken\n"), 1, nil)
	if len(lines) != 2 {
		t.Fatalf("lines = %d", len(lines))
	}
	if len(lines[0].Text) > MaxLineBytes+len("…") || !strings.HasSuffix(lines[0].Text, "é…") {
		t.Errorf("long line was not cut at a rune boundary: %d bytes", len(lines[0].Text))
	}
	if lines[1].Text != "�broken" {
		t.Errorf("invalid UTF-8 = %q", lines[1].Text)
	}
	if Parse(nil, 1, nil) != nil || Parse([]byte("\n"), 1, nil) != nil {
		t.Error("an empty log should have no lines")
	}
}
