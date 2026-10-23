# Repository Presets (B25) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Runnir reads Run Workflow presets a repository shares in `.runnir/launches/*.yaml`, lists them in Overview › Run manually and in the Run Workflow preset menu next to the presets kept on this Mac, and applies them to the form, without ever writing those files.

**Architecture:** The Go Core reads and checks the files in the same scan as `.github/workflows` and keeps the result in the repository snapshot; a new gRPC call `ListLaunchPresets` returns it. The app's `CoreHub` reads it wherever it reads workflows and keeps it on `RepositorySession`. The Run Workflow form turns a repository preset into a `DispatchPreset` with an id derived from the workspace and the file, so the existing apply logic and the Overview's `(workflowID, presetID)` callback stay as they are.

**Tech Stack:** Go 1.27 (`go.yaml.in/yaml/v3`, gRPC, `CGO_ENABLED=0`), protobuf with buf v1.65.0, Swift 6 / SwiftUI / Observation / CryptoKit, Swift Testing.

**Spec:** [2026-10-23-repository-presets-design.md](../specs/2026-10-23-repository-presets-design.md)

## Global Constraints

- Runnir never creates, changes or deletes anything under `.runnir`. Nothing is written by opening a repository.
- Only `.runnir/launches/*.yml|*.yaml` (any case) directly in the folder; at most 100 files of at most 64 KiB; symlinked folders or files are never followed.
- Preset keys: `name` (required, 1–80 characters, one line), `workflow` (required, a file name in `.github/workflows` ending `.yml`/`.yaml`, no `/`, `\`, `.`, `..`, matched exactly against the scan), `ref` (optional, 1–255 characters, no whitespace or control characters), `inputs` (optional mapping, at most 25 entries, names 1–100 characters, scalar values of at most 4096 characters, sent as written). Any other key is an error. No `version` field.
- Problems never fail the repository scan; each becomes an entry with `problem` set. Messages are at most 200 bytes of valid UTF-8 (the scanner's `truncate`).
- Usable presets sort by name, then path; entries with a problem follow, by path.
- Values of inputs that look secret (`DispatchPreset.looksSecret`) are never applied from a repository preset and show as `•••` in detail lines.
- No backward compatibility before the first release tag (AGENTS.md): change the contract in place, no version fields.
- Never add AI attribution to commits, code, docs or the PR. Repository text in English.
- New Swift code goes into existing files: the Xcode project lists files by hand (no synchronized groups), so a new file would need `project.pbxproj` edits.
- Verification commands (AGENTS.md): `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build`; `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests`; in `core/`: `go test ./...`, `go vet ./...`, `go build ./...`.

## File Map

| File | Change |
| --- | --- |
| `core/internal/repository/manager.go` | `LaunchPreset` type, `Snapshot.LaunchPresets`, `Manager.LaunchPresets(id)` |
| `core/internal/scanner/launches.go` (new) | Read `.runnir/launches`, parse and check each file |
| `core/internal/scanner/launches_test.go` (new) | Parsing and folder rules |
| `core/internal/scanner/scanner.go` | `Scan` reads presets after workflows |
| `core/internal/repository/manager_test.go` | `LaunchPresets` follows the latest snapshot |
| `contracts/grpc/runnir/core/v1/runnir_core.proto` | `ListLaunchPresets`, `LaunchPreset` |
| `core/internal/gen/...`, `apps/macos/Runnir/IPC/Generated/...` | Regenerated |
| `core/internal/server/service.go`, `server_test.go` | RPC and its test |
| `apps/macos/Runnir/IPC/CoreService.swift` | `CoreLaunchPreset`, `listLaunchPresets` in `CoreServicing` |
| `apps/macos/Runnir/IPC/GRPCCoreService.swift` | Client call |
| `apps/macos/Runnir/IPC/CoreHub.swift` | `launchPresets`, `launchPresetsError`, loading |
| `apps/macos/RunnirTests/CoreHubTests.swift`, `CoreProcessSupervisorTests.swift` | Fakes and hub tests |
| `apps/macos/Runnir/Features/Desktop/DispatchPresets.swift` | Preset id, `dispatchPreset`, detail line, Overview rows |
| `apps/macos/Runnir/Features/Desktop/RunWorkflowSheet.swift` | Form model and preset menu |
| `apps/macos/Runnir/Features/Desktop/OverviewViews.swift` | Run manually groups |
| `apps/macos/RunnirTests/DispatchPresetTests.swift` | Form and row tests |
| Docs listed in Task 7 | Narrowed `.runnir`, B25/B28, contract, screens |

---

### Task 1: Read and check preset files in the Core

**Files:**
- Modify: `core/internal/repository/manager.go` (types next to `Workflow`)
- Create: `core/internal/scanner/launches.go`
- Test: `core/internal/scanner/launches_test.go`

**Interfaces:**
- Produces: `repository.LaunchPreset{Path, Name, WorkflowPath, Ref string; Inputs map[string]string; Problem string}`; `repository.Snapshot.LaunchPresets []LaunchPreset`; `scanner.ReadLaunchPresets(ctx context.Context, root string, workflows map[string]bool) []repository.LaunchPreset`; constants `maxLaunchFiles = 100`, `maxLaunchFileBytes = 64 * 1024`.

- [ ] **Step 1: Add the types**

In `core/internal/repository/manager.go`, add `LaunchPresets` to `Snapshot` and the new type after `Job`:

```go
type Snapshot struct {
	Branch string
	// OriginHost is the origin remote's host, lowercased; OriginRepository
	// its "owner/name". Both empty without a readable origin.
	OriginHost       string
	OriginRepository string
	Workflows        []Workflow
	// LaunchPresets are the Run Workflow presets of .runnir/launches, with
	// entries for files or folders that cannot be used.
	LaunchPresets []LaunchPreset
}
```

```go
// LaunchPreset is one file of .runnir/launches: a Run Workflow preset the
// repository shares, or, with Problem set, why a file or folder there cannot
// be used.
type LaunchPreset struct {
	// Path is ".runnir/launches/<file>", or ".runnir" or ".runnir/launches"
	// for an entry about that folder.
	Path string
	Name string
	// WorkflowPath is ".github/workflows/<file>".
	WorkflowPath string
	// Ref is empty when the preset keeps the form's branch.
	Ref    string
	Inputs map[string]string
	// Problem is empty for a usable preset.
	Problem string
}
```

- [ ] **Step 2: Write the failing tests**

Create `core/internal/scanner/launches_test.go` (it reuses `write` and `scan` from `scanner_test.go`):

```go
package scanner

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"unicode/utf8"

	"runnir/core/internal/repository"
)

var deployOnly = map[string]bool{".github/workflows/deploy.yml": true}

func readPresets(t *testing.T, root string) []repository.LaunchPreset {
	t.Helper()
	return ReadLaunchPresets(context.Background(), root, deployOnly)
}

func onePreset(t *testing.T, content string) repository.LaunchPreset {
	t.Helper()
	root := t.TempDir()
	write(t, root, ".runnir/launches/p.yaml", content)
	got := readPresets(t, root)
	if len(got) != 1 {
		t.Fatalf("presets = %+v", got)
	}
	return got[0]
}

func manyInputs(n int) string {
	var b strings.Builder
	for i := 0; i < n; i++ {
		fmt.Fprintf(&b, "  i%d: v\n", i)
	}
	return b.String()
}

