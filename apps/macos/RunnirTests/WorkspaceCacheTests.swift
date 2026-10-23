import Foundation
import Testing
@testable import Runnir

@Suite struct CoreLaunchArgumentTests {
    @Test func theDataDirectoryIsPassedToTheCore() {
        let arguments = ProcessCoreLauncher.arguments(socketPath: "/tmp/s.sock",
                                                      dataDirectory: URL(fileURLWithPath: "/Users/me/Library/Application Support/Runnir"))
        #expect(arguments == ["serve", "--socket", "/tmp/s.sock", "--exit-on-stdin-eof", "--client-secret-stdin",
                              "--data-dir", "/Users/me/Library/Application Support/Runnir"])
        #expect(!ProcessCoreLauncher.arguments(socketPath: "/tmp/s.sock", dataDirectory: nil).contains("--data-dir"))
    }
}

@MainActor
@Suite struct CacheFirstHubTests {
    private func readyHub(keepJobLogs: Bool = false) async -> (CoreHub, FakeProvider) {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.keepJobLogs = { keepJobLogs }
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.status == .ready(version: "fake") }
        _ = await eventually { provider.core.subscriptions >= 1 }
        return (hub, provider)
    }

    private func run(_ id: Int64) -> CoreWorkflowRun {
        CoreWorkflowRun(id: id, workflowID: 1, name: "CI", displayTitle: "Change \(id)", runNumber: id, event: "push",
                        status: "completed", conclusion: "success", branch: "main", headSHA: "abc", actor: nil,
                        htmlURL: nil, createdAt: Date(), updatedAt: Date())
    }

    @Test func savedActivityShowsWithoutWaitingForGitHub() async {
        let (hub, provider) = await readyHub()
        provider.core.setActivity(CoreWorkspaceActivity(runs: [run(7)], workflows: [],
            freshness: CoreActivityFreshness(source: .cache, syncing: true, syncedAt: Date(timeIntervalSinceNow: -3600))), for: "/repo/linked")
        provider.core.refreshDelayActivity = .seconds(60) // GitHub never answers
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.runs.count == 1 })
        let session = hub.session(for: workspace)
        #expect(session?.activitySource == .cache)
        #expect(session?.isLoadingGitHub == true, "the Core says a pass is running")
        #expect(provider.core.activityRefreshes.isEmpty)
        #expect(provider.core.openWorkspaceIDs == [workspace])
    }

    @Test func twoWindowsShareOneSessionAndOneRead() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready && !provider.core.activityReads.isEmpty })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(provider.core.openCalls.count == 1)
        #expect(provider.core.activityReads.count == 1)
    }

    @Test func anActivityEventRereadsOnlyItsWorkspace() async {
        let (hub, provider) = await readyHub()
        let a = UUID(), b = UUID()
        hub.attach(windowID: UUID(), workspaceID: a, path: "/repo/linked")
        hub.attach(windowID: UUID(), workspaceID: b, path: "/repo/other")
        #expect(await eventually { provider.core.activityReads.count == 2 })
        provider.core.setActivity(CoreWorkspaceActivity(runs: [run(9)], workflows: [],
                                                        freshness: CoreActivityFreshness(source: .live, access: .ok)), for: "/repo/linked")
        provider.core.push(coreEvent(.activityChanged, repository: FakeCore.id(for: "/repo/linked"), sequence: 50))
        #expect(await eventually { hub.session(for: a)?.runs.first?.id == 9 })
        #expect(provider.core.activityReads.filter { $0 == FakeCore.id(for: "/repo/other") }.count == 1)
    }

    @Test func losingAccessKeepsTheRuns() async {
        let (hub, provider) = await readyHub()
        provider.core.setActivity(CoreWorkspaceActivity(runs: [run(7)], workflows: [],
            freshness: CoreActivityFreshness(source: .live, access: .signedOut, syncedAt: Date())), for: "/repo/linked")
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.githubAccess == .signedOut })
        #expect(hub.session(for: workspace)?.runs.count == 1)
    }

    @Test func reloadAsksTheCoreAndWaits() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })
        await hub.loadGitHubActivity(workspaceID: workspace)
        #expect(provider.core.activityRefreshes.last?.wait == true)
    }

    @Test func theLogsPreferenceIsSentWhenTheCoreStarts() async {
        let (_, provider) = await readyHub(keepJobLogs: true)
        #expect(await eventually { provider.core.storagePreferences.first?.keep == true })
        #expect(provider.core.storagePreferences.first?.delete == false)
    }
}
