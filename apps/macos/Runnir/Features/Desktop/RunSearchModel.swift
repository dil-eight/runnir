import Foundation

/// The search of the runs list over what this Mac knows and, on request,
/// over GitHub. The Core owns the grammar and the matching: this holds the
/// answers for the typed query, the steps of a deep search and what they
/// found, so the list can show them.
@MainActor
@Observable
final class RunSearchModel {
    enum Deep: Equatable {
        case idle
        case running
        /// A step ended with its pages read; going on starts from the cursor.
        case more
        case done
        case rateLimited(Date?)
        case failed(CoreGitHubAccess)
        case busy
    }

    let workspaceID: UUID
    @ObservationIgnored private let hub: CoreHub
    /// How long typing pauses before the saved runs are searched.
    @ObservationIgnored var debounce: Duration = .milliseconds(200)

    /// The query the answers below are for.
    private(set) var query = ""
    private(set) var saved: CoreRunSearch?
    private(set) var isSearching = false
    private(set) var deep: Deep = .idle
    /// Matches read from GitHub, newest first, without repeats.
    private(set) var githubRuns: [CoreWorkflowRun] = []
    private(set) var lookedBackTo: Date?
    private(set) var runsRead = 0
    private(set) var pagesRead = 0
    @ObservationIgnored private var cursor: Date?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var deepTask: Task<Void, Never>?

    init(hub: CoreHub, workspaceID: UUID) {
        self.hub = hub
        self.workspaceID = workspaceID
    }

    /// The ids of the saved runs that match the query; nil without a search.
    var matchingIDs: Set<Int64>? { query.isEmpty ? nil : Set(saved?.cachedRunIDs ?? []) }
    var indexedRuns: [CoreWorkflowRun] { saved?.indexedRuns ?? [] }
    var problems: [String] { saved?.problems ?? [] }

    /// The GitHub matches that are neither in the saved runs nor in the index.
    func foundOnGitHub(excluding known: Set<Int64>) -> [CoreWorkflowRun] {
        let indexed = Set(indexedRuns.map(\.id))
        return githubRuns.filter { !known.contains($0.id) && !indexed.contains($0.id) }
    }

    /// A run the search found that the activity cache does not hold.
    func run(id: Int64) -> CoreWorkflowRun? {
        indexedRuns.first { $0.id == id } ?? githubRuns.first { $0.id == id }
    }

    /// The typed text changed: search again after a pause. A blank text ends
    /// the search; another query ends a deep search of the old one.
    func update(query text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query || (saved == nil && !trimmed.isEmpty && !isSearching) else { return }
        searchTask?.cancel()
        guard !trimmed.isEmpty else {
            reset()
            return
        }
        searchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            isSearching = true
            let result = await hub.searchRuns(workspaceID: workspaceID, query: trimmed)
            guard !Task.isCancelled else { return }
            isSearching = false
            if trimmed != query { resetDeep() }
            query = trimmed
            saved = result ?? CoreRunSearch()
        }
    }

    /// The saved runs changed (a sync): the answer is read again.
    func refresh() {
        guard !query.isEmpty else { return }
        let current = query
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            let result = await hub.searchRuns(workspaceID: workspaceID, query: current)
            guard !Task.isCancelled, current == query else { return }
            saved = result ?? saved
        }
    }

    // MARK: Deep search

    var canSearchGitHub: Bool { !query.isEmpty && deep != .running }

    /// Starts a deep search from the newest runs.
    func searchGitHub() {
        guard canSearchGitHub else { return }
        githubRuns = []
        lookedBackTo = nil
        runsRead = 0
        pagesRead = 0
        cursor = nil
        step()
    }

    /// Reads on from where the last step ended.
    func searchDeeper() {
        guard deep == .more || deep == .busy else { return }
        step()
    }

    func cancelDeep() {
        deepTask?.cancel()
        deepTask = nil
        if deep == .running { deep = githubRuns.isEmpty && runsRead == 0 ? .idle : .more }
    }

    private func step() {
        let asked = query
        deep = .running
        deepTask = Task { [weak self] in
            guard let self else { return }
            let result = await hub.searchRunsOnGitHub(workspaceID: workspaceID, query: asked, cursor: cursor)
            guard !Task.isCancelled, asked == query else { return }
            merge(result)
        }
    }

    private func merge(_ result: CoreGitHubRunSearch) {
        var known = Set(githubRuns.map(\.id))
        for run in result.runs where known.insert(run.id).inserted { githubRuns.append(run) }
        githubRuns.sort { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        runsRead += result.runsRead
        pagesRead += result.pages
        if let back = result.lookedBackTo { lookedBackTo = back }
        guard result.access == .ok else {
            if case .rateLimited(let until) = result.access { deep = .rateLimited(until) } else { deep = .failed(result.access) }
            return
        }
        switch result.stop {
        case .done: deep = .done
        case .budget:
            cursor = result.nextCursor
            deep = .more
        case .rateLimited: deep = .rateLimited(nil)
        case .busy: deep = .busy
        case .unavailable: deep = .failed(.unavailable)
        }
        if result.stop == .done || result.stop == .budget, !result.runs.isEmpty { refresh() }
    }

    private func resetDeep() {
        deepTask?.cancel()
        deepTask = nil
        deep = .idle
        githubRuns = []
        lookedBackTo = nil
        runsRead = 0
        pagesRead = 0
        cursor = nil
    }

    private func reset() {
        resetDeep()
        query = ""
        saved = nil
        isSearching = false
    }
}
