import Foundation
import Observation

/// What the hub needs from the Core supervisor; the real one is
/// `CoreProcessSupervisor`.
protocol CoreProviding: Sendable {
    func states() async -> AsyncStream<CoreConnectionState>
    @discardableResult func start() async throws -> CoreHealth
    @discardableResult func recover() async throws -> CoreHealth
    func service() async throws -> any CoreServicing
}

extension CoreProcessSupervisor: CoreProviding {}

/// The Core's view of one workspace's repository. Each workspace has its own
/// observable session, so a change to one repository only invalidates the
/// windows showing it.
@MainActor
@Observable
final class RepositorySession: Identifiable {
    enum Phase: Equatable {
        case waitingForCore
        case opening
        case ready
        case failed(String)
        /// The Core is not running; data shown may be out of date.
        case unavailable
    }

    nonisolated let workspaceID: UUID
    nonisolated var id: UUID { workspaceID }
    fileprivate(set) var path: String
    fileprivate(set) var phase: Phase = .waitingForCore
    fileprivate(set) var coreID: String?
    fileprivate(set) var branch = ""
    /// The GitHub repository this working tree pushes to ("owner/name").
    fileprivate(set) var githubRepository: String?
    fileprivate(set) var workflows: [CoreWorkflow] = []
    fileprivate(set) var lastRefresh: Date?
    fileprivate(set) var isRefreshing = false
    fileprivate(set) var refreshError: String?
    /// GitHub Actions data for `githubRepository`, read through the Core.
    fileprivate(set) var githubAccess: CoreGitHubAccess?
    fileprivate(set) var runs: [CoreWorkflowRun] = []
    fileprivate(set) var remoteWorkflows: [CoreGitHubWorkflow] = []
    fileprivate(set) var isLoadingGitHub = false
    fileprivate(set) var githubLoadedAt: Date?
    @ObservationIgnored fileprivate var githubPoll: Task<Void, Never>?
    /// A load was asked for while one was running; run another after it,
    /// because what the Core may read (the token) can have changed meanwhile.
    @ObservationIgnored fileprivate var githubReloadPending = false
    @ObservationIgnored fileprivate var windowIDs: Set<UUID> = []
    @ObservationIgnored fileprivate var appliedSequence: UInt64 = 0

    fileprivate init(workspaceID: UUID, path: String) {
        self.workspaceID = workspaceID
        self.path = path
    }

    /// Short status for the toolbar.
    var summary: String {
        switch phase {
        case .ready:
            let count = workflows.count == 1 ? "1 workflow" : "\(workflows.count) workflows"
            let base = branch.isEmpty ? count : "\(branch) · \(count)"
            return refreshError == nil ? base : base + " · refresh failed"
        case .failed: return "Core could not open this repository"
        case .unavailable: return "Core unavailable"
        case .waitingForCore, .opening: return "Connecting to Core..."
        }
    }

    /// The full explanation, for the tooltip.
    var detail: String {
        if case .failed(let message) = phase { return message }
        if let refreshError { return "Showing the last data. " + refreshError }
        return "Branch and workflows reported by Runnir Core"
    }
}

/// Connects workspace windows to the single Core: opens a repository when its
/// first window appears, closes it when its last window goes away, refreshes
/// on request, applies Core events to the matching workspace only, and offers
/// recovery when the Core is lost.
@MainActor
@Observable
final class CoreHub {
    enum Status: Equatable {
        case starting
        case ready(version: String)
        case lost
        case failed(String)
        case stopped

        var needsRecovery: Bool {
            switch self {
            case .lost, .failed: true
            default: false
            }
        }
    }

    private(set) var status: Status = .starting
    private(set) var lastCoreMessage: String?
    private(set) var sessions: [UUID: RepositorySession] = [:]

    @ObservationIgnored private let provider: any CoreProviding
    @ObservationIgnored private var windowWorkspace: [UUID: UUID] = [:]
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    /// Ids this hub closed itself; their REPOSITORY_CLOSED events are not
    /// "someone else closed it" and must not trigger a reopen.
    @ObservationIgnored private var ownCloses: Set<String> = []
    /// Returns the GitHub token to hand to the Core, or nil when signed out.
    @ObservationIgnored var githubTokenProvider: (@MainActor () async -> String?)?
    /// Called when GitHub refused the token, so the account can sign out.
    @ObservationIgnored var onGitHubTokenRejected: (@MainActor () async -> Void)?
    /// How often runs are re-read while any of them is queued or running.
    @ObservationIgnored var githubPollInterval: Duration = .seconds(20)

