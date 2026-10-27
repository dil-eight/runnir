import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import SwiftProtobuf

/// One live gRPC channel to a Core over a Unix domain socket.
final class GRPCCoreConnection: CoreConnection, @unchecked Sendable {
    private typealias Client = Runnir_Core_V1_RunnirCore.Client<HTTP2ClientTransport.Posix>

    let service: any CoreServicing
    private let grpcClient: GRPCClient<HTTP2ClientTransport.Posix>
    private let runTask: Task<Void, Never>

    init(socketPath: String, clientSecret: String) throws {
        let transport = try HTTP2ClientTransport.Posix(
            target: .unixDomainSocket(path: socketPath),
            transportSecurity: .plaintext
        )
        let grpcClient = GRPCClient(transport: transport, interceptors: [ClientSecretInterceptor(secret: clientSecret)])
        self.grpcClient = grpcClient
        self.runTask = Task { try? await grpcClient.runConnections() }
        self.service = GRPCCoreService(client: Runnir_Core_V1_RunnirCore.Client(wrapping: grpcClient))
    }

    /// Open event streams would keep a graceful shutdown waiting forever, so
    /// give it a moment and then cancel the connection outright.
    func close() async {
        grpcClient.beginGracefulShutdown()
        let task = runTask
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await task.value }
            group.addTask { try? await Task.sleep(for: .seconds(1)); task.cancel() }
            await group.next()
            group.cancelAll()
        }
        task.cancel()
    }
}

struct GRPCCoreConnector: CoreConnecting {
    func connect(socketPath: String, clientSecret: String) async throws -> any CoreConnection {
        try GRPCCoreConnection(socketPath: socketPath, clientSecret: clientSecret)
    }
}

/// Adds the per-launch client secret to every call.
struct ClientSecretInterceptor: ClientInterceptor {
    let secret: String

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (StreamingClientRequest<Input>, ClientContext) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        var request = request
        request.metadata.replaceOrAddString("Bearer \(secret)", forKey: "authorization")
        return try await next(request, context)
    }
}

struct GRPCCoreService: CoreServicing {
    fileprivate let client: Runnir_Core_V1_RunnirCore.Client<HTTP2ClientTransport.Posix>

    /// Every unary call has a deadline so a stuck peer cannot hang the caller.
    /// Health is short because the supervisor polls it; scans may take longer.
    static let healthTimeout: Duration = .seconds(2)
    static let callTimeout: Duration = .seconds(30)

    private static func options(_ timeout: Duration) -> CallOptions {
        var options = CallOptions.defaults
        options.timeout = timeout
        return options
    }

    func healthCheck() async throws -> CoreHealth {
        let response = try await call { try await client.healthCheck(.init(), options: Self.options(Self.healthTimeout)) }
        return CoreHealth(
            coreVersion: response.coreVersion,
            protocolVersion: Int(response.protocolVersion),
            openRepositoryCount: Int(response.openRepositoryCount),
            residentMemoryBytes: response.residentMemoryBytes,
            processID: Int32(truncatingIfNeeded: response.processID)
        )
    }

    func openRepository(path: String, workspaceID: UUID?) async throws -> CoreRepository {
        let response = try await call {
            try await client.openRepository(.with {
                $0.path = path
                $0.workspaceID = workspaceID?.uuidString.lowercased() ?? ""
            }, options: Self.options(Self.callTimeout))
        }
        return Self.map(response.repository)
    }

    func workspaceActivity(repositoryID: String, limit: Int) async throws -> CoreWorkspaceActivity {
        let response = try await call {
            try await client.getWorkspaceActivity(.with {
                $0.repositoryID = repositoryID
                $0.limit = UInt32(clamping: limit)
            }, options: Self.options(Self.callTimeout))
        }
        return Self.map(response)
    }

    func refreshWorkspaceActivity(repositoryID: String, wait: Bool, limit: Int) async throws -> CoreWorkspaceActivity {
        // A pass reads two GitHub lists with a 20-second timeout each.
        let response = try await call {
            try await client.refreshWorkspaceActivity(.with {
                $0.repositoryID = repositoryID
                $0.wait = wait
                $0.limit = UInt32(clamping: limit)
            }, options: Self.options(.seconds(90)))
        }
        return Self.map(response)
    }

    func loadOlderRuns(repositoryID: String) async throws -> CoreOlderRuns {
        let response = try await call {
            try await client.loadOlderRuns(.with { $0.repositoryID = repositoryID }, options: Self.options(.seconds(60)))
        }
        return CoreOlderRuns(access: Self.map(response.status), added: Int(response.added),
                             historyComplete: response.historyComplete, budgetReached: response.budgetReached)
    }

    func searchRuns(repositoryID: String, query: String, limit: Int) async throws -> CoreRunSearch {
        let response = try await call {
            try await client.searchRuns(.with {
                $0.repositoryID = repositoryID
                $0.query = query
                $0.limit = UInt32(clamping: max(0, limit))
            }, options: Self.options(Self.callTimeout))
        }
        return CoreRunSearch(cachedRunIDs: response.cachedRunIds, indexedRuns: response.indexedRuns.map(Self.map),
                             cachedSearched: Int(response.cachedSearched), indexedSearched: Int(response.indexedSearched),
                             problems: response.problems)
    }

    func searchWorkspaces(query: String, workspaceIDs: [UUID], limitPerKind: Int) async throws -> CoreWorkspaceSearch {
        let response = try await call {
            try await client.searchWorkspaces(.with {
                $0.query = query
                $0.workspaceIds = workspaceIDs.map { $0.uuidString.lowercased() }
                $0.limitPerKind = UInt32(clamping: max(0, limitPerKind))
            }, options: Self.options(Self.callTimeout))
        }
        return CoreWorkspaceSearch(workspaces: response.workspaces.compactMap(Self.map), problems: response.problems, words: response.words)
    }

