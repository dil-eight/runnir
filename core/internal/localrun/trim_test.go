package localrun

import (
	"encoding/json"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

func TestTrimKeepsOnlyTheJobsGiven(t *testing.T) {
	source := `name: CI
# a comment
on:
  push:
    branches: [main]
env:
  GLOBAL: &shared yes
jobs:
  lint:
    runs-on: ubuntu-latest
    env: {A: *shared}
    steps: [{run: echo lint}]
  Test:
    needs: lint
    runs-on: ubuntu-latest
    steps: [{run: echo test}]
  deploy:
    needs: Test
    runs-on: ubuntu-latest
    steps: [{run: echo deploy}]
`
	copied, err := Trim([]byte(source), map[string]bool{"lint": true, "test": true})
	if err != nil {
		t.Fatal(err)
	}
	var workflow struct {
		Name string
		On   map[string]any `yaml:"on"`
		Env  map[string]string
		Jobs map[string]map[string]any
	}
	if err := yaml.Unmarshal(copied, &workflow); err != nil {
		t.Fatalf("copy does not parse: %v\n%s", err, copied)
	}
	if workflow.Name != "CI" || workflow.On["push"] == nil || workflow.Env["GLOBAL"] != "yes" || len(workflow.Jobs) != 2 ||
		workflow.Jobs["lint"] == nil || workflow.Jobs["Test"] == nil {
		t.Fatalf("copy = %s", copied)
	}

	whole, err := Trim([]byte(source), map[string]bool{"lint": true, "test": true, "deploy": true})
	if err != nil || string(whole) != source {
		t.Fatalf("a copy of every job is the file itself: %v\n%s", err, whole)
	}
	if _, err := Trim([]byte(source), map[string]bool{}); err == nil {
		t.Fatal("a copy without jobs was made")
	}
	if _, err := Trim([]byte("on: push\n"), map[string]bool{"a": true}); err == nil {
		t.Fatal("a file without jobs was copied")
	}
}

func TestPayloadsCarryTheScenariosRefs(t *testing.T) {
	read := func(c EventContext) map[string]any {
		t.Helper()
		data, err := Payload(c)
		if err != nil {
			t.Fatal(err)
		}
		var event map[string]any
		if err := json.Unmarshal(data, &event); err != nil {
			t.Fatal(err)
		}
		return event
	}
	pr := read(EventContext{Event: "pull_request", Branch: "feature", HeadSHA: "abc", Base: "main", PullRequest: 12, DefaultBranch: "main"})
	pull := pr["pull_request"].(map[string]any)
	if pr["number"].(float64) != 12 || pull["head"].(map[string]any)["ref"] != "feature" || pull["base"].(map[string]any)["ref"] != "main" ||
		pr["repository"].(map[string]any)["default_branch"] != "main" {
		t.Fatalf("pull_request = %v", pr)
	}
	push := read(EventContext{Event: "push", Ref: "refs/heads/main", HeadSHA: "abc"})
	if push["ref"] != "refs/heads/main" || push["after"] != "abc" || push["before"] != noCommit {
		t.Fatalf("push = %v", push)
	}
	if release := read(EventContext{Event: "release", Tag: "v1.1.1"}); release["release"].(map[string]any)["tag_name"] != "v1.1.1" {
		t.Fatalf("release = %v", release)
	}
	manual := read(EventContext{Event: "workflow_dispatch", Ref: "refs/heads/feature"})
	if manual["ref"] != "refs/heads/feature" || len(manual["inputs"].(map[string]any)) != 0 {
		t.Fatalf("workflow_dispatch = %v", manual)
	}
	chained := read(EventContext{Event: "workflow_run", Source: "CI", SourceEvent: "push", Branch: "feature"})
	if run := chained["workflow_run"].(map[string]any); run["name"] != "CI" || run["conclusion"] != "success" {
		t.Fatalf("workflow_run = %v", chained)
	}
	if schedule := read(EventContext{Event: "schedule", DefaultBranch: "main"}); !strings.Contains(string(mustJSON(t, schedule)), `"default_branch":"main"`) {
		t.Fatalf("schedule = %v", schedule)
	}
}

func mustJSON(t *testing.T, v any) []byte {
	t.Helper()
	data, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return data
}
