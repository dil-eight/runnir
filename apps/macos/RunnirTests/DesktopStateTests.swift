import Foundation
import AppKit
import Testing
@testable import Runnir

@MainActor
struct YAMLHighlightingTests {
    @Test func highlightingMaximumSizeScalarIsBounded() {
        let source = "value: " + String(repeating: "a", count: 512 * 1024 - 7)
        let start = Date()
        let styled = YAMLSyntaxHighlighting.highlight(source)
        #expect(Date().timeIntervalSince(start) < 2)
        #expect(String(styled.characters) == source)
        #expect(styled.runs.contains { $0.foregroundColor == RunnirTheme.syntaxKey })
    }

    @Test func anchoredHighlightingPreservesTokensAfterPlainText() {
        let source = "value: plain # comment"
        let styled = YAMLSyntaxHighlighting.highlight(source)
        #expect(String(styled.characters) == source)
        #expect(styled.runs.contains { $0.foregroundColor == RunnirTheme.mutedForeground })
        let numeric = YAMLSyntaxHighlighting.highlight("timeout: 30")
        #expect(numeric.runs.contains { $0.foregroundColor == RunnirTheme.syntaxLiteral })
    }

    @Test func highlightsTokensWithoutChangingSourceOrConfusingQuotedComments() {
        let source = "  name: \"CI # not a comment\" # comment"
        let styled = YAMLSyntaxHighlighting.highlight(source)
        #expect(String(styled.characters) == source)
        #expect(styled.runs.contains { $0.foregroundColor == RunnirTheme.syntaxKey })
        #expect(styled.runs.contains { $0.foregroundColor == RunnirTheme.syntaxString })
        #expect(styled.runs.contains { $0.foregroundColor == RunnirTheme.mutedForeground })
        let literal = YAMLSyntaxHighlighting.highlight("enabled: true\n")
        #expect(literal.runs.contains { $0.foregroundColor == RunnirTheme.syntaxLiteral })
        #expect(String(YAMLSyntaxHighlighting.highlight("title: 'Привет 👋'").characters) == "title: 'Привет 👋'")
    }

}

