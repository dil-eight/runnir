package scanner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"

	"go.yaml.in/yaml/v3"

	"runnir/core/internal/repository"
)

const (
	launchesDir        = ".runnir/launches"
	maxLaunchFiles     = 100
	maxLaunchFileBytes = 64 * 1024
	maxPresetName      = 80
	maxPresetInputs    = 25
	maxInputName       = 100
	maxInputValue      = 4096
	maxRefLength       = 255
)

// ReadLaunchPresets reads the Run Workflow presets a repository shares in
// .runnir/launches. workflows holds the workflow ids (".github/workflows/<file>")
// of the same scan; a preset naming another file is reported, not used.
// Nothing here fails: a problem becomes an entry with Problem set. A missing
// .runnir or launches folder means no presets. Usable presets come first by
// name, then path; entries with a problem follow by path.
func ReadLaunchPresets(ctx context.Context, root string, workflows map[string]bool) []repository.LaunchPreset {
	for _, dir := range []string{".runnir", launchesDir} {
		info, err := os.Lstat(filepath.Join(root, filepath.FromSlash(dir)))
		switch {
		case errors.Is(err, fs.ErrNotExist):
			return nil
		case err != nil:
			// lstat needs to search the folder that holds dir, not dir itself.
			blame := path.Dir(dir)
			if blame == "." {
				blame = dir
			}
			return []repository.LaunchPreset{{Path: blame, Problem: "Can't read " + blame}}
		case info.Mode()&fs.ModeSymlink != 0:
			return []repository.LaunchPreset{{Path: dir, Problem: dir + " is a symbolic link; Runnir does not follow links"}}
		case !info.IsDir():
			return []repository.LaunchPreset{{Path: dir, Problem: dir + " is not a folder"}}
		}
	}
	entries, err := os.ReadDir(filepath.Join(root, filepath.FromSlash(launchesDir)))
	if err != nil {
		return []repository.LaunchPreset{{Path: launchesDir, Problem: "Can't read " + launchesDir}}
	}
	var presets, problems []repository.LaunchPreset
	read := 0
	for _, entry := range entries { // ReadDir returns names sorted
		if ctx.Err() != nil {
			return nil
		}
		ext := strings.ToLower(path.Ext(entry.Name()))
		if entry.IsDir() || (ext != ".yml" && ext != ".yaml") {
			continue
		}
		if read == maxLaunchFiles {
			problems = append(problems, repository.LaunchPreset{Path: launchesDir, Problem: fmt.Sprintf("Only the first %d files are read", maxLaunchFiles)})
			break
		}
		read++
		// gRPC refuses strings that are not valid UTF-8, and one such file
		// name would fail the whole list; the name is only shown.
		rel := path.Join(launchesDir, strings.ToValidUTF8(entry.Name(), "�"))
		if entry.Type()&fs.ModeSymlink != 0 {
			problems = append(problems, repository.LaunchPreset{Path: rel, Problem: "symbolic link; Runnir does not follow links"})
			continue
		}
		data, err := readBounded(filepath.Join(root, filepath.FromSlash(launchesDir), entry.Name()), maxLaunchFileBytes)
		switch {
		case err == errTooLarge:
			problems = append(problems, repository.LaunchPreset{Path: rel, Problem: "file is larger than 64 KiB"})
		case err != nil:
			problems = append(problems, repository.LaunchPreset{Path: rel, Problem: "cannot read file"})
		default:
			if preset := parseLaunchPreset(rel, data, workflows); preset.Problem != "" {
				problems = append(problems, preset)
			} else {
				presets = append(presets, preset)
			}
		}
	}
	sort.SliceStable(presets, func(i, j int) bool {
		if presets[i].Name != presets[j].Name {
			return presets[i].Name < presets[j].Name
		}
		return presets[i].Path < presets[j].Path
	})
	sort.SliceStable(problems, func(i, j int) bool { return problems[i].Path < problems[j].Path })
	return append(presets, problems...)
}

