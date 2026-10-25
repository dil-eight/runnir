# Secrets And Variables For Local Runs (B28) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Local act runs get the `secrets.X` and `vars.X` their workflow reads, from values kept per workspace in Keychain, imported from a `.env` file, or typed for one run.

**Architecture:** The Go Core finds the names in each workflow (repository scan and local-run plan), parses `.env` files on request, accepts values only at `ConfirmLocalRun`, and hands them to act through two pipes that act reads as YAML secret and variable files. The Swift app keeps values in Keychain (one service per workspace), shows them in a new **Secrets and Variables** sidebar section and in the Run Locally review, and sends the values for the plan's names when the run starts.

**Tech Stack:** Go 1.x (pure Go, `CGO_ENABLED=0`), protobuf/gRPC (buf), Swift 6, SwiftUI, Observation, Security, LocalAuthentication, Swift Testing.

Spec: [2026-10-25-local-run-secrets-design.md](../specs/2026-10-25-local-run-secrets-design.md).

## Global Constraints

- Values never go to disk, argv, act's environment, the workspace database, logs, `UserDefaults` or `desktop-state.json`.
- Names are upper-cased everywhere (GitHub and act compare them without case).
- At most 100 secrets and 100 variables per run; each value at most 48 KiB (49152 bytes).
- `.env` files: at most 1 MiB, regular file, valid UTF-8. `${X}` is never expanded. `encrypted:` values are flagged, never decrypted.
- `GITHUB_TOKEN` is always in the secrets act gets, empty unless the user set it; never filled from Runnir's sign-in.
- Keychain items: generic password, service `dev.runnir.local-run.<workspace-uuid lowercased>` (`dev.runnir.local-run.ui-testing.<uuid>` for UI tests of a Debug build), account `secret:NAME` or `variable:NAME`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Touch ID (`.deviceOwnerAuthentication`) only to show a saved secret.
- No new Go or Swift dependency. No backward compatibility (AGENTS.md): change messages and settings in place.
- No AI attribution in commits, code, docs or the PR.
- Core checks after each Core task: from `core/`: `go test ./...`, `go vet ./...`, `go build ./...`.
- App checks after each app task: `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build` and `... test -only-testing:RunnirTests`.
- Contract regeneration: `PATH=<dir with protoc-gen-swift 1.39.0 and protoc-gen-grpc-swift-2 2.5.0>:$PATH sh scripts/generate-contracts.sh` (buf 1.65.0, protoc-gen-go 1.36.11, protoc-gen-go-grpc 1.6.1).

## File Structure

| File | Responsibility |
| --- | --- |
| `core/internal/references/references.go` (new) | Find `secrets`/`vars` names a workflow source reads |
| `core/internal/dotenv/dotenv.go` (new) | Parse `.env` text into entries and problems |
| `core/internal/repository/manager.go` | `Workflow.Secrets`, `Workflow.Variables` |
| `core/internal/scanner/scanner.go` | Fill them in `parse` |
| `core/internal/localrun/plan.go` | `Plan.Variables`, `Plan.UnnamedSecrets`, note |
| `core/internal/localrun/values.go` (new) | Pipes and links that hand values to act; masks |
| `core/internal/localrun/runner.go` | `Spec.Secrets/Variables`, `Args`, `Run` wiring |
| `core/internal/localrun/proc_unix.go`, `proc_windows.go` | `passesValues` per platform |
| `core/internal/localrun/output.go` | Masking secret values in kept lines |
| `core/internal/localrun/testdata/fake/main.go` | Fake act copies the value files it is given |
| `core/internal/server/localruns.go` | Confirm with values, validation |
| `core/internal/server/envfile.go` (new) | `ReadEnvFile` |
| `core/internal/server/service.go` | `ListWorkflows` names |
| `contracts/grpc/runnir/core/v1/runnir_core.proto` | Fields and `ReadEnvFile` |
| `apps/macos/Runnir/IPC/CoreService.swift`, `CoreLocalRunModels.swift`, `GRPCCoreService.swift`, `CoreHub.swift` | Swift side of the contract |
| `apps/macos/Runnir/Core/Security/LocalRunValueStore.swift` (new) | Keychain store, in-memory store, kinds and keys |
| `apps/macos/Runnir/Features/Desktop/WorkspaceValues.swift` (new) | Section model: rows, pending edits, Save/Revert, import, reveal |
| `apps/macos/Runnir/Features/Desktop/WorkspaceValuesView.swift` (new) | Section view |
| `apps/macos/Runnir/Features/Desktop/LocalRun.swift`, `LocalRunViews.swift` | Review: values section, access line, start with values |
| `apps/macos/Runnir/App/Navigation/AppSection.swift`, `App/AppState.swift`, `Features/Desktop/DesktopViews.swift`, `App/Desktop/DesktopCoordinator.swift`, `Features/Desktop/UnsavedChanges.swift` | Section, routing, unsaved prompts, workspace removal |

---

### Task 1: Name references in the Core

**Files:**
- Create: `core/internal/references/references.go`
- Test: `core/internal/references/references_test.go`

**Interfaces:**
- Produces: `references.Find(source []byte) references.Names`; `type Names struct { Secrets, Variables []string; UnnamedSecrets bool }` (sorted, upper-cased, unique).

- [ ] **Step 1: Write the failing test**

```go
package references

import (
	"slices"
	"testing"
)

func TestFindNamesEveryForm(t *testing.T) {
	source := []byte(`
on: push
jobs:
  build:
    runs-on: ubuntu-latest
    env:
      REGION: ${{ vars.region }}
    steps:
      - run: echo ${{ secrets.NPM_TOKEN }} ${{ secrets['Deploy_Key'] }} ${{ vars["STAGE"] }}
      - run: echo ${{ secrets.npm_token }} ${{ github.token }}
      # ${{ secrets.IN_COMMENT }}
      - run: echo "${{ myvars.NOT_A_VAR }}"
`)
	names := Find(source)
	if want := []string{"DEPLOY_KEY", "IN_COMMENT", "NPM_TOKEN"}; !slices.Equal(names.Secrets, want) {
		t.Fatalf("secrets = %v, want %v", names.Secrets, want)
	}
	if want := []string{"REGION", "STAGE"}; !slices.Equal(names.Variables, want) {
		t.Fatalf("variables = %v, want %v", names.Variables, want)
	}
	if names.UnnamedSecrets {
		t.Fatal("unnamed secrets reported for named ones")
	}
}

func TestFindReportsSecretsReadAsAWhole(t *testing.T) {
	for _, source := range []string{
		"steps:\n  - run: echo '${{ toJSON(secrets) }}'\n",
		"steps:\n  - run: echo '${{ tojson( secrets ) }}'\n",
		"jobs:\n  call:\n    uses: ./.github/workflows/r.yml\n    secrets: inherit\n",
		"steps:\n  - run: echo ${{ secrets[matrix.name] }}\n",
	} {
		if !Find([]byte(source)).UnnamedSecrets {
			t.Errorf("not reported: %q", source)
		}
	}
}

func TestFindNothing(t *testing.T) {
	names := Find([]byte("on: push\njobs: {}\n"))
	if len(names.Secrets) != 0 || len(names.Variables) != 0 || names.UnnamedSecrets {
		t.Fatalf("names = %+v", names)
	}
}
```

- [ ] **Step 2: Run it and see it fail**

Run: `cd core && go test ./internal/references/`
Expected: FAIL, `undefined: Find`.

- [ ] **Step 3: Implement**

```go
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
```

- [ ] **Step 4: Run it and see it pass**

Run: `cd core && go test ./internal/references/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core/internal/references
git commit -m "Core: find the secrets and variables a workflow reads"
```

### Task 2: Names in the repository scan and the local-run plan

**Files:**
- Modify: `contracts/grpc/runnir/core/v1/runnir_core.proto` (`Workflow`, `LocalRunPlan`), regenerated Go and Swift code
- Modify: `core/internal/repository/manager.go` (`Workflow`)
- Modify: `core/internal/scanner/scanner.go` (`parse`)
- Modify: `core/internal/server/service.go` (`ListWorkflows`), `core/internal/server/localruns.go` (`planMessage`)
- Modify: `core/internal/localrun/plan.go` (`Plan`, `NewPlan`, `notes`; remove `secretPattern`, `secretNames`)
- Test: `core/internal/scanner/scanner_test.go`, `core/internal/localrun/plan_test.go`

**Interfaces:**
- Consumes: `references.Find` (Task 1).
- Produces: `repository.Workflow.Secrets/Variables []string`; `localrun.Plan.Variables []string`, `localrun.Plan.UnnamedSecrets bool`; proto `Workflow.secrets = 8`, `Workflow.variables = 9`, `LocalRunPlan.variables = 18`, `LocalRunPlan.unnamed_secrets = 19`.

- [ ] **Step 1: Write the failing tests**

In `scanner_test.go`, add:

```go
func TestScanListsSecretsAndVariables(t *testing.T) {
	root := t.TempDir()
	write(t, root, ".github/workflows/ci.yml", "name: CI\non: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ${{ secrets.npm_token }} ${{ vars.REGION }}\n")
	snapshot, err := Scan(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	w := snapshot.Workflows[0]
	if !slices.Equal(w.Secrets, []string{"NPM_TOKEN"}) || !slices.Equal(w.Variables, []string{"REGION"}) {
		t.Fatalf("workflow = %+v", w)
	}
}
```

