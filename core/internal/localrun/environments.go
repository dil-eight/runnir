package localrun

import (
	"sort"
	"strings"

	"runnir/core/internal/repository"
)

// Environments are the environments whose values a local run can take: those
// the workflows name and, when some job picks its environment with an
// expression, the repository's on GitHub (onGitHub, asked only then), since
// such a job may run in any of them. Names that differ only in case are one
// environment, as on GitHub, spelled as the workflows spell it. Sorted
// ignoring case.
func Environments(workflows []repository.Workflow, onGitHub func() []string) []string {
	seen := map[string]bool{}
	var out []string
	add := func(name string) {
		key := strings.ToLower(name)
		if name == "" || seen[key] {
			return
		}
		seen[key] = true
		out = append(out, name)
	}
	expression := false
	for _, workflow := range workflows {
		for _, job := range workflow.Jobs {
			add(job.Environment)
			expression = expression || job.EnvironmentExpression
		}
	}
	if expression {
		for _, name := range onGitHub() {
			add(name)
		}
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i]) < strings.ToLower(out[j]) })
	return out
}

// andList joins names as "a", "a and b" or "a, b and c".
func andList(names []string) string {
	if len(names) < 2 {
		return strings.Join(names, "")
	}
	return strings.Join(names[:len(names)-1], ", ") + " and " + names[len(names)-1]
}
