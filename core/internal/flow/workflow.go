// Package flow plans the pipeline of a change: which workflows a scenario (a
// pull request into a base, a push, a merge, a tag, a manual start, the
// schedule) starts, each as a lane of jobs in columns by `needs`, the
// workflows chained after them by `workflow_run`, the workflows run by hand,
// and the workflows the scenario skips with the reason. It reads workflow
// files and a list of changed files only; it never reads GitHub.
package flow

import (
	"bytes"
	"fmt"
	"strings"

	"go.yaml.in/yaml/v3"

	"runnir/core/internal/scanner"
)

// Event is one trigger of a workflow, with its filters.
type Event struct {
	Branches, BranchesIgnore []string
	Tags, TagsIgnore         []string
	Paths, PathsIgnore       []string
	Types                    []string
	// Workflows are the workflows a workflow_run follows, by name.
	Workflows []string
}

// Job is one job of a workflow as the planner reads it.
type Job struct {
	ID, Name string
	Needs    []string
	// If is the job's condition as written, without ${{ }}.
	If string
	// Environment is the environment the job deploys to: a gate.
	Environment string
	// Uses is the reusable workflow the job calls; it is one node.
	Uses string
	// Matrix is how many runs the matrix gives: 0 without a matrix, -1 when
	// it is known only when the workflow runs.
	Matrix int
	// Manual: the job's if requires a workflow_dispatch run (the scanner's
	// reading), with the inputs that if fixes.
	Manual       bool
	ManualInputs map[string]string
}

// Workflow is a workflow file as the planner reads it.
type Workflow struct {
	// Path is ".github/workflows/<file>".
	Path string
	Name string
	// Events by name: push, pull_request, workflow_dispatch, schedule, ...
	Events     map[string]Event
	Jobs       []Job
	ParseError string
}

// Parse reads one workflow file. A file that does not parse comes back with
// ParseError set and no events.
func Parse(path string, data []byte) Workflow {
	parsed := scanner.ParseWorkflow(path, data)
	workflow := Workflow{Path: path, Name: parsed.Name, ParseError: parsed.ParseError, Events: map[string]Event{}}
	extras := map[string]Job{}
	var document yaml.Node
	if err := yaml.NewDecoder(bytes.NewReader(data)).Decode(&document); err == nil &&
		document.Kind == yaml.DocumentNode && len(document.Content) == 1 {
		if top := resolve(document.Content[0]); top.Kind == yaml.MappingNode {
			for i := 0; i+1 < len(top.Content); i += 2 {
				switch top.Content[i].Value {
				case "on":
					workflow.Events = events(resolve(top.Content[i+1]))
				case "jobs":
					extras = jobExtras(resolve(top.Content[i+1]))
				}
			}
		}
	}
	for _, j := range parsed.Jobs {
		extra := extras[j.ID]
		workflow.Jobs = append(workflow.Jobs, Job{
			ID: j.ID, Name: j.Name, Needs: j.Needs, Manual: j.Manual, ManualInputs: j.ManualInputs,
			If: extra.If, Environment: extra.Environment, Uses: extra.Uses, Matrix: extra.Matrix,
		})
	}
	return workflow
}

// OnlyDispatch: the workflow starts only by hand.
func (w Workflow) OnlyDispatch() bool {
	_, ok := w.Events["workflow_dispatch"]
	return ok && len(w.Events) == 1
}

// events accepts every form of "on": a name, a list of names, or a mapping
// of names to their filters.
func events(node *yaml.Node) map[string]Event {
	out := map[string]Event{}
	switch node.Kind {
	case yaml.ScalarNode:
		out[node.Value] = Event{}
	case yaml.SequenceNode:
		for _, item := range node.Content {
			if item = resolve(item); item.Kind == yaml.ScalarNode {
				out[item.Value] = Event{}
			}
		}
	case yaml.MappingNode:
		for i := 0; i+1 < len(node.Content); i += 2 {
			out[node.Content[i].Value] = event(resolve(node.Content[i+1]))
		}
	}
	return out
}

func event(node *yaml.Node) Event {
	var e Event
	if node.Kind != yaml.MappingNode {
		return e
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		values := scalars(resolve(node.Content[i+1]))
		switch node.Content[i].Value {
		case "branches":
			e.Branches = values
		case "branches-ignore":
			e.BranchesIgnore = values
		case "tags":
			e.Tags = values
		case "tags-ignore":
			e.TagsIgnore = values
		case "paths":
			e.Paths = values
		case "paths-ignore":
			e.PathsIgnore = values
		case "types":
			e.Types = values
		case "workflows":
			e.Workflows = values
		}
	}
	return e
}

func jobExtras(node *yaml.Node) map[string]Job {
	out := map[string]Job{}
	if node.Kind != yaml.MappingNode {
		return out
	}
	for i := 0; i+1 < len(node.Content); i += 2 {
		var job Job
		body := resolve(node.Content[i+1])
		if body.Kind != yaml.MappingNode {
			continue
		}
		for j := 0; j+1 < len(body.Content); j += 2 {
			value := resolve(body.Content[j+1])
			switch body.Content[j].Value {
			case "if":
				if value.Kind == yaml.ScalarNode {
					job.If = unwrap(value.Value)
				}
			case "environment":
				job.Environment = environmentName(value)
			case "uses":
				if value.Kind == yaml.ScalarNode {
					job.Uses = value.Value
				}
			case "strategy":
				if value.Kind == yaml.MappingNode {
					for k := 0; k+1 < len(value.Content); k += 2 {
						if value.Content[k].Value == "matrix" {
							job.Matrix = matrixSize(resolve(value.Content[k+1]))
						}
					}
				}
			}
		}
		out[node.Content[i].Value] = job
	}
	return out
}