(Use the file's existing `write` helper and `Scan` call shape; add `slices` to the imports if missing.)

In `plan_test.go`, replace the `p.Secrets` assertion block of the existing test with:

```go
	if !slices.Equal(p.Secrets, []string{"NPM_TOKEN"}) || len(p.Variables) != 0 || p.UnnamedSecrets {
		t.Fatalf("secrets = %v variables = %v unnamed = %v", p.Secrets, p.Variables, p.UnnamedSecrets)
	}
	for _, note := range p.Notes {
		if strings.Contains(note, "get no secrets") {
			t.Fatalf("old note kept: %q", note)
		}
	}
```

and add:

```go
func TestPlanNotesSecretsReadAsAWhole(t *testing.T) {
	source := "on: push\njobs:\n  a:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo '${{ toJSON(secrets) }}' ${{ vars.stage }}\n"
	p, err := NewPlan(Request{WorkflowID: ".github/workflows/a.yml", Source: []byte(source)}, readyReport(), false, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !p.UnnamedSecrets || !slices.Equal(p.Variables, []string{"STAGE"}) {
		t.Fatalf("plan = %+v", p)
	}
	if !slices.Contains(p.Notes, "This workflow reads secrets it does not name; only the listed ones are passed.") {
		t.Fatalf("notes = %v", p.Notes)
	}
}
```

(`readyReport()` stands for whatever helper `plan_test.go` already uses to build a ready `tools.Report`; use that helper's real name.)

- [ ] **Step 2: Run and see them fail**

Run: `cd core && go test ./internal/scanner/ ./internal/localrun/`
Expected: FAIL to compile (`w.Secrets`, `p.Variables` undefined).

- [ ] **Step 3: Contract**

In `runnir_core.proto`, `message Workflow`, after `bool concurrency = 7;`:

```proto
  // Names of the secrets.X and vars.X the file reads, upper-cased.
  repeated string secrets = 8;
  repeated string variables = 9;
```

In `message LocalRunPlan`, replace the `secrets` comment and add two fields after `engine_context = 17`:

```proto
  // Secrets the run reads, upper-cased; the values the user sets are passed.
  repeated string secrets = 8;
```

```proto
  // Variables (vars.X) the run reads, upper-cased.
  repeated string variables = 18;
  // The workflow reads secrets it does not name (toJSON(secrets), secrets:
  // inherit); only the listed ones can be passed.
  bool unnamed_secrets = 19;
```

Regenerate: `PATH=$SCRATCH/bin:$PATH sh scripts/generate-contracts.sh`.

- [ ] **Step 4: Core code**

`repository/manager.go`, in `type Workflow struct` after `Concurrency bool`:

```go
	// Secrets and Variables are the secrets.X and vars.X names the file
	// reads, upper-cased and sorted.
	Secrets   []string
	Variables []string
```

`scanner/scanner.go`, in `parse`, right after `workflow := repository.Workflow{ID: id, Name: id}`:

```go
	names := references.Find(data)
	workflow.Secrets, workflow.Variables = names.Secrets, names.Variables
```

(import `"runnir/core/internal/references"`).

`server/service.go`, `ListWorkflows`: add `Secrets: w.Secrets, Variables: w.Variables` to the `corev1.Workflow` literal.

`localrun/plan.go`:
- In `type Plan`, replace the `Secrets` field with:

```go
	// Secrets and Variables the workflow reads, upper-cased. The values the
	// user sets travel in Spec, never in the plan.
	Secrets   []string
	Variables []string
	// UnnamedSecrets: the workflow also reads secrets it does not name.
	UnnamedSecrets bool
```

- In `NewPlan`, replace `plan.Secrets = secretNames(request.Source)` with:

```go
	names := references.Find(request.Source)
	plan.Secrets, plan.Variables, plan.UnnamedSecrets = names.Secrets, names.Variables, names.UnnamedSecrets
```

- Delete `secretPattern` and `secretNames`.
- In `notes`, replace the `len(plan.Secrets) > 0` block with:

```go
	if plan.UnnamedSecrets {
		notes = append(notes, "This workflow reads secrets it does not name; only the listed ones are passed.")
	}
```

`server/localruns.go`, `planMessage`: add `Variables: plan.Variables, UnnamedSecrets: plan.UnnamedSecrets` to the literal.

- [ ] **Step 5: Run Core checks**

Run: `cd core && go test ./... && go vet ./... && go build ./...`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add contracts core apps/macos/Runnir/IPC/Generated
git commit -m "Core: list the secrets and variables of each workflow and local run"
```

### Task 3: dotenv parser and ReadEnvFile

**Files:**
- Create: `core/internal/dotenv/dotenv.go`, `core/internal/dotenv/dotenv_test.go`
- Create: `core/internal/server/envfile.go`, `core/internal/server/envfile_test.go`
- Modify: `contracts/grpc/runnir/core/v1/runnir_core.proto` (rpc + messages), regenerated code

**Interfaces:**
- Produces: `dotenv.Parse(data []byte) ([]dotenv.Entry, []dotenv.Problem)`; `dotenv.MaxSize = 1 << 20`; `type Entry struct { Name, Value string; Encrypted bool; Line int }`; `type Problem struct { Line int; Message string }`. RPC `ReadEnvFile(ReadEnvFileRequest{path}) → ReadEnvFileResponse{entries: [EnvEntry{name, value, encrypted, line}], problems: [EnvProblem{line, message}]}`.

- [ ] **Step 1: Write the failing parser test**

```go
package dotenv

import (
	"reflect"
	"testing"
)

func TestParse(t *testing.T) {
	data := []byte("\ufeff# comment\n" +
		"\n" +
		"export NPM_TOKEN=abc123\n" +
		"plain = spaced value  # trailing comment\n" +
		"HASH=a#b\n" +
		"SINGLE='lit ${HOME} \\n'\n" +
		"DOUBLE=\"line1\\nline2 \\\"q\\\" \\\\ ${HOME}\"\n" +
		"MULTI=\"first\n" +
		"second\"\n" +
		"KEY='-----BEGIN\n" +
		"body\n" +
		"-----END'\n" +
		"SECRET=encrypted:BDb7t3QkTRp2\n" +
		"not a line\n" +
		"1BAD=x\n" +
		"EMPTY=\n" +
		"NPM_TOKEN=later\n" +
		"OPEN=\"never closed\n")
	entries, problems := Parse(data)
	want := []Entry{
		{Name: "NPM_TOKEN", Value: "later", Line: 17},
		{Name: "PLAIN", Value: "spaced value", Line: 4},
		{Name: "HASH", Value: "a#b", Line: 5},
		{Name: "SINGLE", Value: "lit ${HOME} \\n", Line: 6},
		{Name: "DOUBLE", Value: "line1\nline2 \"q\" \\ ${HOME}", Line: 7},
		{Name: "MULTI", Value: "first\nsecond", Line: 8},
		{Name: "KEY", Value: "-----BEGIN\nbody\n-----END", Line: 10},
		{Name: "SECRET", Encrypted: true, Line: 13},
		{Name: "EMPTY", Value: "", Line: 16},
	}
	if !reflect.DeepEqual(entries, want) {
		t.Fatalf("entries =\n%+v\nwant\n%+v", entries, want)
	}
	wantProblems := []Problem{
		{Line: 14, Message: "Not a NAME=value line."},
		{Line: 15, Message: "Not a NAME=value line."},
		{Line: 18, Message: "The quote that starts here is not closed."},
	}
	if !reflect.DeepEqual(problems, wantProblems) {
		t.Fatalf("problems = %+v", problems)
	}
}

func TestParseCRLFAndTextAfterQuote(t *testing.T) {
	entries, problems := Parse([]byte("A=\"x\" # ok\r\nB='y' junk\r\n"))
	if len(entries) != 1 || entries[0] != (Entry{Name: "A", Value: "x", Line: 1}) {
		t.Fatalf("entries = %+v", entries)
	}
	if len(problems) != 1 || problems[0].Line != 2 {
		t.Fatalf("problems = %+v", problems)
	}
}
```

A later duplicate replaces the earlier entry's value and line but keeps its position (the first `NPM_TOKEN` slot holds `later`, line 17).

- [ ] **Step 2: Run and see it fail**

Run: `cd core && go test ./internal/dotenv/`
Expected: FAIL, `undefined: Parse`.

- [ ] **Step 3: Implement the parser**

```go
// Package dotenv reads .env files for importing values: NAME=value lines as
// dotenv tools write them. Nothing is expanded or executed, and values
// encrypted by dotenvx are flagged rather than decrypted.
package dotenv

import (
	"regexp"
	"strings"
)

// MaxSize is the largest file Runnir reads.
const MaxSize = 1 << 20

type Entry struct {
	// Name is upper-cased.
	Name  string
	Value string
	// Encrypted: a dotenvx "encrypted:" value; Value is empty.
	Encrypted bool
	// Line is the 1-based line the entry starts on.
	Line int
}

type Problem struct {
	Line    int
	Message string
}

var namePattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// Parse reads a dotenv file. A later entry for a name replaces an earlier
// one in its place; a line it cannot read becomes a problem and parsing
// goes on with the next line.
func Parse(data []byte) ([]Entry, []Problem) {
	text := strings.TrimPrefix(strings.ReplaceAll(string(data), "\r\n", "\n"), "\ufeff")
	lines := strings.Split(text, "\n")
	var entries []Entry
	var problems []Problem
	index := map[string]int{}
	for i := 0; i < len(lines); i++ {
		start := i + 1
		line := strings.TrimSpace(lines[i])
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if rest, ok := strings.CutPrefix(line, "export"); ok && (strings.HasPrefix(rest, " ") || strings.HasPrefix(rest, "\t")) {
			line = strings.TrimSpace(rest)
		}
		name, rest, ok := strings.Cut(line, "=")
		name = strings.TrimSpace(name)
		if !ok || !namePattern.MatchString(name) {
			problems = append(problems, Problem{Line: start, Message: "Not a NAME=value line."})
			continue
		}
		rest = strings.TrimLeft(rest, " \t")
		var value string
		if rest != "" && (rest[0] == '"' || rest[0] == '\'') {
			quote := rest[0]
			body := rest[1:]
			end := closing(body, quote)
			for end < 0 && i+1 < len(lines) {
				i++
				body += "\n" + lines[i]
				end = closing(body, quote)
			}
			if end < 0 {
				problems = append(problems, Problem{Line: start, Message: "The quote that starts here is not closed."})
				continue
			}
			if tail := strings.TrimSpace(body[end+1:]); tail != "" && !strings.HasPrefix(tail, "#") {
				problems = append(problems, Problem{Line: start, Message: "Text after the closing quote."})
				continue
			}
			value = body[:end]
			if quote == '"' {
				value = unescape(value)
			}
		} else {
			value = rest
			for _, marker := range []string{" #", "\t#"} {
				if cut := strings.Index(value, marker); cut >= 0 {
					value = value[:cut]
				}
			}
			value = strings.TrimSpace(value)
		}
		entry := Entry{Name: strings.ToUpper(name), Value: value, Line: start}
		if strings.HasPrefix(value, "encrypted:") {
			entry.Value, entry.Encrypted = "", true
		}
		if at, seen := index[entry.Name]; seen {
			entries[at] = entry
			continue
		}
		index[entry.Name] = len(entries)
		entries = append(entries, entry)
	}
	return entries, problems
}

// closing is the index of the quote that ends body, or -1. In double quotes
// a backslash escapes the next character.
func closing(body string, quote byte) int {
	for i := 0; i < len(body); i++ {
		switch {
		case quote == '"' && body[i] == '\\':
			i++
		case body[i] == quote:
			return i
		}
	}
	return -1
}

func unescape(value string) string {
	var out strings.Builder
	for i := 0; i < len(value); i++ {
		if value[i] != '\\' || i+1 == len(value) {
			out.WriteByte(value[i])
			continue
		}
		i++
		switch value[i] {
		case 'n':
			out.WriteByte('\n')
		case 'r':
			out.WriteByte('\r')
		case 't':
			out.WriteByte('\t')
		case '"', '\\':
			out.WriteByte(value[i])
		default:
			out.WriteByte('\\')
			out.WriteByte(value[i])
		}
	}
	return out.String()
}
```

- [ ] **Step 4: Run the parser test**

Run: `cd core && go test ./internal/dotenv/`
Expected: PASS.

- [ ] **Step 5: Contract**

In the `service` block after `CancelExecution`:

```proto
  // Reads a .env file the user chose, to import values into Secrets and
  // Variables. Nothing is expanded or run; values encrypted by dotenvx are
  // flagged, not decrypted. INVALID_ARGUMENT for a file that is not a
  // regular file, is larger than 1 MiB or is not UTF-8.
  rpc ReadEnvFile(ReadEnvFileRequest) returns (ReadEnvFileResponse);
```

Messages (after `GetLocalRunOutputResponse`):

```proto
message ReadEnvFileRequest {
  // An absolute path.
  string path = 1;
}

message EnvEntry {
  // Upper-cased.
  string name = 1;
  string value = 2;
  // A dotenvx "encrypted:" value; `value` is empty.
  bool encrypted = 3;
  uint32 line = 4;
}

message EnvProblem {
  uint32 line = 1;
  string message = 2;
}

message ReadEnvFileResponse {
  // In file order; a later entry for a name replaced an earlier one.
  repeated EnvEntry entries = 1;
  repeated EnvProblem problems = 2;
}
```

Regenerate the contracts.

- [ ] **Step 6: Write the failing server test**

`core/internal/server/envfile_test.go` (use the package's existing `socketPath`, `startWith`, `connect` helpers as `localruns_test.go` does; `//go:build !windows`):

```go
//go:build !windows

package server

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

func TestReadEnvFile(t *testing.T) {
	path := socketPath(t)
	stop := startWith(t, path, Options{})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	dir := t.TempDir()
	file := filepath.Join(dir, ".env")
	_ = os.WriteFile(file, []byte("npm_token=abc\nSEALED=encrypted:xyz\nbad line\n"), 0o600)
	read, err := client.ReadEnvFile(ctx, &corev1.ReadEnvFileRequest{Path: file})
	if err != nil {
		t.Fatal(err)
	}
	if len(read.Entries) != 2 || read.Entries[0].Name != "NPM_TOKEN" || read.Entries[0].Value != "abc" ||
		!read.Entries[1].Encrypted || read.Entries[1].Value != "" || len(read.Problems) != 1 || read.Problems[0].Line != 3 {
		t.Fatalf("read = %v", read)
	}

	big := filepath.Join(dir, "big.env")
	_ = os.WriteFile(big, []byte("A="+strings.Repeat("x", 1<<20)), 0o600)
	binary := filepath.Join(dir, "binary.env")
	_ = os.WriteFile(binary, []byte{'A', '=', 0xff, 0xfe}, 0o600)
	for _, bad := range []string{big, binary, dir, filepath.Join(dir, "missing"), "relative.env"} {
		if _, err := client.ReadEnvFile(ctx, &corev1.ReadEnvFileRequest{Path: bad}); status.Code(err) != codes.InvalidArgument {
			t.Errorf("%s: %v", bad, err)
		}
	}
}
```

Run: `cd core && go test ./internal/server/ -run TestReadEnvFile`
Expected: FAIL, `ReadEnvFile` unimplemented.

- [ ] **Step 7: Implement ReadEnvFile**

`core/internal/server/envfile.go`:

```go
package server

import (
	"context"
	"io"
	"os"
	"path/filepath"
	"unicode/utf8"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"runnir/core/internal/dotenv"
	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// ReadEnvFile reads a .env file the user picked in the app. The path comes
// from the user's own choice, so a symbolic link is followed.
func (s *service) ReadEnvFile(_ context.Context, request *corev1.ReadEnvFileRequest) (*corev1.ReadEnvFileResponse, error) {
	path := request.GetPath()
	if !filepath.IsAbs(path) {
		return nil, status.Error(codes.InvalidArgument, "choose a file")
	}
	info, err := os.Stat(path)
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "Runnir can't read this file")
	}
	if !info.Mode().IsRegular() {
		return nil, status.Error(codes.InvalidArgument, "this is not a file")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "Runnir can't read this file")
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, dotenv.MaxSize+1))
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, "Runnir can't read this file")
	}
	if len(data) > dotenv.MaxSize {
		return nil, status.Error(codes.InvalidArgument, "the file is larger than 1 MiB")
	}
	if !utf8.Valid(data) {
		return nil, status.Error(codes.InvalidArgument, "the file is not UTF-8 text")
	}
	entries, problems := dotenv.Parse(data)
	out := &corev1.ReadEnvFileResponse{}
	for _, entry := range entries {
		out.Entries = append(out.Entries, &corev1.EnvEntry{Name: entry.Name, Value: entry.Value, Encrypted: entry.Encrypted, Line: uint32(entry.Line)})
	}
	for _, problem := range problems {
		out.Problems = append(out.Problems, &corev1.EnvProblem{Line: uint32(problem.Line), Message: problem.Message})
	}
	return out, nil
}
```

- [ ] **Step 8: Run Core checks and commit**

Run: `cd core && go test ./... && go vet ./... && go build ./...` — Expected: PASS.

```bash
git add contracts core apps/macos/Runnir/IPC/Generated
git commit -m "Core: read .env files for importing values"
```

### Task 4: Values through pipes, and masking

**Files:**
- Create: `core/internal/localrun/values.go`, `core/internal/localrun/values_test.go`
- Modify: `core/internal/localrun/runner.go` (`Spec`, `Args`, `Run`), `proc_unix.go`, `proc_windows.go`, `output.go`, `testdata/fake/main.go`, `runner_test.go`

**Interfaces:**
- Produces: `Spec.Secrets map[string]string`, `Spec.Variables map[string]string` (names upper-cased); `localrun.PassesValues bool` (exported const: true on Unix, false on Windows); `localrun.SecretsFile = "secrets.yaml"`, `localrun.VarsFile = "vars.yaml"`.

- [ ] **Step 1: Fake act copies the files it is given**

In `testdata/fake/main.go`, add `CopyValueFiles bool \`json:"copyValueFiles"\`` to `script` and, after the invocation is recorded and before printing lines:

```go
	if s.CopyValueFiles {
		files := map[string]string{}
		for _, arg := range os.Args[1:] {
			for _, flag := range []string{"--secret-file=", "--var-file="} {
				if path, ok := strings.CutPrefix(arg, flag); ok {
					data, err := os.ReadFile(path)
					if err != nil {
						data = []byte("error: " + err.Error())
					}
					files[flag] = string(data)
				}
			}
		}
		encoded, _ := json.Marshal(files)
		appendFile(filepath.Join(dir, "act.files"), string(encoded))
	}
```

(The script is read before this block; move the `script` read above it if needed.)

- [ ] **Step 2: Write the failing runner tests**

In `runner_test.go` add:

```go
func TestValuesReachActThroughPipesOnly(t *testing.T) {
	if !PassesValues {
		t.Skip("values are not passed on this platform")
	}
	secretLine := `{"level":"info","job":"CI/lint","jobID":"lint","raw_output":true,"msg":"token s3cr3t-value and second-line here\n"}`
	actPath, dockerPath, dir := fakeTools(t, map[string]any{"copyValueFiles": true, "lines": []string{startLine, secretLine, doneLine}})
	spec := testSpec(t, actPath, dockerPath)
	spec.Secrets = map[string]string{"NPM_TOKEN": "s3cr3t-value", "CERT": "first-line\nsecond-line"}
	spec.Variables = map[string]string{"REGION": "eu-west-1"}
	runner, outputs, job := startRun(t, spec)
	if err := runner.Run(context.Background(), job); err != nil {
		t.Fatalf("Run = %v", err)
	}

	data, err := os.ReadFile(filepath.Join(dir, "act.files"))
	if err != nil {
		t.Fatal(err)
	}
	var files map[string]string
	if err := json.Unmarshal(data, &files); err != nil {
		t.Fatal(err)
	}
	var secrets, variables map[string]string
	if err := json.Unmarshal([]byte(files["--secret-file="]), &secrets); err != nil {
		t.Fatalf("secret file %q: %v", files["--secret-file="], err)
	}
	if err := json.Unmarshal([]byte(files["--var-file="]), &variables); err != nil {
		t.Fatalf("var file %q: %v", files["--var-file="], err)
	}
	if secrets["NPM_TOKEN"] != "s3cr3t-value" || secrets["CERT"] != "first-line\nsecond-line" || secrets["GITHUB_TOKEN"] != "" || len(secrets) != 3 {
		t.Fatalf("secrets = %v", secrets)
	}
	if variables["REGION"] != "eu-west-1" || len(variables) != 1 {
		t.Fatalf("variables = %v", variables)
	}

	call := invocations(t, dir, "act")[0]
	recorded := strings.Join(append(call.Args, call.Env...), "\n")
	for _, value := range []string{"s3cr3t-value", "first-line", "eu-west-1"} {
		if strings.Contains(recorded, value) {
			t.Fatalf("%q in act's arguments or environment", value)
		}
	}
	snap, _ := outputs.Since(job.ExecutionID, 0)
	for _, line := range snap.Lines {
		if strings.Contains(line.Text, "s3cr3t-value") || strings.Contains(line.Text, "second-line") {
			t.Fatalf("secret kept in output: %q", line.Text)
		}
	}
	if spec.Secrets != nil || spec.Variables != nil {
		t.Fatal("values kept after the run")
	}
}

func TestRunWithoutValuesStillPassesGitHubToken(t *testing.T) {
	if !PassesValues {
		t.Skip("values are not passed on this platform")
	}
	actPath, dockerPath, dir := fakeTools(t, map[string]any{"copyValueFiles": true})
	spec := testSpec(t, actPath, dockerPath)
	runner, _, job := startRun(t, spec)
	if err := runner.Run(context.Background(), job); err != nil {
		t.Fatalf("Run = %v", err)
	}
	data, _ := os.ReadFile(filepath.Join(dir, "act.files"))
	var files map[string]string
	_ = json.Unmarshal(data, &files)
	if files["--secret-file="] != `{"GITHUB_TOKEN":""}` || files["--var-file="] != `{}` {
		t.Fatalf("files = %v", files)
	}
}
```

In `values_test.go`:

```go
package localrun

import (
	"slices"
	"testing"
)

func TestMasksForSecrets(t *testing.T) {
	masks := masksFor(map[string]string{"A": "longer-secret", "B": "{\n  \"key\": \"value-line\"\n}", "C": ""})
	want := []string{"{\n  \"key\": \"value-line\"\n}", "\"key\": \"value-line\"", "longer-secret"}
	if !slices.Equal(masks, want) {
		t.Fatalf("masks = %q", masks)
	}
	if got := mask("x longer-secret y \"key\": \"value-line\"", masks); got != "x *** y ***" {
		t.Fatalf("mask = %q", got)
	}
}
```

Lines of a multi-line value are masked only when at least 4 characters after trimming, so `{` and `}` do not wipe out output; the whole value is always masked.

Run: `cd core && go test ./internal/localrun/`
Expected: FAIL to compile (`spec.Secrets`, `PassesValues`, `masksFor` undefined).

- [ ] **Step 3: Platform constant**

`proc_unix.go`, add:

```go
// PassesValues: secrets and variables reach act through pipes it inherits.
const PassesValues = true
```

`proc_windows.go`, add:

```go
// PassesValues is false: Go cannot hand a Windows child extra descriptors,
// so act gets empty secret and variable files there.
const PassesValues = false
```

- [ ] **Step 4: values.go**

```go
package localrun

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// The names act's --secret-file and --var-file get in the run's scratch
// folder: symbolic links to the pipes act inherits as fd 3 and 4. act reads
// a file whose name ends in .yaml as YAML, once, and JSON is YAML.
const (
	SecretsFile = "secrets.yaml"
	VarsFile    = "vars.yaml"
)

// valueFeed writes one JSON object into a pipe that act reads as a file.
type valueFeed struct {
	read, write *os.File
	data        []byte
	done        chan struct{}
}

// attachValues creates the pipes and links and adds the read ends to cmd.
// GITHUB_TOKEN is always among the secrets, so act never asks the gh CLI
// for one.
func attachValues(cmd *exec.Cmd, scratch string, spec *Spec) ([]*valueFeed, error) {
	secrets := map[string]string{"GITHUB_TOKEN": ""}
	for name, value := range spec.Secrets {
		secrets[name] = value
	}
	variables := map[string]string{}
	for name, value := range spec.Variables {
		variables[name] = value
	}
	var feeds []*valueFeed
	for i, item := range []struct {
		file   string
		values map[string]string
	}{{SecretsFile, secrets}, {VarsFile, variables}} {
		data, err := json.Marshal(item.values)
		if err != nil {
			closeFeeds(feeds)
			return nil, err
		}
		read, write, err := os.Pipe()
		if err != nil {
			closeFeeds(feeds)
			return nil, err
		}
		feeds = append(feeds, &valueFeed{read: read, write: write, data: data, done: make(chan struct{})})
		if err := os.Symlink("/dev/fd/"+strconv.Itoa(3+i), filepath.Join(scratch, item.file)); err != nil {
			closeFeeds(feeds)
			return nil, err
		}
		cmd.ExtraFiles = append(cmd.ExtraFiles, read)
	}
	return feeds, nil
}

// send runs after act started: the parent's copy of the read end closes and
// the values are written. A write error means act exited without reading.
func (f *valueFeed) send() {
	_ = f.read.Close()
	go func() {
		defer close(f.done)
		_, _ = f.write.Write(f.data)
		_ = f.write.Close()
		f.data = nil
	}()
}

func closeFeeds(feeds []*valueFeed) {
	for _, f := range feeds {
		_ = f.read.Close()
		_ = f.write.Close()
	}
}

// masksFor lists what to hide in a run's output: each secret value, and each
// line of a multi-line one of at least 4 characters, longest first.
func masksFor(secrets map[string]string) []string {
	seen := map[string]bool{}
	var masks []string
	add := func(text string) {
		if text != "" && !seen[text] {
			seen[text] = true
			masks = append(masks, text)
		}
	}
	for _, value := range secrets {
		add(value)
		if strings.Contains(value, "\n") {
			for _, line := range strings.Split(value, "\n") {
				if line = strings.TrimSpace(line); len(line) >= 4 {
					add(line)
				}
			}
		}
	}
	sort.Slice(masks, func(i, j int) bool {
		if len(masks[i]) != len(masks[j]) {
			return len(masks[i]) > len(masks[j])
		}
		return masks[i] < masks[j]
	})
	return masks
}

func mask(text string, masks []string) string {
	for _, m := range masks {
		text = strings.ReplaceAll(text, m, "***")
	}
	return text
}
```

- [ ] **Step 5: Spec, Args, Run, output**

`runner.go`, in `type Spec` after `GitHubInstance string`:

```go
	// Secrets and Variables the user set for this run, by upper-cased name.
	// They reach act through pipes and are dropped when the run ends.
	Secrets   map[string]string
	Variables map[string]string
```

In `Args`, replace the `--secret-file` and `--var-file` lines with:

```go
		"--secret-file=" + valueFile(scratch, SecretsFile),
		"--var-file=" + valueFile(scratch, VarsFile),
```

and add:

```go
// valueFile is the pipe link where values are passed, else the empty file.
func valueFile(scratch, name string) string {
	if PassesValues {
		return filepath.Join(scratch, name)
	}
	return filepath.Join(scratch, "empty")
}
```

Update the comment above those flags to: `// Override act's defaults (.env, .secrets, .vars, .input in the repository) so no local file reaches the jobs; secrets and variables come only through Runnir's pipes.`

In `Run`, right after `defer os.RemoveAll(scratch)` add:

```go
	defer func() { spec.Secrets, spec.Variables = nil, nil }()
	r.outputs.update(id, func(run *run) { run.masks = masksFor(spec.Secrets) })
	defer r.outputs.update(id, func(run *run) { run.masks = nil })
```

After `setProcessGroup(cmd)`:

```go
	var feeds []*valueFeed
	if PassesValues {
		if feeds, err = attachValues(cmd, scratch, spec); err != nil {
			return fmt.Errorf("prepare the run: %w", err)
		}
	}
```

Change the `cmd.Start` error branch to close them:

```go
	if err := cmd.Start(); err != nil {
		closeFeeds(feeds)
		return fmt.Errorf("start act: %w", err)
	}
	for _, feed := range feeds {
		feed.send()
	}
```

Also call `closeFeeds(feeds)` in the two `StdoutPipe`/`StderrPipe` error branches. After the `select` that sets `waitErr` (act has exited), add:

```go
	for _, feed := range feeds {
		<-feed.done
	}
```

`output.go`: add `masks []string // secret values hidden in kept lines, while the run goes` to `type run`, and at the top of `(r *run) append`:

```go
	text = mask(text, r.masks)
```

- [ ] **Step 6: Run Core checks**

Run: `cd core && go test ./... && go vet ./... && go build ./...`, then `cd core && GOOS=windows go vet ./internal/localrun/`
Expected: PASS. The existing `TestSuccessfulRunRecordsOutputAndJobs` flag check still passes: both files live in the scratch folder.

- [ ] **Step 7: Commit**

```bash
git add core/internal/localrun
git commit -m "Core: hand act secrets and variables through pipes and mask them in output"
```

### Task 5: ConfirmLocalRun takes values

**Files:**
- Modify: `contracts/grpc/runnir/core/v1/runnir_core.proto` (`ConfirmLocalRunRequest`), regenerated code
- Modify: `core/internal/server/localruns.go`
- Test: `core/internal/server/localruns_test.go`

**Interfaces:**
- Consumes: `localrun.Spec.Secrets/Variables`, `localrun.PassesValues`, `Plan.Secrets/Variables`.
- Produces: `ConfirmLocalRunRequest.secrets = 2`, `.variables = 3` (`map<string,string>`).

- [ ] **Step 1: Contract**

```proto
message ConfirmLocalRunRequest {
  string confirmation_id = 1;
  // Values for the plan's secrets and variables, by name (any case). Only
  // names in the plan are accepted: at most 100 of each, each value at most
  // 48 KiB. They reach act through pipes, never a file, its command line or
  // its environment, and are not logged or stored.
  map<string, string> secrets = 2;
  map<string, string> variables = 3;
}
```

Regenerate.

- [ ] **Step 2: Write the failing test**

In `localruns_test.go` add (reusing `readyTools`, `socketPath`, `startWith`, `connect`, `repoWithWorkflows`):

```go
const valuesWorkflow = "name: CI\non: push\njobs:\n  lint:\n    runs-on: ubuntu-latest\n    steps:\n      - run: echo ${{ secrets.NPM_TOKEN }} ${{ vars.region }}\n"

func TestLocalRunTakesValuesForPlanNamesOnly(t *testing.T) {
	path := socketPath(t)
	var spec *localrun.Spec
	started := make(chan struct{})
	hold := execution.RunnerFunc(func(ctx context.Context, job execution.Job) error {
		spec, _ = job.Spec.(*localrun.Spec)
		close(started)
		<-ctx.Done()
		return ctx.Err()
	})
	stop := startWith(t, path, Options{Runner: hold, Tools: readyTools(), Home: "/Users/me"})
	defer stop()
	client := connect(t, path)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	opened, err := client.OpenRepository(ctx, &corev1.OpenRepositoryRequest{Path: repoWithWorkflows(t, map[string]string{"ci.yml": valuesWorkflow})})
	if err != nil {
		t.Fatal(err)
	}
	prepare := func() *corev1.PrepareLocalRunResponse {
		prepared, err := client.PrepareLocalRun(ctx, &corev1.PrepareLocalRunRequest{RepositoryId: opened.Repository.Id, WorkflowId: ".github/workflows/ci.yml"})
		if err != nil {
			t.Fatal(err)
		}
		return prepared
	}

	first := prepare()
	if !slices.Equal(first.Plan.Secrets, []string{"NPM_TOKEN"}) || !slices.Equal(first.Plan.Variables, []string{"REGION"}) {
		t.Fatalf("plan = %v", first.Plan)
	}
	for _, bad := range []*corev1.ConfirmLocalRunRequest{
		{Secrets: map[string]string{"OTHER": "x"}},
		{Variables: map[string]string{"NPM_TOKEN": "x"}},
		{Secrets: map[string]string{"NPM_TOKEN": strings.Repeat("x", 48<<10+1)}},
	} {
		bad.ConfirmationId = prepare().ConfirmationId
		if _, err := client.ConfirmLocalRun(ctx, bad); status.Code(err) != codes.InvalidArgument {
			t.Fatalf("confirm %v = %v", bad, err)
		}
	}

	confirmed, err := client.ConfirmLocalRun(ctx, &corev1.ConfirmLocalRunRequest{ConfirmationId: first.ConfirmationId,
		Secrets: map[string]string{"npm_token": "s3cr3t"}, Variables: map[string]string{"Region": "eu"}})
	if err != nil {
		t.Fatal(err)
	}
	<-started
	if spec.Secrets["NPM_TOKEN"] != "s3cr3t" || spec.Variables["REGION"] != "eu" || len(spec.Secrets) != 1 || len(spec.Variables) != 1 {
		t.Fatalf("spec values = %v %v", spec.Secrets, spec.Variables)
	}
	output, err := client.GetLocalRunOutput(ctx, &corev1.GetLocalRunOutputRequest{ExecutionId: confirmed.Execution.ExecutionId})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(output.String(), "s3cr3t") {
		t.Fatal("a value is in the run's output message")
	}
}
```

Add `"slices"` and `"strings"` to the imports.

Run: `cd core && go test ./internal/server/ -run TestLocalRunTakesValues`
Expected: FAIL (values ignored, no INVALID_ARGUMENT).

- [ ] **Step 3: Implement**

In `localruns.go` add (imports `fmt`, `strings`):

```go
// The limits on values for one run; GitHub allows 48 KiB per secret.
const (
	maxRunValues    = 100
	maxRunValueSize = 48 << 10
)

// runValues checks values against the names the plan reads and upper-cases them.
func runValues(kind string, values map[string]string, names []string) (map[string]string, error) {
	if len(values) == 0 {
		return nil, nil
	}
	if len(values) > maxRunValues {
		return nil, fmt.Errorf("at most %d %ss can be passed", maxRunValues, kind)
	}
	allowed := map[string]bool{}
	for _, name := range names {
		allowed[name] = true
	}
	out := make(map[string]string, len(values))
	for name, value := range values {
		upper := strings.ToUpper(name)
		if !allowed[upper] {
			return nil, fmt.Errorf("the workflow does not read the %s %s", kind, upper)
		}
		if len(value) > maxRunValueSize {
			return nil, fmt.Errorf("the value of %s is larger than 48 KiB", upper)
		}
		out[upper] = value
	}
	return out, nil
}
```

In `ConfirmLocalRun`, at the very top:

```go
	if !localrun.PassesValues && (len(request.GetSecrets()) > 0 || len(request.GetVariables()) > 0) {
		return nil, status.Error(codes.FailedPrecondition, "secrets and variables reach act only on macOS and Linux")
	}
```

After the digest check:

```go
	secrets, err := runValues("secret", request.GetSecrets(), approved.Spec.Plan.Secrets)
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error()+"; review the run again")
	}
	variables, err := runValues("variable", request.GetVariables(), approved.Spec.Plan.Variables)
	if err != nil {
		return nil, status.Error(codes.InvalidArgument, err.Error()+"; review the run again")
	}
	spec := *approved.Spec
	spec.Secrets, spec.Variables = secrets, variables
```

and pass `Spec: &spec` to `s.executions.StartJob` instead of `approved.Spec`.

- [ ] **Step 4: Run Core checks and commit**

Run: `cd core && go test ./... && go vet ./... && go build ./...` — Expected: PASS.

```bash
git add contracts core apps/macos/Runnir/IPC/Generated
git commit -m "Core: accept secret and variable values when a local run is confirmed"
```

### Task 6: End-to-end check on a real engine

**Files:**
- Modify: `core/internal/localrun/e2e_test.go`

- [ ] **Step 1: Extend the fixture and test**

In `e2eWorkflow`'s `Report` step add after the `token=` line:

```yaml
          echo "secret-sha=$(printf %s '${{ secrets.NPM_TOKEN }}' | sha256sum | cut -c1-16)"
          echo "region=[${{ vars.REGION }}]"
```

Add a test:

```go
func TestE2EValuesReachTheJob(t *testing.T) {
	spec, outputs, job := e2eSpec(t, "hello")
	spec.Secrets = map[string]string{"NPM_TOKEN": "e2e-secret-value"}
	spec.Variables = map[string]string{"REGION": "eu-test-1"}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	err := NewRunner(outputs).Run(ctx, job)
	out := text(outputs, job.ExecutionID)
	t.Logf("output:\n%s", out)
	if err != nil {
		t.Fatalf("Run = %v", err)
	}
	sum := sha256.Sum256([]byte("e2e-secret-value"))
	for _, want := range []string{"secret-sha=" + hex.EncodeToString(sum[:])[:16], "region=[eu-test-1]", "secret=[***]"} {
		if !strings.Contains(out, want) {
			t.Errorf("output lacks %q", want)
		}
	}
	if strings.Contains(out, "e2e-secret-value") {
		t.Error("the secret's value is in the output")
	}
	assertNoContainers(t, spec)
}
```

(imports `crypto/sha256`, `encoding/hex`). The existing test still expects `secret=[]` and `token=[]` without values.

- [ ] **Step 2: Run on OrbStack**

Run: `cd core && RUNNIR_E2E_ACT=$(go env GOPATH)/bin/act go test -tags e2e ./internal/localrun/ -run TestE2E -v` with an act built from `third_party/act` (see ADR 0006). If no engine is available, record that it was not run.
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add core/internal/localrun/e2e_test.go
git commit -m "Core: end-to-end check that secrets and variables reach a job"
```

### Task 7: Swift side of the contract

**Files:**
- Modify: `apps/macos/Runnir/IPC/CoreService.swift` (`CoreWorkflow`, protocol), `CoreLocalRunModels.swift` (`CoreLocalRunPlan`, new env file types), `GRPCCoreService.swift`, `CoreHub.swift`
- Modify: `apps/macos/RunnirTests/CoreHubTests.swift` (`FakeCore`)
- Test: `apps/macos/RunnirTests/LocalRunTests.swift`

**Interfaces:**
- Produces:
  - `CoreWorkflow.secrets: [String]`, `CoreWorkflow.variables: [String]` (default `[]`).
  - `CoreLocalRunPlan.variables: [String]`, `CoreLocalRunPlan.unnamedSecrets: Bool`.
  - `struct CoreEnvEntry: Equatable, Sendable { let name: String; let value: String; let encrypted: Bool; let line: Int }`, `struct CoreEnvProblem: Equatable, Sendable { let line: Int; let message: String }`, `struct CoreEnvFile: Equatable, Sendable { let entries: [CoreEnvEntry]; let problems: [CoreEnvProblem] }`.
  - `CoreServicing.confirmLocalRun(confirmationID: String, secrets: [String: String], variables: [String: String]) async throws -> CoreExecution`.
  - `CoreServicing.readEnvFile(path: String) async throws -> CoreEnvFile`.
  - `CoreHub.readEnvFile(path: String) async -> CoreHub.EnvFileRead` with `enum EnvFileRead: Equatable { case read(CoreEnvFile); case failed(String) }`.
  - `CoreHub.startLocalRun(workspaceID: UUID, prepared: CorePreparedLocalRun, secrets: [String: String] = [:], variables: [String: String] = [:]) async -> LocalRunStart`.
  - `FakeCore.confirmedValues: [(secrets: [String: String], variables: [String: String])]`, `FakeCore.envFile: CoreEnvFile?`, `FakeCore.envFileError: CoreServiceError?`.

- [ ] **Step 1: Write the failing test**

In `LocalRunTests.swift`:

```swift
    @Test func startPassesValuesToTheCore() async throws {
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = prepared() }
        fake.localOutputs = [output(lines: nil, phase: .finished, state: .succeeded)]
        let result = await hub.startLocalRun(workspaceID: workspace, prepared: prepared(),
                                             secrets: ["NPM_TOKEN": "s3cr3t"], variables: ["REGION": "eu"])
        guard case .started = result else { Issue.record("not started: \(result)"); return }
        #expect(fake.confirmedValues.first?.secrets == ["NPM_TOKEN": "s3cr3t"])
        #expect(fake.confirmedValues.first?.variables == ["REGION": "eu"])
    }

    @Test func envFileIsReadThroughTheCore() async {
        let (hub, _, fake) = await hub {
            $0.envFile = CoreEnvFile(entries: [CoreEnvEntry(name: "A", value: "1", encrypted: false, line: 1)], problems: [])
        }
        #expect(await hub.readEnvFile(path: "/tmp/.env") == .read(fake.envFile!))
        fake.envFileError = .invalidArgument("the file is larger than 1 MiB")
        #expect(await hub.readEnvFile(path: "/tmp/.env") == .failed("The file is larger than 1 MiB."))
    }
```

- [ ] **Step 2: Implement**

`CoreService.swift`, `CoreWorkflow`, after `concurrency`:

```swift
    /// The secrets.X and vars.X names the file reads, upper-cased.
    var secrets: [String] = []
    var variables: [String] = []
```

Protocol: replace `confirmLocalRun(confirmationID:)` with

```swift
    /// Starts a prepared local run once with the values for the plan's
    /// secrets and variables. Throws `.failedPrecondition` when the
    /// confirmation expired or was used, or the file changed after the
    /// review, and `.invalidArgument` for a name the plan does not read.
    func confirmLocalRun(confirmationID: String, secrets: [String: String], variables: [String: String]) async throws -> CoreExecution
    /// Reads a .env file the user chose; values encrypted by dotenvx are flagged.
    func readEnvFile(path: String) async throws -> CoreEnvFile
```

`CoreLocalRunModels.swift`: add to `CoreLocalRunPlan` after `secrets`:

```swift
    var variables: [String] = []
    /// The workflow reads secrets it does not name; only listed ones are passed.
    var unnamedSecrets = false
```

and the three env types from **Interfaces**.

`GRPCCoreService.swift`: `listWorkflows` adds `secrets: workflow.secrets, variables: workflow.variables`; the plan map adds `variables: plan.variables, unnamedSecrets: plan.unnamedSecrets` (after `secrets:` / before `notes:` to match the memberwise order); `confirmLocalRun` becomes:

```swift
    func confirmLocalRun(confirmationID: String, secrets: [String: String], variables: [String: String]) async throws -> CoreExecution {
        let response = try await call {
            try await client.confirmLocalRun(.with {
                $0.confirmationID = confirmationID
                $0.secrets = secrets
                $0.variables = variables
            }, options: Self.options(Self.callTimeout))
        }
        return CoreExecution(id: response.execution.executionID, repositoryID: response.execution.repositoryID,
                             state: Self.map(response.execution.state))
    }

    func readEnvFile(path: String) async throws -> CoreEnvFile {
        let response = try await call {
            try await client.readEnvFile(.with { $0.path = path }, options: Self.options(Self.callTimeout))
        }
        return CoreEnvFile(entries: response.entries.map { CoreEnvEntry(name: $0.name, value: $0.value, encrypted: $0.encrypted, line: Int($0.line)) },
                           problems: response.problems.map { CoreEnvProblem(line: Int($0.line), message: $0.message) })
    }
```

`CoreHub.swift`: `startLocalRun` gains the two parameters with defaults and passes them to `service.confirmLocalRun`; its catch list adds `catch CoreServiceError.invalidArgument(let message) { return .failed(Self.sentence(message)) }`. Add:

```swift
    enum EnvFileRead: Equatable {
        case read(CoreEnvFile)
        case failed(String)
    }

    /// Reads a .env file the user chose, for Secrets and Variables.
    func readEnvFile(path: String) async -> EnvFileRead {
        guard let service = await readyService() else { return .failed("Runnir Core is not ready. Try again in a moment.") }
        do {
            return .read(try await service.readEnvFile(path: path))
        } catch CoreServiceError.invalidArgument(let message) {
            return .failed(Self.sentence(message))
        } catch {
            return .failed(Self.describe(error))
        }
    }
```

(`readyService()` stands for however CoreHub already gets its service without a workspace — reuse that accessor, for example the one `toolReadiness` uses.)

`FakeCore`: record values in `confirmLocalRun(confirmationID:secrets:variables:)` into `_confirmedValues` (lock-protected, exposed as `confirmedValues`), and implement `readEnvFile` from `envFile` / `envFileError` (nil `envFile` throws `.notFound`).

`LocalRunReviewModel.run()` keeps calling `hub.startLocalRun(workspaceID:prepared:)` for now (defaults).

- [ ] **Step 3: Build and test the app**

Run the app build and `RunnirTests` (Global Constraints). Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add apps/macos
git commit -m "App: secrets and variables in the Core contract"
```

### Task 8: Keychain store for values

**Files:**
- Create: `apps/macos/Runnir/Core/Security/LocalRunValueStore.swift`
- Test: `apps/macos/RunnirTests/LocalRunValuesTests.swift`
- Modify: `apps/macos/Runnir.xcodeproj/project.pbxproj` only if the project does not use folder references (check whether new files under `Runnir/` are picked up automatically; add them the same way as existing files otherwise).

**Interfaces:**
- Produces:

```swift
enum LocalRunValueKind: String, Sendable, CaseIterable { case secret, variable }
struct LocalRunValueKey: Hashable, Sendable, Comparable { let kind: LocalRunValueKind; let name: String }
protocol LocalRunValueStoring: Sendable {
    func keys(workspaceID: UUID) async throws -> Set<LocalRunValueKey>
    func value(workspaceID: UUID, key: LocalRunValueKey) async throws -> String?
    func save(workspaceID: UUID, key: LocalRunValueKey, value: String) async throws
    func remove(workspaceID: UUID, key: LocalRunValueKey) async throws
    func removeAll(workspaceID: UUID) async throws
}
actor KeychainLocalRunValueStore: LocalRunValueStoring
actor InMemoryLocalRunValueStore: LocalRunValueStoring  // tests and previews; `failReads` makes value(...) throw
```

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import Runnir

@Suite struct LocalRunValueStoreTests {
    @Test func inMemoryStoreKeepsValuesPerWorkspace() async throws {
        let store = InMemoryLocalRunValueStore()
        let a = UUID(), b = UUID()
        let token = LocalRunValueKey(kind: .secret, name: "NPM_TOKEN")
        let region = LocalRunValueKey(kind: .variable, name: "NPM_TOKEN")
        try await store.save(workspaceID: a, key: token, value: "s3cr3t")
        try await store.save(workspaceID: a, key: region, value: "eu")
        #expect(try await store.keys(workspaceID: a) == [token, region])
        #expect(try await store.keys(workspaceID: b).isEmpty)
        #expect(try await store.value(workspaceID: a, key: token) == "s3cr3t")
        try await store.remove(workspaceID: a, key: token)
        #expect(try await store.value(workspaceID: a, key: token) == nil)
        try await store.removeAll(workspaceID: a)
        #expect(try await store.keys(workspaceID: a).isEmpty)
    }

    @Test func keychainAccountNamesRoundTrip() {
        let key = LocalRunValueKey(kind: .variable, name: "REGION")
        #expect(KeychainLocalRunValueStore.account(for: key) == "variable:REGION")
        #expect(KeychainLocalRunValueStore.key(fromAccount: "variable:REGION") == key)
        #expect(KeychainLocalRunValueStore.key(fromAccount: "other:REGION") == nil)
        #expect(KeychainLocalRunValueStore.service(prefix: "dev.runnir.local-run", workspaceID: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!)
                == "dev.runnir.local-run.6f9619ff-8b86-d011-b42d-00c04fc964ff")
    }
}
```

Unit tests never touch the real Keychain; the Keychain store is checked in the live run (Task 13).

- [ ] **Step 2: Implement**

```swift
import Foundation
import Security

