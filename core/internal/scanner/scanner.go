// Package scanner reads a repository's current branch and GitHub Actions
// workflow files. It only parses structure: expressions are kept verbatim,
// nothing is evaluated, and symlinks are never followed. The only reads outside
// the repository root concern a linked worktree's git directory named by its
// ".git" file: the bounded "gitdir" back-reference file is read and compared
// (never returned) to confirm the directory belongs to this worktree, and only
// then is its HEAD read for the branch.
package scanner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"

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
	snapshot := repository.Snapshot{Workflows: workflows}
	if gitDir, linked, ok := resolveGitDir(root); ok {
		snapshot.Branch = readBranch(gitDir)
		snapshot.GitHubRepository = readGitHubRepository(gitDir, linked)
	}
	return snapshot, nil
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

// resolveGitDir returns the repository's git directory: ".git" itself, or for
// a linked worktree (linked is true) the directory its ".git" file names once
// that directory confirms it belongs to this worktree.
func resolveGitDir(root string) (gitDir string, linked, ok bool) {
	gitPath := filepath.Join(root, ".git")
	info, err := os.Lstat(gitPath)
	if err != nil {
		return "", false, false
	}
	switch {
	case info.IsDir():
		return gitPath, false, true
	case info.Mode().IsRegular(): // linked worktree: ".git" holds "gitdir: <path>"
		data, err := readBounded(gitPath, maxHeadBytes)
		if err != nil {
			return "", false, false
		}
		target, ok := strings.CutPrefix(strings.TrimSpace(string(data)), "gitdir:")
		target = strings.TrimSpace(target)
		if !ok || target == "" {
			return "", false, false
		}
		if !filepath.IsAbs(target) {
			target = filepath.Join(root, target)
		}
		if !isOwnWorktreeGitDir(target, gitPath) {
			return "", false, false
		}
		return target, true, true
	default:
		return "", false, false
	}
}

