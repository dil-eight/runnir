# Runnir

Runnir is an open-source native macOS workspace for GitHub Actions and local workflow development. AI is optional and deferred beyond MVP v0.1.

Status: native SwiftUI + Go Core foundation. MVP v0.1 is specified but not complete; existing macOS source paths are preserved.

## Implemented

- Native SwiftUI/AppKit desktop shell based on the Pen Manager, splash and workspace designs.
- Local repository import, read-only workflow browser and independent restorable workspace windows.
- Versioned atomic local registry/session storage, missing-folder recovery and public GitHub toolbar link.
- Xcode project with app, unit test, and UI test targets.
- Swift 6 with strict concurrency checking.
- Feature-oriented source layout.
- Domain models for repositories, workflows, runs, and artifacts.
- Typed GitHub REST client foundation for authenticated user, repositories, and workflows.
- Keychain-backed credential storage abstraction.
- Unit tests for decoding, request construction, error mapping, credentials, and app state.
- macOS GitHub Actions CI for build, unit tests, static analyzer, and dependency review.
- MVP specification and future AI/MCP design documents (no AI runtime or MCP server).
- Minimal Go CLI (`version`) and version-only JSON-RPC stdio endpoint (`rpc`).
- Bundled Core executable with a Swift startup handshake and integration test.
- Go native test automation, six cross-compilation targets, formatting/vet and vulnerability checks.

## Planned

- v0.1 target: lifecycle hardening, signed folder-grant verification and per-workspace SQLite/cache-first sync.
- v0.1: Device Flow login, repository dashboard, typed dispatch, optional portable .runnir launches/environments and private overrides.
- v0.1: run/job/log inspection, cancel/rerun, local YAML editing and offline actionlint validation.
- v0.1: explicit Docker/OrbStack and act setup, compatible local execution/output/cancellation.
- Later: artifact inspection/reuse, optional AI/chat/MCP, cloud integrations and startup offers.
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
`runnir rpc` is desktop IPC; an MCP server is planned and is not implemented.

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

Runnir stores GitHub credentials only in macOS Keychain.

The bootstrap does not fake authentication. To enable login, create a GitHub OAuth app or device-flow capable GitHub App, document the client identifier, and wire the auth service to exchange and store tokens securely.

No client secret should be embedded in the app.

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
