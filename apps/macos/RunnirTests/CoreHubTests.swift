import Foundation
import Testing
@testable import Runnir

// MARK: Fakes (shared with the coordinator tests)

final class FakeCore: CoreServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var _openCalls: [String] = []
    private var _closeCalls: [String] = []
    private var _refreshCalls: [String] = []
    private var _listCalls: [String] = []
    private var _subscriptions = 0
    private var branches: [String: String] = [:]
    private var workflows: [String: [CoreWorkflow]] = [:]
    private var failingPaths: [String: CoreServiceError] = [:]
    private var openDelays: [String: Duration] = [:]
    private var refreshDelay: Duration?
    private var refreshError: CoreServiceError?
    private var openIDs: Set<String> = []
    private var continuations: [AsyncThrowingStream<CoreEvent, any Error>.Continuation] = []

    var openCalls: [String] { lock.withLock { _openCalls } }
    var closeCalls: [String] { lock.withLock { _closeCalls } }
    var refreshCalls: [String] { lock.withLock { _refreshCalls } }
    var listCalls: [String] { lock.withLock { _listCalls } }
    var subscriptions: Int { lock.withLock { _subscriptions } }

    static func id(for path: String) -> String { "id:" + path }

    func setBranch(_ branch: String, for path: String) { lock.withLock { branches[Self.id(for: path)] = branch } }
    func setWorkflows(_ list: [CoreWorkflow], for path: String) { lock.withLock { workflows[Self.id(for: path)] = list } }
    func delayOpen(of path: String, by delay: Duration) { lock.withLock { openDelays[path] = delay } }
    func delayRefresh(by delay: Duration) { lock.withLock { refreshDelay = delay } }
    func failRefresh(with error: CoreServiceError?) { lock.withLock { refreshError = error } }
    /// Mirrors the Core: contexts are shared by path and a close is global.
    func isOpen(_ path: String) -> Bool { lock.withLock { openIDs.contains(Self.id(for: path)) } }

    func failOpen(for path: String, with error: CoreServiceError = .invalidArgument("no")) {
        lock.withLock { failingPaths[path] = error }
    }

    func push(_ event: CoreEvent) { lock.withLock { continuations }.forEach { $0.yield(event) } }
    func endEvents(throwing error: any Error) {
        let current = lock.withLock { () -> [AsyncThrowingStream<CoreEvent, any Error>.Continuation] in
            let copy = continuations
            continuations = []
            return copy
        }
        current.forEach { $0.finish(throwing: error) }
    }

    func healthCheck() async throws -> CoreHealth {
        CoreHealth(coreVersion: "fake", protocolVersion: 1, openRepositoryCount: 0, residentMemoryBytes: 0)
    }

    func openRepository(path: String) async throws -> CoreRepository {
        try lock.withLock {
            _openCalls.append(path)
            if let error = failingPaths[path] { throw error }
        }
        if let delay = lock.withLock({ openDelays[path] }) { try? await Task.sleep(for: delay) }
        let id = Self.id(for: path)
        lock.withLock { _ = openIDs.insert(id) }
        return CoreRepository(id: id, path: path, branch: lock.withLock { branches[id] } ?? "main", workflowCount: 0, lastRefresh: nil)
    }

    func refreshRepository(id: String) async throws -> CoreRepository {
        lock.withLock { _refreshCalls.append(id) }
        if let delay = lock.withLock({ refreshDelay }) { try? await Task.sleep(for: delay) }
        if let error = lock.withLock({ refreshError }) { throw error }
        return CoreRepository(id: id, path: String(id.dropFirst(3)), branch: lock.withLock { branches[id] } ?? "main", workflowCount: 0, lastRefresh: Date())
    }

    func closeRepository(id: String) async throws {
        lock.withLock {
            _closeCalls.append(id)
            openIDs.remove(id)
        }
    }

    func listWorkflows(repositoryID: String) async throws -> [CoreWorkflow] {
        lock.withLock { _listCalls.append(repositoryID); return workflows[repositoryID] ?? [] }
    }

    func startWorkflow(repositoryID: String, workflowID: String, ref: String?) async throws -> CoreExecution {
        throw CoreServiceError.unavailable
    }

    func events(repositoryIDs: [String]) -> AsyncThrowingStream<CoreEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: CoreEvent.self, throwing: (any Error).self)
        lock.withLock { _subscriptions += 1; continuations.append(continuation) }
        return stream
    }
}