    init(provider: any CoreProviding) {
        self.provider = provider
    }

    func session(for workspaceID: UUID) -> RepositorySession? { sessions[workspaceID] }

    // MARK: Lifecycle

    func startMonitoring() {
        guard monitor == nil else { return }
        let provider = provider
        monitor = Task { [weak self] in
            for await state in await provider.states() {
                guard let self else { return }
                await self.handle(state)
            }
        }
    }

    func stopMonitoring() {
        monitor?.cancel()
        monitor = nil
        eventTask?.cancel()
        eventTask = nil
    }

    /// Restarts a lost or failed Core. Attached repositories reopen themselves
    /// when it is ready again.
    func recover() async {
        status = .starting
        do { try await provider.recover() }
        catch { status = .failed(Self.describe(error)) }
    }

    private var isReady: Bool {
        if case .ready = status { true } else { false }
    }

    private func handle(_ state: CoreConnectionState) async {
        switch state {
        case .stopped:
            // Not started yet (or stopped on purpose): nothing is broken, the
            // repositories simply wait for the Core.
            status = .stopped
            eventTask?.cancel()
            eventTask = nil
            for session in sessions.values { session.phase = .waitingForCore }
        case .starting:
            if !isReady { status = .starting }
        case .running(let health):
            status = .ready(version: health.coreVersion)
            // Close events of a previous Core process will never arrive.
            ownCloses.removeAll()
            startEvents()
            // A new Core process starts without a token.
            Task { await pushGitHubCredential() }
            // Not awaited: later states (a lost Core) must not wait for slow scans.
            Task { await openAll() }
        case .lost:
            status = .lost
            markUnavailable()
        case .failed(let error):
            status = .failed(Self.describe(error))
            markUnavailable()
        }
    }

    private func markUnavailable() {
        eventTask?.cancel()
        eventTask = nil
        for session in sessions.values { session.phase = .unavailable }
    }

    // MARK: GitHub credential

    /// Call after sign-in, sign-out or a rejected token so the Core holds the
    /// current token, or none.
    func githubCredentialChanged() {
        Task { await pushGitHubCredential() }
    }

    private func pushGitHubCredential() async {
        guard isReady, let service = try? await provider.service() else { return }
        let token = await githubTokenProvider?()
        try? await service.setGitHubCredential(token)
        // What the Core may read changed: reload every repository's activity.
        for workspaceID in sessions.keys { await loadGitHubActivity(workspaceID: workspaceID) }
    }

    // MARK: GitHub activity

    /// Reads the newest runs and the workflows of the repository's GitHub
    /// origin. While a run is queued or running, reads again after
    /// `githubPollInterval`. A call during a running load is not dropped: the
    /// load runs once more when the current one ends.
    func loadGitHubActivity(workspaceID: UUID) async {
        guard let session = sessions[workspaceID], session.coreID != nil, isReady else { return }
        guard session.githubRepository != nil else {
            session.githubAccess = .noRemote
            return
        }
        guard !session.isLoadingGitHub else {
            session.githubReloadPending = true
            return
        }
        session.isLoadingGitHub = true
        defer { session.isLoadingGitHub = false }
        repeat {
            session.githubReloadPending = false
            guard await loadGitHubActivityOnce(session) else { return }
        } while session.githubReloadPending && sessions[workspaceID] === session && isReady
        scheduleGitHubPoll(for: session)
    }

