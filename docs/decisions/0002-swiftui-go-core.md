# 0002 SwiftUI Desktop + Portable Go Core

Status: accepted. Extends ADR 0001; its native desktop choice remains valid. The runtime transport was changed from one-shot JSON-RPC over stdio to a persistent local gRPC API by [ADR 0004](0004-single-core-process-grpc.md); the stdio JSON-RPC handshake remains. The rest of this decision, including no CGO, an app-owned lifetime and no permanent daemon, still holds.

## Decision

Keep Swift 6/SwiftUI for macOS presentation, Observation state, native AI providers, Keychain, notifications and system integration. Use a separate pure Go executable for portable GitHub Actions and CI/CD domain services, CLI, and future MCP server. Do not embed Go with CGO.

The desktop owns Core's lifecycle and communicates through versioned JSON-RPC over local stdio. No permanent background daemon or mandatory cloud backend is required. IPC and MCP adapters call the same Core services; neither transport owns business rules.

## Rationale

Go supports future Linux/Windows CLI clients and reusable tool integrations. A process boundary keeps native UI and Apple frameworks independent of portable domain code. Stdio avoids a network listener and provides an explicit child lifetime. It is a communication channel, not an isolation boundary.

## Consequences

- Bundle architecture-compatible Core binaries in the macOS app. Use universal helpers for universal builds.
- Keep the Xcode project and Swift sources in `apps/macos/` (moved from the repository root) so the Go Core, contracts and docs stay visually separate.
- Migrate existing Swift GitHub services per feature, with parity tests; preserve working behavior throughout.
- Core accepts only named methods. No model or MCP client can request unrestricted commands.
- Swift owns Keychain persistence. Future credentials cross a private session channel only when necessary, never argv, tool responses, prompts, logs or disk.
- Runnir and its helper are signed with Developer ID and the hardened runtime and run without the App Sandbox ([ADR 0005](0005-developer-id-without-app-sandbox.md)); verify signed builds separately. Cross-platform CLI policy must be enforced by Core before repository tools ship.
- Maintain transport-independent permission and approval checks in Core. AI-generated approval flags are not authorization.
- Prefer the Go standard library and CGO_ENABLED=0; use native execution tests in addition to cross-compilation.

## Initial Scope

`runnir version`, `runnir rpc`, `core.v1.version`, desktop startup handshake, build-time bundling and tests. The handshake creates one short-lived child per exchange and closes stdin after the request; Core exits at EOF. Reusing a process is a later optimization, not a daemon requirement.

## Alternatives

Swift-only domain code limits portable reuse. CGO embedding couples toolchains and lifetimes. A network daemon adds lifecycle and authentication requirements without an immediate product benefit.
