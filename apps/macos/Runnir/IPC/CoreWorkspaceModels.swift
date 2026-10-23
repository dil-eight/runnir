import Foundation

/// Where a workspace's activity comes from, as the Core says.
enum CoreActivitySource: Equatable, Sendable {
    /// Nothing is saved for the repository the origin points at now.
    case none
    /// Read from this Mac; no sync pass reached GitHub since the Core started.
    case cache
    /// A sync pass reached GitHub since the Core started.
    case live
}

/// How fresh a workspace's cached activity is.
struct CoreActivityFreshness: Equatable, Sendable {
    var source: CoreActivitySource = .none
    /// A sync pass is running.
    var syncing = false
    /// The last pass's outcome, or why there is none; nil before the first.
    var access: CoreGitHubAccess?
    /// When the last pass ended.
    var checkedAt: Date?
    /// When a pass last got answers from GitHub (new data or none).
    var syncedAt: Date?
    /// When the saved data last changed.
    var changedAt: Date?
}

/// A workspace's GitHub activity as saved by the Core.
struct CoreWorkspaceActivity: Equatable, Sendable {
    var runs: [CoreWorkflowRun]
    var workflows: [CoreGitHubWorkflow]
    var freshness: CoreActivityFreshness
}

enum CoreStorageState: Equatable, Sendable {
    case persistent
    /// Kept in memory for now; the note says why.
    case memoryOnly
    /// Nothing on this Mac.
    case absent
}

/// What one workspace keeps on this Mac.
struct CoreWorkspaceStorage: Equatable, Identifiable, Sendable {
    let workspaceID: UUID
    let state: CoreStorageState
    /// Why it is in memory, or what recovery did.
    let note: String?
    let isOpen: Bool
    let databaseBytes: UInt64
    let logBytes: UInt64
    let cachedRuns: Int
    let localRuns: Int
    let recoveryCopies: Int
    var id: UUID { workspaceID }
}

struct CoreStorageUsage: Equatable, Sendable {
    let workspaces: [CoreWorkspaceStorage]
    let keepJobLogs: Bool
}
