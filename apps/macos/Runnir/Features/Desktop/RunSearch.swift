import Foundation

/// What the runs list says about a search. The Core reads the query and
/// matches the runs (`RunSearchModel` holds its answers); this is what the
/// list does with them.
enum RunSearch {
    /// Whether a query narrows the list: any text, even a lone qualifier.
    static func isActive(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// "Showing 3 of 812 saved runs · 12,340 in the search index", and where
    /// the rest is when the saved runs are not the whole history.
    static func summary(matches: Int, saved: Int, indexed: Int = 0, historyComplete: Bool) -> String {
        var base = "Showing \(matches) of \(saved) saved \(saved == 1 ? "run" : "runs")"
        if indexed > 0 { base += " · \(indexed.formatted()) in the search index" }
        return historyComplete ? base : base + ". Older runs are on GitHub."
    }
}

extension RunPresentation {
    /// The runs the list shows: those on `branch` (all for nil), among the ids
    /// the Core found for the query (all for nil) and with one of `statuses`.
    /// Without a query or a status, completed superseded runs stay hidden
    /// unless asked for; a search shows every match, because hiding one would
    /// make a run that exists look missing.
    static func list(_ runs: [CoreWorkflowRun], branch: String?, matching ids: Set<Int64>? = nil, statuses: Set<RunStatusFilter> = [],
                     showingSuperseded: Bool) -> [CoreWorkflowRun] {
        let onBranch = branch.map { branch in runs.filter { $0.branch == branch } } ?? runs
        guard ids != nil || !statuses.isEmpty else { return visible(onBranch, showingSuperseded: showingSuperseded) }
        return RunStatusFilter.filter(onBranch.filter { ids?.contains($0.id) ?? true }, statuses: statuses)
    }

    /// The runs on `branch` (all for nil) among the ids found, whatever their
    /// status: what the status menu counts.
    static func matching(_ runs: [CoreWorkflowRun], branch: String?, ids: Set<Int64>?) -> [CoreWorkflowRun] {
        let onBranch = branch.map { branch in runs.filter { $0.branch == branch } } ?? runs
        return onBranch.filter { ids?.contains($0.id) ?? true }
    }

    /// The changes with a run on `branch` (all for nil) that have a run among
    /// the ids found and a run with one of `statuses`.
    static func changes(_ changes: [CoreRunChange], runs: [Int64: CoreWorkflowRun], branch: String?, matching ids: Set<Int64>? = nil,
                        statuses: Set<RunStatusFilter> = []) -> [CoreRunChange] {
        let onBranch = Self.changes(changes, runs: runs, branch: branch)
        guard ids != nil || !statuses.isEmpty else { return onBranch }
        return onBranch.filter { change in
            let members = (change.sections.flatMap { $0.runIDs + $0.repeatRunIDs } + change.olderRunIDs)
            let found = ids.map { ids in members.contains { ids.contains($0) } } ?? true
            let status = statuses.isEmpty || members.compactMap { runs[$0] }.contains { RunStatusFilter.matches($0, statuses) }
            return found && status
        }
    }
}
