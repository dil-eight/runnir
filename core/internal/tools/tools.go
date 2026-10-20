// Package tools finds the programs local runs need: act, the Docker CLI and a
// Docker-compatible container engine. It only looks: it never installs a
// tool, starts an engine or switches the Docker context.
package tools

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Version policy. Runnir drives act through its command line and its JSON
// log format, which are not a stable API, so the app bundles the act version
// local runs were verified with and uses it by default. An installed act is
// an experimental opt-in: it must be at least MinActVersion, and newer
// versions are labelled untested. Docker is used through long-stable CLI
// commands; act negotiates the engine API itself, so the engine only needs
// API 1.41 (Docker 20.10).
var (
	MinActVersion    = Version{0, 2, 60}
	TestedActVersion = Version{0, 2, 89}
	MinEngineAPI     = Version{1, 41, 0}
)

const (
	versionTimeout = 5 * time.Second
	engineTimeout  = 8 * time.Second
	maxOutputBytes = 1 << 20
)

type State int

const (
	StateUnknown State = iota
	// Found: present, answering and new enough.
	Found
	// Missing: not installed, or no engine is configured.
	Missing
	// Stopped: an engine is configured but does not answer.
	Stopped
	// Unsupported: too old, or an engine that is not on this computer.
	Unsupported
	// Failed: the check itself could not finish.
	Failed
)

type Tool struct {
	State   State
	Version string
	// Path is the executable that was checked and that runs use.
	Path   string
	Detail string
	// Untested: newer than the version local runs were verified with.
	Untested bool
}

type Engine struct {
	State State
	// Name is the product behind the endpoint: OrbStack, Docker Desktop,
	// Colima, Rancher Desktop, Podman or Docker Engine.
	Name    string
	Context string
	// Endpoint is the Docker host of the context, without user information.
	Endpoint     string
	Local        bool
	Version      string
	APIVersion   string
	Architecture string
	CPUs         int
	MemoryBytes  uint64
	Detail       string
}

type Report struct {
	// BundledAct ships inside Runnir; InstalledAct is one found on this
	// computer, used only when the user opts in.
	BundledAct   Tool
	InstalledAct Tool
	DockerCLI    Tool
	Engine       Engine
	CheckedAt    time.Time
}

type ActSource int

const (
	ActBundled ActSource = iota + 1
	ActInstalled
)

// Act returns the act a run uses: the installed one when the user opted in
// and it is usable, the bundled one otherwise.
func (r Report) Act(useInstalled bool) (Tool, ActSource) {
	if useInstalled && r.InstalledAct.State == Found {
		return r.InstalledAct, ActInstalled
	}
	return r.BundledAct, ActBundled
}

// Ready reports whether a local run can start.
func (r Report) Ready(useInstalled bool) bool {
	act, _ := r.Act(useInstalled)
	return act.State == Found && r.DockerCLI.State == Found && r.Engine.State == Found && r.Engine.Local
}

// Exec runs a program with exactly the given environment and returns its
// standard output. It must stop when ctx ends.
type Exec func(ctx context.Context, path string, args []string, env []string) ([]byte, error)

// Detector caches the last report; Check with refresh runs the checks again.
// Safe for concurrent use; concurrent checks share one run.
type Detector struct {
	home       string
	bundledAct string
	dirs       []string
	exec       Exec
	stat       func(string) (os.FileInfo, error)
	now        func() time.Time

	mu      sync.Mutex
	last    *Report
	pending chan struct{}
}

// NewDetector checks the act bundled at bundledAct (empty when the build has
// none) and looks for installed tools in pathEnv first, then the usual
// install locations on macOS, because an app opened from the Finder does not
// get the shell's PATH.
func NewDetector(home, bundledAct, pathEnv string) *Detector {
	return &Detector{home: home, bundledAct: bundledAct, dirs: SearchDirs(home, pathEnv), exec: runProgram, stat: os.Stat, now: time.Now}
}

// SearchDirs lists the directories searched for act and docker, in order.
func SearchDirs(home, pathEnv string) []string {
	candidates := filepath.SplitList(pathEnv)
	candidates = append(candidates,
		"/opt/homebrew/bin",
		"/usr/local/bin",
		filepath.Join(home, ".orbstack", "bin"),
		"/Applications/OrbStack.app/Contents/MacOS/xbin",
		"/Applications/Docker.app/Contents/Resources/bin",
		filepath.Join(home, ".docker", "bin"),
		filepath.Join(home, ".rd", "bin"),
		"/opt/local/bin",
		filepath.Join(home, ".local", "bin"),
		filepath.Join(home, "go", "bin"),
		filepath.Join(home, "bin"),
		"/usr/bin",
		"/bin",
	)
	seen := map[string]bool{}
	var dirs []string
	for _, dir := range candidates {
		if !filepath.IsAbs(dir) {
			continue
		}
		dir = filepath.Clean(dir)
		if !seen[dir] {
			seen[dir] = true
			dirs = append(dirs, dir)
		}
	}
	return dirs
}

