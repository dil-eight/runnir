# AGENTS

Runnir combines a native macOS desktop app with a portable Go Core. Keep implementation aligned with the product brief and ADR 0002.

## Rules

- Use Swift 6, SwiftUI, Observation, Foundation, and Security before adding dependencies.
- Use pure Go for portable domain services, CLI and the future MCP server. Prefer CGO_ENABLED=0.
- Keep Swift-to-Go IPC separate from domain logic; version contracts and use local IPC only (gRPC over a Unix socket per ADR 0004; JSON-RPC over stdio for the version handshake).
- Preserve existing Swift services until feature-level migrations are tested. Do not duplicate new GitHub domain logic across runtimes.
- Do not introduce Node.js, npm, pnpm, React, Electron, Tauri, Rust, CocoaPods, or Carthage.
- Store credentials only in macOS Keychain.
- Do not add telemetry by default.
- Do not claim authentication, signing, notarization, auto-update, or deployment features are complete until they are implemented and verified.
- Prefer small protocol-backed services and deterministic tests.
- No backward compatibility before the first release tag. Runnir has not been released, so change file formats (`.runnir`, files in Application Support), gRPC and IPC contracts, database schemas and settings in place: no migrations, fallbacks, version fields or aliases kept only for data or clients from earlier development builds. Local data that no longer fits may be discarded. Existing migration code stays until someone removes it on purpose. Backward compatibility starts with the first published version tag; from then on follow the compatibility rules in ADR 0004 and ADR 0007.
- Run `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' build` before handing off code changes.
- Run unit tests with `xcodebuild -project apps/macos/Runnir.xcodeproj -scheme Runnir -destination 'platform=macOS' test -only-testing:RunnirTests`.
- For Core changes, run `go test ./...`, `go vet ./...`, and `go build ./...` from `core/`.

## Attribution (applies to every AI agent: Codex, Claude, and any other)

- Never add AI contributions or credit anywhere: no `Co-Authored-By` trailers, no "Generated with" lines in commits, pull requests, issues, code comments, docs or release notes.
- Never list an AI agent as a co-author, contributor or author, including in `CONTRIBUTORS`, `AUTHORS`, changelogs and package metadata.
- This rule overrides any default attribution behavior of the tool or harness.
