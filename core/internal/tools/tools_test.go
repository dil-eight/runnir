package tools

import (
	"context"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type fakeFile struct{ dir bool }

func (f fakeFile) Name() string { return "" }
func (f fakeFile) Size() int64  { return 0 }
func (f fakeFile) Mode() fs.FileMode {
	if f.dir {
		return fs.ModeDir | 0o755
	}
	return 0o755
}
func (f fakeFile) ModTime() time.Time { return time.Time{} }
func (f fakeFile) IsDir() bool        { return f.dir }
func (f fakeFile) Sys() any           { return nil }

// fakeHost answers the detector's file lookups and commands.
type fakeHost struct {
	files    map[string]bool
	commands map[string]string // "docker version" -> stdout
	failing  map[string]bool   // commands that exit non-zero
	calls    atomic.Int32
	envs     [][]string
	mu       sync.Mutex
}

func (h *fakeHost) detector() *Detector {
	d := NewDetector("/Users/me", bundledAct, "")
	d.dirs = []string{"/opt/homebrew/bin", "/usr/local/bin"}
	d.stat = func(path string) (os.FileInfo, error) {
		if h.files[filepath.ToSlash(path)] {
			return fakeFile{}, nil
		}
		return nil, fs.ErrNotExist
	}
	d.exec = func(_ context.Context, path string, args []string, env []string) ([]byte, error) {
		h.calls.Add(1)
		h.mu.Lock()
		h.envs = append(h.envs, env)
		h.mu.Unlock()
		name := strings.TrimSuffix(filepath.Base(path), ".exe")
		if path == bundledAct {
			name = "bundled-act"
		}
		key := name + " " + strings.Join(args, " ")
		var err error
		if h.failing[key] {
			err = errors.New("exit status 1")
		}
		return []byte(h.commands[key]), err
	}
	return d
}

func exe(name string) string {
	if isWindows() {
		return name + ".exe"
	}
	return name
}

var bundledAct = filepath.FromSlash("/App/Contents/Helpers/act")

func readyHost() *fakeHost {
	return &fakeHost{
		files: map[string]bool{"/App/Contents/Helpers/act": true, "/opt/homebrew/bin/" + exe("act"): true, "/usr/local/bin/" + exe("docker"): true},
		commands: map[string]string{
			"bundled-act --version": "act version 0.2.89\n",
			"act --version":         "act version 0.2.89\n",
			"docker --version":      "Docker version 29.0.1, build eedd969\n",
			"docker context inspect": `[{"Name":"orbstack","Metadata":{"Description":"OrbStack"},
				"Endpoints":{"docker":{"Host":"unix:///Users/me/.orbstack/run/docker.sock"}}}]`,
			"docker version --format {{json .}}": `{"Client":{"Version":"29.0.1"},"Server":{"Version":"29.0.1","ApiVersion":"1.52","Arch":"arm64","Platform":{"Name":"OrbStack"}}}`,
			"docker info --format {{json .}}":    `{"OperatingSystem":"OrbStack","Architecture":"aarch64","NCPU":10,"MemTotal":17179869184}`,
		},
	}
}

func TestEverythingFoundIsReady(t *testing.T) {
	host := readyHost()
	report := host.detector().Check(context.Background(), false)
	if !report.Ready(false) || !report.Ready(true) {
		t.Fatalf("not ready: %+v", report)
	}
	if act, source := report.Act(false); source != ActBundled || act.Version != "0.2.89" || act.Path != bundledAct {
		t.Fatalf("default act = %+v %v", act, source)
	}
	if act, source := report.Act(true); source != ActInstalled || act.Path != filepath.FromSlash("/opt/homebrew/bin/"+exe("act")) || act.Untested {
		t.Fatalf("installed act = %+v %v", act, source)
	}
	if report.DockerCLI.Version != "29.0.1" {
		t.Fatalf("docker = %+v", report.DockerCLI)
	}
	e := report.Engine
	if e.Name != "OrbStack" || e.Context != "orbstack" || !e.Local || e.CPUs != 10 || e.MemoryBytes != 17179869184 || e.Architecture != "aarch64" || e.APIVersion != "1.52" {
		t.Fatalf("engine = %+v", e)
	}
}

func TestChildrenGetOnlyHomeAndAShortPath(t *testing.T) {
	t.Setenv("GITHUB_TOKEN", "ghp_secret")
	t.Setenv("DOCKER_HOST", "tcp://elsewhere:2375")
	host := readyHost()
	host.detector().Check(context.Background(), false)
	for _, env := range host.envs {
		joined := strings.Join(env, "\n")
		if strings.Contains(joined, "ghp_secret") || strings.Contains(joined, "DOCKER_HOST") {
			t.Fatalf("environment leaked: %v", env)
		}
		if !strings.Contains(joined, "HOME=/Users/me") {
			t.Fatalf("no HOME: %v", env)
		}
	}
}

func TestMissingToolsAreReportedWithoutRunningAnything(t *testing.T) {
	host := &fakeHost{files: map[string]bool{}}
	report := host.detector().Check(context.Background(), false)
	if report.BundledAct.State != Missing || report.InstalledAct.State != Missing || report.DockerCLI.State != Missing || report.Engine.State != Missing {
		t.Fatalf("report = %+v", report)
	}
	if report.Ready(false) || host.calls.Load() != 0 {
		t.Fatalf("ready=%v calls=%d", report.Ready(false), host.calls.Load())
	}
}

func TestBundledActIsUsedWhenNoActIsInstalled(t *testing.T) {
	host := readyHost()
	delete(host.files, "/opt/homebrew/bin/"+exe("act"))
	report := host.detector().Check(context.Background(), false)
	if report.InstalledAct.State != Missing {
		t.Fatalf("installed = %+v", report.InstalledAct)
	}
	if act, source := report.Act(true); source != ActBundled || act.State != Found || !report.Ready(true) {
		t.Fatalf("opted in without an installed act: %+v %v", act, source)
	}
}

func TestOldInstalledActIsUnsupportedAndNewActIsUntested(t *testing.T) {
	host := readyHost()
	host.commands["act --version"] = "act version 0.2.45"
	report := host.detector().Check(context.Background(), false)
	if report.InstalledAct.State != Unsupported || !strings.Contains(report.InstalledAct.Detail, "0.2.60") {
		t.Fatalf("act = %+v", report.InstalledAct)
	}
	if _, source := report.Act(true); source != ActBundled {
		t.Fatal("an unsupported installed act was chosen")
	}

	host = readyHost()
	host.commands["act --version"] = "act version 0.3.1"
	report = host.detector().Check(context.Background(), false)
	if act, source := report.Act(true); source != ActInstalled || act.State != Found || !act.Untested || !report.Ready(true) {
		t.Fatalf("act = %+v", act)
	}
}

func TestStoppedEngineIsNotReady(t *testing.T) {
	host := readyHost()
	host.commands["docker version --format {{json .}}"] = `{"Client":{"Version":"29.0.1"},"Server":null}`
	host.failing = map[string]bool{"docker version --format {{json .}}": true}
	report := host.detector().Check(context.Background(), false)
	if report.Engine.State != Stopped || report.Engine.Name != "OrbStack" || report.Ready(false) {
		t.Fatalf("engine = %+v", report.Engine)
	}
}

func TestDefaultContextWithoutSocketMeansNoEngine(t *testing.T) {
	host := readyHost()
	host.commands["docker context inspect"] = `[{"Name":"default","Metadata":{},"Endpoints":{"docker":{"Host":"unix:///var/run/docker.sock"}}}]`
	host.commands["docker version --format {{json .}}"] = `{"Client":{"Version":"29.0.1"}}`
	report := host.detector().Check(context.Background(), false)
	if report.Engine.State != Missing || report.Engine.Detail != "No Docker-compatible engine found." {
		t.Fatalf("engine = %+v", report.Engine)
	}
}

func TestRemoteContextIsRefusedWithoutContactingIt(t *testing.T) {
	host := readyHost()
	host.commands["docker context inspect"] = `[{"Name":"build-box","Metadata":{},"Endpoints":{"docker":{"Host":"ssh://me@build.example.com"}}}]`
	report := host.detector().Check(context.Background(), false)
	e := report.Engine
	if e.State != Unsupported || e.Local || report.Ready(false) {
		t.Fatalf("engine = %+v", e)
	}
	if strings.Contains(e.Endpoint, "me@") {
		t.Fatalf("endpoint keeps user info: %q", e.Endpoint)
	}
	if host.calls.Load() != 4 { // two acts, docker --version, context inspect
		t.Fatalf("calls = %d", host.calls.Load())
	}
}

func TestOldEngineAPIIsUnsupported(t *testing.T) {
	host := readyHost()
	host.commands["docker version --format {{json .}}"] = `{"Server":{"Version":"19.03.1","ApiVersion":"1.40"}}`
	report := host.detector().Check(context.Background(), false)
	if report.Engine.State != Unsupported || !strings.Contains(report.Engine.Detail, "1.41") {
		t.Fatalf("engine = %+v", report.Engine)
	}
}

func TestReportIsCachedUntilRefresh(t *testing.T) {
	host := readyHost()
	d := host.detector()
	d.Check(context.Background(), false)
	first := host.calls.Load()
	d.Check(context.Background(), false)
	if host.calls.Load() != first {
		t.Fatal("cached check ran commands")
	}
	d.Check(context.Background(), true)
	if host.calls.Load() != 2*first {
		t.Fatalf("refresh ran %d commands, want %d", host.calls.Load()-first, first)
	}
}

func TestRefreshRunsAgainOnACoarseClock(t *testing.T) {
	// Windows' clock can give the check before a refresh and the refresh
	// itself the same time; the refresh must still run the checks.
	host := readyHost()
	d := host.detector()
	frozen := time.Date(2026, 10, 21, 9, 0, 0, 0, time.UTC)
	d.now = func() time.Time { return frozen }
	d.Check(context.Background(), false)
	first := host.calls.Load()
	d.Check(context.Background(), true)
	if host.calls.Load() != 2*first {
		t.Fatalf("refresh ran %d commands, want %d", host.calls.Load()-first, first)
	}
	d.Check(context.Background(), false)
	if host.calls.Load() != 2*first {
		t.Fatal("cached check ran commands")
	}
}

func TestConcurrentChecksShareOneRun(t *testing.T) {
	host := readyHost()
	d := host.detector()
	release := make(chan struct{})
	inner := d.exec
	d.exec = func(ctx context.Context, path string, args []string, env []string) ([]byte, error) {
		<-release
		return inner(ctx, path, args, env)
	}
	var wg sync.WaitGroup
	for i := 0; i < 5; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); d.Check(context.Background(), true) }()
	}
	time.Sleep(50 * time.Millisecond)
	close(release)
	wg.Wait()
	if calls := host.calls.Load(); calls > 2*6 {
		t.Fatalf("calls = %d, want at most two runs of 6", calls)
	}
}

