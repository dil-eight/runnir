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
    func startWorkflow(repositoryID: String, workflowID: String, ref: String?) async throws -> CoreExecution
    /// Hands the signed-in user's GitHub token to the Core's memory; nil clears it.
    func setGitHubCredential(_ token: String?) async throws
    /// GitHub Actions data for the repository's origin on github.com.
    func listGitHubWorkflows(repositoryID: String) async throws -> CoreGitHubResult<CoreGitHubWorkflow>
    func listWorkflowRuns(repositoryID: String, branch: String?, limit: Int) async throws -> CoreGitHubResult<CoreWorkflowRun>
    func listRunJobs(repositoryID: String, runID: Int64) async throws -> CoreGitHubResult<CoreRunJob>
    /// The first element is `.ready`. The stream fails with
    /// `.resourceExhausted` when the subscriber falls behind and with
    /// `.unavailable` when the Core goes away; callers resubscribe and reload.
    func events(repositoryIDs: [String]) -> AsyncThrowingStream<CoreEvent, any Error>
}
