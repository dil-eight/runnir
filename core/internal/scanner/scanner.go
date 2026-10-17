// Package scanner reads a repository's current branch and GitHub Actions
// workflow files. It only parses structure: expressions are kept verbatim,
// nothing is evaluated, and symlinks are never followed. The only reads outside
// the repository root are the HEAD and back-reference files of a linked
// worktree's own git directory, and only after that directory confirms it
// belongs to this worktree.
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
	"strings"

	"go.yaml.in/yaml/v3"

	"runnir/core/internal/repository"
)

const (
	maxFileBytes     = 1 << 20
	maxWorkflowFiles = 200
	maxJobs          = 1000
	maxHeadBytes     = 4096
	maxErrorChars    = 200
	workflowsDir     = ".github/workflows"
)

// Scanner implements repository.Scanner against the local file system.
type Scanner struct{}

func New() Scanner { return Scanner{} }

// Scan returns the checked-out branch and parsed workflows. Unparseable files
// are reported in their Workflow.ParseError and never fail the scan.
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
	return repository.Snapshot{Branch: readBranch(root), Workflows: workflows}, nil
}

// absentOrError maps "does not exist" to no error and permission problems to
// repository.ErrAccessDenied.
func absentOrError(err error) error {
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return nil
	case errors.Is(err, fs.ErrPermission):
		return repository.ErrAccessDenied
	default:
		return fmt.Errorf("read workflows: %w", err)
	}
}

// probeReadable tells "the folder is unreadable" apart from "the folder has no
// workflows". Without it a denied folder (for example under an App Sandbox that
// granted access to the app but not to this process) would look like an empty
// repository, because later steps treat unreadable parts as absent.
func probeReadable(root string) error {
	dir, err := os.Open(root)
	if err == nil {
		defer dir.Close()
		_, err = dir.Readdirnames(1)
		if err == io.EOF {
			return nil
		}
	}
	switch {
	case err == nil:
		return nil
	case errors.Is(err, fs.ErrPermission):
		return repository.ErrAccessDenied
	default:
		return fmt.Errorf("read repository folder: %w", err)
	}
}

// readBranch returns the branch HEAD points to, or "" when HEAD is detached,
// unreadable or does not name a local branch.
func readBranch(root string) string {
	gitPath := filepath.Join(root, ".git")
	info, err := os.Lstat(gitPath)
	if err != nil {
		return ""
	}
	gitDir := gitPath
	switch {
	case info.Mode().IsRegular(): // linked worktree: ".git" holds "gitdir: <path>"
		data, err := readBounded(gitPath, maxHeadBytes)
		if err != nil {
			return ""
		}
		target, ok := strings.CutPrefix(strings.TrimSpace(string(data)), "gitdir:")
		target = strings.TrimSpace(target)
		if !ok || target == "" {
			return ""
		}
		if !filepath.IsAbs(target) {
			target = filepath.Join(root, target)
		}
		if !isOwnWorktreeGitDir(target, gitPath) {
			return ""
		}
		gitDir = target
	case !info.IsDir():
		return ""
	}
	head, err := readBounded(filepath.Join(gitDir, "HEAD"), maxHeadBytes)
	if err != nil {
		return ""
	}
	ref, ok := strings.CutPrefix(strings.TrimSpace(string(head)), "ref:")
	if !ok {
		return ""
	}
	branch, ok := strings.CutPrefix(strings.TrimSpace(ref), "refs/heads/")
	if !ok {
		return ""
	}
	return branch
}

// isOwnWorktreeGitDir accepts a linked worktree's git directory only when it
// has git's layout (".../.git/worktrees/<name>") and its "gitdir" file points
// back at this worktree's ".git" file. A ".git" file written by a repository to
// aim the scan at some other place fails both checks.
func isOwnWorktreeGitDir(gitDir, worktreeGitFile string) bool {
	clean := filepath.Clean(gitDir)
	if filepath.Base(filepath.Dir(clean)) != "worktrees" || filepath.Base(filepath.Dir(filepath.Dir(clean))) != ".git" {
		return false
	}
	back, err := readBounded(filepath.Join(clean, "gitdir"), maxHeadBytes)
	if err != nil {
		return false
	}
	return samePath(strings.TrimSpace(string(back)), worktreeGitFile)
}

func samePath(a, b string) bool {
	ra, errA := filepath.EvalSymlinks(a)
	rb, errB := filepath.EvalSymlinks(b)
	return errA == nil && errB == nil && ra == rb
}

