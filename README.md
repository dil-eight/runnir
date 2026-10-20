# Runnir

Runnir is an open-source native macOS workspace for GitHub Actions and local workflow development. AI is optional and deferred beyond MVP v0.1.

Status: native SwiftUI + Go Core foundation. MVP v0.1 is specified but not complete; existing macOS source paths are preserved.

## Implemented

- Native SwiftUI/AppKit desktop shell based on the Pen designs: splash, Workspace Manager, independent restorable workspace windows and a workspace switcher (Shift-Command-O).
- Local repository import with security-scoped bookmarks (a stale bookmark is refreshed, a moved folder followed), read-only workflow file browser, versioned atomic session storage and missing-folder recovery.
- GitHub sign-in with the Device Flow of the registered Runnir Desktop GitHub App: no client secret in the app, the token only in the Keychain and in the Core's memory, sign-out, and automatic retry after an offline launch. Confirmed with a real sign-in.
- Workspaces linked to their GitHub repository through the `origin` remote, with an access check and a link to install the app on the repository.
- Offline workflow validation with actionlint built into the Go Core: diagnostics for each workflow file in the Workspace section, with the line highlighted in the source. No external tools run, and the repository's `.github/actionlint.yaml` is honored.
- GitHub Actions through the Go Core: workflows, recent runs (refreshed every 20 seconds while one is active, every 5 minutes otherwise), jobs and steps, job logs with search (bounded to the last 2 MiB), cancel and re-run, and `workflow_dispatch` with branch, typed inputs, saved presets and a confirmation. Changes go through a single-use confirmation and are never retried. Dispatch, logs, cancel and re-run are covered by tests with a fake GitHub, not yet by a controlled real run.
- One supervised Go Core per app: local gRPC over a Unix socket with a per-launch client secret, a liveness check, a Restart Core banner, a diagnostics log, and shutdown on quit. Idle measurement on one machine: about 94 MB for the app plus Core with 10 open repositories (Debug build).
- Go CLI (`version`, `serve`) and a version-only JSON-RPC stdio endpoint (`rpc`); execution scheduling exists with a stub runner (there is no real workflow execution engine).
- Swift 6 with strict concurrency, unit tests for the app and Core, macOS CI for build, tests and static analysis, Go tests on three platforms, six cross-compilation targets, a check that generated code matches the contract, formatting, vet and vulnerability checks.
- MVP specification and future AI/MCP design documents (no AI runtime or MCP server).

## Planned

- v0.1: favorites and dashboard status, local YAML editing.
- v0.1: explicit Docker/OrbStack and act setup, compatible local execution, output, cancellation and cleanup.
- v0.1: lifecycle hardening, signed folder-grant verification, per-workspace SQLite and cache-first sync, optional portable .runnir launches and environments.
- Later: artifact inspection and reuse, optional AI/chat/MCP, cloud integrations and startup offers.
- Distribution work: Developer ID signing, notarization, packaging and secure automatic updates; completion is not claimed.

## Specifications

- [Pen design plan: screens, states and reusable components](docs/design/README.md)
- [Optional analytics, crash reports and public GitHub link](docs/product/analytics-and-crash-reporting.md)

- [MVP v0.1 specification](docs/product/specification.md)
- [Implementation checklist and acceptance tests](docs/product/mvp-implementation-checklist.md)
- [First implementation slice and verification](docs/product/first-implementation-slice.md)
- [Desktop implementation report](docs/architecture/desktop-foundation-verification.md)

- [Architecture and boundaries](docs/architecture/overview.md)
- [Gap analysis](docs/architecture/gap-analysis.md)
- [Foundation verification](docs/architecture/foundation-verification.md)
- [SwiftUI + Go decision](docs/decisions/0002-swiftui-go-core.md)
- [Workspace/session and SQLite decision](docs/decisions/0003-workspaces-sessions-offline-storage.md)
- [Desktop lifecycle and restoration](docs/architecture/desktop-lifecycle.md)
- [Portable config, offline DB and shared sync](docs/architecture/workspace-persistence.md)
- [IPC v1](docs/architecture/ipc.md)
- [Updated roadmap](docs/product/roadmap.md)
- [Startup integrations and offers](docs/product/startup-integrations.md)
- [External offer catalog and local matching](docs/architecture/offers-catalog.md)
- [Startup program research](docs/research/startup-offers.md)

- [Future AI-first DevOps assistant](docs/product/ai-first-devops-assistant.md)
- [AI architecture](docs/architecture/ai.md)
- [MCP shape](docs/architecture/mcp.md)
- [Native macOS app template](docs/templates/native-macos-app-template.md)
- [MCP tool template](docs/templates/mcp-tool-template.md)

## Requirements

- macOS 15 or newer.
- Xcode 27 or newer for the current checked-in project settings.
- Swift 6.
- Go 1.27+ (Xcode builds and bundles the helper; CGO is disabled).

The app targets macOS 15+ for modern SwiftUI and Observation APIs and the grpc-swift 2 client (see ADR 0004).

## Development

Core checks (from `core/`): `go test ./...`, `go vet ./...`, `go build ./...`.
Run `go run ./cmd/runnir version` for product/IPC version metadata.
`runnir rpc` and `runnir serve` are desktop IPC; an MCP server is planned and is not implemented. See [Core gRPC API](docs/architecture/grpc-api.md).

Build:

```bash
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build
```

Run unit tests:

```bash
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests
```

Run static analyzer:

```bash
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' analyze
```

## GitHub Authentication

Runnir signs in with the OAuth Device Flow of the registered Runnir Desktop GitHub App, using only its public client ID; no client secret is embedded. The token is stored only in the macOS Keychain and handed to the Core's memory while signed in. Repositories become visible when the app is installed on them. See [GitHub authentication](docs/security/github-authentication.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, scoped tasks, native/Core checks, design contributions, privacy and PR expectations. Bug reports use the [reviewed issue template](.github/ISSUE_TEMPLATE/bug_report.md); suspected vulnerabilities follow [SECURITY.md](SECURITY.md).

## Releases

The checked-in LICENSE contains GPLv3. Apache-2.0 in the proposed MVP brief is an unresolved licensing proposal; LICENSE has not been changed.

Releases are tag-based:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The release workflow builds an unsigned draft app plus platform-specific Core binaries. Production distribution requires Developer ID signing (including the helper), Apple notarization, release notes, and packaging decisions before publishing. Automatic updates remain planned.
