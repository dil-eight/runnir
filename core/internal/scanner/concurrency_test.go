package scanner

import (
	"strings"
	"testing"
)

const concurrencyCI = "name: CI\non:\n  pull_request:\n  push:\n\n# The jobs\njobs:\n  build:\n    runs-on: ubuntu-latest\n    steps:\n      - run: make\n"

func TestConcurrencyIsDetected(t *testing.T) {
	for name, tc := range map[string]struct {
		source string
		want   bool
	}{
		"none":      {concurrencyCI, false},
		"top level": {"on: push\nconcurrency: ci\njobs:\n  a:\n    runs-on: x\n", true},
		"in a job":  {"on: push\njobs:\n  a:\n    concurrency: ci\n    runs-on: x\n", true},
	} {
		if got := parse("ci.yml", []byte(tc.source)); got.Concurrency != tc.want || got.ParseError != "" {
			t.Errorf("%s: %+v", name, got)
		}
	}
}

func TestConcurrencyGoesBeforeJobsAndItsComments(t *testing.T) {
	edit := InsertConcurrency(concurrencyCI)
	if edit.Refusal != ConcurrencyInserted || edit.FirstLine != 6 || edit.LastLine != 9 {
		t.Fatalf("edit = %+v", edit)
	}
	lines := strings.Split(edit.Content, "\n")
	if !strings.HasPrefix(lines[5], "# Newer commits on a pull request") || lines[6] != "concurrency:" ||
		lines[8] != "  cancel-in-progress: true" || lines[9] != "" || lines[10] != "# The jobs" || lines[11] != "jobs:" {
		t.Fatalf("content =\n%s", edit.Content)
	}
	if w := parse("ci.yml", []byte(edit.Content)); !w.Concurrency || w.ParseError != "" || len(w.Jobs) != 1 {
		t.Fatalf("parsed = %+v", w)
	}
}

func TestABlankLineSeparatesTheBlockFromTheKeyAbove(t *testing.T) {
	edit := InsertConcurrency("on: push\njobs:\n  a:\n    runs-on: x\n")
	lines := strings.Split(edit.Content, "\n")
	if edit.FirstLine != 3 || edit.LastLine != 6 || lines[1] != "" || lines[6] != "" || lines[7] != "jobs:" {
		t.Fatalf("edit = %+v\n%s", edit, edit.Content)
	}
}

func TestConcurrencyKeepsWindowsLineEndings(t *testing.T) {
	edit := InsertConcurrency(strings.ReplaceAll(concurrencyCI, "\n", "\r\n"))
	if edit.Refusal != ConcurrencyInserted || strings.Count(edit.Content, "\n") != strings.Count(edit.Content, "\r\n") {
		t.Fatalf("edit = %q", edit.Content)
	}
}

func TestConcurrencyRefusals(t *testing.T) {
	for name, tc := range map[string]struct {
		source string
		want   ConcurrencyRefusal
	}{
		"already at the top": {"concurrency: x\non: push\njobs:\n  a:\n    runs-on: y\n", ConcurrencyAlreadyPresent},
		"already in a job":   {"on: push\njobs:\n  a:\n    concurrency: x\n    runs-on: y\n", ConcurrencyAlreadyPresent},
		"no jobs":            {"on: push\n", ConcurrencyNoJobs},
		"flow mapping":       {"{on: push, jobs: {}}\n", ConcurrencyNotBlockMapping},
		"two documents":      {"on: push\njobs: {}\n---\non: push\n", ConcurrencyNotBlockMapping},
		"indented root":      {"  on: push\n  jobs:\n    a:\n      runs-on: y\n", ConcurrencyNotBlockMapping},
		"not YAML":           {"on: [push\n", ConcurrencyParseError},
		"empty":              {"", ConcurrencyParseError},
		"too large":          {strings.Repeat("#", maxFileBytes+1), ConcurrencyTooLarge},
	} {
		if got := InsertConcurrency(tc.source); got.Refusal != tc.want || got.Content != "" {
			t.Errorf("%s: %+v", name, got)
		}
	}
}
