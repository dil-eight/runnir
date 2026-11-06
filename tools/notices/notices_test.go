package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	apacheText = "                                 Apache License\n                           Version 2.0, January 2004\n"
	mitText    = "MIT License\n\nCopyright (c) 2024 Someone\n\nPermission is hereby granted, free of charge, to any person obtaining a copy"
	bsd2Text   = "Copyright (c) 2020 Someone\n\nRedistribution and use in source and binary forms, with or without\nmodification, are permitted provided that the following conditions are met:"
	bsd3Text   = bsd2Text + "\n3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products"
	iscText    = "Copyright (c) 2015 Someone\n\nPermission to use, copy, modify, and/or distribute this software for any purpose\nwith or without fee is hereby granted"
	zlibText   = "This software is provided 'as-is', without any express or implied warranty.\n3. Altered source versions must be plainly marked as such"
	mplText    = "Mozilla Public License Version 2.0\n==================================\n1.12. \"Secondary License\" means either the GNU General Public License, Version 2.0"
	gplText    = "                    GNU GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007"
	lgplText   = "                   GNU LESSER GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007"
)

func TestClassifyRecognisesTheAllowedLicenses(t *testing.T) {
	for _, c := range []struct{ text, want string }{
		{apacheText, "Apache-2.0"},
		{mitText, "MIT"},
		{bsd2Text, "BSD-2-Clause"},
		{bsd3Text, "BSD-3-Clause"},
		{iscText, "ISC"},
		{zlibText, "Zlib"},
		{mplText, "MPL-2.0"},
		{"All of the code in SQLite has been dedicated to the public domain by the authors.", "LicenseRef-Public-Domain"},
		{mitText + "\n\n" + apacheText, "Apache-2.0 MIT"},
		{"## License\n\n* Permission is hereby granted, free of charge,\n  to any person", "MIT"},
		{"Use it however you like.", ""},
	} {
		if got := strings.Join(classify(c.text), " "); got != c.want {
			t.Errorf("classify(%.30q) = %q, want %q", c.text, got, c.want)
		}
	}
}

func TestLicenseRefusesWhatRunnirMayNotShip(t *testing.T) {
	for _, c := range []struct {
		files []file
		want  string
	}{
		{[]file{{path: "COPYING", text: gplText}}, "under the GPL"},
		{[]file{{path: "COPYING.LESSER", text: lgplText}}, "under the LGPL"},
		{[]file{{path: "LICENSE", text: "Use it however you like."}}, "not recognised"},
		{[]file{{path: "NOTICE", text: "Copyright 2020 Someone", notice: true}}, "no license file"},
		{nil, "no license file"},
	} {
		_, err := license("example.com/m", c.files, nil)
		if err == nil || !strings.Contains(err.Error(), c.want) || !strings.Contains(err.Error(), "example.com/m") {
			t.Errorf("license(%v) error = %v, want one naming the component and %q", c.files, err, c.want)
		}
	}
	// The MPL-2.0 text names the GNU licenses; it is still MPL-2.0.
	if id, err := license("m", []file{{path: "LICENSE", text: mplText}}, nil); err != nil || id != "MPL-2.0" {
		t.Errorf("MPL-2.0 = %q, %v", id, err)
	}
	id, err := license("m", []file{{path: "LICENSE", text: bsd3Text}, {path: "LICENSE.MPL", text: mplText}, {path: "NOTICE", text: gplText, notice: true}}, nil)
	if err != nil || id != "BSD-3-Clause AND MPL-2.0" {
		t.Errorf("dual license = %q, %v", id, err)
	}
}

func TestOverridesNeedAReasonAndAnAllowedLicense(t *testing.T) {
	files := []file{{path: "LICENSE-LOGO", text: "https://example.com/logo.png"}}
	if _, err := license("m", files, map[string]override{"m": {License: "MIT"}}); err == nil || !strings.Contains(err.Error(), "no reason") {
		t.Errorf("override without a reason: %v", err)
	}
	if _, err := license("m", files, map[string]override{"m": {License: "MIT AND GPL-3.0", Reason: "x"}}); err == nil || !strings.Contains(err.Error(), "GPL-3.0") {
		t.Errorf("override with GPL: %v", err)
	}
	if id, err := license("m", files, map[string]override{"m": {License: "BSD-3-Clause", Reason: "the logo is not linked"}}); err != nil || id != "BSD-3-Clause" {
		t.Errorf("override = %q, %v", id, err)
	}
}

func TestLicenseFileNames(t *testing.T) {
	for name, want := range map[string]bool{
		"LICENSE": true, "LICENSE.txt": true, "LICENSE.BSD": true, "LICENSE-LOGO": true, "license.md": true,
		"COPYING": true, "COPYING.md": true, "NOTICE": true, "NOTICE.txt": true, "UNLICENSE": true, "LICENCE": true,
		"license.go": false, "licenses.go": false, "license_test.go": false, "README.md": false, "LICENSES": false,
	} {
		if got := isLicenseFile(name); got != want {
			t.Errorf("isLicenseFile(%q) = %v", name, got)
		}
	}
}

