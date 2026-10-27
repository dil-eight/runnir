import Foundation
import Testing
@testable import Runnir

/// What the list does with the Core's answers to a search. The grammar and
/// the matching are tested in the Core (`runsearch`).
@MainActor
@Suite struct RunSearchTests {
    private func run(_ id: Int64, title: String = "Fix build", branch: String = "main", supersededBy: Int64? = nil,
                     conclusion: String? = "success") -> CoreWorkflowRun {
        CoreWorkflowRun(id: id, workflowID: 3, name: "CI", displayTitle: title, runNumber: id, event: "push", status: "completed",
                        conclusion: conclusion, branch: branch, headSHA: "a3f9c21ffee0", actor: "eugene", htmlURL: nil, createdAt: nil,
                        updatedAt: nil, commitTitle: "", link: .none, supersededBy: supersededBy)
    }

    @Test func aBlankQueryIsNoSearchButALoneQualifierIs() {
        #expect(!RunSearch.isActive("   \n"))
        #expect(RunSearch.isActive("deploy"))
        #expect(RunSearch.isActive("status:failed"))
    }

    @Test func theListKeepsOnlyTheRunsTheCoreFound() {
        let runs = [run(3), run(2), run(1)]
        #expect(RunPresentation.list(runs, branch: nil, matching: [3, 1], showingSuperseded: false).map(\.id) == [3, 1])
        #expect(RunPresentation.list(runs, branch: nil, matching: [], showingSuperseded: false).isEmpty, "found nothing")
    }

    @Test func theListCombinesSearchWithTheBranchAndShowsSupersededMatches() {
        let runs = [run(3, title: "Build app"), run(2, title: "Build app", supersededBy: 3), run(1, title: "Build app", branch: "retry")]
        // No search: what the list showed before, completed superseded runs hidden.
        #expect(RunPresentation.list(runs, branch: nil, showingSuperseded: false).map(\.id) == [3, 1])
        // A search finds a superseded run too: hiding it would make a match look missing.
        #expect(RunPresentation.list(runs, branch: nil, matching: [1, 2, 3], showingSuperseded: false).map(\.id) == [3, 2, 1])
        // The branch filter still applies.
        #expect(RunPresentation.list(runs, branch: "main", matching: [1, 2, 3], showingSuperseded: false).map(\.id) == [3, 2])
        #expect(RunPresentation.list(runs, branch: "retry", matching: [], showingSuperseded: true).isEmpty)
    }

    @Test func aChangeMatchesWhenOneOfItsRunsWasFound() {
        let pull = CoreChangePullRequest(number: 142, title: "Add retry to deploy", state: "merged", draft: false, author: "octocat",
                                         htmlURL: nil, headBranch: "retry", baseBranch: "main", mergedAt: nil)
        let section = CoreRunChangeSection(kind: .latestCommit, headSHA: "9f8e7d6c", branch: "retry", commitTitle: "Bump retry count",
                                           runIDs: [3], repeatRunIDs: [])
        let withPull = CoreRunChange(id: "pr:142", pullRequest: pull, status: .passed, latestAt: nil, sections: [section], olderRunIDs: [2], olderCommits: 1)
        let commitSection = CoreRunChangeSection(kind: .commit, headSHA: "3c4d5e6f", branch: "main", commitTitle: "Bump Go",
                                                 runIDs: [9], repeatRunIDs: [])
        let commit = CoreRunChange(id: "commit:3c4d5e6f", pullRequest: nil, status: .failed, latestAt: nil, sections: [commitSection],
                                   olderRunIDs: [], olderCommits: 0)
        let runs: [Int64: CoreWorkflowRun] = [3: run(3, branch: "retry"), 2: run(2, branch: "retry"), 9: run(9)]
        func ids(_ found: Set<Int64>?, branch: String? = nil, statuses: Set<RunStatusFilter> = []) -> [String] {
            RunPresentation.changes([withPull, commit], runs: runs, branch: branch, matching: found, statuses: statuses).map(\.id)
        }
        #expect(ids(nil) == ["pr:142", "commit:3c4d5e6f"])
        #expect(ids([3]) == ["pr:142"], "a run of the change")
        #expect(ids([2]) == ["pr:142"], "an older run of it too")
        #expect(ids([9]) == ["commit:3c4d5e6f"])
        #expect(ids([2, 9], branch: "main") == ["commit:3c4d5e6f"], "the branch filter still applies")
        #expect(ids([]).isEmpty)
    }

    @Test func theSummarySaysWhatWasSearched() {
        #expect(RunSearch.summary(matches: 3, saved: 812, historyComplete: true) == "Showing 3 of 812 saved runs")
        #expect(RunSearch.summary(matches: 3, saved: 5000, historyComplete: false) == "Showing 3 of 5000 saved runs. Older runs are on GitHub.")
        #expect(RunSearch.summary(matches: 1, saved: 1, historyComplete: true) == "Showing 1 of 1 saved run")
        #expect(RunSearch.summary(matches: 3, saved: 812, indexed: 12_340, historyComplete: true)
                == "Showing 3 of 812 saved runs · \(12_340.formatted()) in the search index")
    }
}
