package scanner

import (
	"bytes"
	"io"
	"strings"

	"go.yaml.in/yaml/v3"
)

// DispatchInput is one `on.workflow_dispatch.inputs` entry.
type DispatchInput struct {
	Name        string
	Description string
	// Type is "string" (the default), "boolean", "choice", "number" or "environment".
	Type     string
	Required bool
	Default  string
	Options  []string
}

// DispatchDefinition says whether a workflow can be started by hand and with
// which inputs.
type DispatchDefinition struct {
	Dispatchable bool
	Inputs       []DispatchInput
}

const maxDispatchInputs = 25

// ParseDispatch reads the workflow_dispatch trigger of a workflow file.
// Expressions are kept verbatim; nothing is evaluated.
func ParseDispatch(data []byte) (DispatchDefinition, error) {
	var document yaml.Node
	if err := yaml.NewDecoder(bytes.NewReader(data)).Decode(&document); err != nil {
		if err == io.EOF {
			return DispatchDefinition{}, nil
		}
		return DispatchDefinition{}, err
	}
	if document.Kind != yaml.DocumentNode || len(document.Content) != 1 {
		return DispatchDefinition{}, nil
	}
	top := resolve(document.Content[0])
	if top.Kind != yaml.MappingNode {
		return DispatchDefinition{}, nil
	}
	on := mappingValue(top, "on")
	if on == nil {
		return DispatchDefinition{}, nil
	}
	switch on.Kind {
	case yaml.ScalarNode, yaml.SequenceNode:
		for _, trigger := range scalarList(on) {
			if trigger == "workflow_dispatch" {
				return DispatchDefinition{Dispatchable: true}, nil
			}
		}
		return DispatchDefinition{}, nil
	case yaml.MappingNode:
		dispatch, present := mappingEntry(on, "workflow_dispatch")
		if !present {
			return DispatchDefinition{}, nil
		}
		definition := DispatchDefinition{Dispatchable: true}
		if dispatch == nil || dispatch.Kind != yaml.MappingNode {
			return definition, nil
		}
		inputs := mappingValue(dispatch, "inputs")
		if inputs == nil || inputs.Kind != yaml.MappingNode {
			return definition, nil
		}
		for i := 0; i+1 < len(inputs.Content) && len(definition.Inputs) < maxDispatchInputs; i += 2 {
			input := DispatchInput{Name: inputs.Content[i].Value, Type: "string"}
			if body := resolve(inputs.Content[i+1]); body.Kind == yaml.MappingNode {
				for j := 0; j+1 < len(body.Content); j += 2 {
					value := resolve(body.Content[j+1])
					switch body.Content[j].Value {
					case "description":
						input.Description = value.Value
					case "type":
						if value.Value != "" {
							input.Type = strings.ToLower(value.Value)
						}
					case "required":
						// YAML spells true as true, True or TRUE.
						input.Required = value.Kind == yaml.ScalarNode && strings.EqualFold(value.Value, "true")
					case "default":
						if value.Kind == yaml.ScalarNode {
							input.Default = value.Value
						}
					case "options":
						input.Options = scalarList(value)
					}
				}
			}
			definition.Inputs = append(definition.Inputs, input)
		}
		return definition, nil
	}
	return DispatchDefinition{}, nil
}

// mappingEntry finds a key; present is true even when its value is null.
func mappingEntry(mapping *yaml.Node, key string) (*yaml.Node, bool) {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == key {
			value := resolve(mapping.Content[i+1])
			if value.Kind == yaml.ScalarNode && (value.Tag == "!!null" || value.Value == "") {
				return nil, true
			}
			return value, true
		}
	}
	return nil, false
}

func mappingValue(mapping *yaml.Node, key string) *yaml.Node {
	value, _ := mappingEntry(mapping, key)
	return value
}