/// A value for local runs is a secret (secrets.X) or a variable (vars.X).
enum LocalRunValueKind: String, Sendable, CaseIterable {
    case secret, variable
}

/// A name, upper-cased, of one kind.
struct LocalRunValueKey: Hashable, Sendable, Comparable {
    let kind: LocalRunValueKind
    let name: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.name, lhs.kind.rawValue) < (rhs.name, rhs.kind.rawValue)
    }
}

/// Values for local runs, kept per workspace on this Mac.
protocol LocalRunValueStoring: Sendable {
    /// The saved names, without reading any value.
    func keys(workspaceID: UUID) async throws -> Set<LocalRunValueKey>
    func value(workspaceID: UUID, key: LocalRunValueKey) async throws -> String?
    func save(workspaceID: UUID, key: LocalRunValueKey, value: String) async throws
    func remove(workspaceID: UUID, key: LocalRunValueKey) async throws
    func removeAll(workspaceID: UUID) async throws
}

/// Keychain items, one service per workspace so its names list in one query
/// and go in one delete.
actor KeychainLocalRunValueStore: LocalRunValueStoring {
    private let prefix: String

    init(prefix: String = KeychainLocalRunValueStore.defaultPrefix) {
        self.prefix = prefix
    }

    /// UI tests of a Debug build keep their own items.
    static var defaultPrefix: String {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return "dev.runnir.local-run.ui-testing" }
        #endif
        return "dev.runnir.local-run"
    }

    static func service(prefix: String, workspaceID: UUID) -> String {
        "\(prefix).\(workspaceID.uuidString.lowercased())"
    }

    static func account(for key: LocalRunValueKey) -> String { "\(key.kind.rawValue):\(key.name)" }

    static func key(fromAccount account: String) -> LocalRunValueKey? {
        let parts = account.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let kind = LocalRunValueKind(rawValue: parts[0]), !parts[1].isEmpty else { return nil }
        return LocalRunValueKey(kind: kind, name: parts[1])
    }

    func keys(workspaceID: UUID) async throws -> Set<LocalRunValueKey> {
        var query = base(workspaceID)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        let attributes = items as? [[String: Any]] ?? []
        return Set(attributes.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(Self.key(fromAccount:)) })
    }

    func value(workspaceID: UUID, key: LocalRunValueKey) async throws -> String? {
        var query = item(workspaceID, key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var data: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &data)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
        guard let data = data as? Data, let value = String(data: data, encoding: .utf8) else { throw KeychainError.invalidData }
        return value
    }

    func save(workspaceID: UUID, key: LocalRunValueKey, value: String) async throws {
        let data = Data(value.utf8)
        var query = item(workspaceID, key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecAttrLabel as String] = "Runnir local run \(key.kind.rawValue) \(key.name)"
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(item(workspaceID, key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.unhandledStatus(update) }
            return
        }
        guard status == errSecSuccess else { throw KeychainError.unhandledStatus(status) }
    }

    func remove(workspaceID: UUID, key: LocalRunValueKey) async throws {
        let status = SecItemDelete(item(workspaceID, key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unhandledStatus(status) }
    }

    func removeAll(workspaceID: UUID) async throws {
        let status = SecItemDelete(base(workspaceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unhandledStatus(status) }
    }

    private func base(_ workspaceID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service(prefix: prefix, workspaceID: workspaceID)]
    }

    private func item(_ workspaceID: UUID, _ key: LocalRunValueKey) -> [String: Any] {
        var query = base(workspaceID)
        query[kSecAttrAccount as String] = Self.account(for: key)
        return query
    }
}