final class FakeProvider: CoreProviding, @unchecked Sendable {
    let core = FakeCore()
    private let lock = NSLock()
    private var continuation: AsyncStream<CoreConnectionState>.Continuation?
    private var current: CoreConnectionState = .stopped
    private var _recoverCalls = 0
    var recoverCalls: Int { lock.withLock { _recoverCalls } }

    func emit(_ state: CoreConnectionState) {
        let target: AsyncStream<CoreConnectionState>.Continuation? = lock.withLock {
            current = state
            return continuation
        }
        target?.yield(state)
    }

    func ready() {
        emit(.starting)
        emit(.running(CoreHealth(coreVersion: "fake", protocolVersion: 1, openRepositoryCount: 0, residentMemoryBytes: 0)))
    }

    func states() async -> AsyncStream<CoreConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: CoreConnectionState.self)
        lock.withLock { self.continuation = continuation }
        continuation.yield(lock.withLock { current })
        return stream
    }

    func start() async throws -> CoreHealth { throw CoreSupervisorError.launchFailed }

    func recover() async throws -> CoreHealth {
        lock.withLock { _recoverCalls += 1 }
        ready()
        return CoreHealth(coreVersion: "fake", protocolVersion: 1, openRepositoryCount: 0, residentMemoryBytes: 0)
    }

    func service() async throws -> any CoreServicing {
        if case .running = lock.withLock({ current }) { return core }
        throw CoreServiceError.unavailable
    }
}

func coreEvent(_ kind: CoreEventKind, repository: String?, sequence: UInt64 = 1) -> CoreEvent {
    CoreEvent(sequence: sequence, kind: kind, repositoryID: repository, executionID: nil,
              executionState: .unspecified, message: nil, date: Date())
}

private func workflow(_ id: String) -> CoreWorkflow {
    CoreWorkflow(id: id, name: id, triggers: ["push"], jobs: [], parseError: nil)
}

