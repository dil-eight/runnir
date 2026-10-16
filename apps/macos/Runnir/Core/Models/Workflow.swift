import Foundation

struct Workflow: Identifiable, Equatable, Sendable {
    let id: Int64
    let repositoryFullName: String
    let name: String
    let path: String
    let state: WorkflowState
}

enum WorkflowState: String, Codable, Equatable, Sendable {
    case active
    case deleted
    case disabledFork = "disabled_fork"
    case disabledInactive = "disabled_inactivity"
    case disabledManually = "disabled_manually"
}