    /// One read of runs and workflows; false when it was cancelled.
    private func loadGitHubActivityOnce(_ session: RepositorySession) async -> Bool {
        let workspaceID = session.workspaceID
        guard let coreID = session.coreID else { return true }
        func isCurrent() -> Bool { sessions[workspaceID] === session && session.coreID == coreID }
        do {
            let service = try await provider.service()
            let runs = try await service.listWorkflowRuns(repositoryID: coreID, branch: nil, limit: 30)
            let workflows = runs.access == .ok ? try await service.listGitHubWorkflows(repositoryID: coreID) : nil
            guard isCurrent() else { return true }
            session.githubAccess = runs.access
            switch runs.access {
            case .ok:
                session.runs = runs.items
                if let workflows, workflows.access == .ok { session.remoteWorkflows = workflows.items }
                session.githubLoadedAt = Date()
            case .rateLimited, .unavailable:
                break // keep the last data; the access state says it may be stale
            case .noRemote, .signedOut, .tokenRejected, .notVisible:
                session.runs = []
                session.remoteWorkflows = []
            }
            if runs.access == .tokenRejected { await onGitHubTokenRejected?() }
        } catch is CancellationError {
            return false
        } catch {
            if isCurrent() { session.githubAccess = .unavailable }
        }
        return true
    }

    private func scheduleGitHubPoll(for session: RepositorySession) {
        session.githubPoll?.cancel()
        guard session.runs.contains(where: { $0.outcome.isActive }) else { return }
        let interval = githubPollInterval
        let workspaceID = session.workspaceID
        session.githubPoll = Task { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled, let self, self.sessions[workspaceID] === session else { return }
            await self.loadGitHubActivity(workspaceID: workspaceID)
        }
    }

    // MARK: Dispatch

    /// How long and how often to look for the run a dispatch started.
    @ObservationIgnored var runLookupTimeout: Duration = .seconds(60)
    @ObservationIgnored var runLookupInterval: Duration = .seconds(3)

    private func serviceAndCoreID(_ workspaceID: UUID) async -> (any CoreServicing, String)? {
        guard isReady, let coreID = sessions[workspaceID]?.coreID, let service = try? await provider.service() else { return nil }
        return (service, coreID)
    }