@MainActor
struct ThemeTokenTests {
    @Test func everyTokenResolvesForBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for token in RunnirColorToken.allCases {
                let expected = (name == .darkAqua ? token.palette.dark : token.palette.light).nsColor
                #expect(token.resolved(for: appearance) == expected)
            }
        }
    }

    @Test func keepsPenPaletteAndUsesDistinctButtonForegrounds() {
        #expect(RunnirColorToken.background.palette.dark.rawValue == 0x181B20)
        #expect(RunnirColorToken.primary.palette.dark.rawValue == 0x7C9CFF)
        #expect(RunnirColorToken.primaryForeground.palette.light == .white)
        #expect(RunnirColorToken.primaryForeground.palette.dark == .neutral950)
    }

    @Test func bodyButtonsAndStatusTokensHaveReadableContrast() {
        for dark in [false, true] {
            func value(_ token: RunnirColorToken) -> RunnirPalette {
                dark ? token.palette.dark : token.palette.light
            }
            for token in [RunnirColorToken.foreground, .secondaryForeground, .success, .warning, .destructive, .info] {
                #expect(contrast(value(token), value(.background)) >= 4.5)
            }
            #expect(contrast(value(.primaryForeground), value(.primary)) >= 4.5)
            // A primary button is the accent at 20% (32% under the pointer)
            // over the window, as on runnir.com.
            for alpha in [0.2, 0.32] {
                let fill = blend(value(.primary), over: value(.background), alpha: alpha)
                #expect(contrast(value(.primaryButtonText), fill) >= 4.5, "primary button text at \(alpha), dark: \(dark)")
            }
            #expect(contrast(value(.secondaryContent), value(.secondary)) >= 4.5)
        }
    }

    @Test func pullRequestColorsReadInLightAndDark() {
        for dark in [false, true] {
            func pick(_ pair: (light: UInt32, dark: UInt32)) -> UInt32 { dark ? pair.dark : pair.light }
            func token(_ token: RunnirColorToken) -> UInt32 { (dark ? token.palette.dark : token.palette.light).rawValue }
            // Chip text on its tint.
            #expect(contrast(pick(PullRequestColors.runningValues), pick(PullRequestColors.runningSoftValues)) >= 4.5, "dark: \(dark)")
            #expect(contrast(token(.success), pick(PullRequestColors.passedSoftValues)) >= 4.5, "dark: \(dark)")
            #expect(contrast(token(.destructive), pick(PullRequestColors.failedSoftValues)) >= 4.5, "dark: \(dark)")
            // Icons on the popup's background.
            #expect(contrast(pick(PullRequestColors.runningValues), token(.background)) >= 3, "dark: \(dark)")
            #expect(contrast(pick(PullRequestColors.mergedValues), token(.background)) >= 3, "dark: \(dark)")
        }
    }

    private func blend(_ top: RunnirPalette, over bottom: RunnirPalette, alpha: Double) -> UInt32 {
        [16, 8, 0].reduce(UInt32(0)) { color, shift in
            let a = Double((top.rawValue >> shift) & 255), b = Double((bottom.rawValue >> shift) & 255)
            return color | (UInt32((a * alpha + b * (1 - alpha)).rounded()) << shift)
        }
    }

    private func contrast(_ first: RunnirPalette, _ second: UInt32) -> Double {
        contrast(first.rawValue, second)
    }

    private func contrast(_ first: RunnirPalette, _ second: RunnirPalette) -> Double {
        contrast(first.rawValue, second.rawValue)
    }

    private func contrast(_ first: UInt32, _ second: UInt32) -> Double {
        func luminance(_ color: UInt32) -> Double {
            let channels = [16, 8, 0].map { shift -> Double in
                let value = Double((color >> shift) & 255) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
        }
        let a = luminance(first), b = luminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

struct DesktopStateTests {
    @Test func sidebarMatchesPenWithoutRemovingLegacyDestinations() {
        #expect(AppSection.sidebarSections == [.dashboard, .workflows, .runs, .workspace])
        #expect(AppSection.dashboard.title == "Overview")
        #expect(AppSection.allCases.contains(.repositories))
        #expect(AppSection.allCases.contains(.artifacts))
    }

    @Test func aWindowSavedOnARetiredSectionOpensOnOverview() {
        #expect(AppSection.repositories.restored == .dashboard)
        #expect(AppSection.artifacts.restored == .dashboard)
        for section in AppSection.allCases where !AppSection.retired.contains(section) {
            #expect(section.restored == section)
        }
    }

    @Test func manualClosePersistsWithoutResurrectingOnReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDesktopStateStore(directory: directory)
        let workspace = WorkspaceRecord(id: UUID(), path: "/test/repo", name: "repo", bookmark: Data(), lastOpenedAt: Date())
        let first = WorkspaceWindowRecord(id: UUID(), workspaceID: workspace.id)
        let second = WorkspaceWindowRecord(id: UUID(), workspaceID: workspace.id, section: .workspace)
        var state = DesktopSnapshot(workspaces: [workspace], windows: [first, second])
        try store.save(state)
        state.closeWindow(first.id)
        try store.save(state)
        let reloaded = try store.load()
        #expect(reloaded.windows == [second])
        #expect(reloaded.workspaces == [workspace])
        state.closeWindow(second.id)
        try store.save(state)
        #expect(try store.load().windows.isEmpty)
        #expect(try store.load().workspaces.count == 1)
    }

    @Test func reassociationDoesNotChangeOtherWindow() throws {
        let a = WorkspaceRecord(id: UUID(), path: "/a", name: "a", bookmark: Data(), lastOpenedAt: Date())
        let b = WorkspaceRecord(id: UUID(), path: "/b", name: "b", bookmark: Data(), lastOpenedAt: Date())
        let first = WorkspaceWindowRecord(id: UUID(), workspaceID: a.id, section: .workspace)
        let second = WorkspaceWindowRecord(id: UUID(), workspaceID: a.id, section: .runs)
        var state = DesktopSnapshot(workspaces: [a, b], windows: [first, second])
        state.associate(windowID: first.id, workspaceID: b.id)
        #expect(state.windows[0].id == first.id)
        #expect(state.windows[0].workspaceID == b.id)
        #expect(state.windows[0].section == .dashboard)
        #expect(state.windows[1] == second)
        try state.validate()
    }

    @Test func invalidUpdateDoesNotReplaceCommittedState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDesktopStateStore(directory: directory)
        try store.save(DesktopSnapshot())
        let invalid = DesktopSnapshot(windows: [WorkspaceWindowRecord(id: UUID(), workspaceID: UUID())])
        #expect(throws: (any Error).self) { try store.save(invalid) }
        #expect(try store.load() == DesktopSnapshot())
    }

    @Test func unknownSchemaAndCorruptStateAreNotSilentlyReset() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileDesktopStateStore(directory: directory)
        var invalid = DesktopSnapshot()
        invalid.version = 99
        #expect(throws: (any Error).self) { try store.save(invalid) }
        try store.save(DesktopSnapshot())
        let corrupt = Data("not json".utf8)
        try corrupt.write(to: store.stateURL)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try Data(contentsOf: store.stateURL) == corrupt)
    }

    @Test func detectsDuplicateIdentitiesAndInvalidGeometry() {
        let workspace = WorkspaceRecord(id: UUID(), path: "/a", name: "a", bookmark: Data(), lastOpenedAt: Date())
        #expect(throws: (any Error).self) { try DesktopSnapshot(workspaces: [workspace, workspace]).validate() }
        let window = WorkspaceWindowRecord(id: UUID(), workspaceID: workspace.id,
            frame: WindowGeometry(x: 0, y: 0, width: -1, height: 800))
        #expect(throws: (any Error).self) { try DesktopSnapshot(workspaces: [workspace], windows: [window]).validate() }
    }
}

