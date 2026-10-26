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

/// A throwaway UserDefaults suite; call `remove` when the test ends.
struct TestDefaults {
    let name = "runnir-tests-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: name)! }
    func remove() { UserDefaults().removePersistentDomain(forName: name) }
}

@MainActor
@Suite struct CacheFirstHubTests {
    private func readyHub(defaults: UserDefaults? = nil) async -> (CoreHub, FakeProvider) {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        if let defaults { hub.storageDefaults = defaults }
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

    @Test func moreRunsComeFromTheCacheThenFromGitHub() async {
        let (hub, provider) = await readyHub()
        let runs = (1...200).map { run(Int64($0)) }
        let fresh = CoreActivityFreshness(source: .live, access: .ok)
        provider.core.setActivity(CoreWorkspaceActivity(runs: runs, workflows: [], freshness: fresh, cachedRuns: 250), for: "/repo/linked")
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.cachedRuns == 250 })
        #expect(provider.core.activityLimits.allSatisfy { $0 == 200 })
        // 250 are cached: the next read asks for 400, and nothing goes to GitHub.
        await hub.showMoreRuns(workspaceID: workspace)
        #expect(provider.core.activityLimits.last == 400)
        #expect(provider.core.olderRunsCalls.isEmpty)
        // Every cached run is shown and GitHub has older ones: one page from GitHub.
        provider.core.setActivity(CoreWorkspaceActivity(runs: runs, workflows: [], freshness: fresh, cachedRuns: 200), for: "/repo/linked")
        provider.core.olderRunsResult = CoreOlderRuns(access: .ok, added: 100, historyComplete: false, budgetReached: false)
        await hub.showMoreRuns(workspaceID: workspace) // reads again from the cache: 200 cached
        await hub.showMoreRuns(workspaceID: workspace)
        #expect(provider.core.olderRunsCalls.count == 1)
        #expect(hub.session(for: workspace)?.olderRuns == .idle)
    }

    @Test func searchingReadsEverySavedRunAndNeverAsksGitHub() async {
        let (hub, provider) = await readyHub()
        let runs = (1...200).map { run(Int64($0)) }
        let fresh = CoreActivityFreshness(source: .live, access: .ok)
        provider.core.setActivity(CoreWorkspaceActivity(runs: runs, workflows: [], freshness: fresh, cachedRuns: 1200), for: "/repo/linked")
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.cachedRuns == 1200 })
        let refreshes = provider.core.activityRefreshes.count

        await hub.loadSavedRuns(workspaceID: workspace)
        #expect(provider.core.activityLimits.last == 1200, "every saved run, in one read from the cache")
        #expect(provider.core.olderRunsCalls.isEmpty)
        #expect(provider.core.activityRefreshes.count == refreshes, "no pass over GitHub")

        let reads = provider.core.activityLimits.count
        await hub.loadSavedRuns(workspaceID: workspace)
        #expect(provider.core.activityLimits.count == reads, "once is enough")
    }

    @Test func searchingNeverAsksForMoreThanTheBudget() async {
        let (hub, provider) = await readyHub()
        let fresh = CoreActivityFreshness(source: .live, access: .ok)
        provider.core.setActivity(CoreWorkspaceActivity(runs: [run(1)], workflows: [], freshness: fresh, cachedRuns: 9000), for: "/repo/linked")
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.cachedRuns == 9000 })
        await hub.loadSavedRuns(workspaceID: workspace)
        #expect(provider.core.activityLimits.last == CoreHub.maxActivityLimit)
    }

    @Test func olderRunsSayWhenGitHubFailsAndWhenTheBudgetIsReached() async {
        let (hub, provider) = await readyHub()
        provider.core.setActivity(CoreWorkspaceActivity(runs: [run(1)], workflows: [], freshness: CoreActivityFreshness(source: .live, access: .ok),
                                                        cachedRuns: 1), for: "/repo/linked")
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.runs.count == 1 })
        provider.core.olderRunsResult = CoreOlderRuns(access: .unavailable, added: 0, historyComplete: false, budgetReached: false)
        await hub.showMoreRuns(workspaceID: workspace)
        #expect(hub.session(for: workspace)?.olderRuns == .failed(.unavailable))
        provider.core.olderRunsResult = CoreOlderRuns(access: .ok, added: 0, historyComplete: false, budgetReached: true)
        await hub.showMoreRuns(workspaceID: workspace) // Retry
        #expect(hub.session(for: workspace)?.olderRuns == .budgetReached)
        await hub.showMoreRuns(workspaceID: workspace)
        #expect(provider.core.olderRunsCalls.count == 2, "nothing more is asked once the budget is reached")
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
        let suite = TestDefaults()
        defer { suite.remove() }
        suite.defaults.set(true, forKey: StorageSettings.keepJobLogsKey)
        let (_, provider) = await readyHub(defaults: suite.defaults)
        #expect(await eventually { provider.core.storagePreferences.first?.keep == true })
        #expect(provider.core.storagePreferences.first?.delete == false)
    }

    @Test func aLogDeletionTheCoreMissedIsSentAtItsNextStart() async {
        let suite = TestDefaults()
        defer { suite.remove() }
        let (hub, provider) = await readyHub(defaults: suite.defaults)
        #expect(await eventually { provider.core.storagePreferences.count == 1 })
        provider.core.storagePreferencesError = .unavailable
        let model = StorageSettingsModel(hub: hub, workspaces: { [] }, defaults: suite.defaults)
        await model.setKeepJobLogs(false)
        #expect(provider.core.storagePreferences.last?.delete == true)
        #expect(suite.defaults.bool(forKey: StorageSettings.logDeletionPendingKey), "still pending after the failed call")

        provider.core.storagePreferencesError = nil
        provider.ready() // a new Core
        #expect(await eventually { !suite.defaults.bool(forKey: StorageSettings.logDeletionPendingKey) })
        #expect(provider.core.storagePreferences.last.map { !$0.keep && $0.delete } == true)
    }

    @Test func deletingDataWaitsForTheLastWindowsClose() async {
        let (hub, provider) = await readyHub()
        provider.core.closeDelay = .milliseconds(200)
        let workspace = UUID(), window = UUID()
        hub.attach(windowID: window, workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })
        hub.detach(windowID: window)
        // Removing the registration right away: the Core is still closing.
        #expect(await hub.deleteWorkspaceData(workspace))
        #expect(provider.core.deletedData == [workspace])
    }

    @Test func aCacheReadEndingDoesNotEndAReload() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready && provider.core.activityReads.count == 1 })
        provider.core.holdActivityRefresh = true
        let reload = Task { await hub.loadGitHubActivity(workspaceID: workspace) }
        #expect(await eventually { provider.core.activityRefreshes.count == 1 })
        provider.core.push(coreEvent(.activityChanged, repository: FakeCore.id(for: "/repo/linked"), sequence: 60))
        #expect(await eventually { provider.core.activityReads.count == 2 })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(hub.session(for: workspace)?.isLoadingGitHub == true, "the Reload is still waiting")
        provider.core.holdActivityRefresh = false
        await reload.value
        #expect(hub.session(for: workspace)?.isLoadingGitHub == false)
    }

    @Test func aRejectionOlderThanTheTokenHeldDoesNotSignOut() async {
        let (hub, provider) = await readyHub()
        var rejected = 0
        hub.onGitHubTokenRejected = { rejected += 1 }
        #expect(await eventually { !provider.core.serverCredentialCalls.isEmpty })
        try? await Task.sleep(for: .milliseconds(20))
        // Saved before the token now held was handed over.
        provider.core.setActivity(CoreWorkspaceActivity(runs: [run(7)], workflows: [],
            freshness: CoreActivityFreshness(source: .live, access: .tokenRejected, checkedAt: Date(timeIntervalSinceNow: -3600))), for: "/repo/linked")
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.githubAccess == .tokenRejected })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rejected == 0)
    }
}