// Check returns the cached report, or a new one when there is none or
// refresh is set.
func (d *Detector) Check(ctx context.Context, refresh bool) Report {
	requested := d.now()
	for {
		d.mu.Lock()
		// A refresh takes a report from a check that started after it was
		// asked for; one that was already running may predate the change
		// the user is checking for.
		if d.last != nil && (!refresh || !d.last.CheckedAt.Before(requested)) {
			report := *d.last
			d.mu.Unlock()
			return report
		}
		if wait := d.pending; wait != nil {
			d.mu.Unlock()
			select {
			case <-wait:
				continue
			case <-ctx.Done():
				return Report{BundledAct: failed(ctx.Err()), InstalledAct: failed(ctx.Err()), DockerCLI: failed(ctx.Err()),
					Engine: Engine{State: Failed, Detail: ctx.Err().Error()}, CheckedAt: d.now()}
			}
		}
		done := make(chan struct{})
		d.pending = done
		d.mu.Unlock()

		report := d.check(ctx)

		d.mu.Lock()
		if ctx.Err() == nil {
			d.last = &report
		}
		d.pending = nil
		close(done)
		d.mu.Unlock()
		return report
	}
}

func failed(err error) Tool { return Tool{State: Failed, Detail: err.Error()} }

// Env is the environment for docker and act: the user's home, so the Docker
// CLI finds its contexts and credential helpers, and a short PATH. Nothing
// else from the Core's environment is passed on.
func (d *Detector) Env(dockerPath string) []string {
	path := []string{"/usr/bin", "/bin", "/usr/sbin", "/sbin"}
	if dockerPath != "" {
		path = append([]string{filepath.Dir(dockerPath)}, path...)
	}
	// act otherwise asks api.nektosact.com for notices on every start,
	// sending its version, OS and architecture.
	env := []string{"HOME=" + d.home, "PATH=" + strings.Join(path, string(os.PathListSeparator)), "LANG=C", "ACT_DISABLE_VERSION_CHECK=1"}
	if tmp := os.Getenv("TMPDIR"); tmp != "" {
		env = append(env, "TMPDIR="+tmp)
	}
	if runtime.GOOS == "windows" {
		for _, name := range []string{"SystemRoot", "USERPROFILE", "TEMP", "TMP"} {
			if value := os.Getenv(name); value != "" {
				env = append(env, name+"="+value)
			}
		}
	}
	return env
}

func (d *Detector) check(ctx context.Context) Report {
	report := Report{CheckedAt: d.now()}
	report.BundledAct = d.checkBundledAct(ctx)
	report.InstalledAct = d.checkInstalledAct(ctx)
	report.DockerCLI = d.checkDockerCLI(ctx)
	if report.DockerCLI.State != Found {
		report.Engine = Engine{State: Missing, Detail: "The Docker CLI is needed to reach a container engine."}
		return report
	}
	report.Engine = d.checkEngine(ctx, report.DockerCLI.Path)
	return report
}

func (d *Detector) find(name string) string {
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	for _, dir := range d.dirs {
		candidate := filepath.Join(dir, name)
		info, err := d.stat(candidate)
		if err != nil || info.IsDir() {
			continue
		}
		if runtime.GOOS != "windows" && info.Mode()&0o111 == 0 {
			continue
		}
		return candidate
	}
	return ""
}

func (d *Detector) run(ctx context.Context, timeout time.Duration, path string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return d.exec(ctx, path, args, d.Env(path))
}

func (d *Detector) checkBundledAct(ctx context.Context) Tool {
	if d.bundledAct == "" {
		return Tool{State: Missing, Detail: "This build of Runnir has no bundled act."}
	}
	if info, err := d.stat(d.bundledAct); err != nil || info.IsDir() {
		return Tool{State: Missing, Path: d.bundledAct, Detail: "The act bundled with Runnir is missing. Reinstall Runnir."}
	}
	tool, _ := d.actVersion(ctx, d.bundledAct)
	return tool
}