// readBranch returns the branch HEAD points to, or "" when HEAD is detached,
// unreadable or does not name a local branch.
func readBranch(gitDir string) string {
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

const maxConfigBytes = 64 * 1024

// readGitHubRepository returns "owner/name" when the origin remote points at
// github.com. A linked worktree shares the main repository's config: its
// "commondir" file is followed only when it names the git directory that
// holds the worktree ("<git dir>/worktrees/<name>"), so a repository cannot
// point the scan at another repository's config.
func readGitHubRepository(gitDir string, linked bool) string {
	commonDir := gitDir
	if linked {
		data, err := readBounded(filepath.Join(gitDir, "commondir"), maxHeadBytes)
		if err != nil {
			return ""
		}
		target := strings.TrimSpace(string(data))
		if !filepath.IsAbs(target) {
			target = filepath.Join(gitDir, target)
		}
		owner := filepath.Dir(filepath.Dir(filepath.Clean(gitDir)))
		if !samePath(filepath.Clean(target), owner) {
			return ""
		}
		commonDir = owner
	}
	config, err := readBounded(filepath.Join(commonDir, "config"), maxConfigBytes)
	if err != nil {
		return ""
	}
	return gitHubRepository(originURL(string(config)))
}

// originURL returns the first url of [remote "origin"] in a git config file.
func originURL(config string) string {
	inOrigin := false
	for _, raw := range strings.Split(config, "\n") {
		line := strings.TrimSpace(raw)
		if line == "" || line[0] == '#' || line[0] == ';' {
			continue
		}
		if line[0] == '[' {
			header := strings.TrimSuffix(strings.TrimPrefix(line, "["), "]")
			section, subsection, _ := strings.Cut(header, " ")
			inOrigin = strings.EqualFold(section, "remote") && strings.Trim(strings.TrimSpace(subsection), `"`) == "origin"
			continue
		}
		if !inOrigin {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if ok && strings.EqualFold(strings.TrimSpace(key), "url") {
			return strings.Trim(strings.TrimSpace(value), `"`)
		}
	}
	return ""
}

// gitHubRepository turns a github.com remote URL into "owner/name"; any other
// host, or a malformed path, gives "".
func gitHubRepository(remote string) string {
	var path string
	if user, rest, ok := strings.Cut(remote, "@"); ok && !strings.Contains(user, "/") && !strings.Contains(remote, "://") {
		// scp-like: git@github.com:owner/name.git
		host, p, ok := strings.Cut(rest, ":")
		if !ok || !strings.EqualFold(host, "github.com") {
			return ""
		}
		path = p
	} else {
		parsed, err := url.Parse(remote)
		if err != nil || !strings.EqualFold(parsed.Hostname(), "github.com") {
			return ""
		}
		switch parsed.Scheme {
		case "https", "http", "ssh", "git":
		default:
			return ""
		}
		path = parsed.Path
	}
	path = strings.TrimSuffix(strings.Trim(path, "/"), ".git")
	owner, name, ok := strings.Cut(path, "/")
	if !ok || !validOwner.MatchString(owner) || !validName.MatchString(name) {
		return ""
	}
	return owner + "/" + name
}

var (
	validOwner = regexp.MustCompile(`^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$`)
	validName  = regexp.MustCompile(`^[A-Za-z0-9._-]{1,100}$`)
)

// isOwnWorktreeGitDir accepts a linked worktree's git directory only when it
// has git's layout ("<git dir>/worktrees/<name>", where the git dir may be
// ".git" or a bare repository such as "project.git") and its "gitdir" file
// points back at this worktree's ".git" file. The back-reference is what proves
// ownership; a ".git" file aiming the scan at some other place fails it.
func isOwnWorktreeGitDir(gitDir, worktreeGitFile string) bool {
	clean := filepath.Clean(gitDir)
	if filepath.Base(filepath.Dir(clean)) != "worktrees" {
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
	files, err := ReadWorkflowFiles(ctx, root)
	if err != nil {
		return nil, err
	}
	workflows := make([]repository.Workflow, 0, len(files))
	for _, file := range files {
		if file.Problem != "" {
			workflows = append(workflows, repository.Workflow{ID: file.ID, Name: file.ID, ParseError: file.Problem})
			continue
		}
		workflows = append(workflows, parse(file.ID, file.Data))
	}
	return workflows, nil
}

// WorkflowFile is one file of .github/workflows. Problem is set, and Data
// empty, when the file could not be read.
type WorkflowFile struct {
	ID      string // ".github/workflows/<name>"
	Data    []byte
	Problem string
}

// ReadWorkflowFiles reads the YAML files of .github/workflows in name order:
// regular files only, at most 200 files of 1 MiB each. Symlinked .github or
// workflows directories are refused so a repository cannot point a read
// outside its granted folder. A missing directory means no files; one the
// Core may not read is an error, so it is never mistaken for an empty
// repository.
func ReadWorkflowFiles(ctx context.Context, root string) ([]WorkflowFile, error) {
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
	var files []WorkflowFile
	for _, entry := range entries { // ReadDir returns names sorted
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		ext := strings.ToLower(filepath.Ext(entry.Name()))
		if !entry.Type().IsRegular() || (ext != ".yml" && ext != ".yaml") {
			continue
		}
		if len(files) == maxWorkflowFiles {
			break
		}
		id := path.Join(workflowsDir, entry.Name())
		data, err := readBounded(filepath.Join(root, filepath.FromSlash(id)), maxFileBytes)
		switch {
		case err == errTooLarge:
			files = append(files, WorkflowFile{ID: id, Problem: "file is larger than 1 MiB"})
		case err != nil:
			files = append(files, WorkflowFile{ID: id, Problem: "cannot read file"})
		default:
			files = append(files, WorkflowFile{ID: id, Data: data})
		}
	}
	return files, nil
}

// ReadLinterConfig returns the repository's actionlint config
// (.github/actionlint.yaml or .yml) and its id, or nothing when there is
// none. Like workflow files it must be a regular file inside a regular
// .github directory, at most 64 KiB.
func ReadLinterConfig(root string) (id string, data []byte, err error) {
	if info, err := os.Lstat(filepath.Join(root, ".github")); err != nil || !info.IsDir() {
		return "", nil, nil
	}
	for _, name := range []string{"actionlint.yaml", "actionlint.yml"} {
		id := path.Join(".github", name)
		data, err := readBounded(filepath.Join(root, filepath.FromSlash(id)), maxConfigBytes)
		switch {
		case err == nil:
			return id, data, nil
		case errors.Is(err, fs.ErrNotExist):
			continue
		case errors.Is(err, fs.ErrPermission):
			return "", nil, repository.ErrAccessDenied
		default:
			return id, nil, fmt.Errorf("%s cannot be read: it must be a regular file of at most 64 KiB", id)
		}
	}
	return "", nil, nil
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

// truncate bounds a message without splitting a character: gRPC refuses to
// send a string that is not valid UTF-8, which would fail the whole listing.
// Invalid bytes are replaced first, because a replacement character is
// longer than the byte it stands for.
func truncate(message string) string {
	message = strings.ToValidUTF8(message, "\uFFFD")
	if len(message) > maxErrorChars {
		cut := maxErrorChars
		for cut > 0 && !utf8.RuneStart(message[cut]) {
			cut--
		}
		message = message[:cut]
	}
	return message
}