/// Values in memory, for tests and previews.
actor InMemoryLocalRunValueStore: LocalRunValueStoring {
    private var values: [UUID: [LocalRunValueKey: String]] = [:]
    /// Makes `value` throw, as a Keychain that refuses access would.
    var failReads = false

    init(values: [UUID: [LocalRunValueKey: String]] = [:]) { self.values = values }

    func setFailReads(_ fail: Bool) { failReads = fail }
    func keys(workspaceID: UUID) async throws -> Set<LocalRunValueKey> { Set(values[workspaceID, default: [:]].keys) }
    func value(workspaceID: UUID, key: LocalRunValueKey) async throws -> String? {
        if failReads { throw KeychainError.unhandledStatus(errSecAuthFailed) }
        return values[workspaceID]?[key]
    }
    func save(workspaceID: UUID, key: LocalRunValueKey, value: String) async throws { values[workspaceID, default: [:]][key] = value }
    func remove(workspaceID: UUID, key: LocalRunValueKey) async throws { values[workspaceID]?[key] = nil }
    func removeAll(workspaceID: UUID) async throws { values[workspaceID] = nil }
}
```

- [ ] **Step 3: Build and test; commit**

Run the app build and `RunnirTests`. Expected: PASS.

```bash
git add apps/macos
git commit -m "App: keep values for local runs in Keychain per workspace"
```

### Task 9: Design in runnir.pen

**Files:**
- Modify: `docs/design/runnir.pen` (through the pencil MCP only), `docs/design/screens-and-states.md`

- [ ] **Step 1:** Load the pencil MCP guidance (`get_app_state`, `read_skill` as the tool asks), list the top-level frames of `docs/design/runnir.pen`, and find the current S16 and S10 frames and the row layout (rows A–G per the placement rule: 1280-wide frames, 100 px gaps, 160 px between rows).
- [ ] **Step 2:** Add a new row "Row label — Secrets and Variables" between row D (Runs) and row E (Workspace), shifting the rows below down. Draw "S16 / Secrets and Variables / Filled and missing / Dark / 1280×800" with the workspace sidebar (Overview, Workflows, Runs, Secrets and Variables selected, Workspace), two tables (Secrets, Variables) with a monospace name column and caption of workflows, a value column (secure dots with eye; one empty highlighted "Missing"), a "Saved, not used by any workflow" group, the toolbar (Import .env…, Revert, Save), and the Keychain note. Add states: "Revealed secret", "Import summary", "Empty". Reuse existing components (sidebar, buttons, inputs) from zone 02.
- [ ] **Step 3:** Update S10 (Local execution review) with the SECRETS AND VARIABLES section (two columns, a missing highlighted row, "Save entered values to this workspace", "Manage in Secrets and Variables") and the new Secrets access line. Remove or retire the old S16 "Environments" and S17 frames (S17 is not needed).
- [ ] **Step 4:** Update the 00 index card's "States" line. Ask the user to press ⌘S in Pencil.
- [ ] **Step 5:** `screens-and-states.md`: rewrite the S16 row (Secrets and Variables: sidebar section; names from workflows, values per workspace in Keychain, reveal after Touch ID, import .env, not-used group; states filled, missing, revealed, import summary with skipped/encrypted/problems, empty, Keychain refused, save failed · FR-06/09); S10 states add "secrets and variables: saved, missing, entered for this run, Keychain refused"; S17 row: "Not needed: Runnir has no portable environments (decided in B28)".
- [ ] **Step 6: Commit**

```bash
git add docs/design
git commit -m "Design: Secrets and Variables and the review's values section (B28)"
```

### Task 10: Secrets and Variables model

**Files:**
- Create: `apps/macos/Runnir/Features/Desktop/WorkspaceValues.swift`
- Test: `apps/macos/RunnirTests/LocalRunValuesTests.swift` (add a suite)

**Interfaces:**
- Consumes: `LocalRunValueStoring`, `LocalRunValueKey`, `CoreWorkflow.secrets/variables`, `CoreEnvFile`, `OwnerConfirmation`.
- Produces:

```swift
@MainActor @Observable final class WorkspaceValuesModel {
    struct Row: Identifiable, Equatable { let key: LocalRunValueKey; let workflows: [String]; var saved: Bool; var id: LocalRunValueKey { key } }
    private(set) var secrets: [Row]          // names some workflow reads as secrets
    private(set) var variables: [Row]        // names some workflow reads as variables
    private(set) var unused: [Row]           // saved, read by no workflow
    var edits: [LocalRunValueKey: String]    // typed, not saved
    private(set) var removals: Set<LocalRunValueKey>
    private(set) var shown: [LocalRunValueKey: String]   // saved values on screen: variables, and secrets after Touch ID
    private(set) var error: String?
    private(set) var importSummary: String?
    private(set) var refused: Set<LocalRunValueKey>      // Keychain refused a read
    var isDirty: Bool
    func load(workspaceID: UUID, workflows: [CoreWorkflow], store: any LocalRunValueStoring) async
    func text(for key: LocalRunValueKey) -> String
    func setText(_ text: String, for key: LocalRunValueKey)
    func forget(_ key: LocalRunValueKey)
    func undoForget(_ key: LocalRunValueKey)
    func reveal(_ key: LocalRunValueKey, workspaceID: UUID, store: any LocalRunValueStoring, ask: @MainActor (String) async -> OwnerConfirmation) async
    func hideSecrets()
    func save(workspaceID: UUID, store: any LocalRunValueStoring) async -> Bool
    func revert()
    func apply(_ file: CoreEnvFile)
}
```

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
@Suite struct WorkspaceValuesModelTests {
    private let workspace = UUID()
    private func workflows() -> [CoreWorkflow] {
        [CoreWorkflow(id: ".github/workflows/ci.yml", name: "CI", triggers: ["push"], jobs: [], parseError: nil,
                      secrets: ["NPM_TOKEN", "SHARED"], variables: ["REGION", "SHARED"]),
         CoreWorkflow(id: ".github/workflows/deploy.yml", name: "Deploy", triggers: ["push"], jobs: [], parseError: nil,
                      secrets: ["NPM_TOKEN"])]
    }
    private let token = LocalRunValueKey(kind: .secret, name: "NPM_TOKEN")
    private let region = LocalRunValueKey(kind: .variable, name: "REGION")

    @Test func rowsMergeWorkflowsAndSavedNames() async {
        let old = LocalRunValueKey(kind: .secret, name: "OLD")
        let store = InMemoryLocalRunValueStore(values: [workspace: [token: "s3cr3t", region: "eu", old: "x"]])
        let model = WorkspaceValuesModel()
        await model.load(workspaceID: workspace, workflows: workflows(), store: store)
        #expect(model.secrets.map(\.key.name) == ["NPM_TOKEN", "SHARED"])
        #expect(model.secrets.first?.workflows == ["ci.yml", "deploy.yml"])
        #expect(model.secrets.first?.saved == true)
        #expect(model.secrets.last?.saved == false)
        #expect(model.variables.map(\.key.name) == ["REGION", "SHARED"])
        #expect(model.unused.map(\.key) == [old])
        // Variables show without asking; secrets stay hidden.
        #expect(model.text(for: region) == "eu")
        #expect(model.text(for: token) == "")
    }

    @Test func editsArePendingUntilSave() async throws {
        let store = InMemoryLocalRunValueStore()
        let model = WorkspaceValuesModel()
        await model.load(workspaceID: workspace, workflows: workflows(), store: store)
        model.setText("typed", for: token)
        #expect(model.isDirty)
        #expect(try await store.value(workspaceID: workspace, key: token) == nil)
        model.revert()
        #expect(!model.isDirty)
        model.setText("typed", for: token)
        #expect(await model.save(workspaceID: workspace, store: store))
        #expect(try await store.value(workspaceID: workspace, key: token) == "typed")
        #expect(!model.isDirty)
        #expect(model.secrets.first?.saved == true)
        model.forget(token)
        #expect(await model.save(workspaceID: workspace, store: store))
        #expect(try await store.value(workspaceID: workspace, key: token) == nil)
    }

    @Test func revealAsksTheOwnerFirst() async {
        let store = InMemoryLocalRunValueStore(values: [workspace: [token: "s3cr3t"]])
        let model = WorkspaceValuesModel()
        await model.load(workspaceID: workspace, workflows: workflows(), store: store)
        await model.reveal(token, workspaceID: workspace, store: store) { _ in .declined }
        #expect(model.text(for: token) == "")
        var reason = ""
        await model.reveal(token, workspaceID: workspace, store: store) { reason = $0; return .confirmed }
        #expect(model.text(for: token) == "s3cr3t")
        #expect(reason == "show the saved value of NPM_TOKEN")
        model.hideSecrets()
        #expect(model.text(for: token) == "")
    }

    @Test func importFillsMatchingNamesAndCountsTheRest() async {
        let model = WorkspaceValuesModel()
        await model.load(workspaceID: workspace, workflows: workflows(), store: InMemoryLocalRunValueStore())
        model.apply(CoreEnvFile(entries: [
            CoreEnvEntry(name: "NPM_TOKEN", value: "from-file", encrypted: false, line: 1),
            CoreEnvEntry(name: "SHARED", value: "both", encrypted: false, line: 2),
            CoreEnvEntry(name: "UNUSED", value: "x", encrypted: false, line: 3),
            CoreEnvEntry(name: "REGION", value: "", encrypted: true, line: 4),
        ], problems: [CoreEnvProblem(line: 5, message: "Not a NAME=value line.")]))
        #expect(model.text(for: token) == "from-file")
        #expect(model.text(for: LocalRunValueKey(kind: .secret, name: "SHARED")) == "both")
        #expect(model.text(for: LocalRunValueKey(kind: .variable, name: "SHARED")) == "both")
        #expect(model.text(for: region) == "")
        #expect(model.importSummary == "Filled 3 values. 1 name is not used by any workflow. 1 value is encrypted by dotenvx and was not imported. Line 5 could not be read.")
    }
}
```

