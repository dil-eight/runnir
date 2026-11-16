package localrun

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
)

// SandboxExec runs a command in the macOS sandbox (Seatbelt). A lane with
// jobs on this Mac runs act under it, so the jobs' steps can neither read
// the user's home folder outside the repository nor write outside the run's
// folders, nor reach the Keychain, the pasteboard, the container engine or
// an SSH agent, nor start anything outside the sandbox.
var SandboxExec = "/usr/bin/sandbox-exec"

// sandboxRoots are the folders a lane under the sandbox may use.
type sandboxRoots struct {
	// Home is the user's home folder: closed but for the folders below.
	Home string
	// Readable folders inside or outside it: the repository, act, Node.js.
	// None is the home folder or holds it (opensHome).
	Readable []string
	// Writable folders: the lane's scratch folder and act's cache.
	Writable []string
	// Sockets are unix sockets outside the home folder a lane may not
	// connect to: the container engine's.
	Sockets []string
}

// sandboxProfile is the Seatbelt profile of a lane with jobs on this Mac.
// Everything is allowed but writes outside the run's folders and the
// system's temporary ones, reads of the home folder outside the readable
// folders, the Keychain's and the pasteboard's services, unix sockets in the
// home folder and launchd's, and the ways to start something outside the
// sandbox.
func sandboxProfile(roots sandboxRoots) string {
	var b strings.Builder
	b.WriteString("(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write*")
	for _, dir := range append(append([]string(nil), roots.Writable...), "/private/tmp", "/private/var/tmp", "/private/var/folders") {
		fmt.Fprintf(&b, "\n  (subpath %s)", sbString(dir))
	}
	for _, device := range []string{"/dev/null", "/dev/zero", "/dev/dtracehelper", "/dev/ptmx", "/dev/tty"} {
		fmt.Fprintf(&b, "\n  (literal %s)", sbString(device))
	}
	b.WriteString("\n  (regex #\"^/dev/ttys[0-9]+$\")\n  (subpath \"/dev/fd\"))\n")
	fmt.Fprintf(&b, "(deny file-read* (subpath %s))\n(allow file-read*", sbString(roots.Home))
	readable := append(append([]string(nil), roots.Readable...), roots.Writable...)
	for _, dir := range readable {
		fmt.Fprintf(&b, "\n  (subpath %s)", sbString(dir))
	}
	b.WriteString(")\n")
	// Tools look at the folders on the way to an allowed one.
	ancestors := map[string]bool{}
	for _, dir := range readable {
		for parent := filepath.Dir(dir); parent != dir && len(parent) > 1; dir, parent = parent, filepath.Dir(parent) {
			ancestors[parent] = true
		}
	}
	list := make([]string, 0, len(ancestors))
	for dir := range ancestors {
		list = append(list, dir)
	}
	sort.Strings(list)
	if len(list) > 0 {
		b.WriteString("(allow file-read-metadata")
		for _, dir := range list {
			fmt.Fprintf(&b, "\n  (literal %s)", sbString(dir))
		}
		b.WriteString(")\n")
	}
	b.WriteString("(deny mach-lookup\n  (global-name \"com.apple.SecurityServer\")\n  (global-name \"com.apple.securityd.xpc\")\n" +
		"  (global-name \"com.apple.secd\")\n  (global-name \"com.apple.pasteboard.1\"))\n")
	// What LaunchServices opens, an Apple Event drives and a launchd job
	// runs is outside the sandbox.
	b.WriteString("(deny lsopen)\n(deny appleevent-send)\n(deny job-creation)\n")
	// Connecting to a unix socket is not reading it, so the closed home
	// folder leaves the container engine's socket and SSH agents open, and
	// launchd's sockets hold the system's SSH agent.
	fmt.Fprintf(&b, "(deny network-outbound\n  (remote unix-socket (subpath %s))\n", sbString(roots.Home))
	b.WriteString("  (remote unix-socket (regex #\"^/private/(var/run|tmp)/com\\.apple\\.launchd\\.[^/]+/\"))")
	for _, socket := range roots.Sockets {
		fmt.Fprintf(&b, "\n  (remote unix-socket (path-literal %s))", sbString(socket))
	}
	b.WriteString(")\n")
	return b.String()
}

// sbString quotes a path for a Seatbelt profile.
func sbString(path string) string {
	return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(path) + `"`
}

// realPath resolves symbolic links, as the sandbox matches resolved paths;
// a path that does not resolve is kept.
func realPath(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	return path
}

