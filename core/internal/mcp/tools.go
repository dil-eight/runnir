package mcp

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// The tools this server offers, as mcp/runnir-tools.json describes them;
// a test keeps the two equal.
const (
	listValueSets = "runnir_list_value_sets"
	setValues     = "runnir_set_values"
)

type tool struct {
	Name        string          `json:"name"`
	Title       string          `json:"title,omitempty"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"inputSchema"`
	Annotations map[string]any  `json:"annotations,omitempty"`
}

const repositorySchema = `{"type":"string","minLength":1,"description":"A workspace registered in Runnir: its folder's absolute path (an agent's working directory) or its name"}`

const valuesSchema = `{"type":"object","propertyNames":{"type":"string","pattern":"^(?![Gg][Ii][Tt][Hh][Uu][Bb]_)[A-Za-z_][A-Za-z0-9_]*$","maxLength":255},"additionalProperties":{"type":"string","minLength":1,"maxLength":49152},"maxProperties":100}`

var tools = []tool{
	{
		Name:  listValueSets,
		Title: "List the values of local runs",
		Description: "List a workspace's value sets for local runs (the Repository and its environments) with the secret and variable names " +
			"each set's jobs read and whether each is saved, taken from the Repository or missing. Variable values may be returned; secret values never.",
		InputSchema: json.RawMessage(`{"type":"object","properties":{"repository":` + repositorySchema + `},"required":["repository"],"additionalProperties":false}`),
		Annotations: map[string]any{"readOnlyHint": true, "openWorldHint": false},
	},
	{
		Name:  setValues,
		Title: "Save values for local runs",
		Description: "Save secrets and variables into one value set of a workspace (the Repository or an environment) for local runs, " +
			"after the user confirms the change in Runnir. Secret values pass through the MCP client and the model's context; Runnir never returns them.",
		InputSchema: json.RawMessage(`{"type":"object","properties":{"repository":` + repositorySchema +
			`,"set":{"type":"string","minLength":1,"description":"\"Repository\" or an environment's name from runnir_list_value_sets"}` +
			`,"secrets":` + valuesSchema + `,"variables":` + valuesSchema +
			`},"required":["repository","set"],"minProperties":3,"additionalProperties":false}`),
		Annotations: map[string]any{"readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false},
	},
}

// decode reads a tool's arguments strictly: unknown keys and wrong types
// are refused, and the message never quotes a value.
func decode(arguments json.RawMessage, into any) error {
	if len(arguments) == 0 || string(arguments) == "null" {
		arguments = json.RawMessage("{}")
	}
	decoder := json.NewDecoder(strings.NewReader(string(arguments)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(into); err != nil {
		var typeErr *json.UnmarshalTypeError
		switch {
		case asType(err, &typeErr):
			return fmt.Errorf("%s must be a %s", strings.TrimPrefix(typeErr.Field, "."), typeErr.Type.String())
		case strings.HasPrefix(err.Error(), "json: unknown field "):
			return fmt.Errorf("%s is not an argument of this tool", strings.TrimPrefix(err.Error(), "json: unknown field "))
		default:
			return fmt.Errorf("the arguments are not a JSON object")
		}
	}
	return nil
}

func asType(err error, target **json.UnmarshalTypeError) bool {
	t, ok := err.(*json.UnmarshalTypeError)
	if ok {
		*target = t
	}
	return ok
}

type listArguments struct {
	Repository *string `json:"repository"`
}

type setArguments struct {
	Repository *string            `json:"repository"`
	Set        *string            `json:"set"`
	Secrets    map[string]*string `json:"secrets"`
	Variables  map[string]*string `json:"variables"`
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
			return nil, fmt.Errorf("the %s %s has no value", kind, name)
		}
		out = append(out, &corev1.McpValue{Name: name, Value: *values[name]})
	}
	return out, nil
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

func stateName(state corev1.McpValueState) string {
	switch state {
	case corev1.McpValueState_MCP_VALUE_STATE_SAVED:
		return "saved"
	case corev1.McpValueState_MCP_VALUE_STATE_FROM_REPOSITORY:
		return "from_repository"
	case corev1.McpValueState_MCP_VALUE_STATE_MISSING:
		return "missing"
	case corev1.McpValueState_MCP_VALUE_STATE_NOT_NEEDED:
		return "not_needed"
	default:
		return "unknown"
	}
}

func fromSets(sets *corev1.McpValueSets) valueSets {
	out := valueSets{Workspace: sets.GetWorkspace(), Sets: []valueSet{}}
	for _, set := range sets.GetSets() {
		item := valueSet{Name: set.GetName(), Stale: set.GetStale(), Secrets: []valueName{}, Variables: []valueName{}}
		for _, name := range set.GetNames() {
			if name.GetSecret() {
				// A secret's value never leaves Runnir, whatever the app sent.
				item.Secrets = append(item.Secrets, valueName{Name: name.GetName(), State: stateName(name.GetState())})
			} else {
				item.Variables = append(item.Variables, valueName{Name: name.GetName(), State: stateName(name.GetState()), Value: name.GetValue()})
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
