package localrun

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// SandboxExec runs a command in the macOS sandbox (Seatbelt). A lane with
// jobs on this Mac runs act under it, so the jobs' steps can neither read
// the user's home folder outside the repository nor write outside the run's
// folders, nor reach the Keychain.
var SandboxExec = "/usr/bin/sandbox-exec"

// sandboxRoots are the folders a lane under the sandbox may use.
type sandboxRoots struct {
	// Home is the user's home folder: closed but for the folders below.
	Home string
	// Readable folders inside or outside it: the repository, act, act's
	// cache, Node.js, the engine's socket.
	Readable []string
	// Writable folders: the lane's scratch folder and act's cache.
	Writable []string
}

// sandboxProfile is the Seatbelt profile of a lane with jobs on this Mac.
// Everything is allowed but writes outside the run's folders and the
// system's temporary ones, reads of the home folder outside the readable
// folders, and the Keychain's services.
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
	b.WriteString("(deny mach-lookup\n  (global-name \"com.apple.SecurityServer\")\n  (global-name \"com.apple.securityd.xpc\")\n  (global-name \"com.apple.secd\"))\n")
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

// gitFolders are the repository's git folders outside it: a worktree's
// .git file names its folder in the main repository.
func gitFolders(repository string) []string {
	data, err := os.ReadFile(filepath.Join(repository, ".git"))
	if err != nil {
		return nil
	}
	dir, ok := strings.CutPrefix(strings.TrimSpace(string(data)), "gitdir: ")
	if !ok {
		return nil
	}
	if !filepath.IsAbs(dir) {
		dir = filepath.Join(repository, dir)
	}
	// .../.git/worktrees/<name>: the common folder is two levels up.
	return []string{realPath(dir), realPath(filepath.Dir(filepath.Dir(dir)))}
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
// its scratch folder and returns the profile's path. Without the sandbox
// only the sudo shim is written: Xcode's and SwiftPM's own sandboxes work.
func prepareHost(spec *Spec, dir string, sandboxed bool) (string, error) {
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
	readable := []string{realPath(spec.RepositoryPath), realPath(filepath.Dir(spec.ActPath))}
	readable = append(readable, gitFolders(spec.RepositoryPath)...)
	if spec.HostNode != "" {
		// The Node.js installation: .../bin/node is two levels in.
		readable = append(readable, realPath(filepath.Dir(filepath.Dir(spec.HostNode))))
	}
	if socket, ok := strings.CutPrefix(spec.DockerHost, "unix://"); ok {
		readable = append(readable, realPath(socket))
	}
	writable := []string{realPath(dir)}
	if spec.CacheDir != "" {
		writable = append(writable, realPath(spec.CacheDir))
	}
	profile := filepath.Join(dir, "sandbox.sb")
	content := sandboxProfile(sandboxRoots{Home: home, Readable: readable, Writable: writable})
	return profile, os.WriteFile(profile, []byte(content), 0o600)
}
