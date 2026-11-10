package mcptools

import (
	"fmt"
	"sort"
	"strings"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
	"runnir/core/internal/mcpbridge"
)

func (t *Tools) listValueSets(c *call) (Result, error) {
	var a workspaceArgs
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	if a.Repository == nil || *a.Repository == "" {
		return Result{}, refuse("Name a repository: a registered workspace's folder or its name.")
	}
	c.note("%q", *a.Repository)
	sets, err := t.app.List(c.ctx, c.client, *a.Repository)
	if err != nil {
		return Result{}, err
	}
	return result("", fromSets(sets))
}

func (t *Tools) setValues(c *call) (Result, error) {
	var a struct {
		Repository *string            `json:"repository"`
		Set        *string            `json:"set"`
		Secrets    map[string]*string `json:"secrets"`
		Variables  map[string]*string `json:"variables"`
	}
	if err := decode(c.args, &a); err != nil {
		return Result{}, err
	}
	request := &corev1.McpRequest{Client: c.client}
	if a.Repository != nil {
		request.Repository = *a.Repository
	}
	if a.Set != nil {
		request.Set = *a.Set
	}
	var err error
	if request.Secrets, err = pairs(a.Secrets, "secret"); err != nil {
		return Result{}, err
	}
	if request.Variables, err = pairs(a.Variables, "variable"); err != nil {
		return Result{}, err
	}
	c.note("%q set %q secrets=[%s] variables=[%s]", request.Repository, request.Set, names(request.Secrets), names(request.Variables))
	if err := mcpbridge.CheckSet(request); err != nil {
		return Result{}, err
	}
	saved, err := t.app.Set(c.ctx, request)
	if err != nil {
		return Result{}, err
	}
	structured, text := fromSaved(saved)
	return Result{Text: text, Structured: structured}, nil
}

func pairs(values map[string]*string, kind string) ([]*corev1.McpValue, error) {
	names := make([]string, 0, len(values))
	for name := range values {
		names = append(names, name)
	}
	sort.Strings(names)
	out := make([]*corev1.McpValue, 0, len(names))
	for _, name := range names {
		if values[name] == nil {
			return nil, refuse("The %s %s has no value.", kind, name)
		}
		out = append(out, &corev1.McpValue{Name: name, Value: *values[name]})
	}
	return out, nil
}

func names(values []*corev1.McpValue) string {
	out := make([]string, 0, len(values))
	for _, v := range values {
		out = append(out, v.GetName())
	}
	sort.Strings(out)
	return strings.Join(out, " ")
}

// valueSets is what runnir_list_value_sets returns.
type valueSets struct {
	Workspace string     `json:"workspace"`
	Sets      []valueSet `json:"sets"`
}

type valueSet struct {
	Name      string      `json:"name"`
	Stale     bool        `json:"stale,omitempty"`
	Secrets   []valueName `json:"secrets"`
	Variables []valueName `json:"variables"`
}

type valueName struct {
	Name  string `json:"name"`
	State string `json:"state"`
	Value string `json:"value,omitempty"`
}

func fromSets(sets *corev1.McpValueSets) valueSets {
	out := valueSets{Workspace: sets.GetWorkspace(), Sets: []valueSet{}}
	for _, set := range sets.GetSets() {
		item := valueSet{Name: set.GetName(), Stale: set.GetStale(), Secrets: []valueName{}, Variables: []valueName{}}
		for _, name := range set.GetNames() {
			state := lowerName(name.GetState().String(), "MCP_VALUE_STATE_")
			if state == "" {
				state = "unknown"
			}
			if name.GetSecret() {
				// A secret's value never leaves Runnir, whatever the app sent.
				item.Secrets = append(item.Secrets, valueName{Name: name.GetName(), State: state})
			} else {
				item.Variables = append(item.Variables, valueName{Name: name.GetName(), State: state, Value: name.GetValue()})
			}
		}
		out.Sets = append(out.Sets, item)
	}
	return out
}

// savedValues is what runnir_set_values returns.
type savedValues struct {
	Workspace string    `json:"workspace"`
	Set       string    `json:"set"`
	Saved     savedSets `json:"saved"`
}

type savedSets struct {
	Secrets   []string `json:"secrets"`
	Variables []string `json:"variables"`
}

func fromSaved(saved *corev1.McpSavedValues) (savedValues, string) {
	out := savedValues{Workspace: saved.GetWorkspace(), Set: saved.GetSet(),
		Saved: savedSets{Secrets: append([]string{}, saved.GetSecrets()...), Variables: append([]string{}, saved.GetVariables()...)}}
	var parts []string
	if len(out.Saved.Secrets) > 0 {
		parts = append(parts, "secrets "+strings.Join(out.Saved.Secrets, ", "))
	}
	if len(out.Saved.Variables) > 0 {
		parts = append(parts, "variables "+strings.Join(out.Saved.Variables, ", "))
	}
	text := fmt.Sprintf("Saved in %s › %s: %s. Local runs of this workspace now use them.", out.Workspace, out.Set, strings.Join(parts, "; "))
	return out, text
}