    func refs(workspaceID: UUID) async -> CoreGitHubRefs {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID),
              let refs = try? await service.listGitHubRefs(repositoryID: coreID) else {
            return CoreGitHubRefs(access: .unavailable, defaultBranch: "", branches: [], tags: [])
        }
        if refs.access == .tokenRejected { await onGitHubTokenRejected?() }
        return refs
    }

    func describeDispatch(workspaceID: UUID, workflowPath: String, ref: String) async -> CoreDispatchDefinition {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID),
              let definition = try? await service.describeWorkflowDispatch(repositoryID: coreID, workflowPath: workflowPath, ref: ref) else {
            return CoreDispatchDefinition(access: .unavailable, dispatchable: false, inputs: [], parseError: nil)
        }
        if definition.access == .tokenRejected { await onGitHubTokenRejected?() }
        return definition
    }

    func prepareDispatch(workspaceID: UUID, workflowID: Int64, ref: String, inputs: [String: String]) async -> CorePreparedDispatch {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID),
              let prepared = try? await service.prepareWorkflowDispatch(repositoryID: coreID, workflowID: workflowID, ref: ref, inputs: inputs) else {
            return CorePreparedDispatch(access: .unavailable, dispatchID: nil, expiresAt: nil, problems: [], workflowPath: "")
        }
        if prepared.access == .tokenRejected { await onGitHubTokenRejected?() }
        return prepared
    }

    /// Sends a prepared dispatch. nil means the confirmation expired or was
    /// already used, or the Core was not reachable: nothing was sent.
    func confirmDispatch(workspaceID: UUID, dispatchID: String) async -> CoreDispatchResult? {
        guard let (service, _) = await serviceAndCoreID(workspaceID),
              let result = try? await service.confirmWorkflowDispatch(dispatchID: dispatchID) else { return nil }
        if result.access == .tokenRejected { await onGitHubTokenRejected?() }
        return result
    }

    /// Finds the run a dispatch started: the run GitHub named, or the newest
    /// workflow_dispatch run of that workflow on that branch created at or
    /// after the dispatch and unknown before it. Reloads runs until found or
    /// until `runLookupTimeout`; nil means it has not appeared yet. Never sends
    /// the dispatch again.
    func locateDispatchedRun(workspaceID: UUID, workflowID: Int64, ref: String, dispatchedAt: Date,
                             knownRunIDs: Set<Int64>, reportedRunID: Int64?) async -> CoreWorkflowRun? {
        let clock = ContinuousClock()
        let deadline = clock.now + runLookupTimeout
        while !Task.isCancelled {
            await loadGitHubActivity(workspaceID: workspaceID)
            guard let session = sessions[workspaceID] else { return nil }
            let match = session.runs.first { run in
                if let reportedRunID { return run.id == reportedRunID }
                return !knownRunIDs.contains(run.id) && run.workflowID == workflowID && run.event == "workflow_dispatch"
                    && run.branch == ref && (run.createdAt ?? .distantPast) >= dispatchedAt.addingTimeInterval(-30)
            }
            if let match { return match }
            if clock.now >= deadline { return nil }
            try? await Task.sleep(for: runLookupInterval)
        }
        return nil
    }

    /// Jobs and steps of one run, read on demand.
    func jobs(workspaceID: UUID, runID: Int64) async -> CoreGitHubResult<CoreRunJob> {
        guard let coreID = sessions[workspaceID]?.coreID, isReady,
              let service = try? await provider.service() else {
            return CoreGitHubResult(access: .unavailable, items: [])
        }
        do {
            let result = try await service.listRunJobs(repositoryID: coreID, runID: runID)
            if result.access == .tokenRejected { await onGitHubTokenRejected?() }
            return result
        } catch {
            return CoreGitHubResult(access: .unavailable, items: [])
        }
    }

    // MARK: Logs and run actions

    /// The end of one job's log.
    func jobLog(workspaceID: UUID, jobID: Int64) async -> CoreJobLog {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else { return .failed(.unavailable) }
        do {
            let log = try await service.jobLog(repositoryID: coreID, jobID: jobID)
            if log.access == .tokenRejected { await onGitHubTokenRejected?() }
            return log
        } catch {
            return .failed(.unavailable)
        }
    }

    func prepareRunAction(workspaceID: UUID, runID: Int64, action: CoreRunAction) async -> CorePreparedRunAction {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID),
              let prepared = try? await service.prepareRunAction(repositoryID: coreID, runID: runID, action: action) else {
            return CorePreparedRunAction(access: .unavailable, actionID: nil, expiresAt: nil, problems: [], run: nil)
        }
        if prepared.access == .tokenRejected { await onGitHubTokenRejected?() }
        return prepared
    }

    /// Sends a prepared run action. nil means the confirmation expired or was
    /// already used, or the Core was not reachable: nothing was sent.
    func confirmRunAction(workspaceID: UUID, actionID: String) async -> CoreRunActionResult? {
        guard let (service, _) = await serviceAndCoreID(workspaceID),
              let result = try? await service.confirmRunAction(actionID: actionID) else { return nil }
        if result.access == .tokenRejected { await onGitHubTokenRejected?() }
        return result
    }

    /// After GitHub accepted a cancel or re-run, reloads runs until the run
    /// shows it (see `runShows`), or until `runLookupTimeout`. Returns the
    /// changed run, or nil when no change showed up in time. An active run
    /// then keeps being polled as usual.
    func followRunChange(workspaceID: UUID, from before: CoreWorkflowRun, action: CoreRunAction) async -> CoreWorkflowRun? {
        let clock = ContinuousClock()
        let deadline = clock.now + runLookupTimeout
        while !Task.isCancelled {
            await loadGitHubActivity(workspaceID: workspaceID)
            guard let session = sessions[workspaceID] else { return nil }
            if let run = session.runs.first(where: { $0.id == before.id }), Self.runShows(action, before: before, now: run) {
                return run
            }
            if clock.now >= deadline { return nil }
            try? await Task.sleep(for: runLookupInterval)
        }
        return nil
    }

    /// Whether a run reflects an accepted action. An active run changes all the
    /// time, so a cancel counts only once the run has finished; a re-run once
    /// a new attempt exists or the run is going again.
    nonisolated static func runShows(_ action: CoreRunAction, before: CoreWorkflowRun, now: CoreWorkflowRun) -> Bool {
        switch action {
        case .cancel: now.status == "completed"
        case .rerun, .rerunFailed: now.runAttempt > before.runAttempt || now.status != "completed"
        }
    }

    // MARK: Windows

    /// Associates a window with a workspace; the first window opens the
    /// repository in the Core. Re-attaching a window moves it, and a changed
    /// path (after relinking) reopens the repository.
    func attach(windowID: UUID, workspaceID: UUID, path: String) {
        if let previous = windowWorkspace[windowID], previous != workspaceID {
            release(windowID: windowID, from: previous)
        }
        windowWorkspace[windowID] = workspaceID
        if let existing = sessions[workspaceID] {
            existing.windowIDs.insert(windowID)
            guard existing.path != path else { return }
            let oldID = existing.coreID
            let oldPath = existing.path
            existing.path = path
            existing.coreID = nil
            existing.branch = ""
            existing.workflows = []
            existing.phase = .waitingForCore
            if let oldID { closeInCore(oldID, path: oldPath) }
            if isReady { Task { await open(existing) } }
            return
        }
        let session = RepositorySession(workspaceID: workspaceID, path: path)
        session.windowIDs = [windowID]
        sessions[workspaceID] = session
        if isReady { Task { await open(session) } }
    }

    /// Releases a window. The repository stays open in the Core while another
    /// window shows it and closes with the last one.
    func detach(windowID: UUID) {
        guard let workspaceID = windowWorkspace.removeValue(forKey: windowID) else { return }
        release(windowID: windowID, from: workspaceID)
    }

    private func release(windowID: UUID, from workspaceID: UUID) {
        guard let session = sessions[workspaceID] else { return }
        session.windowIDs.remove(windowID)
        guard session.windowIDs.isEmpty else { return }
        session.githubPoll?.cancel()
        sessions[workspaceID] = nil
        if let coreID = session.coreID { closeInCore(coreID, path: session.path) }
    }

    private func isShown(_ path: String) -> Bool { sessions.values.contains { $0.path == path } }

    /// Closes a repository in the Core unless a window shows its path again.
    /// Core contexts are shared by path and closing is global, so a close that
    /// raced with a reopen of the same path is followed by a fresh open.
    private func closeInCore(_ repositoryID: String, path: String) {
        Task {
            guard !isShown(path) else { return }
            // A missing Core or repository means there is nothing left to close.
            guard let service = try? await provider.service() else { return }
            ownCloses.insert(repositoryID)
            do {
                try await service.closeRepository(id: repositoryID)
            } catch {
                // No close happened, so no event will come to clear the mark.
                ownCloses.remove(repositoryID)
            }
            if let reopened = sessions.values.first(where: { $0.path == path }) {
                await open(reopened, force: true)
            }
        }
    }

    // MARK: Repository operations

    private func openAll() async {
        // Opens run side by side; each task stays on the main actor.
        let tasks = sessions.values.map { session in Task { await open(session) } }
        for task in tasks { await task.value }
    }

    /// Opens the session's repository. An open already in flight for the same
    /// session is not repeated (attach and the Core-ready handler can both ask);
    /// `force` reopens anyway, for a close that may have overtaken that open.
    private func open(_ session: RepositorySession, force: Bool = false) async {
        guard isReady else { session.phase = .unavailable; return }
        guard force || session.phase != .opening else { return }
        session.phase = .opening
        let path = session.path
        // The session may move to another path (relink) or go away (last window
        // closed) while this open is in flight; its result then must not land.
        func isCurrent() -> Bool { sessions[session.workspaceID] === session && session.path == path }
        do {
            let service = try await provider.service()
            let repository = try await service.openRepository(path: path)
            guard isCurrent() else {
                closeInCore(repository.id, path: path)
                return
            }
            session.coreID = repository.id
            let workflows = try await service.listWorkflows(repositoryID: repository.id)
            guard isCurrent() else { return }
            apply(repository, workflows: workflows, to: session)
            session.phase = .ready
            Task { await loadGitHubActivity(workspaceID: session.workspaceID) }
        } catch let error as CoreServiceError where error == .unavailable {
            if isCurrent() { session.phase = .unavailable }
        } catch is CancellationError {
            // Do not leave the session looking busy, which would block retries.
            if isCurrent() { session.phase = .waitingForCore }
        } catch {
            if isCurrent() { session.phase = .failed(Self.describe(error)) }
        }
    }

    func refresh(workspaceID: UUID) async {
        guard let session = sessions[workspaceID], !session.isRefreshing, isReady else { return }
        guard let coreID = session.coreID else {
            // Never opened (failed, timed out or the Core was away): Refresh is the retry.
            if session.phase != .opening { await open(session) }
            return
        }
        session.isRefreshing = true
        defer { session.isRefreshing = false }
        let path = session.path
        // A relink can move the session to another repository meanwhile.
        func isCurrent() -> Bool {
            sessions[workspaceID] === session && session.path == path && session.coreID == coreID
        }
        do {
            let service = try await provider.service()
            let repository = try await service.refreshRepository(id: coreID)
            let workflows = try await service.listWorkflows(repositoryID: coreID)
            guard isCurrent() else { return }
            apply(repository, workflows: workflows, to: session)
            session.refreshError = nil
            Task { await loadGitHubActivity(workspaceID: workspaceID) }
        } catch let error as CoreServiceError where error == .notFound {
            if isCurrent() { await open(session) }
        } catch let error as CoreServiceError where error == .unavailable {
            if isCurrent() { session.phase = .unavailable }
        } catch is CancellationError {
            return
        } catch {
            if isCurrent() { session.refreshError = Self.describe(error) }
        }
    }

    private func apply(_ repository: CoreRepository, workflows: [CoreWorkflow], to session: RepositorySession) {
        session.coreID = repository.id
        session.branch = repository.branch
        session.githubRepository = repository.githubRepository
        session.lastRefresh = repository.lastRefresh
        session.workflows = workflows
    }

    // MARK: Events

    private func startEvents() {
        eventTask?.cancel()
        let provider = provider
        eventTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let service = try await provider.service()
                    for try await event in service.events(repositoryIDs: []) {
                        guard let self else { return }
                        self.apply(event)
                    }
                    return
                } catch let error as CoreServiceError where error == .resourceExhausted {
                    // We fell behind: reload everything, then listen again.
                    guard let self else { return }
                    await self.resync()
                } catch {
                    // The supervisor reports a lost Core; nothing to retry here.
                    return
                }
            }
        }
    }

    private func resync() async {
        await openAll()
    }

    private func apply(_ event: CoreEvent) {
        switch event.kind {
        case .repositoryRefreshed:
            guard let session = session(forCoreID: event.repositoryID),
                  !session.isRefreshing, event.sequence > session.appliedSequence else { return }
            session.appliedSequence = event.sequence
            reloadWorkflows(of: session)
        case .repositoryClosed:
            // A close this hub sent is followed by its own reopen when needed.
            if let id = event.repositoryID, ownCloses.remove(id) != nil { return }
            guard let session = session(forCoreID: event.repositoryID), session.phase == .ready else { return }
            Task { await open(session) }
        case .coreError:
            lastCoreMessage = event.message
        default:
            break
        }
    }

    private func session(forCoreID id: String?) -> RepositorySession? {
        guard let id else { return nil }
        return sessions.values.first { $0.coreID == id }
    }

    private func reloadWorkflows(of session: RepositorySession) {
        guard let coreID = session.coreID else { return }
        let provider = provider
        Task {
            guard let service = try? await provider.service(),
                  let workflows = try? await service.listWorkflows(repositoryID: coreID),
                  sessions[session.workspaceID] === session, session.coreID == coreID else { return }
            session.workflows = workflows
        }
    }

    // MARK: Text

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as CoreSupervisorError:
            switch error {
            case .helperUnavailable: "The bundled Core is missing from the app."
            case .alreadyRunning: "Another Runnir instance is already running the Core."
            case .timedOut: "The Core did not become ready in time."
            case .incompatibleProtocol(let version): "The Core speaks protocol \(version), which this app does not support."
            case .launchFailed: "The Core could not be launched."
            case .processExited(let code): "The Core exited with status \(code)."
            case .socketPathTooLong: "The Core's socket path is too long for this system."
            }
        case let error as CoreServiceError:
            switch error {
            case .unavailable: "The Core is not available."
            case .notFound: "The repository is not open in the Core."
            case .accessDenied: "The Core cannot read this folder. Use Locate / Grant Access to renew access."
            case .invalidArgument, .failedPrecondition: "The Core could not use this folder."
            case .resourceExhausted: "The Core is busy. Try again."
            case .timedOut: "The Core took too long to answer. Press Refresh to try again."
            case .incompatibleProtocol(let version): "The Core speaks protocol \(version), which this app does not support."
            case .remote: "The Core request failed."
            }
        default:
            "The Core request failed."
        }
    }
}
