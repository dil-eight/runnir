import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite struct RunStatusFilterTests {
    private func run(_ id: Int64, title: String = "Fix build", branch: String = "main", status: String = "completed",
                     conclusion: String? = "success") -> CoreWorkflowRun {
        CoreWorkflowRun(id: id, workflowID: 3, name: "CI", displayTitle: title, runNumber: id, event: "push", status: status,
                        conclusion: conclusion, branch: branch, headSHA: "a3f9c21ffee0", actor: "eugene", htmlURL: nil, createdAt: nil,
                        updatedAt: nil, commitTitle: "", link: .none, supersededBy: nil)
    }

    private func statuses(_ runs: [CoreWorkflowRun]) -> [RunStatusFilter] { runs.map(RunStatusFilter.of) }

    @Test func everyStatusAndConclusionFallsInOneOfTheSix() {
        #expect(RunStatusFilter.of(run(1, conclusion: "success")) == .succeeded)
        for conclusion in ["failure", "timed_out", "startup_failure"] {
            #expect(RunStatusFilter.of(run(1, conclusion: conclusion)) == .failed, "\(conclusion)")
        }
        #expect(RunStatusFilter.of(run(1, conclusion: "cancelled")) == .cancelled)
        #expect(RunStatusFilter.of(run(1, status: "in_progress", conclusion: nil)) == .running)
        for status in ["queued", "waiting", "requested", "pending"] {
            #expect(RunStatusFilter.of(run(1, status: status, conclusion: nil)) == .queued, "\(status)")
        }
        #expect(RunStatusFilter.of(run(1, conclusion: "skipped")) == .skipped)
        #expect(RunStatusFilter.of(run(1, conclusion: "neutral")) == .skipped)
        #expect(RunStatusFilter.of(run(1, conclusion: "stale")) == .skipped)
        #expect(RunStatusFilter.of(run(1, conclusion: "action_required")) == .queued, "it waits for a person")
    }

    @Test func chosenStatusesCombineWithOrAndNoneMeansAll() {
        let runs = [run(1), run(2, conclusion: "failure"), run(3, status: "in_progress", conclusion: nil), run(4, conclusion: "cancelled")]
        #expect(RunStatusFilter.filter(runs, statuses: []).map(\.id) == [1, 2, 3, 4])
        #expect(RunStatusFilter.filter(runs, statuses: [.failed]).map(\.id) == [2])
        #expect(RunStatusFilter.filter(runs, statuses: [.failed, .running]).map(\.id) == [2, 3])
    }

    @Test func theStatusFilterCombinesWithTheQueryAndTheBranch() {
        let runs = [run(1, title: "Release 1.4.0", conclusion: "failure"), run(2, title: "Release 1.3.9"),
                    run(3, title: "Bump Go", conclusion: "failure"), run(4, title: "Release 1.4.1", branch: "dev", conclusion: "failure")]
        let failed = RunPresentation.list(runs, branch: nil, query: "release", statuses: [.failed], showingSuperseded: false)
        #expect(failed.map(\.id) == [1, 4])
        let onMain = RunPresentation.list(runs, branch: "main", query: "release", statuses: [.failed], showingSuperseded: false)
        #expect(onMain.map(\.id) == [1])
        let onlyStatus = RunPresentation.list(runs, branch: nil, query: "", statuses: [.failed], showingSuperseded: false)
        #expect(onlyStatus.map(\.id) == [1, 3, 4])
    }

    @Test func theCountsFollowTheQueryAndTheBranchWhateverIsTicked() {
        let runs = [run(1, title: "Release 1.4.0", conclusion: "failure"), run(2, title: "Release 1.3.9"),
                    run(3, title: "Bump Go", conclusion: "failure"), run(4, title: "Release 1.4.1", branch: "dev", conclusion: "failure")]
        let counts = RunStatusFilter.counts(RunPresentation.matching(runs, branch: nil, query: "release"))
        #expect(counts[.failed] == 2)
        #expect(counts[.succeeded] == 1)
        #expect(counts[.running] == nil, "a status nothing matches has no count")
        let main = RunStatusFilter.counts(RunPresentation.matching(runs, branch: "main", query: "release"))
        #expect(main[.failed] == 1)
        let all = RunStatusFilter.counts(RunPresentation.matching(runs, branch: nil, query: ""))
        #expect(all.values.reduce(0, +) == 4)
    }

    @Test func aStatusFilterShowsSupersededRunsLikeASearchDoes() {
        let runs = [run(1, conclusion: "failure"), run(2, conclusion: "failure")]
        let hidden = RunPresentation.list(runs, branch: nil, query: "", statuses: [], showingSuperseded: false)
        let filtered = RunPresentation.list(runs, branch: nil, query: "", statuses: [.failed], showingSuperseded: false)
        #expect(filtered.count == 2)
        #expect(hidden.count <= filtered.count)
    }
}
