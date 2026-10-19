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
    case rateLimited(until: Date?)
    case unavailable
}

/// A GitHub answer: the access outcome and the items when it was `.ok`.
struct CoreGitHubResult<Item: Sendable>: Sendable {
    let access: CoreGitHubAccess
    let items: [Item]
}

extension CoreGitHubResult: Equatable where Item: Equatable {}

struct CoreGitHubWorkflow: Equatable, Identifiable, Sendable {
    let id: Int64
    let name: String
    let path: String
    let state: String
    let htmlURL: URL?
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

    var outcome: CoreRunOutcome { CoreRunOutcome(status: status, conclusion: conclusion) }
    var title: String { displayTitle.isEmpty ? name : displayTitle }
}

struct CoreRunStep: Equatable, Identifiable, Sendable {
    let number: Int64
    let name: String
    let status: String
    let conclusion: String?
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
