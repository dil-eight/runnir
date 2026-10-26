# Contributing

Runnir welcomes focused contributions to native macOS UI, portable Go Core, tests, design, documentation and accessibility. Start with the [MVP specification](docs/product/specification.md), [roadmap](docs/product/roadmap.md) and [implementation checklist](docs/product/mvp-implementation-checklist.md). Follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## Choose A Contribution

Use a concrete backlog item or reproducible issue and describe the user outcome. Check existing issues/PRs before starting overlapping work. For substantial scope or a new dependency, open an issue describing the problem and proposed change before investing in a large implementation; small fixes and documentation improvements can go directly to a PR.

The proposed first vertical slice is [workspace/window lifecycle](docs/product/first-implementation-slice.md), followed by [offline validation](docs/product/offline-validation-slice.md). The [gap analysis](docs/architecture/gap-analysis.md) distinguishes implemented foundations from missing features. Do not assume a planned screen, protocol or manifest is a functioning feature.

AI/MCP and cloud/referral integrations remain later directions. Keep current contributions tied to the agreed MVP or an explicitly scoped issue. No Runnir account, paid AI subscription or analytics consent is needed to contribute.

## Development Setup

For desktop work, use a Mac with a supported Xcode 27+ installation, Swift 6 and Go 1.27+. The app targets macOS 15+. Go is required because Xcode builds and bundles the Core helper. The Xcode build never downloads Go: when the Go on PATH is older than `core/go.mod` asks for, it uses that version if a `go` command already downloaded it to the module cache, and otherwise stops and asks you to update Go (for example `brew upgrade go`). Open apps/macos/Runnir.xcodeproj, select Runnir and My Mac, then Run.

Go-only work can run from core/ on supported macOS/Linux/Windows environments. Native desktop integration tests require macOS/Xcode; a cross-build is not evidence of native execution on another OS.

The current foundation builds unsigned; no production signing keys are required for routine development. Real authentication still requires a configured supported GitHub client. Use synthetic fixtures and injected test services when credentials are unavailable; do not add a fake successful login or commit a personal token.

## Architecture And Code

- Preserve Swift 6/SwiftUI/Observation for native UI, Keychain and system integration; use pure Go for new portable domain services. Read [ADR 0002](docs/decisions/0002-swiftui-go-core.md) and [ADR 0003](docs/decisions/0003-workspaces-sessions-offline-storage.md).
- Keep versioned IPC (gRPC over a Unix socket, plus the JSON-RPC version handshake) separate from business logic. Document changed contracts, regenerate code with `scripts/generate-contracts.sh`, and add compatibility/error tests.
- Preserve existing Swift services until feature-level migrations are tested. Avoid unrelated file moves/refactors and duplicate GitHub implementations.
- Prefer small protocol-backed services, deterministic tests and standard libraries. Do not introduce Node/npm/pnpm, React, Electron, Tauri, Rust, CocoaPods or Carthage.
- Explain new dependency need, pinned version, license, data access, subprocess/network behavior and maintenance cost in the PR. Do not silently add an SDK with autocollection.
- Follow [AGENTS.md](AGENTS.md) when working with coding agents, including its attribution rules.

## macOS UI Workflow

Run the app in Xcode with scheme Runnir and destination My Mac. Use isolated SwiftUI previews for visual iteration and the real app for GitHub, Keychain, IPC and process checks. See [development workflow and Storybook-style catalog options](docs/development/macos-ui-workflow.md).

For Pen work, read the [design plan](docs/design/README.md), [screen/state matrix](docs/design/screens-and-states.md) and [component inventory](docs/design/reusable-components.md). Preserve collaborative changes and existing concepts; use reusable instances and semantic tokens. docs/design/runnir.pen and required referenced assets may be committed. Local agent skills and build output stay ignored.

Use synthetic content in screenshots, fixtures and previews. Include loading/empty/error/denied states, supported window sizes, light/dark and keyboard/accessibility behavior appropriate to the change. Previews and the component catalog are planned practices, not currently implemented tooling. Include before/after screenshots for visual changes when useful, with no private repository content.

## Local Checks

For native code changes, run from the repository root:

```bash
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests
xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' analyze
```

For Core changes, run from core/:

```bash
gofmt -w cmd internal
go test ./...
go vet ./...
go build ./...
```

CI additionally runs race checks, formatting/vulnerability checks and six target cross-builds. Prefer CGO_ENABLED=0 for portable release binaries. Review the actual workflow results; checked-in CI configuration is not proof that hosted jobs passed.

Add focused tests for API failures/rate limits, IPC compatibility, validation diagnostics, process state/cancellation and security-sensitive behavior touched by the change. Use mocks for deterministic error cases and controlled real integration evidence for authentication/execution claims. Documentation-only changes need link/content checks, not a full app rebuild. State any checks you could not run and why.

## Privacy And Reports

Read the [privacy guardrails](docs/legal/security-privacy-policy.md) and [analytics/crash reporting requirements](docs/product/analytics-and-crash-reporting.md). Keep credentials in Keychain; never include tokens, signing material, environment secrets, user paths, private source/YAML or raw workflow/crash logs in issues, fixtures, screenshots or diagnostics.

Analytics stays off by default and requires independent opt-in. Crash reporting requires a sanitized preview and explicit sharing approval; opening a browser draft is not proof that an issue was created. An analytics feature must document its operator, payload, consent/withdrawal, retention and actual network behavior before enabling delivery.

For ordinary bugs, use the [issue template](.github/ISSUE_TEMPLATE/bug_report.md): describe expected/actual behavior, minimal synthetic reproduction, app/Core version, coarse macOS version and architecture. Add only a reviewed sanitized diagnostic summary. Public issues expose report contents and the author's GitHub identity. Follow [SECURITY.md](SECURITY.md) for suspected vulnerabilities rather than posting exploit details publicly.

## Pull Requests

- Keep changes focused.
- Link the issue/backlog/FR and explain the concrete problem and resulting behavior.
- Include verification commands/results and material limitations; a draft PR is appropriate for incomplete work.
- Add fixture-based regression coverage where behavior changes warrant it; do not claim untested authentication, signing, notarization, updates or deployment is complete.
- Document new GitHub permissions, repository filesystem access and IPC contracts before introducing them.
- Include design/state references and safe screenshots for UI work; describe how unsaved data and failure recovery behave.
- Leave unrelated changes intact. Exclude secrets, local skills, build output and personal editor files.

Maintainers review scope, behavior, test evidence, privacy and dependency impact. Do not assume publishing an issue or opening a PR authorizes deployment, a release or production credentials. Keep commits/descriptions focused on the product change; follow AGENTS.md's attribution policy.

## Licensing

The checked-in [LICENSE](LICENSE) contains GPLv3. Apache-2.0 is a proposal in a product brief, not an adopted license change. Do not relabel/relicense the project in a contribution. Check dependency compatibility and retain required upstream notices; do not introduce third-party material without a usable license/source record.