func TestAValidPresetIsRead(t *testing.T) {
	got := onePreset(t, "name: Deploy to staging\nworkflow: deploy.yml\nref: main\ninputs:\n  environment: staging\n  dry_run: false\n  replicas: 3\n")
	want := repository.LaunchPreset{Path: ".runnir/launches/p.yaml", Name: "Deploy to staging", WorkflowPath: ".github/workflows/deploy.yml",
		Ref: "main", Inputs: map[string]string{"environment": "staging", "dry_run": "false", "replicas": "3"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("preset = %+v", got)
	}
}

func TestRefAndInputsAreOptional(t *testing.T) {
	got := onePreset(t, "name: Plain\nworkflow: deploy.yml\n")
	if got.Problem != "" || got.Ref != "" || len(got.Inputs) != 0 || got.Name != "Plain" {
		t.Fatalf("preset = %+v", got)
	}
}

func TestExpressionsAndAliasesStayText(t *testing.T) {
	got := onePreset(t, "name: &n Deploy\nworkflow: deploy.yml\ninputs:\n  sha: ${{ github.sha }}\n  label: *n\n")
	if got.Problem != "" || got.Inputs["sha"] != "${{ github.sha }}" || got.Inputs["label"] != "Deploy" {
		t.Fatalf("preset = %+v", got)
	}
}

func TestUnusablePresetsSayWhy(t *testing.T) {
	cases := map[string]struct{ content, want string }{
		"empty":              {"", "file is empty"},
		"invalid yaml":       {"name: [unclosed\n", "invalid YAML: line"},
		"two documents":      {"name: A\nworkflow: deploy.yml\n---\nname: B\n", "more than one"},
		"not a mapping":      {"- name: A\n", "mapping"},
		"unknown key":        {"name: A\nworkflow: deploy.yml\ntarget: local\n", `"target"`},
		"duplicate key":      {"name: A\nname: B\nworkflow: deploy.yml\n", ""},
		"missing name":       {"workflow: deploy.yml\n", "name is missing"},
		"blank name":         {"name: '  '\nworkflow: deploy.yml\n", "name must be"},
		"long name":          {"name: " + strings.Repeat("n", 81) + "\nworkflow: deploy.yml\n", "name must be"},
		"null name":          {"name:\nworkflow: deploy.yml\n", "name must be"},
		"missing workflow":   {"name: A\n", "workflow is missing"},
		"workflow path":      {"name: A\nworkflow: .github/workflows/deploy.yml\n", "file name"},
		"workflow dotdot":    {"name: A\nworkflow: ..\n", "file name"},
		"workflow extension": {"name: A\nworkflow: deploy.json\n", "file name"},
		"unknown workflow":   {"name: A\nworkflow: preview.yml\n", "preview.yml is not in .github/workflows"},
		"case mismatch":      {"name: A\nworkflow: Deploy.yml\n", "is not in .github/workflows"},
		"ref with space":     {"name: A\nworkflow: deploy.yml\nref: my branch\n", "ref must be"},
		"long ref":           {"name: A\nworkflow: deploy.yml\nref: " + strings.Repeat("r", 256) + "\n", "ref must be"},
		"inputs not a map":   {"name: A\nworkflow: deploy.yml\ninputs: [a]\n", "inputs must be"},
		"null input":         {"name: A\nworkflow: deploy.yml\ninputs:\n  a:\n", `"a" needs`},
		"nested input":       {"name: A\nworkflow: deploy.yml\ninputs:\n  a: {b: c}\n", `"a" needs`},
		"long value":         {"name: A\nworkflow: deploy.yml\ninputs:\n  a: " + strings.Repeat("v", 4097) + "\n", "longer than 4096"},
		"too many inputs":    {"name: A\nworkflow: deploy.yml\ninputs:\n" + manyInputs(26), "at most 25"},
	}
	for label, c := range cases {
		got := onePreset(t, c.content)
		if got.Problem == "" || !strings.Contains(got.Problem, c.want) {
			t.Errorf("%s: problem = %q, want it to mention %q", label, got.Problem, c.want)
		}
		if got.Path != ".runnir/launches/p.yaml" {
			t.Errorf("%s: path = %q", label, got.Path)
		}
	}
}

func TestProblemsStayShortAndValidUTF8(t *testing.T) {
	got := onePreset(t, "name: A\nworkflow: deploy.yml\n"+strings.Repeat("é", 300)+": x\n")
	if got.Problem == "" || len(got.Problem) > maxErrorChars || !utf8.ValidString(got.Problem) {
		t.Fatalf("problem = %q", got.Problem)
	}
}

func TestNoRunnirFolderMeansNoPresets(t *testing.T) {
	root := t.TempDir()
	if got := readPresets(t, root); len(got) != 0 {
		t.Fatalf("no .runnir: %+v", got)
	}
	write(t, root, ".runnir/notes.txt", "x")
	if got := readPresets(t, root); len(got) != 0 {
		t.Fatalf("no launches: %+v", got)
	}
	if err := os.MkdirAll(filepath.Join(root, ".runnir", "launches"), 0o755); err != nil {
		t.Fatal(err)
	}
	if got := readPresets(t, root); len(got) != 0 {
		t.Fatalf("empty launches: %+v", got)
	}
}

func TestSymlinkedFoldersAreNotFollowed(t *testing.T) {
	outside := t.TempDir()
	write(t, outside, "launches/p.yaml", "name: Leak\nworkflow: deploy.yml\n")
	for dir, target := range map[string]string{".runnir": outside, ".runnir/launches": filepath.Join(outside, "launches")} {
		root := t.TempDir()
		if err := os.MkdirAll(filepath.Join(root, ".runnir"), 0o755); err != nil {
			t.Fatal(err)
		}
		link := filepath.Join(root, filepath.FromSlash(dir))
		_ = os.Remove(link) // .runnir itself is replaced by the link
		if err := os.Symlink(target, link); err != nil {
			t.Fatal(err)
		}
		got := readPresets(t, root)
		if len(got) != 1 || got[0].Path != dir || !strings.Contains(got[0].Problem, "symbolic link") {
			t.Errorf("%s: presets = %+v", dir, got)
		}
	}
}

func TestLaunchesAsAFileIsReported(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".runnir/launches", "not a folder")
	got := readPresets(t, root)
	if len(got) != 1 || got[0].Path != ".runnir/launches" || !strings.Contains(got[0].Problem, "not a folder") {
		t.Fatalf("presets = %+v", got)
	}
}

func TestUnreadableLaunchesFolderIsReported(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("permission bits are not enforced here")
	}
	root := t.TempDir()
	write(t, root, ".runnir/launches/p.yaml", "name: A\nworkflow: deploy.yml\n")
	dir := filepath.Join(root, ".runnir", "launches")
	if err := os.Chmod(dir, 0); err != nil {
		t.Fatal(err)
	}
	defer os.Chmod(dir, 0o755)
	got := readPresets(t, root)
	if len(got) != 1 || got[0].Path != ".runnir/launches" || !strings.Contains(got[0].Problem, "Can't read") {
		t.Fatalf("presets = %+v", got)
	}
}

func TestOnlyBoundedYAMLFilesAreReadInOrder(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	write(t, outside, "leak.yaml", "name: Leak\nworkflow: deploy.yml\n")
	write(t, root, ".runnir/launches/b.yaml", "name: Beta\nworkflow: deploy.yml\n")
	write(t, root, ".runnir/launches/a.YML", "name: Alpha\nworkflow: deploy.yml\n")
	write(t, root, ".runnir/launches/README.md", "docs")
	write(t, root, ".runnir/launches/nested/c.yaml", "name: Nested\nworkflow: deploy.yml\n")
	write(t, root, ".runnir/launches/big.yaml", "name: Big\nworkflow: deploy.yml\n#"+strings.Repeat("x", maxLaunchFileBytes))
	if err := os.Symlink(filepath.Join(outside, "leak.yaml"), filepath.Join(root, ".runnir", "launches", "link.yaml")); err != nil {
		t.Fatal(err)
	}
	got := readPresets(t, root)
	var paths []string
	for _, p := range got {
		paths = append(paths, p.Path)
	}
	want := []string{".runnir/launches/a.YML", ".runnir/launches/b.yaml", ".runnir/launches/big.yaml", ".runnir/launches/link.yaml"}
	if !reflect.DeepEqual(paths, want) {
		t.Fatalf("paths = %v", paths)
	}
	if got[0].Name != "Alpha" || got[1].Name != "Beta" || !strings.Contains(got[2].Problem, "64 KiB") || !strings.Contains(got[3].Problem, "symbolic link") {
		t.Fatalf("presets = %+v", got)
	}
}

func TestAtMostAHundredFilesAreRead(t *testing.T) {
	root := t.TempDir()
	for i := 0; i <= maxLaunchFiles; i++ {
		write(t, root, fmt.Sprintf(".runnir/launches/p%03d.yaml", i), fmt.Sprintf("name: P%03d\nworkflow: deploy.yml\n", i))
	}
	got := readPresets(t, root)
	if len(got) != maxLaunchFiles+1 {
		t.Fatalf("entries = %d", len(got))
	}
	if got[maxLaunchFiles-1].Name != "P099" {
		t.Fatalf("last preset = %+v", got[maxLaunchFiles-1])
	}
	if last := got[maxLaunchFiles]; last.Path != ".runnir/launches" || !strings.Contains(last.Problem, "first 100") {
		t.Fatalf("folder entry = %+v", last)
	}
}

func TestSharedNamesSortByFile(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".runnir/launches/z.yaml", "name: Same\nworkflow: deploy.yml\n")
	write(t, root, ".runnir/launches/a.yaml", "name: Same\nworkflow: deploy.yml\n")
	got := readPresets(t, root)
	if len(got) != 2 || got[0].Path != ".runnir/launches/a.yaml" || got[1].Path != ".runnir/launches/z.yaml" {
		t.Fatalf("presets = %+v", got)
	}
}
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `cd core && go test ./internal/scanner/ -run 'Preset|Runnir|Launches|Bounded|Hundred|SharedNames|Symlinked' 2>&1 | head -20`
Expected: build failure, `undefined: ReadLaunchPresets` (and `maxLaunchFiles`, `maxLaunchFileBytes`).

- [ ] **Step 4: Implement `launches.go`**

Create `core/internal/scanner/launches.go`:

```go
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
			return []repository.LaunchPreset{{Path: dir, Problem: "Can't read " + dir}}
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
		rel := path.Join(launchesDir, entry.Name())
		if entry.Type()&fs.ModeSymlink != 0 {
			problems = append(problems, repository.LaunchPreset{Path: rel, Problem: "symbolic link; Runnir does not follow links"})
			continue
		}
		data, err := readBounded(filepath.Join(root, filepath.FromSlash(rel)), maxLaunchFileBytes)
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
```

- [ ] **Step 5: Run the tests to see them pass**

Run: `cd core && go test ./internal/scanner/ -v -run 'Preset|Runnir|Launches|Bounded|Hundred|SharedNames|Symlinked|UTF8' 2>&1 | tail -25`
Expected: every listed test `PASS`. If "invalid yaml" fails because yaml.v3 words the error without "line", print the problem, keep the prefix "invalid YAML: " and change the case's `want` to `"invalid YAML"` only when the message still carries the line number elsewhere (the spec requires the line).

- [ ] **Step 6: Commit**

```bash
git add core/internal/repository/manager.go core/internal/scanner/launches.go core/internal/scanner/launches_test.go
git commit -m "Core: read and check repository presets in .runnir/launches"
```

---

### Task 2: Presets in the scan and the repository manager

**Files:**
- Modify: `core/internal/scanner/scanner.go:53-62` (`Scan`)
- Modify: `core/internal/repository/manager.go` (after `Workflows`)
- Test: `core/internal/scanner/launches_test.go`, `core/internal/repository/manager_test.go`

