# Runnir

Runnir is an open-source native macOS workspace for GitHub Actions and local workflow development. AI is optional and deferred beyond MVP v0.1.

Status: native SwiftUI + Go Core foundation. MVP v0.1 is specified but not complete; existing macOS source paths are preserved.

## Implemented

- Native SwiftUI/AppKit desktop shell based on the Pen designs: splash, Workspace Manager, independent restorable workspace windows and a workspace switcher (Shift-Command-O).
- GitHub tab in the Workspace Manager: the repositories of every account where the Runnir Desktop app is installed, with search, an owner filter and stars. A repository opens as its registered workspace. One without a local clone shows its workflows with their latest runs and recent runs, and its workflows can be started from there. Runnir never clones a repository.
- Local repository import with security-scoped bookmarks (a stale bookmark is refreshed, a moved folder followed), versioned atomic session storage and missing-folder recovery.
- Workflow editor in the Workspace section with line numbers, YAML colors and lines with diagnostics marked. Saving goes through the Go Core, which writes inside the repository only, replaces the file in one step, and refuses to overwrite a file that changed on disk since it was opened unless you choose Save Anyway. Runnir asks before unsaved edits would be lost, and checks the file again after saving. New workflow files start from a small workflow you can run by hand; renaming a file keeps its unsaved edits and star, and copies its presets to the new name while GitHub still knows the old one. Neither ever replaces another file, and nothing is committed.
- GitHub sign-in with the Device Flow of the registered Runnir Desktop GitHub App: no client secret in the app, the token only in the Keychain and in the Core's memory, sign-out, and automatic retry after an offline launch. Confirmed with a real sign-in.
- Workspaces linked to their GitHub repository through the `origin` remote, with an access check and a link to install the app on the repository.
- An Overview per workspace: favorite workflows first (kept on this Mac), each workflow's latest GitHub run, the selected workflow's last run as a pipeline of its jobs, recent runs, and saved presets to run again. When GitHub cannot be reached, it shows the last data with its age.
- Offline workflow validation with actionlint built into the Go Core: diagnostics for each workflow file in the Workspace section, with the line highlighted in the source. No external tools run, and the repository's `.github/actionlint.yaml` is honored.
- GitHub Actions through the Go Core: workflows, recent runs (refreshed every 20 seconds while one is active, every 5 minutes otherwise), jobs and steps, job logs with search (bounded to the last 2 MiB), cancel and re-run, and `workflow_dispatch` with branch, typed inputs, saved presets and a confirmation. Changes go through a single-use confirmation and are never retried. Dispatch, logs, cancel and re-run are covered by tests with a fake GitHub, not yet by a controlled real run.
- One supervised Go Core per app: local gRPC over a Unix socket with a per-launch client secret, a liveness check, a Restart Core banner, a diagnostics log, and shutdown on quit. Idle measurement on one machine: about 94 MB for the app plus Core with 10 open repositories (Debug build).
- Local workflow runs with act and your own container engine (OrbStack, Docker Desktop, Colima). A review lists the tools, which jobs can run, the images to download, the secrets the workflow will not get, and what the run can access. The run starts only after you confirm that you trust the workflow. Runs show live, bounded output per job and can be stopped; their containers are removed afterwards. Quitting, or closing the workspace while a run is going, asks first. Runnir bundles the act version it was verified with (v0.2.89); an installed act can be used instead with an experimental setting. The Docker socket, Docker credentials, the GitHub token and the host environment are never passed to a run. Verified end to end on OrbStack with small images, not yet with the full runner images. See [ADR 0006](docs/decisions/0006-bundled-act-for-local-runs.md).
- Settings › Tools shows the bundled and installed act, the Docker CLI and the container engine, with Recheck and a button to open a stopped engine. Runnir never installs tools, starts an engine or switches the Docker context.
- Go CLI (`version`, `serve`) and a version-only JSON-RPC stdio endpoint (`rpc`).
- Swift 6 with strict concurrency, unit tests for the app and Core, macOS CI for build, tests and static analysis, Go tests on three platforms, six cross-compilation targets, a check that generated code matches the contract, formatting, vet and vulnerability checks.
- MVP specification and future AI/MCP design documents (no AI runtime or MCP server).

## Planned

- v0.1: creating and renaming workflow files.
- v0.1: local runs with the full runner images verified on Docker Desktop and OrbStack; workflow_dispatch inputs and secrets for local runs.
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
- [Developer ID without the App Sandbox](docs/decisions/0005-developer-id-without-app-sandbox.md)
- [Bundled act for local runs](docs/decisions/0006-bundled-act-for-local-runs.md)
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

## No App Sandbox

Runnir does not use the Apple App Sandbox. It is distributed outside the Mac App Store, signed with Developer ID, with the hardened runtime and notarization. Local workflow runs need the user's container engine (Docker Desktop, OrbStack, Colima) and `act`; under the sandbox every process Runnir starts inherits it, and the sandbox refuses the Docker socket. Runnir itself limits what it touches instead: it reads only inside the folders you choose, never follows symlinks or `..` out of them, bounds every read, keeps credentials in the Keychain, and asks for confirmation before running code or changing anything on GitHub. See [ADR 0005](docs/decisions/0005-developer-id-without-app-sandbox.md).

## GitHub Authentication

Runnir signs in with the OAuth Device Flow of the registered Runnir Desktop GitHub App, using only its public client ID; no client secret is embedded. The token is stored only in the macOS Keychain and handed to the Core's memory while signed in. Repositories become visible when the app is installed on them. See [GitHub authentication](docs/security/github-authentication.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup, scoped tasks, native/Core checks, design contributions, privacy and PR expectations. Bug reports use the [reviewed issue template](.github/ISSUE_TEMPLATE/bug_report.md); suspected vulnerabilities follow [SECURITY.md](SECURITY.md).

## Releases

The checked-in LICENSE contains GPLv3. The app bundles act (MIT); its license ships in `Contents/Resources/Licenses`, and the notices of act's own dependencies still need to be collected before a release. Apache-2.0 in the proposed MVP brief is an unresolved licensing proposal; LICENSE has not been changed.

Releases are tag-based:

```bash
git tag v0.1.0
git push origin v0.1.0
```

The release workflow builds an unsigned draft app plus platform-specific Core binaries. Production distribution requires Developer ID signing (including the helper), Apple notarization, release notes, and packaging decisions before publishing. Automatic updates remain planned.
