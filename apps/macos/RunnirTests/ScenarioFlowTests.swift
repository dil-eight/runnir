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
}
