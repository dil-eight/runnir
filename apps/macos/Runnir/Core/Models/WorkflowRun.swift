import Foundation

struct WorkflowRun: Identifiable, Equatable, Sendable {
    let id: Int64
    let workflowID: Int64
    let commitSHA: String
    let branch: String
    let event: String
    let status: WorkflowRunStatus
    let conclusion: WorkflowRunConclusion?
    let runAttempt: Int
    let createdAt: Date
    let updatedAt: Date
}

enum WorkflowRunStatus: String, Codable, Equatable, Sendable {
    case queued
    case inProgress = "in_progress"
    case completed
    case waiting
    case requested
    case pending
}

enum WorkflowRunConclusion: String, Codable, Equatable, Sendable {
    case success
    case failure
    case neutral
    case cancelled
    case skipped
    case timedOut = "timed_out"
    case actionRequired = "action_required"
}
