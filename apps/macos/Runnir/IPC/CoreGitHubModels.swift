import Foundation

/// What the Core could do with GitHub for a repository.
enum CoreGitHubAccess: Equatable, Sendable {
    case ok
    /// The working tree has no origin on github.com.
    case noRemote
    case signedOut
    /// GitHub refused the token; the Core forgot it.
    case tokenRejected
    /// The Runnir Desktop app is not installed on the repository, or the user cannot see it.
    case notVisible
    /// The app is installed, but it or the user lacks a permission for this:
    /// the installation has not accepted new permissions, or the user cannot
    /// write to the repository.
    case permissionMissing
    case rateLimited(until: Date?)
    case unavailable
}

/// A GitHub answer: the access outcome and the items when it was `.ok`.
struct CoreGitHubResult<Item: Sendable>: Sendable {
    let access: CoreGitHubAccess
    let items: [Item]
}

extension CoreGitHubResult: Equatable where Item: Equatable {}

/// The GitHub repository a working tree is linked to, as the Core reads it.
struct CoreGitHubRepository: Equatable, Sendable {
    let access: CoreGitHubAccess
    let fullName: String
    /// "public", "private" or "internal".
    let visibility: String
    let defaultBranch: String
    let htmlURL: URL?
    /// The signed-in user can push, so can start, cancel and re-run workflows.
    var canPush = false
    /// The installation of the repository's owner, when the user can see it.
    var installation: CoreGitHubInstallation? = nil

    static func failed(_ access: CoreGitHubAccess) -> CoreGitHubRepository {
        CoreGitHubRepository(access: access, fullName: "", visibility: "", defaultBranch: "", htmlURL: nil)
    }
}

/// An account where the Runnir Desktop app is installed.
struct CoreGitHubInstallation: Equatable, Identifiable, Sendable {
    let id: Int64
    let account: String
    /// "User" or "Organization".
    let accountType: String
    /// "all" or "selected".
    let repositorySelection: String
    /// Where the account's owner changes which repositories the app reaches
    /// and accepts new permissions.
    let htmlURL: URL?
    /// Permissions Runnir needs that the installation has not granted, such
    /// as "actions: write".
    var missingPermissions: [String] = []
    var suspended = false
}

/// A github.com repository the signed-in user's token reaches.
struct CoreGitHubAccountRepository: Equatable, Identifiable, Sendable {
    var id: String { fullName }
    /// "owner/name" as GitHub spells it.
    let fullName: String
    let owner: String
    let name: String
    let description: String
    /// "public", "private" or "internal".
    let visibility: String
    let defaultBranch: String
    let htmlURL: URL?
    let pushedAt: Date?
    let archived: Bool
    let fork: Bool
    /// The user can push, so can start workflows.
    let canPush: Bool
    let installationID: Int64
}

/// The repositories of the accounts where the app is installed.
struct CoreGitHubAccount: Equatable, Sendable {
    let access: CoreGitHubAccess
    let installations: [CoreGitHubInstallation]
    /// Newest push first.
    let repositories: [CoreGitHubAccountRepository]
    /// More repositories exist than the Core read.
    let truncated: Bool

    static func failed(_ access: CoreGitHubAccess) -> CoreGitHubAccount {
        CoreGitHubAccount(access: access, installations: [], repositories: [], truncated: false)
    }
}

struct CoreGitHubWorkflow: Equatable, Identifiable, Sendable {
    let id: Int64
    let name: String
    let path: String
    let state: String
    let htmlURL: URL?

    /// A workflow file that can be started by hand when it has a
    /// workflow_dispatch trigger. Workflows GitHub runs itself (Dependabot,
    /// code scanning: "dynamic/...") cannot be.
    var canBeStartedByHand: Bool { state == "active" && path.hasPrefix(".github/workflows/") }
}

/// GitHub's run status and conclusion, kept as strings from the API and
/// interpreted by `CoreRunOutcome`.
struct CoreWorkflowRun: Equatable, Identifiable, Sendable {
    let id: Int64
    let workflowID: Int64
    let name: String
    let displayTitle: String
    let runNumber: Int64
    let event: String
    let status: String
    let conclusion: String?
    let branch: String
    let headSHA: String
    let actor: String?
    let htmlURL: URL?
    let createdAt: Date?
    let updatedAt: Date?
    /// 1 for the first attempt; each re-run adds one.
    var runAttempt: Int64 = 1

    var outcome: CoreRunOutcome { CoreRunOutcome(status: status, conclusion: conclusion) }
    var title: String { displayTitle.isEmpty ? name : displayTitle }
    /// GitHub re-runs failed jobs only for a run that ended with failed or
    /// cancelled jobs; a startup failure has no jobs to re-run.
    var canRerunFailedJobs: Bool {
        status == "completed" && ["failure", "cancelled", "timed_out"].contains(conclusion ?? "")
    }
}

struct CoreRunStep: Equatable, Identifiable, Sendable {
    let number: Int64
    let name: String
    let status: String
    let conclusion: String?
    var startedAt: Date? = nil
    var completedAt: Date? = nil
    var id: Int64 { number }
    var outcome: CoreRunOutcome { CoreRunOutcome(status: status, conclusion: conclusion) }
}