@MainActor
struct DesktopCoordinatorTests {
    @Test func quittingBeforeLoadDoesNotOverwritePersistedSession() throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = DesktopCoordinator(store: fixture.store)
        #expect(coordinator.isLoading)
        #expect(coordinator.prepareToQuit())
        #expect(try fixture.store.load().workspaces == [fixture.original])
    }

    @Test func quittingDuringLoadDoesNotSaveOrRestoreLateResult() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let delayed = ControlledDesktopStore(backing: fixture.store, delayLoad: true)
        defer { delayed.releaseLoad.signal() }
        let coordinator = DesktopCoordinator(store: delayed)
        let loading = Task { await coordinator.loadSession() }
        let started = await Task.detached { delayed.waitUntilLoadStarted() }.value
        #expect(started)
        #expect(coordinator.prepareToQuit())
        delayed.releaseLoad.signal()
        await loading.value
        #expect(coordinator.snapshot.workspaces.isEmpty)
        #expect(try fixture.store.load().workspaces == [fixture.original])
    }

    @Test func loadedSessionSurvivesNormalQuitAndBlocksEarlyMutations() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = DesktopCoordinator(store: fixture.store)
        #expect(throws: (any Error).self) { try coordinator.relinkWorkspace(fixture.relocated) }
        await coordinator.loadSession()
        #expect(!coordinator.isLoading)
        #expect(coordinator.prepareToQuit())
        #expect(try fixture.store.load().workspaces == [fixture.original])
    }

    @Test func switchingAWindowAwayFromARunningWorkspaceAsksFirst() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let other = WorkspaceRecord(id: UUID(), path: fixture.relocated.path, name: "other", bookmark: Data(), lastOpenedAt: Date())
        try fixture.store.save(DesktopSnapshot(workspaces: [fixture.original, other]))
        let provider = FakeProvider()
        let plan = CoreLocalRunPlan(workflowID: ".github/workflows/probe.yml", event: "push")
        provider.core.preparedLocalRun = CorePreparedLocalRun(readiness: FakeCore.readyTools, plan: plan, confirmationID: "local_1", expiresAt: Date())
        provider.core.localOutputs = [CoreLocalRunOutput(
            executionID: "exec_1", repositoryID: "repo", state: .running, phase: .running, lines: [], discarded: false,
            lastSequence: 0, jobs: [], plan: plan, startedAt: Date(), finishedAt: nil, exitCode: nil, message: nil, cleanupProblem: nil)]
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.status == .ready(version: "fake") }

        let factory = TestWindowFactory()
        let coordinator = DesktopCoordinator(store: fixture.store, core: hub, makeGrant: factory.makeGrant,
                                             makeWorkspaceWindow: factory.makeWindow)
        await coordinator.loadSession()
        coordinator.openRegistered(fixture.original)
        let window = try #require(factory.windows.first)
        _ = await eventually { hub.session(for: fixture.original.id)?.phase == .ready }
        let review = LocalRunReviewModel(workspaceID: fixture.original.id, workflowID: plan.workflowID, jobs: [], hub: hub)
        await review.prepare()
        review.trusted = true
        let run = try #require(await review.run())

        var asked: [LocalRunStopPrompt.Action] = []
        coordinator.confirmStoppingLocalRuns = { asked.append($0.action); return false }
        coordinator.openRegistered(other, reuseWindowID: window.record.id)
        #expect(asked == [.switchWorkspace])
        #expect(window.record.workspaceID == fixture.original.id)
        #expect(hub.session(for: fixture.original.id)?.localRun === run)
        #expect(factory.grants.count == 2 && factory.grants[1].stopped, "the other workspace's folder access is released")
        #expect(coordinator.snapshot.windows.first?.workspaceID == fixture.original.id)
        run.stopFollowing()
    }

    @Test func closingAWindowWithUnsavedEditsAsksFirst() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let factory = TestWindowFactory()
        let coordinator = DesktopCoordinator(store: fixture.store, makeGrant: factory.makeGrant, makeWorkspaceWindow: factory.makeWindow)
        await coordinator.loadSession()
        coordinator.openRegistered(fixture.original)
        let window = try #require(factory.windows.first)
        window.unsaved = "ci.yml"
        var asked: [[String]] = []
        var answer = UnsavedChoice.cancel
        coordinator.confirmUnsavedChanges = { asked.append($0); return answer }

        #expect(!coordinator.shouldClose(window.record.id))
        #expect(coordinator.snapshot.windows.count == 1)

        answer = .save
        #expect(!coordinator.shouldClose(window.record.id), "the window closes only after the save")
        _ = await eventually { window.saveCalls == 1 }

        window.unsaved = "ci.yml"
        answer = .discard
        #expect(coordinator.shouldClose(window.record.id))
        #expect(coordinator.snapshot.windows.isEmpty)
        #expect(asked == [["ci.yml"], ["ci.yml"], ["ci.yml"]])
    }

    @Test func quittingWithUnsavedEditsAsksOnceForAllWindows() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let factory = TestWindowFactory()
        let coordinator = DesktopCoordinator(store: fixture.store, makeGrant: factory.makeGrant, makeWorkspaceWindow: factory.makeWindow)
        await coordinator.loadSession()
        coordinator.openRegistered(fixture.original)
        coordinator.openRegistered(fixture.original)
        var asked: [[String]] = []
        coordinator.confirmUnsavedChanges = { asked.append($0); return .save }
        #expect(coordinator.unsavedEditsQuitDecision() == .proceed)
        #expect(asked.isEmpty)

        factory.windows[0].unsaved = "ci.yml"
        factory.windows[1].unsaved = "release.yml"
        #expect(coordinator.unsavedEditsQuitDecision() == .saveFirst)
        #expect(asked == [["ci.yml", "release.yml"]])
        factory.windows[1].saveSucceeds = false
        #expect(await coordinator.saveAllUnsavedWorkflows() == false)
        #expect(factory.windows[0].saveCalls == 1 && factory.windows[1].saveCalls == 1)

        coordinator.confirmUnsavedChanges = { _ in .discard }
        #expect(coordinator.unsavedEditsQuitDecision() == .proceed)
        coordinator.confirmUnsavedChanges = { _ in .cancel }
        #expect(coordinator.unsavedEditsQuitDecision() == .cancel)
    }

    @Test func switchingAWindowWithUnsavedEditsAsksFirst() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let other = WorkspaceRecord(id: UUID(), path: fixture.relocated.path, name: "other", bookmark: Data(), lastOpenedAt: Date())
        try fixture.store.save(DesktopSnapshot(workspaces: [fixture.original, other]))
        let factory = TestWindowFactory()
        let coordinator = DesktopCoordinator(store: fixture.store, makeGrant: factory.makeGrant, makeWorkspaceWindow: factory.makeWindow)
        await coordinator.loadSession()
        coordinator.openRegistered(fixture.original)
        let window = try #require(factory.windows.first)
        window.unsaved = "ci.yml"
        coordinator.confirmUnsavedChanges = { _ in .cancel }
        coordinator.openRegistered(other, reuseWindowID: window.record.id)
        #expect(window.record.workspaceID == fixture.original.id)
        #expect(factory.grants.last?.stopped == true)

        coordinator.confirmUnsavedChanges = { _ in .save }
        coordinator.openRegistered(other, reuseWindowID: window.record.id)
        _ = await eventually { window.record.workspaceID == other.id }
        #expect(window.saveCalls == 1)
        #expect(window.record.workspaceID == other.id)
    }

    @Test func theWindowLimitSaysSoInsteadOfBlamingTheFolder() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let full = (0..<DesktopSnapshot.maxWindows).map { _ in WorkspaceWindowRecord(id: UUID(), workspaceID: fixture.original.id) }
        try fixture.store.save(DesktopSnapshot(workspaces: [fixture.original], windows: full))
        let factory = TestWindowFactory()
        let coordinator = DesktopCoordinator(store: fixture.store, makeGrant: factory.makeGrant,
                                             makeWorkspaceWindow: factory.makeWindow)
        await coordinator.loadSession()
        coordinator.openRegistered(fixture.original)
        #expect(coordinator.message == DesktopCoordinator.tooManyWindowsMessage)
        #expect(factory.windows.isEmpty && factory.calls == 0, "no window and no folder access is attempted")
        #expect(try fixture.store.load().windows.count == DesktopSnapshot.maxWindows)
    }

    @Test func relinkRebindsEveryOpenWindowAndPreservesIdentityAndNavigation() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let factory = TestWindowFactory()
        let coordinator = DesktopCoordinator(store: fixture.store, makeGrant: factory.makeGrant,
                                             makeWorkspaceWindow: factory.makeWindow)
        await coordinator.loadSession()
        coordinator.openRegistered(fixture.original)
        coordinator.openRegistered(fixture.original)
        #expect(factory.windows.count == 2)
        let first = try #require(factory.windows.first)
        let second = try #require(factory.windows.last)
        coordinator.selectSection(.workspace, windowID: first.record.id)
        coordinator.selectSection(.runs, windowID: second.record.id)
        let records = coordinator.snapshot.windows
        let oldGrants = factory.grants
        try coordinator.relinkWorkspace(fixture.relocated)
        #expect(coordinator.snapshot.windows == records)
        #expect(coordinator.openCount(fixture.original.id) == 2)
        #expect(oldGrants.allSatisfy { $0.stopped })
        for window in factory.windows {
            #expect(window.workspace.path == fixture.relocated.path)
            let reader = try #require(window.grant?.reader)
            #expect(try reader.source(for: LocalWorkflowFile(relativePath: ".github/workflows/probe.yml")) == "new")
        }
        #expect(try fixture.store.load().workspaces == [fixture.relocated])
    }

    @Test func aStaleBookmarkOrMovedFolderUpdatesTheSavedWorkspace() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let factory = TestWindowFactory()
        factory.resolvedPath = fixture.relocated.path
        factory.refreshedBookmark = Data([1, 2, 3])
        let coordinator = DesktopCoordinator(store: fixture.store, makeGrant: factory.makeGrant,
                                             makeWorkspaceWindow: factory.makeWindow)
        await coordinator.loadSession()
        coordinator.openRegistered(fixture.original)
        let window = try #require(factory.windows.first)
        #expect(window.workspace.path == fixture.relocated.path)
        let saved = try #require(try fixture.store.load().workspaces.first)
        #expect(saved.id == fixture.original.id)
        #expect(saved.path == fixture.relocated.path)
        #expect(saved.bookmark == Data([1, 2, 3]))
        #expect(saved.name == "fixture", "a name that is not the folder name is kept")
        #expect(coordinator.message == nil)
    }

    @Test func aRenamedFolderRenamesAWorkspaceNamedAfterIt() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        var named = fixture.original
        named.name = URL(fileURLWithPath: fixture.original.path).lastPathComponent
        try fixture.store.save(DesktopSnapshot(workspaces: [named]))
        let factory = TestWindowFactory()
        factory.resolvedPath = fixture.relocated.path
        let coordinator = DesktopCoordinator(store: fixture.store, makeGrant: factory.makeGrant,
                                             makeWorkspaceWindow: factory.makeWindow)
        await coordinator.loadSession()
        coordinator.openRegistered(named)
        let saved = try #require(try fixture.store.load().workspaces.first)
        #expect(saved.name == URL(fileURLWithPath: fixture.relocated.path).lastPathComponent)
        #expect(factory.windows.first?.workspace.name == saved.name)
    }

    @Test func failedGrantPreparationRollsBackAllWindowsAndRegistry() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let factory = TestWindowFactory()
        let coordinator = DesktopCoordinator(store: fixture.store, makeGrant: factory.makeGrant,
                                             makeWorkspaceWindow: factory.makeWindow)
        await coordinator.loadSession()
        coordinator.openRegistered(fixture.original)
        coordinator.openRegistered(fixture.original)
        let before = coordinator.snapshot
        factory.failGrantOnCall = 4
        #expect(throws: (any Error).self) { try coordinator.relinkWorkspace(fixture.relocated) }
        #expect(coordinator.snapshot == before)
        #expect(try fixture.store.load() == before)
        #expect(factory.windows.allSatisfy { $0.workspace.path == fixture.original.path })
        #expect(factory.grants.prefix(2).allSatisfy { !$0.stopped })
        #expect(factory.grants.last?.stopped == true)
    }

    @Test func failedRelinkCommitReleasesPreparedGrantsWithoutSwitchingWindows() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let controlled = ControlledDesktopStore(backing: fixture.store)
        let factory = TestWindowFactory()
        let coordinator = DesktopCoordinator(store: controlled, makeGrant: factory.makeGrant,
                                             makeWorkspaceWindow: factory.makeWindow)
        await coordinator.loadSession()
        coordinator.openRegistered(fixture.original)
        let before = coordinator.snapshot
        controlled.failWrites = true
        #expect(throws: (any Error).self) { try coordinator.relinkWorkspace(fixture.relocated) }
        #expect(coordinator.snapshot == before)
        #expect(try fixture.store.load() == before)
        #expect(factory.windows.first?.workspace.path == fixture.original.path)
        #expect(factory.grants.first?.stopped == false)
        #expect(factory.grants.last?.stopped == true)
    }
}