- [ ] **Step 2: Implement**

```swift
import Foundation

/// The Secrets and Variables section of one window: the names the
/// workspace's workflows read, which have saved values, and edits not saved
/// yet. Saved secret values are read only to show one after Touch ID.
@MainActor
@Observable
final class WorkspaceValuesModel {
    struct Row: Identifiable, Equatable {
        let key: LocalRunValueKey
        /// File names of the workflows that read it; empty in `unused`.
        let workflows: [String]
        var saved: Bool
        var id: LocalRunValueKey { key }
    }

    private(set) var secrets: [Row] = []
    private(set) var variables: [Row] = []
    private(set) var unused: [Row] = []
    /// Typed values, not saved yet.
    private(set) var edits: [LocalRunValueKey: String] = [:]
    /// Saved values to forget on Save.
    private(set) var removals: Set<LocalRunValueKey> = []
    /// Saved values on screen: every variable, and a secret after Touch ID.
    private(set) var shown: [LocalRunValueKey: String] = [:]
    /// Names whose saved value Keychain would not give.
    private(set) var refused: Set<LocalRunValueKey> = []
    private(set) var error: String?
    private(set) var importSummary: String?
    private(set) var isLoading = false

    var isDirty: Bool { !edits.isEmpty || !removals.isEmpty }

    func load(workspaceID: UUID, workflows: [CoreWorkflow], store: any LocalRunValueStoring) async {
        isLoading = true
        defer { isLoading = false }
        let saved: Set<LocalRunValueKey>
        do { saved = try await store.keys(workspaceID: workspaceID) } catch {
            self.error = "Keychain did not list the saved values: \(error.localizedDescription)"
            return
        }
        var readers: [LocalRunValueKey: [String]] = [:]
        for workflow in workflows {
            let file = (workflow.id as NSString).lastPathComponent
            for name in workflow.secrets { readers[LocalRunValueKey(kind: .secret, name: name), default: []].append(file) }
            for name in workflow.variables { readers[LocalRunValueKey(kind: .variable, name: name), default: []].append(file) }
        }
        let rows = readers.map { Row(key: $0.key, workflows: $0.value.sorted(), saved: saved.contains($0.key)) }.sorted { $0.key < $1.key }
        secrets = rows.filter { $0.key.kind == .secret }
        variables = rows.filter { $0.key.kind == .variable }
        unused = saved.subtracting(readers.keys).sorted().map { Row(key: $0, workflows: [], saved: true) }
        shown = shown.filter { saved.contains($0.key) && $0.key.kind == .secret }
        refused = []
        for key in saved where key.kind == .variable {
            do { shown[key] = try await store.value(workspaceID: workspaceID, key: key) } catch { refused.insert(key) }
        }
    }

    /// What the value field shows: a typed value, else the saved one when it
    /// is on screen, else nothing.
    func text(for key: LocalRunValueKey) -> String {
        if removals.contains(key) { return "" }
        return edits[key] ?? shown[key] ?? ""
    }

    func setText(_ text: String, for key: LocalRunValueKey) {
        removals.remove(key)
        if text == shown[key] { edits[key] = nil } else { edits[key] = text }
    }

    func forget(_ key: LocalRunValueKey) {
        edits[key] = nil
        removals.insert(key)
    }

    func undoForget(_ key: LocalRunValueKey) { removals.remove(key) }

    func isSaved(_ key: LocalRunValueKey) -> Bool {
        (secrets + variables + unused).first { $0.key == key }?.saved ?? false
    }

    func reveal(_ key: LocalRunValueKey, workspaceID: UUID, store: any LocalRunValueStoring,
                ask: @MainActor (String) async -> OwnerConfirmation) async {
        guard key.kind == .secret else { return }
        guard case .confirmed = await ask("show the saved value of \(key.name)") else { return }
        do { shown[key] = try await store.value(workspaceID: workspaceID, key: key) } catch { refused.insert(key) }
    }

    /// Hides revealed secrets, when the window loses focus or the section changes.
    func hideSecrets() { shown = shown.filter { $0.key.kind == .variable } }

    /// Writes the edits and removals; keeps them and shows why on failure.
    func save(workspaceID: UUID, store: any LocalRunValueStoring) async -> Bool {
        do {
            for (key, value) in edits.sorted(by: { $0.key < $1.key }) {
                try await store.save(workspaceID: workspaceID, key: key, value: value)
            }
            for key in removals.sorted() { try await store.remove(workspaceID: workspaceID, key: key) }
        } catch {
            self.error = "Keychain did not save the changes: \(error.localizedDescription)"
            return false
        }
        let written = edits
        edits = [:]
        let forgotten = removals
        removals = []
        error = nil
        importSummary = nil
        for key in forgotten { shown[key] = nil }
        for (key, value) in written where key.kind == .variable { shown[key] = value }
        func mark(_ rows: inout [Row]) {
            for index in rows.indices {
                if written[rows[index].key] != nil { rows[index].saved = true }
                if forgotten.contains(rows[index].key) { rows[index].saved = false }
            }
        }
        mark(&secrets)
        mark(&variables)
        unused.removeAll { forgotten.contains($0.key) }
        return true
    }

    func revert() {
        edits = [:]
        removals = []
        importSummary = nil
    }

    /// Fills the names some workflow reads from a .env file, as edits.
    func apply(_ file: CoreEnvFile) {
        var filled = 0, notUsed = 0, encrypted = 0
        for entry in file.entries {
            let keys = (secrets + variables).map(\.key).filter { $0.name == entry.name }
            if keys.isEmpty { notUsed += 1; continue }
            if entry.encrypted { encrypted += 1; continue }
            for key in keys {
                setText(entry.value, for: key)
                filled += 1
            }
        }
        var parts = ["Filled \(filled) \(filled == 1 ? "value" : "values")."]
        if notUsed > 0 { parts.append("\(notUsed) \(notUsed == 1 ? "name is" : "names are") not used by any workflow.") }
        if encrypted > 0 { parts.append("\(encrypted) \(encrypted == 1 ? "value is" : "values are") encrypted by dotenvx and \(encrypted == 1 ? "was" : "were") not imported.") }
        let lines = file.problems.map { String($0.line) }
        if lines.count == 1 { parts.append("Line \(lines[0]) could not be read.") }
        if lines.count > 1 { parts.append("Lines \(ListFormatter.localizedString(byJoining: lines)) could not be read.") }
        importSummary = parts.joined(separator: " ")
    }
}
```