    static func map(_ hits: Runnir_Core_V1_WorkspaceSearchHits) -> CoreWorkspaceHits? {
        guard let id = UUID(uuidString: hits.workspaceID) else { return nil }
        return CoreWorkspaceHits(
            workspaceID: id, isOpen: hits.open, repository: hits.repository,
            savedAt: hits.hasSavedAt ? hits.savedAt.date : nil, problem: hits.problem.isEmpty ? nil : hits.problem,
            runs: hits.runs.map(Self.map), runsMatched: Int(hits.runsMatched),
            pullRequests: hits.pullRequests.map {
                CoreSearchedPullRequest(number: $0.number, title: $0.title, state: $0.state, isDraft: $0.draft, author: $0.author,
                                        headRef: $0.headRef, htmlURL: webURL($0.htmlURL), updatedAt: $0.hasUpdatedAt ? $0.updatedAt.date : nil)
            },
            pullRequestsMatched: Int(hits.pullRequestsMatched),
            workflows: hits.workflows.map(Self.map), workflowsMatched: Int(hits.workflowsMatched),
            localRuns: hits.localRuns.map {
                CoreSearchedLocalRun(executionID: $0.executionID, workflowPath: $0.workflowPath, jobID: $0.jobID, state: $0.state,
                                     message: $0.message, startedAt: $0.hasStartedAt ? $0.startedAt.date : nil)
            },
            localRunsMatched: Int(hits.localRunsMatched))
    }

    /// A step reads up to 10 pages from GitHub, one after another.
    func searchRunsOnGitHub(repositoryID: String, query: String, cursor: Date?, pages: Int) async throws -> CoreGitHubRunSearch {
        let response = try await call {
            try await client.searchRunsOnGitHub(.with {
                $0.repositoryID = repositoryID
                $0.query = query
                if let cursor { $0.cursor = .init(date: cursor) }
                $0.pages = UInt32(clamping: max(0, pages))
            }, options: Self.options(.seconds(330)))
        }
        let stop: CoreSearchStop = switch response.stop {
        case .done: .done
        case .budget: .budget
        case .rateLimited: .rateLimited
        case .busy: .busy
        default: .unavailable
        }
        return CoreGitHubRunSearch(
            access: Self.map(response.status),
            runs: response.runs.map(Self.map), nextCursor: response.hasNextCursor ? response.nextCursor.date : nil,
            lookedBackTo: response.hasLookedBackTo ? response.lookedBackTo.date : nil, pages: Int(response.pages),
            runsRead: Int(response.runsRead), stop: stop, problems: response.problems)
    }

    func clearRunIndex(workspaceIDs: [UUID]) async throws -> [CoreWorkspaceStorage] {
        let response = try await call {
            try await client.clearRunIndex(.with { $0.workspaceIds = workspaceIDs.map { $0.uuidString.lowercased() } },
                                           options: Self.options(Self.callTimeout))
        }
        return response.workspaces.compactMap(Self.map)
    }

    func insertWorkflowConcurrency(repositoryID: String, content: String) async throws -> CoreConcurrencyInsertion {
        let response = try await call {
            try await client.insertWorkflowConcurrency(.with {
                $0.repositoryID = repositoryID
                $0.content = content
            }, options: Self.options(Self.callTimeout))
        }
        return Self.map(response)
    }

    static func map(_ response: Runnir_Core_V1_InsertWorkflowConcurrencyResponse) -> CoreConcurrencyInsertion {
        switch response.refusal {
        case .alreadyPresent: .refused(.alreadyPresent)
        case .noJobs: .refused(.noJobs)
        case .notBlockMapping: .refused(.notBlockMapping)
        case .parseError: .refused(.parseError)
        case .tooLarge: .refused(.tooLarge)
        default: .inserted(content: response.content, firstLine: Int(response.firstLine), lastLine: Int(response.lastLine))
        }
    }

    func storageUsage(workspaceIDs: [UUID]) async throws -> CoreStorageUsage {
        let response = try await call {
            try await client.getStorageUsage(.with { $0.workspaceIds = workspaceIDs.map { $0.uuidString.lowercased() } },
                                             options: Self.options(Self.callTimeout))
        }
        return CoreStorageUsage(workspaces: response.workspaces.compactMap(Self.map), keepJobLogs: response.keepJobLogs)
    }

    func clearWorkspaceCache(workspaceIDs: [UUID]) async throws -> [CoreWorkspaceStorage] {
        let response = try await call {
            try await client.clearWorkspaceCache(.with { $0.workspaceIds = workspaceIDs.map { $0.uuidString.lowercased() } },
                                                 options: Self.options(Self.callTimeout))
        }
        return response.workspaces.compactMap(Self.map)
    }

    func deleteWorkspaceData(workspaceID: UUID) async throws {
        _ = try await call {
            try await client.deleteWorkspaceData(.with { $0.workspaceID = workspaceID.uuidString.lowercased() },
                                                 options: Self.options(Self.callTimeout))
        }
    }

    func setStoragePreferences(keepJobLogs: Bool, deleteKeptLogs: Bool) async throws {
        _ = try await call {
            try await client.setStoragePreferences(.with {
                $0.keepJobLogs = keepJobLogs
                $0.deleteKeptLogs = deleteKeptLogs
            }, options: Self.options(Self.callTimeout))
        }
    }

    static func map(_ workflow: Runnir_Core_V1_GitHubWorkflow) -> CoreGitHubWorkflow {
        CoreGitHubWorkflow(id: workflow.id, name: workflow.name, path: workflow.path, state: workflow.state, htmlURL: webURL(workflow.htmlURL))
    }

    static func map(_ activity: Runnir_Core_V1_WorkspaceActivity) -> CoreWorkspaceActivity {
        let f = activity.freshness
        let source: CoreActivitySource = switch f.source {
        case .cache: .cache
        case .live: .live
        default: .none
        }
        let pullRequestsAccess: CoreGitHubAccess? = f.pullRequestsAccess == .unspecified
            ? nil : map(Runnir_Core_V1_GitHubStatus.with { $0.access = f.pullRequestsAccess })
        return CoreWorkspaceActivity(
            runs: activity.runs.map(map), workflows: activity.workflows.map(map),
            freshness: CoreActivityFreshness(
                source: source, syncing: f.syncing, access: f.hasStatus ? map(f.status) : nil,
                checkedAt: f.hasCheckedAt ? f.checkedAt.date : nil, syncedAt: f.hasSyncedAt ? f.syncedAt.date : nil,
                changedAt: f.hasChangedAt ? f.changedAt.date : nil, pullRequestsAccess: pullRequestsAccess),
            changes: activity.changes.map(map), concurrencyHints: activity.concurrencyHints.map(map),
            cachedRuns: Int(activity.cachedRuns), historyComplete: activity.historyComplete,
            savings: activity.savings.compactMap(map))
    }

