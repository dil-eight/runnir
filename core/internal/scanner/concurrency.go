package scanner

import (
	"io"
	"strings"

	"go.yaml.in/yaml/v3"
)

// concurrencyBlock is what InsertConcurrency adds. Pull requests group by
// number and pushes to other branches than the default by ref, so a newer
// commit cancels the older run in progress; everything else gets a group
// of its own (run_id) and is never cancelled or queued.
const concurrencyBlock = "# Newer commits on a pull request or branch cancel its older runs; runs on the default branch, scheduled and manual runs are never cancelled.\n" +
	"concurrency:\n" +
	"  group: ${{ github.workflow }}-${{ github.event.pull_request.number || (github.event_name == 'push' && github.ref != format('refs/heads/{0}', github.event.repository.default_branch) && github.ref) || github.run_id }}\n" +
	"  cancel-in-progress: true"

// ConcurrencyRefusal says why InsertConcurrency changed nothing.
type ConcurrencyRefusal int

const (
	ConcurrencyInserted ConcurrencyRefusal = iota
	ConcurrencyAlreadyPresent
	ConcurrencyNoJobs
	ConcurrencyNotBlockMapping
	ConcurrencyParseError
	ConcurrencyTooLarge
)

// ConcurrencyEdit is the text with the block and the block's first and last
// line (1-based), or the refusal with no text.
type ConcurrencyEdit struct {
	Content   string
	FirstLine int
	LastLine  int
	Refusal   ConcurrencyRefusal
}

// InsertConcurrency adds the concurrency block to a workflow's text before
// the top-level jobs key, or before the comment lines directly above it,
// keeping the file's line endings. It reads nothing from disk.
func InsertConcurrency(content string) ConcurrencyEdit {
	if len(content) > maxFileBytes {
		return ConcurrencyEdit{Refusal: ConcurrencyTooLarge}
	}
	decoder := yaml.NewDecoder(strings.NewReader(content))
	var document yaml.Node
	if err := decoder.Decode(&document); err != nil {
		return ConcurrencyEdit{Refusal: ConcurrencyParseError}
	}
	var more yaml.Node
	if err := decoder.Decode(&more); err != io.EOF {
		return ConcurrencyEdit{Refusal: ConcurrencyNotBlockMapping}
	}
	if document.Kind != yaml.DocumentNode || len(document.Content) != 1 {
		return ConcurrencyEdit{Refusal: ConcurrencyParseError}
	}
	top := resolve(document.Content[0])
	if top.Kind != yaml.MappingNode || top.Style&yaml.FlowStyle != 0 {
		return ConcurrencyEdit{Refusal: ConcurrencyNotBlockMapping}
	}
	jobsLine := 0
	for i := 0; i+1 < len(top.Content); i += 2 {
		key, value := top.Content[i], resolve(top.Content[i+1])
		switch key.Value {
		case "concurrency":
			return ConcurrencyEdit{Refusal: ConcurrencyAlreadyPresent}
		case "jobs":
			if key.Column != 1 {
				return ConcurrencyEdit{Refusal: ConcurrencyNotBlockMapping}
			}
			jobsLine = key.Line
			if value.Kind == yaml.MappingNode {
				for j := 0; j+1 < len(value.Content); j += 2 {
					if body := resolve(value.Content[j+1]); body.Kind == yaml.MappingNode && hasKey(body, "concurrency") {
						return ConcurrencyEdit{Refusal: ConcurrencyAlreadyPresent}
					}
				}
			}
		}
	}
	if jobsLine == 0 {
		return ConcurrencyEdit{Refusal: ConcurrencyNoJobs}
	}
	newline := "\n"
	if strings.Contains(content, "\r\n") {
		newline = "\r\n"
	}
	lines := strings.SplitAfter(content, "\n")
	at := jobsLine - 1
	for at > 0 && strings.HasPrefix(strings.TrimSpace(lines[at-1]), "#") {
		at--
	}
	var inserted []string
	if at > 0 && strings.TrimSpace(lines[at-1]) != "" {
		inserted = append(inserted, "")
	}
	first := at + len(inserted) + 1
	inserted = append(inserted, strings.Split(concurrencyBlock, "\n")...)
	last := at + len(inserted)
	inserted = append(inserted, "")
	var b strings.Builder
	for _, line := range lines[:at] {
		b.WriteString(line)
	}
	for _, line := range inserted {
		b.WriteString(line)
		b.WriteString(newline)
	}
	for _, line := range lines[at:] {
		b.WriteString(line)
	}
	return ConcurrencyEdit{Content: b.String(), FirstLine: first, LastLine: last}
}

func hasKey(mapping *yaml.Node, name string) bool {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == name {
			return true
		}
	}
	return false
}
