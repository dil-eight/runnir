package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"unicode"
)

type target struct{ goos, goarch string }

// coreTargets are the platforms the release builds the Core for; actTargets
// those the app builds act for.
var (
	coreTargets = []target{
		{"darwin", "arm64"}, {"darwin", "amd64"},
		{"linux", "arm64"}, {"linux", "amd64"},
		{"windows", "arm64"}, {"windows", "amd64"},
	}
	actTargets = []target{{"darwin", "arm64"}, {"darwin", "amd64"}}
)

type goModule struct {
	Path    string
	Version string
	Dir     string
	Main    bool
	Replace *goModule
}

type goPackage struct {
	ImportPath string
	Dir        string
	Standard   bool
	Module     *goModule
}

// linkedModules returns, by module path, the modules whose packages `go
// list -deps` links into pkg for each target, with the directories of those
// packages.
func linkedModules(dir, pkg string, targets []target) (map[string]*linked, error) {
	modules := map[string]*linked{}
	for _, t := range targets {
		cmd := exec.Command("go", "list", "-deps", "-json=ImportPath,Dir,Standard,Module", pkg)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(), "GOOS="+t.goos, "GOARCH="+t.goarch, "CGO_ENABLED=0", "GOFLAGS=")
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		out, err := cmd.Output()
		if err != nil {
			return nil, fmt.Errorf("go list in %s for %s/%s: %v: %s", dir, t.goos, t.goarch, err, strings.TrimSpace(stderr.String()))
		}
		decoder := json.NewDecoder(bytes.NewReader(out))
		for {
			var p goPackage
			if err := decoder.Decode(&p); errors.Is(err, io.EOF) {
				break
			} else if err != nil {
				return nil, err
			}
			if p.Standard || p.Module == nil || p.Module.Main {
				continue
			}
			m := *p.Module
			if m.Replace != nil {
				if m.Replace.Version == "" {
					return nil, fmt.Errorf("%s is replaced by a local directory, which has no published source", m.Path)
				}
				m = goModule{Path: m.Replace.Path, Version: m.Replace.Version, Dir: m.Replace.Dir}
			}
			l := modules[m.Path]
			if l == nil {
				l = &linked{module: m, packages: map[string]bool{}}
				modules[m.Path] = l
			}
			l.packages[p.Dir] = true
		}
	}
	return modules, nil
}

type linked struct {
	module   goModule
	packages map[string]bool // directories of the linked packages
}

// goComponents turns linked modules into components: the license files at
// each module's root and in the directories between a linked package and the
// root (a vendored library with its own license).
func goComponents(modules map[string]*linked, overrides map[string]override) ([]component, []error) {
	var components []component
	var errs []error
	paths := make([]string, 0, len(modules))
	for path := range modules {
		paths = append(paths, path)
	}
	sort.Strings(paths)
	for _, path := range paths {
		l := modules[path]
		dirs := map[string]bool{l.module.Dir: true}
		for dir := range l.packages {
			for d := dir; strings.HasPrefix(d, l.module.Dir) && d != l.module.Dir; d = filepath.Dir(d) {
				dirs[d] = true
			}
		}
		files, err := readLicenseFiles(l.module.Dir, sortedKeys(dirs))
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %v", path, err))
			continue
		}
		id, err := license(path, files, overrides)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		components = append(components, component{
			Name:    path,
			Version: l.module.Version,
			License: id,
			Source:  "https://proxy.golang.org/" + escapeModule(path) + "/@v/" + escapeModule(l.module.Version) + ".zip",
			files:   files,
		})
	}
	return components, errs
}

// goItself is Go's runtime and standard library, linked into every Go
// program, under the toolchain's own license.
func goItself(version string) (component, error) {
	out, err := exec.Command("go", "env", "GOROOT").Output()
	if err != nil {
		return component{}, fmt.Errorf("go env GOROOT: %v", err)
	}
	goroot := strings.TrimSpace(string(out))
	// Homebrew keeps the license next to GOROOT (libexec) instead of in it.
	path := filepath.Join(goroot, "LICENSE")
	text, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		path = filepath.Join(filepath.Dir(goroot), "LICENSE")
		text, err = os.ReadFile(path)
	}
	if err != nil {
		return component{}, fmt.Errorf("Go's license: %v", err)
	}
	files := []file{{path: path, text: string(text)}}
	id, err := license("Go", files, nil)
	if err != nil {
		return component{}, err
	}
	return component{Name: "Go", Version: version, License: id, Source: "https://go.dev/dl/", files: files}, nil
}

// goVersion reads the go directive of a go.mod: the toolchain the release
// builds with (CI's setup-go reads the same file), so the notices do not
// depend on the Go of whoever generates them.
func goVersion(goMod string) (string, error) {
	data, err := os.ReadFile(goMod)
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(data), "\n") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(line), "go "); ok {
			return strings.TrimSpace(v), nil
		}
	}
	return "", fmt.Errorf("%s has no go directive", goMod)
}

// escapeModule escapes a module path or version for the module proxy: each
// upper case letter becomes "!" and the letter in lower case.
func escapeModule(s string) string {
	var b strings.Builder
	for _, r := range s {
		if unicode.IsUpper(r) {
			b.WriteByte('!')
			b.WriteRune(unicode.ToLower(r))
		} else {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// readLicenseFiles reads the license and notice files of dirs; root is shown
// in messages relative to nothing, the rest relative to root.
func readLicenseFiles(root string, dirs []string) ([]file, error) {
	var files []file
	for _, dir := range dirs {
		paths, err := licenseFiles(dir)
		if err != nil {
			return nil, err
		}
		for _, path := range paths {
			text, err := os.ReadFile(path)
			if err != nil {
				return nil, err
			}
			rel, _ := filepath.Rel(root, path)
			files = append(files, file{path: filepath.ToSlash(rel), text: string(text), notice: isNotice(filepath.Base(path))})
		}
	}
	return files, nil
}

func sortedKeys(m map[string]bool) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}