private struct CoordinatorFixture {
    let directory: URL
    let store: FileDesktopStateStore
    let original: WorkspaceRecord
    let relocated: WorkspaceRecord

    init() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let a = directory.appendingPathComponent("old")
        let b = directory.appendingPathComponent("new")
        for (root, contents) in [(a, "old"), (b, "new")] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(".github/workflows"), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: root.appendingPathComponent(".github/workflows/probe.yml"))
        }
        original = WorkspaceRecord(id: UUID(), path: a.path, name: "fixture", bookmark: Data(), lastOpenedAt: Date())
        var updated = original
        updated.path = b.path
        relocated = updated
        store = FileDesktopStateStore(directory: directory.appendingPathComponent("state"))
        try store.save(DesktopSnapshot(workspaces: [original]))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private final class ControlledDesktopStore: DesktopStateStoring, @unchecked Sendable {
    let backing: FileDesktopStateStore
    let delayLoad: Bool
    let loadStarted = DispatchSemaphore(value: 0)
    let releaseLoad = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldFailWrites = false
    var failWrites: Bool {
        get { lock.withLock { shouldFailWrites } }
        set { lock.withLock { shouldFailWrites = newValue } }
    }

    init(backing: FileDesktopStateStore, delayLoad: Bool = false) {
        self.backing = backing
        self.delayLoad = delayLoad
    }

    func load() throws -> DesktopSnapshot {
        loadStarted.signal()
        if delayLoad { releaseLoad.wait() }
        return try backing.load()
    }

    func waitUntilLoadStarted() -> Bool { loadStarted.wait(timeout: .now() + 5) == .success }

    func save(_ snapshot: DesktopSnapshot) throws {
        if failWrites { throw DesktopStoreError.ioFailure }
        try backing.save(snapshot)
    }
}

