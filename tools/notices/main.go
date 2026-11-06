// Command notices collects the licenses of the third-party code Runnir
// ships and writes them as committed files (spec B49):
//
//	licenses/notices.json                the app's Settings › About
//	licenses/Runnir-LICENSE.txt          View License in the app
//	core/internal/licenses/LICENSE       `runnir licenses`
//	core/internal/licenses/NOTICES.txt   `runnir licenses`, the release asset
//
// Run it from the repository root, as scripts/update-notices.sh does. -check
// writes nothing and fails when a file would change.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

type override struct {
	License string `json:"license"`
	Reason  string `json:"reason"`
}

const overridesFile = "tools/notices/overrides.json"

func main() {
	root := flag.String("root", ".", "repository root")
	check := flag.Bool("check", false, "write nothing; fail when a generated file would change")
	packages := flag.String("swift-packages", "", "checkouts of the app's Swift packages (default: resolve them with xcodebuild into build/notices/SourcePackages)")
	flag.Parse()
	if err := run(*root, *check, *packages); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(root string, check bool, checkouts string) error {
	root, err := filepath.Abs(root)
	if err != nil {
		return err
	}
	overrides, err := readOverrides(filepath.Join(root, overridesFile))
	if err != nil {
		return err
	}
	if checkouts == "" {
		if checkouts, err = resolveSwiftPackages(root, filepath.Join(root, "build/notices/SourcePackages")); err != nil {
			return err
		}
	} else if checkouts, err = filepath.Abs(checkouts); err != nil {
		return err
	}
	groups, err := collect(root, checkouts, overrides)
	if err != nil {
		return err
	}
	files, err := outputs(root, build(groups))
	if err != nil {
		return err
	}
	var changed []string
	for _, name := range sortedKeys(keysOf(files)) {
		path := filepath.Join(root, name)
		old, err := os.ReadFile(path)
		if err == nil && bytes.Equal(old, files[name]) {
			continue
		}
		if check {
			changed = append(changed, name)
			continue
		}
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(path, files[name], 0o644); err != nil {
			return err
		}
	}
	if len(changed) > 0 {
		return fmt.Errorf("license notices are out of date: %v; run %s and commit the result", changed, generatedBy)
	}
	return nil
}

// collect gathers the three groups; it reports every problem at once.
func collect(root, checkouts string, overrides map[string]override) ([]group, error) {
	var errs []error
	goVer, err := goVersion(filepath.Join(root, "core/go.mod"))
	if err != nil {
		return nil, err
	}
	golang, err := goItself(goVer)
	if err != nil {
		return nil, err
	}
	app, e := swiftComponents(root, checkouts, overrides)
	errs = append(errs, e...)
	coreModules, err := linkedModules(filepath.Join(root, "core"), "./cmd/runnir", coreTargets)
	if err != nil {
		return nil, err
	}
	core, e := goComponents(coreModules, overrides)
	errs = append(errs, e...)
	actModules, err := linkedModules(filepath.Join(root, "third_party/act"), "github.com/nektos/act", actTargets)
	if err != nil {
		return nil, err
	}
	act, e := goComponents(actModules, overrides)
	errs = append(errs, e...)
	if len(errs) > 0 {
		return nil, errors.Join(errs...)
	}
	return []group{
		{Name: "Runnir.app", Components: app},
		{Name: "Runnir Core", Components: append([]component{golang}, core...)},
		{Name: "act", Components: append([]component{golang}, act...)},
	}, nil
}

func outputs(root string, c catalog) (map[string][]byte, error) {
	license, err := os.ReadFile(filepath.Join(root, "LICENSE"))
	if err != nil {
		return nil, err
	}
	notices, err := renderJSON(c)
	if err != nil {
		return nil, err
	}
	core, err := renderText(c, "Runnir Core", "Runnir Core")
	if err != nil {
		return nil, err
	}
	return map[string][]byte{
		"licenses/notices.json":              notices,
		"licenses/Runnir-LICENSE.txt":        license,
		"core/internal/licenses/LICENSE":     license,
		"core/internal/licenses/NOTICES.txt": core,
	}, nil
}

func readOverrides(path string) (map[string]override, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var file struct {
		Components map[string]override `json:"components"`
	}
	if err := json.Unmarshal(data, &file); err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	return file.Components, nil
}

func keysOf(m map[string][]byte) map[string]bool {
	keys := map[string]bool{}
	for k := range m {
		keys[k] = true
	}
	return keys
}
