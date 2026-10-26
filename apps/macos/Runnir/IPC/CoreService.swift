import Foundation

/// App-facing model of the Core API. The generated gRPC types stay inside
/// `GRPCCoreService`, so views and coordinators never depend on the wire format.
struct CoreHealth: Equatable, Sendable {
    let coreVersion: String
    let protocolVersion: Int
    let openRepositoryCount: Int
    let residentMemoryBytes: UInt64
    /// OS process id of the answering Core; 0 when not reported.
    var processID: Int32 = 0
}

struct CoreRepository: Equatable, Identifiable, Sendable {
    let id: String
    let path: String
    let branch: String
    let workflowCount: Int
    let lastRefresh: Date?
    /// "owner/name" from the origin remote, on github.com or an Enterprise
    /// server the Core holds, if any.
    var githubRepository: String? = nil
    /// Server id of `githubRepository`; empty is github.com.
    var githubServerID: String? = nil
    /// The origin's host, even when no server matches it.
    var originHost: String? = nil
}

struct CoreJob: Equatable, Sendable {
    let id: String
    let name: String
    let needs: [String]
    /// The job's if requires a workflow_dispatch run: it is started by hand,
    /// with the inputs that if fixes.
    var manual = false
    var manualInputs: [String: String] = [:]
}

struct CoreWorkflow: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let triggers: [String]
    let jobs: [CoreJob]
    let parseError: String?
    /// The workflow_dispatch inputs the local file declares.
    var dispatchInputs: [CoreDispatchInput] = []
    /// The file sets concurrency at the top level or in a job.
    var concurrency = false
    /// The secrets.X and vars.X names the file reads, upper-cased.
    var secrets: [String] = []
    var variables: [String] = []
}

/// A Run Workflow preset the repository shares in .runnir/launches, or, with
/// `problem` set, a file or folder there that cannot be used.
struct CoreLaunchPreset: Equatable, Identifiable, Sendable {
    /// ".runnir/launches/<file>", or ".runnir" / ".runnir/launches" for an
    /// entry about that folder.
    let path: String
    let name: String
    /// ".github/workflows/<file>"; empty with a problem.
    let workflowPath: String
    /// nil keeps the form's branch.
    let ref: String?
    let inputs: [String: String]
    let problem: String?

    var id: String { path }
}

/// One actionlint finding. Line and column are 1-based, 0 when unknown.
struct CoreWorkflowDiagnostic: Equatable, Sendable {
    let line: Int
    let column: Int
    /// The actionlint rule, for example "syntax-check".
    let kind: String
    let message: String
}

struct CoreWorkflowValidation: Equatable, Sendable {
    /// ".github/workflows/<name>", as in `CoreWorkflow.id`.
    let workflowID: String
    let diagnostics: [CoreWorkflowDiagnostic]
    /// Set when the file could not be checked.
    let problem: String?
    let truncated: Bool
}

struct CoreValidationReport: Equatable, Sendable {
    let workflows: [CoreWorkflowValidation]
    /// "actionlint v1.7.12".
    let validator: String
    /// The repository's actionlint config could not be used.
    let configProblem: String?

    func validation(for workflowID: String) -> CoreWorkflowValidation? {
        workflows.first { $0.workflowID == workflowID }
    }
}

/// What a save did: the digest of the file now on disk, and whether the
/// save was refused because the file had changed.
struct CoreWorkflowSave: Equatable, Sendable {
    let sha256: String
    let conflict: Bool
}

enum CoreExecutionState: Equatable, Sendable {
    case unspecified, queued, running, succeeded, failed, cancelled
}

struct CoreExecution: Equatable, Sendable {
    let id: String
    let repositoryID: String
    let state: CoreExecutionState
}

enum CoreEventKind: Equatable, Sendable {
    case ready
    case repositoryOpened, repositoryRefreshed, repositoryClosed
    case workflowStarted, workflowStatusChanged, workflowCompleted, workflowFailed
    case coreError
    /// A workspace's saved activity or its freshness changed.
    case activityChanged
    case unknown
}

struct CoreEvent: Equatable, Sendable {
    let sequence: UInt64
    let kind: CoreEventKind
    let repositoryID: String?
    let executionID: String?
    let executionState: CoreExecutionState
    let message: String?
    let date: Date
}

enum CoreServiceError: Error, Equatable, Sendable {
    /// The Core process is not running or the connection was lost.
    case unavailable
    case notFound
    case invalidArgument(String)
    case failedPrecondition(String)
    /// The name is taken; nothing was replaced.
    case alreadyExists(String)
    /// The operating system denies the Core read access to the folder.
    case accessDenied
    /// The call's deadline passed; the Core may still be healthy.
    case timedOut
    /// The Core queue or an event subscriber limit was hit; retry or resync.
    case resourceExhausted
    case incompatibleProtocol(Int)
    case remote(code: Int, message: String)
}