func environmentName(node *yaml.Node) string {
	switch node.Kind {
	case yaml.ScalarNode:
		return node.Value
	case yaml.MappingNode:
		for i := 0; i+1 < len(node.Content); i += 2 {
			if node.Content[i].Value == "name" {
				if value := resolve(node.Content[i+1]); value.Kind == yaml.ScalarNode {
					return value.Value
				}
			}
		}
	}
	return ""
}

// maxMatrix bounds the combinations worked out: GitHub allows 256 a run.
const maxMatrix = 256

// matrixSize counts the runs of a literal matrix: the product of its axes,
// less the combinations `exclude` removes, plus those `include` adds. A
// matrix built by an expression is known only when the workflow runs: -1.
func matrixSize(node *yaml.Node) int {
	if node.Kind != yaml.MappingNode {
		return -1
	}
	type axis struct {
		key    string
		values []string
	}
	var axes []axis
	var include, exclude []map[string]string
	for i := 0; i+1 < len(node.Content); i += 2 {
		key, value := node.Content[i].Value, resolve(node.Content[i+1])
		switch key {
		case "include", "exclude":
			if value.Kind != yaml.SequenceNode {
				return -1
			}
			for _, item := range value.Content {
				entry, ok := literalMap(resolve(item))
				if !ok {
					return -1
				}
				if key == "include" {
					include = append(include, entry)
				} else {
					exclude = append(exclude, entry)
				}
			}
		default:
			if value.Kind != yaml.SequenceNode {
				return -1
			}
			var values []string
			for _, item := range value.Content {
				values = append(values, literal(resolve(item)))
			}
			axes = append(axes, axis{key, values})
		}
	}
	combos := []map[string]string{{}}
	for _, a := range axes {
		var next []map[string]string
		for _, combo := range combos {
			for _, v := range a.values {
				extended := map[string]string{a.key: v}
				for k, value := range combo {
					extended[k] = value
				}
				next = append(next, extended)
			}
		}
		combos = next
		if len(combos) > maxMatrix {
			return -1
		}
	}
	if len(axes) == 0 {
		combos = nil
	}
	matches := func(combo, entry map[string]string) bool {
		for k, v := range entry {
			if value, ok := combo[k]; ok && value != v {
				return false
			}
		}
		return true
	}
	kept := combos[:0]
	for _, combo := range combos {
		excluded := false
		for _, entry := range exclude {
			excluded = excluded || matches(combo, entry)
		}
		if !excluded {
			kept = append(kept, combo)
		}
	}
	added := 0
	for _, entry := range include {
		// An entry whose axis values match a combination extends it; any
		// other entry is a combination of its own.
		axisKeys, extends := 0, false
		for _, a := range axes {
			if _, ok := entry[a.key]; ok {
				axisKeys++
			}
		}
		if axisKeys > 0 {
			for _, combo := range kept {
				extends = extends || matches(combo, entry)
			}
		}
		if !extends {
			added++
		}
	}
	return len(kept) + added
}

func literalMap(node *yaml.Node) (map[string]string, bool) {
	if node.Kind != yaml.MappingNode {
		return nil, false
	}
	out := map[string]string{}
	for i := 0; i+1 < len(node.Content); i += 2 {
		out[node.Content[i].Value] = literal(resolve(node.Content[i+1]))
	}
	return out, true
}

// literal is a value as matrix entries compare it: a scalar's text, or the
// position of anything else, which then equals only itself.
func literal(node *yaml.Node) string {
	if node.Kind == yaml.ScalarNode {
		return node.Value
	}
	return fmt.Sprintf("\x00%d:%d", node.Line, node.Column)
}

func scalars(node *yaml.Node) []string {
	switch node.Kind {
	case yaml.ScalarNode:
		if node.Value == "" {
			return nil
		}
		return []string{node.Value}
	case yaml.SequenceNode:
		var out []string
		for _, item := range node.Content {
			if item = resolve(item); item.Kind == yaml.ScalarNode {
				out = append(out, item.Value)
			}
		}
		return out
	}
	return nil
}

// unwrap drops the ${{ }} around a whole condition.
func unwrap(condition string) string {
	text := strings.TrimSpace(condition)
	if inner, ok := strings.CutPrefix(text, "${{"); ok {
		if inner, ok = strings.CutSuffix(inner, "}}"); ok && !strings.Contains(inner, "${{") {
			return strings.TrimSpace(inner)
		}
	}
	return text
}

func resolve(node *yaml.Node) *yaml.Node {
	for depth := 0; node.Kind == yaml.AliasNode && node.Alias != nil && depth < 8; depth++ {
		node = node.Alias
	}
	return node
}
