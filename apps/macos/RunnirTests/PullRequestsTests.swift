import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct PullRequestsTests {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pulls-" + UUID().uuidString, isDirectory: true)
    }

    private func pr(_ number: Int64, state: String = "open", ci: CorePullRequestCI = .passed) -> CorePullRequest {
        CorePullRequest(repository: "o/r", number: number, title: "PR \(number)", htmlURL: URL(string: "https://github.com/o/r/pull/\(number)"),
                        state: state, draft: false, headBranch: "b", updatedAt: Date(), closedAt: state == "open" ? nil : Date(),
                        ci: ci, ciRuns: 1, ciFailed: ci == .failed ? 1 : 0, ciRunning: ci == .running ? 1 : 0, ciURL: nil)
    }

    private func readyHub() async -> (CoreHub, FakeProvider) {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.status == .ready(version: "fake") }
        return (hub, provider)
    }

    @Test func closedPullRequestsCanBeRemovedAndStayRemoved() async throws {
        let folder = directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (hub, provider) = await readyHub()
        provider.core.pullRequestsResult = CorePullRequests(access: .ok, open: [pr(1, ci: .failed), pr(2, ci: .running)],
                                                            closed: [pr(3, state: "merged"), pr(4, state: "closed")], headsUnreadable: false)
        let model = PullRequestsModel(store: FileDismissedPullRequestsStore(directory: folder))
        await model.refresh(hub: hub)
        #expect(model.open.count == 2 && model.closed.map(\.number) == [3, 4])
        #expect(model.worstCI == .failed)
        let since = try #require(provider.core.pullRequestCalls.first)
        #expect(abs(since.timeIntervalSinceNow + 24 * 3600) < 60, "closed ones from the last day")

        model.dismiss(model.closed[0])
        #expect(model.closed.map(\.number) == [4])
        // The next launch still leaves it out.
        let restarted = PullRequestsModel(store: FileDismissedPullRequestsStore(directory: folder))
        await restarted.refresh(hub: hub)
        #expect(restarted.closed.map(\.number) == [4])
        restarted.restoreDismissed()
        #expect(restarted.closed.map(\.number) == [3, 4])
    }

    @Test func signingOutClearsAndAFailedReadKeeps() async {
        let (hub, provider) = await readyHub()
        provider.core.pullRequestsResult = CorePullRequests(access: .ok, open: [pr(1)], closed: [], headsUnreadable: true)
        let model = PullRequestsModel(store: nil)
        await model.refresh(hub: hub)
        #expect(model.open.count == 1 && model.headsUnreadable && model.worstCI == .passed)

        provider.core.pullRequestsResult = .failed(.unavailable)
        await model.refresh(hub: hub)
        #expect(model.open.count == 1 && model.access == .unavailable)

        provider.core.pullRequestsResult = .failed(.signedOut)
        await model.refresh(hub: hub)
        #expect(model.open.isEmpty && model.loadedAt == nil)
    }

    @Test func aFreshListIsNotReadAgainWhenTheMenuOpens() async {
        let (hub, provider) = await readyHub()
        provider.core.pullRequestsResult = CorePullRequests(access: .ok, open: [], closed: [], headsUnreadable: false)
        let model = PullRequestsModel(store: nil)
        await model.refreshIfStale(hub: hub)
        await model.refreshIfStale(hub: hub)
        #expect(provider.core.pullRequestCalls.count == 1)
        model.now = { Date().addingTimeInterval(120) }
        await model.refreshIfStale(hub: hub)
        #expect(provider.core.pullRequestCalls.count == 2)
    }

    // MARK: Shortcut

    @Test func shortcutsShowAndNeedACommandKey() throws {
        #expect(KeyShortcut.pullRequestsDefault.display == "⌥⌘R")
        let typed = try #require(KeyShortcut(keyCode: UInt16(kVK_ANSI_P), flags: [.command, .shift], characters: "p"))
        #expect(typed.display == "⇧⌘P" && typed.keyCode == UInt32(kVK_ANSI_P))
        #expect(KeyShortcut(keyCode: UInt16(kVK_ANSI_P), flags: [.shift], characters: "p") == nil, "Shift alone is typing")
        #expect(KeyShortcut(keyCode: UInt16(kVK_ANSI_P), flags: [], characters: "p") == nil)
        #expect(KeyShortcut(keyCode: UInt16(kVK_F5), flags: [.control], characters: nil)?.display == "⌃F5")
    }

    @Test func conflictsWithMacOSAndRunnirMenusAreFound() {
        let menu = NSMenu()
        let file = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        file.submenu = NSMenu(title: "File")
        file.submenu?.addItem(NSMenuItem(title: "Open Workspace...", action: nil, keyEquivalent: "n"))
        menu.addItem(file)

        let openWorkspace = KeyShortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey), key: "N")
        #expect(ShortcutConflicts.find(openWorkspace, system: [], menu: menu) == ["Runnir's “Open Workspace...” menu command uses ⌘N."])

        let spotlight = KeyShortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey), key: "Space")
        let system = [ShortcutConflicts.SystemHotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey))]
        #expect(ShortcutConflicts.find(spotlight, system: system, menu: menu).first?.hasPrefix("macOS uses ⌘Space") == true)

        #expect(ShortcutConflicts.find(.pullRequestsDefault, system: system, menu: menu).isEmpty)
    }

    @Test func theShortcutIsOnByDefaultAndSaved() throws {
        let suite = "shortcut-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(PullRequestShortcutSettings.enabled(in: defaults))
        #expect(PullRequestShortcutSettings.shortcut(in: defaults) == .pullRequestsDefault)
        let custom = KeyShortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(cmdKey | controlKey), key: "P")
        PullRequestShortcutSettings.save(custom, in: defaults)
        #expect(PullRequestShortcutSettings.shortcut(in: defaults) == custom)
    }
}
