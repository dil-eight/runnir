import Foundation
@testable import Runnir

/// Polls a main-actor condition for up to four seconds.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

/// Polls an asynchronous condition for up to ten seconds.
func eventuallyAsync(_ condition: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}

/// A folder in the temporary directory that does not exist yet.
func temporaryFolder(_ prefix: String = "") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
}

/// A hub on a fake Core that is ready; `configure` sets the fake up first.
@MainActor
func makeReadyHub(_ configure: (FakeCore) -> Void = { _ in }) async -> (CoreHub, FakeProvider) {
    let provider = FakeProvider()
    configure(provider.core)
    let hub = CoreHub(provider: provider)
    hub.startMonitoring()
    provider.ready()
    _ = await eventually { hub.status == .ready(version: "fake") }
    return (hub, provider)
}

/// Opens a workspace of `path` in the hub and waits until its session
/// passes `ready`.
@MainActor
func attachWorkspace(_ hub: CoreHub, path: String, until ready: @MainActor (RepositorySession) -> Bool) async -> UUID {
    let workspace = UUID()
    hub.attach(windowID: UUID(), workspaceID: workspace, path: path)
    _ = await eventually { hub.session(for: workspace).map(ready) ?? false }
    return workspace
}

/// A ready hub with one open workspace, backed by the provider's fake Core.
@MainActor
func makeWorkspaceHub(_ configure: (FakeCore) -> Void = { _ in }) async -> (CoreHub, UUID, FakeCore) {
    let (hub, provider) = await makeReadyHub(configure)
    let workspace = await attachWorkspace(hub, path: "/repo/a") { $0.phase == .ready }
    return (hub, workspace, provider.core)
}

/// A ready hub with one workspace linked to GitHub, on branch "feature",
/// whose run lookups are quick.
@MainActor
func makeLinkedHub(_ configure: (FakeCore) -> Void = { _ in }) async -> (CoreHub, FakeProvider, UUID) {
    let (hub, provider) = await makeReadyHub {
        $0.setBranch("feature", for: "/repo/linked")
        configure($0)
    }
    hub.runLookupInterval = .milliseconds(10)
    hub.runLookupTimeout = .milliseconds(300)
    let workspace = await attachWorkspace(hub, path: "/repo/linked") { $0.githubAccess == .ok }
    return (hub, provider, workspace)
}