**Interfaces:**
- Consumes: `ReadLaunchPresets` from Task 1.
- Produces: `func (m *Manager) LaunchPresets(id string) ([]LaunchPreset, error)` returning `ErrNotFound` for an unknown or unopened id.

- [ ] **Step 1: Write the failing tests**

Append to `core/internal/scanner/launches_test.go`:

```go
func TestScanChecksPresetsAgainstItsWorkflows(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".github/workflows/deploy.yml", "on: workflow_dispatch\njobs: {}\n")
	write(t, root, ".runnir/launches/ok.yaml", "name: Deploy\nworkflow: deploy.yml\n")
	write(t, root, ".runnir/launches/missing.yaml", "name: Preview\nworkflow: preview.yml\n")
	got := scan(t, root).LaunchPresets
	if len(got) != 2 || got[0].Name != "Deploy" || got[0].Problem != "" || !strings.Contains(got[1].Problem, "preview.yml") {
		t.Fatalf("presets = %+v", got)
	}
}

func TestPresetProblemsNeverFailTheScan(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".github/workflows/ci.yml", "on: push\njobs: {}\n")
	write(t, root, ".runnir", "a file, not a folder")
	snapshot := scan(t, root)
	if len(snapshot.Workflows) != 1 || len(snapshot.LaunchPresets) != 1 || snapshot.LaunchPresets[0].Path != ".runnir" {
		t.Fatalf("snapshot = %+v", snapshot)
	}
}
```

Append to `core/internal/repository/manager_test.go`:

```go
func TestLaunchPresetsComeFromTheLatestSnapshot(t *testing.T) {
	var name atomic.Value
	name.Store("First")
	scanner := &fakeScanner{scan: func(context.Context, string) (Snapshot, error) {
		return Snapshot{LaunchPresets: []LaunchPreset{{Path: ".runnir/launches/p.yaml", Name: name.Load().(string)}}}, nil
	}}
	m, _ := newManager(scanner)
	info, err := m.Open(context.Background(), dir(t))
	if err != nil {
		t.Fatal(err)
	}
	presets, err := m.LaunchPresets(info.ID)
	if err != nil || len(presets) != 1 || presets[0].Name != "First" {
		t.Fatalf("presets = %v, %v", presets, err)
	}
	name.Store("Second")
	if _, err := m.Refresh(context.Background(), info.ID); err != nil {
		t.Fatal(err)
	}
	if presets, _ := m.LaunchPresets(info.ID); len(presets) != 1 || presets[0].Name != "Second" {
		t.Fatalf("after refresh = %v", presets)
	}
	if _, err := m.LaunchPresets("repo_nope"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unknown id = %v", err)
	}
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd core && go test ./internal/scanner/ ./internal/repository/ -run 'ScanChecksPresets|PresetProblemsNever|LaunchPresetsComeFrom' 2>&1 | tail -10`
Expected: build failure `m.LaunchPresets undefined`; with it stubbed, the scanner tests fail with `presets = []`.

- [ ] **Step 3: Implement**

In `core/internal/scanner/scanner.go`, `Scan` becomes:

```go
func (Scanner) Scan(ctx context.Context, root string) (repository.Snapshot, error) {
	if err := ctx.Err(); err != nil {
		return repository.Snapshot{}, err
	}
	if err := probeReadable(root); err != nil {
		return repository.Snapshot{}, err
	}
	workflows, err := readWorkflows(ctx, root)
	if err != nil {
		return repository.Snapshot{}, err
	}
	ids := make(map[string]bool, len(workflows))
	for _, workflow := range workflows {
		ids[workflow.ID] = true
	}
	snapshot := repository.Snapshot{Workflows: workflows, LaunchPresets: ReadLaunchPresets(ctx, root, ids)}
	if err := ctx.Err(); err != nil {
		return repository.Snapshot{}, err
	}
	if gitDir, linked, ok := resolveGitDir(root); ok {
		snapshot.Branch = readBranch(gitDir)
		snapshot.OriginHost, snapshot.OriginRepository = readOrigin(gitDir, linked)
	}
	return snapshot, nil
}
```

Update the package comment's first sentence in `scanner.go` to: `// Package scanner reads a repository's current branch, GitHub Actions workflow files and the Run Workflow presets in .runnir/launches.` (keep the rest of the comment).

In `core/internal/repository/manager.go`, after `Workflows`:

```go
// LaunchPresets returns the .runnir/launches presets of the latest published
// snapshot.
func (m *Manager) LaunchPresets(id string) ([]LaunchPreset, error) {
	e, err := m.lookupReady(id)
	if err != nil {
		return nil, err
	}
	e.mu.RLock()
	defer e.mu.RUnlock()
	return append([]LaunchPreset(nil), e.snap.LaunchPresets...), nil
}
```

- [ ] **Step 4: Run the package tests**

Run: `cd core && go test ./internal/scanner/ ./internal/repository/ 2>&1 | tail -5`
Expected: `ok runnir/core/internal/scanner` and `ok runnir/core/internal/repository`.

- [ ] **Step 5: Commit**

```bash
git add core/internal/scanner/scanner.go core/internal/scanner/launches_test.go core/internal/repository/manager.go core/internal/repository/manager_test.go
git commit -m "Core: keep repository presets in the repository snapshot"
```

---

### Task 3: `ListLaunchPresets` in the contract and the Core

**Files:**
- Modify: `contracts/grpc/runnir/core/v1/runnir_core.proto`
- Regenerate: `core/internal/gen/runnir/core/v1/*`, `apps/macos/Runnir/IPC/Generated/runnir/core/v1/*`
- Modify: `core/internal/server/service.go` (after `ListWorkflows`)
- Test: `core/internal/server/server_test.go`

**Interfaces:**
- Consumes: `Manager.LaunchPresets` from Task 2.
- Produces: RPC `ListLaunchPresets(ListLaunchPresetsRequest{repository_id}) returns (ListLaunchPresetsResponse{repeated LaunchPreset presets})`; `LaunchPreset{path=1, name=2, workflow_path=3, ref=4, map<string,string> inputs=5, problem=6}`. Generated Swift: `Runnir_Core_V1_ListLaunchPresetsRequest`, `Runnir_Core_V1_LaunchPreset` (fields `path`, `name`, `workflowPath`, `ref`, `inputs`, `problem`), client method `listLaunchPresets(_:options:)`.

- [ ] **Step 1: Write the failing server test**

Append to `core/internal/server/server_test.go`:

```go
func TestListLaunchPresetsOverGRPC(t *testing.T) {
	path := socketPath(t)
	stop := start(t, path)
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	must := func(err error) {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
	}
	must(os.MkdirAll(filepath.Join(root, ".github", "workflows"), 0o755))
	must(os.WriteFile(filepath.Join(root, ".github", "workflows", "deploy.yml"), []byte("on: workflow_dispatch\njobs: {}\n"), 0o644))
	must(os.MkdirAll(filepath.Join(root, ".runnir", "launches"), 0o755))
	must(os.WriteFile(filepath.Join(root, ".runnir", "launches", "staging.yaml"),
		[]byte("name: Staging\nworkflow: deploy.yml\nref: main\ninputs:\n  environment: staging\n"), 0o644))

	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: root})
	if err != nil {
		t.Fatal(err)
	}
	listed, err := client.ListLaunchPresets(ctx, &corev1.ListLaunchPresetsRequest{RepositoryId: opened.Repository.Id})
	if err != nil || len(listed.Presets) != 1 {
		t.Fatalf("list = %v, %v", listed, err)
	}
	p := listed.Presets[0]
	if p.Path != ".runnir/launches/staging.yaml" || p.Name != "Staging" || p.WorkflowPath != ".github/workflows/deploy.yml" ||
		p.Ref != "main" || p.Inputs["environment"] != "staging" || p.Problem != "" {
		t.Fatalf("preset = %v", p)
	}

	// A file added on disk shows after a refresh, never before.
	must(os.WriteFile(filepath.Join(root, ".runnir", "launches", "broken.yaml"), []byte("name: Broken\nworkflow: missing.yml\n"), 0o644))
	if before, _ := client.ListLaunchPresets(ctx, &corev1.ListLaunchPresetsRequest{RepositoryId: opened.Repository.Id}); len(before.Presets) != 1 {
		t.Fatalf("before refresh = %v", before)
	}
	if _, err := client.RefreshRepository(ctx, &corev1.RefreshRepositoryRequest{RepositoryId: opened.Repository.Id}); err != nil {
		t.Fatal(err)
	}
	again, err := client.ListLaunchPresets(ctx, &corev1.ListLaunchPresetsRequest{RepositoryId: opened.Repository.Id})
	if err != nil || len(again.Presets) != 2 || again.Presets[1].Path != ".runnir/launches/broken.yaml" || again.Presets[1].Problem == "" {
		t.Fatalf("after refresh = %v, %v", again, err)
	}

	_, err = client.ListLaunchPresets(ctx, &corev1.ListLaunchPresetsRequest{RepositoryId: "repo_nope"})
	if status.Code(err) != codes.NotFound {
		t.Fatalf("unknown id = %v", err)
	}
}
```

- [ ] **Step 2: Add the RPC and messages to the contract**

In `contracts/grpc/runnir/core/v1/runnir_core.proto`, after `rpc ListWorkflows(ListWorkflowsRequest) returns (ListWorkflowsResponse);`:

```proto
  // Run Workflow presets the repository shares in .runnir/launches, read in
  // the same scan as its workflows. Runnir never writes these files.
  rpc ListLaunchPresets(ListLaunchPresetsRequest) returns (ListLaunchPresetsResponse);
```

After `message Job { ... }`:

```proto
message ListLaunchPresetsRequest {
  string repository_id = 1;
}

message ListLaunchPresetsResponse {
  // Usable presets by name, then path; entries with a problem after them, by path.
  repeated LaunchPreset presets = 1;
}

message LaunchPreset {
  // ".runnir/launches/<file>", or ".runnir" / ".runnir/launches" for a problem with that folder.
  string path = 1;
  string name = 2;
  // ".github/workflows/<file>".
  string workflow_path = 3;
  // Empty: keep the branch the form has.
  string ref = 4;
  map<string, string> inputs = 5;
  // Why the entry cannot be used; empty when it can. Other fields are empty then.
  string problem = 6;
}
```

In the file's header comment, replace `// this package; breaking changes require a new package version.` and the line before it (`// Every repository-scoped call carries repository_id. Additive changes keep`) with:

```proto
// Every repository-scoped call carries repository_id. Until the first release
// tag the contract changes in place (AGENTS.md); from then on additive changes
// keep this package and breaking changes require a new package version.
```

- [ ] **Step 3: Build the Swift generators and regenerate**

The Go generators on this Mac already match CI (buf 1.65.0, protoc-gen-go v1.36.11, protoc-gen-go-grpc 1.6.1; check with `buf --version; protoc-gen-go --version; protoc-gen-go-grpc --version`). The Swift plugins are built outside the repository, exactly as CI does:

```bash
PLUGINS="${TMPDIR:-/tmp}/runnir-protoc-plugins"
mkdir -p "$PLUGINS"
for spec in apple/swift-protobuf@1.39.0@protoc-gen-swift grpc/grpc-swift-protobuf@2.5.0@protoc-gen-grpc-swift-2; do
  repo=${spec%%@*}; rest=${spec#*@}; tag=${rest%%@*}; product=${rest#*@}
  dir="$PLUGINS/${repo#*/}"
  [ -d "$dir" ] || git clone --quiet --depth 1 --branch "$tag" "https://github.com/$repo.git" "$dir"
  swift build -c release --product "$product" --package-path "$dir"
  PATH="$(swift build -c release --show-bin-path --package-path "$dir"):$PATH"