func TestEscapeModule(t *testing.T) {
	for in, want := range map[string]string{
		"github.com/Microsoft/go-winio":    "github.com/!microsoft/go-winio",
		"github.com/AlecAivazis/survey/v2": "github.com/!alec!aivazis/survey/v2",
		"v29.3.0+incompatible":             "v29.3.0+incompatible",
	} {
		if got := escapeModule(in); got != want {
			t.Errorf("escapeModule(%q) = %q, want %q", in, got, want)
		}
	}
}

func write(t *testing.T, path, text string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestGoComponentsReadNestedLicenses(t *testing.T) {
	dir := t.TempDir()
	write(t, filepath.Join(dir, "LICENSE"), mitText)
	write(t, filepath.Join(dir, "third_party/lib/LICENSE"), bsd3Text)
	write(t, filepath.Join(dir, "third_party/lib/inner/inner.go"), "package inner")
	write(t, filepath.Join(dir, "unused/LICENSE"), gplText) // not linked, not read
	modules := map[string]*linked{"github.com/Example/m": {
		module:   goModule{Path: "github.com/Example/m", Version: "v1.2.3", Dir: dir},
		packages: map[string]bool{dir: true, filepath.Join(dir, "third_party/lib/inner"): true},
	}}
	components, errs := goComponents(modules, nil)
	if len(errs) > 0 {
		t.Fatal(errs)
	}
	c := components[0]
	if c.License != "BSD-3-Clause AND MIT" || len(c.files) != 2 || c.files[1].path != "third_party/lib/LICENSE" {
		t.Fatalf("component = %+v", c)
	}
	if c.Source != "https://proxy.golang.org/github.com/!example/m/@v/v1.2.3.zip" {
		t.Errorf("source = %s", c.Source)
	}
}

func TestSwiftComponentsReadVendoredLicenses(t *testing.T) {
	root := t.TempDir()
	write(t, filepath.Join(root, packageResolved), `{"pins":[
		{"identity":"swift-thing","location":"https://github.com/apple/swift-thing.git","state":{"revision":"0123456789abcdef","version":"1.2.0"}},
		{"identity":"pinned","location":"https://github.com/o/pinned","state":{"revision":"fedcba9876543210ffff"}}]}`)
	checkouts := filepath.Join(root, "checkouts")
	write(t, filepath.Join(checkouts, "swift-thing/LICENSE.txt"), apacheText)
	write(t, filepath.Join(checkouts, "swift-thing/NOTICE.txt"), "This product contains a derivation of BoringSSL.")
	write(t, filepath.Join(checkouts, "swift-thing/Sources/CVendored/LICENSE"), iscText)
	write(t, filepath.Join(checkouts, "pinned/LICENSE"), mitText)
	components, errs := swiftComponents(root, checkouts, nil)
	if len(errs) > 0 {
		t.Fatal(errs)
	}
	if len(components) != 2 || components[0].Name != "pinned" || components[1].Name != "swift-thing" {
		t.Fatalf("components = %+v", components)
	}
	pinned, thing := components[0], components[1]
	if pinned.Version != "fedcba987654" || pinned.Source != "https://github.com/o/pinned/tree/fedcba9876543210ffff" {
		t.Errorf("pinned = %+v", pinned)
	}
	if thing.License != "Apache-2.0 AND ISC" || len(thing.files) != 3 || thing.Source != "https://github.com/apple/swift-thing/tree/1.2.0" {
		t.Errorf("swift-thing = %+v", thing)
	}
}

func TestOutputIsDeterministicAndStoresATextOnce(t *testing.T) {
	groups := func() []group {
		return []group{{Name: "Runnir Core", Components: []component{
			{Name: "a.example/one", Version: "v1", License: "Apache-2.0", Source: "s1", files: []file{{text: apacheText + "\r\n  "}}},
			{Name: "b.example/two", Version: "v2", License: "Apache-2.0", Source: "s2", files: []file{{text: apacheText}}},
			{Name: "c.example/three", Version: "v3", License: "MIT", Source: "s3", files: []file{{text: mitText}}},
		}}}
	}
	first, second := build(groups()), build(groups())
	if len(first.Texts) != 2 {
		t.Fatalf("texts = %d, want the Apache text once and MIT", len(first.Texts))
	}
	j1, _ := renderJSON(first)
	j2, _ := renderJSON(second)
	t1, _ := renderText(first, "Runnir Core", "Runnir Core")
	t2, _ := renderText(second, "Runnir Core", "Runnir Core")
	if !bytes.Equal(j1, j2) || !bytes.Equal(t1, t2) {
		t.Fatal("two runs differ")
	}
	text := string(t1)
	if strings.Count(text, "Apache License") != 1 || !strings.Contains(text, "a.example/one v1 (Apache-2.0)\n  Source: s1\nb.example/two v2 (Apache-2.0)") {
		t.Errorf("text:\n%s", text)
	}
}