@Suite struct FreshnessTextTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func eachStateHasItsLine() {
        typealias F = CoreActivityFreshness
        #expect(ActivityFreshnessText.line(F(source: .none, syncing: true), now: now) == "Loading activity…")
        #expect(ActivityFreshnessText.line(F(source: .live, syncing: true, access: .ok), now: now) == "Refreshing…")
        #expect(ActivityFreshnessText.line(F(source: .cache, syncedAt: now.addingTimeInterval(-7200)), now: now)
            == "Showing saved activity · synced 2 hours ago")
        #expect(ActivityFreshnessText.line(F(source: .live, access: .ok, checkedAt: now.addingTimeInterval(-60),
                                              syncedAt: now.addingTimeInterval(-60), changedAt: now.addingTimeInterval(-60)), now: now)
            == "Up to date · checked 1 minute ago")
        #expect(ActivityFreshnessText.line(F(source: .live, access: .ok, checkedAt: now.addingTimeInterval(-2),
                                              syncedAt: now.addingTimeInterval(-2), changedAt: now.addingTimeInterval(-3600)), now: now)
            == "No changes since 1 hour ago · checked just now")
        #expect(ActivityFreshnessText.line(F(source: .live, access: .unavailable, syncedAt: now.addingTimeInterval(-600)), now: now)
            == "Showing activity from 10 minutes ago")
        #expect(ActivityFreshnessText.line(F(), now: now) == nil)
        // A change seconds before the last answer is "up to date", not "no changes since just now".
        #expect(ActivityFreshnessText.line(F(source: .live, access: .ok, checkedAt: now.addingTimeInterval(-2),
                                              syncedAt: now.addingTimeInterval(-2), changedAt: now.addingTimeInterval(-20)), now: now)
            == "Up to date · checked just now")
    }
}

