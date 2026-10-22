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

    @Test func pollingReadsSoonAfterSignInAndClearsOnSignOut() async {
        let (hub, provider) = await readyHub()
        provider.core.pullRequestsResult = CorePullRequests(access: .ok, open: [pr(1, ci: .failed)], closed: [], headsUnreadable: false)
        let model = PullRequestsModel(store: nil)
        var signedIn = false
        model.startPolling(hub: hub, retry: .milliseconds(20)) { signedIn }
        defer { model.stopPolling() }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(provider.core.pullRequestCalls.isEmpty, "nothing is read while signed out")

        signedIn = true
        #expect(await eventually { model.worstCI == .failed }, "the first read does not wait three minutes")
        #expect(provider.core.pullRequestCalls.count == 1)

        signedIn = false
        #expect(await eventually { model.open.isEmpty && model.worstCI == nil })
    }

    // MARK: Shortcut

    @Test func shortcutsShowAndNeedACommandKey() throws {
        #expect(KeyShortcut.pullRequestsDefault.display == "⌥⌘R")
        let typed = try #require(KeyShortcut(keyCode: UInt16(kVK_ANSI_P), flags: [.command, .shift], characters: "p"))
        #expect(typed.display == "⇧⌘P" && typed.keyCode == UInt32(kVK_ANSI_P))
        #expect(KeyShortcut(keyCode: UInt16(kVK_ANSI_P), flags: [.shift], characters: "p") == nil, "Shift alone is typing")
        #expect(KeyShortcut(keyCode: UInt16(kVK_ANSI_P), flags: [], characters: "p") == nil)
        #expect(KeyShortcut(keyCode: UInt16(kVK_F5), flags: [.control], characters: nil)?.display == "⌃F5")
        // By key position, whatever the layout types.
        #expect(KeyShortcut(keyCode: UInt16(kVK_ANSI_R), flags: [.command, .option], characters: "к") == .pullRequestsDefault)
        #expect(KeyShortcut(keyCode: UInt16(kVK_ANSI_2), flags: [.command, .shift], characters: "@")?.display == "⇧⌘2")
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

    @Test func aShortcutAlreadyRegisteredIsRefusedWithAReason() {
        let unusual = KeyShortcut(keyCode: UInt32(kVK_F12), modifiers: UInt32(controlKey | optionKey | shiftKey), key: "F12")
        let first = GlobalShortcutCenter()
        let second = GlobalShortcutCenter()
        first.apply(enabled: true, shortcut: unusual)
        defer { first.apply(enabled: false, shortcut: unusual) }
        #expect(first.status == .registered(unusual))
        second.apply(enabled: true, shortcut: unusual)
        #expect(second.status == .unavailable("Another app already uses ⌃⌥⇧F12. Choose another shortcut."))
        second.apply(enabled: false, shortcut: unusual)
        #expect(second.status == .off)
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

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RunNotificationTests {
    private func pr(_ number: Int64, ci: CorePullRequestCI, runs: Int = 3, failed: Int = 0) -> CorePullRequest {
        CorePullRequest(repository: "o/r", number: number, title: "Fix it", htmlURL: URL(string: "https://github.com/o/r/pull/\(number)"),
                        state: "open", draft: false, headBranch: "b", updatedAt: Date(), closedAt: nil, ci: ci,
                        ciRuns: runs, ciFailed: failed, ciRunning: ci == .running ? 1 : 0, ciURL: URL(string: "https://github.com/o/r/actions/runs/9"))
    }

    @Test func onlyChecksThatWereRunningAndFinishedAreReported() async {
        let (hub, provider) = await makeReadyHub()
        let model = PullRequestsModel(store: nil)
        var finished: [Int64] = []
        model.onChecksFinished = { finished.append($0.number) }
        // The first read reports nothing, whatever the checks say.
        provider.core.pullRequestsResult = CorePullRequests(access: .ok, open: [pr(1, ci: .running), pr(2, ci: .passed), pr(3, ci: .running)],
                                                            closed: [], headsUnreadable: false)
        await model.refresh(hub: hub)
        #expect(finished.isEmpty)
        // 1 failed, 2 stays passed, 3 still runs.
        provider.core.pullRequestsResult = CorePullRequests(access: .ok, open: [pr(1, ci: .failed, failed: 1), pr(2, ci: .passed), pr(3, ci: .running)],
                                                            closed: [], headsUnreadable: false)
        await model.refresh(hub: hub)
        #expect(finished == [1])
        // 3 passes; 1 is not reported again.
        provider.core.pullRequestsResult = CorePullRequests(access: .ok, open: [pr(1, ci: .failed, failed: 1), pr(2, ci: .passed), pr(3, ci: .passed)],
                                                            closed: [], headsUnreadable: false)
        await model.refresh(hub: hub)
        #expect(finished == [1, 3])
    }

    @Test func notificationsSayWhatFinished() throws {
        let failed = try #require(RunNotification.checksFinished(pr(34, ci: .failed, runs: 3, failed: 1)))
        #expect(failed.title == "Checks failed · o/r #34" && failed.body == "Fix it — 1 of 3 checks failed." && !failed.succeeded)
        #expect(failed.url?.absoluteString == "https://github.com/o/r/actions/runs/9", "a failure opens the failed run")
        let passed = try #require(RunNotification.checksFinished(pr(31, ci: .passed, runs: 4)))
        #expect(passed.title == "Checks passed · o/r #31" && passed.body == "Fix it — all 4 checks passed." && passed.succeeded)
        #expect(RunNotification.checksFinished(pr(1, ci: .running)) == nil)
        #expect(RunNotification.duration(48) == "48 s" && RunNotification.duration(72) == "1 min 12 s" && RunNotification.duration(120) == "2 min")
    }

    @Test func aLocalRunReportsOnceWhenItFinishes() throws {
        let plan = CoreLocalRunPlan(workflowID: ".github/workflows/ci.yml", workflowName: "CI", jobID: "test",
                                    jobs: [CoreLocalRunJob(id: "test", name: "test", support: .supported)])
        let run = LocalRunModel(executionID: "e1", workspaceID: UUID(), plan: plan)
        var reports = 0
        run.onFinish = { _ in reports += 1 }
        let start = Date(timeIntervalSince1970: 1000)
        func output(_ phase: CoreLocalRunPhase, _ state: CoreExecutionState, exit: Int?) -> CoreLocalRunOutput {
            CoreLocalRunOutput(executionID: "e1", repositoryID: "r", state: state, phase: phase, lines: [], discarded: false, lastSequence: 0,
                               jobs: [], plan: plan, startedAt: start, finishedAt: phase == .finished ? start.addingTimeInterval(48) : nil,
                               exitCode: exit, message: nil, cleanupProblem: nil)
        }
        run.apply(output(.running, .running, exit: nil))
        #expect(reports == 0)
        run.apply(output(.finished, .failed, exit: 1))
        run.apply(output(.finished, .failed, exit: 1))
        #expect(reports == 1)
        let note = try #require(RunNotification.localRunFinished(run, workspaceName: "runnir"))
        #expect(note.title == "Local run failed · runnir" && note.body == "CI › test stopped after 48 s: the job exited with code 1.")
        #expect(note.workspaceID == run.workspaceID)
    }

    @Test func settingsChooseWhatIsSent() throws {
        let suite = "notify-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var sent: [String] = []
        let notifier = RunNotifier(defaults: defaults) { sent.append($0.id) }
        let failed = RunNotification.checksFinished(pr(1, ci: .failed, failed: 1))
        let passed = RunNotification.checksFinished(pr(2, ci: .passed))
        notifier.notify(failed)
        notifier.notify(passed)
        #expect(sent.count == 2, "both kinds, successes and failures, by default")
        defaults.set(true, forKey: NotificationSettings.failuresOnlyKey)
        notifier.notify(passed)
        #expect(sent.count == 2)
        defaults.set(false, forKey: NotificationSettings.pullRequestChecksKey)
        notifier.notify(failed)
        #expect(sent.count == 2)
    }
}