done
export PATH="$(go env GOPATH)/bin:$PATH"
sh scripts/generate-contracts.sh
git status --short contracts core/internal/gen apps/macos/Runnir/IPC/Generated
```

Expected: `buf lint` passes; the proto and the four generated files (`runnir_core.pb.go`, `runnir_core_grpc.pb.go`, `runnir_core.pb.swift`, `runnir_core.grpc.swift`) are modified, nothing else.

- [ ] **Step 4: Run the server test to see it fail**

Run: `cd core && go test ./internal/server/ -run TestListLaunchPresetsOverGRPC 2>&1 | tail -5`
Expected: FAIL with `code = Unimplemented`.

- [ ] **Step 5: Implement the RPC**

In `core/internal/server/service.go`, after `ListWorkflows`:

```go
// ListLaunchPresets returns the .runnir/launches presets of the latest scan.
func (s *service) ListLaunchPresets(_ context.Context, request *corev1.ListLaunchPresetsRequest) (*corev1.ListLaunchPresetsResponse, error) {
	presets, err := s.repositories.LaunchPresets(request.GetRepositoryId())
	if err != nil {
		return nil, rpcError(err)
	}
	out := &corev1.ListLaunchPresetsResponse{Presets: make([]*corev1.LaunchPreset, 0, len(presets))}
	for _, p := range presets {
		out.Presets = append(out.Presets, &corev1.LaunchPreset{
			Path: p.Path, Name: p.Name, WorkflowPath: p.WorkflowPath, Ref: p.Ref, Inputs: p.Inputs, Problem: p.Problem,
		})
	}
	return out, nil
}
```

- [ ] **Step 6: Run all Core checks**

Run: `cd core && go test ./... 2>&1 | tail -25 && go vet ./... && go build ./...`
Expected: every package `ok`, no vet output.

- [ ] **Step 7: Commit**

```bash
git add contracts/grpc/runnir/core/v1/runnir_core.proto core/internal/gen apps/macos/Runnir/IPC/Generated core/internal/server/service.go core/internal/server/server_test.go
git commit -m "Contract: ListLaunchPresets returns a repository's presets"
```

---

### Task 4: The app reads repository presets

**Files:**
- Modify: `apps/macos/Runnir/IPC/CoreService.swift` (model after `CoreWorkflow`; protocol after `listWorkflows`)
- Modify: `apps/macos/Runnir/IPC/GRPCCoreService.swift` (after `listWorkflows`)
- Modify: `apps/macos/Runnir/IPC/CoreHub.swift` (`RepositorySession` fields; `attach` relink reset; `open`, `refresh`, `reloadWorkflows`)
- Modify: `apps/macos/RunnirTests/CoreProcessSupervisorTests.swift` (`FakeService`)
- Test: `apps/macos/RunnirTests/CoreHubTests.swift` (`FakeCore` and new tests)

**Interfaces:**
- Consumes: generated `Runnir_Core_V1_*` from Task 3.
- Produces: `struct CoreLaunchPreset: Equatable, Identifiable, Sendable { path, name, workflowPath: String; ref: String?; inputs: [String: String]; problem: String?; var id: String { path } }`; `CoreServicing.listLaunchPresets(repositoryID:) async throws -> [CoreLaunchPreset]`; `RepositorySession.launchPresets: [CoreLaunchPreset]`, `RepositorySession.launchPresetsError: String?`; test helpers `FakeCore.setLaunchPresets(_:for:)`, `FakeCore.failLaunchPresets(with:)`.

- [ ] **Step 1: Add the model and the protocol requirement**

In `apps/macos/Runnir/IPC/CoreService.swift`, after `struct CoreWorkflow`:

```swift
/// A Run Workflow preset the repository shares in .runnir/launches, or, with
/// `problem` set, a file or folder there that cannot be used.
struct CoreLaunchPreset: Equatable, Identifiable, Sendable {
    /// ".runnir/launches/<file>", or ".runnir" / ".runnir/launches" for an
    /// entry about that folder.
    let path: String
    let name: String
    /// ".github/workflows/<file>"; empty with a problem.
    let workflowPath: String
    /// nil keeps the form's branch.
    let ref: String?
    let inputs: [String: String]
    let problem: String?

    var id: String { path }
}
```

In `protocol CoreServicing`, after `func listWorkflows(repositoryID: String) async throws -> [CoreWorkflow]`:

```swift
    /// The repository's presets in .runnir/launches from the Core's latest
    /// scan, with entries for files it cannot use.
    func listLaunchPresets(repositoryID: String) async throws -> [CoreLaunchPreset]
```

In `apps/macos/Runnir/IPC/GRPCCoreService.swift`, after `listWorkflows`:

```swift
    func listLaunchPresets(repositoryID: String) async throws -> [CoreLaunchPreset] {
        let response = try await call { try await client.listLaunchPresets(.with { $0.repositoryID = repositoryID }, options: Self.options(Self.callTimeout)) }
        return response.presets.map { preset in
            CoreLaunchPreset(path: preset.path, name: preset.name, workflowPath: preset.workflowPath,
                             ref: preset.ref.isEmpty ? nil : preset.ref, inputs: preset.inputs,
                             problem: preset.problem.isEmpty ? nil : preset.problem)
        }
    }
```

In `apps/macos/RunnirTests/CoreProcessSupervisorTests.swift`, in `FakeService` after its `listWorkflows`:

```swift
    func listLaunchPresets(repositoryID: String) async throws -> [CoreLaunchPreset] { throw CoreServiceError.unavailable }
```

In `apps/macos/RunnirTests/CoreHubTests.swift`, in `FakeCore` after its `listWorkflows`:

```swift
    private var launchPresets: [String: [CoreLaunchPreset]] = [:]
    private var launchPresetsError: CoreServiceError?
    func setLaunchPresets(_ list: [CoreLaunchPreset], for path: String) { lock.withLock { launchPresets[Self.id(for: path)] = list } }
    func failLaunchPresets(with error: CoreServiceError?) { lock.withLock { launchPresetsError = error } }
    func listLaunchPresets(repositoryID: String) async throws -> [CoreLaunchPreset] {
        try lock.withLock {
            if let launchPresetsError { throw launchPresetsError }
            return launchPresets[repositoryID] ?? []
        }
    }
