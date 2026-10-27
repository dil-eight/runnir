package flow

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// maxChangedFiles bounds the files read for paths filters.
const maxChangedFiles = 5000

// Git reads what a change touches with the git CLI, in the working tree.
type Git struct {
	// Path is the git binary; empty when none was found.
	Path string
	Root string
	// Timeout bounds each git command; zero is 5 seconds.
	Timeout time.Duration
}

// FindGit looks for git in dirs. /usr/bin/git on macOS is a stand-in that
// offers to install the developer tools when they are missing, so it counts
// only once they are there.
func FindGit(dirs []string) string {
	for _, dir := range dirs {
		candidate := filepath.Join(dir, "git")
		info, err := os.Stat(candidate)
		if err != nil || info.IsDir() || info.Mode()&0o111 == 0 {
			continue
		}
		if candidate == "/usr/bin/git" && !developerToolsInstalled() {
			continue
		}
		return candidate
	}
	return ""
}

func developerToolsInstalled() bool {
	if _, err := os.Stat("/Library/Developer/CommandLineTools/usr/bin/git"); err == nil {
		return true
	}
	if target, err := filepath.EvalSymlinks("/var/db/xcode_select_link"); err == nil {
		if _, err := os.Stat(filepath.Join(target, "usr", "bin", "git")); err == nil {
			return true
		}
	}
	return false
}

func (g Git) run(ctx context.Context, args ...string) ([]byte, error) {
	timeout := g.Timeout
	if timeout <= 0 {
		timeout = 5 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, g.Path, append([]string{"-C", g.Root}, args...)...)
	// No prompts, no locks taken behind the user's back, stable output.
	cmd.Env = []string{"GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0", "LC_ALL=C", "HOME=" + os.Getenv("HOME"), "PATH=/usr/bin:/bin"}
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.WaitDelay = time.Second
	err := cmd.Run()
	return out.Bytes(), err
}

// Head is the commit checked out, empty when git cannot say.
func (g Git) Head(ctx context.Context) string {
	if g.Path == "" {
		return ""
	}
	out, err := g.run(ctx, "rev-parse", "HEAD")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// Upstream is the branch the current one tracks ("origin/feature"), empty
// without one.
func (g Git) Upstream(ctx context.Context) string {
	if g.Path == "" {
		return ""
	}
	out, err := g.run(ctx, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// UpstreamHead is the commit of the branch the current one tracks, as last
// fetched or pushed; empty without one.
func (g Git) UpstreamHead(ctx context.Context) string {
	if g.Path == "" {
		return ""
	}
	out, err := g.run(ctx, "rev-parse", "--verify", "--quiet", "@{upstream}")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// maxTags bounds the local tags read.
const maxTags = 10000

// Tags are the tags of the local repository; nil when git cannot say.
func (g Git) Tags(ctx context.Context) map[string]bool {
	if g.Path == "" {
		return nil
	}
	out, err := g.run(ctx, "for-each-ref", "--format=%(refname)", "--count="+strconv.Itoa(maxTags), "refs/tags")
	if err != nil {
		return nil
	}
	tags := map[string]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		if name, ok := strings.CutPrefix(strings.TrimSpace(line), "refs/tags/"); ok && name != "" {
			tags[name] = true
		}
	}
	return tags
}

// Changes lists the files changed since the change left `against`: the
// commits since the merge base, uncommitted changes and untracked files.
func (g Git) Changes(ctx context.Context, against string) Changes {
	out := Changes{Against: against}
	if g.Path == "" {
		out.Note = "git not found, so paths filters are unknown"
		return out
	}
	baseOut, err := g.run(ctx, "merge-base", "HEAD", against)
	base := strings.TrimSpace(string(baseOut))
	if err != nil || base == "" {
		out.Note = against + " is unknown here: fetch first, so paths filters are unknown"
		return out
	}
	seen := map[string]bool{}
	add := func(data []byte) {
		for _, name := range bytes.Split(data, []byte{0}) {
			if file := string(name); file != "" && !seen[file] && len(out.Files) < maxChangedFiles {
				seen[file] = true
				out.Files = append(out.Files, file)
			}
		}
	}
	diff, err := g.run(ctx, "diff", "--name-only", "-z", base)
	if err != nil {
		out.Note = "git could not list the changed files, so paths filters are unknown"
		return out
	}
	add(diff)
	if untracked, err := g.run(ctx, "ls-files", "-z", "--others", "--exclude-standard"); err == nil {
		add(untracked)
	}
	out.Known = true
	return out
}

// ChangesFor reads the changes a scenario's paths filters look at.
func (g Git) ChangesFor(ctx context.Context, s Scenario, repo Repo) Changes {
	switch s.Kind {
	case PullRequest, Merge:
		if _, ok := exactName(s.Target); !ok {
			return Changes{Note: "pick a branch for " + s.Target + " to read paths filters"}
		}
		return g.Changes(ctx, "origin/"+s.Target)
	case Push:
		if upstream := g.Upstream(ctx); upstream != "" {
			return g.Changes(ctx, upstream)
		}
		if repo.DefaultBranch == "" {
			return Changes{Note: "the branch has no upstream, so paths filters are unknown"}
		}
		return g.Changes(ctx, "origin/"+repo.DefaultBranch)
	}
	return Changes{Known: true}
}