/// Operations the app needs from the Core. Every repository call carries the
/// repository id. Implementations are safe to call from any task.
protocol CoreServicing: Sendable {
    func healthCheck() async throws -> CoreHealth
    /// Opens a working tree; with `workspaceID` it gets the workspace's
    /// database and sync in the Core.
    func openRepository(path: String, workspaceID: UUID?) async throws -> CoreRepository
    /// The workspace's activity as saved on this Mac; never waits for GitHub.
    func workspaceActivity(repositoryID: String, limit: Int) async throws -> CoreWorkspaceActivity
    /// Asks the workspace's sync for a pass; with `wait`, answers after it.
    func refreshWorkspaceActivity(repositoryID: String, wait: Bool, limit: Int) async throws -> CoreWorkspaceActivity
    /// Reads one page of older runs from GitHub into the workspace's cache.
    func loadOlderRuns(repositoryID: String) async throws -> CoreOlderRuns
    /// What workspaces keep on this Mac; empty ids: all with data and all open.
    func storageUsage(workspaceIDs: [UUID]) async throws -> CoreStorageUsage
    /// Deletes what can be downloaded again; empty ids: every workspace.
    func clearWorkspaceCache(workspaceIDs: [UUID]) async throws -> [CoreWorkspaceStorage]
    /// Deletes a closed workspace's data folder.
    func deleteWorkspaceData(workspaceID: UUID) async throws
    /// Whether finished jobs' logs are kept; off with `deleteKeptLogs` also
    /// deletes the logs kept so far.
    func setStoragePreferences(keepJobLogs: Bool, deleteKeptLogs: Bool) async throws
    func refreshRepository(id: String) async throws -> CoreRepository
    func closeRepository(id: String) async throws
    func listWorkflows(repositoryID: String) async throws -> [CoreWorkflow]
    /// The repository's presets in .runnir/launches from the Core's latest
    /// scan, with entries for files it cannot use.
    func listLaunchPresets(repositoryID: String) async throws -> [CoreLaunchPreset]
    /// Checks the workflow files on disk with the Core's built-in actionlint;
    /// nil `workflowID` checks all of them.
    func validateWorkflows(repositoryID: String, workflowID: String?) async throws -> CoreValidationReport
    func startWorkflow(repositoryID: String, workflowID: String, ref: String?) async throws -> CoreExecution
    /// Saves an edited workflow file if it still has `baseSHA256` on disk
    /// (or `overwrite`); a changed file comes back as a conflict, unwritten.
    func saveWorkflowFile(repositoryID: String, workflowID: String, content: String, baseSHA256: String,
                          overwrite: Bool) async throws -> CoreWorkflowSave
    /// Adds a workflow file named `fileName` to .github/workflows; empty
    /// `content` writes the Core's starter. Returns the new workflow id.
    func createWorkflowFile(repositoryID: String, fileName: String, content: String) async throws -> String
    /// Renames a workflow file within its folder; returns the new workflow id.
    func renameWorkflowFile(repositoryID: String, workflowID: String, newFileName: String) async throws -> String
    /// The editor's text with the suggested concurrency block, or why not;
    /// nothing is written.
    func insertWorkflowConcurrency(repositoryID: String, content: String) async throws -> CoreConcurrencyInsertion
    /// Hands a server's GitHub token to the Core's memory; nil clears it
    /// (for an Enterprise server, forgets the server). The kind of the
    /// token now held, nil when cleared.
    @discardableResult
    func setGitHubCredential(_ token: String?, server: GitHubServerRef) async throws -> CoreGitHubCredentialKind?
    /// What a token can do on a server; the held tokens are not changed.
    func checkGitHubToken(_ token: String, server: GitHubServerRef) async throws -> CoreGitHubTokenCheck
    /// The user's open pull requests on one server with their CI, and those
    /// closed since.
    func listPullRequests(server: String, closedSince: Date) async throws -> CorePullRequests
    /// The repository each working tree's origin points at, on github.com or
    /// an Enterprise server the Core holds, by path; read from git's
    /// metadata without opening them.
    func githubOrigins(paths: [String]) async throws -> [String: GitHubRepositoryRef]
    /// The repositories a server's token reaches, and the accounts where the
    /// Runnir Desktop app is installed (github.com).
    func listGitHubRepositories(server: String) async throws -> CoreGitHubAccount
    /// GitHub Actions data for a repository's origin on github.com, or for a
    /// repository named directly.
    func listGitHubWorkflows(target: CoreGitHubTarget) async throws -> CoreGitHubResult<CoreGitHubWorkflow>
    /// Whether the token can see the GitHub repository, and its details.
    func gitHubRepository(target: CoreGitHubTarget) async throws -> CoreGitHubRepository
    func listWorkflowRuns(target: CoreGitHubTarget, branch: String?, limit: Int) async throws -> CoreGitHubResult<CoreWorkflowRun>
    func listRunJobs(repositoryID: String, runID: Int64) async throws -> CoreGitHubResult<CoreRunJob>
    func listGitHubRefs(target: CoreGitHubTarget) async throws -> CoreGitHubRefs
    func describeWorkflowDispatch(target: CoreGitHubTarget, workflowPath: String, ref: String) async throws -> CoreDispatchDefinition
    /// Validates a dispatch in the Core; nothing is sent to GitHub yet.
    func prepareWorkflowDispatch(target: CoreGitHubTarget, workflowID: Int64, ref: String, inputs: [String: String]) async throws -> CorePreparedDispatch
    /// Sends a prepared dispatch once. Throws when the confirmation expired or was used.
    func confirmWorkflowDispatch(dispatchID: String) async throws -> CoreDispatchResult
    /// The dispatches sent from this Mac for a workspace, newest first; an empty path lists every workflow's.
    func dispatchHistory(repositoryID: String, workflowPath: String) async throws -> [CoreDispatchRecord]
    /// Says which run a history entry started. The Core keeps the first answer.
    func linkDispatchRun(repositoryID: String, id: Int64, runID: Int64) async throws
    /// The end of one job's log, split into lines tagged with kind and step.
    func jobLog(repositoryID: String, jobID: Int64) async throws -> CoreJobLog
    /// Writes one job's whole log to a file for an editor.
    func saveJobLog(repositoryID: String, jobID: Int64) async throws -> CoreSavedJobLog
    /// Checks a cancel or re-run against the run's state; nothing is sent yet.
    func prepareRunAction(repositoryID: String, runID: Int64, action: CoreRunAction) async throws -> CorePreparedRunAction
    /// Sends a prepared run action once. Throws when the confirmation expired or was used.
    func confirmRunAction(actionID: String) async throws -> CoreRunActionResult
    /// act, the Docker CLI and the container engine as found on this Mac.
    /// Read-only; `refresh` checks again instead of reusing the last result.
    func toolReadiness(refresh: Bool) async throws -> CoreToolReadiness
    /// Checks the tools and the workflow file and returns the plan, with a
    /// single-use confirmation when nothing blocks it. Starts nothing.
    func prepareLocalRun(repositoryID: String, workflowID: String, jobID: String?, event: String?,
                         useInstalledAct: Bool) async throws -> CorePreparedLocalRun
    /// Starts a prepared local run once with the values for the plan's
    /// secrets and variables. Throws `.failedPrecondition` when the
    /// confirmation expired or was used, or the file changed after the
    /// review, and `.invalidArgument` for a name the plan does not read.
    func confirmLocalRun(confirmationID: String, secrets: [String: String], variables: [String: String]) async throws -> CoreExecution
    /// Parses the bytes of a .env file the user chose; values encrypted by
    /// dotenvx are flagged. The Core reads no path for this.
    func parseEnvFile(content: Data) async throws -> CoreEnvFile
    /// A local run's state and the output lines after `after`.
    func localRunOutput(executionID: String, after: UInt64) async throws -> CoreLocalRunOutput
    func cancelExecution(executionID: String) async throws
    /// The first element is `.ready`. The stream fails with
    /// `.resourceExhausted` when the subscriber falls behind and with
    /// `.unavailable` when the Core goes away; callers resubscribe and reload.
    func events(repositoryIDs: [String]) -> AsyncThrowingStream<CoreEvent, any Error>
}