```

- [ ] **Step 2: Write the failing hub tests**

In `apps/macos/RunnirTests/CoreHubTests.swift`, next to the private `workflow(_:)` helper:

```swift
private func launchPreset(_ name: String) -> CoreLaunchPreset {
    CoreLaunchPreset(path: ".runnir/launches/\(name).yaml", name: name, workflowPath: ".github/workflows/deploy.yml",
                     ref: nil, inputs: [:], problem: nil)
}
```

Inside `struct CoreHubTests`:

```swift
    @Test
    func repositoryPresetsArriveWithTheRepositoryAndFollowRefreshesAndEvents() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        provider.core.setLaunchPresets([launchPreset("a")], for: "/repo/a")
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/a")
        #expect(await eventually { hub.session(for: workspace)?.launchPresets.map(\.name) == ["a"] })

        provider.core.setLaunchPresets([launchPreset("a"), launchPreset("b")], for: "/repo/a")
        await hub.refresh(workspaceID: workspace)
        #expect(hub.session(for: workspace)?.launchPresets.count == 2)

        provider.core.setLaunchPresets([launchPreset("c")], for: "/repo/a")
        provider.core.push(coreEvent(.repositoryRefreshed, repository: FakeCore.id(for: "/repo/a"), sequence: 5))
        #expect(await eventually { hub.session(for: workspace)?.launchPresets.map(\.name) == ["c"] })
    }

    @Test
    func aFailedPresetReadKeepsTheLastListAndNeverFailsTheRepository() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        provider.core.setLaunchPresets([launchPreset("a")], for: "/repo/a")
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/a")
        #expect(await eventually { hub.session(for: workspace)?.launchPresets.count == 1 })

        provider.core.failLaunchPresets(with: .timedOut)
        await hub.refresh(workspaceID: workspace)
        let session = hub.session(for: workspace)
        #expect(session?.launchPresets.count == 1)
        #expect(session?.launchPresetsError != nil)
        #expect(session?.phase == .ready && session?.refreshError == nil)

        provider.core.failLaunchPresets(with: nil)
        await hub.refresh(workspaceID: workspace)
        #expect(hub.session(for: workspace)?.launchPresetsError == nil)
    }
```

- [ ] **Step 3: Run the tests to see them fail**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/CoreHubTests 2>&1 | tail -20`
Expected: build failure, `value of type 'RepositorySession' has no member 'launchPresets'`.

- [ ] **Step 4: Implement loading in `CoreHub`**

In `RepositorySession` (`CoreHub.swift`), after `fileprivate(set) var workflows: [CoreWorkflow] = []`:

```swift
    /// Run Workflow presets the repository shares in .runnir/launches, with
    /// entries for files that cannot be used, as the Core last read them.
    fileprivate(set) var launchPresets: [CoreLaunchPreset] = []
    /// Why the last read of `launchPresets` failed; the previous list stays.
    fileprivate(set) var launchPresetsError: String?
```

In `attach`, where a relink resets the session (`existing.workflows = []`), add after that line:

```swift
            existing.launchPresets = []
            existing.launchPresetsError = nil
```

Add to `CoreHub` next to `reloadWorkflows`:

```swift
    /// Reads the repository's presets. A failed read keeps the last list and
    /// says why; it never fails opening or refreshing the repository.
    private func loadLaunchPresets(of session: RepositorySession, coreID: String, service: any CoreServicing) async {
        func isCurrent() -> Bool { sessions[session.workspaceID] === session && session.coreID == coreID }
        do {
            let presets = try await service.listLaunchPresets(repositoryID: coreID)
            guard isCurrent() else { return }
            session.launchPresets = presets
            session.launchPresetsError = nil
        } catch {
            guard isCurrent() else { return }
            session.launchPresetsError = Self.describe(error)
        }
    }
```

In `open(_:force:)`, after `session.phase = .ready`:

```swift
            Task { await loadLaunchPresets(of: session, coreID: repository.id, service: service) }
```

In `refresh(workspaceID:)`, after `session.refreshError = nil`:

```swift
            await loadLaunchPresets(of: session, coreID: coreID, service: service)
```

In `reloadWorkflows(of:)`, inside the `Task`, after `session.workflows = workflows`:

```swift
            await self.loadLaunchPresets(of: session, coreID: coreID, service: service)
```

- [ ] **Step 5: Run the tests**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/CoreHubTests 2>&1 | grep -E "passed|failed|error:" | tail -10`
Expected: the suite passes, including the two new tests.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Runnir/IPC/CoreService.swift apps/macos/Runnir/IPC/GRPCCoreService.swift apps/macos/Runnir/IPC/CoreHub.swift apps/macos/RunnirTests/CoreHubTests.swift apps/macos/RunnirTests/CoreProcessSupervisorTests.swift
git commit -m "App: read repository presets with the repository"
```

---

### Task 5: Repository presets in Run Workflow

**Files:**
- Modify: `apps/macos/Runnir/Features/Desktop/DispatchPresets.swift` (end of file)
- Modify: `apps/macos/Runnir/Features/Desktop/RunWorkflowSheet.swift` (`DispatchFormModel` presets section, `load()`, `presetControl`, `presetTitle`)
- Test: `apps/macos/RunnirTests/DispatchPresetTests.swift` (new suite at the end)

**Interfaces:**
- Consumes: `RepositorySession.launchPresets`, `CoreLaunchPreset`, `FakeCore.setLaunchPresets` from Task 4.
- Produces: `CoreLaunchPreset.isUsable: Bool`, `CoreLaunchPreset.fileName: String`, `CoreLaunchPreset.dispatchPreset(workspaceID:) -> DispatchPreset`, `static CoreLaunchPreset.presetID(workspaceID: UUID, path: String) -> UUID`; `DispatchFormModel.repositoryPresets: [DispatchPreset]`, `.appliedPresetIsShared: Bool`, `.appliedPresetFile: String?`.

- [ ] **Step 1: Write the failing tests**

Append to `apps/macos/RunnirTests/DispatchPresetTests.swift`:

```swift
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RepositoryPresetFormTests {
    private let workflow = CoreGitHubWorkflow(id: 1, name: "Deploy", path: ".github/workflows/deploy.yml", state: "active", htmlURL: nil)
    private let inputs = [
        CoreDispatchInput(name: "environment", description: "", kind: .choice, required: true, defaultValue: "staging", options: ["staging", "production"]),
        CoreDispatchInput(name: "version", description: "", kind: .string, required: false, defaultValue: "", options: []),
        CoreDispatchInput(name: "deploy_token", description: "", kind: .string, required: false, defaultValue: "", options: []),
    ]
    private let production = CoreLaunchPreset(path: ".runnir/launches/production.yaml", name: "Production", workflowPath: ".github/workflows/deploy.yml",
                                              ref: "main", inputs: ["environment": "production", "deploy_token": "ghp_from_git"], problem: nil)

    /// `openWith` is the repository preset the Overview hands to the sheet.
    private func rig(_ launchPresets: [CoreLaunchPreset], openWith: CoreLaunchPreset? = nil) async -> (DispatchFormModel, DispatchPresetLibrary, UUID, URL) {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        provider.core.setBranch("feature", for: "/repo/linked")
        provider.core.setLaunchPresets(launchPresets, for: "/repo/linked")
        provider.core.dispatchDefinition = CoreDispatchDefinition(access: .ok, dispatchable: true, inputs: inputs, parseError: nil)
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        _ = await eventually {
            hub.session(for: workspace)?.githubAccess == .ok && hub.session(for: workspace)?.launchPresets.count == launchPresets.count
        }
        let directory = temporaryDirectory()
        let library = DispatchPresetLibrary(store: FileDispatchPresetStore(directory: directory))
        let form = DispatchFormModel(workspaceID: workspace, hub: hub, workflows: [workflow], workflowID: workflow.id,
                                     currentBranch: "feature", presets: library,
                                     presetID: openWith.map { CoreLaunchPreset.presetID(workspaceID: workspace, path: $0.path) })
        await form.load()
        return (form, library, workspace, directory)
    }

    @Test
    func presetIDsAreStableAndDistinct() {
        let workspace = UUID()
        let id = CoreLaunchPreset.presetID(workspaceID: workspace, path: ".runnir/launches/a.yaml")
        #expect(id == CoreLaunchPreset.presetID(workspaceID: workspace, path: ".runnir/launches/a.yaml"))
        #expect(id != CoreLaunchPreset.presetID(workspaceID: workspace, path: ".runnir/launches/b.yaml"))
        #expect(id != CoreLaunchPreset.presetID(workspaceID: UUID(), path: ".runnir/launches/a.yaml"))
        #expect(id.uuidString.dropFirst(14).first == "5")
    }

    @Test
    func repositoryPresetsAreOfferedApartFromThoseOnThisMac() async throws {
        let other = CoreLaunchPreset(path: ".runnir/launches/other.yaml", name: "Other", workflowPath: ".github/workflows/ci.yml",
                                     ref: nil, inputs: [:], problem: nil)
        let broken = CoreLaunchPreset(path: ".runnir/launches/broken.yaml", name: "", workflowPath: "", ref: nil, inputs: [:],
                                      problem: "name is missing")
        let (form, library, workspace, directory) = await rig([production, other, broken])
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try #require(library.add(name: "Mine", workspaceID: workspace, workflowPath: workflow.path, ref: "feature", inputs: [:]))
        #expect(form.repositoryPresets.map(\.name) == ["Production"])
        #expect(form.availablePresets.map(\.name) == ["Mine"])
    }

    @Test
    func applyingARepositoryPresetLeavesOutValuesThatLookSecret() async throws {
        let (form, _, _, directory) = await rig([production])
        defer { try? FileManager.default.removeItem(at: directory) }
        let preset = try #require(form.repositoryPresets.first)
        form.apply(preset)
        #expect(await eventually { form.ref == "main" && !form.isLoadingDefinition && form.values["environment"] == "production" })
        #expect(form.values["deploy_token"] == "")
        #expect(form.presetNotes == ["Not applied because it looks secret: deploy_token."])
        #expect(form.appliedPresetIsShared)
        #expect(form.appliedPresetFile == ".runnir/launches/production.yaml")
        #expect(!form.presetIsModified)
        form.values["version"] = "2.0"
        #expect(form.presetIsModified)
    }

    @Test
    func aRepositoryPresetIsOnlyCopiedNeverChangedHere() async throws {
        let (form, library, workspace, directory) = await rig([production])
        defer { try? FileManager.default.removeItem(at: directory) }
        let preset = try #require(form.repositoryPresets.first)
        form.apply(preset)
        #expect(await eventually { form.ref == "main" && !form.isLoadingDefinition && form.values["environment"] == "production" })
        #expect(!form.updateAppliedPreset())
        #expect(!form.renameAppliedPreset(to: "Renamed"))
        form.deleteAppliedPreset()
        #expect(form.appliedPresetID == preset.id)

        #expect(form.saveAsPreset(named: "My production"))
        let copy = try #require(library.presets(workspaceID: workspace, workflowPath: workflow.path).first)
        #expect(copy.ref == "main" && copy.inputs == ["environment": "production", "version": ""])
        #expect(!form.appliedPresetIsShared)
    }

    @Test
    func aRepositoryPresetWithoutABranchKeepsTheFormsBranch() async throws {
        let plain = CoreLaunchPreset(path: ".runnir/launches/plain.yaml", name: "Plain", workflowPath: workflow.path,
                                     ref: nil, inputs: ["version": "1.0"], problem: nil)
        let (form, _, _, directory) = await rig([plain])
        defer { try? FileManager.default.removeItem(at: directory) }
        form.apply(try #require(form.repositoryPresets.first))
        #expect(form.ref == "feature")
        #expect(form.values["version"] == "1.0")
        #expect(form.presetNotes.isEmpty)
        #expect(!form.presetIsModified)
    }

    @Test
    func aRepositoryPresetChosenOnTheOverviewIsAppliedWhenTheSheetOpens() async {
        let (form, _, workspace, directory) = await rig([production], openWith: production)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await eventually { form.values["environment"] == "production" })
        #expect(form.appliedPresetID == CoreLaunchPreset.presetID(workspaceID: workspace, path: production.path))
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/RepositoryPresetFormTests 2>&1 | tail -20`
Expected: build failure, `type 'CoreLaunchPreset' has no member 'presetID'`.

