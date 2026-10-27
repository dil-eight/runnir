import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite struct RunStatusFilterTests {
    /// A run as the Core sends it: its status group set by the Core. Status
    /// and conclusion say nothing to the filter, so they are left alike.
    private func run(_ id: Int64, title: String = "Fix build", branch: String = "main",
                     group: CoreRunStatusGroup? = .succeeded) -> CoreWorkflowRun {
        CoreWorkflowRun(id: id, workflowID: 3, name: "CI", displayTitle: title, runNumber: id, event: "push", status: "completed",
                        conclusion: "success", branch: branch, headSHA: "a3f9c21ffee0", actor: "eugene", htmlURL: nil, createdAt: nil,
                        updatedAt: nil, commitTitle: "", link: .none, supersededBy: nil, statusGroup: group)
    }

    @Test func theCoreSaysWhichStatusARunHas() {
        let pairs: [(CoreRunStatusGroup, RunStatusFilter)] = [(.succeeded, .succeeded), (.failed, .failed), (.cancelled, .cancelled),
                                                              (.running, .running), (.queued, .queued), (.skipped, .skipped)]
        for (group, status) in pairs { #expect(RunStatusFilter.of(run(1, group: group)) == status) }
        // A run the Core gave no status matches no ticked status and is not counted.
        let unknown = run(9, group: nil)
        #expect(RunStatusFilter.of(unknown) == nil)
        #expect(RunStatusFilter.filter([unknown, run(1)], statuses: [.succeeded]).map(\.id) == [1])
        #expect(RunStatusFilter.filter([unknown], statuses: []).map(\.id) == [9], "no status ticked keeps every run")
        #expect(RunStatusFilter.counts([unknown, run(1)]) == [.succeeded: 1])
    }

    @Test func chosenStatusesCombineWithOrAndNoneMeansAll() {
        let runs = [run(1), run(2, group: .failed), run(3, group: .running), run(4, group: .cancelled)]
        #expect(RunStatusFilter.filter(runs, statuses: []).map(\.id) == [1, 2, 3, 4])
        #expect(RunStatusFilter.filter(runs, statuses: [.failed]).map(\.id) == [2])
        #expect(RunStatusFilter.filter(runs, statuses: [.failed, .running]).map(\.id) == [2, 3])
    }

    @Test func theStatusFilterCombinesWithTheFoundRunsAndTheBranch() {
        let runs = [run(1, title: "Release 1.4.0", group: .failed), run(2, title: "Release 1.3.9"),
                    run(3, title: "Bump Go", group: .failed), run(4, title: "Release 1.4.1", branch: "dev", group: .failed)]
        // The Core found the three Release runs for the query.
        let found: Set<Int64> = [1, 2, 4]
        let failed = RunPresentation.list(runs, branch: nil, matching: found, statuses: [.failed], showingSuperseded: false)
        #expect(failed.map(\.id) == [1, 4])
        let onMain = RunPresentation.list(runs, branch: "main", matching: found, statuses: [.failed], showingSuperseded: false)
        #expect(onMain.map(\.id) == [1])
        let onlyStatus = RunPresentation.list(runs, branch: nil, matching: nil, statuses: [.failed], showingSuperseded: false)
        #expect(onlyStatus.map(\.id) == [1, 3, 4])
    }

    @Test func theCountsFollowTheFoundRunsAndTheBranchWhateverIsTicked() {
        let runs = [run(1, title: "Release 1.4.0", group: .failed), run(2, title: "Release 1.3.9"),
                    run(3, title: "Bump Go", group: .failed), run(4, title: "Release 1.4.1", branch: "dev", group: .failed)]
        let counts = RunStatusFilter.counts(RunPresentation.matching(runs, branch: nil, ids: [1, 2, 4]))
        #expect(counts[.failed] == 2)
        #expect(counts[.succeeded] == 1)
        #expect(counts[.running] == nil, "a status nothing matches has no count")
        let main = RunStatusFilter.counts(RunPresentation.matching(runs, branch: "main", ids: [1, 2, 4]))
        #expect(main[.failed] == 1)
        let all = RunStatusFilter.counts(RunPresentation.matching(runs, branch: nil, ids: nil))
        #expect(all.values.reduce(0, +) == 4)
    }

    @Test func aStatusFilterShowsSupersededRunsLikeASearchDoes() {
        let runs = [run(1, group: .failed), run(2, group: .failed)]
        let hidden = RunPresentation.list(runs, branch: nil, statuses: [], showingSuperseded: false)
        let filtered = RunPresentation.list(runs, branch: nil, statuses: [.failed], showingSuperseded: false)
        #expect(filtered.count == 2)
        #expect(hidden.count <= filtered.count)
    }
}