@MainActor
private final class TestRepositoryGrant: RepositoryGranting {
    let url: URL
    let reader: RepositoryReader
    let refreshedBookmark: Data?
    var stopped = false
    /// `resolvedPath` stands for a bookmark that now points at a moved folder.
    init(_ workspace: WorkspaceRecord, resolvedPath: String? = nil, refreshedBookmark: Data? = nil) throws {
        url = URL(fileURLWithPath: resolvedPath ?? workspace.path)
        reader = try RepositoryReader(root: url)
        self.refreshedBookmark = refreshedBookmark
    }
    func stop() { stopped = true }
}

@MainActor
private final class TestWorkspaceWindow: WorkspaceWindowManaging {
    var record: WorkspaceWindowRecord
    var workspace: WorkspaceRecord
    var grant: (any RepositoryGranting)?
    var window: NSWindow? { nil }
    init(_ record: WorkspaceWindowRecord, _ workspace: WorkspaceRecord, _ grant: (any RepositoryGranting)?) {
        self.record = record
        self.workspace = workspace
        self.grant = grant
    }
    func attach(record: WorkspaceWindowRecord, workspace: WorkspaceRecord, grant: any RepositoryGranting) {
        self.grant?.stop()
        self.record = record
        self.workspace = workspace
        self.grant = grant
    }
    func showWindow(_ sender: Any?) {}
    var unsaved: String?
    var saveSucceeds = true
    var saveCalls = 0
    var unsavedWorkflowName: String? { unsaved }
    func saveUnsavedWorkflow() async -> Bool {
        saveCalls += 1
        if saveSucceeds { unsaved = nil }
        return saveSucceeds
    }
}

