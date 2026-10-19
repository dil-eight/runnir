// Package joblog turns a GitHub Actions job log into display lines: it strips
// timestamps and terminal colors, recognizes workflow commands such as
// ##[error] and ##[group], and assigns each line to the step that was running
// when it was written. Nothing in the log is evaluated.
package joblog

import (
	"bytes"
	"regexp"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

type Kind int

const (
	Plain Kind = iota
	Error
	Warning
	Notice
	Command
	Group
	EndGroup
	Debug
)

// Line is one log line. Number counts from 1 in the full log, including lines
// dropped before the returned tail. Step is 0 when no step matches.
type Line struct {
	Number int64
	Text   string
	Kind   Kind
	Step   int64
}

// Step is the part of a job step needed to place lines.
type Step struct {
	Number    int64
	StartedAt time.Time
}

// MaxLineBytes bounds one line; longer lines are cut and end with "…".
const MaxLineBytes = 8 << 10

var (
	ansi    = regexp.MustCompile(`\x1b\[[0-9;?]*[ -/]*[@-~]`)
	markers = []struct {
		prefix string
		kind   Kind
	}{
		{"##[error]", Error}, {"##[warning]", Warning}, {"##[notice]", Notice},
		{"##[group]", Group}, {"##[endgroup]", EndGroup}, {"##[debug]", Debug},
		{"##[command]", Command}, {"[command]", Command},
	}
)

// Tail keeps the last maxLines lines of data and returns how many lines it
// dropped, so that a log of many short lines is cut before it is parsed.
func Tail(data []byte, maxLines int) ([]byte, int) {
	body := bytes.TrimSuffix(data, []byte("\n"))
	end := len(body)
	for i := 0; i < maxLines; i++ {
		newline := bytes.LastIndexByte(body[:end], '\n')
		if newline < 0 {
			return data, 0
		}
		end = newline
	}
	start := end + 1
	return data[start:], bytes.Count(data[:start], []byte("\n"))
}

// Parse splits data into lines numbered from firstLine. Steps that never
// started (zero StartedAt), such as skipped ones, receive no lines.
func Parse(data []byte, firstLine int64, steps []Step) []Line {
	data = bytes.TrimPrefix(data, []byte("\xef\xbb\xbf"))
	data = bytes.TrimSuffix(data, []byte("\n"))
	if len(data) == 0 {
		return nil
	}
	started := make([]Step, 0, len(steps))
	for _, step := range steps {
		if !step.StartedAt.IsZero() {
			started = append(started, step)
		}
	}
	sort.SliceStable(started, func(i, j int) bool { return started[i].StartedAt.Before(started[j].StartedAt) })

	raw := bytes.Split(data, []byte("\n"))
	lines := make([]Line, 0, len(raw))
	var current int64
	if len(started) > 0 {
		current = started[0].Number
	}
	for i, chunk := range raw {
		text := string(bytes.TrimSuffix(chunk, []byte("\r")))
		if at, rest, ok := timestamp(text); ok {
			text = rest
			current = stepAt(started, at, current)
		}
		text = ansi.ReplaceAllString(text, "")
		kind := Plain
		for _, marker := range markers {
			if strings.HasPrefix(text, marker.prefix) {
				kind, text = marker.kind, text[len(marker.prefix):]
				break
			}
		}
		if kind == Plain && looksLikeError(text) {
			kind = Error
		}
		lines = append(lines, Line{Number: firstLine + int64(i), Text: bound(text), Kind: kind, Step: current})
	}
	return lines
}

// timestamp splits GitHub's "2026-10-19T10:00:00.1234567Z " line prefix.
func timestamp(text string) (time.Time, string, bool) {
	space := strings.IndexByte(text, ' ')
	if space < 20 || space > 40 || text[4] != '-' {
		return time.Time{}, text, false
	}
	at, err := time.Parse(time.RFC3339Nano, text[:space])
	if err != nil {
		return time.Time{}, text, false
	}
	return at, text[space+1:], true
}

// stepAt is the last step that started at or before t. Step times have
// one-second precision, so a step owns the whole second it started in.
func stepAt(steps []Step, t time.Time, fallback int64) int64 {
	if len(steps) == 0 {
		return fallback
	}
	owner := steps[0].Number
	for _, step := range steps {
		if step.StartedAt.Truncate(time.Second).After(t) {
			break
		}
		owner = step.Number
	}
	return owner
}

func looksLikeError(text string) bool {
	trimmed := strings.TrimLeft(text, " \t")
	return len(trimmed) >= 6 && strings.EqualFold(trimmed[:6], "error:")
}

func bound(text string) string {
	if len(text) > MaxLineBytes {
		cut := MaxLineBytes
		for cut > 0 && !utf8.RuneStart(text[cut]) {
			cut--
		}
		text = text[:cut] + "…"
	}
	return strings.ToValidUTF8(text, "�")
}
