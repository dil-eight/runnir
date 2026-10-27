import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite struct RunGraphTests {
    private func job(_ id: String, name: String = "", needs: [String] = []) -> CoreJob {
        CoreJob(id: id, name: name, needs: needs)
    }

    private func runJob(_ id: Int64, _ name: String, status: String = "completed", conclusion: String? = "success",
                        steps: [CoreRunStep] = []) -> CoreRunJob {
        CoreRunJob(id: id, name: name, status: status, conclusion: conclusion, startedAt: nil, completedAt: nil, htmlURL: nil, steps: steps)
    }

    @Test func jobsAreLaidOutInTheOrderTheyNeedEachOther() throws {
        let workflow = [job("lint"), job("unit", name: "unit-tests"), job("build", needs: ["lint", "unit"]), job("publish", needs: ["build"])]
        let runJobs = [runJob(1, "lint"), runJob(2, "unit-tests"), runJob(3, "build", conclusion: "failure")]
        let layout = try #require(RunGraph.layout(workflow: workflow, runJobs: runJobs))
        #expect(layout.columns.map { $0.map(\.id) } == [["lint", "unit"], ["build"], ["publish"]])
        #expect(layout.columns[0][1].name == "unit-tests")
        #expect(layout.columns[1][0].outcome == .failed)
        #expect(layout.columns[2][0].outcome == nil, "a job that has no run job has no outcome")
        #expect(layout.others.isEmpty)
    }

    @Test func aMatrixIsOneNodeWithItsCountAndTheWorstOutcome() throws {
        let workflow = [job("test", name: "test")]
        let runJobs = [runJob(1, "test (ubuntu)"), runJob(2, "test (macos)", conclusion: "failure"), runJob(3, "test (windows)")]
        let node = try #require(RunGraph.layout(workflow: workflow, runJobs: runJobs)?.columns.first?.first)
        #expect(node.title == "test ×3")
        #expect(node.outcome == .failed)
        #expect(RunGraph.jobToOpen(node.jobs)?.id == 2, "a click opens the failed variant")
    }

    @Test func aNameSetByAnExpressionShowsTheJobId() throws {
        let node = try #require(RunGraph.layout(workflow: [job("deploy", name: "Deploy ${{ matrix.env }}")], runJobs: [])?.columns.first?.first)
        #expect(node.name == "deploy")
    }

    @Test func runJobsNoFileJobClaimsAreKeptAsOthers() throws {
        let layout = try #require(RunGraph.layout(workflow: [job("build")], runJobs: [runJob(1, "build"), runJob(2, "release / publish")]))
        #expect(layout.others.map(\.name) == ["release / publish"])
    }

    @Test func withoutJobsFromTheFileThereIsNoGraph() {
        #expect(RunGraph.layout(workflow: [], runJobs: [runJob(1, "build")]) == nil)
    }

    @Test func aJobThatNeverStartedIsWaitingOrSkippedByTheRun() {
        #expect(RunGraph.absentOutcome(runActive: true) == .queued)
        #expect(RunGraph.absentOutcome(runActive: false) == .skipped)
    }

    @Test func theFocusIsTheFailedStepOfAFailedRunOrTheRunningOneOfAnActiveRun() throws {
        let failedStep = CoreRunStep(number: 2, name: "Archive", status: "completed", conclusion: "failure", startedAt: nil, completedAt: nil)
        let okStep = CoreRunStep(number: 1, name: "Set up job", status: "completed", conclusion: "success", startedAt: nil, completedAt: nil)
        let failed = [runJob(1, "lint"), runJob(2, "build", conclusion: "failure", steps: [okStep, failedStep])]
        let finished = try #require(RunGraph.focus(failed, runActive: false))
        #expect(finished.job.id == 2 && finished.step?.name == "Archive" && finished.failed)
        #expect(RunGraph.focus([runJob(1, "lint")], runActive: false) == nil, "a run that passed has nothing to point at")

        let runningStep = CoreRunStep(number: 3, name: "Install", status: "in_progress", conclusion: nil, startedAt: nil, completedAt: nil)
        let active = [runJob(1, "lint"), runJob(2, "build", status: "in_progress", conclusion: nil, steps: [okStep, runningStep])]
        let now = try #require(RunGraph.focus(active, runActive: true))
        #expect(now.job.id == 2 && now.step?.name == "Install" && !now.failed)
    }

    @Test func theLayerOpensOnTheFailedStepAndForgetsAnotherRun() async {
        let hub = CoreHub(provider: FakeProvider())
        let model = RunLayerModel(hub: hub, workspaceID: UUID())
        let failedStep = CoreRunStep(number: 2, name: "Archive", status: "completed", conclusion: "failure", startedAt: nil, completedAt: nil)
        let job = runJob(5, "build", conclusion: "failure", steps: [failedStep])
        model.show(run: 1)
        model.apply(jobs: (CoreGitHubResult(access: .ok, items: [job]), false))
        model.open(job)
        #expect(model.isOpen && model.jobID == 5 && model.step == 2)
        model.expanded = true
        model.apply(jobs: (CoreGitHubResult(access: .ok, items: [job]), false))
        #expect(model.isOpen && model.expanded, "a reload that still has the job keeps the log open")
        model.apply(jobs: (CoreGitHubResult(access: .ok, items: []), false))
        #expect(!model.isOpen && !model.expanded, "the job is gone: nothing stays open")
        model.open(job)
        model.show(run: 2)
        #expect(!model.isOpen && model.jobs == nil && model.workflow == nil)
    }
}