- [ ] **Step 3: Build, test, commit**

Run the app build and `RunnirTests`. Expected: PASS.

```bash
git add apps/macos
git commit -m "App: model for Secrets and Variables"
```

### Task 11: Secrets and Variables section

**Files:**
- Create: `apps/macos/Runnir/Features/Desktop/WorkspaceValuesView.swift`
- Modify: `apps/macos/Runnir/App/Navigation/AppSection.swift`, `apps/macos/Runnir/App/AppState.swift`, `apps/macos/Runnir/Features/Desktop/DesktopViews.swift` (routing), `apps/macos/Runnir/App/Desktop/DesktopCoordinator.swift` (store, unsaved prompts, removal), `apps/macos/Runnir/Features/Desktop/UnsavedChanges.swift`
- Test: `apps/macos/RunnirTests/DesktopStateTests.swift`, `apps/macos/RunnirTests/WorkflowEditingTests.swift`

**Interfaces:**
- Consumes: `WorkspaceValuesModel` (Task 10), `LocalRunValueStoring` (Task 8), `CoreHub.readEnvFile` (Task 7).
- Produces: `AppSection.secrets` (title "Secrets and Variables", symbol "key"), `AppState.values: WorkspaceValuesModel`, `DesktopCoordinator.localRunValues: any LocalRunValueStoring` (init parameter, default `InMemoryLocalRunValueStore()`; the app passes `KeychainLocalRunValueStore()`), `WorkspaceWindowManaging.unsavedNames: [String]` and `saveUnsavedChanges() async -> Bool` replacing `unsavedWorkflowName` / `saveUnsavedWorkflow()`.