    /// Nil for a kind this app does not know.
    static func map(_ saving: Runnir_Core_V1_Saving) -> CoreSaving? {
        let kind: CoreSavingKind
        switch saving.kind {
        case .localRuns: kind = .localRuns
        default: return nil
        }
        return CoreSaving(kind: kind, minutes: Int(clamping: saving.minutes), count: Int(saving.count),
                          since: saving.hasSince ? saving.since.date : nil)
    }

    static func map(_ change: Runnir_Core_V1_RunChange) -> CoreRunChange {
        CoreRunChange(id: change.id, pullRequest: change.hasPullRequest ? map(change.pullRequest) : nil, status: map(change.status),
                      latestAt: change.hasLatestAt ? change.latestAt.date : nil, sections: change.sections.map(map),
                      olderRunIDs: change.olderRunIds, olderCommits: Int(change.olderCommits))
    }

    static func map(_ pullRequest: Runnir_Core_V1_ChangePullRequest) -> CoreChangePullRequest {
        CoreChangePullRequest(number: pullRequest.number, title: pullRequest.title, state: pullRequest.state, draft: pullRequest.draft,
                              author: pullRequest.author, htmlURL: webURL(pullRequest.htmlURL), headBranch: pullRequest.headBranch,
                              baseBranch: pullRequest.baseBranch, mergedAt: pullRequest.hasMergedAt ? pullRequest.mergedAt.date : nil)
    }

    static func map(_ section: Runnir_Core_V1_RunChangeSection) -> CoreRunChangeSection {
        let kind: CoreRunChangeSectionKind = switch section.kind {
        case .afterMerge: .afterMerge
        case .latestCommit: .latestCommit
        default: .commit
        }
        return CoreRunChangeSection(kind: kind, headSHA: section.headSha, branch: section.branch, commitTitle: section.commitTitle,
                                    runIDs: section.runIds, repeatRunIDs: section.repeatRunIds)
    }

    static func map(_ hint: Runnir_Core_V1_ConcurrencyHint) -> CoreConcurrencyHint {
        CoreConcurrencyHint(workflowID: hint.workflowID, path: hint.path, runs: Int(hint.runs), overlapMinutes: Int(hint.overlapMinutes),
                            runIDs: hint.runIds, pullRequests: hint.pullRequests)
    }

    static func map(_ link: Runnir_Core_V1_RunLink) -> CoreRunLink {
        switch link.kind {
        case .pullRequest: .pullRequest(link.pullRequest)
        case .afterMerge: .afterMerge(link.pullRequest)
        default: .none
        }
    }

    static func map(_ ci: Runnir_Core_V1_PullRequestCi) -> CorePullRequestCI {
        switch ci {
        case .none: .none
        case .running: .running
        case .passed: .passed
        case .failed: .failed
        case .cancelled: .cancelled
        default: .unknown
        }
    }

    static func map(_ storage: Runnir_Core_V1_WorkspaceStorage) -> CoreWorkspaceStorage? {
        guard let id = UUID(uuidString: storage.workspaceID) else { return nil }
        let state: CoreStorageState = switch storage.state {
        case .persistent: .persistent
        case .memoryOnly: .memoryOnly
        default: .absent
        }
        return CoreWorkspaceStorage(workspaceID: id, state: state, note: storage.note.isEmpty ? nil : storage.note, isOpen: storage.open,
                                    databaseBytes: storage.databaseBytes, logBytes: storage.logBytes, cachedRuns: Int(storage.cachedRuns),
                                    localRuns: Int(storage.localRuns), recoveryCopies: Int(storage.recoveryCopies),
                                    indexedRuns: Int(storage.indexedRuns))
    }

    func refreshRepository(id: String) async throws -> CoreRepository {
        let response = try await call { try await client.refreshRepository(.with { $0.repositoryID = id }, options: Self.options(Self.callTimeout)) }
        return Self.map(response.repository)
    }

    func closeRepository(id: String) async throws {
        _ = try await call { try await client.closeRepository(.with { $0.repositoryID = id }, options: Self.options(Self.callTimeout)) }
    }

    func listWorkflows(repositoryID: String) async throws -> [CoreWorkflow] {
        let response = try await call { try await client.listWorkflows(.with { $0.repositoryID = repositoryID }, options: Self.options(Self.callTimeout)) }
        return response.workflows.map { workflow in
            CoreWorkflow(
                id: workflow.id,
                name: workflow.name,
                triggers: workflow.triggers,
                jobs: workflow.jobs.map { CoreJob(id: $0.id, name: $0.name, needs: $0.needs, manual: $0.manual, manualInputs: $0.manualInputs) },
                parseError: workflow.parseError.isEmpty ? nil : workflow.parseError,
                dispatchInputs: workflow.dispatchInputs.map(Self.dispatchInput),
                concurrency: workflow.concurrency,
                secrets: workflow.secrets,
                variables: workflow.variables
            )
        }
    }

    private static func dispatchInput(_ input: Runnir_Core_V1_DispatchInput) -> CoreDispatchInput {
        let kind: CoreDispatchInputKind = switch input.type {
        case .boolean: .boolean
        case .choice: .choice
        case .number: .number
        case .environment: .environment
        default: .string
        }
        return CoreDispatchInput(name: input.name, description: input.description_p, kind: kind,
                                 required: input.required, defaultValue: input.defaultValue, options: input.options)
    }

    func listLaunchPresets(repositoryID: String) async throws -> [CoreLaunchPreset] {
        let response = try await call { try await client.listLaunchPresets(.with { $0.repositoryID = repositoryID }, options: Self.options(Self.callTimeout)) }
        return response.presets.map { preset in
            CoreLaunchPreset(path: preset.path, name: preset.name, workflowPath: preset.workflowPath,
                             ref: preset.ref.isEmpty ? nil : preset.ref, inputs: preset.inputs,
                             problem: preset.problem.isEmpty ? nil : preset.problem)
        }
    }