func (d *Detector) checkInstalledAct(ctx context.Context) Tool {
	path := d.find("act")
	if path == "" {
		return Tool{State: Missing, Detail: "No act is installed on this Mac."}
	}
	tool, version := d.actVersion(ctx, path)
	if tool.State != Found {
		return tool
	}
	switch {
	case version.Less(MinActVersion):
		tool.State = Unsupported
		tool.Detail = fmt.Sprintf("act %s is older than %s, the oldest version Runnir runs. Update act.", version, MinActVersion)
	case TestedActVersion.Less(version):
		tool.Untested = true
		tool.Detail = fmt.Sprintf("Newer than %s, the version local runs were verified with.", TestedActVersion)
	}
	return tool
}

func (d *Detector) actVersion(ctx context.Context, path string) (Tool, Version) {
	out, err := d.run(ctx, versionTimeout, path, "--version")
	if err != nil {
		return Tool{State: Failed, Path: path, Detail: "act did not report its version."}, Version{}
	}
	version, ok := ParseVersion(string(out))
	if !ok {
		return Tool{State: Failed, Path: path, Detail: "act reported a version Runnir cannot read."}, Version{}
	}
	return Tool{State: Found, Version: version.String(), Path: path}, version
}

func (d *Detector) checkDockerCLI(ctx context.Context) Tool {
	path := d.find("docker")
	if path == "" {
		return Tool{State: Missing, Detail: "The Docker CLI was not found. It comes with OrbStack, Docker Desktop or Colima."}
	}
	out, err := d.run(ctx, versionTimeout, path, "--version")
	if err != nil {
		return Tool{State: Failed, Path: path, Detail: "The Docker CLI did not report its version."}
	}
	version, ok := ParseVersion(string(out))
	if !ok {
		return Tool{State: Failed, Path: path, Detail: "The Docker CLI reported a version Runnir cannot read."}
	}
	return Tool{State: Found, Version: version.String(), Path: path}
}

type contextInfo struct {
	Name     string `json:"Name"`
	Metadata struct {
		Description string `json:"Description"`
	} `json:"Metadata"`
	Endpoints struct {
		Docker struct {
			Host string `json:"Host"`
		} `json:"docker"`
	} `json:"Endpoints"`
}

type versionInfo struct {
	Server *struct {
		Version    string `json:"Version"`
		APIVersion string `json:"ApiVersion"`
		Arch       string `json:"Arch"`
		Platform   struct {
			Name string `json:"Name"`
		} `json:"Platform"`
	} `json:"Server"`
}

type engineInfo struct {
	OperatingSystem string `json:"OperatingSystem"`
	Architecture    string `json:"Architecture"`
	NCPU            int    `json:"NCPU"`
	MemTotal        uint64 `json:"MemTotal"`
}

func (d *Detector) checkEngine(ctx context.Context, docker string) Engine {
	out, err := d.run(ctx, versionTimeout, docker, "context", "inspect")
	var contexts []contextInfo
	if err != nil || json.Unmarshal(out, &contexts) != nil || len(contexts) == 0 {
		return Engine{State: Failed, Detail: "The Docker CLI did not describe its current context."}
	}
	current := contexts[0]
	engine := Engine{Context: current.Name}
	endpoint := current.Endpoints.Docker.Host
	engine.Endpoint, engine.Local = describeEndpoint(endpoint)
	engine.Name = engineName(current.Name, current.Metadata.Description, endpoint, "")
	if !engine.Local {
		engine.State = Unsupported
		engine.Detail = fmt.Sprintf("Context %s points at an engine on another computer. Local runs need an engine on this Mac; Runnir does not switch your context.", current.Name)
		return engine
	}

	out, err = d.run(ctx, engineTimeout, docker, "version", "--format", "{{json .}}")
	var version versionInfo
	// docker version exits non-zero when the engine does not answer but
	// still prints the client part, so the output decides.
	_ = json.Unmarshal(bytes.TrimSpace(out), &version)
	if version.Server == nil {
		if ctx.Err() != nil {
			engine.State = Failed
			engine.Detail = "The check was cancelled or took too long."
			return engine
		}
		if socket := unixSocketPath(endpoint); socket != "" && engine.Name == "Docker Engine" {
			if _, statErr := d.stat(socket); statErr != nil {
				engine.State = Missing
				engine.Detail = "No Docker-compatible engine found."
				return engine
			}
		}
		engine.State = Stopped
		engine.Detail = fmt.Sprintf("%s is not running or does not answer.", engine.Name)
		return engine
	}
	engine.Version = version.Server.Version
	engine.APIVersion = version.Server.APIVersion
	engine.Architecture = version.Server.Arch

	out, err = d.run(ctx, engineTimeout, docker, "info", "--format", "{{json .}}")
	var info engineInfo
	if err == nil && json.Unmarshal(bytes.TrimSpace(out), &info) == nil {
		engine.CPUs = info.NCPU
		engine.MemoryBytes = info.MemTotal
		if info.Architecture != "" {
			engine.Architecture = info.Architecture
		}
		engine.Name = engineName(current.Name, current.Metadata.Description, endpoint, info.OperatingSystem)
	}

	api, ok := ParseVersion(engine.APIVersion)
	if !ok || api.Less(MinEngineAPI) {
		engine.State = Unsupported
		engine.Detail = fmt.Sprintf("The engine's API version %s is older than %s.", engine.APIVersion, MinEngineAPI.Short())
		return engine
	}
	engine.State = Found
	return engine
}

