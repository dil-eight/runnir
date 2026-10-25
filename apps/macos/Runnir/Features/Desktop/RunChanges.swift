import Foundation

/// What the Runs section knows around a run: its pull request, the run that
/// superseded it, and a concurrency suggestion for its workflow.
struct RunInspectorContext: Equatable {
    var pullRequest: CoreChangePullRequest?
    var supersededBy: CoreWorkflowRun?
    var hint: CoreConcurrencyHint?
    var workflowName = ""
}

/// How runs and changes read in the Runs section, the inspector and the
/// Overview. The Core decides links, superseded runs and changes; this only
/// words them.
enum RunPresentation {
    static func shortSHA(_ sha: String) -> String { String(sha.prefix(7)) }

    /// "#142", "#142 after merge", or the short commit without a pull request.
    static func linkText(_ run: CoreWorkflowRun) -> String {
        switch run.link {
        case .pullRequest(let number): "#\(number)"
        case .afterMerge(let number): "#\(number) after merge"
        case .none: shortSHA(run.headSHA)
        }
    }

    /// A row's second line: workflow and number, then the pull request when
    /// there is one (a 300-point list cuts the end of the line), branch and
    /// event; a run without a pull request ends with its short commit.
    static func detail(_ run: CoreWorkflowRun) -> String {
        let head = "\(run.name) #\(run.runNumber)"
        let parts = run.link.pullRequest == nil
            ? [head, run.branch, run.event, linkText(run)]
            : [head, linkText(run), run.branch, run.event]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The Overview's latest run: "run #881 · a1b2c3d · #142 after merge".
    static func summary(_ run: CoreWorkflowRun) -> String {
        var parts = ["run #\(run.runNumber)", shortSHA(run.headSHA)]
        if run.link.pullRequest != nil { parts.append(linkText(run)) }
        return parts.joined(separator: " · ")
    }

    /// The runs a list shows: completed superseded runs only when asked for.
    /// An outdated run (superseded, still going) always shows.
    static func visible(_ runs: [CoreWorkflowRun], showingSuperseded: Bool) -> [CoreWorkflowRun] {
        showingSuperseded ? runs : runs.filter { !$0.isSuperseded || $0.outcome.isActive }
    }

    static func hiddenCount(_ runs: [CoreWorkflowRun]) -> Int {
        runs.count { $0.isSuperseded && !$0.outcome.isActive }
    }

    /// The pull requests the changes describe, by number.
    static func pullRequests(_ changes: [CoreRunChange]) -> [Int64: CoreChangePullRequest] {
        Dictionary(changes.compactMap { change in change.pullRequest.map { ($0.number, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// Changes with a run on `branch`; all of them for nil.
    static func changes(_ changes: [CoreRunChange], runs: [Int64: CoreWorkflowRun], branch: String?) -> [CoreRunChange] {
        guard let branch else { return changes }
        return changes.filter { change in
            (change.sections.flatMap { $0.runIDs + $0.repeatRunIDs } + change.olderRunIDs).contains { runs[$0]?.branch == branch }
        }
    }

    /// "#142 Add retry to deploy", or "3c4d5e6 Bump Go" for a commit.
    static func changeTitle(_ change: CoreRunChange) -> String {
        if let pullRequest = change.pullRequest {
            return pullRequest.title.isEmpty ? "#\(pullRequest.number)" : "#\(pullRequest.number) \(pullRequest.title)"
        }
        guard let section = change.sections.first else { return change.id }
        return [shortSHA(section.headSHA), section.commitTitle].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Under a change's title: a pull request's branches ("retry → main"),
    /// a commit's branch; nil when the Core knows neither.
    static func changeSubtitle(_ change: CoreRunChange) -> String? {
        if let pullRequest = change.pullRequest {
            switch (pullRequest.headBranch.isEmpty, pullRequest.baseBranch.isEmpty) {
            case (false, false): return "\(pullRequest.headBranch) → \(pullRequest.baseBranch)"
            case (false, true): return pullRequest.headBranch
            default: break
            }
        }
        return change.sections.first { !$0.branch.isEmpty }?.branch
    }

    /// "After merge · main · a1b2c3d", "On the PR · 9f8e7d6 (latest)"; nil
    /// for a commit, whose header already says it.
    static func sectionTitle(_ section: CoreRunChangeSection) -> String? {
        switch section.kind {
        case .afterMerge: "After merge · \(section.branch) · \(shortSHA(section.headSHA))"
        case .latestCommit: "On the PR · \(shortSHA(section.headSHA)) (latest)"
        case .commit: nil
        }
    }

    /// "2 earlier runs on 2 older commits"; nil without any.
    static func olderText(_ change: CoreRunChange) -> String? {
        guard !change.olderRunIDs.isEmpty else { return nil }
        let runs = change.olderRunIDs.count == 1 ? "1 earlier run" : "\(change.olderRunIDs.count) earlier runs"
        let commits = change.olderCommits == 1 ? "1 older commit" : "\(change.olderCommits) older commits"
        return "\(runs) on \(commits)"
    }

    /// "2 earlier runs on this commit"; nil without any.
    static func repeatsText(_ section: CoreRunChangeSection) -> String? {
        switch section.repeatRunIDs.count {
        case 0: nil
        case 1: "1 earlier run on this commit"
        case let n: "\(n) earlier runs on this commit"
        }
    }

    /// "open", "draft", "merged" or "closed"; nil when the Core has not read it.
    static func stateLabel(_ pullRequest: CoreChangePullRequest) -> String? {
        if pullRequest.state == "open" && pullRequest.draft { return "draft" }
        return pullRequest.state.isEmpty ? nil : pullRequest.state
    }

    /// "Pull request #142 Add retry to deploy · merged".
    static func pullRequestLine(_ pullRequest: CoreChangePullRequest) -> String {
        var line = "Pull request #\(pullRequest.number)"
        if !pullRequest.title.isEmpty { line += " \(pullRequest.title)" }
        if let state = stateLabel(pullRequest) { line += " · \(state)" }
        return line
    }

    /// "Commit a1b2c3d Bump retry count".
    static func commitLine(_ run: CoreWorkflowRun) -> String {
        ["Commit", shortSHA(run.headSHA), run.commitTitle].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A row's help: the pull request's title and the commit.
    static func rowHelp(_ run: CoreWorkflowRun, pullRequest: CoreChangePullRequest?) -> String {
        var lines: [String] = []
        if let pullRequest {
            lines.append(pullRequest.title.isEmpty ? "Pull request #\(pullRequest.number)" : "Pull request #\(pullRequest.number) \(pullRequest.title)")
        }
        lines.append(commitLine(run))
        return lines.joined(separator: "\n")
    }

    /// The "outdated" label's help.
    static func outdatedHelp(_ run: CoreWorkflowRun, newer: CoreWorkflowRun?) -> String {
        let pull = run.link.pullRequest.map { " of #\($0)" } ?? ""
        let started = newer.map { " started \($0.name) #\($0.runNumber)" } ?? " started a newer run"
        return "A newer commit\(pull)\(started). Cancel this run to save runner time."
    }

    /// "3 runs of CI on older commits kept running after a newer push (about 18 min)."
    static func hintText(_ hint: CoreConcurrencyHint, workflowName: String) -> String {
        let runs = hint.runs == 1 ? "1 run" : "\(hint.runs) runs"
        return "\(runs) of \(workflowName) on older commits kept running after a newer push (about \(hint.overlapMinutes) min)."
    }

    /// The repository's Actions page, from a run's address.
    static func actionsURL(_ runs: [CoreWorkflowRun]) -> URL? {
        guard let address = runs.last?.htmlURL?.absoluteString, let range = address.range(of: "/actions/runs/") else { return nil }
        return URL(string: String(address[..<range.lowerBound]) + "/actions")
    }

    static func context(for run: CoreWorkflowRun, runs: [Int64: CoreWorkflowRun], pullRequests: [Int64: CoreChangePullRequest],
                        hints: [CoreConcurrencyHint], workflowName: String) -> RunInspectorContext {
        RunInspectorContext(pullRequest: run.link.pullRequest.flatMap { pullRequests[$0] },
                            supersededBy: run.supersededBy.flatMap { runs[$0] },
                            hint: hints.first { $0.workflowID == run.workflowID }, workflowName: workflowName)
    }
}
