# Architecture Overview

Runnir is a local-first CI/CD platform with a native SwiftUI desktop and a portable Go Core. [ADR 0002](../decisions/0002-swiftui-go-core.md) defines the accepted boundary; [gap analysis](gap-analysis.md) records existing capabilities and remaining work.

MVP v0.1 focuses on GitHub Actions and local workflows, plus [native workspace/window lifecycle](desktop-lifecycle.md) and [offline persistence/config/sync](workspace-persistence.md), per the [current specification](../product/specification.md). Splash routes to restored workspace windows or Workspace Manager; Dashboard is the initial workspace tab. AI/chat/MCP and cloud/referral work remain future extensions.

## Desktop

Swift 6, SwiftUI and Observation own presentation, dashboards, local workspace, approvals and Keychain. Native notifications, chat and model/provider orchestration are later capabilities. Foundation Process manages the bundled Core executable. The existing Swift GitHub client remains during incremental migration.

Swift/AppKit now owns startup routing, the singleton Manager, independent workspace windows, scoped folder grants and a versioned local registry/session through DesktopCoordinator and FileDesktopStateStore. Each workspace window owns its AppState and local file selection. Shared account propagation and shared workspace database/sync remain future work. See [ADR 0003](../decisions/0003-workspaces-sessions-offline-storage.md) and [desktop verification](desktop-foundation-verification.md).

## Portable Core

Pure Go owns new portable GitHub Actions integration, workflow intelligence, pipeline/provenance tracking, artifacts/deployments, CLI and future MCP. Transport adapters call shared domain services. No CGO, mandatory backend or permanent daemon.

Current implementation: CLI version and version-only JSON-RPC. See [IPC v1](ipc.md).

Target: shared workspace config/database/index/sync/environment services in Go, with native access bridges. One logical runtime/DB writer/sync per workspaceId serves independent windows. A future app-owned service process can last for the app session without becoming a permanent daemon. Current one-request version IPC does not provide that lifecycle/events contract.

## Target Organization

```text
apps/macos/          # native SwiftUI app and Xcode project
core/cmd/runnir/     # CLI composition and commands
core/internal/      # domain services and transport adapters as implemented
docs/architecture/
docs/ai/
docs/mcp/
docs/roadmap/
```

The Xcode project and native sources live in `apps/macos/`; the Go Core stays in `core/`. Create modules when they contain behavior, not empty placeholders.

## Security Boundaries

Keychain owns desktop credentials. Local stdio does not grant filesystem scope or authority. Future repository tools require explicit, enforced grants; MCP and AI cannot self-approve mutations. Treat workflow/log text as untrusted data. A signed macOS helper inherits the app sandbox; development builds currently disable signing, so signed sandbox enforcement remains a distribution verification requirement.

Optional external AI requires explicit provider/data consent. Offers are a separate opt-in public catalog with local matching, not a repository upload service. See [startup integrations](../product/startup-integrations.md).

## Build And Distribution

Bundle the matching Go executable (universal for universal apps). Core cross-builds target darwin/linux/windows on arm64/amd64 with CGO disabled. Native tests are configured for macOS/Linux/Windows; these do not yet prove execution on every target architecture. Tagged releases publish unsigned draft app and Core artifacts. Signing, notarization and secure app updates remain planned.