// opensHome reports a folder that is the home folder or holds it: allowing
// it after closing the home folder would open all of it.
func opensHome(dir, home string) bool {
	dir, home = filepath.Clean(dir), filepath.Clean(home)
	return dir == home || dir == "/" || strings.HasPrefix(home, dir+string(filepath.Separator))
}

// maxGitFileBytes bounds the .git and commondir files read for the sandbox.
const maxGitFileBytes = 4096

// gitFolders are the repository's git folders outside it, as git finds them:
// the folder its .git file names (a linked worktree's, or one made with
// --separate-git-dir) and, for a linked worktree, the main repository's git
// folder when its commondir names the folder that holds the worktree's.
func gitFolders(repository string) []string {
	dir, ok := gitFileTarget(filepath.Join(repository, ".git"), repository)
	if !ok {
		return nil
	}
	folders := []string{realPath(dir)}
	// .../.git/worktrees/<name>: commondir names .../.git.
	if common, ok := gitFileTarget(filepath.Join(dir, "commondir"), dir); ok && filepath.Base(filepath.Dir(dir)) == "worktrees" {
		if owner := filepath.Dir(filepath.Dir(dir)); realPath(common) == realPath(owner) {
			folders = append(folders, realPath(owner))
		}
	}
	return folders
}

// gitFileTarget reads a folder a git file names ("gitdir: <path>" or, for
// commondir, the path alone), relative to base.
func gitFileTarget(path, base string) (string, bool) {
	file, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer file.Close()
	if info, err := file.Stat(); err != nil || !info.Mode().IsRegular() {
		return "", false
	}
	data, err := io.ReadAll(io.LimitReader(file, maxGitFileBytes))
	if err != nil {
		return "", false
	}
	text := strings.TrimSpace(string(data))
	if filepath.Base(path) == ".git" {
		var ok bool
		if text, ok = strings.CutPrefix(text, "gitdir:"); !ok {
			return "", false
		}
		text = strings.TrimSpace(text)
	}
	if text == "" || strings.ContainsAny(text, "\n\x00") {
		return "", false
	}
	if !filepath.IsAbs(text) {
		text = filepath.Join(base, text)
	}
	return filepath.Clean(text), true
}

// nodeFolders is what the sandbox opens of Node.js for JavaScript actions:
// the folder of a Node.js installation (nvm's version folder, an unpacked
// download), for npm and npx too, or else the node binary alone, so node in
// ~/bin or ~/.local/bin opens nothing else of those folders.
func nodeFolders(node string) []string {
	real := realPath(node)
	if prefix := filepath.Dir(filepath.Dir(real)); filepath.Base(filepath.Dir(real)) == "bin" && nodeInstallation(prefix) {
		return []string{prefix}
	}
	return []string{real}
}

// nodeInstallation reports a folder that holds a Node.js installation and
// nothing else, as nvm and the downloads from nodejs.org lay one out.
func nodeInstallation(prefix string) bool {
	if info, err := os.Stat(filepath.Join(prefix, "lib", "node_modules")); err != nil || !info.IsDir() {
		return false
	}
	entries, err := os.ReadDir(prefix)
	if err != nil {
		return false
	}
	for _, entry := range entries {
		switch entry.Name() {
		case "bin", "include", "lib", "share", "CHANGELOG.md", "LICENSE", "README.md", ".DS_Store":
		default:
			return false
		}
	}
	return true
}

// sandboxedCache is act's cache folder for a lane in the macOS sandbox: its
// workspace's own, apart from the one runs outside the sandbox and other
// workspaces use, so the actions and tools a job there writes into it reach
// only later runs of the same workspace in the sandbox.
func sandboxedCache(spec *Spec) string {
	if spec.CacheDir == "" {
		return ""
	}
	sum := sha256.Sum256([]byte(realPath(spec.RepositoryPath)))
	return filepath.Join(spec.CacheDir, "sandboxed", hex.EncodeToString(sum[:8]))
}