    func validateWorkflows(repositoryID: String, workflowID: String?) async throws -> CoreValidationReport {
        let response = try await call {
            try await client.validateWorkflows(.with {
                $0.repositoryID = repositoryID
                $0.workflowID = workflowID ?? ""
            }, options: Self.options(Self.callTimeout))
        }
        return CoreValidationReport(
            workflows: response.workflows.map { workflow in
                CoreWorkflowValidation(
                    workflowID: workflow.workflowID,
                    diagnostics: workflow.diagnostics.map {
                        CoreWorkflowDiagnostic(line: Int($0.line), column: Int($0.column), kind: $0.kind, message: $0.message)
                    },
                    problem: workflow.problem.isEmpty ? nil : workflow.problem,
                    truncated: workflow.truncated
                )
            },
            validator: response.validator,
            configProblem: response.configProblem.isEmpty ? nil : response.configProblem
        )
    }

    func startWorkflow(repositoryID: String, workflowID: String, ref: String?) async throws -> CoreExecution {
        let response = try await call {
            try await client.startWorkflow(.with {
                $0.repositoryID = repositoryID
                $0.workflowID = workflowID
                $0.ref = ref ?? ""
            }, options: Self.options(Self.callTimeout))
        }
        return CoreExecution(id: response.executionID, repositoryID: response.repositoryID, state: Self.map(response.state))
    }

    func saveWorkflowFile(repositoryID: String, workflowID: String, content: String, baseSHA256: String,
                          overwrite: Bool) async throws -> CoreWorkflowSave {
        var options = Self.options(Self.callTimeout)
        options.maxRequestMessageBytes = 4 << 20
        let response = try await call {
            try await client.saveWorkflowFile(.with {
                $0.repositoryID = repositoryID
                $0.workflowID = workflowID
                $0.content = content
                $0.baseSha256 = baseSHA256
                $0.overwrite = overwrite
            }, options: options)
        }
        return CoreWorkflowSave(sha256: response.sha256, conflict: response.conflict)
    }

    func createWorkflowFile(repositoryID: String, fileName: String, content: String) async throws -> String {
        var options = Self.options(Self.callTimeout)
        options.maxRequestMessageBytes = 4 << 20
        let response = try await call {
            try await client.createWorkflowFile(.with {
                $0.repositoryID = repositoryID
                $0.fileName = fileName
                $0.content = content
            }, options: options)
        }
        return response.workflowID
    }

    func renameWorkflowFile(repositoryID: String, workflowID: String, newFileName: String) async throws -> String {
        let response = try await call {
            try await client.renameWorkflowFile(.with {
                $0.repositoryID = repositoryID
                $0.workflowID = workflowID
                $0.newFileName = newFileName
            }, options: Self.options(Self.callTimeout))
        }
        return response.workflowID
    }

    /// A link from GitHub, kept only when it is a web page: the app opens
    /// these, and a server must not make it open a file or another app.
    static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    static func message(_ server: GitHubServerRef) -> Runnir_Core_V1_GithubServer {
        .with {
            $0.id = server.id
            $0.apiURL = server.apiURL?.absoluteString ?? ""
            $0.webHost = server.webHost
        }
    }

    @discardableResult
    func setGitHubCredential(_ token: String?, server: GitHubServerRef) async throws -> CoreGitHubCredentialKind? {
        if let token {
            let response = try await call {
                try await client.setGitHubCredential(.with {
                    $0.token = token
                    if !server.isDotCom { $0.server = Self.message(server) }
                }, options: Self.options(Self.callTimeout))
            }
            return Self.map(response.kind)
        } else {
            _ = try await call {
                try await client.clearGitHubCredential(.with { $0.serverID = server.id }, options: Self.options(Self.callTimeout))
            }
            return nil
        }
    }

    func checkGitHubToken(_ token: String, server: GitHubServerRef) async throws -> CoreGitHubTokenCheck {
        let response = try await call {
            try await client.checkGitHubToken(.with {
                $0.token = token
                if !server.isDotCom { $0.server = Self.message(server) }
            }, options: Self.options(.seconds(30)))
        }
        return CoreGitHubTokenCheck(
            access: Self.map(response.status), kind: Self.map(response.kind), login: response.login, scopes: response.scopes,
            expiresAt: response.hasExpiresAt ? response.expiresAt.date : nil, repositories: Int(response.repositories),
            checks: response.checks.map { check in
                let state: CoreGitHubTokenCheck.State = switch check.state {
                case .passed: .passed
                case .missing: .missing
                default: .unknown
                }
                return CoreGitHubTokenCheck.Item(name: check.name, state: state, detail: check.detail)
            },
            suitable: response.suitable)
    }

    static func map(_ kind: Runnir_Core_V1_GithubCredentialKind) -> CoreGitHubCredentialKind {
        switch kind {
        case .appUser: .appUser
        case .classic: .classic
        case .fineGrained: .fineGrained
        case .oauth: .oauth
        default: .other
        }
    }

    func listPullRequests(server: String, closedSince: Date) async throws -> CorePullRequests {
        var options = Self.options(.seconds(60))
        options.maxResponseMessageBytes = 4 << 20
        let response = try await call {
            try await client.listPullRequests(.with {
                $0.closedSince = .init(date: closedSince)
                $0.githubServer = server
            }, options: options)
        }
        func map(_ pr: Runnir_Core_V1_PullRequest) -> CorePullRequest {
            let ci = Self.map(pr.ci)
            return CorePullRequest(repository: pr.repository, number: pr.number, title: pr.title, htmlURL: Self.webURL(pr.htmlURL),
                                   state: pr.state, draft: pr.draft, headBranch: pr.headBranch,
                                   updatedAt: pr.hasUpdatedAt ? pr.updatedAt.date : nil, closedAt: pr.hasClosedAt ? pr.closedAt.date : nil,
                                   ci: ci, ciRuns: Int(pr.ciRuns), ciFailed: Int(pr.ciFailed), ciRunning: Int(pr.ciRunning),
                                   ciURL: Self.webURL(pr.ciURL))
        }
        return CorePullRequests(access: Self.map(response.status), open: response.open.map(map), closed: response.closed.map(map),
                                headsUnreadable: response.headsUnreadable,
                                pendingInstallations: response.pendingInstallations.map(Self.map))
    }

