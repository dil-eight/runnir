// Package validate checks a repository's workflow files offline with
// actionlint, built into the Core as a library. No external program runs:
// shellcheck and pyflakes integrations stay off.
//
// actionlint reads files on its own when it follows a project (the config,
// reusable workflows named by "uses: ./..."), and it would follow symlinks
// and ".." out of the repository. So it never sees the repository itself:
// the workflow files and the config are read the way the scanner reads them
// (bounded, no symlinks) and copied into a private temporary project that
// is removed afterwards. A file whose local "uses:" climbs out with ".." is
// checked without a project, so nothing outside is read for it. Local
// actions are not checked; actionlint skips actions it cannot find.
package validate

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime/debug"
	"sort"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/rhysd/actionlint"
	"go.yaml.in/yaml/v3"

	"runnir/core/internal/repository"
	"runnir/core/internal/scanner"
)

// ErrUnknownWorkflow: the requested workflow file does not exist.
var ErrUnknownWorkflow = errors.New("no such workflow file")

const (
	maxDiagnostics = 200
	maxMessage     = 1000
)

type Diagnostic struct {
	Line    int
	Column  int
	Kind    string // the actionlint rule, for example "syntax-check" or "expression"
	Message string
}

// Result is one workflow file. Problem is set when it could not be checked.
type Result struct {
	WorkflowID  string
	Diagnostics []Diagnostic
	Problem     string
	// More than maxDiagnostics were found; the first ones are kept.
	Truncated bool
}

type Report struct {
	Results []Result
	// The repository's actionlint config could not be used; checks ran
	// with the defaults.
	ConfigProblem string
	// "actionlint v1.7.12".
	Validator string
}

// actionlint sets package-level state (color output) when a linter is
// created, so checks run one at a time. Each takes milliseconds per file.
var lintMu sync.Mutex

// Workflows checks the workflow files of root, or only the one with id `only`.
func Workflows(ctx context.Context, root, only string) (Report, error) {
	files, err := scanner.ReadWorkflowFiles(ctx, root)
	if err != nil {
		return Report{}, err
	}
	if only != "" && !contains(files, only) {
		return Report{}, ErrUnknownWorkflow
	}
	report := Report{Validator: Validator()}
	configID, config, configErr := scanner.ReadLinterConfig(root)
	if configErr != nil {
		if errors.Is(configErr, repository.ErrAccessDenied) {
			return Report{}, configErr
		}
		report.ConfigProblem = configErr.Error()
		config = nil
	}

	stage, err := os.MkdirTemp("", "runnir-actionlint-")
	if err != nil {
		return Report{}, fmt.Errorf("prepare check: %w", err)
	}
	defer os.RemoveAll(stage)
	workflows := filepath.Join(stage, ".github", "workflows")
	if err := os.MkdirAll(workflows, 0o700); err != nil {
		return Report{}, fmt.Errorf("prepare check: %w", err)
	}
	for _, file := range files {
		if file.Problem == "" {
			if err := os.WriteFile(filepath.Join(stage, filepath.FromSlash(file.ID)), file.Data, 0o600); err != nil {
				return Report{}, fmt.Errorf("prepare check: %w", err)
			}
		}
	}

	lintMu.Lock()
	defer lintMu.Unlock()
	project, problem := stagedProject(stage, configID, config)
	if problem != "" {
		report.ConfigProblem = problem
	}
	linter, err := actionlint.NewLinter(io.Discard, &actionlint.LinterOptions{
		Color:      actionlint.ColorOptionKindNever,
		WorkingDir: stage,
	})
	if err != nil {
		return Report{}, fmt.Errorf("prepare check: %w", err)
	}

	for _, file := range files {
		if only != "" && file.ID != only {
			continue
		}
		if err := ctx.Err(); err != nil {
			return Report{}, err
		}
		result := Result{WorkflowID: file.ID, Problem: file.Problem}
		if file.Problem == "" {
			fileProject := project
			if climbsOut(file.Data) {
				fileProject = nil
			}
			found, err := linter.Lint(filepath.Join(stage, filepath.FromSlash(file.ID)), file.Data, fileProject)
			if err != nil {
				result.Problem = "actionlint could not check this file"
			} else {
				result.Diagnostics, result.Truncated = diagnostics(found, stage)
			}
		}
		report.Results = append(report.Results, result)
	}
	return report, nil
}