// The commands a lane under the sandbox finds first on its PATH. Xcode,
// SwiftPM and the Swift compiler (for macros) sandbox what they run with
// sandbox-exec, which cannot start inside a sandbox, so their own sandboxes
// are turned off; the lane's is stricter. A job on this Mac gets no root: `sudo xcode-select -s` selects
// that Xcode for the later steps instead, and any other sudo fails.
var hostShims = map[string]string{
	"xcodebuild": `#!/bin/sh
# Runnir: Xcode's own sandboxes cannot start inside the macOS sandbox this job runs in,
# and Xcode's tests cannot reach Xcode from inside it, so they would hang.
for argument in "$@"; do
    case "$argument" in
    test|test-without-building)
        echo "Runnir: xcodebuild $argument cannot run in the macOS sandbox: the tests cannot reach Xcode from inside it. swift test can." >&2
        exit 1
        ;;
    esac
done
exec /usr/bin/xcodebuild "$@" -IDEPackageSupportDisableManifestSandbox=YES -IDEPackageSupportDisablePluginExecutionSandbox=YES ENABLE_USER_SCRIPT_SANDBOXING=NO SWIFTC_DISABLE_SANDBOX=YES
`,
	"swift": `#!/bin/sh
# Runnir: SwiftPM's own sandbox cannot start inside the macOS sandbox this job runs in.
case "$1" in
build|test|run|package)
    command=$1
    shift
    exec /usr/bin/swift "$command" --disable-sandbox "$@"
    ;;
esac
exec /usr/bin/swift "$@"
`,
	"sudo": `#!/bin/sh
# Runnir: a job on this Mac gets no root.
if [ "$1" = "xcode-select" ] && { [ "$2" = "-s" ] || [ "$2" = "--switch" ]; } && [ -n "$3" ]; then
    dir=$3
    [ -d "$dir/Contents/Developer" ] && dir="$dir/Contents/Developer"
    echo "DEVELOPER_DIR=$dir" >> "$GITHUB_ENV"
    echo "Runnir: the next steps use the Xcode in $dir; xcode-select was not run, a job on this Mac gets no root."
    exit 0
fi
echo "Runnir: a job on this Mac gets no root, so \"sudo $*\" did not run." >&2
exit 1
`,
}

// hostPath is the PATH of a lane under the sandbox: the shims, Node.js for
// JavaScript actions, Homebrew and the system's tools.
func hostPath(shims, node string) string {
	dirs := []string{shims}
	if node != "" {
		dirs = append(dirs, filepath.Dir(node))
	}
	dirs = append(dirs, "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin")
	seen := map[string]bool{}
	var unique []string
	for _, dir := range dirs {
		if !seen[dir] {
			seen[dir] = true
			unique = append(unique, dir)
		}
	}
	return strings.Join(unique, ":")
}

// prepareHost writes a lane's shims and, in the sandbox, its profile into
// its scratch folder and returns the profile's path; cache is the lane's
// act cache folder. Without the sandbox only the sudo shim is written:
// Xcode's and SwiftPM's own sandboxes work.
func prepareHost(spec *Spec, dir, cache string, sandboxed bool) (string, error) {
	shims := filepath.Join(dir, "bin")
	if err := os.Mkdir(shims, 0o700); err != nil {
		return "", err
	}
	for name, script := range hostShims {
		if !sandboxed && name != "sudo" {
			continue
		}
		if err := os.WriteFile(filepath.Join(shims, name), []byte(script), 0o700); err != nil {
			return "", err
		}
	}
	if !sandboxed {
		return "", nil
	}
	home := spec.UserHome
	if home == "" {
		var err error
		if home, err = os.UserHomeDir(); err != nil {
			return "", err
		}
	}
	home = realPath(home)
	repository := realPath(spec.RepositoryPath)
	if opensHome(repository, home) {
		return "", errors.New("the repository is the home folder or holds it, and the macOS sandbox keeps the home folder closed")
	}
	readable := []string{repository, realPath(filepath.Dir(spec.ActPath))}
	readable = append(readable, gitFolders(spec.RepositoryPath)...)
	if spec.HostNode != "" {
		readable = append(readable, nodeFolders(spec.HostNode)...)
	}
	roots := sandboxRoots{Home: home, Writable: []string{realPath(dir), realPath(cache)}}
	for _, path := range readable {
		if !opensHome(path, home) && !slices.Contains(roots.Readable, path) {
			roots.Readable = append(roots.Readable, path)
		}
	}
	// The engine's socket when it is outside the home folder, as Podman's
	// is, and the default one Docker Desktop links there.
	for _, socket := range []string{strings.TrimPrefix(dockerHost(spec.DockerHost), "unix://"), "/var/run/docker.sock"} {
		if filepath.IsAbs(socket) && !slices.Contains(roots.Sockets, realPath(socket)) {
			roots.Sockets = append(roots.Sockets, realPath(socket))
		}
	}
	profile := filepath.Join(dir, "sandbox.sb")
	return profile, os.WriteFile(profile, []byte(sandboxProfile(roots)), 0o600)
}