- [ ] **Step 1: Write the failing tests**

`WorkflowEditingTests.swift`, next to the existing title test:

```swift
        #expect(UnsavedChangesPrompt.title(for: ["ci.yml", "Secrets and Variables"]) == "Do you want to save the changes you made to 2 items?")
```

`DesktopStateTests.swift`: rename the fake's `unsavedWorkflowName`/`saveUnsavedWorkflow` to `unsavedNames` (returning `unsaved.map { [$0] } ?? []`) and `saveUnsavedChanges()`; existing tests keep their meaning. Add:

```swift
    @Test func removingARegistrationForgetsItsLocalRunValues() async throws {
        let fixture = try DesktopFixture()  // use the file's existing fixture type
        let values = InMemoryLocalRunValueStore(values: [fixture.original.id: [LocalRunValueKey(kind: .secret, name: "A"): "x"]])
        let coordinator = DesktopCoordinator(store: fixture.store, localRunValues: values)
        await coordinator.loadSession()
        coordinator.removeRegistration(fixture.original)
        #expect(await eventually { (try? await values.keys(workspaceID: fixture.original.id))?.isEmpty == true })
    }
```

(Use the fixture and `eventually` helpers the file already has; adjust names to them.)

- [ ] **Step 2: Implement routing and state**

`AppSection.swift`: add `case secrets` after `runs`; `sidebarSections = [.dashboard, .workflows, .runs, .secrets, .workspace]`; title `"Secrets and Variables"`; symbol `"key"`. Fix every exhaustive `switch` on `AppSection` the compiler reports.

`AppState.swift`: add

```swift
    /// The Secrets and Variables section: names, saved values and edits.
    let values = WorkspaceValuesModel()
```

`UnsavedChanges.swift`, `title(for:)`:

```swift
    static func title(for files: [String]) -> String {
        if files.count == 1 { return "Do you want to save the changes you made to \(files[0])?" }
        let workflows = files.allSatisfy { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
        return "Do you want to save the changes you made to \(files.count) \(workflows ? "workflow files" : "items")?"
    }
```

`DesktopCoordinator.swift`:
- Protocol `WorkspaceWindowManaging`: replace `var unsavedWorkflowName: String? { get }` with `var unsavedNames: [String] { get }` and `func saveUnsavedWorkflow() async -> Bool` with `func saveUnsavedChanges() async -> Bool` (update the default extension: `var unsavedNames: [String] { [] }`).
- Call sites: line ~349 `if current.record.workspaceID != workspace.id, case let names = current.unsavedNames, !names.isEmpty { switch confirmUnsavedChanges(names) ...` and `current.saveUnsavedChanges()`; line ~530 likewise; `unsavedEditsQuitDecision` uses `windows.values.flatMap(\.unsavedNames).sorted()`; `saveAllUnsavedWorkflows` iterates `where !controller.unsavedNames.isEmpty` and calls `saveUnsavedChanges()`.
- `WorkspaceWindowController`:

```swift
    var unsavedNames: [String] {
        var names: [String] = []
        if let files = state?.files, files.isDirty, let name = files.selected?.name { names.append(name) }
        if state?.values.isDirty == true { names.append("Secrets and Variables") }
        return names
    }

    func saveUnsavedChanges() async -> Bool {
        guard let state else { return true }
        var saved = true
        if state.files.isDirty {
            guard let core = desktop.core else { return false }
            saved = await state.files.save(hub: core, workspaceID: record.workspaceID)
            if saved { await state.files.validate(hub: core, workspaceID: record.workspaceID) }
        }
        if state.values.isDirty {
            saved = await state.values.save(workspaceID: record.workspaceID, store: desktop.localRunValues) && saved
        }
        return saved
    }
```

- `DesktopCoordinator`: new stored `let localRunValues: any LocalRunValueStoring` and init parameter `localRunValues: any LocalRunValueStoring = InMemoryLocalRunValueStore()`; `DesktopAppDelegate` passes `localRunValues: KeychainLocalRunValueStore()`. In `removeRegistration`, after `hintDismissals.removeAll(...)`:

```swift
            Task { [localRunValues] in try? await localRunValues.removeAll(workspaceID: workspace.id) }
```

`DesktopViews.swift`, `content` switch, before `case .workflows`:

```swift
        case .secrets:
            if let session, let hub = desktop.core {
                WorkspaceValuesView(model: state.values, workspaceID: workspace.id, session: session, hub: hub, store: desktop.localRunValues)
            } else {
                coreUnavailable
            }
```

- [ ] **Step 3: The view**

`WorkspaceValuesView.swift`:

```swift
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// S16 Secrets and Variables: values for local runs, kept on this Mac.
struct WorkspaceValuesView: View {
    @Bindable var model: WorkspaceValuesModel
    let workspaceID: UUID
    let session: RepositorySession
    let hub: CoreHub
    let store: any LocalRunValueStoring
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let error = model.error { message(error, symbol: "exclamationmark.triangle", tint: RunnirTheme.destructive) }
                    if let summary = model.importSummary { message(summary, symbol: "square.and.arrow.down", tint: RunnirTheme.secondaryForeground) }
                    if model.secrets.isEmpty && model.variables.isEmpty && model.unused.isEmpty {
                        Text("No workflow in this workspace reads secrets or variables.")
                            .font(.system(size: 13)).foregroundStyle(RunnirTheme.secondaryForeground)
                    }
                    table("SECRETS", rows: model.secrets)
                    table("VARIABLES", rows: model.variables)
                    table("SAVED, NOT USED BY ANY WORKFLOW", rows: model.unused, unused: true)
                    Text("Values stay on this Mac in Keychain and are used only for local runs. GitHub Actions secrets stay on GitHub.")
                        .font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                }
                .padding(24).frame(maxWidth: 920, alignment: .leading)
            }
        }
        .task(id: session.workflows) { await model.load(workspaceID: workspaceID, workflows: session.workflows, store: store) }
        .onDisappear { model.hideSecrets() }
        .onChange(of: activeState) { _, state in if state != .key { model.hideSecrets() } }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text("Secrets and Variables").font(.system(size: 15, weight: .semibold))
            Spacer()
            Button("Import .env…", action: importFile)
            Button("Revert") { model.revert() }.disabled(!model.isDirty)
            Button("Save") { Task { _ = await model.save(workspaceID: workspaceID, store: store) } }
                .buttonStyle(DesignButtonStyle(primary: true)).keyboardShortcut("s").disabled(!model.isDirty)
        }
        .buttonStyle(DesignButtonStyle()).padding(.horizontal, 24).frame(height: 52)
    }

    @ViewBuilder private func table(_ title: String, rows: [WorkspaceValuesModel.Row], unused: Bool = false) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: title)
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        ValueRow(model: model, row: row, unused: unused,
                                 reveal: { Task { await model.reveal(row.key, workspaceID: workspaceID, store: store, ask: OwnerConfirmation.ask(reason:)) } })
                        if row.id != rows.last?.id { Divider() }
                    }
                }
                .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(RunnirTheme.border))
            }
        }
    }

    private func message(_ text: String, symbol: String, tint: Color) -> some View {
        Label(text, systemImage: symbol).font(.system(size: 12)).foregroundStyle(tint).fixedSize(horizontal: false, vertical: true)
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.message = "Choose a .env file to fill values from"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: session.path)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            switch await hub.readEnvFile(path: url.path) {
            case .read(let file): model.apply(file)
            case .failed(let reason): model.showImportFailure(reason)
            }
        }
    }
}

/// One name and its value field.
private struct ValueRow: View {
    @Bindable var model: WorkspaceValuesModel
    let row: WorkspaceValuesModel.Row
    let unused: Bool
    let reveal: () -> Void

    var body: some View {
        let key = row.key
        let forgotten = model.removals.contains(key)
        let missing = !row.saved && model.text(for: key).isEmpty
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(key.name).font(.system(size: 13, design: .monospaced)).textSelection(.enabled)
                Text(caption(missing: missing, forgotten: forgotten)).font(.system(size: 11))
                    .foregroundStyle(missing ? RunnirTheme.warning : RunnirTheme.secondaryForeground)
            }
            .frame(width: 300, alignment: .leading)
            if !unused {
                field(key: key, missing: missing)
            } else {
                Text(key.kind == .secret ? "Secret" : "Variable").font(.system(size: 12)).foregroundStyle(RunnirTheme.secondaryForeground)
                Spacer()
            }
            if row.saved {
                if forgotten {
                    Button("Undo") { model.undoForget(key) }
                } else {
                    Button { model.forget(key) } label: { Image(systemName: "trash") }.help("Forget the saved value on Save")
                }
            }
        }
        .buttonStyle(DesignButtonStyle(compact: true)).padding(.horizontal, 14).padding(.vertical, 10)
    }

    @ViewBuilder private func field(key: LocalRunValueKey, missing: Bool) -> some View {
        let binding = Binding(get: { model.text(for: key) }, set: { model.setText($0, for: key) })
        HStack(spacing: 6) {
            Group {
                if key.kind == .secret && model.shown[key] == nil {
                    SecureField(row.saved ? "••••••••" : "Value", text: binding)
                } else {
                    TextField("Value", text: binding)
                }
            }
            .textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(missing ? RunnirTheme.warning : .clear))
            if key.kind == .secret && row.saved && model.shown[key] == nil && model.edits[key] == nil {
                Button(action: reveal) { Image(systemName: "eye") }.help("Show the saved value (Touch ID or password)")
            }
        }
    }

    private func caption(missing: Bool, forgotten: Bool) -> String {
        if forgotten { return "Forgotten on Save" }
        if model.refused.contains(row.key) { return "Keychain refused access" }
        if unused { return "not used by any workflow" }
        let readers = row.workflows.joined(separator: ", ")
        return missing ? "Missing · \(readers)" : readers
    }
}
```

