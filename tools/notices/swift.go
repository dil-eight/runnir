package main

import (
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

const (
	xcodeProject    = "apps/macos/Runnir.xcodeproj"
	packageResolved = xcodeProject + "/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)

type resolvedFile struct {
	Pins []struct {
		Identity string `json:"identity"`
		Location string `json:"location"`
		State    struct {
			Revision string `json:"revision"`
			Version  string `json:"version"`
		} `json:"state"`
	} `json:"pins"`
}

// resolveSwiftPackages checks out the app's packages at the versions of
// Package.resolved into dir and returns dir/checkouts. xcodebuild reuses what
// an earlier run left in dir.
func resolveSwiftPackages(root, dir string) (string, error) {
	cmd := exec.Command("xcodebuild", "-resolvePackageDependencies",
		"-project", xcodeProject, "-scheme", "Runnir",
		"-onlyUsePackageVersionsFromResolvedFile",
		"-clonedSourcePackagesDirPath", dir)
	cmd.Dir = root
	if out, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("xcodebuild -resolvePackageDependencies: %v\n%s", err, out)
	}
	return filepath.Join(dir, "checkouts"), nil
}

// swiftComponents reads Package.resolved and, for each package, the license
// files at its root and under Sources (libraries a package vendors, such as
// BoringSSL in swift-crypto).
func swiftComponents(root, checkouts string, overrides map[string]override) ([]component, []error) {
	data, err := os.ReadFile(filepath.Join(root, packageResolved))
	if err != nil {
		return nil, []error{err}
	}
	var resolved resolvedFile
	if err := json.Unmarshal(data, &resolved); err != nil {
		return nil, []error{fmt.Errorf("%s: %v", packageResolved, err)}
	}
	var components []component
	var errs []error
	for _, pin := range resolved.Pins {
		repo := strings.TrimSuffix(pin.Location, ".git")
		dir := filepath.Join(checkouts, filepath.Base(repo))
		dirs := []string{dir}
		sources := filepath.Join(dir, "Sources")
		_ = filepath.WalkDir(sources, func(path string, d fs.DirEntry, err error) error {
			if err == nil && d.IsDir() && path != sources {
				if files, _ := licenseFiles(path); len(files) > 0 {
					dirs = append(dirs, path)
				}
			}
			return nil
		})
		sort.Strings(dirs[1:])
		files, err := readLicenseFiles(dir, dirs)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %v (resolve the packages first)", pin.Identity, err))
			continue
		}
		id, err := license(pin.Identity, files, overrides)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		version := pin.State.Version
		if version == "" && len(pin.State.Revision) >= 12 {
			version = pin.State.Revision[:12]
		}
		ref := pin.State.Version
		if ref == "" {
			ref = pin.State.Revision
		}
		components = append(components, component{
			Name:    pin.Identity,
			Version: version,
			License: id,
			Source:  repo + "/tree/" + ref,
			files:   files,
		})
	}
	sort.Slice(components, func(i, j int) bool { return components[i].Name < components[j].Name })
	return components, errs
}