func readWorkflows(ctx context.Context, root string) ([]repository.Workflow, error) {
	// Refuse symlinked .github or workflows directories so a repository
	// cannot point the scan outside its granted folder. A missing directory
	// means no workflows; one the Core may not read is an error, so it is
	// never mistaken for an empty repository.
	for _, dir := range []string{".github", workflowsDir} {
		info, err := os.Lstat(filepath.Join(root, filepath.FromSlash(dir)))
		if err != nil {
			return nil, absentOrError(err)
		}
		if !info.IsDir() {
			return nil, nil
		}
	}
	entries, err := os.ReadDir(filepath.Join(root, filepath.FromSlash(workflowsDir)))
	if err != nil {
		return nil, absentOrError(err)
	}
	var workflows []repository.Workflow
	for _, entry := range entries { // ReadDir returns names sorted
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		ext := strings.ToLower(filepath.Ext(entry.Name()))
		if !entry.Type().IsRegular() || (ext != ".yml" && ext != ".yaml") {
			continue
		}
		if len(workflows) == maxWorkflowFiles {
			break
		}
		id := path.Join(workflowsDir, entry.Name())
		data, err := readBounded(filepath.Join(root, filepath.FromSlash(id)), maxFileBytes)
		switch {
		case err == errTooLarge:
			workflows = append(workflows, repository.Workflow{ID: id, Name: id, ParseError: "file is larger than 1 MiB"})
		case err != nil:
			workflows = append(workflows, repository.Workflow{ID: id, Name: id, ParseError: "cannot read file"})
		default:
			workflows = append(workflows, parse(id, data))
		}
	}
	return workflows, nil
}

var errTooLarge = fmt.Errorf("file too large")

// readBounded reads a regular file of at most limit bytes. The type check and
// the open are not atomic; the scan is read-only and bounded, so a race can
// at worst read one extra small file.
func readBounded(file string, limit int64) ([]byte, error) {
	info, err := os.Lstat(file)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() {
		return nil, fmt.Errorf("not a regular file")
	}
	f, err := os.Open(file)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, errTooLarge
	}
	return data, nil
}

func parse(id string, data []byte) repository.Workflow {
	workflow := repository.Workflow{ID: id, Name: id}
	fail := func(message string) repository.Workflow {
		workflow.ParseError = message
		return workflow
	}

	var document yaml.Node
	if err := yaml.NewDecoder(bytes.NewReader(data)).Decode(&document); err != nil {
		if err == io.EOF {
			return fail("file is empty")
		}
		return fail(truncate("invalid YAML: " + strings.TrimPrefix(err.Error(), "yaml: ")))
	}
	if document.Kind != yaml.DocumentNode || len(document.Content) != 1 {
		return fail("file is empty")
	}
	top := resolve(document.Content[0])
	if top.Kind != yaml.MappingNode {
		return fail("workflow must be a mapping")
	}

	for i := 0; i+1 < len(top.Content); i += 2 {
		key, value := top.Content[i], resolve(top.Content[i+1])
		switch key.Value {
		case "name":
			if value.Kind == yaml.ScalarNode && value.Value != "" {
				workflow.Name = value.Value
			}
		case "on":
			workflow.Triggers = triggers(value)
		case "jobs":
			workflow.Jobs = jobs(value, &workflow)
		}
	}
	return workflow
}

// triggers accepts every form of "on": a scalar, a sequence of scalars, or a
// mapping whose keys are the events.
func triggers(node *yaml.Node) []string {
	if node.Kind == yaml.MappingNode {
		var out []string
		for i := 0; i < len(node.Content); i += 2 {
			out = append(out, node.Content[i].Value)
		}
		return out
	}
	return scalarList(node)
}

// scalarList accepts a scalar or a sequence of scalars, the shape of "needs"
// and of the short forms of "on"; anything else yields nothing.
func scalarList(node *yaml.Node) []string {
	switch node.Kind {
	case yaml.ScalarNode:
		return []string{node.Value}
	case yaml.SequenceNode:
		var out []string
		for _, item := range node.Content {
			if item = resolve(item); item.Kind == yaml.ScalarNode {
				out = append(out, item.Value)
			}
		}
		return out
	}
	return nil
}

func jobs(node *yaml.Node, workflow *repository.Workflow) []repository.Job {
	if node.Kind != yaml.MappingNode {
		return nil
	}
	var out []repository.Job
	for i := 0; i+1 < len(node.Content); i += 2 {
		if len(out) == maxJobs {
			workflow.ParseError = fmt.Sprintf("more than %d jobs; list truncated", maxJobs)
			break
		}
		job := repository.Job{ID: node.Content[i].Value, Name: node.Content[i].Value}
		if body := resolve(node.Content[i+1]); body.Kind == yaml.MappingNode {
			for j := 0; j+1 < len(body.Content); j += 2 {
				value := resolve(body.Content[j+1])
				switch body.Content[j].Value {
				case "name":
					if value.Kind == yaml.ScalarNode && value.Value != "" {
						job.Name = value.Value
					}
				case "needs":
					job.Needs = scalarList(value)
				}
			}
		}
		out = append(out, job)
	}
	return out
}

// resolve follows aliases a bounded number of steps. Aliases are never
// expanded wholesale, so alias bombs cost nothing.
func resolve(node *yaml.Node) *yaml.Node {
	for depth := 0; node.Kind == yaml.AliasNode && node.Alias != nil && depth < 8; depth++ {
		node = node.Alias
	}
	return node
}

func truncate(message string) string {
	if len(message) > maxErrorChars {
		return message[:maxErrorChars]
	}
	return message
}