    func githubOrigins(paths: [String]) async throws -> [String: GitHubRepositoryRef] {
        let response = try await call {
            try await client.getGitHubOrigins(.with { $0.paths = paths }, options: Self.options(Self.callTimeout))
        }
        return Dictionary(response.origins.map { ($0.path, GitHubRepositoryRef(serverID: $0.githubServerID, fullName: $0.githubRepository)) },
                          uniquingKeysWith: { first, _ in first })
    }

    func listGitHubRepositories(server: String) async throws -> CoreGitHubAccount {
        // Up to 1,000 repositories over several GitHub pages.
        var options = Self.options(.seconds(60))
        options.maxResponseMessageBytes = 8 << 20
        let response = try await call { try await client.listGitHubRepositories(.with { $0.githubServer = server }, options: options) }
        return CoreGitHubAccount(
            access: Self.map(response.status),
            installations: response.installations.map(Self.map),
            repositories: response.repositories.map {
                CoreGitHubAccountRepository(fullName: $0.fullName, owner: $0.owner, name: $0.name, description: $0.description_p,
                                            visibility: $0.visibility, defaultBranch: $0.defaultBranch, htmlURL: Self.webURL($0.htmlURL),
                                            pushedAt: $0.hasPushedAt ? $0.pushedAt.date : nil, archived: $0.archived, fork: $0.fork,
                                            canPush: $0.canPush, installationID: $0.installationID)
            },
            truncated: response.truncated,
            credentialKind: Self.map(response.credentialKind))
    }

    func listGitHubWorkflows(target: CoreGitHubTarget) async throws -> CoreGitHubResult<CoreGitHubWorkflow> {
        let response = try await call {
            try await client.listGitHubWorkflows(.with {
                switch target {
                case .repository(let id): $0.repositoryID = id
                case .named(let ref):
                    $0.githubRepository = ref.fullName
                    $0.githubServer = ref.serverID
                }
            }, options: Self.options(Self.callTimeout))
        }
        return CoreGitHubResult(access: Self.map(response.status), items: response.workflows.map(Self.map))
    }

    func gitHubRepository(target: CoreGitHubTarget) async throws -> CoreGitHubRepository {
        let response = try await call {
            try await client.getGitHubRepository(.with {
                switch target {
                case .repository(let id): $0.repositoryID = id
                case .named(let ref):
                    $0.githubRepository = ref.fullName
                    $0.githubServer = ref.serverID
                }
            }, options: Self.options(Self.callTimeout))
        }
        return CoreGitHubRepository(access: Self.map(response.status), fullName: response.fullName, visibility: response.visibility,
                                    defaultBranch: response.defaultBranch, htmlURL: Self.webURL(response.htmlURL),
                                    canPush: response.canPush, installation: response.hasInstallation ? Self.map(response.installation) : nil)
    }

    static func map(_ installation: Runnir_Core_V1_GitHubInstallation) -> CoreGitHubInstallation {
        CoreGitHubInstallation(id: installation.id, account: installation.account, accountType: installation.accountType,
                               repositorySelection: installation.repositorySelection, htmlURL: Self.webURL(installation.htmlURL),
                               missingPermissions: installation.missingPermissions, suspended: installation.suspended)
    }

    func listWorkflowRuns(target: CoreGitHubTarget, branch: String?, limit: Int) async throws -> CoreGitHubResult<CoreWorkflowRun> {
        let response = try await call {
            try await client.listWorkflowRuns(.with {
                switch target {
                case .repository(let id): $0.repositoryID = id
                case .named(let ref):
                    $0.githubRepository = ref.fullName
                    $0.githubServer = ref.serverID
                }
                $0.branch = branch ?? ""
                $0.limit = UInt32(clamping: max(0, min(limit, 100)))
            }, options: Self.options(Self.callTimeout))
        }
        return CoreGitHubResult(access: Self.map(response.status), items: response.runs.map(Self.map))
    }

    static func map(_ run: Runnir_Core_V1_WorkflowRun) -> CoreWorkflowRun {
        CoreWorkflowRun(
            id: run.id, workflowID: run.workflowID, name: run.name, displayTitle: run.displayTitle,
            runNumber: run.runNumber, event: run.event, status: run.status,
            conclusion: run.conclusion.isEmpty ? nil : run.conclusion, branch: run.branch, headSHA: run.headSha,
            actor: run.actor.isEmpty ? nil : run.actor, htmlURL: Self.webURL(run.htmlURL),
            createdAt: run.hasCreatedAt ? run.createdAt.date : nil,
            updatedAt: run.hasUpdatedAt ? run.updatedAt.date : nil,
            runAttempt: max(1, run.runAttempt),
            headRepository: run.headRepository, commitTitle: run.commitTitle,
            link: run.hasLink ? Self.map(run.link) : .none,
            supersededBy: run.supersededBy == 0 ? nil : run.supersededBy,
            statusGroup: Self.map(run.statusGroup)
        )
    }

    static func map(_ group: Runnir_Core_V1_RunStatusGroup) -> CoreRunStatusGroup? {
        switch group {
        case .success: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        case .running: .running
        case .queued: .queued
        case .skipped: .skipped
        case .unspecified, .UNRECOGNIZED: nil
        }
    }

    func listRunJobs(repositoryID: String, runID: Int64) async throws -> CoreGitHubResult<CoreRunJob> {
        let response = try await call {
            try await client.listRunJobs(.with {
                $0.repositoryID = repositoryID
                $0.runID = runID
            }, options: Self.options(Self.callTimeout))
        }
        return CoreGitHubResult(access: Self.map(response.status), items: response.jobs.map { Self.map($0) })
    }

    func getRunWorkflow(repositoryID: String, runID: Int64) async throws -> CoreRunWorkflow {
        let response = try await call {
            try await client.getRunWorkflow(.with {
                $0.repositoryID = repositoryID
                $0.runID = runID
            }, options: Self.options(Self.callTimeout))
        }
        return CoreRunWorkflow(
            access: Self.map(response.status), path: response.workflowPath,
            jobs: response.jobs.map { CoreJob(id: $0.id, name: $0.name, needs: $0.needs, manual: $0.manual, manualInputs: $0.manualInputs) },
            problem: response.problem)
    }