- [ ] **Step 3: Add the preset helpers**

In `apps/macos/Runnir/Features/Desktop/DispatchPresets.swift`, add `import CryptoKit` under `import Foundation`, and at the end of the file:

```swift
// MARK: Repository presets

extension CoreLaunchPreset {
    /// Whether the Run Workflow form can use it.
    var isUsable: Bool { problem == nil }

    /// The file name for a problem row, or the folder for an entry about it.
    var fileName: String {
        let folder = ".runnir/launches/"
        return path.hasPrefix(folder) ? String(path.dropFirst(folder.count)) : path
    }

    /// The preset as the Run Workflow form applies it. Its branch is empty
    /// when the preset keeps the form's.
    func dispatchPreset(workspaceID: UUID) -> DispatchPreset {
        DispatchPreset(id: Self.presetID(workspaceID: workspaceID, path: path), name: name, workspaceID: workspaceID,
                       workflowPath: workflowPath, ref: ref ?? "", inputs: inputs, updatedAt: .distantPast)
    }

    /// A name-based id from the workspace and the file, so a preset keeps it
    /// across rescans and the Overview can hand it to Run Workflow.
    static func presetID(workspaceID: UUID, path: String) -> UUID {
        var b = Array(SHA256.hash(data: Data((workspaceID.uuidString + "\n" + path).utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50 // version 5: name-based
        b[8] = (b[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
```

- [ ] **Step 4: Teach the form about repository presets**

In `RunWorkflowSheet.swift`, `DispatchFormModel`:

Replace the `initialPresetID` block in `load()`:

```swift
        if let initialPresetID, let preset = (repositoryPresets + availablePresets).first(where: { $0.id == initialPresetID }) {
            apply(preset)
        }
```

Replace `appliedPreset` and add the repository members after `availablePresets`:

```swift
    /// Presets the repository shares for the selected workflow, usable ones
    /// only, as the Core last read them.
    var repositoryPresets: [DispatchPreset] {
        guard let path = selectedWorkflow?.path, let workspaceID, let session = hub.session(for: workspaceID) else { return [] }
        return session.launchPresets.filter { $0.isUsable && $0.workflowPath == path }.map { $0.dispatchPreset(workspaceID: workspaceID) }
    }

    var appliedPreset: DispatchPreset? {
        guard let appliedPresetID else { return nil }
        return (repositoryPresets + availablePresets).first { $0.id == appliedPresetID }
    }

    /// The applied preset comes from the repository: it is changed by editing
    /// its file, never here.
    var appliedPresetIsShared: Bool {
        guard let appliedPresetID else { return false }
        return repositoryPresets.contains { $0.id == appliedPresetID }
    }

    /// The file of the applied repository preset, for the menu's hint.
    var appliedPresetFile: String? {
        guard let appliedPresetID, let workspaceID, let session = hub.session(for: workspaceID) else { return nil }
        return session.launchPresets.first { CoreLaunchPreset.presetID(workspaceID: workspaceID, path: $0.path) == appliedPresetID }?.path
    }
```

Replace `presetIsModified`:

```swift
    /// The form no longer matches what applying the preset gives: its branch
    /// when it has one, the workflow's defaults with its values on top. Inputs
    /// that look secret are left out on both sides.
    var presetIsModified: Bool {
        guard let preset = appliedPreset else { return false }
        if !preset.ref.isEmpty && preset.ref != ref { return true }
        let inputs = definition?.inputs ?? []
        let secret = Set(inputs.filter(DispatchPreset.looksSecret).map(\.name))
        let kept = Set(presetValues.keys)
        var expected = Self.initialValues(for: inputs).filter { kept.contains($0.key) }
        for (name, value) in preset.inputs where kept.contains(name) { expected[name] = value }
        return expected != presetValues || preset.inputs.keys.contains { !kept.contains($0) && !secret.contains($0) }
    }
```

In `apply(_:)`, a preset without a branch keeps the form's:

```swift
    func apply(_ preset: DispatchPreset) {
        appliedPresetID = preset.id
        presetNotes = []
        let known = (refs?.branches ?? []) + (refs?.tags ?? [])
        if !preset.ref.isEmpty, preset.ref != ref, known.contains(preset.ref) {
            pendingPreset = preset
            select(ref: preset.ref)
            return
        }
        if !preset.ref.isEmpty, preset.ref != ref {
            presetNotes.append("The preset's branch \(preset.ref) no longer exists on GitHub; \(ref) is kept.")
        }
        if let definition, !isLoadingDefinition, definition.access == .ok, definition.parseError == nil {
            overlay(preset, inputs: definition.inputs)
        } else {
            pendingPreset = preset
        }
    }
```

In `overlay(_:inputs:)`, right after `guard let input = byName[name] else { ... }`:

```swift
            if DispatchPreset.looksSecret(input) {
                // GitHub logs dispatch inputs; presets on this Mac never hold
                // such values, a file in the repository might.
                presetNotes.append("Not applied because it looks secret: \(name).")
                continue
            }
```

Guard the three changing operations:

```swift
    @discardableResult
    func updateAppliedPreset() -> Bool {
        guard canSavePreset, !appliedPresetIsShared, let id = appliedPresetID,
              presets?.update(id, ref: ref, inputs: presetValues) == true else { return false }
        presetNotes = []
        return true
    }

    @discardableResult
    func renameAppliedPreset(to name: String) -> Bool {
        guard let id = appliedPresetID, !appliedPresetIsShared else { return false }
        return presets?.rename(id, to: name) == true
    }

    func deleteAppliedPreset() {
        guard let id = appliedPresetID, !appliedPresetIsShared, presets?.delete(id) == true else { return }
        appliedPresetID = nil
        presetNotes = []
    }
```

- [ ] **Step 5: Group the menu**

In the sheet view, replace the `Menu { ... }` content of `presetControl` and add a helper:

```swift
                Menu {
                    if model.repositoryPresets.isEmpty {
                        ForEach(model.availablePresets) { presetButton($0) }
                    } else {
                        Section("In This Repository") {
                            ForEach(model.repositoryPresets) { presetButton($0) }
                        }
                        if !model.availablePresets.isEmpty {
                            Section("On This Mac") {
                                ForEach(model.availablePresets) { presetButton($0) }
                            }
                        }
                    }
                    if !model.availablePresets.isEmpty || !model.repositoryPresets.isEmpty { Divider() }
                    Button("Save as New Preset...") { presetName = ""; presetPrompt = .save }.disabled(!model.canSavePreset)
                    if let applied = model.appliedPreset {
                        if model.appliedPresetIsShared {
                            Text("Edit \(model.appliedPresetFile ?? ".runnir/launches") to change this preset")
                        } else {
                            Button("Update \"\(applied.name)\"") { model.updateAppliedPreset() }
                                .disabled(!model.canSavePreset || !model.presetIsModified)
                            Button("Rename \"\(applied.name)\"...") { presetName = applied.name; presetPrompt = .rename }
                            Button("Delete \"\(applied.name)\"...", role: .destructive) { confirmingDelete = true }
                        }
                    }
                } label: {
                    Label(presetTitle, systemImage: "bookmark")
                }
```

```swift
    private func presetButton(_ preset: DispatchPreset) -> some View {
        Button { model.apply(preset) } label: {
            if preset.id == model.appliedPresetID { Label(preset.name, systemImage: "checkmark") } else { Text(preset.name) }
        }
    }
```

In `presetTitle`, replace `model.availablePresets.isEmpty` with `model.availablePresets.isEmpty && model.repositoryPresets.isEmpty`.

