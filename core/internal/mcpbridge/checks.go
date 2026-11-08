// Package mcpbridge holds the calls MCP clients make until the app answers
// them (docs/superpowers/specs/2026-11-08-mcp-value-sets-design.md). It
// never logs, stores or returns a secret value.
package mcpbridge

import (
	"fmt"
	"strings"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// The limits of one runnir_set_values call; a value's is GitHub's limit for
// a secret.
const (
	MaxNames      = 100
	MaxNameBytes  = 255
	MaxValueBytes = 48 * 1024
)

// Refusal is an answer the MCP client gets as it is: why nothing was done.
type Refusal string

func (r Refusal) Error() string { return string(r) }

// CheckSet refuses a runnir_set_values call the app should not be asked
// about. The refusal names names, never values.
func CheckSet(r *corev1.McpBridgeSetValuesRequest) error {
	if strings.TrimSpace(r.GetRepository()) == "" {
		return Refusal("Name a repository: a registered workspace's folder or its name.")
	}
	if strings.TrimSpace(r.GetSet()) == "" {
		return Refusal("Name a set: \"Repository\" or an environment from runnir_list_value_sets.")
	}
	total := len(r.GetSecrets()) + len(r.GetVariables())
	if total == 0 {
		return Refusal("Give at least one secret or variable.")
	}
	if total > MaxNames {
		return Refusal(fmt.Sprintf("Give at most %d secrets and variables at once; %d were given.", MaxNames, total))
	}
	secrets := map[string]bool{}
	for _, v := range r.GetSecrets() {
		if err := checkValue(v, "secret", secrets); err != nil {
			return err
		}
	}
	variables := map[string]bool{}
	for _, v := range r.GetVariables() {
		if err := checkValue(v, "variable", variables); err != nil {
			return err
		}
		if secrets[v.GetName()] {
			return Refusal(fmt.Sprintf("%s is both a secret and a variable; give it as one of them.", v.GetName()))
		}
	}
	return nil
}

func checkValue(v *corev1.McpValue, kind string, seen map[string]bool) error {
	name := v.GetName()
	if err := checkName(name); err != nil {
		return err
	}
	if seen[name] {
		return Refusal(fmt.Sprintf("%s is given twice.", name))
	}
	seen[name] = true
	if v.GetValue() == "" {
		return Refusal(fmt.Sprintf("The %s %s has no value. To clear a value, use Secrets and Variables in Runnir.", kind, name))
	}
	if len(v.GetValue()) > MaxValueBytes {
		return Refusal(fmt.Sprintf("The %s %s is longer than 48 KiB, GitHub's limit.", kind, name))
	}
	return nil
}

// checkName takes the names GitHub takes: letters, digits and underscores,
// not starting with a digit or GITHUB_. GITHUB_TOKEN is the exception: a
// local run has no token of its own, so a set may give it one.
func checkName(name string) error {
	quoted := name
	if len(quoted) > 64 {
		quoted = quoted[:64] + "…"
	}
	switch {
	case name == "":
		return Refusal("A name is empty.")
	case len(name) > MaxNameBytes:
		return Refusal(fmt.Sprintf("%q is longer than %d characters.", quoted, MaxNameBytes))
	case strings.HasPrefix(strings.ToUpper(name), "GITHUB_") && strings.ToUpper(name) != "GITHUB_TOKEN":
		return Refusal(fmt.Sprintf("%s starts with GITHUB_, which GitHub keeps for itself.", name))
	case name[0] >= '0' && name[0] <= '9':
		return Refusal(fmt.Sprintf("%s starts with a digit.", name))
	}
	for _, c := range name {
		if !(c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') {
			return Refusal(fmt.Sprintf("%q may hold only letters, digits and underscores.", quoted))
		}
	}
	return nil
}
