# Third-Party License Notices And Settings › About (B49)

Status: design approved on 2026-11-06. Backlog: B49 in the [MVP checklist](../../product/mvp-implementation-checklist.md), part of the B17 release gate. Follows [ADR 0008](../../decisions/0008-apache-2-license.md), whose consequence "before the first release tag the app and the Core binaries must carry the third-party notices" this closes. Drawn in `runnir.pen` (journey G, Row — Settings, `S12 / Settings / About …`).

## Problem

Runnir.app bundles two Go programs, `runnir-core` and `act`, and links 22 Swift packages; the release also publishes the Core alone for darwin, linux and windows. Their licenses (MIT, BSD, Apache-2.0 with NOTICE files, ISC and one MPL-2.0 module) require their texts and notices to go with every copy. Today only act's own license ships, in `Contents/Resources/Licenses`; act's 87 modules, the Core's 26, Go itself and the Swift packages ship nothing, and the bare Core binaries carry no notice at all. The app also has no place that says which version runs and under which license.

## Decisions

| Question | Decision |
| --- | --- |
| Where users see them | A new last section of Settings, About: versions, Runnir's license, links, and the third-party components with their texts |
| Bare Core binaries | `runnir licenses` prints Runnir's license and the Core's notices, embedded with `go:embed`; the release also publishes the same text as `runnir-<tag>-THIRD-PARTY-NOTICES.txt` |
| How the texts are collected | A generator, `tools/notices` (its own Go module, standard library only), writes committed files; CI regenerates them and fails when they differ. Builds copy files and never read module caches or the network |
| Which code | Go: the packages `go list -deps` links into the Core for the six release targets and into act for darwin arm64 and amd64, plus Go's own license. Swift: every package in `Package.resolved`, a superset of what the app links |
| Which files | `LICENSE*`, `LICENCE*`, `COPYING*` and `NOTICE*` at a module's or package's root, and license files in the directories of linked Go packages and under a Swift package's `Sources/` (BoringSSL in swift-crypto and swift-nio-ssl) |
| Allowed licenses | Apache-2.0, MIT, BSD-2-Clause, BSD-3-Clause, ISC, Zlib and MPL-2.0. Any other license, an unrecognised text or a component without a license file fails the generator with the component's name. `tools/notices/overrides.json` records a manual decision with its reason |
| MPL-2.0 | Every Go component names its exact source archive on `proxy.golang.org`, which is how a recipient obtains the MPL-covered source (`github.com/cyphar/filepath-securejoin` in act) |
| Duplicates | Identical texts are stored once (one Apache-2.0 for dozens of modules); MIT and BSD differ in their copyright lines and stay separate |
| Website links | `https://runnir.com`, `/privacy` and `/terms` |

## Generated Files

All start with a line saying that `scripts/update-notices.sh` generates them.