// MARK: Tests

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CoreHubTests {
    private func makeHub() -> (CoreHub, FakeProvider) {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        return (hub, provider)
    }

    private func readyHub() async -> (CoreHub, FakeProvider) {
        let (hub, provider) = makeHub()
        provider.ready()
        _ = await eventually { hub.status == .ready(version: "fake") }
        return (hub, provider)
    }

    @Test
    func repositoryOpensWithTheFirstWindowAndClosesWithTheLast() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        let w1 = UUID(), w2 = UUID()
        hub.attach(windowID: w1, workspaceID: workspace, path: "/repo/a")
        hub.attach(windowID: w2, workspaceID: workspace, path: "/repo/a")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })
        #expect(provider.core.openCalls == ["/repo/a"])

        hub.detach(windowID: w1)
        #expect(hub.session(for: workspace) != nil)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(provider.core.closeCalls.isEmpty)

        hub.detach(windowID: w2)
        #expect(hub.session(for: workspace) == nil)
        #expect(await eventually { provider.core.closeCalls == [FakeCore.id(for: "/repo/a")] })
    }

    @Test
    func attachingBeforeTheCoreIsReadyWaitsAndThenOpens() async {
        let (hub, provider) = makeHub()
        let workspace = UUID()
        provider.core.setBranch("dev", for: "/repo/a")
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/a")
        #expect(hub.session(for: workspace)?.phase == .waitingForCore)
        #expect(provider.core.openCalls.isEmpty)

        provider.ready()
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })
        #expect(hub.session(for: workspace)?.branch == "dev")
    }

    @Test
    func tenWorkspacesShareOneCoreWithoutRestarting() async {
        let (hub, provider) = await readyHub()
        let workspaces = (0..<10).map { _ in UUID() }
        for (index, workspace) in workspaces.enumerated() {
            hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/\(index)")
        }
        #expect(await eventually { workspaces.allSatisfy { hub.session(for: $0)?.phase == .ready } })
        #expect(Set(workspaces.compactMap { hub.session(for: $0)?.coreID }).count == 10)
        #expect(provider.core.openCalls.count == 10)
        #expect(provider.recoverCalls == 0)
    }

    @Test
    func refreshTouchesOnlyItsOwnWorkspace() async throws {
        let (hub, provider) = await readyHub()
        let a = UUID(), b = UUID()
        hub.attach(windowID: UUID(), workspaceID: a, path: "/repo/a")
        hub.attach(windowID: UUID(), workspaceID: b, path: "/repo/b")
        #expect(await eventually { hub.session(for: a)?.phase == .ready && hub.session(for: b)?.phase == .ready })

        provider.core.setBranch("release", for: "/repo/a")
        await hub.refresh(workspaceID: a)
        #expect(hub.session(for: a)?.branch == "release")
        #expect(hub.session(for: a)?.lastRefresh != nil)
        #expect(hub.session(for: b)?.branch == "main")
        #expect(hub.session(for: b)?.lastRefresh == nil)
        #expect(provider.core.refreshCalls == [FakeCore.id(for: "/repo/a")])
    }

    @Test
    func eventsUpdateOnlyTheMatchingWorkspace() async throws {
        let (hub, provider) = await readyHub()
        let a = UUID(), b = UUID()
        hub.attach(windowID: UUID(), workspaceID: a, path: "/repo/a")
        hub.attach(windowID: UUID(), workspaceID: b, path: "/repo/b")
        #expect(await eventually { hub.session(for: a)?.phase == .ready && hub.session(for: b)?.phase == .ready })
        let listsForA = provider.core.listCalls.filter { $0 == FakeCore.id(for: "/repo/a") }.count

        provider.core.setWorkflows([workflow("ci.yml")], for: "/repo/b")
        provider.core.push(coreEvent(.repositoryRefreshed, repository: FakeCore.id(for: "/repo/b")))
        #expect(await eventually { hub.session(for: b)?.workflows.count == 1 })
        #expect(hub.session(for: a)?.workflows.isEmpty == true)
        #expect(provider.core.listCalls.filter { $0 == FakeCore.id(for: "/repo/a") }.count == listsForA)
    }

    @Test
    func lostCoreMarksSessionsUnavailableAndRecoveryReopensThem() async {
        let (hub, provider) = await readyHub()
        let a = UUID(), b = UUID()
        hub.attach(windowID: UUID(), workspaceID: a, path: "/repo/a")
        hub.attach(windowID: UUID(), workspaceID: b, path: "/repo/b")
        #expect(await eventually { hub.session(for: a)?.phase == .ready && hub.session(for: b)?.phase == .ready })

        provider.emit(.lost(.processExited(137)))
        #expect(await eventually { hub.status == .lost })
        #expect(hub.status.needsRecovery)
        #expect(hub.session(for: a)?.phase == .unavailable)
        #expect(hub.session(for: b)?.phase == .unavailable)

        await hub.recover()
        #expect(await eventually { hub.session(for: a)?.phase == .ready && hub.session(for: b)?.phase == .ready })
        #expect(provider.recoverCalls == 1)
        #expect(provider.core.openCalls.count == 4)
        #expect(hub.status == .ready(version: "fake"))
        #expect(provider.core.subscriptions == 2)
    }

    @Test
    func failedStartOffersRecovery() async {
        let (hub, provider) = makeHub()
        hub.attach(windowID: UUID(), workspaceID: UUID(), path: "/repo/a")
        provider.emit(.failed(.timedOut))
        #expect(await eventually { hub.status.needsRecovery })
        if case .failed(let reason) = hub.status { #expect(!reason.isEmpty) } else { Issue.record("expected failed") }
    }

    @Test
    func aFailingRepositoryDoesNotAffectTheOthers() async {
        let (hub, provider) = await readyHub()
        provider.core.failOpen(for: "/repo/bad")
        let good = UUID(), bad = UUID()
        hub.attach(windowID: UUID(), workspaceID: good, path: "/repo/good")
        hub.attach(windowID: UUID(), workspaceID: bad, path: "/repo/bad")
        #expect(await eventually { hub.session(for: good)?.phase == .ready })
        #expect(await eventually { if case .failed = hub.session(for: bad)?.phase { true } else { false } })
    }

    @Test
    func anUnreadableFolderIsReportedAsSuchAndOtherRepositoriesStayReady() async {
        let (hub, provider) = await readyHub()
        provider.core.failOpen(for: "/repo/denied", with: .accessDenied)
        let good = UUID(), denied = UUID()
        hub.attach(windowID: UUID(), workspaceID: good, path: "/repo/good")
        hub.attach(windowID: UUID(), workspaceID: denied, path: "/repo/denied")
        #expect(await eventually { hub.session(for: good)?.phase == .ready })
        #expect(await eventually {
            if case .failed(let message) = hub.session(for: denied)?.phase { message.contains("cannot read") } else { false }
        })
    }

    @Test
    func relinkingToANewPathClosesTheOldRepositoryAndOpensTheNewOne() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID(), window = UUID()
        hub.attach(windowID: window, workspaceID: workspace, path: "/repo/old")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })

        hub.attach(windowID: window, workspaceID: workspace, path: "/repo/new")
        #expect(await eventually { hub.session(for: workspace)?.coreID == FakeCore.id(for: "/repo/new") })
        #expect(await eventually { provider.core.closeCalls == [FakeCore.id(for: "/repo/old")] })
        #expect(hub.session(for: workspace)?.phase == .ready)
    }

    @Test
    func relinkingWhileTheOldOpenIsInFlightKeepsTheNewPath() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID(), window = UUID()
        provider.core.delayOpen(of: "/repo/old", by: .milliseconds(300))
        hub.attach(windowID: window, workspaceID: workspace, path: "/repo/old")
        #expect(await eventually { provider.core.openCalls.contains("/repo/old") })
        hub.attach(windowID: window, workspaceID: workspace, path: "/repo/new")

        #expect(await eventually { hub.session(for: workspace)?.coreID == FakeCore.id(for: "/repo/new") })
        // The late result of the old open must neither overwrite the session nor leak.
        #expect(await eventually { provider.core.closeCalls.contains(FakeCore.id(for: "/repo/old")) })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(hub.session(for: workspace)?.coreID == FakeCore.id(for: "/repo/new"))
        #expect(hub.session(for: workspace)?.phase == .ready)
        #expect(!provider.core.isOpen("/repo/old"))
        #expect(provider.core.isOpen("/repo/new"))
    }

    @Test
    func reopeningRightAfterTheLastWindowClosedKeepsTheRepositoryOpen() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        let first = UUID()
        hub.attach(windowID: first, workspaceID: workspace, path: "/repo/a")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })

        hub.detach(windowID: first)
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/a")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(provider.core.isOpen("/repo/a"))
        #expect(hub.session(for: workspace)?.phase == .ready)
    }

    @Test
    func aLostCoreIsReportedWhileSlowOpensAreStillRunning() async {
        let (hub, provider) = makeHub()
        provider.core.delayOpen(of: "/repo/slow", by: .seconds(5))
        hub.attach(windowID: UUID(), workspaceID: UUID(), path: "/repo/slow")
        provider.ready()
        #expect(await eventually { provider.core.openCalls.contains("/repo/slow") })
        provider.emit(.lost(.processExited(9)))
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await eventually { hub.status == .lost })
        #expect(clock.now - started < .seconds(1))
    }

    @Test
    func aRefreshThatFinishesAfterARelinkDoesNotOverwriteTheNewRepository() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID(), window = UUID()
        provider.core.setBranch("old-branch", for: "/repo/old")
        provider.core.setBranch("new-branch", for: "/repo/new")
        hub.attach(windowID: window, workspaceID: workspace, path: "/repo/old")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })

        provider.core.delayRefresh(by: .milliseconds(300))
        let refresh = Task { await hub.refresh(workspaceID: workspace) }
        #expect(await eventually { provider.core.refreshCalls.count == 1 })
        hub.attach(windowID: window, workspaceID: workspace, path: "/repo/new")
        await refresh.value

        #expect(await eventually { hub.session(for: workspace)?.coreID == FakeCore.id(for: "/repo/new") })
        #expect(hub.session(for: workspace)?.branch == "new-branch")
    }

    @Test
    func beforeTheCoreStartsRepositoriesWaitInsteadOfShowingUnavailable() async {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/a")
        hub.startMonitoring() // the first state is .stopped
        #expect(await eventually { hub.status == .stopped })
        #expect(hub.session(for: workspace)?.phase == .waitingForCore)
        #expect(hub.session(for: workspace)?.summary == "Connecting to Core...")
    }

    @Test
    func statusTextShowsTheFailureReasonAndAFailedRefresh() async {
        let (hub, provider) = await readyHub()
        provider.core.failOpen(for: "/repo/denied", with: .accessDenied)
        let denied = UUID(), good = UUID()
        hub.attach(windowID: UUID(), workspaceID: denied, path: "/repo/denied")
        hub.attach(windowID: UUID(), workspaceID: good, path: "/repo/good")
        #expect(await eventually { if case .failed = hub.session(for: denied)?.phase { true } else { false } })
        #expect(hub.session(for: denied)?.detail.contains("Locate / Grant Access") == true)

        #expect(await eventually { hub.session(for: good)?.phase == .ready })
        #expect(hub.session(for: good)?.summary == "main · 0 workflows")
        provider.core.failRefresh(with: .accessDenied)
        await hub.refresh(workspaceID: good)
        #expect(hub.session(for: good)?.summary == "main · 0 workflows · refresh failed")
        #expect(hub.session(for: good)?.detail.hasPrefix("Showing the last data.") == true)
    }

    @Test
    func movingAWindowToAnotherWorkspaceReleasesTheFirst() async {
        let (hub, provider) = await readyHub()
        let a = UUID(), b = UUID(), window = UUID()
        hub.attach(windowID: window, workspaceID: a, path: "/repo/a")
        #expect(await eventually { hub.session(for: a)?.phase == .ready })
        hub.attach(windowID: window, workspaceID: b, path: "/repo/b")
        #expect(hub.session(for: a) == nil)
        #expect(await eventually { hub.session(for: b)?.phase == .ready })
        #expect(await eventually { provider.core.closeCalls == [FakeCore.id(for: "/repo/a")] })
    }

    @Test
    func fallingBehindTriggersAResyncAndANewSubscription() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/a")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })
        #expect(await eventually { provider.core.subscriptions == 1 })

        provider.core.endEvents(throwing: CoreServiceError.resourceExhausted)
        #expect(await eventually { provider.core.subscriptions == 2 })
        #expect(provider.core.openCalls.count == 2)
    }

    @Test
    func aRepositoryClosedBySomeoneElseIsReopened() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/a")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })
        provider.core.push(coreEvent(.repositoryClosed, repository: FakeCore.id(for: "/repo/a")))
        #expect(await eventually { provider.core.openCalls.count == 2 })
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })
    }

    @Test
    func coreErrorsAreKept() async {
        let (hub, provider) = await readyHub()
        var event = coreEvent(.coreError, repository: nil)
        event = CoreEvent(sequence: 5, kind: .coreError, repositoryID: nil, executionID: nil,
                          executionState: .unspecified, message: "disk full", date: Date())
        provider.core.push(event)
        #expect(await eventually { hub.lastCoreMessage == "disk full" })
    }
}