/// The GitHub repository a call is about.
enum CoreGitHubTarget: Hashable, Sendable {
    /// The origin of a repository open in the Core, by its Core id.
    case repository(String)
    /// A repository with no local clone, on its server.
    case named(GitHubRepositoryRef)
}

extension CoreServicing {
    func openRepository(path: String) async throws -> CoreRepository {
        try await openRepository(path: path, workspaceID: nil)
    }

    /// github.com's token.
    @discardableResult
    func setGitHubCredential(_ token: String?) async throws -> CoreGitHubCredentialKind? {
        try await setGitHubCredential(token, server: .dotCom)
    }

    func checkGitHubToken(_ token: String) async throws -> CoreGitHubTokenCheck {
        try await checkGitHubToken(token, server: .dotCom)
    }

    func gitHubRepository(repositoryID: String) async throws -> CoreGitHubRepository {
        try await gitHubRepository(target: .repository(repositoryID))
    }

    func listGitHubWorkflows(repositoryID: String) async throws -> CoreGitHubResult<CoreGitHubWorkflow> {
        try await listGitHubWorkflows(target: .repository(repositoryID))
    }

    func listWorkflowRuns(repositoryID: String, branch: String?, limit: Int) async throws -> CoreGitHubResult<CoreWorkflowRun> {
        try await listWorkflowRuns(target: .repository(repositoryID), branch: branch, limit: limit)
    }

    func listGitHubRefs(repositoryID: String) async throws -> CoreGitHubRefs {
        try await listGitHubRefs(target: .repository(repositoryID))
    }

    func describeWorkflowDispatch(repositoryID: String, workflowPath: String, ref: String) async throws -> CoreDispatchDefinition {
        try await describeWorkflowDispatch(target: .repository(repositoryID), workflowPath: workflowPath, ref: ref)
    }

    func prepareWorkflowDispatch(repositoryID: String, workflowID: Int64, ref: String, inputs: [String: String]) async throws -> CorePreparedDispatch {
        try await prepareWorkflowDispatch(target: .repository(repositoryID), workflowID: workflowID, ref: ref, inputs: inputs)
    }
}