    static func map(_ job: Runnir_Core_V1_RunJob) -> CoreRunJob {
        CoreRunJob(
            id: job.id, name: job.name, status: job.status, conclusion: job.conclusion.isEmpty ? nil : job.conclusion,
            startedAt: job.hasStartedAt ? job.startedAt.date : nil,
            completedAt: job.hasCompletedAt ? job.completedAt.date : nil,
            htmlURL: Self.webURL(job.htmlURL),
            steps: job.steps.map { step in
                CoreRunStep(number: step.number, name: step.name, status: step.status,
                            conclusion: step.conclusion.isEmpty ? nil : step.conclusion,
                            startedAt: step.hasStartedAt ? step.startedAt.date : nil,
                            completedAt: step.hasCompletedAt ? step.completedAt.date : nil)
            }
        )
    }

    func listGitHubRefs(target: CoreGitHubTarget) async throws -> CoreGitHubRefs {
        let response = try await call {
            try await client.listGitHubRefs(.with {
                switch target {
                case .repository(let id): $0.repositoryID = id
                case .named(let ref):
                    $0.githubRepository = ref.fullName
                    $0.githubServer = ref.serverID
                }
            }, options: Self.options(Self.callTimeout))
        }
        return CoreGitHubRefs(access: Self.map(response.status), defaultBranch: response.defaultBranch,
                              branches: response.branches, tags: response.tags)
    }

    func describeWorkflowDispatch(target: CoreGitHubTarget, workflowPath: String, ref: String) async throws -> CoreDispatchDefinition {
        let response = try await call {
            try await client.describeWorkflowDispatch(.with {
                switch target {
                case .repository(let id): $0.repositoryID = id
                case .named(let ref):
                    $0.githubRepository = ref.fullName
                    $0.githubServer = ref.serverID
                }
                $0.workflowPath = workflowPath
                $0.ref = ref
            }, options: Self.options(Self.callTimeout))
        }
        return CoreDispatchDefinition(
            access: Self.map(response.status),
            dispatchable: response.dispatchable,
            inputs: response.inputs.map(Self.dispatchInput),
            parseError: response.parseError.isEmpty ? nil : response.parseError
        )
    }

    func prepareWorkflowDispatch(target: CoreGitHubTarget, workflowID: Int64, ref: String, inputs: [String: String]) async throws -> CorePreparedDispatch {
        let response = try await call {
            try await client.prepareWorkflowDispatch(.with {
                switch target {
                case .repository(let id): $0.repositoryID = id
                case .named(let ref):
                    $0.githubRepository = ref.fullName
                    $0.githubServer = ref.serverID
                }
                $0.workflowID = workflowID
                $0.ref = ref
                $0.inputs = inputs
            }, options: Self.options(Self.callTimeout))
        }
        return CorePreparedDispatch(
            access: Self.map(response.status),
            dispatchID: response.dispatchID.isEmpty ? nil : response.dispatchID,
            expiresAt: response.hasExpiresAt ? response.expiresAt.date : nil,
            problems: response.problems,
            workflowPath: response.workflowPath
        )
    }

    func confirmWorkflowDispatch(dispatchID: String) async throws -> CoreDispatchResult {
        let response = try await call {
            try await client.confirmWorkflowDispatch(.with { $0.dispatchID = dispatchID }, options: Self.options(Self.callTimeout))
        }
        return CoreDispatchResult(
            access: Self.map(response.status),
            dispatchedAt: response.hasDispatchedAt ? response.dispatchedAt.date : nil,
            runID: response.runID == 0 ? nil : response.runID,
            rejection: response.rejection.isEmpty ? nil : response.rejection,
            historyID: response.historyID == 0 ? nil : response.historyID
        )
    }

    func dispatchHistory(repositoryID: String, workflowPath: String) async throws -> [CoreDispatchRecord] {
        let response = try await call {
            try await client.listDispatchHistory(.with {
                $0.repositoryID = repositoryID
                $0.workflowPath = workflowPath
            }, options: Self.options(Self.callTimeout))
        }
        return response.records.map { record in
            CoreDispatchRecord(id: record.id, workflowPath: record.workflowPath, ref: record.ref, inputs: record.inputs,
                               omittedInputs: record.omittedInputs, sentAt: record.hasSentAt ? record.sentAt.date : .distantPast,
                               runID: record.runID)
        }
    }

    func linkDispatchRun(repositoryID: String, id: Int64, runID: Int64) async throws {
        _ = try await call {
            try await client.linkDispatchRun(.with {
                $0.repositoryID = repositoryID
                $0.id = id
                $0.runID = runID
            }, options: Self.options(Self.callTimeout))
        }
    }

    func clearDispatchHistory(repositoryID: String) async throws -> Int {
        let response = try await call {
            try await client.clearDispatchHistory(.with { $0.repositoryID = repositoryID }, options: Self.options(Self.callTimeout))
        }
        return Int(response.removed)
    }

    /// The whole log can take minutes to download, so this call waits longer.
    func saveJobLog(repositoryID: String, jobID: Int64) async throws -> CoreSavedJobLog {
        let response = try await call {
            try await client.saveJobLog(.with {
                $0.repositoryID = repositoryID
                $0.jobID = jobID
            }, options: Self.options(.seconds(330)))
        }
        let availability: CoreJobLogAvailability = switch response.availability {
        case .expired: .expired
        case .notReady: .notReady
        default: .available
        }
        return CoreSavedJobLog(access: Self.map(response.status), availability: availability,
                               file: response.path.isEmpty ? nil : URL(fileURLWithPath: response.path),
                               stoppedEarly: response.stoppedEarly)
    }

    /// A log of up to 50,000 lines can exceed gRPC's default 4 MiB message
    /// limit on the wire, so this call allows more.
    func jobLog(repositoryID: String, jobID: Int64) async throws -> CoreJobLog {
        var options = Self.options(.seconds(150))
        options.maxRequestMessageBytes = 16 << 20
        options.maxResponseMessageBytes = 16 << 20
        let response = try await call {
            try await client.getJobLog(.with {
                $0.repositoryID = repositoryID
                $0.jobID = jobID
            }, options: options)
        }
        let availability: CoreJobLogAvailability = switch response.availability {
        case .expired: .expired
        case .notReady: .notReady
        default: .available
        }
        return CoreJobLog(
            access: Self.map(response.status), availability: availability,
            lines: response.lines.map { line in
                let kind: CoreLogLineKind = switch line.kind {
                case .error: .error
                case .warning: .warning
                case .notice: .notice
                case .command: .command
                case .group: .group
                case .endGroup: .endGroup
                case .debug: .debug
                default: .plain
                }
                return CoreLogLine(number: line.number, text: line.text, kind: kind, stepNumber: line.stepNumber)
            },
            truncated: response.truncated,
            stoppedEarly: response.stoppedEarly
        )
    }

