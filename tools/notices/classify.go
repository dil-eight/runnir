package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// allowed are the licenses Runnir may ship (spec B49). Anything else, or a
// text none of the rules below recognises, fails the generator.
var allowed = map[string]bool{
	"Apache-2.0":   true,
	"MIT":          true,
	"BSD-2-Clause": true,
	"BSD-3-Clause": true,
	"ISC":          true,
	"Zlib":         true,
	"MPL-2.0":      true,
	// SQLite's dedication, for the C code modernc.org/sqlite is made from.
	"LicenseRef-Public-Domain": true,
}

var spaces = regexp.MustCompile(`[\s*#>]+`)

// normalise lowers the text and collapses white space and the comment and
// Markdown marks some license files are written with.
func normalise(text string) string {
	return strings.TrimSpace(spaces.ReplaceAllString(strings.ToLower(text), " "))
}

// classify returns the SPDX ids of the licenses a text grants, sorted. A file
// that holds two licenses (yaml's MIT and Apache-2.0) returns both.
func classify(text string) []string {
	t := normalise(text)
	var ids []string
	if strings.Contains(t, "apache license") && strings.Contains(t, "2.0") {
		ids = append(ids, "Apache-2.0")
	}
	if strings.Contains(t, "mozilla public license") && strings.Contains(t, "2.0") {
		ids = append(ids, "MPL-2.0")
	}
	if strings.Contains(t, "permission is hereby granted, free of charge") {
		ids = append(ids, "MIT")
	}
	if strings.Contains(t, "permission to use, copy, modify, and/or distribute this software for any purpose") ||
		strings.Contains(t, "permission to use, copy, modify, and distribute this software for any purpose") {
		ids = append(ids, "ISC")
	}
	if strings.Contains(t, "altered source versions must be plainly marked") {
		ids = append(ids, "Zlib")
	}
	if strings.Contains(t, "dedicated to the public domain") {
		ids = append(ids, "LicenseRef-Public-Domain")
	}
	if strings.Contains(t, "redistribution and use in source and binary forms") {
		if strings.Contains(t, "neither the name") || strings.Contains(t, "endorse or promote products") {
			ids = append(ids, "BSD-3-Clause")
		} else {
			ids = append(ids, "BSD-2-Clause")
		}
	}
	sort.Strings(ids)
	return ids
}

// copyleft names a license the text grants that Runnir must not ship, for an
// error message. Only asked when classify found nothing: the MPL-2.0 text
// itself names the GNU licenses.
func copyleft(text string) string {
	t := normalise(text)
	for _, c := range []struct{ marker, name string }{
		{"gnu affero general public license", "AGPL"},
		{"gnu lesser general public license", "LGPL"},
		{"gnu library general public license", "LGPL"},
		{"gnu general public license", "GPL"},
		{"server side public license", "SSPL"},
	} {
		if strings.Contains(t, c.marker) {
			return c.name
		}
	}
	return ""
}

var licenseName = regexp.MustCompile(`(?i)^(licen[cs]e|copying|notice|unlicense)([._-].*)?$`)

var codeExtension = map[string]bool{
	".go": true, ".swift": true, ".c": true, ".h": true, ".cc": true, ".s": true,
	".py": true, ".sh": true, ".json": true, ".yml": true, ".yaml": true, ".html": true, ".tmpl": true,
}

// isLicenseFile: LICENSE, LICENCE, COPYING, UNLICENSE or NOTICE, with or
// without a suffix (LICENSE.txt, LICENSE.BSD, NOTICE.md), but not code that
// happens to be called license.go.
func isLicenseFile(name string) bool {
	return licenseName.MatchString(name) && !codeExtension[strings.ToLower(filepath.Ext(name))]
}

func isNotice(name string) bool {
	return strings.HasPrefix(strings.ToLower(name), "notice")
}

// licenseFiles lists the license and notice files directly in dir, sorted.
func licenseFiles(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var files []string
	for _, e := range entries {
		if e.Type().IsRegular() && isLicenseFile(e.Name()) {
			files = append(files, filepath.Join(dir, e.Name()))
		}
	}
	sort.Strings(files)
	return files, nil
}

// file is one license or notice text of a component.
type file struct {
	path   string // for messages only
	text   string
	notice bool
}

// license works out a component's license from its files: the union of what
// its license files grant. NOTICE files are kept but not classified.
func license(name string, files []file, overrides map[string]override) (string, error) {
	if o, ok := overrides[name]; ok {
		if strings.TrimSpace(o.Reason) == "" {
			return "", fmt.Errorf("%s: the override in overrides.json gives no reason", name)
		}
		for _, id := range strings.Split(o.License, " AND ") {
			if !allowed[id] {
				return "", fmt.Errorf("%s: the override names %q, which Runnir may not ship", name, id)
			}
		}
		return o.License, nil
	}
	seen := map[string]bool{}
	licenses := 0
	for _, f := range files {
		if f.notice {
			continue
		}
		licenses++
		ids := classify(f.text)
		if len(ids) == 0 {
			if c := copyleft(f.text); c != "" {
				return "", fmt.Errorf("%s: %s is under the %s, which Runnir may not ship", name, f.path, c)
			}
			return "", fmt.Errorf("%s: the license in %s is not recognised; add the component to overrides.json with a reason if it may ship", name, f.path)
		}
		for _, id := range ids {
			seen[id] = true
		}
	}
	if licenses == 0 {
		return "", fmt.Errorf("%s: no license file", name)
	}
	var ids []string
	for id := range seen {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return strings.Join(ids, " AND "), nil
}
