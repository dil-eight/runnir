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
    private var closeError: CoreServiceError?
    private var refreshError: CoreServiceError?
    private var openIDs: Set<String> = []
    private var continuations: [AsyncThrowingStream<CoreEvent, any Error>.Continuation] = []
    private var _serverCredentialCalls: [(token: String?, server: String)] = []
    private var runsResults: [String: CoreGitHubResult<CoreWorkflowRun>] = [:]
    private var _runsCalls: [String] = []
    private var jobsResult = CoreGitHubResult<CoreRunJob>(access: .ok, items: [])
    var runsCalls: [String] { lock.withLock { _runsCalls } }
    func setRuns(_ result: CoreGitHubResult<CoreWorkflowRun>, for path: String) { lock.withLock { runsResults[Self.id(for: path)] = result } }
    func setJobs(_ result: CoreGitHubResult<CoreRunJob>) { lock.withLock { jobsResult = result } }
    /// Runs of a repository named directly, without a local clone.
    func setRuns(_ result: CoreGitHubResult<CoreWorkflowRun>, forRepository name: String) {
        lock.withLock { runsResults["github:" + name] = result }
    }
    /// What a call's target is recorded and looked up as: the Core id, or
    /// "github:owner/name".
    static func key(_ target: CoreGitHubTarget) -> String {
        switch target {
        case .repository(let id): id
        case .named(let ref): "github:" + ref.key
        }
    }
    var pullRequestsResult = CorePullRequests.failed(.signedOut)
    /// Answers by server id; a server without one gets `pullRequestsResult`.
    var pullRequestsByServer: [String: CorePullRequests] = [:]
    private var _pullRequestCalls: [Date] = []
    private var _pullRequestServers: [String] = []
    var pullRequestCalls: [Date] { lock.withLock { _pullRequestCalls } }
    var pullRequestServers: [String] { lock.withLock { _pullRequestServers } }
    func listPullRequests(server: String, closedSince: Date) async throws -> CorePullRequests {
        lock.withLock {
            _pullRequestCalls.append(closedSince)
            _pullRequestServers.append(server)
            return pullRequestsByServer[server] ?? pullRequestsResult
        }
    }
    /// GitHub origins by working tree path, as repository keys.
    var origins: [String: String] = [:]
    private var _originRequests: [[String]] = []
    var originRequests: [[String]] { lock.withLock { _originRequests } }
    func githubOrigins(paths: [String]) async throws -> [String: GitHubRepositoryRef] {
        lock.withLock {
            _originRequests.append(paths)
            return origins.filter { paths.contains($0.key) }.compactMapValues { GitHubRepositoryRef(key: $0) }
        }
    }
    var accountResult = CoreGitHubAccount.failed(.signedOut)
    /// Answers by server id; a server without one gets `accountResult`.
    var accountsByServer: [String: CoreGitHubAccount] = [:]
    private var _accountCalls = 0
    var accountCalls: Int { lock.withLock { _accountCalls } }
    func listGitHubRepositories(server: String) async throws -> CoreGitHubAccount {
        lock.withLock {
            _accountCalls += 1
            return accountsByServer[server] ?? accountResult
        }
    }
    private var _workflowTargets: [String] = []
    var workflowTargets: [String] { lock.withLock { _workflowTargets } }
    func listGitHubWorkflows(target: CoreGitHubTarget) async throws -> CoreGitHubResult<CoreGitHubWorkflow> {
        lock.withLock { _workflowTargets.append(Self.key(target)) }
        return CoreGitHubResult(access: .ok, items: [CoreGitHubWorkflow(id: 1, name: "CI", path: ".github/workflows/ci.yml", state: "active", htmlURL: nil)])
    }
    /// Answers with the result set when the call started, after this delay.
    var runsDelay: Duration?
    func listWorkflowRuns(target: CoreGitHubTarget, branch: String?, limit: Int) async throws -> CoreGitHubResult<CoreWorkflowRun> {
        let key = Self.key(target)
        let (result, delay) = lock.withLock {
            _runsCalls.append(key)
            return (runsResults[key] ?? CoreGitHubResult(access: .ok, items: []), runsDelay)
        }
        if let delay { try? await Task.sleep(for: delay) }
        return result
    }
    func listRunJobs(repositoryID: String, runID: Int64) async throws -> CoreGitHubResult<CoreRunJob> { lock.withLock { jobsResult } }
    var validationResult: Result<CoreValidationReport, CoreServiceError> = .success(CoreValidationReport(
        workflows: [CoreWorkflowValidation(workflowID: ".github/workflows/ci.yml",
                                           diagnostics: [CoreWorkflowDiagnostic(line: 4, column: 3, kind: "job-needs", message: "job \"build\" needs job \"test\" which does not exist")],
                                           problem: nil, truncated: false)],
        validator: "actionlint v1.7.12", configProblem: nil))
    private var _validations = 0
    var validations: Int { lock.withLock { _validations } }
    var validationDelay: Duration?
    func validateWorkflows(repositoryID: String, workflowID: String?) async throws -> CoreValidationReport {
        let (result, delay) = lock.withLock {
            _validations += 1
            return (validationResult, validationDelay)
        }
        if let delay { try? await Task.sleep(for: delay) }
        return try result.get()
    }
    var repositoryResult = CoreGitHubRepository(access: .ok, fullName: "o/r", visibility: "private", defaultBranch: "main",
                                                htmlURL: URL(string: "https://github.com/o/r"))
    func gitHubRepository(target: CoreGitHubTarget) async throws -> CoreGitHubRepository { lock.withLock { repositoryResult } }
    private var _confirmed: [String] = []
    var confirmed: [String] { lock.withLock { _confirmed } }
    var dispatchDefinition = CoreDispatchDefinition(access: .ok, dispatchable: true, inputs: [], parseError: nil)
    var preparedProblems: [String] = []
    /// What GitHub answers a prepared dispatch with, when not `.ok`.
    var preparedAccess: CoreGitHubAccess = .ok
    private var _dispatchTargets: [String] = []
    /// Targets of refs, describe and prepare calls, in order.
    var dispatchTargets: [String] { lock.withLock { _dispatchTargets } }
    func listGitHubRefs(target: CoreGitHubTarget) async throws -> CoreGitHubRefs {
        lock.withLock { _dispatchTargets.append(Self.key(target)) }
        return 
        CoreGitHubRefs(access: .ok, defaultBranch: "main", branches: ["main", "feature"], tags: ["v1.0"])
    }
    func describeWorkflowDispatch(target: CoreGitHubTarget, workflowPath: String, ref: String) async throws -> CoreDispatchDefinition {
        lock.withLock {
            _dispatchTargets.append(Self.key(target))
            return dispatchDefinition
        }
    }
    func prepareWorkflowDispatch(target: CoreGitHubTarget, workflowID: Int64, ref: String, inputs: [String: String]) async throws -> CorePreparedDispatch {
        lock.withLock {
            _dispatchTargets.append(Self.key(target))
            if preparedAccess != .ok {
                return CorePreparedDispatch(access: preparedAccess, dispatchID: nil, expiresAt: nil, problems: [], workflowPath: "")
            }
            return preparedProblems.isEmpty
                ? CorePreparedDispatch(access: .ok, dispatchID: "dispatch_1", expiresAt: Date().addingTimeInterval(120), problems: [], workflowPath: ".github/workflows/ci.yml")
                : CorePreparedDispatch(access: .ok, dispatchID: nil, expiresAt: nil, problems: preparedProblems, workflowPath: ".github/workflows/ci.yml")
        }
    }
    func confirmWorkflowDispatch(dispatchID: String) async throws -> CoreDispatchResult {
        try lock.withLock {
            guard !_confirmed.contains(dispatchID) else { throw CoreServiceError.failedPrecondition("used") }
            _confirmed.append(dispatchID)
            return CoreDispatchResult(access: .ok, dispatchedAt: Date(), runID: nil, rejection: nil)
        }
    }
    // Logs and run actions
    var jobLogResult = CoreJobLog(access: .ok, availability: .available, lines: [], truncated: false)
    var runActionProblems: [String] = []
    var runActionRejection: String?
    var preparedRun: CoreWorkflowRun?
    private var _runActions: [CoreRunAction] = []
    private var _confirmedActions: [String] = []
    var runActions: [CoreRunAction] { lock.withLock { _runActions } }
    var confirmedActions: [String] { lock.withLock { _confirmedActions } }
    func jobLog(repositoryID: String, jobID: Int64) async throws -> CoreJobLog { lock.withLock { jobLogResult } }
    func prepareRunAction(repositoryID: String, runID: Int64, action: CoreRunAction) async throws -> CorePreparedRunAction {
        lock.withLock {
            _runActions.append(action)
            return runActionProblems.isEmpty
                ? CorePreparedRunAction(access: .ok, actionID: "action_\(_runActions.count)", expiresAt: Date().addingTimeInterval(120), problems: [], run: preparedRun)
                : CorePreparedRunAction(access: .ok, actionID: nil, expiresAt: nil, problems: runActionProblems, run: preparedRun)
        }
    }
    func confirmRunAction(actionID: String) async throws -> CoreRunActionResult {
        try lock.withLock {
            guard !_confirmedActions.contains(actionID) else { throw CoreServiceError.failedPrecondition("used") }
            _confirmedActions.append(actionID)
            if let runActionRejection { return CoreRunActionResult(access: .ok, acceptedAt: nil, rejection: runActionRejection) }
            return CoreRunActionResult(access: .ok, acceptedAt: Date(), rejection: nil)
        }
    }
    /// github.com's tokens, in order.
    var credentialCalls: [String?] { lock.withLock { _serverCredentialCalls.filter { $0.server.isEmpty }.map(\.token) } }
    /// Every server's tokens, in order; nil clears.
    var serverCredentialCalls: [(token: String?, server: String)] { lock.withLock { _serverCredentialCalls } }
    func setGitHubCredential(_ token: String?, server: GitHubServerRef) async throws -> CoreGitHubCredentialKind? {
        lock.withLock { _serverCredentialCalls.append((token, server.id)) }
        guard let token else { return nil }
        return token.hasPrefix("ghu_") ? .appUser : token.hasPrefix("github_pat_") ? .fineGrained : .classic
    }
    var tokenCheck = CoreGitHubTokenCheck.failed(.tokenRejected)
    private var _checkedTokens: [String] = []
    private var _tokenCheckServers: [GitHubServerRef] = []
    var checkedTokens: [String] { lock.withLock { _checkedTokens } }
    var tokenCheckServers: [GitHubServerRef] { lock.withLock { _tokenCheckServers } }
    func checkGitHubToken(_ token: String, server: GitHubServerRef) async throws -> CoreGitHubTokenCheck {
        lock.withLock {
            _checkedTokens.append(token)
            _tokenCheckServers.append(server)
            return tokenCheck
        }
    }

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

    func failOpen(for path: String, with error: CoreServiceError? = .invalidArgument("no")) {
        lock.withLock { failingPaths[path] = error }
    }
    func failClose(with error: CoreServiceError?) { lock.withLock { closeError = error } }

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

    private var _openWorkspaceIDs: [UUID] = []
    /// The workspace ids repositories were opened with, in order.
    var openWorkspaceIDs: [UUID] { lock.withLock { _openWorkspaceIDs } }

    func openRepository(path: String, workspaceID: UUID?) async throws -> CoreRepository {
        try lock.withLock {
            _openCalls.append(path)
            if let workspaceID { _openWorkspaceIDs.append(workspaceID) }
            if let error = failingPaths[path] { throw error }
        }
        if let delay = lock.withLock({ openDelays[path] }) { try? await Task.sleep(for: delay) }
        let id = Self.id(for: path)
        lock.withLock { _ = openIDs.insert(id) }
        return CoreRepository(id: id, path: path, branch: lock.withLock { branches[id] } ?? "main", workflowCount: 0, lastRefresh: nil,
                              githubRepository: path == "/repo/linked" ? "o/r" : nil)
    }

    func refreshRepository(id: String) async throws -> CoreRepository {
        lock.withLock { _refreshCalls.append(id) }
        if let delay = lock.withLock({ refreshDelay }) { try? await Task.sleep(for: delay) }
        if let error = lock.withLock({ refreshError }) { throw error }
        return CoreRepository(id: id, path: String(id.dropFirst(3)), branch: lock.withLock { branches[id] } ?? "main", workflowCount: 0, lastRefresh: Date())
    }

    func closeRepository(id: String) async throws {
        try lock.withLock {
            _closeCalls.append(id)
            if let closeError { throw closeError }
            openIDs.remove(id)
        }
    }

    func listWorkflows(repositoryID: String) async throws -> [CoreWorkflow] {
        lock.withLock { _listCalls.append(repositoryID); return workflows[repositoryID] ?? [] }
    }

    func startWorkflow(repositoryID: String, workflowID: String, ref: String?) async throws -> CoreExecution {
        throw CoreServiceError.unavailable
    }

    // MARK: Workspace activity

    private var activities: [String: CoreWorkspaceActivity] = [:]
    private var _activityReads: [String] = []
    private var _activityRefreshes: [(id: String, wait: Bool)] = []
    var activityReads: [String] { lock.withLock { _activityReads } }
    var activityRefreshes: [(id: String, wait: Bool)] { lock.withLock { _activityRefreshes } }
    func setActivity(_ activity: CoreWorkspaceActivity, for path: String) { lock.withLock { activities[Self.id(for: path)] = activity } }
    /// What the Core holds for a repository: the activity set, otherwise
    /// one built from the runs set with `setRuns`, as a live pass.
    private func activity(for id: String) -> CoreWorkspaceActivity {
        if let activity = activities[id] { return activity }
        let runs = runsResults[id] ?? CoreGitHubResult(access: .ok, items: [])
        let workflows = runs.access == .ok ? [CoreGitHubWorkflow(id: 1, name: "CI", path: ".github/workflows/ci.yml", state: "active", htmlURL: nil)] : []
        return CoreWorkspaceActivity(runs: runs.items, workflows: workflows,
                                     freshness: CoreActivityFreshness(source: .live, access: runs.access, checkedAt: Date(), syncedAt: Date()))
    }
    func workspaceActivity(repositoryID: String, limit: Int) async throws -> CoreWorkspaceActivity {
        lock.withLock {
            _activityReads.append(repositoryID)
            return activity(for: repositoryID)
        }
    }
    var refreshDelayActivity: Duration?
    func refreshWorkspaceActivity(repositoryID: String, wait: Bool, limit: Int) async throws -> CoreWorkspaceActivity {
        let delay = lock.withLock { () -> Duration? in
            _activityRefreshes.append((repositoryID, wait))
            _runsCalls.append(repositoryID)
            return refreshDelayActivity ?? runsDelay
        }
        if let delay { try? await Task.sleep(for: delay) }
        return lock.withLock { activity(for: repositoryID) }
    }
    var storage = CoreStorageUsage(workspaces: [], keepJobLogs: false)
    private var _clearedCaches: [[UUID]] = []
    private var _deletedData: [UUID] = []
    private var _storagePreferences: [(keep: Bool, delete: Bool)] = []
    var clearedCaches: [[UUID]] { lock.withLock { _clearedCaches } }
    var deletedData: [UUID] { lock.withLock { _deletedData } }
    var storagePreferences: [(keep: Bool, delete: Bool)] { lock.withLock { _storagePreferences } }
    func storageUsage(workspaceIDs: [UUID]) async throws -> CoreStorageUsage { lock.withLock { storage } }
    func clearWorkspaceCache(workspaceIDs: [UUID]) async throws -> [CoreWorkspaceStorage] {
        lock.withLock { _clearedCaches.append(workspaceIDs); return storage.workspaces }
    }
    func deleteWorkspaceData(workspaceID: UUID) async throws { lock.withLock { _deletedData.append(workspaceID) } }
    func setStoragePreferences(keepJobLogs: Bool, deleteKeptLogs: Bool) async throws {
        lock.withLock { _storagePreferences.append((keepJobLogs, deleteKeptLogs)) }
    }

    // MARK: Saving files

    /// What the file on disk holds, by path; a save succeeds while its base
    /// matches, like the Core.
    var savedFiles: [String: String] = [:]
    var saveError: CoreServiceError?
    var saveDelay: Duration?
    private var _saves: [(workflowID: String, content: String, overwrite: Bool)] = []
    var saves: [(workflowID: String, content: String, overwrite: Bool)] { lock.withLock { _saves } }
    func saveWorkflowFile(repositoryID: String, workflowID: String, content: String, baseSHA256: String,
                          overwrite: Bool) async throws -> CoreWorkflowSave {
        if let saveDelay { try? await Task.sleep(for: saveDelay) }
        return try lock.withLock {
            _saves.append((workflowID, content, overwrite))
            if let saveError { throw saveError }
            let current = savedFiles[workflowID] ?? ""
            if !overwrite, WorkflowDigest.sha256(current) != baseSHA256 {
                return CoreWorkflowSave(sha256: WorkflowDigest.sha256(current), conflict: true)
            }
            savedFiles[workflowID] = content
            return CoreWorkflowSave(sha256: WorkflowDigest.sha256(content), conflict: false)
        }
    }

    /// Where create and rename change files on disk, like the Core; nil
    /// changes nothing on disk.
    var workflowRoot: URL?
    var fileChangeError: CoreServiceError?
    private var _fileChanges: [String] = []
    /// "create <name>" and "rename <id> <name>", in order.
    var fileChanges: [String] { lock.withLock { _fileChanges } }
    func createWorkflowFile(repositoryID: String, fileName: String, content: String) async throws -> String {
        try lock.withLock {
            _fileChanges.append("create \(fileName)")
            if let fileChangeError { throw fileChangeError }
            let id = ".github/workflows/\(fileName)"
            if let workflowRoot {
                let url = workflowRoot.appendingPathComponent(id)
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    throw CoreServiceError.alreadyExists("a file with that name already exists in .github/workflows")
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (content.isEmpty ? "name: starter\n" : content).write(to: url, atomically: true, encoding: .utf8)
            }
            return id
        }
    }

    func renameWorkflowFile(repositoryID: String, workflowID: String, newFileName: String) async throws -> String {
        try lock.withLock {
            _fileChanges.append("rename \(workflowID) \(newFileName)")
            if let fileChangeError { throw fileChangeError }
            let id = ".github/workflows/\(newFileName)"
            if let workflowRoot {
                try FileManager.default.moveItem(at: workflowRoot.appendingPathComponent(workflowID), to: workflowRoot.appendingPathComponent(id))
            }
            savedFiles[id] = savedFiles.removeValue(forKey: workflowID)
            return id
        }
    }

    // MARK: Local runs

    static let readyTools = CoreToolReadiness(
        bundledAct: CoreToolStatus(state: .found, version: "0.2.89", path: "/App/Contents/Helpers/act"),
        installedAct: CoreToolStatus(state: .missing, detail: "No act is installed on this Mac."),
        dockerCLI: CoreToolStatus(state: .found, version: "29.0.1", path: "/usr/local/bin/docker"),
        engine: CoreContainerEngine(state: .found, name: "OrbStack", context: "orbstack", local: true, cpus: 8, memoryBytes: 16 << 30),
        checkedAt: Date(), testedActVersion: "0.2.89", minimumActVersion: "0.2.60")
    var readiness = FakeCore.readyTools
    private var _readinessRefreshes = 0
    var readinessRefreshes: Int { lock.withLock { _readinessRefreshes } }
    /// What PrepareLocalRun answers; nil throws `.unavailable`.
    var preparedLocalRun: CorePreparedLocalRun?
    private var _localRunRequests: [(workflowID: String, jobID: String?, event: String?, installed: Bool)] = []
    var localRunRequests: [(workflowID: String, jobID: String?, event: String?, installed: Bool)] { lock.withLock { _localRunRequests } }
    var confirmLocalRunError: CoreServiceError?
    private var _confirmedLocalRuns: [String] = []
    var confirmedLocalRuns: [String] { lock.withLock { _confirmedLocalRuns } }
    /// Answers to GetLocalRunOutput in order; the last one repeats.
    var localOutputs: [CoreLocalRunOutput] = []
    var localOutputError: CoreServiceError?
    private var _outputRequests: [UInt64] = []
    var outputRequests: [UInt64] { lock.withLock { _outputRequests } }
    private var _cancelledExecutions: [String] = []
    var cancelledExecutions: [String] { lock.withLock { _cancelledExecutions } }

    func toolReadiness(refresh: Bool) async throws -> CoreToolReadiness {
        lock.withLock {
            if refresh { _readinessRefreshes += 1 }
            return readiness
        }
    }
    func prepareLocalRun(repositoryID: String, workflowID: String, jobID: String?, event: String?,
                         useInstalledAct: Bool) async throws -> CorePreparedLocalRun {
        try lock.withLock {
            _localRunRequests.append((workflowID, jobID, event, useInstalledAct))
            guard let preparedLocalRun else { throw CoreServiceError.unavailable }
            return preparedLocalRun
        }
    }
    func confirmLocalRun(confirmationID: String) async throws -> CoreExecution {
        try lock.withLock {
            if let confirmLocalRunError { throw confirmLocalRunError }
            guard !_confirmedLocalRuns.contains(confirmationID) else { throw CoreServiceError.failedPrecondition("used") }
            _confirmedLocalRuns.append(confirmationID)
            return CoreExecution(id: "exec_1", repositoryID: "repo", state: .running)
        }
    }
    func localRunOutput(executionID: String, after: UInt64) async throws -> CoreLocalRunOutput {
        try lock.withLock {
            _outputRequests.append(after)
            if let localOutputError { throw localOutputError }
            guard !localOutputs.isEmpty else { throw CoreServiceError.notFound }
            return localOutputs.count > 1 ? localOutputs.removeFirst() : localOutputs[0]
        }
    }
    func cancelExecution(executionID: String) async throws {
        lock.withLock { _cancelledExecutions.append(executionID) }
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
        // Events pushed before the hub subscribes would be lost.
        _ = await eventually { provider.core.subscriptions >= 1 }
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
        // coreID is set before the workflow list arrives; wait for the open to finish.
        #expect(await eventually {
            hub.session(for: workspace)?.coreID == FakeCore.id(for: "/repo/new") && hub.session(for: workspace)?.phase == .ready
        })
        #expect(await eventually { provider.core.closeCalls == [FakeCore.id(for: "/repo/old")] })
    }

    @Test
    func relinkingWhileTheOldOpenIsInFlightKeepsTheNewPath() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID(), window = UUID()
        provider.core.delayOpen(of: "/repo/old", by: .milliseconds(300))
        hub.attach(windowID: window, workspaceID: workspace, path: "/repo/old")
        #expect(await eventually { provider.core.openCalls.contains("/repo/old") })
        hub.attach(windowID: window, workspaceID: workspace, path: "/repo/new")

        #expect(await eventually {
            hub.session(for: workspace)?.coreID == FakeCore.id(for: "/repo/new") && hub.session(for: workspace)?.phase == .ready
        })
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

        #expect(await eventually {
            hub.session(for: workspace)?.coreID == FakeCore.id(for: "/repo/new") && hub.session(for: workspace)?.phase == .ready
        })
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
    func refreshRetriesARepositoryWhoseOpenFailed() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        provider.core.failOpen(for: "/repo/a", with: .accessDenied)
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/a")
        #expect(await eventually { if case .failed = hub.session(for: workspace)?.phase { true } else { false } })

        provider.core.failOpen(for: "/repo/a", with: nil) // access fixed
        await hub.refresh(workspaceID: workspace)
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })
        #expect(provider.core.openCalls.count == 2)
    }

    @Test
    func aTimedOutOpenIsNotReportedAsAMissingCore() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        provider.core.failOpen(for: "/repo/slow", with: .timedOut)
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/slow")
        #expect(await eventually {
            if case .failed(let message) = hub.session(for: workspace)?.phase { message.contains("too long") } else { false }
        })
        #expect(hub.status == .ready(version: "fake"))
    }

    @Test
    func aCloseThatFailedDoesNotHideALaterRealClose() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID(), first = UUID()
        hub.attach(windowID: first, workspaceID: workspace, path: "/repo/a")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })

        provider.core.failClose(with: .notFound)
        hub.detach(windowID: first)
        #expect(await eventually { provider.core.closeCalls.count == 1 })
        provider.core.failClose(with: nil)
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/a")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })

        // Someone else closes it now: the window must reopen it.
        let opensBefore = provider.core.openCalls.count
        provider.core.push(coreEvent(.repositoryClosed, repository: FakeCore.id(for: "/repo/a")))
        #expect(await eventually { provider.core.openCalls.count == opensBefore + 1 })
    }

    @Test
    func attachingRightAsTheCoreBecomesReadyOpensOnce() async {
        for _ in 0..<20 {
            let (hub, provider) = makeHub()
            let workspace = UUID()
            provider.ready()
            // Attach in the window between the ready state and the hub's open-all.
            await Task.yield()
            hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/a")
            #expect(await eventually { hub.session(for: workspace)?.phase == .ready })
            try? await Task.sleep(for: .milliseconds(20))
            #expect(provider.core.openCalls == ["/repo/a"])
        }
    }

    @Test
    func theGitHubRepositoryFromTheCoreReachesTheSession() async {
        let (hub, _) = await readyHub()
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.githubRepository == "o/r" })
    }

    @Test
    func theCoreGetsTheTokenWhenReadyAgainAfterRecoveryAndLosesItOnSignOut() async {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        var token: String? = "ghu_signed_in"
        hub.githubTokenProvider = { token }
        hub.startMonitoring()
        provider.ready()
        #expect(await eventually { provider.core.credentialCalls == ["ghu_signed_in"] })

        provider.emit(.lost(.processExited(9)))
        #expect(await eventually { hub.status == .lost })
        await hub.recover()
        #expect(await eventually { provider.core.credentialCalls == ["ghu_signed_in", "ghu_signed_in"] })

        token = nil
        hub.githubCredentialChanged()
        #expect(await eventually { provider.core.credentialCalls.last == .some(nil) })
    }

    @Test
    func folderAccessEndsOnlyAfterTheCoreClosedTheRepository() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        let first = UUID(), second = UUID()
        hub.attach(windowID: first, workspaceID: workspace, path: "/repo/a")
        hub.attach(windowID: second, workspaceID: workspace, path: "/repo/a")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })

        // Another window still shows the repository: nothing to wait for.
        var firstReleased = false
        hub.detach(windowID: first) { firstReleased = true }
        #expect(firstReleased)
        #expect(provider.core.closeCalls.isEmpty)

        // The last window: released only once the Core has closed it.
        var closedBeforeRelease: Bool?
        hub.detach(windowID: second) {
            closedBeforeRelease = provider.core.closeCalls == [FakeCore.id(for: "/repo/a")]
        }
        #expect(closedBeforeRelease == nil, "the close is still on its way")
        #expect(await eventually { closedBeforeRelease != nil })
        #expect(closedBeforeRelease == true)

        var unknownReleased = false
        hub.detach(windowID: UUID()) { unknownReleased = true }
        #expect(unknownReleased)
    }

    @Test
    func workflowsAreValidatedThroughTheCore() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        #expect(await hub.validateWorkflows(workspaceID: workspace) == .failed("Runnir Core is not ready. Validation runs in the Core."))
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/a")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })

        let files = WorkspaceFilesModel()
        await files.validate(hub: hub, workspaceID: workspace)
        let ci = LocalWorkflowFile(relativePath: ".github/workflows/ci.yml")
        #expect(files.validation?.validator == "actionlint v1.7.12")
        #expect(files.problemCount(for: ci) == 1)
        #expect(files.problemCount(for: LocalWorkflowFile(relativePath: ".github/workflows/other.yml")) == nil)
        #expect(files.validationError == nil)

        // A failed check keeps the last report and says why.
        provider.core.validationResult = .failure(.accessDenied)
        await files.validate(hub: hub, workspaceID: workspace)
        #expect(files.validation != nil)
        #expect(files.validationError?.contains("cannot read this folder") == true)
        #expect(provider.core.validations == 2)

        // A check asked for during a running one runs again afterwards.
        provider.core.validationResult = .success(CoreValidationReport(workflows: [], validator: "actionlint v1.7.12", configProblem: nil))
        provider.core.validationDelay = .milliseconds(100)
        let first = Task { await files.validate(hub: hub, workspaceID: workspace) }
        #expect(await eventually { files.isValidating })
        await files.validate(hub: hub, workspaceID: workspace)
        await first.value
        #expect(provider.core.validations == 4)
        #expect(files.validationError == nil && files.validation?.workflows.isEmpty == true)
        // A failure the Core explains keeps its words.
        provider.core.validationDelay = nil
        provider.core.validationResult = .failure(.remote(code: 13, message: "the check could not be prepared in the Core's temporary directory"))
        await files.validate(hub: hub, workspaceID: workspace)
        #expect(files.validationError == "The check failed in Runnir Core: the check could not be prepared in the Core's temporary directory")

        // Choosing the same diagnostic again scrolls back to it.
        files.reveal(line: 4)
        let reveals = files.revealCount
        files.reveal(line: 4)
        #expect(files.highlightedLine == 4 && files.revealCount == reveals + 1)
        files.reveal(line: 0)
        #expect(files.highlightedLine == 4 && files.revealCount == reveals + 1, "a diagnostic without a position moves nothing")
    }

    @Test
    func theLinkedRepositoryIsReadThroughTheCore() async {
        let (hub, provider) = await readyHub()
        var rejected = 0
        hub.onGitHubTokenRejected = { rejected += 1 }
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })
        let linked = await hub.githubRepository(workspaceID: workspace)
        #expect(linked.fullName == "o/r" && linked.visibility == "private" && linked.access == .ok)

        provider.core.repositoryResult = .failed(.tokenRejected)
        #expect(await hub.githubRepository(workspaceID: workspace).access == .tokenRejected)
        #expect(rejected == 1, "a rejected token signs the account out")
        #expect(await hub.githubRepository(workspaceID: UUID()).access == .unavailable)
    }

    @Test
    func aLoadAskedForDuringAnotherRunsAfterIt() async {
        let (hub, provider) = await readyHub()
        let path = "/repo/linked"
        // The first load answers "signed out" slowly, as before the token arrives.
        provider.core.setRuns(CoreGitHubResult(access: .signedOut, items: []), for: path)
        provider.core.runsDelay = .milliseconds(200)
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: path)
        // The load is marked before it asks the Core, so wait for the Core
        // to have been asked; otherwise the first load could already read
        // the answer meant for the second.
        #expect(await eventually { hub.session(for: workspace)?.isLoadingGitHub == true && !provider.core.runsCalls.isEmpty })

        // The token arrives meanwhile and a load is asked for again.
        provider.core.runsDelay = nil
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [run(1, status: "completed", conclusion: "success")]), for: path)
        await hub.loadGitHubActivity(workspaceID: workspace)

        #expect(await eventually { hub.session(for: workspace)?.githubAccess == .ok })
        #expect(hub.session(for: workspace)?.runs.count == 1)
        // At least the first load and the one asked for during it; the Core's
        // own credential push may add another.
        #expect(await eventually { provider.core.runsCalls.count >= 2 })
    }

    private func run(_ id: Int64, status: String, conclusion: String?) -> CoreWorkflowRun {
        CoreWorkflowRun(id: id, workflowID: 1, name: "CI", displayTitle: "Change \(id)", runNumber: id, event: "push",
                        status: status, conclusion: conclusion, branch: "main", headSHA: "abc", actor: nil,
                        htmlURL: nil, createdAt: Date(), updatedAt: Date())
    }

    @Test
    func runsAndWorkflowsLoadForALinkedRepository() async {
        let (hub, provider) = await readyHub()
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [run(1, status: "completed", conclusion: "success")]), for: "/repo/linked")
        let linked = UUID(), local = UUID()
        hub.attach(windowID: UUID(), workspaceID: linked, path: "/repo/linked")
        hub.attach(windowID: UUID(), workspaceID: local, path: "/repo/local")
        #expect(await eventually { hub.session(for: linked)?.runs.count == 1 })
        #expect(hub.session(for: linked)?.githubAccess == .ok)
        #expect(hub.session(for: linked)?.remoteWorkflows.count == 1)
        #expect(await eventually { hub.session(for: local)?.githubAccess == .noRemote })
        // A repository without a GitHub remote never asks the Core for runs.
        #expect(provider.core.runsCalls.allSatisfy { $0 == FakeCore.id(for: "/repo/linked") })
    }

    @Test
    func missingAccessClearsRunsAndARejectedTokenSignsOut() async {
        let (hub, provider) = await readyHub()
        var rejected = 0
        hub.onGitHubTokenRejected = { rejected += 1 }
        let workspace = UUID()
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [run(1, status: "completed", conclusion: "failure")]), for: "/repo/linked")
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.runs.count == 1 })

        provider.core.setRuns(CoreGitHubResult(access: .notVisible, items: []), for: "/repo/linked")
        await hub.loadGitHubActivity(workspaceID: workspace)
        #expect(hub.session(for: workspace)?.githubAccess == .notVisible)
        #expect(hub.session(for: workspace)?.runs.isEmpty == true)

        provider.core.setRuns(CoreGitHubResult(access: .tokenRejected, items: []), for: "/repo/linked")
        await hub.loadGitHubActivity(workspaceID: workspace)
        #expect(rejected == 1)
    }

    @Test
    func rateLimitsKeepTheLastRuns() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [run(1, status: "completed", conclusion: "success")]), for: "/repo/linked")
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.runs.count == 1 })
        provider.core.setRuns(CoreGitHubResult(access: .rateLimited(until: nil), items: []), for: "/repo/linked")
        await hub.loadGitHubActivity(workspaceID: workspace)
        #expect(hub.session(for: workspace)?.githubAccess == .rateLimited(until: nil))
        #expect(hub.session(for: workspace)?.runs.count == 1)
    }

    @Test
    func activeRunsAreReadAgainUntilTheyFinish() async {
        let (hub, provider) = await readyHub()
        hub.githubPollInterval = .milliseconds(30)
        let workspace = UUID()
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [run(1, status: "in_progress", conclusion: nil)]), for: "/repo/linked")
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { provider.core.runsCalls.count >= 3 })

        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [run(1, status: "completed", conclusion: "success")]), for: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.runs.first?.outcome == .succeeded })
        let settled = provider.core.runsCalls.count
        try? await Task.sleep(for: .milliseconds(150))
        #expect(provider.core.runsCalls.count == settled)
    }

    @Test
    func signingInReloadsRunsAndJobsPassThrough() async {
        let (hub, provider) = await readyHub()
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        #expect(await eventually { hub.session(for: workspace)?.githubAccess == .ok })
        let before = provider.core.runsCalls.count
        hub.githubTokenProvider = { "ghu_new" }
        hub.githubCredentialChanged()
        #expect(await eventually { provider.core.runsCalls.count > before })

        let job = CoreRunJob(id: 9, name: "build", status: "completed", conclusion: "success", startedAt: nil, completedAt: nil, htmlURL: nil,
                             steps: [CoreRunStep(number: 1, name: "Checkout", status: "completed", conclusion: "success")])
        provider.core.setJobs(CoreGitHubResult(access: .ok, items: [job]))
        let jobs = await hub.jobs(workspaceID: workspace, runID: 1)
        #expect(jobs == CoreGitHubResult(access: .ok, items: [job]))
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
        #expect(await eventually { provider.core.openCalls.count == 2 })
    }

    @Test
    func aDroppedEventStreamIsResubscribedWhileTheCoreRuns() async {
        let (hub, provider) = await readyHub()
        hub.eventRetryDelay = .milliseconds(10)
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/a")
        #expect(await eventually { hub.session(for: workspace)?.phase == .ready })

        // The stream ends without the Core going away.
        provider.core.endEvents(throwing: CoreServiceError.unavailable)
        #expect(await eventually { provider.core.subscriptions == 2 })
        #expect(await eventually { provider.core.openCalls.count == 2 }, "missed events are made up by a reload")
        #expect(hub.status == .ready(version: "fake"))
    }

    @Test
    func runsAreReadAgainWhileNothingIsActive() async {
        let (hub, provider) = await readyHub()
        hub.githubIdlePollInterval = .milliseconds(30)
        let path = "/repo/linked"
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [run(1, status: "completed", conclusion: "success")]), for: path)
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: path)
        #expect(await eventually { hub.session(for: workspace)?.runs.count == 1 })
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [run(2, status: "queued", conclusion: nil),
                                                                    run(1, status: "completed", conclusion: "success")]), for: path)
        #expect(await eventually { hub.session(for: workspace)?.runs.count == 2 }, "a new run appears without a manual reload")
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
