// Package yamlnode reads the parts of a workflow file's YAML tree that more
// than one package needs.
package yamlnode

import "go.yaml.in/yaml/v3"

// Resolve follows aliases a bounded number of steps. Aliases are never
// expanded wholesale, so alias bombs cost nothing.
func Resolve(node *yaml.Node) *yaml.Node {
	for depth := 0; node.Kind == yaml.AliasNode && node.Alias != nil && depth < 8; depth++ {
		node = node.Alias
	}
	return node
}

// Scalars accepts a scalar or a sequence of scalars, the shape of "needs",
// "runs-on" and of the short forms of "on"; an empty scalar and anything
// else yield nothing.
func Scalars(node *yaml.Node) []string {
	switch node.Kind {
	case yaml.ScalarNode:
		if node.Value == "" {
			return nil
		}
		return []string{node.Value}
	case yaml.SequenceNode:
		var out []string
		for _, item := range node.Content {
			if item = Resolve(item); item.Kind == yaml.ScalarNode {
				out = append(out, item.Value)
			}
		}
		return out
	}
	return nil
}