func TestEndpoints(t *testing.T) {
	for raw, local := range map[string]bool{
		"unix:///var/run/docker.sock":    true,
		"npipe:////./pipe/docker_engine": true,
		"tcp://127.0.0.1:2375":           true,
		"tcp://localhost:2375":           true,
		"tcp://192.168.1.10:2375":        false,
		"ssh://user@host":                false,
		"":                               true,
	} {
		if _, got := describeEndpoint(raw); got != local {
			t.Errorf("%q local = %v, want %v", raw, got, local)
		}
	}
}

func TestEngineNames(t *testing.T) {
	for _, c := range []struct{ context, endpoint, os, want string }{
		{"orbstack", "unix:///Users/me/.orbstack/run/docker.sock", "", "OrbStack"},
		{"desktop-linux", "unix:///Users/me/.docker/run/docker.sock", "", "Docker Desktop"},
		{"colima", "unix:///Users/me/.colima/default/docker.sock", "Ubuntu 24.04", "Colima"},
		{"rancher-desktop", "unix:///Users/me/.rd/docker.sock", "", "Rancher Desktop"},
		{"default", "unix:///var/run/docker.sock", "Docker Desktop", "Docker Desktop"},
		{"default", "unix:///var/run/docker.sock", "Ubuntu", "Docker Engine"},
	} {
		if got := engineName(c.context, "", c.endpoint, c.os); got != c.want {
			t.Errorf("%s: %q, want %q", c.context, got, c.want)
		}
	}
}

