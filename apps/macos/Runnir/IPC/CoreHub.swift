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

/// Loading runs older than the cached ones, as the run list's end shows it.
enum OlderRunsState: Equatable {
    case idle
    case loading
    /// GitHub did not answer; Retry asks again.
    case failed(CoreGitHubAccess)
    /// The Core keeps 5000 runs; older ones are on GitHub.
    case budgetReached
}

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
    /// The server of `githubRepository`; empty is github.com.
    fileprivate(set) var githubServerID: String?
    /// The origin's host, even when it is on no server Runnir knows.
    fileprivate(set) var originHost: String?
    /// `githubRepository` on its server.
    var githubRef: GitHubRepositoryRef? {
        githubRepository.map { GitHubRepositoryRef(serverID: githubServerID ?? "", fullName: $0) }
    }
    fileprivate(set) var workflows: [CoreWorkflow] = []
    /// Run Workflow presets the repository shares in .runnir/launches, with
    /// entries for files that cannot be used, as the Core last read them.
    fileprivate(set) var launchPresets: [CoreLaunchPreset] = []
    /// Why the last read of `launchPresets` failed; the previous list stays.
    fileprivate(set) var launchPresetsError: String?
    /// Counts reads of `launchPresets`; only the latest one may land.
    @ObservationIgnored fileprivate var launchPresetReads = 0
    fileprivate(set) var lastRefresh: Date?
    fileprivate(set) var isRefreshing = false
    fileprivate(set) var refreshError: String?
    /// GitHub Actions data for `githubRepository`, saved and synced by the
    /// Core; shown at once and kept when access is lost.
    fileprivate(set) var runs: [CoreWorkflowRun] = []
    fileprivate(set) var remoteWorkflows: [CoreGitHubWorkflow] = []
    /// How fresh `runs` and `remoteWorkflows` are, as the Core says.
    fileprivate(set) var freshness = CoreActivityFreshness()
    /// The changes of `runs` and the concurrency suggestions, as the Core
    /// grouped them.
    fileprivate(set) var changes: [CoreRunChange] = []
    fileprivate(set) var concurrencyHints: [CoreConcurrencyHint] = []
    /// Every run the Core keeps, and whether GitHub has none older.
    fileprivate(set) var cachedRuns = 0
    fileprivate(set) var historyComplete = false
    /// What this Mac saved the workspace, as the Core counted it.
    fileprivate(set) var savings: [CoreSaving] = []
    /// How many of the newest runs the session reads; grows as lists scroll.
    fileprivate(set) var activityLimit = CoreHub.activityPage
    /// The limit a search replaced to cover every saved run; nil outside a search.
    fileprivate var limitBeforeSearch: Int?
    fileprivate(set) var olderRuns: OlderRunsState = .idle
    /// The last sync pass's outcome, or why there is none; nil before the first.
    var githubAccess: CoreGitHubAccess? { freshness.access }
    var activitySource: CoreActivitySource { freshness.source }
    var isLoadingGitHub: Bool { freshness.syncing || isReadingActivity || isRefreshingActivity }
    /// When GitHub last answered.
    var githubLoadedAt: Date? { freshness.syncedAt }
    fileprivate(set) var isReadingActivity = false
    /// A Reload is waiting for the Core's pass; apart from cache reads, so
    /// one ending never clears the other.
    fileprivate(set) var isRefreshingActivity = false
    /// The GitHub repository as the Core last read it: whether the user can
    /// push, and the owner's installation with permissions waiting for an
    /// owner. Read on demand (`githubRepository(workspaceID:)`), not polled.
    fileprivate(set) var githubDetails: CoreGitHubRepository?
    /// The workspace's latest local run, shared by its windows.
    fileprivate(set) var localRun: LocalRunModel?
    /// A read was asked for while one ran; read once more after it.
    @ObservationIgnored fileprivate var activityReadPending = false
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

        /// The running Core's version; nil until it is ready.
        var coreVersion: String? {
            if case .ready(let version) = self { version } else { nil }
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
    /// Closes in flight for workspaces whose last window went away, so
    /// deleting their data waits until the Core let go of them.
    @ObservationIgnored private var closing: [UUID: Task<Void, Never>] = [:]
    /// Returns the GitHub token to hand to the Core, or nil when signed out.
    @ObservationIgnored var githubTokenProvider: (@MainActor () async -> String?)?
    /// Called when GitHub refused the token, so the account can sign out.
    @ObservationIgnored var onGitHubTokenRejected: (@MainActor () async -> Void)?
    /// A local run finished, with its workspace's name.
    @ObservationIgnored var onLocalRunFinished: (@MainActor (LocalRunModel, String) -> Void)?
    /// First wait before subscribing to events again after the stream ended
    /// while the Core still runs; doubles up to 30 seconds.
    @ObservationIgnored var eventRetryDelay: Duration = .milliseconds(500)

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
            // A new Core process starts without a token or storage preferences.
            schedulePush()
            Task { await pushStoragePreferences() }
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
        schedulePush()
    }

    /// Pushes run one after another, each reading the token and servers
    /// when it starts: a slow one (a Keychain prompt) cannot hand the Core
    /// a server removed while it waited.
    @ObservationIgnored private var credentialPush: Task<Void, Never>?

    private func schedulePush() {
        let previous = credentialPush
        credentialPush = Task { await previous?.value; await pushGitHubCredential() }
    }

    /// Counts the tokens handed to the Core, so a view that read GitHub
    /// before the Core had the new one (just after signing in) reads again.
    private(set) var credentialGeneration = 0
    /// When tokens were last handed to the Core.
    @ObservationIgnored private var credentialPushedAt: Date?

    /// The Enterprise servers to sign in to, with their tokens.
    @ObservationIgnored var enterpriseCredentialsProvider: (@MainActor () async -> [(server: GitHubServerRef, token: String)])?

    /// Kinds of the tokens the Core holds, by server id ("" is github.com).
    private(set) var credentialKinds: [String: CoreGitHubCredentialKind] = [:]
    /// github.com's token kind; nil when signed out of github.com.
    var credentialKind: CoreGitHubCredentialKind? { credentialKinds[""] }
    /// Servers the Core holds a token for: github.com first, then Enterprise.
    private(set) var signedInServers: [GitHubServerRef] = []
    /// Every Enterprise server handed over, signed in or not, for names.
    private(set) var enterpriseServers: [GitHubServerRef] = []

    /// An Enterprise server by id; nil for github.com ("" or nil) or one
    /// the hub was not given.
    func serverRef(for serverID: String?) -> GitHubServerRef? {
        guard let serverID, !serverID.isEmpty else { return nil }
        return enterpriseServers.first { $0.id == serverID }
    }

    /// The kind of token the Core holds for a server; "" or nil is github.com.
    func credentialKind(for serverID: String?) -> CoreGitHubCredentialKind? {
        credentialKinds[serverID ?? ""]
    }

    /// Help for a workspace's access outcome, with its server and origin.
    func accessHelp(_ access: CoreGitHubAccess, workspaceID: UUID, purpose: GitHubAccessHelp.Purpose,
                    details: CoreGitHubRepository? = nil) -> GitHubAccessHelp? {
        let session = sessions[workspaceID]
        return GitHubAccessHelp.forAccess(access, repository: session?.githubRepository, purpose: purpose, details: details,
                                          credential: credentialKind(for: session?.githubServerID),
                                          server: serverRef(for: session?.githubServerID), originHost: session?.originHost)
    }
    @ObservationIgnored private var pushedEnterpriseIDs: Set<String> = []

    private func pushGitHubCredential() async {
        guard isReady, let service = try? await provider.service() else { return }
        var kinds: [String: CoreGitHubCredentialKind] = [:]
        var servers: [GitHubServerRef] = []
        if let kind = (try? await service.setGitHubCredential(await githubTokenProvider?(), server: .dotCom)) ?? nil {
            kinds[""] = kind
            servers.append(.dotCom)
        }
        let enterprise = await enterpriseCredentialsProvider?() ?? []
        for (server, token) in enterprise {
            if let kind = (try? await service.setGitHubCredential(token, server: server)) ?? nil {
                kinds[server.id] = kind
                servers.append(server)
            }
        }
        // Forget servers removed since the last push.
        let current = Set(enterprise.map(\.server.id))
        for id in pushedEnterpriseIDs.subtracting(current) {
            _ = try? await service.setGitHubCredential(nil, server: GitHubServerRef(id: id, apiURL: nil, webHost: ""))
        }
        // Which GitHub server a working tree is on depends on the servers
        // the Core holds: when they changed, open repositories are read again.
        let serversChanged = current != pushedEnterpriseIDs
        pushedEnterpriseIDs = current
        enterpriseServers = enterprise.map(\.server)
        credentialKinds = kinds
        signedInServers = servers
        credentialGeneration += 1
        credentialPushedAt = Date()
        // The Core syncs again on its own when a token changes. Which server
        // a working tree is on depends on the servers it holds: when they
        // changed, open repositories are read again.
        if serversChanged {
            for workspaceID in sessions.keys { await refresh(workspaceID: workspaceID) }
        }
    }

    /// Whether a call's repository is on github.com, whose rejected sign-in
    /// GitHubSession forgets. An Enterprise server's rejected token is
    /// forgotten by the Core alone; its notice asks for a new token.
    private func isDotCom(_ target: GitHubTarget) -> Bool {
        switch target {
        case .workspace(let workspaceID): (sessions[workspaceID]?.githubServerID ?? "").isEmpty
        case .repository(let ref): ref.serverID.isEmpty
        }
    }

    private func tokenRejected(on target: GitHubTarget) async {
        if isDotCom(target) { await onGitHubTokenRejected?() }
    }

    // MARK: GitHub activity

    /// How many runs a session reads at first, and how many more each time
    /// a list reaches its end.
    static let activityPage = 200
    /// The Core keeps at most this many runs per workspace.
    static let maxActivityLimit = 5000
    /// How often the Core's sync reads a workspace with an active run
    /// (`workspace.DefaultIntervals` in the Core).
    static let activeSyncInterval: Duration = .seconds(20)

    /// Asks the Core's sync for a pass and shows the result. The Core merges
    /// requests from every window into one pass and schedules the next one
    /// itself, faster while a run is active.
    func loadGitHubActivity(workspaceID: UUID) async {
        guard let session = sessions[workspaceID], let coreID = session.coreID, isReady,
              let service = try? await provider.service() else { return }
        session.isRefreshingActivity = true
        defer { session.isRefreshingActivity = false }
        guard let activity = try? await service.refreshWorkspaceActivity(repositoryID: coreID, wait: true, limit: session.activityLimit),
              sessions[workspaceID] === session, session.coreID == coreID else { return }
        await apply(activity, to: session)
    }

    /// Reads the saved activity. One read per session at a time; a request
    /// during it reads once more afterwards.
    private func readActivity(of session: RepositorySession) async {
        guard !session.isReadingActivity else {
            session.activityReadPending = true
            return
        }
        session.isReadingActivity = true
        defer { session.isReadingActivity = false }
        repeat {
            session.activityReadPending = false
            guard let coreID = session.coreID, isReady, let service = try? await provider.service(),
                  let activity = try? await service.workspaceActivity(repositoryID: coreID, limit: session.activityLimit),
                  sessions[session.workspaceID] === session, session.coreID == coreID else { return }
            await apply(activity, to: session)
        } while session.activityReadPending && sessions[session.workspaceID] === session
    }

    private func apply(_ activity: CoreWorkspaceActivity, to session: RepositorySession) async {
        let previous = session.freshness.access
        let previousPullRequests = session.freshness.pullRequestsAccess
        session.runs = activity.runs
        session.remoteWorkflows = activity.workflows
        session.freshness = activity.freshness
        session.changes = activity.changes
        session.concurrencyHints = activity.concurrencyHints
        session.cachedRuns = activity.cachedRuns
        session.historyComplete = activity.historyComplete
        session.savings = activity.savings
        // Whether an owner has to accept the pull request permission decides
        // what the note asks for.
        if activity.freshness.pullRequestsAccess == .permissionMissing, previousPullRequests != .permissionMissing {
            await githubRepository(workspaceID: session.workspaceID)
        }
        let access = activity.freshness.access
        guard access != previous else { return }
        // Only a rejection of the token the Core holds now signs out: one
        // checked before the last hand-over was about an earlier token.
        if access == .tokenRejected, (activity.freshness.checkedAt ?? .distantPast) >= (credentialPushedAt ?? .distantPast) {
            await tokenRejected(on: .workspace(session.workspaceID))
        }
        // Whether an owner has to accept permissions, or the user lacks
        // access, decides what the notice asks for.
        if access == .permissionMissing { await githubRepository(workspaceID: session.workspaceID) }
    }

    /// Shows every run saved on this Mac, up to the budget, so a search covers
    /// them all. It reads the Core's saved activity only: nothing goes to
    /// GitHub, so it works offline too.
    func loadSavedRuns(workspaceID: UUID) async {
        guard let session = sessions[workspaceID] else { return }
        let wanted = min(Self.maxActivityLimit, session.cachedRuns)
        guard wanted > session.activityLimit else { return }
        if session.limitBeforeSearch == nil { session.limitBeforeSearch = session.activityLimit }
        session.activityLimit = wanted
        await readActivity(of: session)
    }

    /// Goes back to the runs shown before the search, so later syncs and reads
    /// do not keep carrying the whole cache.
    func endSavedRunsSearch(workspaceID: UUID) async {
        guard let session = sessions[workspaceID], let before = session.limitBeforeSearch else { return }
        session.limitBeforeSearch = nil
        session.activityLimit = before
        await readActivity(of: session)
    }

    /// Shows more runs when a list reaches its end: 200 more from the cache,
    /// or, once every cached run is shown, one page of older runs from GitHub.
    func showMoreRuns(workspaceID: UUID) async {
        guard let session = sessions[workspaceID], session.olderRuns != .loading else { return }
        if session.cachedRuns > session.runs.count {
            session.activityLimit = min(Self.maxActivityLimit, session.activityLimit + Self.activityPage)
            await readActivity(of: session)
            return
        }
        guard !session.historyComplete, session.olderRuns != .budgetReached, session.githubAccess == .ok,
              let coreID = session.coreID, isReady, let service = try? await provider.service() else { return }
        session.olderRuns = .loading
        let result = try? await service.loadOlderRuns(repositoryID: coreID)
        guard sessions[workspaceID] === session else { return }
        switch result {
        case nil:
            session.olderRuns = .failed(.unavailable)
        case let result? where result.budgetReached && result.added == 0:
            session.olderRuns = .budgetReached
        case let result? where result.access != .ok:
            session.olderRuns = .failed(result.access)
        case let result?:
            session.olderRuns = result.budgetReached ? .budgetReached : .idle
            session.activityLimit = min(Self.maxActivityLimit, max(session.activityLimit, session.runs.count + result.added))
            await readActivity(of: session)
        }
    }

    /// The editor's text with the suggested concurrency block from the Core;
    /// nil when the Core is not ready or did not answer.
    func insertWorkflowConcurrency(workspaceID: UUID, content: String) async -> CoreConcurrencyInsertion? {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else { return nil }
        return try? await service.insertWorkflowConcurrency(repositoryID: coreID, content: content)
    }

    /// What keeps the Core from reading the workspace's pull requests, and
    /// the fix; nil when it reads them.
    func pullRequestsHelp(workspaceID: UUID) -> GitHubAccessHelp? {
        guard let session = sessions[workspaceID], let access = session.freshness.pullRequestsAccess,
              access == .permissionMissing || access == .notVisible else { return nil }
        return GitHubAccessHelp.pullRequestsUnreadable(repository: session.githubRepository, details: session.githubDetails,
                                                       credential: credentialKind(for: session.githubServerID),
                                                       server: serverRef(for: session.githubServerID))
    }

    // MARK: Dispatch

    /// How long and how often to look for the run a dispatch started.
    @ObservationIgnored var runLookupTimeout: Duration = .seconds(60)
    @ObservationIgnored var runLookupInterval: Duration = .seconds(3)

    private func serviceAndCoreID(_ workspaceID: UUID) async -> (any CoreServicing, String)? {
        guard isReady, let coreID = sessions[workspaceID]?.coreID, let service = try? await provider.service() else { return nil }
        return (service, coreID)
    }

    /// The repository a GitHub call is about: a workspace's origin, or a
    /// repository on a server that has no local clone.
    enum GitHubTarget: Hashable, Sendable {
        case workspace(UUID)
        case repository(GitHubRepositoryRef)
    }

    private func serviceAndTarget(_ target: GitHubTarget) async -> (any CoreServicing, CoreGitHubTarget)? {
        switch target {
        case .workspace(let workspaceID):
            guard let (service, coreID) = await serviceAndCoreID(workspaceID) else { return nil }
            return (service, .repository(coreID))
        case .repository(let ref):
            guard isReady, let service = try? await provider.service() else { return nil }
            return (service, .named(ref))
        }
    }

    func refs(workspaceID: UUID) async -> CoreGitHubRefs { await refs(target: .workspace(workspaceID)) }

    func refs(target: GitHubTarget) async -> CoreGitHubRefs {
        guard let (service, coreTarget) = await serviceAndTarget(target),
              let refs = try? await service.listGitHubRefs(target: coreTarget) else {
            return CoreGitHubRefs(access: .unavailable, defaultBranch: "", branches: [], tags: [])
        }
        if refs.access == .tokenRejected { await tokenRejected(on: target) }
        return refs
    }

    func describeDispatch(workspaceID: UUID, workflowPath: String, ref: String) async -> CoreDispatchDefinition {
        await describeDispatch(target: .workspace(workspaceID), workflowPath: workflowPath, ref: ref)
    }

    func describeDispatch(target: GitHubTarget, workflowPath: String, ref: String) async -> CoreDispatchDefinition {
        guard let (service, coreTarget) = await serviceAndTarget(target),
              let definition = try? await service.describeWorkflowDispatch(target: coreTarget, workflowPath: workflowPath, ref: ref) else {
            return CoreDispatchDefinition(access: .unavailable, dispatchable: false, inputs: [], parseError: nil)
        }
        if definition.access == .tokenRejected { await tokenRejected(on: target) }
        return definition
    }

    func prepareDispatch(workspaceID: UUID, workflowID: Int64, ref: String, inputs: [String: String]) async -> CorePreparedDispatch {
        await prepareDispatch(target: .workspace(workspaceID), workflowID: workflowID, ref: ref, inputs: inputs)
    }

    func prepareDispatch(target: GitHubTarget, workflowID: Int64, ref: String, inputs: [String: String]) async -> CorePreparedDispatch {
        guard let (service, coreTarget) = await serviceAndTarget(target),
              let prepared = try? await service.prepareWorkflowDispatch(target: coreTarget, workflowID: workflowID, ref: ref, inputs: inputs) else {
            return CorePreparedDispatch(access: .unavailable, dispatchID: nil, expiresAt: nil, problems: [], workflowPath: "")
        }
        if prepared.access == .tokenRejected { await tokenRejected(on: target) }
        return prepared
    }

    func confirmDispatch(workspaceID: UUID, dispatchID: String) async -> CoreDispatchResult? {
        await confirmDispatch(target: .workspace(workspaceID), dispatchID: dispatchID)
    }

    /// Sends a prepared dispatch. nil means the confirmation expired or was
    /// already used, or the Core was not reachable: nothing was sent.
    func confirmDispatch(target: GitHubTarget, dispatchID: String) async -> CoreDispatchResult? {
        guard let (service, _) = await serviceAndTarget(target),
              let result = try? await service.confirmWorkflowDispatch(dispatchID: dispatchID) else { return nil }
        if result.access == .tokenRejected { await tokenRejected(on: target) }
        return result
    }

    /// The dispatches sent from this Mac for a workflow of a workspace, newest
    /// first. Empty when there are none or the Core cannot say.
    func dispatchHistory(workspaceID: UUID, workflowPath: String) async -> [CoreDispatchRecord] {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID),
              let records = try? await service.dispatchHistory(repositoryID: coreID, workflowPath: workflowPath) else { return [] }
        return records
    }

    /// Tells the Core which run a history entry started. A failure only
    /// leaves the entry without a run.
    func linkDispatchRun(workspaceID: UUID, historyID: Int64, runID: Int64) async {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else { return }
        try? await service.linkDispatchRun(repositoryID: coreID, id: historyID, runID: runID)
    }

    /// Forgets the dispatch history of the workspace's repository. False when
    /// the Core could not do it, so the list is left as it is.
    func clearDispatchHistory(workspaceID: UUID) async -> Bool {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else { return false }
        return (try? await service.clearDispatchHistory(repositoryID: coreID)) != nil
    }

    /// Runs known before a dispatch, so the run it starts can be told apart.
    func knownRunIDs(_ target: GitHubTarget) async -> Set<Int64> {
        switch target {
        case .workspace(let workspaceID):
            return Set(sessions[workspaceID]?.runs.map(\.id) ?? [])
        case .repository:
            return Set(await runs(of: target, limit: 30).items.map(\.id))
        }
    }

    func locateDispatchedRun(workspaceID: UUID, workflowID: Int64, ref: String, dispatchedAt: Date,
                             knownRunIDs: Set<Int64>, reportedRunID: Int64?) async -> CoreWorkflowRun? {
        await locateDispatchedRun(target: .workspace(workspaceID), workflowID: workflowID, ref: ref, dispatchedAt: dispatchedAt,
                                  knownRunIDs: knownRunIDs, reportedRunID: reportedRunID)
    }

    /// Finds the run a dispatch started: the run GitHub named, or the newest
    /// workflow_dispatch run of that workflow on that branch created at or
    /// after the dispatch and unknown before it. Reloads runs until found or
    /// until `runLookupTimeout`; nil means it has not appeared yet. Never sends
    /// the dispatch again.
    func locateDispatchedRun(target: GitHubTarget, workflowID: Int64, ref: String, dispatchedAt: Date,
                             knownRunIDs: Set<Int64>, reportedRunID: Int64?) async -> CoreWorkflowRun? {
        let clock = ContinuousClock()
        let deadline = clock.now + runLookupTimeout
        while !Task.isCancelled {
            let runs: [CoreWorkflowRun]
            switch target {
            case .workspace(let workspaceID):
                await loadGitHubActivity(workspaceID: workspaceID)
                guard let session = sessions[workspaceID] else { return nil }
                runs = session.runs
            case .repository:
                runs = await self.runs(of: target, limit: 30).items
            }
            let match = runs.first { run in
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

    /// The GitHub repository of a workspace or one named directly: whether
    /// the user can push, and the owner's installation. A workspace keeps it
    /// in its session.
    @discardableResult
    func githubRepository(target: GitHubTarget) async -> CoreGitHubRepository {
        if case .workspace(let workspaceID) = target { return await githubRepository(workspaceID: workspaceID) }
        guard let (service, coreTarget) = await serviceAndTarget(target),
              let repository = try? await service.gitHubRepository(target: coreTarget) else { return .failed(.unavailable) }
        if repository.access == .tokenRejected { await tokenRejected(on: target) }
        return repository
    }

    // MARK: Repositories without a local clone

    /// The GitHub repository of each working tree's origin, by path; nil
    /// when the Core is not ready.
    func githubOrigins(paths: [String]) async -> [String: GitHubRepositoryRef]? {
        guard isReady, let service = try? await provider.service() else { return nil }
        return try? await service.githubOrigins(paths: Array(paths.prefix(500)))
    }

    /// Pull requests from every signed-in server, merged newest first, each
    /// with its server. `.ok` when any server answered, else the first
    /// failure.
    func pullRequests(closedSince: Date) async -> CorePullRequests {
        guard isReady, let service = try? await provider.service() else { return .failed(.unavailable) }
        // Before the first push github.com is asked, and says if it has no token.
        let servers = signedInServers.isEmpty ? [GitHubServerRef.dotCom] : signedInServers
        var open: [CorePullRequest] = [], closed: [CorePullRequest] = []
        var answered = 0, headsUnreadable = false
        var pending: [CoreGitHubInstallation] = []
        var firstFailure: CoreGitHubAccess?
        for server in servers {
            guard let result = try? await service.listPullRequests(server: server.id, closedSince: closedSince) else {
                firstFailure = firstFailure ?? .unavailable
                continue
            }
            if result.access == .tokenRejected, server.isDotCom { await onGitHubTokenRejected?() }
            guard result.access == .ok else {
                firstFailure = firstFailure ?? result.access
                continue
            }
            answered += 1
            headsUnreadable = headsUnreadable || result.headsUnreadable
            pending += result.pendingInstallations
            open += result.open.map { var pr = $0; pr.server = server.id; return pr }
            closed += result.closed.map { var pr = $0; pr.server = server.id; return pr }
        }
        guard answered > 0 else { return .failed(firstFailure ?? .unavailable) }
        // Each server's list is already newest first; only a merge is sorted.
        if answered > 1 {
            let newest: (CorePullRequest, CorePullRequest) -> Bool = { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
            open.sort(by: newest)
            closed.sort(by: newest)
        }
        return CorePullRequests(access: .ok, open: open, closed: closed, headsUnreadable: headsUnreadable, pendingInstallations: pending)
    }

    /// What a token can do, asked of GitHub through the Core without
    /// changing the token the Core holds.
    func checkGitHubToken(_ token: String, server: GitHubServerRef = .dotCom) async -> CoreGitHubTokenCheck {
        guard isReady, let service = try? await provider.service() else { return .failed(.unavailable) }
        do {
            return try await service.checkGitHubToken(token, server: server)
        } catch CoreServiceError.invalidArgument {
            return .failed(.tokenRejected)
        } catch {
            return .failed(.unavailable)
        }
    }

    /// The repositories a server's token reaches; "" is github.com.
    func accountRepositories(server: String = "") async -> CoreGitHubAccount {
        guard isReady, let service = try? await provider.service() else { return .failed(.unavailable) }
        guard let account = try? await service.listGitHubRepositories(server: server) else { return .failed(.unavailable) }
        if account.access == .tokenRejected, server.isEmpty { await onGitHubTokenRejected?() }
        return account
    }

    /// A repository's workflows on GitHub.
    func workflows(of target: GitHubTarget) async -> CoreGitHubResult<CoreGitHubWorkflow> {
        guard let (service, coreTarget) = await serviceAndTarget(target),
              let result = try? await service.listGitHubWorkflows(target: coreTarget) else {
            return CoreGitHubResult(access: .unavailable, items: [])
        }
        if result.access == .tokenRejected { await tokenRejected(on: target) }
        return result
    }

    /// A repository's newest runs on GitHub, read now.
    func runs(of target: GitHubTarget, limit: Int) async -> CoreGitHubResult<CoreWorkflowRun> {
        guard let (service, coreTarget) = await serviceAndTarget(target),
              let result = try? await service.listWorkflowRuns(target: coreTarget, branch: nil, limit: limit) else {
            return CoreGitHubResult(access: .unavailable, items: [])
        }
        if result.access == .tokenRejected { await tokenRejected(on: target) }
        return result
    }

    /// The linked GitHub repository as the Core sees it with the current
    /// token, kept in the session's `githubDetails`.
    @discardableResult
    func githubRepository(workspaceID: UUID) async -> CoreGitHubRepository {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else { return .failed(.unavailable) }
        do {
            let repository = try await service.gitHubRepository(repositoryID: coreID)
            if repository.access == .tokenRejected { await tokenRejected(on: .workspace(workspaceID)) }
            if let session = sessions[workspaceID], session.coreID == coreID { session.githubDetails = repository }
            return repository
        } catch {
            return .failed(.unavailable)
        }
    }

    /// Jobs and steps of one run, read on demand.
    func jobs(workspaceID: UUID, runID: Int64) async -> CoreGitHubResult<CoreRunJob> {
        guard let coreID = sessions[workspaceID]?.coreID, isReady,
              let service = try? await provider.service() else {
            return CoreGitHubResult(access: .unavailable, items: [])
        }
        do {
            let result = try await service.listRunJobs(repositoryID: coreID, runID: runID)
            if result.access == .tokenRejected { await tokenRejected(on: .workspace(workspaceID)) }
            return result
        } catch {
            return CoreGitHubResult(access: .unavailable, items: [])
        }
    }

    /// The jobs of the workflow file one run used, with their needs, for the
    /// run's graph. Without jobs and with a problem when the file cannot be read.
    func runWorkflow(workspaceID: UUID, runID: Int64) async -> CoreRunWorkflow {
        guard let coreID = sessions[workspaceID]?.coreID, isReady,
              let service = try? await provider.service() else { return .failed(.unavailable) }
        do {
            let result = try await service.getRunWorkflow(repositoryID: coreID, runID: runID)
            if result.access == .tokenRejected { await tokenRejected(on: .workspace(workspaceID)) }
            return result
        } catch {
            return .failed(.unavailable)
        }
    }

    /// The pipeline of the workspace's change in a scenario (nil: the
    /// default one); nil when the Core cannot answer.
    func flow(workspaceID: UUID, scenario: CoreScenario?) async -> CoreFlow? {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else { return nil }
        return try? await service.flow(repositoryID: coreID, scenario: scenario)
    }

    // MARK: Storage

    /// Where Settings › Storage keeps its choices (`StorageSettings`).
    @ObservationIgnored var storageDefaults: UserDefaults = .standard

    /// Hands the logs choice to the Core, at its start and when it changes.
    /// A deletion asked for when the choice was turned off stays pending
    /// until a Core confirms it, so a Core that was away still deletes.
    func pushStoragePreferences() async {
        let keep = storageDefaults.bool(forKey: StorageSettings.keepJobLogsKey)
        let deleteKept = !keep && storageDefaults.bool(forKey: StorageSettings.logDeletionPendingKey)
        guard isReady, let service = try? await provider.service() else { return }
        do {
            try await service.setStoragePreferences(keepJobLogs: keep, deleteKeptLogs: deleteKept)
            if deleteKept { storageDefaults.set(false, forKey: StorageSettings.logDeletionPendingKey) }
        } catch {
            // Still pending: the next Core start sends it again.
        }
    }

    /// What workspaces keep on this Mac; nil when the Core cannot say.
    func storageUsage(workspaceIDs: [UUID] = []) async -> CoreStorageUsage? {
        guard isReady, let service = try? await provider.service() else { return nil }
        return try? await service.storageUsage(workspaceIDs: workspaceIDs)
    }

    /// Clears the cache of the workspaces (all when empty); open ones sync again.
    @discardableResult
    func clearCache(workspaceIDs: [UUID]) async -> Bool {
        guard isReady, let service = try? await provider.service() else { return false }
        return (try? await service.clearWorkspaceCache(workspaceIDs: workspaceIDs)) != nil
    }

    /// Forgets the search index of the workspaces (all when empty): the runs
    /// it keeps that the cache has dropped or GitHub deleted.
    @discardableResult
    func clearRunIndex(workspaceIDs: [UUID]) async -> Bool {
        guard isReady, let service = try? await provider.service() else { return false }
        return (try? await service.clearRunIndex(workspaceIDs: workspaceIDs)) != nil
    }

    /// The saved runs and the search index for a query; nil when the Core
    /// cannot answer. Nothing goes to GitHub, so it works offline.
    func searchRuns(workspaceID: UUID, query: String) async -> CoreRunSearch? {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else { return nil }
        return try? await service.searchRuns(repositoryID: coreID, query: query, limit: 200)
    }

    /// The global search over the saved data of workspaces (all when empty);
    /// nil when the Core cannot answer. Nothing goes to GitHub.
    func searchWorkspaces(query: String, workspaceIDs: [UUID] = []) async -> CoreWorkspaceSearch? {
        guard isReady, let service = try? await provider.service() else { return nil }
        return try? await service.searchWorkspaces(query: query, workspaceIDs: workspaceIDs, limitPerKind: 8)
    }

    /// One step of a deep search on GitHub.
    func searchRunsOnGitHub(workspaceID: UUID, query: String, cursor: Date?) async -> CoreGitHubRunSearch {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else { return .failed(.unavailable) }
        do {
            let result = try await service.searchRunsOnGitHub(repositoryID: coreID, query: query, cursor: cursor, pages: 10)
            if result.access == .tokenRejected { await tokenRejected(on: .workspace(workspaceID)) }
            return result
        } catch {
            return .failed(.unavailable)
        }
    }

    /// Deletes a closed workspace's data on this Mac, once the Core has
    /// closed the repository its last window released.
    @discardableResult
    func deleteWorkspaceData(_ workspaceID: UUID) async -> Bool {
        if let close = closing.removeValue(forKey: workspaceID) { await close.value }
        guard isReady, let service = try? await provider.service() else { return false }
        do {
            try await service.deleteWorkspaceData(workspaceID: workspaceID)
            return true
        } catch {
            return false
        }
    }

    // MARK: Validation

    enum ValidationOutcome: Equatable {
        case report(CoreValidationReport)
        case failed(String)
    }

    /// Checks the workspace's workflow files with the Core's actionlint.
    func validateWorkflows(workspaceID: UUID) async -> ValidationOutcome {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else {
            return .failed("Runnir Core is not ready. Validation runs in the Core.")
        }
        do {
            return .report(try await service.validateWorkflows(repositoryID: coreID, workflowID: nil))
        } catch CoreServiceError.remote(_, let message) where !message.isEmpty {
            // The Core explains a failed check itself.
            return .failed("The check failed in Runnir Core: \(message)")
        } catch {
            return .failed(Self.describe(error))
        }
    }

    // MARK: Editing

    enum WorkflowSaveOutcome: Equatable {
        /// Written; the digest of the file now on disk.
        case saved(String)
        /// The file changed on disk since it was loaded; nothing was written.
        case conflict
        case failed(String)
    }

    func saveWorkflowFile(workspaceID: UUID, workflowID: String, content: String, baseSHA256: String,
                          overwrite: Bool) async -> WorkflowSaveOutcome {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else {
            return .failed("Runnir Core is not ready. Files are saved by the Core; your changes are still in the editor.")
        }
        do {
            let result = try await service.saveWorkflowFile(repositoryID: coreID, workflowID: workflowID, content: content,
                                                            baseSHA256: baseSHA256, overwrite: overwrite)
            return result.conflict ? .conflict : .saved(result.sha256)
        } catch CoreServiceError.notFound {
            return .failed("Runnir Core does not know this workflow file yet. Refresh, then save again.")
        } catch CoreServiceError.invalidArgument(let message), CoreServiceError.failedPrecondition(let message) {
            return .failed(Self.sentence(message))
        } catch {
            return .failed(Self.describe(error))
        }
    }

    enum WorkflowFileChange: Equatable {
        /// Done; the file's workflow id now.
        case done(String)
        case failed(String)
    }

    /// Adds a workflow file through the Core; empty `content` writes the
    /// Core's starter. The Core scans the repository again, and its event
    /// updates the session's workflows.
    func createWorkflowFile(workspaceID: UUID, fileName: String, content: String = "") async -> WorkflowFileChange {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else {
            return .failed("Runnir Core is not ready. Files are created by the Core.")
        }
        do {
            return .done(try await service.createWorkflowFile(repositoryID: coreID, fileName: fileName, content: content))
        } catch {
            return .failed(Self.fileChangeMessage(error))
        }
    }

    /// Renames a workflow file through the Core.
    func renameWorkflowFile(workspaceID: UUID, workflowID: String, newFileName: String) async -> WorkflowFileChange {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else {
            return .failed("Runnir Core is not ready. Files are renamed by the Core.")
        }
        do {
            return .done(try await service.renameWorkflowFile(repositoryID: coreID, workflowID: workflowID, newFileName: newFileName))
        } catch {
            return .failed(Self.fileChangeMessage(error))
        }
    }

    private static func fileChangeMessage(_ error: any Error) -> String {
        switch error {
        case CoreServiceError.notFound:
            "Runnir Core does not know this workflow file yet. Refresh, then try again."
        case CoreServiceError.invalidArgument(let message), CoreServiceError.failedPrecondition(let message),
             CoreServiceError.alreadyExists(let message):
            sentence(message)
        default:
            describe(error)
        }
    }

    // MARK: Local runs

    enum EnvFileRead: Equatable {
        case read(CoreEnvFile)
        case failed(String)
    }

    /// The largest .env file read, as the Core parses it.
    nonisolated static let maxEnvFileBytes = 1 << 20

    /// Reads a .env file the user chose (a regular file of at most 1 MiB)
    /// and has the Core parse it, for Secrets and Variables.
    func readEnvFile(url: URL) async -> EnvFileRead {
        let content: Data
        do {
            content = try await Task.detached { try Self.readBounded(url) }.value
        } catch EnvFileError.tooLarge {
            return .failed("The file is larger than 1 MiB.")
        } catch {
            return .failed("Runnir can't read this file.")
        }
        guard isReady, let service = try? await provider.service() else {
            return .failed("Runnir Core is not ready. Try again in a moment.")
        }
        do {
            return .read(try await service.parseEnvFile(content: content))
        } catch CoreServiceError.invalidArgument(let message) {
            return .failed(Self.sentence(message))
        } catch {
            return .failed(Self.describe(error))
        }
    }

    private enum EnvFileError: Error { case tooLarge, notAFile }

    nonisolated private static func readBounded(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw EnvFileError.notAFile }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxEnvFileBytes + 1) ?? Data()
        guard data.count <= maxEnvFileBytes else { throw EnvFileError.tooLarge }
        return data
    }

    /// act, the Docker CLI and the container engine as the Core finds them;
    /// nil when the Core is not ready.
    func toolReadiness(refresh: Bool) async -> CoreToolReadiness? {
        guard isReady, let service = try? await provider.service() else { return nil }
        return try? await service.toolReadiness(refresh: refresh)
    }

    enum LocalRunPreparation: Equatable {
        case prepared(CorePreparedLocalRun)
        case failed(String)
    }

    /// Reviews a local run in the Core. Nothing starts.
    func prepareLocalRun(workspaceID: UUID, workflowID: String, jobID: String?, event: String?,
                         useInstalledAct: Bool) async -> LocalRunPreparation {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else {
            return .failed("Runnir Core is not ready. Local runs are reviewed and started by the Core.")
        }
        do {
            return .prepared(try await service.prepareLocalRun(repositoryID: coreID, workflowID: workflowID, jobID: jobID,
                                                               event: event, useInstalledAct: useInstalledAct))
        } catch CoreServiceError.notFound {
            return .failed("This workflow or job is no longer in the working tree. Refresh and review again.")
        } catch CoreServiceError.invalidArgument(let message), CoreServiceError.failedPrecondition(let message) {
            return .failed(Self.sentence(message))
        } catch {
            return .failed(Self.describe(error))
        }
    }

    enum LocalRunStart {
        case started(LocalRunModel)
        case failed(String)
    }

    /// Starts a reviewed run once with the values for its secrets and
    /// variables, and makes it the workspace's local run.
    func startLocalRun(workspaceID: UUID, prepared: CorePreparedLocalRun,
                       secrets: [String: String] = [:], variables: [String: String] = [:]) async -> LocalRunStart {
        guard let confirmationID = prepared.confirmationID else { return .failed("This run can't start yet.") }
        // Another window of this workspace may have started one meanwhile;
        // replacing it would hide a run that keeps going.
        if let current = sessions[workspaceID]?.localRun, !current.isFinished {
            return .failed("A local run of this workspace is still going. Stop it before starting another.")
        }
        guard let (service, _) = await serviceAndCoreID(workspaceID) else {
            return .failed("Runnir Core is not ready. Nothing was started.")
        }
        do {
            let execution = try await service.confirmLocalRun(confirmationID: confirmationID, secrets: secrets, variables: variables)
            guard let session = sessions[workspaceID] else { return .failed("The workspace was closed.") }
            let model = LocalRunModel(executionID: execution.id, workspaceID: workspaceID, plan: prepared.plan)
            let name = (session.path as NSString).lastPathComponent
            model.onFinish = { [weak self] run in self?.onLocalRunFinished?(run, name) }
            session.localRun?.stopFollowing()
            session.localRun = model
            model.follow(hub: self)
            return .started(model)
        } catch CoreServiceError.failedPrecondition(let message), CoreServiceError.invalidArgument(let message) {
            return .failed(Self.sentence(message))
        } catch CoreServiceError.resourceExhausted {
            return .failed("Runnir Core has too many runs waiting. Try again when one finishes.")
        } catch {
            return .failed(Self.describe(error))
        }
    }

    /// Local runs still going, which quitting would stop. Without a running
    /// Core there is nothing to stop, whatever the last report said.
    var activeLocalRuns: [LocalRunModel] {
        guard isReady else { return [] }
        return sessions.values.compactMap(\.localRun).filter { !$0.isFinished }.sorted { $0.executionID < $1.executionID }
    }

    /// The local run that closing this window would stop: the window is the
    /// last one of its workspace, which closes the repository in the Core,
    /// and the workspace's run is still going.
    func localRunEnding(withWindow windowID: UUID) -> LocalRunModel? {
        guard isReady, let workspaceID = windowWorkspace[windowID], let session = sessions[workspaceID],
              session.windowIDs == [windowID], let run = session.localRun, !run.isFinished else { return nil }
        return run
    }

    /// "ci.yml in mobile-app", for prompts.
    func describe(_ run: LocalRunModel) -> String {
        let file = URL(fileURLWithPath: run.plan.workflowID).lastPathComponent
        guard let path = sessions[run.workspaceID]?.path else { return file }
        return "\(file) in \(URL(fileURLWithPath: path).lastPathComponent)"
    }

    func localRunOutput(executionID: String, after: UInt64) async throws -> CoreLocalRunOutput {
        guard isReady, let service = try? await provider.service() else { throw CoreServiceError.unavailable }
        return try await service.localRunOutput(executionID: executionID, after: after)
    }

    /// Asks the Core to stop a run; false when the request did not reach it.
    func cancelExecution(executionID: String) async -> Bool {
        guard isReady, let service = try? await provider.service() else { return false }
        do {
            try await service.cancelExecution(executionID: executionID)
            return true
        } catch {
            return false
        }
    }

    /// "the workflow file changed" -> "The workflow file changed."
    nonisolated static func sentence(_ message: String) -> String {
        guard let first = message.first else { return message }
        let text = first.uppercased() + message.dropFirst()
        return text.hasSuffix(".") ? text : text + "."
    }

    // MARK: Logs and run actions

    /// The end of one job's log.
    func jobLog(workspaceID: UUID, jobID: Int64) async -> CoreJobLog {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else { return .failed(.unavailable) }
        do {
            let log = try await service.jobLog(repositoryID: coreID, jobID: jobID)
            if log.access == .tokenRejected { await tokenRejected(on: .workspace(workspaceID)) }
            return log
        } catch {
            return .failed(.unavailable)
        }
    }

    /// One job's whole log, written to a file by the Core.
    func saveJobLog(workspaceID: UUID, jobID: Int64) async -> CoreSavedJobLog {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID) else { return .failed(.unavailable) }
        do {
            let saved = try await service.saveJobLog(repositoryID: coreID, jobID: jobID)
            if saved.access == .tokenRejected { await tokenRejected(on: .workspace(workspaceID)) }
            return saved
        } catch {
            return .failed(.unavailable)
        }
    }

    func prepareRunAction(workspaceID: UUID, runID: Int64, action: CoreRunAction) async -> CorePreparedRunAction {
        guard let (service, coreID) = await serviceAndCoreID(workspaceID),
              let prepared = try? await service.prepareRunAction(repositoryID: coreID, runID: runID, action: action) else {
            return CorePreparedRunAction(access: .unavailable, actionID: nil, expiresAt: nil, problems: [], run: nil)
        }
        if prepared.access == .tokenRejected { await tokenRejected(on: .workspace(workspaceID)) }
        return prepared
    }

    /// Sends a prepared run action. nil means the confirmation expired or was
    /// already used, or the Core was not reachable: nothing was sent.
    func confirmRunAction(workspaceID: UUID, actionID: String) async -> CoreRunActionResult? {
        guard let (service, _) = await serviceAndCoreID(workspaceID),
              let result = try? await service.confirmRunAction(actionID: actionID) else { return nil }
        if result.access == .tokenRejected { await tokenRejected(on: .workspace(workspaceID)) }
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
        case .rerun, .rerunFailed, .rerunJob: now.runAttempt > before.runAttempt || now.status != "completed"
        case .approveDeployments: now.status != "waiting"
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
            existing.launchPresets = []
            existing.launchPresetsError = nil
            existing.runs = []
            existing.remoteWorkflows = []
            existing.freshness = CoreActivityFreshness()
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
    /// window shows it and closes with the last one. `afterRelease` runs once
    /// the Core no longer needs this window's folder access: after the close
    /// request finished, or at once when nothing is closed. The app keeps the
    /// security-scoped access until then.
    func detach(windowID: UUID, afterRelease: (@MainActor () -> Void)? = nil) {
        guard let workspaceID = windowWorkspace.removeValue(forKey: windowID) else {
            afterRelease?()
            return
        }
        release(windowID: windowID, from: workspaceID, then: afterRelease)
    }

    private func release(windowID: UUID, from workspaceID: UUID, then afterRelease: (@MainActor () -> Void)? = nil) {
        guard let session = sessions[workspaceID] else { afterRelease?(); return }
        session.windowIDs.remove(windowID)
        guard session.windowIDs.isEmpty else { afterRelease?(); return }
        sessions[workspaceID] = nil
        if let coreID = session.coreID {
            closing[workspaceID] = closeInCore(coreID, path: session.path, then: afterRelease)
        } else {
            afterRelease?()
        }
    }

    private func isShown(_ path: String) -> Bool { sessions.values.contains { $0.path == path } }

    /// Closes a repository in the Core unless a window shows its path again.
    /// Core contexts are shared by path and closing is global, so a close that
    /// raced with a reopen of the same path is followed by a fresh open.
    @discardableResult
    private func closeInCore(_ repositoryID: String, path: String, then afterClose: (@MainActor () -> Void)? = nil) -> Task<Void, Never> {
        Task {
            var finished = afterClose
            defer { finished?() }
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
            // The close is done; a reopen below uses another window's access.
            finished?()
            finished = nil
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
            let repository = try await service.openRepository(path: path, workspaceID: session.workspaceID)
            guard isCurrent() else {
                closeInCore(repository.id, path: path)
                return
            }
            session.coreID = repository.id
            let workflows = try await service.listWorkflows(repositoryID: repository.id)
            guard isCurrent() else { return }
            apply(repository, workflows: workflows, to: session)
            session.phase = .ready
            Task { await loadLaunchPresets(of: session, coreID: repository.id, service: service) }
            // Saved activity first; the Core syncs on its own once the
            // workspace is open and announces each pass.
            Task { await readActivity(of: session) }
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
            await loadLaunchPresets(of: session, coreID: coreID, service: service)
            // The Core's RefreshRepository already asked its sync for a pass.
            Task { await readActivity(of: session) }
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
        session.githubServerID = repository.githubServerID
        session.originHost = repository.originHost
        session.lastRefresh = repository.lastRefresh
        session.workflows = workflows
    }

    // MARK: Events

    /// Listens to Core events for as long as the Core runs. When the stream
    /// ends while the Core is still up (the subscriber fell behind, or the
    /// channel dropped), it subscribes again and reloads every repository,
    /// because events may have been missed. Losing the Core cancels this.
    private func startEvents() {
        eventTask?.cancel()
        let provider = provider
        let firstDelay = eventRetryDelay
        eventTask = Task { [weak self] in
            var resubscribing = false
            var delay = firstDelay
            while !Task.isCancelled {
                var fellBehind = false
                do {
                    let service = try await provider.service()
                    // Subscribe before reloading, so nothing in between is lost.
                    let stream = service.events(repositoryIDs: [])
                    if resubscribing { await self?.resync() }
                    for try await event in stream {
                        guard let self else { return }
                        self.apply(event)
                        delay = firstDelay
                    }
                } catch let error as CoreServiceError where error == .resourceExhausted {
                    fellBehind = true
                } catch is CancellationError {
                    return
                } catch {
                    // The channel dropped or the Core is going away; the
                    // supervisor reports a lost Core and cancels this task.
                }
                guard !Task.isCancelled, self?.isReady == true else { return }
                resubscribing = true
                if !fellBehind {
                    try? await Task.sleep(for: delay)
                    delay = min(delay * 2, .seconds(30))
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
        case .activityChanged:
            guard let session = session(forCoreID: event.repositoryID) else { return }
            Task { await readActivity(of: session) }
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
            await self.loadLaunchPresets(of: session, coreID: coreID, service: service)
        }
    }

    /// Reads the repository's presets. A failed read keeps the last list and
    /// says why; it never fails opening or refreshing the repository. Reads
    /// started from opening, refreshing and events are not ordered, so only
    /// the latest started may land: it saw the newest scan.
    private func loadLaunchPresets(of session: RepositorySession, coreID: String, service: any CoreServicing) async {
        session.launchPresetReads += 1
        let read = session.launchPresetReads
        func isCurrent() -> Bool {
            sessions[session.workspaceID] === session && session.coreID == coreID && session.launchPresetReads == read
        }
        do {
            let presets = try await service.listLaunchPresets(repositoryID: coreID)
            guard isCurrent() else { return }
            session.launchPresets = presets
            session.launchPresetsError = nil
        } catch is CancellationError {
            return // nothing failed
        } catch {
            guard isCurrent() else { return }
            session.launchPresetsError = Self.describe(error)
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
            case .invalidArgument, .failedPrecondition, .alreadyExists: "The Core could not use this folder."
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