- [ ] **Step 6: Run the preset and form tests**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/RepositoryPresetFormTests -only-testing:RunnirTests/DispatchPresetFormTests -only-testing:RunnirTests/DispatchFormModelTests 2>&1 | grep -E "passed|failed|error:" | tail -15`
Expected: all three suites pass; the existing `DispatchPresetFormTests` still pass with the new `presetIsModified`.

- [ ] **Step 7: Commit**

```bash
git add apps/macos/Runnir/Features/Desktop/DispatchPresets.swift apps/macos/Runnir/Features/Desktop/RunWorkflowSheet.swift apps/macos/RunnirTests/DispatchPresetTests.swift
git commit -m "App: apply repository presets in Run Workflow"
```

---

### Task 6: Overview › Run manually shows repository presets

**Files:**
- Modify: `apps/macos/Runnir/Features/Desktop/DispatchPresets.swift` (end of file)
- Modify: `apps/macos/Runnir/Features/Desktop/OverviewViews.swift` (`runManually`, `presetDetail`, new helpers)
- Test: `apps/macos/RunnirTests/DispatchPresetTests.swift` (new suite)

**Interfaces:**
- Consumes: `CoreLaunchPreset.isUsable`, `.fileName`, `.presetID(workspaceID:path:)` from Task 5; `RepositorySession.launchPresets`, `.launchPresetsError` from Task 4.
- Produces: `enum RepositoryPresetRow: Equatable, Identifiable { case preset(CoreLaunchPreset, workflow: CoreGitHubWorkflow?); case problem(CoreLaunchPreset); case unreadable(String) }` with `static func rows(presets:remoteWorkflows:readError:) -> [RepositoryPresetRow]`; `static DispatchPreset.detail(workflow: String, ref: String, inputs: [String: String]) -> String`.

- [ ] **Step 1: Write the failing tests**

Append to `apps/macos/RunnirTests/DispatchPresetTests.swift`:

```swift
@Suite
struct RepositoryPresetRowTests {
    private let deploy = CoreGitHubWorkflow(id: 1, name: "Deploy", path: ".github/workflows/deploy.yml", state: "active", htmlURL: nil)

    @Test
    func rowsFollowTheCoreAndFindTheirWorkflows() {
        let staging = CoreLaunchPreset(path: ".runnir/launches/staging.yaml", name: "Staging", workflowPath: ".github/workflows/deploy.yml",
                                       ref: "main", inputs: [:], problem: nil)
        let preview = CoreLaunchPreset(path: ".runnir/launches/preview.yaml", name: "Preview", workflowPath: ".github/workflows/preview.yml",
                                       ref: nil, inputs: [:], problem: nil)
        let broken = CoreLaunchPreset(path: ".runnir/launches/broken.yaml", name: "", workflowPath: "", ref: nil, inputs: [:],
                                      problem: "name is missing")
        let rows = RepositoryPresetRow.rows(presets: [staging, preview, broken], remoteWorkflows: [deploy], readError: "The Core is not available.")
        #expect(rows == [.preset(staging, workflow: deploy), .preset(preview, workflow: nil), .problem(broken), .unreadable("The Core is not available.")])
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(broken.fileName == "broken.yaml")
        #expect(RepositoryPresetRow.rows(presets: [], remoteWorkflows: [deploy], readError: nil).isEmpty)
    }

    @Test
    func detailLinesHideValuesThatLookSecret() {
        #expect(DispatchPreset.detail(workflow: "Deploy", ref: "main", inputs: ["environment": "staging", "deploy_token": "ghp_x"])
                == "Deploy · main · deploy_token=••• · environment=staging")
        #expect(DispatchPreset.detail(workflow: "Deploy", ref: "", inputs: [:]) == "Deploy")
    }
}
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/RepositoryPresetRowTests 2>&1 | tail -20`
Expected: build failure, `cannot find 'RepositoryPresetRow' in scope`.

- [ ] **Step 3: Add the row model and the detail line**

At the end of `apps/macos/Runnir/Features/Desktop/DispatchPresets.swift`:

```swift
extension DispatchPreset {
    /// "Deploy · main · environment=staging": the workflow, the branch when
    /// set, then the values by name, with values of inputs that look secret
    /// hidden.
    static func detail(workflow: String, ref: String, inputs: [String: String]) -> String {
        let values = inputs.sorted { $0.key < $1.key }.map { name, value in
            let hidden = looksSecret(CoreDispatchInput(name: name, description: "", kind: .string, required: false, defaultValue: "", options: []))
            return "\(name)=\(hidden ? "•••" : value)"
        }
        return ([workflow] + (ref.isEmpty ? [] : [ref]) + values).joined(separator: " · ")
    }
}

/// One row of Overview › Run manually's repository group.
enum RepositoryPresetRow: Equatable, Identifiable {
    /// A usable preset; `workflow` is GitHub's workflow for its file, nil
    /// when GitHub's list does not have it.
    case preset(CoreLaunchPreset, workflow: CoreGitHubWorkflow?)
    /// A file or folder that cannot be used.
    case problem(CoreLaunchPreset)
    /// The presets could not be read; the reason.
    case unreadable(String)

    var id: String {
        switch self {
        case .preset(let preset, _): "preset:" + preset.path
        case .problem(let preset): "problem:" + preset.path
        case .unreadable: "unreadable"
        }
    }