    func prepareRunAction(repositoryID: String, runID: Int64, action: CoreRunAction) async throws -> CorePreparedRunAction {
        let response = try await call {
            try await client.prepareRunAction(.with {
                $0.repositoryID = repositoryID
                $0.runID = runID
                $0.action = switch action {
                case .cancel: .cancel
                case .rerun: .rerun
                case .rerunFailed: .rerunFailed
                case .rerunJob: .rerunJob
                case .approveDeployments: .approveDeployments
                }
                if case .rerunJob(let id) = action { $0.jobID = id }
            }, options: Self.options(Self.callTimeout))
        }
        return CorePreparedRunAction(
            access: Self.map(response.status),
            actionID: response.actionID.isEmpty ? nil : response.actionID,
            expiresAt: response.hasExpiresAt ? response.expiresAt.date : nil,
            problems: response.problems,
            run: response.hasRun ? Self.map(response.run) : nil,
            environments: response.environments,
            job: response.hasJob ? Self.map(response.job) : nil
        )
    }

    func confirmRunAction(actionID: String) async throws -> CoreRunActionResult {
        let response = try await call {
            try await client.confirmRunAction(.with { $0.actionID = actionID }, options: Self.options(Self.callTimeout))
        }
        return CoreRunActionResult(
            access: Self.map(response.status),
            acceptedAt: response.hasAcceptedAt ? response.acceptedAt.date : nil,
            rejection: response.rejection.isEmpty ? nil : response.rejection
        )
    }

    // MARK: Local runs

    func toolReadiness(refresh: Bool) async throws -> CoreToolReadiness {
        // Checking the engine runs a few docker commands with their own timeouts.
        let response = try await call {
            try await client.getToolReadiness(.with { $0.refresh = refresh }, options: Self.options(.seconds(45)))
        }
        return Self.map(response.readiness)
    }

    func prepareLocalRun(repositoryID: String, workflowID: String, jobID: String?, event: String?,
                         useInstalledAct: Bool) async throws -> CorePreparedLocalRun {
        let response = try await call {
            try await client.prepareLocalRun(.with {
                $0.repositoryID = repositoryID
                $0.workflowID = workflowID
                $0.jobID = jobID ?? ""
                $0.event = event ?? ""
                $0.useInstalledAct = useInstalledAct
            }, options: Self.options(.seconds(90)))
        }
        return CorePreparedLocalRun(
            readiness: Self.map(response.readiness), plan: Self.map(response.plan),
            confirmationID: response.confirmationID.isEmpty ? nil : response.confirmationID,
            expiresAt: response.hasExpiresAt ? response.expiresAt.date : nil
        )
    }

    func confirmLocalRun(confirmationID: String, secrets: [String: String], variables: [String: String]) async throws -> CoreExecution {
        let response = try await call {
            try await client.confirmLocalRun(.with {
                $0.confirmationID = confirmationID
                $0.secrets = secrets
                $0.variables = variables
            }, options: Self.options(Self.callTimeout))
        }
        return CoreExecution(id: response.execution.executionID, repositoryID: response.execution.repositoryID,
                             state: Self.map(response.execution.state))
    }

    func parseEnvFile(content: Data) async throws -> CoreEnvFile {
        let response = try await call {
            try await client.parseEnvFile(.with { $0.content = content }, options: Self.options(Self.callTimeout))
        }
        return CoreEnvFile(entries: response.entries.map { CoreEnvEntry(name: $0.name, value: $0.value, encrypted: $0.encrypted, line: Int($0.line)) },
                           problems: response.problems.map { CoreEnvProblem(line: Int($0.line), message: $0.message) })
    }

    func localRunOutput(executionID: String, after: UInt64) async throws -> CoreLocalRunOutput {
        var options = Self.options(Self.callTimeout)
        // 5,000 lines of up to 4 KiB each can exceed gRPC's 4 MiB default.
        options.maxResponseMessageBytes = 32 << 20
        let response = try await call {
            try await client.getLocalRunOutput(.with {
                $0.executionID = executionID
                $0.afterSequence = after
            }, options: options)
        }
        let phase: CoreLocalRunPhase = switch response.phase {
        case .queued: .queued
        case .running: .running
        case .stopping: .stopping
        case .cleaningUp: .cleaningUp
        case .finished: .finished
        default: .unknown
        }
        return CoreLocalRunOutput(
            executionID: response.executionID, repositoryID: response.repositoryID,
            state: Self.map(response.state), phase: phase,
            lines: response.lines.map { CoreLocalRunLine(sequence: $0.sequence, jobID: $0.jobID, text: $0.text, isError: $0.error) },
            discarded: response.discarded, lastSequence: response.lastSequence,
            jobs: response.jobs.map { job in
                let state: CoreLocalJobState = switch job.state {
                case .waiting: .waiting
                case .running: .running
                case .succeeded: .succeeded
                case .failed: .failed
                case .skipped: .skipped
                case .unsupported: .unsupported
                case .cancelled: .cancelled
                case .notRun: .notRun
                default: .unknown
                }
                return CoreLocalRunJobStatus(id: job.id, name: job.name, state: state, reason: job.reason,
                                             startedAt: job.hasStartedAt ? job.startedAt.date : nil,
                                             finishedAt: job.hasFinishedAt ? job.finishedAt.date : nil)
            },
            plan: Self.map(response.plan),
            startedAt: response.hasStartedAt ? response.startedAt.date : nil,
            finishedAt: response.hasFinishedAt ? response.finishedAt.date : nil,
            exitCode: response.exitCode < 0 ? nil : Int(response.exitCode),
            message: response.message.isEmpty ? nil : response.message,
            cleanupProblem: response.cleanupProblem.isEmpty ? nil : response.cleanupProblem
        )
    }