// parseLaunchPreset checks one preset file. Nothing is evaluated: values are
// kept as written. Problem is set, and the other fields are empty, when the
// file cannot be used.
func parseLaunchPreset(rel string, data []byte, workflows map[string]bool) repository.LaunchPreset {
	fail := func(format string, args ...any) repository.LaunchPreset {
		return repository.LaunchPreset{Path: rel, Problem: truncate(fmt.Sprintf(format, args...))}
	}
	decoder := yaml.NewDecoder(bytes.NewReader(data))
	var document yaml.Node
	if err := decoder.Decode(&document); err != nil {
		if err == io.EOF {
			return fail("file is empty")
		}
		return fail("invalid YAML: %s", strings.TrimPrefix(err.Error(), "yaml: "))
	}
	var next yaml.Node
	if err := decoder.Decode(&next); err != io.EOF {
		return fail("file has more than one YAML document")
	}
	if document.Kind != yaml.DocumentNode || len(document.Content) != 1 {
		return fail("file is empty")
	}
	top := resolve(document.Content[0])
	if top.Kind != yaml.MappingNode {
		return fail("a preset must be a mapping of name, workflow, ref and inputs")
	}
	preset := repository.LaunchPreset{Path: rel}
	seen := map[string]bool{}
	for i := 0; i+1 < len(top.Content); i += 2 {
		key, value := top.Content[i], resolve(top.Content[i+1])
		if seen[key.Value] {
			return fail("line %d: %q appears twice", key.Line, key.Value)
		}
		seen[key.Value] = true
		switch key.Value {
		case "name":
			name, ok := scalarText(value)
			name = strings.TrimSpace(name)
			if !ok || name == "" || utf8.RuneCountInString(name) > maxPresetName || strings.ContainsAny(name, "\r\n") {
				return fail("line %d: name must be text of 1 to %d characters on one line", key.Line, maxPresetName)
			}
			preset.Name = name
		case "workflow":
			file, ok := scalarText(value)
			ext := strings.ToLower(path.Ext(file))
			if !ok || file == "." || file == ".." || strings.ContainsAny(file, "/\\") || (ext != ".yml" && ext != ".yaml") {
				return fail("line %d: workflow must be a file name in .github/workflows, such as deploy.yml", key.Line)
			}
			preset.WorkflowPath = path.Join(workflowsDir, file)
		case "ref":
			ref, ok := scalarText(value)
			badRune := strings.IndexFunc(ref, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }) >= 0
			if !ok || ref == "" || len(ref) > maxRefLength || badRune {
				return fail("line %d: ref must be a branch or tag name of at most %d characters without spaces", key.Line, maxRefLength)
			}
			preset.Ref = ref
		case "inputs":
			inputs, problem := launchInputs(value)
			if problem != "" {
				return fail("%s", problem)
			}
			preset.Inputs = inputs
		default:
			return fail("line %d: unknown key %q; a preset has name, workflow, ref and inputs", key.Line, key.Value)
		}
	}
	switch {
	case preset.Name == "":
		return fail("name is missing")
	case preset.WorkflowPath == "":
		return fail("workflow is missing")
	case !workflows[preset.WorkflowPath]:
		return fail("workflow %s is not in .github/workflows", path.Base(preset.WorkflowPath))
	}
	return preset
}

// launchInputs reads the inputs mapping: scalar values only, as written.
func launchInputs(node *yaml.Node) (map[string]string, string) {
	if node.Kind != yaml.MappingNode {
		return nil, fmt.Sprintf("line %d: inputs must be a mapping of input names to values", node.Line)
	}
	if len(node.Content)/2 > maxPresetInputs {
		return nil, fmt.Sprintf("line %d: a preset sets at most %d inputs", node.Line, maxPresetInputs)
	}
	inputs := make(map[string]string, len(node.Content)/2)
	for i := 0; i+1 < len(node.Content); i += 2 {
		key, value := node.Content[i], resolve(node.Content[i+1])
		name := key.Value
		if name == "" || utf8.RuneCountInString(name) > maxInputName {
			return nil, fmt.Sprintf("line %d: input names have 1 to %d characters", key.Line, maxInputName)
		}
		if _, dup := inputs[name]; dup {
			return nil, fmt.Sprintf("line %d: input %q appears twice", key.Line, name)
		}
		text, ok := scalarText(value)
		if !ok {
			return nil, fmt.Sprintf("line %d: input %q needs a text, number or true/false value", key.Line, name)
		}
		if utf8.RuneCountInString(text) > maxInputValue {
			return nil, fmt.Sprintf("line %d: the value of %q is longer than %d characters", key.Line, name, maxInputValue)
		}
		inputs[name] = text
	}
	return inputs, ""
}

// scalarText returns a scalar's text as written; null and non-scalars give false.
func scalarText(node *yaml.Node) (string, bool) {
	if node.Kind != yaml.ScalarNode || node.Tag == "!!null" {
		return "", false
	}
	return node.Value, true
}