    /// The Core's order (usable presets by name, then problems), then a row
    /// for a failed read.
    static func rows(presets: [CoreLaunchPreset], remoteWorkflows: [CoreGitHubWorkflow], readError: String?) -> [RepositoryPresetRow] {
        var rows = presets.map { preset -> RepositoryPresetRow in
            preset.isUsable ? .preset(preset, workflow: remoteWorkflows.first { $0.path == preset.workflowPath }) : .problem(preset)
        }
        if let readError { rows.append(.unreadable(readError)) }
        return rows
    }
}
```

- [ ] **Step 4: Show the groups in the Overview**

In `apps/macos/Runnir/Features/Desktop/OverviewViews.swift`, replace `runManually` and `presetDetail`:

```swift
    private var runManually: some View {
        let available = session?.githubAccess == .ok
        let rows: [(DispatchPreset, CoreGitHubWorkflow)] = (session?.remoteWorkflows ?? []).flatMap { workflow in
            presets.presets(workspaceID: workspaceID, workflowPath: workflow.path).map { ($0, workflow) }
        }
        let shared = RepositoryPresetRow.rows(presets: session?.launchPresets ?? [], remoteWorkflows: session?.remoteWorkflows ?? [],
                                              readError: session?.launchPresetsError)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title: "RUN MANUALLY")
                Spacer()
                Button("New...") { runWorkflow(nil, nil) }.buttonStyle(.link).font(.system(size: 12)).disabled(!available)
            }
            DesignDivider()
            // Reading works, but starting waits for an owner's approval or
            // for write access: said where workflows are started.
            if available, let repository = session?.githubRepository,
               let blocker = GitHubAccessHelp.blocker(for: .run, repository: repository, details: session?.githubDetails) {
                GitHubAccessNotice(help: blocker, style: .note, github: github).padding(.vertical, 6)
            }
            if !shared.isEmpty {
                presetGroup("IN THIS REPOSITORY", symbol: "folder.badge.gearshape", source: ".runnir/launches")
                ForEach(shared) { row in
                    sharedRow(row, available: available)
                    DesignDivider()
                }
                presetGroup("ON THIS MAC", symbol: "laptopcomputer", source: nil)
            }
            if rows.isEmpty {
                Text(available ? "Presets you save in Run Workflow appear here." : "Running workflows needs access to the repository on GitHub.")
                    .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground).padding(.vertical, 6)
            }
            ForEach(rows, id: \.0.id) { preset, workflow in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preset.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(DispatchPreset.detail(workflow: workflow.name, ref: preset.ref, inputs: preset.inputs))
                            .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Run") { runWorkflow(workflow.id, preset.id) }
                        .buttonStyle(DesignButtonStyle()).disabled(!available || workflow.state != "active")
                        .help("Review and start \(workflow.name) with this preset")
                }.padding(.vertical, 4)
                DesignDivider()
            }
            if !shared.isEmpty {
                Label("Repository presets are shared through Git. Runnir reads them and never changes them.", systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(RunnirTheme.mutedForeground).padding(.top, 4)
            }
        }
    }

    private func presetGroup(_ title: String, symbol: String, source: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title).fontWeight(.semibold).tracking(0.6)
            Spacer(minLength: 8)
            if let source { Text(source).font(.system(size: 11, design: .monospaced)) }
        }
        .font(.system(size: 10)).foregroundStyle(RunnirTheme.mutedForeground).padding(.top, 8)
    }

    @ViewBuilder private func sharedRow(_ row: RepositoryPresetRow, available: Bool) -> some View {
        switch row {
        case .preset(let preset, let workflow):
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text(sharedDetail(preset, workflow: workflow, available: available))
                        .font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button("Run") {
                    if let workflow { runWorkflow(workflow.id, CoreLaunchPreset.presetID(workspaceID: workspaceID, path: preset.path)) }
                }
                .buttonStyle(DesignButtonStyle()).disabled(!available || workflow?.state != "active")
                .help(workflow.map { "Review and start \($0.name) with this preset" } ?? "This workflow is not on GitHub yet")
            }.padding(.vertical, 4)
        case .problem(let preset):
            problemRow(title: preset.fileName, detail: preset.problem ?? "")
        case .unreadable(let reason):
            problemRow(title: ".runnir/launches", detail: "Repository presets could not be read. \(reason)")
        }
    }

    private func sharedDetail(_ preset: CoreLaunchPreset, workflow: CoreGitHubWorkflow?, available: Bool) -> String {
        let name = workflow?.name ?? (preset.workflowPath as NSString).lastPathComponent
        let detail = DispatchPreset.detail(workflow: name, ref: preset.ref ?? "", inputs: preset.inputs)
        // GitHub's list is known only with access; without it every Run is off anyway.
        return workflow == nil && available ? detail + " · not on GitHub yet" : detail
    }

    private func problemRow(title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(RunnirTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(RunnirTheme.secondaryForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 6)
    }
```

(The old `presetDetail(_:workflow:)` is removed; its only caller now uses `DispatchPreset.detail`.)

- [ ] **Step 5: Build and run the new tests**

Run: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests/RepositoryPresetRowTests 2>&1 | grep -E "passed|failed|error:" | tail -10`
Expected: the suite passes.

- [ ] **Step 6: Commit**

```bash
git add apps/macos/Runnir/Features/Desktop/DispatchPresets.swift apps/macos/Runnir/Features/Desktop/OverviewViews.swift apps/macos/RunnirTests/DispatchPresetTests.swift
git commit -m "App: repository presets in Overview › Run manually"
```

---

### Task 7: Documents, full verification and a live check

**Files:**
- Modify: `docs/architecture/workspace-persistence.md`, `docs/decisions/0003-workspaces-sessions-offline-storage.md`, `docs/product/specification.md`, `docs/product/mvp-implementation-checklist.md`, `docs/architecture/grpc-api.md`, `docs/design/screens-and-states.md`, `docs/superpowers/specs/2026-10-23-repository-presets-design.md`

- [ ] **Step 1: Narrow `.runnir` in `workspace-persistence.md`**

- Status line: replace "No .runnir loader, local file index or environment subsystem exists yet." with "The Core reads Run Workflow presets from `.runnir/launches` (B25, [design](../superpowers/specs/2026-10-23-repository-presets-design.md)); there is no local file index or environment subsystem."
- In the storage tree, replace the three `.runnir` lines with `<repo>/.runnir/launches/*.yaml          # optional portable Run Workflow presets (implemented, read-only)`.
- Replace the whole section "Portable Configuration Examples" from "Examples are proposed schema v1" down to (and including) the paragraph that starts "keychain:// is an illustrative reference" and the precedence paragraph, with:

```markdown
`.runnir` holds only `launches/*.yaml`: Run Workflow presets a team shares through Git. Runnir reads them and never creates, changes or deletes them; the format, limits and error handling are in the [B25 design](../superpowers/specs/2026-10-23-repository-presets-design.md). `config.yaml` and `environments.yaml` from the earlier plan are not introduced: nothing would use them.

Secrets never go into `.runnir`. Plan for local runs (B28, not implemented): the secrets a run needs are the `secrets.X` the workflow itself references; for each one the user enters a value for this run, or keeps it in Keychain for this workspace, and a kept value is shown only after Touch ID or the password. Values reach act through its environment (`-s NAME`), never argv, disk, the database or logs. Environment variables come from the user's own tools (dotenvx, `.env`, act's files) rather than a Runnir format. GitHub Actions secrets stay on GitHub.
```

- Keep "Malformed/missing/unsupported config..." but reword it to: "A malformed or unusable preset file is listed with its problem and never used; the workspace opens normally. Opening never writes to the working tree. Local-only presets stay machine-private in `dispatch-presets.json`."
- In the acceptance table, W02 becomes: "Safe optional YAML parse of `.runnir/launches`, limits/traversal/symlink denial and degraded opening", and W03/W04 rows get "(B28)". In "State on 2026-10-22", add a sentence: "W02 is covered by Core tests of `.runnir/launches` (2026-10-23)."

- [ ] **Step 2: ADR 0003, specification and screens**

- ADR 0003 status line: replace "portable config pending" with "portable Run Workflow presets in `.runnir/launches` implemented 2026-10-23; config and environment files not introduced". In Decisions, the `.runnir` bullet becomes: "- .runnir contains optional portable Run Workflow presets (`launches/*.yaml`). Runnir only reads them; creating or editing them is the user's. Machine overrides, cache, session and credentials never belong there."
- `specification.md` line 85: replace "Read optional .runnir config/environments/launches safely and read-only on open." with "Read optional `.runnir/launches` presets safely and read-only on open."; line 87: replace "portable .runnir launch presets require explicit creation/editing" with "portable `.runnir/launches` presets are written by the user, never by Runnir"; line 95: replace "Keep portable non-secret .runnir configuration" with "Keep portable non-secret `.runnir/launches` presets".
- `screens-and-states.md`: append to the S03 states cell ", repository presets with an unusable file (Run manually)"; append to the S06 states cell ", preset menu with repository and Mac presets"; append to the S16 and S17 rows' last cell " · drawn for the earlier plan; revisited in B28".

- [ ] **Step 3: Checklist and gRPC document**

- `mvp-implementation-checklist.md`:
  - B09 row, "Missing for acceptance": replace `Portable \`.runnir\` presets (B25)` with `—`; append to its "State" cell "; presets from `.runnir/launches` (B25) listed and applied next to them".
  - Add after the B09 row:

```markdown
| B25 | Run Workflow presets from `.runnir/launches` read and checked in the Core's repository scan (no symlinks, at most 100 files of 64 KiB, exact workflow match, unknown keys refused, problems listed per file and never failing the scan); `ListLaunchPresets`; Overview › Run manually groups presets "in this repository" and "on this Mac" with unusable files shown; the Run Workflow menu offers both, applies a repository preset like a Mac one, leaves out values that look secret and copies it to this Mac on "Save as New"; Runnir never writes `.runnir` | Signed-build check |
```

  - "Not started" line: replace "B18–B25 and B28–B29" with "B18–B24 and B28–B29".
  - B25 line in the lifecycle track: `- [ ] B25 / F2: Read-only Run Workflow presets from \`.runnir/launches\` (config and environment files not introduced); bounds/schema/traversal/degraded-opening tests.`
  - B28 line: `- [ ] B28 / F5: Secrets for local runs from the workflow's own \`secrets.X\` references: entered for one run or kept in Keychain per workspace, shown only after Touch ID or the password, passed to act through its environment; environment variables from the user's tools (dotenvx, \`.env\`); no Runnir format for either.`
- `grpc-api.md`: in the RPC list, after `ListWorkflows`, add "`ListLaunchPresets` (the `.runnir/launches` presets of the latest scan, with a problem per unusable file; never written by the Core)".

- [ ] **Step 4: Spec status**

In the spec's status line, replace "design approved on 2026-10-23, not implemented yet." with "design approved and implemented on 2026-10-23 ([plan](../plans/2026-10-23-repository-presets.md)). Change made while planning: instead of a `PresetChoice` enum, a repository preset gets a name-based id from the workspace and its file (`CoreLaunchPreset.presetID`), so the Overview's `(workflowID, presetID)` callback and the form's apply logic stay as they were; `CoreLaunchPreset` lives in `CoreService.swift` next to `CoreWorkflow`."

- [ ] **Step 5: Full verification**

Run, from the repository root:

```bash
(cd core && go test ./... && go vet ./... && go build ./...)
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build 2>&1 | tail -3
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests 2>&1 | grep -E "Test run with|passed|failed" | tail -5
```

Expected: Go packages `ok`, no vet output, `** BUILD SUCCEEDED **`, and the RunnirTests run reports every test passed. Report any failure with its output instead of continuing.

- [ ] **Step 6: Live check in the test copy**

1. Make a scratch repository: `S=$TMPDIR/b25-live; mkdir -p $S/repo/.github/workflows $S/repo/.runnir/launches $S/state; cd $S/repo && git init -q && git remote add origin https://github.com/<a repository the signed-in test account can read>.git`; add `.github/workflows/deploy.yml` with `on: workflow_dispatch` and an `environment` choice input; add `staging.yaml` (valid), `preview.yaml` (workflow `preview.yml`, missing) and `broken.yaml` (`name: [`).
2. Build the test copy: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' -derivedDataPath $S/dd PRODUCT_BUNDLE_IDENTIFIER=com.dileight.runnir.alertcheck build`.
3. Run it with its own state: `RUNNIR_UI_TEST_STATE_DIRECTORY=$S/state RUNNIR_UI_TEST_IMPORT_PATHS=$S/repo $S/dd/Build/Products/Debug/Runnir.app/Contents/MacOS/Runnir --ui-testing`.
4. Check with screenshots: Overview › Run manually shows "IN THIS REPOSITORY · .runnir/launches" with Staging, then warning rows for `broken.yaml` and `preview.yaml`, then "ON THIS MAC" and the footnote; Run on Staging opens Run Workflow with the preset applied; the preset menu shows "In This Repository" and the edit hint; adding `qa.yaml` on disk appears after Refresh. Nothing under `$S/repo/.runnir` changed (`git -C $S/repo status --short` lists only the files you added).
5. Record the result in one sentence at the end of the B25 row's evidence in `workspace-persistence.md` ("Live check on <date> in the Debug test copy: ..."), stating what was not checked (for example dispatch against github.com if the account could not run it).

- [ ] **Step 7: Commit**

```bash
git add docs
git commit -m "Docs: repository presets (B25), narrowed .runnir and the B28 direction"
```

---

## Self-Review Notes

- Spec coverage: file format and reading rules (Task 1), scan and snapshot (Task 2), contract (Task 3), app loading and failed reads (Task 4), Run Workflow menu, secret-looking values, no Update/Rename/Delete, Save as New (Task 5), Overview rows including "not on GitHub yet" and the read-error row (Task 6), docs and live check (Task 7).
- Changed from the spec while planning: a name-based preset id replaces the `PresetChoice` enum (recorded in Task 7 Step 4).