    func cancelExecution(executionID: String) async throws {
        _ = try await call {
            try await client.cancelExecution(.with { $0.executionID = executionID }, options: Self.options(Self.callTimeout))
        }
    }

    static func map(_ state: Runnir_Core_V1_ToolState) -> CoreToolState {
        switch state {
        case .found: .found
        case .missing: .missing
        case .stopped: .stopped
        case .unsupported: .unsupported
        case .failed: .failed
        default: .unknown
        }
    }

    static func map(_ tool: Runnir_Core_V1_ToolStatus) -> CoreToolStatus {
        CoreToolStatus(state: map(tool.state), version: tool.version, path: tool.path, detail: tool.detail, untested: tool.untested)
    }

    static func map(_ readiness: Runnir_Core_V1_ToolReadiness) -> CoreToolReadiness {
        let engine = readiness.engine
        return CoreToolReadiness(
            bundledAct: map(readiness.bundledAct), installedAct: map(readiness.installedAct), dockerCLI: map(readiness.dockerCli),
            engine: CoreContainerEngine(state: map(engine.state), name: engine.name, context: engine.context, endpoint: engine.endpoint,
                                        local: engine.local, version: engine.version, architecture: engine.architecture,
                                        cpus: Int(engine.cpus), memoryBytes: engine.memoryBytes, detail: engine.detail),
            checkedAt: readiness.hasCheckedAt ? readiness.checkedAt.date : nil,
            testedActVersion: readiness.testedActVersion, minimumActVersion: readiness.minimumActVersion
        )
    }

    static func map(_ plan: Runnir_Core_V1_LocalRunPlan) -> CoreLocalRunPlan {
        CoreLocalRunPlan(
            workflowID: plan.workflowID, workflowName: plan.workflowName, events: plan.events, event: plan.event, jobID: plan.jobID,
            jobs: plan.jobs.map { job in
                let support: CoreLocalJobSupport = switch job.support {
                case .supported: .supported
                case .unsupported: .unsupported
                default: .unknown
                }
                return CoreLocalRunJob(id: job.id, name: job.name, runsOn: job.runsOn, image: job.image, support: support, reason: job.reason)
            },
            images: plan.images.map { CoreLocalRunImage(reference: $0.reference, present: $0.present) },
            secrets: plan.secrets, variables: plan.variables, unnamedSecrets: plan.unnamedSecrets,
            notes: plan.notes, blockers: plan.blockers,
            cpus: Int(plan.cpus), memoryBytes: plan.memoryBytes, timeoutSeconds: Int(plan.timeoutSeconds),
            actVersion: plan.actVersion, installedAct: plan.installedAct, engineName: plan.engineName, engineContext: plan.engineContext
        )
    }

    static func map(_ status: Runnir_Core_V1_GitHubStatus) -> CoreGitHubAccess {
        switch status.access {
        case .ok: .ok
        case .noRemote: .noRemote
        case .signedOut: .signedOut
        case .tokenRejected: .tokenRejected
        case .notVisible: .notVisible
        case .permissionMissing: .permissionMissing
        case .rateLimited: .rateLimited(until: status.hasRetryAfter ? status.retryAfter.date : nil)
        default: .unavailable
        }
    }

    func events(repositoryIDs: [String]) -> AsyncThrowingStream<CoreEvent, any Error> {
        let client = client
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await client.subscribeEvents(.with { $0.repositoryIds = repositoryIDs }) { response in
                        for try await message in response.messages {
                            continuation.yield(Self.map(message))
                        }
                    }
                    continuation.finish(throwing: CoreServiceError.unavailable)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Mapping

    private func call<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as CoreServiceError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.map(error)
        }
    }

    static func map(_ error: any Error) -> CoreServiceError {
        guard let rpc = error as? RPCError else { return .unavailable }
        switch rpc.code {
        case .notFound: return .notFound
        case .invalidArgument: return .invalidArgument(rpc.message)
        case .failedPrecondition: return .failedPrecondition(rpc.message)
        case .alreadyExists: return .alreadyExists(rpc.message)
        case .resourceExhausted: return .resourceExhausted
        case .permissionDenied: return .accessDenied
        case .deadlineExceeded: return .timedOut
        case .unavailable, .cancelled: return .unavailable
        default: return .remote(code: rpc.code.rawValue, message: rpc.message)
        }
    }

    static func map(_ repository: Runnir_Core_V1_Repository) -> CoreRepository {
        CoreRepository(
            id: repository.id,
            path: repository.path,
            branch: repository.branch,
            workflowCount: Int(repository.workflowCount),
            lastRefresh: repository.hasLastRefresh ? repository.lastRefresh.date : nil,
            githubRepository: repository.githubRepository.isEmpty ? nil : repository.githubRepository,
            githubServerID: repository.githubRepository.isEmpty ? nil : repository.githubServerID,
            originHost: repository.originHost.isEmpty ? nil : repository.originHost
        )
    }

    static func map(_ state: Runnir_Core_V1_ExecutionState) -> CoreExecutionState {
        switch state {
        case .queued: .queued
        case .running: .running
        case .succeeded: .succeeded
        case .failed: .failed
        case .cancelled: .cancelled
        default: .unspecified
        }
    }

    static func map(_ event: Runnir_Core_V1_CoreEvent) -> CoreEvent {
        let kind: CoreEventKind = switch event.type {
        case .coreReady: .ready
        case .repositoryOpened: .repositoryOpened
        case .repositoryRefreshed: .repositoryRefreshed
        case .repositoryClosed: .repositoryClosed
        case .workflowStarted: .workflowStarted
        case .workflowStatusChanged: .workflowStatusChanged
        case .workflowCompleted: .workflowCompleted
        case .workflowFailed: .workflowFailed
        case .coreError: .coreError
        case .activityChanged: .activityChanged
        default: .unknown
        }
        return CoreEvent(
            sequence: event.sequence,
            kind: kind,
            repositoryID: event.repositoryID.isEmpty ? nil : event.repositoryID,
            executionID: event.executionID.isEmpty ? nil : event.executionID,
            executionState: map(event.executionState),
            message: event.message.isEmpty ? nil : event.message,
            date: event.hasOccurredAt ? event.occurredAt.date : Date()
        )
    }
}
