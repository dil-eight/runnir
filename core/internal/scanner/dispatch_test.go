package scanner

import (
	"reflect"
	"testing"
)

func TestDispatchForms(t *testing.T) {
	cases := map[string]bool{
		"on: workflow_dispatch\njobs: {}\n":              true,
		"on: [push, workflow_dispatch]\njobs: {}\n":      true,
		"on:\n  workflow_dispatch:\n  push:\njobs: {}\n": true,
		"on:\n  workflow_dispatch: {}\njobs: {}\n":       true,
		"on: push\njobs: {}\n":                           false,
		"on:\n  push:\n    branches: [main]\njobs: {}\n": false,
		"name: no trigger\njobs: {}\n":                   false,
		"":                                               false,
	}
	for source, want := range cases {
		definition, err := ParseDispatch([]byte(source))
		if err != nil || definition.Dispatchable != want {
			t.Errorf("%q: dispatchable = %v, err = %v; want %v", source, definition.Dispatchable, err, want)
		}
	}
}

func TestDispatchInputsKeepOrderTypesAndDefaults(t *testing.T) {
	definition, err := ParseDispatch([]byte(`
on:
  workflow_dispatch:
    inputs:
      environment:
        description: Where to deploy
        type: choice
        required: true
        default: staging
        options: [staging, production]
      dry_run:
        type: boolean
        default: true
      replicas:
        type: number
        default: 3
      note:
        description: Free text
jobs: {}
`))
	if err != nil {
		t.Fatal(err)
	}
	want := []DispatchInput{
		{Name: "environment", Description: "Where to deploy", Type: "choice", Required: true, Default: "staging", Options: []string{"staging", "production"}},
		{Name: "dry_run", Type: "boolean", Default: "true"},
		{Name: "replicas", Type: "number", Default: "3"},
		{Name: "note", Description: "Free text", Type: "string"},
	}
	if !definition.Dispatchable || !reflect.DeepEqual(definition.Inputs, want) {
		t.Fatalf("definition = %+v", definition)
	}
}

func TestMalformedWorkflowIsAnError(t *testing.T) {
	if _, err := ParseDispatch([]byte("on: [workflow_dispatch\n")); err == nil {
		t.Fatal("want a parse error")
	}
}

func TestRequiredAcceptsEveryYAMLSpellingOfTrue(t *testing.T) {
	definition, err := ParseDispatch([]byte(`
on:
  workflow_dispatch:
    inputs:
      a: {required: True}
      b: {required: TRUE}
      c: {required: "true"}
      d: {required: false}
      e: {required: yes}
`))
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, input := range definition.Inputs {
		got[input.Name] = input.Required
	}
	want := map[string]bool{"a": true, "b": true, "c": true, "d": false, "e": false}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("required = %v, want %v", got, want)
	}
}
