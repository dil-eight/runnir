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