// stagedProject writes the config into the staged project when it parses.
// A config actionlint refuses is reported and left out, so the files are
// still checked with the defaults.
func stagedProject(stage, configID string, config []byte) (*actionlint.Project, string) {
	var problem string
	if config != nil {
		path := filepath.Join(stage, filepath.FromSlash(configID))
		if err := os.WriteFile(path, config, 0o600); err == nil {
			project, err := actionlint.NewProject(stage)
			if err == nil {
				return project, ""
			}
			problem = clean(fmt.Sprintf("%s is not a valid actionlint config: %s", configID, err.Error()), stage)
			_ = os.Remove(path)
		}
	}
	project, err := actionlint.NewProject(stage)
	if err != nil {
		return nil, problem
	}
	return project, problem
}

func diagnostics(found []*actionlint.Error, stage string) ([]Diagnostic, bool) {
	sort.SliceStable(found, func(i, j int) bool {
		if found[i].Line != found[j].Line {
			return found[i].Line < found[j].Line
		}
		return found[i].Column < found[j].Column
	})
	truncated := len(found) > maxDiagnostics
	if truncated {
		found = found[:maxDiagnostics]
	}
	out := make([]Diagnostic, 0, len(found))
	for _, e := range found {
		out = append(out, Diagnostic{Line: e.Line, Column: e.Column, Kind: e.Kind, Message: clean(e.Message, stage)})
	}
	return out, truncated
}

// clean removes the staged directory from a message, so it names files the
// way the user sees them, and bounds it as valid UTF-8.
func clean(message, stage string) string {
	message = strings.ReplaceAll(message, stage+string(filepath.Separator), "")
	message = strings.ReplaceAll(message, stage, ".")
	message = strings.ToValidUTF8(message, "�")
	if len(message) > maxMessage {
		cut := maxMessage
		for cut > 0 && !utf8.RuneStart(message[cut]) {
			cut--
		}
		message = message[:cut] + "…"
	}
	return message
}

// climbsOut reports a local "uses: ./..." anywhere in the document whose
// path leaves the repository through "..". A file that does not parse has
// nothing actionlint could follow.
func climbsOut(data []byte) bool {
	var document yaml.Node
	if yaml.Unmarshal(data, &document) != nil {
		return false
	}
	var walk func(node *yaml.Node, depth int) bool
	walk = func(node *yaml.Node, depth int) bool {
		if node == nil || depth > 64 {
			return false
		}
		if node.Kind == yaml.MappingNode {
			for i := 0; i+1 < len(node.Content); i += 2 {
				key, value := node.Content[i], node.Content[i+1]
				for value.Kind == yaml.AliasNode && value.Alias != nil {
					value = value.Alias
				}
				if key.Value == "uses" && value.Kind == yaml.ScalarNode && strings.HasPrefix(value.Value, "./") {
					cleaned := filepath.ToSlash(filepath.Clean(filepath.FromSlash(value.Value)))
					if cleaned == ".." || strings.HasPrefix(cleaned, "../") {
						return true
					}
				}
			}
		}
		for _, child := range node.Content {
			if child.Kind != yaml.AliasNode && walk(child, depth+1) {
				return true
			}
		}
		return false
	}
	return walk(&document, 0)
}

func contains(files []scanner.WorkflowFile, id string) bool {
	for _, file := range files {
		if file.ID == id {
			return true
		}
	}
	return false
}

// Validator names the built-in actionlint and its version.
func Validator() string {
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, dep := range info.Deps {
			if dep.Path == "github.com/rhysd/actionlint" {
				return "actionlint " + dep.Version
			}
		}
	}
	return "actionlint"
}