struct CoreRunJob: Equatable, Identifiable, Sendable {
    let id: Int64
    let name: String
    let status: String
    let conclusion: String?
    let startedAt: Date?
    let completedAt: Date?
    let htmlURL: URL?
    let steps: [CoreRunStep]
    var outcome: CoreRunOutcome { CoreRunOutcome(status: status, conclusion: conclusion) }
}

/// The one thing a person wants to know about a run, job or step.
enum CoreRunOutcome: Equatable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case cancelled
    case skipped
    case neutral

    init(status: String, conclusion: String?) {
        switch (status, conclusion ?? "") {
        case ("completed", "success"): self = .succeeded
        case ("completed", "failure"), ("completed", "timed_out"), ("completed", "startup_failure"): self = .failed
        case ("completed", "cancelled"): self = .cancelled
        case ("completed", "skipped"): self = .skipped
        case ("completed", _): self = .neutral
        case ("in_progress", _): self = .running
        default: self = .queued // queued, waiting, requested, pending
        }
    }

    /// Still going: worth checking again soon.
    var isActive: Bool { self == .queued || self == .running }

    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "In progress"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .skipped: "Skipped"
        case .neutral: "Completed"
        }
    }

    var symbol: String {
        switch self {
        case .queued: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .cancelled: "stop.circle"
        case .skipped: "arrow.uturn.right.circle"
        case .neutral: "minus.circle"
        }
    }
}

// MARK: Dispatch

struct CoreGitHubRefs: Equatable, Sendable {
    let access: CoreGitHubAccess
    let defaultBranch: String
    let branches: [String]
    let tags: [String]
}

enum CoreDispatchInputKind: Equatable, Sendable {
    case string, boolean, choice, number, environment
}

struct CoreDispatchInput: Equatable, Identifiable, Sendable {
    let name: String
    let description: String
    let kind: CoreDispatchInputKind
    let required: Bool
    let defaultValue: String
    let options: [String]
    var id: String { name }
}

/// Whether a workflow can be started by hand at a ref, from the file GitHub
/// will run.
struct CoreDispatchDefinition: Equatable, Sendable {
    let access: CoreGitHubAccess
    let dispatchable: Bool
    let inputs: [CoreDispatchInput]
    let parseError: String?
}

/// A validated dispatch waiting for the user's confirmation, or the reasons it
/// cannot run.
struct CorePreparedDispatch: Equatable, Sendable {
    let access: CoreGitHubAccess
    let dispatchID: String?
    let expiresAt: Date?
    let problems: [String]
    let workflowPath: String
}

struct CoreDispatchResult: Equatable, Sendable {
    let access: CoreGitHubAccess
    /// Set when GitHub accepted the request.
    let dispatchedAt: Date?
    /// The new run when GitHub said which one it started.
    let runID: Int64?
    /// GitHub's reason when it refused the request.
    let rejection: String?
}

// MARK: Logs and run actions

enum CoreLogLineKind: Equatable, Sendable {
    case plain, error, warning, notice, command, group, endGroup, debug
}

struct CoreLogLine: Equatable, Identifiable, Sendable {
    /// Counts from 1 in the full log, including lines dropped by truncation.
    let number: Int64
    let text: String
    let kind: CoreLogLineKind
    /// The step running when the line was written; 0 when none matched.
    let stepNumber: Int64
    var id: Int64 { number }
}

enum CoreJobLogAvailability: Equatable, Sendable {
    case available
    /// GitHub no longer has the log.
    case expired
    /// The job has not finished; GitHub serves the log afterwards.
    case notReady
}

struct CoreJobLog: Equatable, Sendable {
    let access: CoreGitHubAccess
    let availability: CoreJobLogAvailability
    let lines: [CoreLogLine]
    /// Earlier lines were dropped to keep the log bounded.
    let truncated: Bool
    /// The log is larger than the Core reads: the lines end before the log does.
    var stoppedEarly = false

    static func failed(_ access: CoreGitHubAccess) -> CoreJobLog {
        CoreJobLog(access: access, availability: .available, lines: [], truncated: false)
    }
}

enum CoreRunAction: Equatable, Sendable {
    case cancel
    case rerun
    case rerunFailed

    var title: String {
        switch self {
        case .cancel: "Cancel Run"
        case .rerun: "Re-run all jobs"
        case .rerunFailed: "Re-run failed jobs"
        }
    }
}

/// A run action checked against the run's current state, waiting for the
/// user's confirmation, or the reasons it cannot be taken now.
struct CorePreparedRunAction: Equatable, Sendable {
    let access: CoreGitHubAccess
    let actionID: String?
    let expiresAt: Date?
    let problems: [String]
    /// The run as GitHub reported it while preparing.
    let run: CoreWorkflowRun?
}

struct CoreRunActionResult: Equatable, Sendable {
    let access: CoreGitHubAccess
    /// Set when GitHub accepted the request; the outcome follows in the run.
    let acceptedAt: Date?
    /// GitHub's reason when it refused the request.
    let rejection: String?
}
