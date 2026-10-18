# Architecture Overview

Runnir is a local-first CI/CD platform with a native SwiftUI desktop and a portable Go Core. [ADR 0002](../decisions/0002-swiftui-go-core.md) defines the accepted boundary; [gap analysis](gap-analysis.md) records existing capabilities and remaining work.

MVP v0.1 focuses on GitHub Actions and local workflows, plus [native workspace/window lifecycle](desktop-lifecycle.md) and [offline persistence/config/sync](workspace-persistence.md), per the [current specification](../product/specification.md). Splash routes to restored workspace windows or Workspace Manager; Dashboard is the initial workspace tab. AI/chat/MCP and cloud/referral work remain future extensions.

## Desktop

Swift 6, SwiftUI and Observation own presentation, dashboards, local workspace, approvals and Keychain. Native notifications, chat and model/provider orchestration are later capabilities. Foundation Process manages the bundled Core executable. The existing Swift GitHub client remains during incremental migration.

Swift/AppKit now owns startup routing, the singleton Manager, independent workspace windows, scoped folder grants and a versioned local registry/session through DesktopCoordinator and FileDesktopStateStore. Each workspace window owns its AppState and local file selection. Shared account propagation and shared workspace database/sync remain future work. See [ADR 0003](../decisions/0003-workspaces-sessions-offline-storage.md) and [desktop verification](desktop-foundation-verification.md).

## Portable Core

Pure Go owns new portable GitHub Actions integration, workflow intelligence, pipeline/provenance tracking, artifacts/deployments, CLI and future MCP. Transport adapters call shared domain services. No CGO, mandatory backend or permanent daemon.

Current implementation: the CLI (`version`, `serve`), a version-only JSON-RPC handshake ([IPC v1](ipc.md)), and a local gRPC API over a Unix socket served by one app-owned Core process: repository open, close and refresh, workflow listing, an event stream and execution scheduling with a stub runner ([gRPC API v1](grpc-api.md), [ADR 0004](../decisions/0004-single-core-process-grpc.md)). There is no GitHub integration, workflow validation or real execution engine in the Core yet.

Target: shared workspace config/database/index/sync/environment services in Go, with native access bridges. One logical runtime/DB writer/sync per workspaceId serves independent windows. The app-owned service process now exists: it lasts for the app session, serves every window and is not a permanent daemon. Repository contexts and events are shared across windows; the database and sync writer are not implemented.

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

Keychain owns desktop credentials. Neither the local socket nor stdio grants filesystem scope or authority, and the Core socket currently has no per-client access control (see [gRPC API](grpc-api.md#security-model-today)). Future repository tools require explicit, enforced grants; MCP and AI cannot self-approve mutations. Treat workflow/log text as untrusted data. A signed macOS helper inherits the app sandbox; development builds currently disable signing, so signed sandbox enforcement remains a distribution verification requirement.

Optional external AI requires explicit provider/data consent. Offers are a separate opt-in public catalog with local matching, not a repository upload service. See [startup integrations](../product/startup-integrations.md).

## Build And Distribution

Bundle the matching Go executable (universal for universal apps). Core cross-builds target darwin/linux/windows on arm64/amd64 with CGO disabled. Native tests are configured for macOS/Linux/Windows; these do not yet prove execution on every target architecture. Tagged releases publish unsigned draft app and Core artifacts. Signing, notarization and secure app updates remain planned.
