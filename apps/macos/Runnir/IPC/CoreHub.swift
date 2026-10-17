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
    fileprivate(set) var workflows: [CoreWorkflow] = []
    fileprivate(set) var lastRefresh: Date?
    fileprivate(set) var isRefreshing = false
    fileprivate(set) var refreshError: String?
    @ObservationIgnored fileprivate var windowIDs: Set<UUID> = []
    @ObservationIgnored fileprivate var appliedSequence: UInt64 = 0

    fileprivate init(workspaceID: UUID, path: String) {
        self.workspaceID = workspaceID
        self.path = path
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
            status = .stopped
            markUnavailable()
        case .starting:
            if !isReady { status = .starting }
        case .running(let health):
            status = .ready(version: health.coreVersion)
            startEvents()
            await openAll()
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
            existing.path = path
            existing.coreID = nil
            existing.branch = ""
            existing.workflows = []
            existing.phase = .waitingForCore
            if let oldID { closeInCore(oldID) }
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
        sessions[workspaceID] = nil
        if let coreID = session.coreID { closeInCore(coreID) }
    }

    private func closeInCore(_ repositoryID: String) {
        let provider = provider
        Task {
            // A missing Core or repository means there is nothing left to close.
            if let service = try? await provider.service() {
                try? await service.closeRepository(id: repositoryID)
            }
        }
    }

    // MARK: Repository operations

    private func openAll() async {
        // Opens run side by side; each task stays on the main actor.
        let tasks = sessions.values.map { session in Task { await open(session) } }
        for task in tasks { await task.value }
    }

    private func open(_ session: RepositorySession) async {
        guard isReady else { session.phase = .unavailable; return }
        session.phase = .opening
        do {
            let service = try await provider.service()
            let repository = try await service.openRepository(path: session.path)
            guard sessions[session.workspaceID] === session else {
                // The last window closed while the open was in flight.
                try? await service.closeRepository(id: repository.id)
                return
            }
            session.coreID = repository.id
            let workflows = try await service.listWorkflows(repositoryID: repository.id)
            guard sessions[session.workspaceID] === session else { return }
            apply(repository, workflows: workflows, to: session)
            session.phase = .ready
        } catch let error as CoreServiceError where error == .unavailable {
            session.phase = .unavailable
        } catch is CancellationError {
            return
        } catch {
            session.phase = .failed(Self.describe(error))
        }
    }

    func refresh(workspaceID: UUID) async {
        guard let session = sessions[workspaceID], let coreID = session.coreID,
              !session.isRefreshing, isReady else { return }
        session.isRefreshing = true
        defer { session.isRefreshing = false }
        do {
            let service = try await provider.service()
            let repository = try await service.refreshRepository(id: coreID)
            let workflows = try await service.listWorkflows(repositoryID: coreID)
            guard sessions[workspaceID] === session else { return }
            apply(repository, workflows: workflows, to: session)
            session.refreshError = nil
        } catch let error as CoreServiceError where error == .notFound {
            await open(session)
        } catch let error as CoreServiceError where error == .unavailable {
            session.phase = .unavailable
        } catch is CancellationError {
            return
        } catch {
            session.refreshError = Self.describe(error)
        }
    }

    private func apply(_ repository: CoreRepository, workflows: [CoreWorkflow], to session: RepositorySession) {
        session.coreID = repository.id
        session.branch = repository.branch
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
            // Our own closes remove the session first, so a match means someone
            // else closed a repository a window still shows.
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
                  sessions[session.workspaceID] === session else { return }
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
            }
        case let error as CoreServiceError:
            switch error {
            case .unavailable: "The Core is not available."
            case .notFound: "The repository is not open in the Core."
            case .accessDenied: "The Core cannot read this folder. Use Locate / Grant Access to renew access."
            case .invalidArgument, .failedPrecondition: "The Core could not use this folder."
            case .resourceExhausted: "The Core is busy. Try again."
            case .incompatibleProtocol(let version): "The Core speaks protocol \(version), which this app does not support."
            case .remote: "The Core request failed."
            }
        default:
            "The Core request failed."
        }
    }
}
