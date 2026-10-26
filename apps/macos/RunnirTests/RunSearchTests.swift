import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite struct RunSearchTests {
    private func run(_ id: Int64, title: String = "Fix build", workflow: String = "CI", event: String = "push", branch: String = "main",
                     sha: String = "a3f9c21ffee0", actor: String? = "eugene", status: String = "completed", conclusion: String? = "success",
                     commit: String = "", link: CoreRunLink = .none, supersededBy: Int64? = nil) -> CoreWorkflowRun {
        CoreWorkflowRun(id: id, workflowID: 3, name: workflow, displayTitle: title, runNumber: id, event: event, status: status,
                        conclusion: conclusion, branch: branch, headSHA: sha, actor: actor, htmlURL: nil, createdAt: nil, updatedAt: nil,
                        commitTitle: commit, link: link, supersededBy: supersededBy)
    }

    private func found(_ query: String, in runs: [CoreWorkflowRun]) -> [Int64] {
        RunSearch.filter(runs, query: query).map(\.id)
    }

    @Test func aBlankQueryIsNoSearch() {
        #expect(RunSearch.terms("   ").isEmpty)
        #expect(!RunSearch.isActive(" \n"))
        #expect(RunSearch.terms("  Fix  BUILD ") == ["fix", "build"])
        let runs = [run(1), run(2)]
        #expect(found("", in: runs) == [1, 2])
    }

    @Test func aTitleFragmentMatchesWhateverTheCase() {
        let runs = [run(1, title: "Fix profile lookup for archive step"), run(2, title: "Bump Fastlane")]
        #expect(found("PROFILE", in: runs) == [1])
        #expect(found("lane", in: runs) == [2])
        #expect(found("nothing like it", in: runs).isEmpty)
    }

    @Test func aCommitMatchesFromItsFirstCharactersOnly() {
        let runs = [run(1, sha: "a3f9c21ffee0"), run(2, sha: "0b1c2d3e4f50")]
        #expect(found("a3f9", in: runs) == [1])
        #expect(found("a3f9c21", in: runs) == [1])
        #expect(found("f9c2", in: runs).isEmpty, "the middle of a commit is not a match")
        #expect(found("a3f", in: runs).isEmpty, "fewer than four characters are not taken for a commit")
    }

    @Test func workflowBranchAuthorEventAndCommitMessageMatch() {
        let runs = [run(1, workflow: "Deploy", event: "workflow_dispatch", branch: "release/1.4", actor: "octocat", commit: "Bump Fastlane to 2.226"),
                    run(2)]
        for query in ["deploy", "dispatch", "release", "octocat", "fastlane"] {
            #expect(found(query, in: runs) == [1], "\(query)")
        }
    }

    @Test func theOutcomeAndTheRunNumberMatch() {
        let runs = [run(1, status: "completed", conclusion: "failure"), run(2, status: "in_progress", conclusion: nil), run(1482)]
        #expect(found("failed", in: runs) == [1])
        #expect(found("#1482", in: runs) == [1482])
        #expect(found("1482", in: runs) == [1482])
    }

    @Test func aHashNumberAlsoFindsThePullRequestItBelongsTo() {
        let runs = [run(5, link: .pullRequest(142)), run(6, link: .afterMerge(142)), run(142), run(7)]
        #expect(found("#142", in: runs) == [5, 6, 142])
    }

    @Test func everyTermMustMatchButEachMayMatchAnotherField() {
        let runs = [run(1, title: "Fix build", actor: "octocat"), run(2, title: "Fix build", actor: "eugene"), run(3, title: "Other", actor: "octocat")]
        #expect(found("fix octocat", in: runs) == [1])
        #expect(found("octocat fix", in: runs) == [1])
        #expect(found("fix nobody", in: runs).isEmpty)
    }

    @Test func theListCombinesSearchWithTheBranchAndShowsSupersededMatches() {
        let runs = [run(3, title: "Build app"), run(2, title: "Build app", supersededBy: 3), run(1, title: "Build app", branch: "retry")]
        // No query: what the list showed before, completed superseded runs hidden.
        #expect(RunPresentation.list(runs, branch: nil, query: "", showingSuperseded: false).map(\.id) == [3, 1])
        // A search finds a superseded run too: hiding it would make a match look missing.
        #expect(RunPresentation.list(runs, branch: nil, query: "build", showingSuperseded: false).map(\.id) == [3, 2, 1])
        // The branch filter still applies.
        #expect(RunPresentation.list(runs, branch: "main", query: "build", showingSuperseded: false).map(\.id) == [3, 2])
        #expect(RunPresentation.list(runs, branch: "retry", query: "nothing", showingSuperseded: true).isEmpty)
    }

    @Test func aChangeMatchesByItsPullRequestOrOneOfItsRuns() {
        let pull = CoreChangePullRequest(number: 142, title: "Add retry to deploy", state: "merged", draft: false, author: "octocat",
                                         htmlURL: nil, headBranch: "retry", baseBranch: "main", mergedAt: nil)
        let section = CoreRunChangeSection(kind: .latestCommit, headSHA: "9f8e7d6c", branch: "retry", commitTitle: "Bump retry count",
                                           runIDs: [3], repeatRunIDs: [])
        let withPull = CoreRunChange(id: "pr:142", pullRequest: pull, status: .passed, latestAt: nil, sections: [section], olderRunIDs: [2], olderCommits: 1)
        let commitSection = CoreRunChangeSection(kind: .commit, headSHA: "3c4d5e6f", branch: "main", commitTitle: "Bump Go",
                                                 runIDs: [9], repeatRunIDs: [])
        let commit = CoreRunChange(id: "commit:3c4d5e6f", pullRequest: nil, status: .failed, latestAt: nil, sections: [commitSection],
                                   olderRunIDs: [], olderCommits: 0)
        let runs: [Int64: CoreWorkflowRun] = [3: run(3, branch: "retry"), 2: run(2, title: "Older nightly", branch: "retry"), 9: run(9, title: "Nightly e2e", actor: "robot")]
        func ids(_ query: String, branch: String? = nil) -> [String] {
            RunPresentation.changes([withPull, commit], runs: runs, branch: branch, query: query).map(\.id)
        }
        #expect(ids("") == ["pr:142", "commit:3c4d5e6f"])
        #expect(ids("add retry") == ["pr:142"], "the pull request's title")
        #expect(ids("octocat") == ["pr:142"], "the pull request's author")
        #expect(ids("nightly") == ["pr:142", "commit:3c4d5e6f"], "a run of the change, an older one too")
        #expect(ids("robot") == ["commit:3c4d5e6f"])
        #expect(ids("bump go") == ["commit:3c4d5e6f"], "the commit's message")
        #expect(ids("nightly", branch: "main") == ["commit:3c4d5e6f"], "the branch filter still applies")
        #expect(ids("zzz").isEmpty)
    }

    @Test func theSummarySaysWhatWasSearched() {
        #expect(RunSearch.summary(matches: 3, saved: 812, historyComplete: true) == "Showing 3 of 812 saved runs")
        #expect(RunSearch.summary(matches: 3, saved: 5000, historyComplete: false) == "Showing 3 of 5000 saved runs. Older runs are on GitHub.")
        #expect(RunSearch.summary(matches: 1, saved: 1, historyComplete: true) == "Showing 1 of 1 saved run")
    }
}
