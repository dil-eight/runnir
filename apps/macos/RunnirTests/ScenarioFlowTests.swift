import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ScenarioFlowTests {
    private func job(_ id: String, column: Int = 0, matrix: Int = 0, skipped: String = "") -> CoreFlowJob {
        CoreFlowJob(id: id, name: id, needs: [], column: column, matrix: matrix, environment: "", condition: "", skipped: skipped,
                    manual: false, manualInputs: [:], uses: "")
    }

    private func run(_ id: Int64) -> CoreWorkflowRun {
        CoreWorkflowRun(id: id, workflowID: 3, name: "CI", displayTitle: "Fix", runNumber: id, event: "pull_request", status: "completed",
                        conclusion: "success", branch: "feature", headSHA: "abc", actor: nil, htmlURL: nil, createdAt: nil, updatedAt: nil)
    }

    private let pullRequest = CoreScenario(kind: .pullRequest, target: "main", title: "Pull request → main")
    private let merge = CoreScenario(kind: .merge, target: "main", title: "Merge into main")

    @Test func jobsSitInTheColumnsTheCoreGaveThem() {
        let columns = ScenarioFlowModel.columns([job("lint"), job("unit"), job("build", column: 1), job("deploy", column: 2)])
        #expect(columns.map { $0.map(\.id) } == [["lint", "unit"], ["build"], ["deploy"]])
        #expect(ScenarioFlowModel.columns([]).isEmpty)
    }

    @Test func aLaneIsAsWideAsItsColumns() {
        #expect(ScenarioFlowView.jobsWidth([]) == 0)
        #expect(ScenarioFlowView.jobsWidth([job("lint")]) == ScenarioFlowView.nodeWidth)
        let three = ScenarioFlowView.jobsWidth([job("a"), job("b", column: 1), job("c", column: 2), job("d", column: 2)])
        #expect(three == 3 * ScenarioFlowView.nodeWidth + 2 * ScenarioFlowView.columnGap)
    }

    @Test func aNodeSaysItsMatrix() {
        #expect(ScenarioFlowModel.title(job("tests", matrix: 3)) == "tests ×3")
        #expect(ScenarioFlowModel.title(job("tests", matrix: -1)) == "tests ×n")
        #expect(ScenarioFlowModel.title(job("tests", matrix: 1)) == "tests")
    }

    @Test func theChangesLineSaysWhatPathsAreReadAgainst() {
        #expect(ScenarioFlowModel.changesText(CoreFlowChanges(applies: true, known: true, count: 12, against: "origin/main"))
                == "12 files changed against origin/main")
        #expect(ScenarioFlowModel.changesText(CoreFlowChanges(applies: true, known: false, note: "git not found")) == "git not found")
        #expect(ScenarioFlowModel.changesText(CoreFlowChanges(applies: false, known: true)) == nil, "a tag reads no paths")
    }

    @Test func aBranchWithoutAPullRequestIntoTheBaseIsSaidSo() {
        let none = CoreFlow(scenarios: [pullRequest, merge], scenario: pullRequest)
        #expect(ScenarioFlowModel.noPullRequestText(none, branch: "feature/retry")
                == "feature/retry has no open pull request into main: this is what opening one starts.")
        // One into another base does not count for main.
        #expect(ScenarioFlowModel.noPullRequestText(CoreFlow(scenario: pullRequest, pullRequestBase: "develop"), branch: "feature/retry") != nil)
        #expect(ScenarioFlowModel.noPullRequestText(CoreFlow(scenario: pullRequest, pullRequestBase: "main"), branch: "feature/retry") == nil)
        #expect(ScenarioFlowModel.noPullRequestText(CoreFlow(scenario: merge), branch: "feature/retry") == nil)
        #expect(ScenarioFlowModel.noPullRequestText(none, branch: "") == nil)
    }

    @Test func aScenarioThatStartsNothingSaysSoInPlaceOfTheLanes() {
        let push = CoreScenario(kind: .push, target: "feature/retry", title: "Push to feature/retry")
        let skipped = [CoreSkippedWorkflow(path: ".github/workflows/ci.yml", name: "CI", reason: "branch feature/retry does not match main")]
        let none = ScenarioFlowModel.nothingRuns(CoreFlow(scenario: push, skipped: skipped))
        #expect(none?.title == "Nothing runs on a push to feature/retry")
        #expect(none?.detail == "No workflow reacts to a push to this branch, and the branch has no open pull request whose checks a push would run again."
                + " Why each workflow stays out is under Not in this scenario.")
        let open = ScenarioFlowModel.nothingRuns(CoreFlow(scenario: push, pullRequestBase: "main"))
        #expect(open?.detail == "No workflow reacts to a push to this branch or to the update of its pull request into main.")
        // A workflow run by hand is not the scenario's own.
        let lane = { (kind: CoreFlowLane.Kind) in
            CoreFlowLane(path: ".github/workflows/x.yml", name: "X", kind: kind, after: "", afterPath: "", why: "", jobs: [], run: nil,
                         statusesFrom: "", parseError: "")
        }
        #expect(ScenarioFlowModel.nothingRuns(CoreFlow(scenario: push, lanes: [lane(.byHand)])) != nil)
        #expect(ScenarioFlowModel.nothingRuns(CoreFlow(scenario: push, lanes: [lane(.direct)])) == nil)
        #expect(ScenarioFlowModel.nothingRuns(CoreFlow()) == nil, "no scenario has its own line")
        #expect(ScenarioFlowModel.nothingRuns(CoreFlow(scenario: merge))?.title == "Nothing runs on a merge into main")
    }

    @Test func thePickerGroupsScenariosByKind() {
        let groups = ScenarioFlowModel.groups([pullRequest, CoreScenario(kind: .pullRequest, target: "release", title: "Pull request → release"),
                                               merge, CoreScenario(kind: .schedule, target: "", title: "Schedule")])
        #expect(groups.map(\.title) == ["Pull request", "Merge into", "Schedule"])
        #expect(groups[0].scenarios.count == 2)
    }

    @Test func theModelPlansThePickedScenarioAndReadsTheJobsOfEachLane() async {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        _ = await eventually { hub.session(for: workspace)?.coreID != nil }
        let lane = CoreFlowLane(path: ".github/workflows/ci.yml", name: "CI", kind: .direct, after: "", afterPath: "", why: "pull_request",
                                jobs: [job("lint")], run: run(10), statusesFrom: "", parseError: "")
        provider.core.flowResult = CoreFlow(scenarios: [pullRequest, merge], scenario: pullRequest, lanes: [lane])
        let model = ScenarioFlowModel(hub: hub, workspaceID: workspace)
        await model.load()
        #expect(model.scenario == pullRequest && model.flow?.lanes.count == 1)
        #expect(provider.core.flowScenarios == [nil], "the Core picks the default")
        #expect(model.jobs[10] != nil, "the lane's run has its jobs read")
        model.choose(merge)
        await model.load()
        #expect(provider.core.flowScenarios.last == merge)
    }

    @Test func jobsReadBeforeTheTokenArrivedAreReadAgain() async {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        _ = await eventually { hub.session(for: workspace)?.coreID != nil }
        let lane = CoreFlowLane(path: ".github/workflows/ci.yml", name: "CI", kind: .direct, after: "", afterPath: "", why: "pull_request",
                                jobs: [job("lint")], run: run(10), statusesFrom: "", parseError: "")
        provider.core.flowResult = CoreFlow(scenarios: [pullRequest], scenario: pullRequest, lanes: [lane])
        // At launch the Core has no token until Keychain hands it over.
        provider.core.setJobs(CoreGitHubResult(access: .signedOut, items: []))
        let model = ScenarioFlowModel(hub: hub, workspaceID: workspace)
        await model.load()
        #expect(model.jobs[10]?.access == .signedOut)
        provider.core.setJobs(CoreGitHubResult(access: .ok, items: []))
        await model.load()
        #expect(model.jobs[10]?.access == .ok, "the same run, unchanged, is read again once its jobs could not be")
    }
}