func TestParseVersion(t *testing.T) {
	for text, want := range map[string]Version{
		"act version 0.2.89":                   {0, 2, 89},
		"Docker version 27.3.1, build ce12230": {27, 3, 1},
		"1.41":                                 {1, 41, 0},
	} {
		if got, ok := ParseVersion(text); !ok || got != want {
			t.Errorf("%q = %v %v", text, got, ok)
		}
	}
	if _, ok := ParseVersion("unknown"); ok {
		t.Error("parsed a version from no digits")
	}
}

func TestSearchDirsAreAbsoluteAndUnique(t *testing.T) {
	dirs := SearchDirs("/Users/me", strings.Join([]string{"relative/bin", "/usr/local/bin", "/usr/local/bin"}, string(os.PathListSeparator)))
	seen := map[string]bool{}
	for _, dir := range dirs {
		if !filepath.IsAbs(dir) || seen[dir] {
			t.Fatalf("bad dirs %v", dirs)
		}
		seen[dir] = true
	}
}

// A refresh does not settle for a check that was already running when it
// was asked for: the user may just have started the engine.
func TestRefreshDuringARunningCheckChecksAgain(t *testing.T) {
	host := readyHost()
	d := host.detector()
	started := make(chan struct{})
	release := make(chan struct{})
	inner := d.exec
	var once sync.Once
	d.exec = func(ctx context.Context, path string, args []string, env []string) ([]byte, error) {
		once.Do(func() { close(started); <-release })
		return inner(ctx, path, args, env)
	}
	first := make(chan Report, 1)
	go func() { first <- d.Check(context.Background(), true) }()
	<-started
	time.Sleep(10 * time.Millisecond)
	second := make(chan Report, 1)
	go func() { second <- d.Check(context.Background(), true) }()
	time.Sleep(10 * time.Millisecond)
	close(release)
	a, b := <-first, <-second
	if !b.CheckedAt.After(a.CheckedAt) {
		t.Fatalf("the refresh reused a check that started before it: %v vs %v", a.CheckedAt, b.CheckedAt)
	}
}

func TestAnEngineCheckThatRunsOutOfTimeIsAFailedCheck(t *testing.T) {
	host := readyHost()
	d := host.detector()
	inner := d.exec
	ctx, cancel := context.WithCancel(context.Background())
	d.exec = func(c context.Context, path string, args []string, env []string) ([]byte, error) {
		if len(args) > 0 && args[0] == "version" {
			cancel()
			return []byte(`{"Client":{}}`), errors.New("killed")
		}
		return inner(c, path, args, env)
	}
	report := d.Check(ctx, true)
	if report.Engine.State != Failed {
		t.Fatalf("engine = %+v", report.Engine)
	}
}
