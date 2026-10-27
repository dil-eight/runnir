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
    /// Reading pull requests: nil before a read, else .ok or why not.
    var pullRequestsAccess: CoreGitHubAccess?
}

/// A workspace's GitHub activity as saved by the Core.
struct CoreWorkspaceActivity: Equatable, Sendable {
    var runs: [CoreWorkflowRun]
    var workflows: [CoreGitHubWorkflow]
    var freshness: CoreActivityFreshness
    /// The changes of `runs`, newest first.
    var changes: [CoreRunChange] = []
    var concurrencyHints: [CoreConcurrencyHint] = []
    /// Every run the Core keeps for the workspace.
    var cachedRuns = 0
    /// GitHub has no run older than the oldest kept.
    var historyComplete = false
    /// What this Mac saved the workspace, one total per kind.
    var savings: [CoreSaving] = []
}

/// What a saving total counts.
enum CoreSavingKind: Equatable, Sendable {
    /// Local runs that ended with a result, in the minutes GitHub would have
    /// billed for their jobs (each rounded up to a whole minute).
    case localRuns
}

/// One running total of what this Mac saved the workspace.
struct CoreSaving: Equatable, Sendable {
    let kind: CoreSavingKind
    let minutes: Int
    /// Runs, for `.localRuns`.
    let count: Int
    /// When the first one was counted.
    let since: Date?
}

/// What a change shows of its pull request.
struct CoreChangePullRequest: Equatable, Sendable {
    let number: Int64
    let title: String
    /// "open", "closed" or "merged"; empty when the Core has not read it yet.
    let state: String
    let draft: Bool
    let author: String
    let htmlURL: URL?
    let headBranch: String
    let baseBranch: String
    let mergedAt: Date?
}

enum CoreRunChangeSectionKind: Equatable, Sendable { case afterMerge, latestCommit, commit }

/// A change's runs on one commit.
struct CoreRunChangeSection: Equatable, Sendable {
    let kind: CoreRunChangeSectionKind
    let headSHA: String
    let branch: String
    let commitTitle: String
    /// The newest run of each workflow and event, newest first.
    let runIDs: [Int64]
    /// The other runs of those workflows and events on this commit.
    let repeatRunIDs: [Int64]
}

/// A pull request with every run linked to it, or a commit with the runs
/// that have no link.
struct CoreRunChange: Equatable, Identifiable, Sendable {
    /// "pr:142" or "commit:<sha>".
    let id: String
    let pullRequest: CoreChangePullRequest?
    let status: CorePullRequestCI
    let latestAt: Date?
    let sections: [CoreRunChangeSection]
    let olderRunIDs: [Int64]
    let olderCommits: Int
}

/// A concurrency block would have stopped superseded runs of a workflow.
struct CoreConcurrencyHint: Equatable, Sendable {
    let workflowID: Int64
    let path: String
    let runs: Int
    let overlapMinutes: Int
    let runIDs: [Int64]
    let pullRequests: [Int64]
}

/// What a request for older runs did.
/// What a search over the runs saved on this Mac found: the matching runs of
/// the activity cache, by id (the app holds them already), and the matches
/// only the search index knows.
struct CoreRunSearch: Equatable, Sendable {
    var cachedRunIDs: [Int64] = []
    var indexedRuns: [CoreWorkflowRun] = []
    var cachedSearched = 0
    var indexedSearched = 0
    /// Parts of the query that could not be used.
    var problems: [String] = []
}

