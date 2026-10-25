// Package references finds the secrets and configuration variables a
// workflow file reads. Expressions are not evaluated: a name counts where it
// is written out, so one in a comment counts too.
package references

import (
	"regexp"
	"sort"
	"strings"
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

var (
	dotted  = regexp.MustCompile(`\b(secrets|vars)\.([A-Za-z_][A-Za-z0-9_]*)`)
	indexed = regexp.MustCompile(`\b(secrets|vars)\[\s*['"]([A-Za-z_][A-Za-z0-9_]*)['"]\s*\]`)
	whole   = regexp.MustCompile(`(?i:tojson)\(\s*secrets\s*\)|\bsecrets:\s*inherit\b|\bsecrets\[\s*[^'"\s]`)
)

func Find(source []byte) Names {
	found := map[string]map[string]bool{"secrets": {}, "vars": {}}
	for _, pattern := range []*regexp.Regexp{dotted, indexed} {
		for _, match := range pattern.FindAllSubmatch(source, -1) {
			found[string(match[1])][strings.ToUpper(string(match[2]))] = true
		}
	}
	return Names{Secrets: sorted(found["secrets"]), Variables: sorted(found["vars"]), UnnamedSecrets: whole.Match(source)}
}

func sorted(set map[string]bool) []string {
	names := make([]string, 0, len(set))
	for name := range set {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}
