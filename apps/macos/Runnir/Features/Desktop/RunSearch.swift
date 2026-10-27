import Foundation

/// Searching the runs saved on this Mac. A query is words separated by
/// spaces; a run matches when every word matches somewhere in it, in any
/// case: its title, workflow, commit message, branch, author, event, outcome
/// or pull request, and the start of its commit (four characters or more).
/// `#142` also finds the run or the pull request with that number.
enum RunSearch {
    /// The words of a query, lowercased; empty for a blank query.
    static func terms(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func isActive(_ query: String) -> Bool { !terms(query).isEmpty }

    static func filter(_ runs: [CoreWorkflowRun], query: String) -> [CoreWorkflowRun] {
        let terms = terms(query)
        guard !terms.isEmpty else { return runs }
        return runs.filter { matches($0, terms: terms) }
    }

    static func matches(_ run: CoreWorkflowRun, terms: [String]) -> Bool {
        terms.allSatisfy { matches(run, term: $0) }
    }

    /// A change matches when each word matches its pull request or commits,
    /// or one of its runs; different words may match different runs.
    static func matches(_ change: CoreRunChange, runs: [Int64: CoreWorkflowRun], terms: [String]) -> Bool {
        let members = (change.sections.flatMap { $0.runIDs + $0.repeatRunIDs } + change.olderRunIDs).compactMap { runs[$0] }
        var text: [String] = []
        if let pull = change.pullRequest {
            text += ["#\(pull.number)", pull.title, pull.author, pull.headBranch, pull.baseBranch, pull.state]
        }
        for section in change.sections { text += [section.commitTitle, section.branch] }
        let lowered = text.map { $0.lowercased() }
        return terms.allSatisfy { term in
            lowered.contains { $0.contains(term) }
                || change.sections.contains { startsLikeACommit($0.headSHA, term) }
                || members.contains { matches($0, term: term) }
        }
    }

    /// "Showing 3 of 812 saved runs", and where the rest is when the saved
    /// runs are not the whole history.
    static func summary(matches: Int, saved: Int, historyComplete: Bool) -> String {
        let base = "Showing \(matches) of \(saved) saved \(saved == 1 ? "run" : "runs")"
        return historyComplete ? base : base + ". Older runs are on GitHub."
    }

    private static func matches(_ run: CoreWorkflowRun, term: String) -> Bool {
        var text = [run.title, run.name, run.commitTitle, run.branch, run.actor ?? "", run.event, run.outcome.label]
        // The pull request, not the short commit, which is matched from its start only.
        if run.link.pullRequest != nil { text.append(RunPresentation.linkText(run)) }
        if text.contains(where: { $0.lowercased().contains(term) }) { return true }
        if startsLikeACommit(run.headSHA, term) { return true }
        if term.hasPrefix("#"), let number = Int64(term.dropFirst()) {
            return run.runNumber == number || run.link.pullRequest == number
        }
        if let number = Int64(term) { return run.runNumber == number }
        return false
    }

    private static func startsLikeACommit(_ sha: String, _ term: String) -> Bool {
        term.count >= 4 && term.allSatisfy(\.isHexDigit) && sha.lowercased().hasPrefix(term)
    }
}

extension RunPresentation {
    /// The runs the list shows: those on `branch` (all for nil) that match
    /// `query`. Without a query, completed superseded runs stay hidden unless
    /// asked for; a search shows every match, because hiding one would make a
    /// run that exists look missing.
    static func list(_ runs: [CoreWorkflowRun], branch: String?, query: String, statuses: Set<RunStatusFilter> = [],
                     showingSuperseded: Bool) -> [CoreWorkflowRun] {
        let onBranch = branch.map { branch in runs.filter { $0.branch == branch } } ?? runs
        guard RunSearch.isActive(query) || !statuses.isEmpty else { return visible(onBranch, showingSuperseded: showingSuperseded) }
        return RunStatusFilter.filter(RunSearch.filter(onBranch, query: query), statuses: statuses)
    }

    /// The runs on `branch` (all for nil) that match `query`, whatever their
    /// status: what the status menu counts.
    static func matching(_ runs: [CoreWorkflowRun], branch: String?, query: String) -> [CoreWorkflowRun] {
        let onBranch = branch.map { branch in runs.filter { $0.branch == branch } } ?? runs
        return RunSearch.filter(onBranch, query: query)
    }

    /// The changes with a run on `branch` (all for nil) that match `query`
    /// and have a run with one of `statuses`.
    static func changes(_ changes: [CoreRunChange], runs: [Int64: CoreWorkflowRun], branch: String?, query: String,
                        statuses: Set<RunStatusFilter> = []) -> [CoreRunChange] {
        let onBranch = Self.changes(changes, runs: runs, branch: branch)
        let terms = RunSearch.terms(query)
        let matched = terms.isEmpty ? onBranch : onBranch.filter { RunSearch.matches($0, runs: runs, terms: terms) }
        guard !statuses.isEmpty else { return matched }
        return matched.filter { change in
            (change.sections.flatMap { $0.runIDs + $0.repeatRunIDs } + change.olderRunIDs)
                .compactMap { runs[$0] }.contains { statuses.contains(RunStatusFilter.of($0)) }
        }
    }
}