@MainActor
private final class TestWindowFactory {
    var windows: [TestWorkspaceWindow] = []
    var grants: [TestRepositoryGrant] = []
    var calls = 0
    var failGrantOnCall: Int?
    var resolvedPath: String?
    var refreshedBookmark: Data?
    func makeGrant(_ workspace: WorkspaceRecord) throws -> any RepositoryGranting {
        calls += 1
        if calls == failGrantOnCall { throw RepositoryAccessError.unavailable }
        let grant = try TestRepositoryGrant(workspace, resolvedPath: resolvedPath, refreshedBookmark: refreshedBookmark)
        grants.append(grant)
        return grant
    }
    func makeWindow(_ record: WorkspaceWindowRecord, _ workspace: WorkspaceRecord,
                    _ grant: (any RepositoryGranting)?, _ desktop: DesktopCoordinator) -> any WorkspaceWindowManaging {
        let window = TestWorkspaceWindow(record, workspace, grant)
        windows.append(window)
        return window
    }
}

struct RepositoryReaderTests {
    @Test func missingWorkflowDirectoryIsEmpty() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try RepositoryReader(root: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent(".github"))
        #expect(try reader.workflows().isEmpty)
    }

    @Test func pinsRootWhenSelectedPathIsReplacedWithSymlink() throws {
        let root = try fixture()
        let external = try fixture()
        let moved = root.appendingPathExtension("moved")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: moved)
            try? FileManager.default.removeItem(at: external)
        }
        let file = LocalWorkflowFile(relativePath: ".github/workflows/probe.yml")
        try Data("original".utf8).write(to: root.appendingPathComponent(file.relativePath))
        try Data("outside".utf8).write(to: external.appendingPathComponent(file.relativePath))
        let reader = try RepositoryReader(root: root)
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: external)
        #expect(try reader.source(for: file) == "original")
        #expect(throws: (any Error).self) { try RepositoryReader(root: root) }
    }

    @Test func rejectsIntermediateAndFinalSymlinks() throws {
        let root = try fixture()
        let external = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: external) }
        let file = LocalWorkflowFile(relativePath: ".github/workflows/probe.yml")
        try Data("outside".utf8).write(to: external.appendingPathComponent(file.relativePath))
        let reader = try RepositoryReader(root: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(file.relativePath),
                                                  withDestinationURL: external.appendingPathComponent(file.relativePath))
        #expect(throws: (any Error).self) { try reader.source(for: file) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(".github/workflows"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".github/workflows"),
                                                  withDestinationURL: external.appendingPathComponent(".github/workflows"))
        #expect(throws: (any Error).self) { try reader.source(for: file) }
        #expect(throws: (any Error).self) { try reader.workflows() }
    }

    @Test func rejectsNulAndNonRegularFiles() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try RepositoryReader(root: root)
        #expect(throws: (any Error).self) { try reader.source(for: LocalWorkflowFile(relativePath: ".github/workflows/a\0.yml")) }
        #expect(throws: (any Error).self) { try reader.source(for: LocalWorkflowFile(relativePath: ".github/workflows")) }
    }

    @Test func readsOnlyWorkflowFilesWithoutCreatingConfig() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(".github/workflows")
        try Data("name: Build\non: push\n".utf8).write(to: directory.appendingPathComponent("build.yml"))
        try Data("ignored".utf8).write(to: directory.appendingPathComponent("notes.txt"))
        let reader = try RepositoryReader(root: root)
        #expect(try RepositoryReader.canonicalRepository(root).path == root.path)
        let files = try reader.workflows()
        #expect(files.map(\.name) == ["build.yml"])
        #expect(try reader.source(for: files[0]).contains("Build"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".runnir").path))
    }

    @Test func rejectsTraversalAndSymlinkEscape() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let reader = try RepositoryReader(root: root)
        #expect(throws: (any Error).self) { try reader.source(for: LocalWorkflowFile(relativePath: "../private.txt")) }
        #expect(throws: (any Error).self) { try reader.source(for: LocalWorkflowFile(relativePath: "/etc/passwd")) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(".github/workflows/escape.yml").path,
                                                   withDestinationPath: "/etc/passwd")
        #expect(throws: (any Error).self) { try reader.workflows() }
    }

    @Test func boundsSourceSize() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = LocalWorkflowFile(relativePath: ".github/workflows/large.yaml")
        try Data(repeating: 65, count: 512 * 1024 + 1).write(to: root.appendingPathComponent(file.relativePath))
        #expect(throws: (any Error).self) { try RepositoryReader(root: root).source(for: file) }
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".github/workflows"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: false)
        return root
    }
}

