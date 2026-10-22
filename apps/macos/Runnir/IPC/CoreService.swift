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
    /// "owner/name" from the origin remote on github.com, if any.
    var githubRepository: String? = nil
}

struct CoreJob: Equatable, Sendable {
    let id: String
    let name: String
    let needs: [String]
}

struct CoreWorkflow: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let triggers: [String]
    let jobs: [CoreJob]
    let parseError: String?
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
    func openRepository(path: String) async throws -> CoreRepository
    func refreshRepository(id: String) async throws -> CoreRepository
    func closeRepository(id: String) async throws
    func listWorkflows(repositoryID: String) async throws -> [CoreWorkflow]
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
    /// Hands the signed-in user's GitHub token to the Core's memory; nil clears it.
    /// The kind of the token now held, nil when cleared.
    @discardableResult
    func setGitHubCredential(_ token: String?) async throws -> CoreGitHubCredentialKind?
    /// What a token can do; the held token is not changed.
    func checkGitHubToken(_ token: String) async throws -> CoreGitHubTokenCheck
    /// "owner/name" of the github.com repository each working tree's origin
    /// points at, by path; read from git's metadata without opening them.
    func githubOrigins(paths: [String]) async throws -> [String: String]
    /// The github.com repositories the token reaches, and the accounts where
    /// the Runnir Desktop app is installed.
    func listGitHubRepositories() async throws -> CoreGitHubAccount
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
    /// The end of one job's log, split into lines tagged with kind and step.
    func jobLog(repositoryID: String, jobID: Int64) async throws -> CoreJobLog
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
    /// Starts a prepared local run once. Throws `.failedPrecondition` when the
    /// confirmation expired or was used, or the file changed after the review.
    func confirmLocalRun(confirmationID: String) async throws -> CoreExecution
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
    /// A github.com repository named "owner/name", with no local clone.
    case named(String)
}

extension CoreServicing {
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
