// Package references finds the secrets and configuration variables a
// workflow file reads. It parses the file's expressions, every ${{ }} in a
// value and every if: condition, so comments and look-alikes such as
// steps.vars.outputs do not count. A file that is not YAML is read as text,
// as far as that goes.
package references

import (
	"bytes"
	"regexp"
	"sort"
	"strings"

	"github.com/rhysd/actionlint"
	"go.yaml.in/yaml/v3"
)

// Names are upper-cased, unique and sorted: GitHub and act compare secret
// and variable names without case.
type Names struct {
	Secrets   []string
	Variables []string
	// UnnamedSecrets: the workflow also reads secrets it does not name, as
	// toJSON(secrets), `secrets: inherit` or secrets[expression].
	UnnamedSecrets bool
}

func Find(source []byte) Names {
	c := collector{found: map[string]map[string]bool{"secrets": {}, "vars": {}}}
	var document yaml.Node
	if err := yaml.NewDecoder(bytes.NewReader(source)).Decode(&document); err != nil {
		c.text(string(source))
	} else {
		c.node(&document, "")
	}
	return Names{Secrets: sorted(c.found["secrets"]), Variables: sorted(c.found["vars"]), UnnamedSecrets: c.unnamed}
}

type collector struct {
	found   map[string]map[string]bool
	unnamed bool
}

func (c *collector) node(n *yaml.Node, key string) {
	switch n.Kind {
	case yaml.DocumentNode, yaml.SequenceNode:
		for _, child := range n.Content {
			c.node(child, "")
		}
	case yaml.MappingNode:
		for i := 0; i+1 < len(n.Content); i += 2 {
			c.node(n.Content[i+1], n.Content[i].Value)
		}
	case yaml.ScalarNode:
		switch {
		case key == "secrets" && strings.TrimSpace(n.Value) == "inherit":
			c.unnamed = true
		case key == "if" && !strings.Contains(n.Value, "${{"):
			// A condition is an expression without the braces.
			c.expression(n.Value)
		default:
			c.embedded(n.Value)
		}
	}
	// An alias points at a node read where it is defined.
}

// embedded reads every ${{ }} in a value.
func (c *collector) embedded(value string) {
	for {
		start := strings.Index(value, "${{")
		if start < 0 {
			return
		}
		value = value[start+3:]
		end := strings.Index(value, "}}")
		if end < 0 {
			c.text(value)
			return
		}
		c.expression(value[:end])
		value = value[end+2:]
	}
}

func (c *collector) expression(source string) {
	expr, err := actionlint.NewExprParser().Parse(actionlint.NewExprLexer(source + "}}"))
	if err != nil {
		c.text(source)
		return
	}
	actionlint.VisitExprNode(expr, func(n, parent actionlint.ExprNode, entering bool) {
		variable, ok := n.(*actionlint.VariableNode)
		if !entering || !ok || (variable.Name != "secrets" && variable.Name != "vars") {
			return
		}
		switch p := parent.(type) {
		case *actionlint.ObjectDerefNode:
			if p.Receiver == n {
				c.add(variable.Name, p.Property)
				return
			}
		case *actionlint.IndexAccessNode:
			if index, ok := p.Index.(*actionlint.StringNode); ok && p.Operand == n {
				c.add(variable.Name, index.Value)
				return
			}
		}
		if variable.Name == "secrets" {
			c.unnamed = true
		}
	})
}

func (c *collector) add(kind, name string) {
	if namePattern.MatchString(name) {
		c.found[kind][strings.ToUpper(name)] = true
	}
}

var (
	namePattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
	// For text that is not YAML or an expression actionlint cannot parse:
	// `secrets.X` and `vars.X` not preceded by a dot or a word, outside
	// comment lines.
	dotted  = regexp.MustCompile(`(?:^|[^\w.])(secrets|vars)\.([A-Za-z_][A-Za-z0-9_]*)`)
	indexed = regexp.MustCompile(`(?:^|[^\w.])(secrets|vars)\[\s*['"]([A-Za-z_][A-Za-z0-9_]*)['"]\s*\]`)
	whole   = regexp.MustCompile(`(?i:tojson)\(\s*secrets\s*\)|(?:^|[^\w.])secrets:\s*inherit\b|(?:^|[^\w.])secrets\[\s*[^'"\s]`)
)

func (c *collector) text(source string) {
	for _, line := range strings.Split(source, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		for _, pattern := range []*regexp.Regexp{dotted, indexed} {
			for _, match := range pattern.FindAllStringSubmatch(line, -1) {
				c.add(match[1], match[2])
			}
		}
		if whole.MatchString(line) {
			c.unnamed = true
		}
	}
}

func sorted(set map[string]bool) []string {
	names := make([]string, 0, len(set))
	for name := range set {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}
