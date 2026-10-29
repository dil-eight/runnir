import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite struct RunChangesTests {
    private func run(_ id: Int64, sha: String = "a1b2c3d4", link: CoreRunLink = .none, supersededBy: Int64? = nil,
                     status: String = "completed", branch: String = "main") -> CoreWorkflowRun {
        CoreWorkflowRun(id: id, workflowID: 3, name: "CI", displayTitle: "Add retry", runNumber: id, event: "push", status: status,
                        conclusion: status == "completed" ? "success" : nil, branch: branch, headSHA: sha, actor: nil,
                        htmlURL: URL(string: "https://github.com/o/r/actions/runs/\(id)"), createdAt: nil, updatedAt: nil,
                        commitTitle: "Bump retry count", link: link, supersededBy: supersededBy)
    }

    private let pull = CoreChangePullRequest(number: 142, title: "Add retry to deploy", state: "merged", draft: false, author: "octocat",
                                             htmlURL: URL(string: "https://github.com/o/r/pull/142"), headBranch: "retry", baseBranch: "main",
                                             mergedAt: nil)

    @Test func runsSayWhatTheyBelongTo() {
        #expect(RunPresentation.linkText(run(1, link: .pullRequest(142))) == "#142")
        #expect(RunPresentation.linkText(run(1, link: .afterMerge(142))) == "#142 after merge")
        #expect(RunPresentation.linkText(run(1)) == "a1b2c3d")
        #expect(RunPresentation.detail(run(881, link: .afterMerge(142))) == "CI #881 · #142 after merge · main · push")
        #expect(RunPresentation.detail(run(878)) == "CI #878 · main · push · a1b2c3d")
        #expect(RunPresentation.summary(run(881, link: .afterMerge(142))) == "run #881 · a1b2c3d · #142 after merge")
        #expect(RunPresentation.summary(run(881)) == "run #881 · a1b2c3d")
        #expect(RunPresentation.pullRequestLine(pull) == "Pull request #142 Add retry to deploy · merged")
        #expect(RunPresentation.commitLine(run(1)) == "Commit a1b2c3d Bump retry count")
        #expect(RunPresentation.rowHelp(run(1, link: .pullRequest(142)), pullRequest: pull) == "Pull request #142 Add retry to deploy\nCommit a1b2c3d Bump retry count")
    }

    @Test func completedSupersededRunsAreHiddenUntilAskedFor() {
        let runs = [run(3), run(2, supersededBy: 3), run(1, supersededBy: 3, status: "in_progress")]
        #expect(RunPresentation.visible(runs, showingSuperseded: false).map(\.id) == [3, 1], "an outdated run stays")
        #expect(RunPresentation.visible(runs, showingSuperseded: true).map(\.id) == [3, 2, 1])
        #expect(RunPresentation.hiddenCount(runs) == 1)
        #expect(runs[2].isOutdated && !runs[1].isOutdated)
    }

    @Test func changesReadAsTheSpecSays() {
        let merged = CoreRunChangeSection(kind: .afterMerge, headSHA: "a1b2c3d4", branch: "main", commitTitle: "", runIDs: [5, 4], repeatRunIDs: [])
        let latest = CoreRunChangeSection(kind: .latestCommit, headSHA: "9f8e7d6c", branch: "retry", commitTitle: "", runIDs: [3], repeatRunIDs: [7, 8])
        let change = CoreRunChange(id: "pr:142", pullRequest: pull, status: .passed, latestAt: nil, sections: [merged, latest],
                                   olderRunIDs: [2, 1], olderCommits: 2)
        #expect(RunPresentation.changeTitle(change) == "#142 Add retry to deploy")
        #expect(RunPresentation.sectionTitle(merged) == "After merge · main · a1b2c3d")
        #expect(RunPresentation.sectionTitle(latest) == "On the PR · 9f8e7d6 (latest)")
        #expect(RunPresentation.olderText(change) == "2 earlier runs on 2 older commits")
        #expect(RunPresentation.repeatsText(latest) == "2 earlier runs on this commit")
        #expect(RunPresentation.repeatsText(merged) == nil)
        #expect(RunPresentation.stateLabel(pull) == "merged")
        let commit = CoreRunChange(id: "commit:3c4d5e6f", pullRequest: nil, status: .failed, latestAt: nil,
                                   sections: [CoreRunChangeSection(kind: .commit, headSHA: "3c4d5e6f", branch: "main", commitTitle: "Bump Go", runIDs: [9], repeatRunIDs: [])],
                                   olderRunIDs: [], olderCommits: 0)
        #expect(RunPresentation.changeTitle(commit) == "3c4d5e6 Bump Go")
        #expect(RunPresentation.sectionTitle(commit.sections[0]) == nil)
        #expect(RunPresentation.changeSubtitle(change) == "retry → main", "the header names the branches, not each row")
        #expect(RunPresentation.changeSubtitle(commit) == "main")
        let runs = Dictionary(uniqueKeysWithValues: [run(9, branch: "main"), run(3, branch: "retry")].map { ($0.id, $0) })
        #expect(RunPresentation.changes([change, commit], runs: runs, branch: "retry").map(\.id) == ["pr:142"])
        #expect(RunPresentation.changes([change, commit], runs: runs, branch: nil).count == 2)
        #expect(RunPresentation.pullRequests([change, commit])[142]?.title == "Add retry to deploy")
    }

    @Test func theInspectorKnowsThePullRequestTheNewerRunAndTheHint() {
        let older = run(1, link: .pullRequest(142), supersededBy: 3)
        let newer = run(3, link: .pullRequest(142))
        let hint = CoreConcurrencyHint(workflowID: 3, path: ".github/workflows/ci.yml", runs: 3, overlapMinutes: 18, runIDs: [1], pullRequests: [142])
        let context = RunPresentation.context(for: older, runs: [3: newer], pullRequests: [142: pull], hints: [hint], workflowName: "CI")
        #expect(context.pullRequest == pull && context.supersededBy == newer && context.hint == hint)
        #expect(RunPresentation.hintText(hint, workflowName: "CI") == "3 runs of CI on older commits kept running after a newer push (about 18 min).")
        #expect(RunPresentation.outdatedHelp(older, newer: newer) == "A newer commit of #142 started CI #3. Cancel this run to save runner time.")
        #expect(RunPresentation.actionsURL([newer])?.absoluteString == "https://github.com/o/r/actions")
    }

    @Test func dismissedHintsAreKeptPerWorkspace() {
        let defaults = TestDefaults()
        defer { defaults.remove() }
        let workspace = UUID(), other = UUID()
        let dismissals = ConcurrencyHintDismissals(defaults: defaults.defaults)
        dismissals.dismiss(".github/workflows/ci.yml", workspaceID: workspace)
        #expect(dismissals.isDismissed(".github/workflows/ci.yml", workspaceID: workspace))
        #expect(!dismissals.isDismissed(".github/workflows/ci.yml", workspaceID: other))
        let reread = ConcurrencyHintDismissals(defaults: defaults.defaults)
        #expect(reread.isDismissed(".github/workflows/ci.yml", workspaceID: workspace))
        reread.removeAll(workspaceID: workspace)
        #expect(!ConcurrencyHintDismissals(defaults: defaults.defaults).isDismissed(".github/workflows/ci.yml", workspaceID: workspace))
    }

    private let sent = Date(timeIntervalSince1970: 1_000_000)

    private func started(_ starts: [CoreRunnirStart], attempt: Int64) -> CoreWorkflowRun {
        var marked = run(21)
        marked.runAttempt = attempt
        marked.runnirStarts = starts
        return marked
    }

    @Test func aRunRunnirStartedSaysSoBeforeItsDetailAndInItsHelp() {
        let dispatched = started([CoreRunnirStart(attempt: 1, kind: .dispatch, sentAt: sent)], attempt: 1)
        #expect(dispatched.startedFromRunnir && !run(1).startedFromRunnir)
        #expect(RunPresentation.fromRunnir == "From Runnir \u{00B7} ")
        let help = RunPresentation.rowHelp(dispatched, pullRequest: nil)
        #expect(help.hasPrefix("Commit a1b2c3d Bump retry count\nAttempt 1 was started from Runnir on this Mac, "))
        #expect(help.hasSuffix("\n" + RunPresentation.onlyThisMacKnows))
        #expect(RunPresentation.rowHelp(run(1), pullRequest: nil) == "Commit a1b2c3d Bump retry count", "a run Runnir did not start keeps its help")
    }

    @Test func theInspectorSaysWhichAttemptRunnirStarted() {
        let dispatch = CoreRunnirStart(attempt: 1, kind: .dispatch, sentAt: sent)
        let rerun = CoreRunnirStart(attempt: 2, kind: .rerunFailed, sentAt: sent)
        #expect(RunPresentation.runnirAttempt(started([dispatch], attempt: 1)) == " \u{00B7} from Runnir")
        #expect(RunPresentation.runnirAttempt(started([rerun], attempt: 2)) == " \u{00B7} re-run from Runnir")
        #expect(RunPresentation.runnirAttempt(started([dispatch, rerun], attempt: 3)) == " \u{00B7} attempt 2 from Runnir", "the newest earlier attempt")
        #expect(RunPresentation.runnirAttempt(run(1)) == nil)
    }

    @Test func theHelpNamesEachAttemptAndThatOnlyThisMacKnows() throws {
        let rerun = CoreRunnirStart(attempt: 2, kind: .rerunFailed, sentAt: sent)
        let one = try #require(RunPresentation.runnirHelp(started([rerun], attempt: 2), now: sent.addingTimeInterval(12 * 60)))
        #expect(one.hasPrefix("Attempt 2 re-ran the failed jobs from Runnir on this Mac, "))
        #expect(one.contains("on this Mac, 12m ago."), "the time is English whatever the Mac's language")
        #expect(one.contains(" Attempt 1 was not started from this Mac.\n"))
        #expect(one.hasSuffix(RunPresentation.onlyThisMacKnows))
        let many = try #require(RunPresentation.runnirHelp(started([CoreRunnirStart(attempt: 2, kind: .rerun, sentAt: sent),
                                                                    CoreRunnirStart(attempt: 4, kind: .rerunJob, sentAt: sent)], attempt: 4), now: sent))
        #expect(many.contains("Attempt 2 re-ran every job from Runnir on this Mac, "))
        #expect(many.contains("Attempt 4 re-ran one job from Runnir on this Mac, "))
        #expect(many.contains("Attempts 1 and 3 were not started from this Mac."))
        #expect(RunPresentation.runnirHelp(run(1)) == nil)
    }
}
