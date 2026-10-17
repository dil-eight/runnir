# Native Desktop + Go Core Template

Planning template aligned with ADR 0002; current Xcode paths remain at root.

UI development should use named, fixture-backed SwiftUI previews and optionally a separate native component catalog when needed. See [macOS UI development](../development/macos-ui-workflow.md); neither previews nor a catalog are currently implemented.

Current scope is [MVP v0.1](../product/specification.md): Dashboard, Repositories, Runs, Local Workspace and Settings. Existing workflow/artifact sections need not be removed. AI and MCP are future extension points, not template bootstrap requirements.

Swift 6/SwiftUI/Observation own presentation, Apple Intelligence integration, Keychain, notifications and IPC process lifecycle. Go owns portable CI/CD domain logic, CLI and future MCP. Use stdio JSON-RPC, separate transport protocols, pure Go where practical, and no embedded CGO.

Target native modules: App lifecycle/window/session/registry/access bridges, Features/WorkspaceManager, Dashboard, Repositories, Workflows, Runs, LocalWorkspace, Environments, Settings, IPC and DesignSystem. Target Core services: config, persistence/index/sync, environments, github, workflows, artifacts, security and ipc; later pipelines/MCP/model orchestration remain scoped future work. Create modules when implemented; no empty directory bootstrap or wholesale source relocation.

Cold launch routes through a transient native splash to restored workspace windows or singleton Workspace Manager. Dashboard is the default workspace tab. Chat remains future v0.3. Target WindowState is per window; shared WorkspaceRuntime owns config/SQLite/sync/environments, with native lifecycle/Keychain/access bridges and portable Go services. See [ADR 0003](../decisions/0003-workspaces-sessions-offline-storage.md).

Portable .runnir config/launch presets are optional and read-only on open. Session/registry/DB/private overrides live under resolved Application Support, never the working tree or temporary folders. No live execution restores from window/session state.

Future provider and tool contracts must support typed intents, availability, scoped data consent, evidence and action proposals. Core validates permission and approval outside the model before state changes. Keep repository-scoped credentials out of prompts and tool outputs.

Required checks scale with implementation: IPC compatibility/lifecycle, GitHub contract parity, Keychain, scope denial, action approval, workflow fixtures, provenance, provider availability and release/update integrity.

Build/test macOS with the commands in AGENTS.md. Xcode bundles Core through scripts/build-core-macos.sh; Go must be installed for development. Run Go test/vet/build from core. CI also checks formatting, vulnerabilities and target compilation. Production signing and updates require separate verification.