Add to `WorkspaceValuesModel`:

```swift
    func showImportFailure(_ reason: String) { importSummary = reason }
```

- [ ] **Step 4: Build, test, commit**

Run the app build and `RunnirTests`. Expected: PASS. Open the app (Debug), check the section against the S16 frame.

```bash
git add apps/macos
git commit -m "App: Secrets and Variables section in the workspace"
```

### Task 12: Values in the Run Locally review

**Files:**
- Modify: `apps/macos/Runnir/Features/Desktop/LocalRun.swift` (`LocalRunReviewModel`), `LocalRunViews.swift` (review section, access row), `DesktopViews.swift` (pass the store and an "open section" action)
- Test: `apps/macos/RunnirTests/LocalRunTests.swift`

**Interfaces:**
- Consumes: `LocalRunValueStoring`, `CoreHub.startLocalRun(workspaceID:prepared:secrets:variables:)`, `CoreLocalRunPlan.secrets/variables/unnamedSecrets`.
- Produces: `LocalRunReviewModel(workspaceID:workflowID:jobs:jobID:hub:values:useInstalledAct:)` with `values: any LocalRunValueStoring = InMemoryLocalRunValueStore()`; properties `entered: [LocalRunValueKey: String]`, `saveEntered: Bool`, `saved: Set<LocalRunValueKey>`, `refused: Set<LocalRunValueKey>`; `var runKeys: [LocalRunValueKey]`, `var missing: [LocalRunValueKey]`, `var accessSummary: String`.

- [ ] **Step 1: Write the failing tests**

```swift
    private func valuesPlan() -> CorePreparedLocalRun {
        var plan = plan()
        plan.secrets = ["NPM_TOKEN", "OTHER"]
        plan.variables = ["REGION"]
        return CorePreparedLocalRun(readiness: FakeCore.readyTools, plan: plan, confirmationID: "local_1", expiresAt: Date())
    }

    @Test func runSendsSavedAndEnteredValuesForPlanNames() async throws {
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = valuesPlan() }
        let token = LocalRunValueKey(kind: .secret, name: "NPM_TOKEN")
        let region = LocalRunValueKey(kind: .variable, name: "REGION")
        let store = InMemoryLocalRunValueStore(values: [workspace: [token: "saved", region: "eu",
                                                                     LocalRunValueKey(kind: .secret, name: "UNRELATED"): "x"]])
        let review = LocalRunReviewModel(workspaceID: workspace, workflowID: ".github/workflows/ci.yml", jobs: [], hub: hub, values: store)
        await review.prepare()
        #expect(review.saved == [token, region])
        #expect(review.missing == [LocalRunValueKey(kind: .secret, name: "OTHER")])
        #expect(review.accessSummary == "2 passed, 1 empty. Workflow steps can read these values and send them over the network.")
        review.entered[region] = "us"
        review.trusted = true
        fake.localOutputs = [output(lines: nil, phase: .finished, state: .succeeded)]
        _ = try #require(await review.run())
        #expect(fake.confirmedValues.first?.secrets == ["NPM_TOKEN": "saved"])
        #expect(fake.confirmedValues.first?.variables == ["REGION": "us"])
        #expect(try await store.value(workspaceID: workspace, key: region) == "eu")
    }

    @Test func enteredValuesAreSavedWhenAsked() async throws {
        let (hub, workspace, fake) = await hub { $0.preparedLocalRun = valuesPlan() }
        let store = InMemoryLocalRunValueStore()
        let review = LocalRunReviewModel(workspaceID: workspace, workflowID: ".github/workflows/ci.yml", jobs: [], hub: hub, values: store)
        await review.prepare()
        let other = LocalRunValueKey(kind: .secret, name: "OTHER")
        review.entered[other] = "typed"
        review.saveEntered = true
        review.trusted = true
        fake.localOutputs = [output(lines: nil, phase: .finished, state: .succeeded)]
        _ = try #require(await review.run())
        #expect(try await store.value(workspaceID: workspace, key: other) == "typed")
    }

    @Test func refusedKeychainReadCountsAsMissing() async {
        let (hub, workspace, _) = await hub { $0.preparedLocalRun = valuesPlan() }
        let token = LocalRunValueKey(kind: .secret, name: "NPM_TOKEN")
        let store = InMemoryLocalRunValueStore(values: [workspace: [token: "saved"]])
        await store.setFailReads(true)
        let review = LocalRunReviewModel(workspaceID: workspace, workflowID: ".github/workflows/ci.yml", jobs: [], hub: hub, values: store)
        await review.prepare()
        #expect(review.refused == [token])
        #expect(review.missing.contains(token))
    }
```

`prepare()` lists saved keys and test-reads each saved key of the plan once (without keeping the value) so a refused read shows before the run; `run()` reads the values again.

- [ ] **Step 2: Implement the model**

In `LocalRunReviewModel`:

```swift
    /// Values typed for this run, by name.
    var entered: [LocalRunValueKey: String] = [:]
    /// Save the typed values to the workspace when the run starts.
    var saveEntered = false
    private(set) var saved: Set<LocalRunValueKey> = []
    private(set) var refused: Set<LocalRunValueKey> = []
    @ObservationIgnored private let values: any LocalRunValueStoring

    /// The plan's names: secrets, then variables.
    var runKeys: [LocalRunValueKey] {
        guard let plan = prepared?.plan else { return [] }
        return plan.secrets.map { LocalRunValueKey(kind: .secret, name: $0) } + plan.variables.map { LocalRunValueKey(kind: .variable, name: $0) }
    }

    private func typed(_ key: LocalRunValueKey) -> String? { entered[key].flatMap { $0.isEmpty ? nil : $0 } }

    var missing: [LocalRunValueKey] {
        runKeys.filter { typed($0) == nil && (!saved.contains($0) || refused.contains($0)) }
    }

    var accessSummary: String {
        let keys = runKeys
        if keys.isEmpty { return "None read by this workflow. GitHub token and host environment are not passed" }
        let empty = missing.count
        return "\(keys.count - empty) passed, \(empty) empty. Workflow steps can read these values and send them over the network."
    }
```

Init gains `values: any LocalRunValueStoring = InMemoryLocalRunValueStore()` stored in `self.values`. At the end of the `.prepared` branch of `prepare()`:

```swift
            await loadSaved()
```

```swift
    private func loadSaved() async {
        let keys = (try? await values.keys(workspaceID: workspaceID)) ?? []
        saved = keys.intersection(runKeys)
        refused = []
        for key in saved where (try? await values.value(workspaceID: workspaceID, key: key)) == nil {
            refused.insert(key)
        }
    }
```

In `run()`, before `hub.startLocalRun`:

```swift
        var secrets: [String: String] = [:], variables: [String: String] = [:]
        for key in runKeys {
            let value: String?
            if let text = typed(key) { value = text } else if saved.contains(key) { value = try? await values.value(workspaceID: workspaceID, key: key) } else { value = nil }
            guard let value else { continue }
            if key.kind == .secret { secrets[key.name] = value } else { variables[key.name] = value }
        }
        if saveEntered {
            for (key, text) in entered where !text.isEmpty { try? await values.save(workspaceID: workspaceID, key: key, value: text) }
        }
```

and call `hub.startLocalRun(workspaceID: workspaceID, prepared: prepared, secrets: secrets, variables: variables)`. After the sheet closes the model is released with its typed values.

- [ ] **Step 3: The review section**

In `LocalRunViews.swift`, add a `values` section after `compatibility`, shown when `!model.runKeys.isEmpty`:

```swift
    @ViewBuilder private var values: some View {
        if !model.runKeys.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(title: "SECRETS AND VARIABLES")
                VStack(spacing: 0) {
                    ForEach(model.runKeys, id: \.self) { key in
                        let missing = model.missing.contains(key)
                        HStack(alignment: .firstTextBaseline, spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(key.name).font(.system(size: 13, design: .monospaced))
                                Text(model.refused.contains(key) ? "Keychain refused access" : missing ? "Missing · empty in this run" : key.kind == .secret ? "Saved secret" : "Saved variable")
                                    .font(.system(size: 11)).foregroundStyle(missing ? RunnirTheme.warning : RunnirTheme.secondaryForeground)
                            }.frame(width: 240, alignment: .leading)
                            let binding = Binding(get: { model.entered[key] ?? "" }, set: { model.entered[key] = $0 })
                            Group {
                                if key.kind == .secret {
                                    SecureField(model.saved.contains(key) ? "••••••••" : "Value for this run", text: binding)
                                } else {
                                    TextField(model.saved.contains(key) ? "Saved value" : "Value for this run", text: binding)
                                }
                            }
                            .textFieldStyle(.roundedBorder).font(.system(size: 13, design: .monospaced))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(missing ? RunnirTheme.warning : .clear))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        if key != model.runKeys.last { Divider() }
                    }
                }
                .background(RunnirTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Toggle("Save entered values to this workspace", isOn: $model.saveEntered).toggleStyle(.checkbox).font(.system(size: 12))
                    Spacer()
                    Button("Manage in Secrets and Variables", action: manageValues).buttonStyle(.link).font(.system(size: 12))
                }
            }
        }
    }
```

`LocalRunReviewView` gains `var manageValues: () -> Void = {}`; `DesktopViews` passes `{ state.localRunRequest = nil; state.selectedSection = .secrets }` and constructs the review model with `values: desktop.localRunValues`. In `access`, replace the Secrets row with `accessRow("key", "Secrets", model.accessSummary)`. Place `values` in the review's stack after `compatibility`.

- [ ] **Step 4: Build, test, commit**

Run the app build and `RunnirTests`. Expected: PASS.

```bash
git add apps/macos
git commit -m "App: secrets and variables in the Run Locally review"
```

### Task 13: Docs, live check and final verification

**Files:**
- Modify: `docs/architecture/workspace-persistence.md`, `docs/architecture/grpc-api.md`, `docs/product/mvp-implementation-checklist.md`, `docs/decisions/0006-bundled-act-for-local-runs.md` (one line on the secret and variable files), `docs/superpowers/specs/2026-10-25-local-run-secrets-design.md` (status: implemented, changes made while planning)

- [ ] **Step 1: Docs**
  - `workspace-persistence.md`: replace the "Plan for local runs (B28, not implemented)" sentence with the implemented behavior: names from the workflow, values per workspace in Keychain (`dev.runnir.local-run.<workspace>`), shown after Touch ID or the password, imported from a chosen `.env` file, typed for one run; act reads them from pipes linked as `secrets.yaml` and `vars.yaml` in the run's scratch folder; never on disk, argv, act's environment, the database or logs; removing the workspace forgets them.
  - `grpc-api.md`: `ReadEnvFile`, `ConfirmLocalRunRequest.secrets/variables`, `Workflow.secrets/variables`, `LocalRunPlan.variables/unnamed_secrets`.
  - Checklist: add a B28 row to Progress: "Secrets and variables for local runs ([spec](../superpowers/specs/2026-10-25-local-run-secrets-design.md)): names from `secrets.X`/`vars.X` in the workflow; a Secrets and Variables section with values per workspace in Keychain, shown after Touch ID or the password, filled from a chosen `.env` file (dotenvx-encrypted values flagged, not decrypted); the Run Locally review lists the run's names, takes values for one run and can save them; values reach act through pipes, masked in output; covered by Core and app unit tests and an end-to-end run on OrbStack" with missing "Signed-build Keychain check; dotenvx decryption". Change "Not started: B18–B24 and B28–B29" to "B18–B24 and B29". Update the B28 track line to describe what was built.
  - ADR 0006: in the act command line paragraph, say `--secret-file` and `--var-file` point at pipes carrying the user's values, and `--env-file`/`--input-file` at an empty file.
- [ ] **Step 2: Full verification**
  - `cd core && go test ./... && go vet ./... && go build ./...`
  - App build and `RunnirTests`.
  - Contract check: regenerate and confirm `git status` shows no change.
- [ ] **Step 3: Live check** in the Debug app: open a workspace whose workflow reads a secret and a variable, set them in Secrets and Variables (Keychain prompt may appear for a Debug build), reveal the secret with Touch ID, import a `.env`, run locally on OrbStack, see the variable printed and the secret masked; remove a test workspace and check its Keychain items are gone (`security find-generic-password -s dev.runnir.local-run.<uuid>` fails). Record the result in the B28 row's evidence, naming what was not checked.
- [ ] **Step 4: Commit and open the PR**

```bash
git add docs
git commit -m "Docs: secrets and variables for local runs (B28)"
git push -u origin dilbarov/local-run-secrets
gh pr create --title "Secrets and variables for local runs (B28)" --body "<summary of the change, tests and the live check; no AI attribution>"
```