@MainActor
struct DesktopCoreIntegrationTests {
    @Test func windowsShareOneCoreRepositoryAndTheLastCloseReleasesIt() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        let factory = TestWindowFactory()
        let coordinator = DesktopCoordinator(store: fixture.store, core: hub, makeGrant: factory.makeGrant,
                                             makeWorkspaceWindow: factory.makeWindow)
        await coordinator.loadSession()
        coordinator.openRegistered(fixture.original)
        coordinator.openRegistered(fixture.original)
        #expect(await eventually { hub.session(for: fixture.original.id)?.phase == .ready })
        #expect(provider.core.openCalls == [fixture.original.path])

        let first = try #require(factory.windows.first)
        let second = try #require(factory.windows.last)
        coordinator.didClose(first.record.id)
        #expect(hub.session(for: fixture.original.id) != nil)
        coordinator.didClose(second.record.id)
        #expect(hub.session(for: fixture.original.id) == nil)
        #expect(await eventually { provider.core.closeCalls == [FakeCore.id(for: fixture.original.path)] })
    }

    @Test func relinkingMovesTheRepositoryInTheCore() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        let factory = TestWindowFactory()
        let coordinator = DesktopCoordinator(store: fixture.store, core: hub, makeGrant: factory.makeGrant,
                                             makeWorkspaceWindow: factory.makeWindow)
        await coordinator.loadSession()
        coordinator.openRegistered(fixture.original)
        #expect(await eventually { hub.session(for: fixture.original.id)?.phase == .ready })

        try coordinator.relinkWorkspace(fixture.relocated)
        #expect(await eventually { hub.session(for: fixture.original.id)?.coreID == FakeCore.id(for: fixture.relocated.path) })
        #expect(await eventually { provider.core.closeCalls == [FakeCore.id(for: fixture.original.path)] })
    }

    @Test func quittingDoesNotTouchTheCore() async throws {
        let fixture = try CoordinatorFixture()
        defer { fixture.remove() }
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        let factory = TestWindowFactory()
        let coordinator = DesktopCoordinator(store: fixture.store, core: hub, makeGrant: factory.makeGrant,
                                             makeWorkspaceWindow: factory.makeWindow)
        await coordinator.loadSession()
        coordinator.openRegistered(fixture.original)
        #expect(await eventually { hub.session(for: fixture.original.id)?.phase == .ready })
        #expect(coordinator.prepareToQuit())
        coordinator.didClose(try #require(factory.windows.first).record.id) // teardown during quit
        #expect(provider.core.closeCalls.isEmpty)
    }
}