@Suite struct BugReportTests {
    let draft = BugReportDraft(appVersion: "0.1.0 (7)", coreVersion: "0.1.0", macOSVersion: "27.2", architecture: "arm64")

    @Test func theDraftOpensANewIssueWithTheEnvironmentOnly() throws {
        let components = try #require(URLComponents(url: draft.url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https" && components.host == "github.com" && components.path == "/dil-eight/runnir/issues/new")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(items["title"] == "[Bug] ")
        let body = try #require(items["body"])
        #expect(body.contains("- Runnir version/build: 0.1.0 (7)"))
        #expect(body.contains("- Core version (if known): 0.1.0"))
        #expect(body.contains("- macOS major/minor version: 27.2"))
        #expect(body.contains("- Architecture (arm64/amd64): arm64"))
        #expect(body.contains("## Privacy Check"))
        #expect(!body.contains("/Users") && !body.contains(NSHomeDirectory()))
    }

    @Test func anUnknownCoreSaysSo() {
        let offline = BugReportDraft(appVersion: "0.1.0", coreVersion: nil, macOSVersion: "27.2", architecture: "x86_64")
        #expect(offline.environment[1] == "- Core version (if known): unknown")
    }

    @Test func theCurrentDraftReadsThisMac() {
        let current = BugReportDraft.current(coreVersion: "1.2.3")
        #expect(current.coreVersion == "1.2.3")
        #expect(current.macOSVersion.split(separator: ".").count == 2)
        #expect(["arm64", "x86_64"].contains(current.architecture))
    }
}

@MainActor
@Suite struct WorkspaceBadgeTests {
    @Test func theBadgeShowsTheFirstLetterInAStableColor() {
        let id = UUID(uuidString: "5CE88FF0-5C16-43B3-8F20-8E33E852B019")!
        #expect(WorkspaceBadge.initial("runnir") == "R")
        #expect(WorkspaceBadge.initial("") == "?")
        #expect(WorkspaceBadge.colorIndex(id) == WorkspaceBadge.colorIndex(id))
        #expect((0..<WorkspaceBadge.palette.count).contains(WorkspaceBadge.colorIndex(id)))
    }
}

@MainActor
@Suite struct StorageSettingsTests {
    private func workspace(_ name: String) -> WorkspaceRecord {
        WorkspaceRecord(id: UUID(), path: "/repo/\(name)", name: name, bookmark: Data(), lastOpenedAt: Date())
    }

    private func storage(_ id: UUID) -> CoreWorkspaceStorage {
        CoreWorkspaceStorage(workspaceID: id, state: .persistent, note: nil, isOpen: false, databaseBytes: 4096,
                             logBytes: 0, cachedRuns: 3, localRuns: 1, recoveryCopies: 0)
    }

    @Test func registeredAndRemovedWorkspacesAreListedAndCleared() async {
        let suite = TestDefaults()
        defer { suite.remove() }
        let defaults = suite.defaults
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.storageDefaults = defaults
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.status == .ready(version: "fake") }
        _ = await eventually { provider.core.storagePreferences.count == 1 } // the push at Core start
        let kept = workspace("kept"), empty = workspace("empty")
        let removed = UUID()
        provider.core.storage = CoreStorageUsage(workspaces: [storage(kept.id), storage(removed)], keepJobLogs: false)
        let model = StorageSettingsModel(hub: hub, workspaces: { [kept, empty] }, defaults: defaults)
        await model.load()
        #expect(model.rows.map(\.name) == ["empty", "kept", "Removed workspace"])
        #expect(model.rows.first { $0.id == empty.id }?.storage == nil)
        #expect(model.rows.first { $0.id == removed }?.isRegistered == false)
        let keptStorage = model.rows.first(where: { $0.id == kept.id })?.storage
        let summary = StorageSettingsModel.summary(keptStorage)
        #expect(summary.hasPrefix("3 saved runs · 1 local run"))

        await model.clear([kept.id])
        #expect(provider.core.clearedCaches == [[kept.id]])
        await model.clearAll()
        #expect(provider.core.clearedCaches.last == [])
        await model.delete(removed)
        #expect(provider.core.deletedData == [removed])

        await model.setKeepJobLogs(true)
        #expect(defaults.bool(forKey: StorageSettings.keepJobLogsKey))
        await model.setKeepJobLogs(false)
        #expect(provider.core.storagePreferences.dropFirst().map(\.keep) == [true, false])
        #expect(provider.core.storagePreferences.last?.delete == true, "turning it off deletes kept logs")
        #expect(!defaults.bool(forKey: StorageSettings.keepJobLogsKey))
        #expect(!defaults.bool(forKey: StorageSettings.logDeletionPendingKey), "the Core confirmed the deletion")
    }
}