| File | Content | Used by |
| --- | --- | --- |
| `licenses/notices.json` | Groups "Runnir.app" (Swift packages), "Runnir Core" (Go and the Core's modules) and "act" (act, its modules and Go). A component: `name`, `version`, `license` (SPDX id), `source` (URL), `texts` (ids). A pool of texts by id (the first 12 hex digits of their SHA-256) | The app bundle, Settings › About |
| `licenses/Runnir-LICENSE.txt` | A copy of `LICENSE` | The app bundle, View License |
| `core/internal/licenses/LICENSE` | A copy of `LICENSE` | `runnir licenses` |
| `core/internal/licenses/NOTICES.txt` | Plain text: per component a heading with name, version, license and source, then its texts | `runnir licenses`, the release asset |

Output is deterministic: groups in a fixed order, components by name, texts by id, no dates, so two runs without a change are identical byte for byte.

## Generator

`go run ./tools/notices` from the repository root writes the files; `-check` writes nothing and exits 1 with a diff summary when a file would change. `scripts/update-notices.sh` runs it.

1. Go: for each target, `go list -deps -json` of `./cmd/runnir` in `core` (GOOS darwin, linux, windows × GOARCH arm64, amd64) and of `github.com/nektos/act` in `third_party/act` (darwin arm64, amd64), with `CGO_ENABLED=0`. Modules other than the main one are collected with their directories; each linked package's directory and its parents up to the module root are searched for license files.
2. Go itself: `$(go env GOROOT)/LICENSE`, as component "Go" with the toolchain's version, in the Core and act groups.
3. Swift: `xcodebuild -resolvePackageDependencies -project apps/macos/Runnir.xcodeproj -scheme Runnir -clonedSourcePackagesDirPath <temporary folder>`, then each package of `Package.resolved` from `<folder>/checkouts/<name>`; its version is the resolved version (or revision). `-swift-packages <dir>` points at existing checkouts instead, for tests.
4. Classification by normalised text (lower case, collapsed white space): Apache-2.0 ("apache license" and "version 2.0"), MPL-2.0 ("mozilla public license"), ISC, Zlib, MIT ("permission is hereby granted, free of charge"), BSD-3-Clause (the clause naming contributors who may not endorse) or BSD-2-Clause. A component's license is that of its root license file; NOTICE files are kept as texts but not classified. GPL, LGPL, AGPL, SSPL and anything unrecognised fail.
5. Source URLs: Go modules `https://proxy.golang.org/<escaped path>/@v/<escaped version>.zip` (upper case letters escaped as `!` plus lower case, as the module proxy requires); Go `https://go.dev/dl/`; Swift packages their repository URL at `/tree/<version>`.

## Core

- `core/internal/licenses` embeds `LICENSE` and `NOTICES.txt` and returns them as one text.
- `runnir licenses` prints it and exits 0; the usage text lists it next to `version`, `serve` and `rpc`. It touches no network, data folder or analytics ledger.
- `release.yml` writes `build/export/runnir-<tag>-THIRD-PARTY-NOTICES.txt` from the same file, publishes it with the other assets, and the asset check covers it. The release notes say where the licenses are.

## App: Settings › About

Drawn in Pen first. The last section of Settings, after Privacy; the global search finds it as About, Version, License and Acknowledgements; opening it counts `overlay:settings.about` (B21).

- Header: the app icon, "Runnir", "Version 0.1.0 · Core 0.1.0" and Copy, which copies the app, Core and macOS versions as Report a Bug shows them.
- License: "Runnir is licensed under the Apache License 2.0." and View License, which shows `Runnir-LICENSE.txt` in a panel inside Settings (Runnir's own panel, not a popover).
- Links: Website, GitHub, Privacy Policy and Terms of Use, opened in the browser.
- Third-party software: the number of components and a search field (name or license); three collapsible groups, Runnir.app, Runnir Core and act; a row shows the name, the version in monospace and the license id; clicking a row shows its texts in a scrolling monospaced box, then Source.
- Data: `LicenseCatalog` (a protocol, the bundle's `Licenses/notices.json` in the app, a fake in tests). Without the file the section says "Licenses are missing from this build."

## Build And CI

- `scripts/build-core-macos.sh` copies `licenses/notices.json` and `licenses/Runnir-LICENSE.txt` into `Resources/Licenses` instead of act's `LICENSE` (act's text is in `notices.json`).
- `scripts/check-app-build.sh` fails a bundle without both files or without the three groups.
- `app-build.yml` (macOS) runs `go run ./tools/notices -check` and the generator's tests; `tools/**` triggers it.

## Testing

- Generator, with fixture modules and packages: each allowed license is recognised; GPL, LGPL, an unknown text and a missing file fail with the component's name; identical texts are stored once; a license file in a package directory is found; module paths with upper case letters are escaped; output is identical across two runs; an override applies and needs a reason.
- Core: `runnir licenses` starts with the Apache License and names `google.golang.org/grpc`; `go test`, `go vet` and `go build` in `core`.
- App: `LicenseCatalog` decodes the groups, searches by name and license, and reports a missing file; the app builds and its unit tests pass, `DropdownTests` included.

## Not In This Change

A NOTICE file for Runnir itself (it has no upstream notices to carry); notices for the Linux and Windows Core binaries beyond what `runnir licenses` and the release asset provide; checking licenses of tools used only to build (Xcode, protoc plugins), which are not distributed.