/// What the global search found in the saved data of one workspace.
struct CoreWorkspaceHits: Equatable, Identifiable, Sendable {
    let workspaceID: UUID
    var id: UUID { workspaceID }
    /// The workspace is open in the Core; otherwise its data was read from
    /// disk as the last session left it.
    var isOpen = false
    /// "owner/name" of the saved data; empty when nothing was saved.
    var repository = ""
    /// When the saved data was last read from GitHub.
    var savedAt: Date?
    /// Why the workspace could not be searched; nil when it was.
    var problem: String?
    var runs: [CoreWorkflowRun] = []
    var runsMatched = 0
    var pullRequests: [CoreSearchedPullRequest] = []
    var pullRequestsMatched = 0
    var workflows: [CoreGitHubWorkflow] = []
    var workflowsMatched = 0
    var localRuns: [CoreSearchedLocalRun] = []
    var localRunsMatched = 0

    var isEmpty: Bool { runsMatched + pullRequestsMatched + workflowsMatched + localRunsMatched == 0 }
}

/// A pull request as the activity cache saved it.
struct CoreSearchedPullRequest: Equatable, Identifiable, Sendable {
    let number: Int64
    var id: Int64 { number }
    let title: String
    /// "open", "closed" or "merged".
    let state: String
    let isDraft: Bool
    let author: String
    let headRef: String
    let htmlURL: URL?
    let updatedAt: Date?
}

/// A local run as a workspace's history keeps it.
struct CoreSearchedLocalRun: Equatable, Identifiable, Sendable {
    let executionID: String
    var id: String { executionID }
    let workflowPath: String
    let jobID: String
    /// "queued", "running", "succeeded", "failed", "cancelled" or "interrupted".
    let state: String
    let message: String
    let startedAt: Date?
}

struct CoreWorkspaceSearch: Equatable, Sendable {
    var workspaces: [CoreWorkspaceHits] = []
    /// Parts of the query that could not be used.
    var problems: [String] = []
    /// The query's words without its qualifiers, as the Core read them: what
    /// a result is marked by.
    var words: [String] = []
}

/// Why a step of a deep search on GitHub ended.
enum CoreSearchStop: Equatable, Sendable {
    /// GitHub has no older run for the query.
    case done
    /// The pages of this step are read; going on starts from the cursor.
    case budget
    case rateLimited
    case unavailable
    /// Another deep search of this repository is running.
    case busy
}

/// One step of a deep search on GitHub.
struct CoreGitHubRunSearch: Equatable, Sendable {
    let access: CoreGitHubAccess
    var runs: [CoreWorkflowRun] = []
    /// Where the next step starts; nil when the search is done.
    var nextCursor: Date?
    /// The creation time of the oldest run read so far.
    var lookedBackTo: Date?
    var pages = 0
    var runsRead = 0
    var stop: CoreSearchStop = .unavailable
    var problems: [String] = []

    static func failed(_ access: CoreGitHubAccess) -> CoreGitHubRunSearch {
        CoreGitHubRunSearch(access: access)
    }
}

struct CoreOlderRuns: Equatable, Sendable {
    let access: CoreGitHubAccess
    let added: Int
    let historyComplete: Bool
    let budgetReached: Bool
}

/// Why the Core did not add the concurrency block.
enum CoreConcurrencyRefusal: Equatable, Sendable {
    case alreadyPresent, noJobs, notBlockMapping, parseError, tooLarge

    var message: String {
        switch self {
        case .alreadyPresent: "This workflow already has a concurrency setting, so nothing was added."
        case .noJobs: "This workflow has no jobs key, so there is nowhere to add the block."
        case .notBlockMapping: "Runnir adds the block only to a workflow written as a plain YAML mapping. Add it by hand."
        case .parseError: "This workflow can't be read as YAML. Fix it first, then try again."
        case .tooLarge: "This workflow file is larger than 1 MiB."
        }
    }
}

enum CoreConcurrencyInsertion: Equatable, Sendable {
    case inserted(content: String, firstLine: Int, lastLine: Int)
    case refused(CoreConcurrencyRefusal)
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
    /// Runs in the search index.
    var indexedRuns = 0
    var id: UUID { workspaceID }
}

struct CoreStorageUsage: Equatable, Sendable {
    let workspaces: [CoreWorkspaceStorage]
    let keepJobLogs: Bool
}