var imageReference = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/:@-]{0,254}$`)

// ImagePresent reports whether the engine at dockerHost already has the
// image, so a plan can say what act will download. Any error means "no".
func (d *Detector) ImagePresent(ctx context.Context, dockerPath, dockerHost, reference string) bool {
	if dockerPath == "" || !imageReference.MatchString(reference) {
		return false
	}
	ctx, cancel := context.WithTimeout(ctx, versionTimeout)
	defer cancel()
	env := d.Env(dockerPath)
	if dockerHost != "" {
		env = append(env, "DOCKER_HOST="+dockerHost)
	}
	_, err := d.exec(ctx, dockerPath, []string{"image", "inspect", "--format", "{{.Id}}", "--", reference}, env)
	return err == nil
}

// describeEndpoint returns a displayable endpoint and whether it is on this
// computer: a Unix socket, a named pipe or a loopback TCP address.
func describeEndpoint(raw string) (string, bool) {
	if raw == "" {
		return "", true // the CLI's built-in default socket
	}
	u, err := url.Parse(raw)
	if err != nil {
		return "", false
	}
	u.User = nil
	shown := u.String()
	switch u.Scheme {
	case "unix", "npipe":
		return shown, true
	case "tcp", "http", "https":
		host := u.Hostname()
		if host == "localhost" {
			return shown, true
		}
		ip := net.ParseIP(host)
		return shown, ip != nil && ip.IsLoopback()
	default: // ssh and anything unknown
		return shown, false
	}
}

func unixSocketPath(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "unix" {
		return ""
	}
	return u.Path
}

func engineName(contextName, description, endpoint, operatingSystem string) string {
	lower := strings.ToLower(contextName + " " + description + " " + endpoint)
	switch {
	case strings.Contains(lower, "orbstack"):
		return "OrbStack"
	case strings.Contains(lower, "colima"):
		return "Colima"
	case strings.Contains(lower, "/.rd/") || strings.Contains(lower, "rancher"):
		return "Rancher Desktop"
	case strings.Contains(lower, "podman"):
		return "Podman"
	case strings.Contains(lower, "desktop-linux") || strings.Contains(lower, "docker desktop") || strings.Contains(lower, "/.docker/run/docker.sock"):
		return "Docker Desktop"
	}
	switch operatingSystem {
	case "OrbStack", "Docker Desktop":
		return operatingSystem
	}
	return "Docker Engine"
}

// Version is a major.minor.patch version.
type Version [3]int

var versionPattern = regexp.MustCompile(`(\d+)\.(\d+)(?:\.(\d+))?`)

// ParseVersion reads the first version number in text, such as
// "act version 0.2.89" or "Docker version 27.3.1, build ce12230".
func ParseVersion(text string) (Version, bool) {
	match := versionPattern.FindStringSubmatch(text)
	if match == nil {
		return Version{}, false
	}
	var v Version
	for i := 0; i < 3; i++ {
		if match[i+1] == "" {
			continue
		}
		n, err := strconv.Atoi(match[i+1])
		if err != nil {
			return Version{}, false
		}
		v[i] = n
	}
	return v, true
}

func (v Version) Less(other Version) bool {
	for i := range v {
		if v[i] != other[i] {
			return v[i] < other[i]
		}
	}
	return false
}

func (v Version) String() string { return fmt.Sprintf("%d.%d.%d", v[0], v[1], v[2]) }
func (v Version) Short() string  { return fmt.Sprintf("%d.%d", v[0], v[1]) }

func runProgram(ctx context.Context, path string, args []string, env []string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, path, args...)
	cmd.Env = env
	cmd.Dir = os.TempDir()
	var stdout limitedBuffer
	cmd.Stdout = &stdout
	cmd.Stderr = nil
	cmd.WaitDelay = time.Second
	err := cmd.Run()
	return stdout.Bytes(), err
}

// limitedBuffer keeps the first maxOutputBytes written to it.
type limitedBuffer struct{ bytes.Buffer }

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if room := maxOutputBytes - b.Len(); room > 0 {
		if len(p) > room {
			b.Buffer.Write(p[:room])
		} else {
			b.Buffer.Write(p)
		}
	}
	return len(p), nil
}
