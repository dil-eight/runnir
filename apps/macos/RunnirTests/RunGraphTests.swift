import AppKit
import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite struct RunGraphTests {
    private func job(_ id: String, name: String = "", needs: [String] = []) -> CoreJob {
        CoreJob(id: id, name: name, needs: needs)
    }

    private func runJob(_ id: Int64, _ name: String, node: String = "", status: String = "completed", conclusion: String? = "success",
                        steps: [CoreRunStep] = []) -> CoreRunJob {
        CoreRunJob(id: id, name: name, status: status, conclusion: conclusion, startedAt: nil, completedAt: nil, htmlURL: nil, steps: steps,
                   workflowJobID: node)
    }

    @Test func jobsAreLaidOutInTheOrderTheyNeedEachOther() throws {
        let workflow = [job("lint"), job("unit", name: "unit-tests"), job("build", needs: ["lint", "unit"]), job("publish", needs: ["build"])]
        let runJobs = [runJob(1, "lint", node: "lint"), runJob(2, "unit-tests", node: "unit"), runJob(3, "build", node: "build", conclusion: "failure")]
        let layout = try #require(RunGraph.layout(workflow: workflow, runJobs: runJobs))
        #expect(layout.columns.map { $0.map(\.id) } == [["lint", "unit"], ["build"], ["publish"]])
        #expect(layout.columns[0][1].name == "unit-tests")
        #expect(layout.columns[1][0].outcome == .failed)
        #expect(layout.columns[2][0].outcome == nil, "a job that has no run job has no outcome")
        #expect(layout.others.isEmpty)
    }

    @Test func aMatrixIsOneNodeWithItsCountAndTheWorstOutcome() throws {
        let workflow = [job("test", name: "test")]
        let runJobs = [runJob(1, "test (ubuntu)", node: "test"), runJob(2, "test (macos)", node: "test", conclusion: "failure"),
                       runJob(3, "test (windows)", node: "test")]
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
        let layout = try #require(RunGraph.layout(workflow: [job("build")], runJobs: [runJob(1, "build", node: "build"), runJob(2, "release / publish")]))
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

    private func skip(_ kind: CoreJobSkip.Kind, need: String = "", result: String = "", note: String = "") -> CoreJobSkip {
        CoreJobSkip(jobID: "publish", kind: kind, need: need, needResult: result, condition: "github.event_name == 'pull_request'",
                    values: [.init(name: "github.event_name", value: "push")], unknown: [], note: note)
    }

    @Test func aSkippedNodeSaysWhy() {
        #expect(RunGraph.reason(skip(.needs, need: "build", result: "failure")) == "need failed")
        #expect(RunGraph.reason(skip(.needs, need: "build", result: "cancelled")) == "need cancelled")
        #expect(RunGraph.reason(skip(.needs, need: "build", result: "skipped")) == "need skipped")
        #expect(RunGraph.reason(skip(.conditionFalse)) == "condition false")
        #expect(RunGraph.reason(skip(.notKnown)) == "not known")
        #expect(RunGraph.reason(skip(.notInRun)) == "not in this run")
        #expect(RunGraph.resultOutcome("failure") == .failed && RunGraph.resultOutcome("cancelled") == .cancelled)
    }

    @Test func thePanelSaysWhyAndWhereItWasRead() {
        #expect(RunGraph.panelTitle(job: "publish", skip(.needs, need: "build", result: "failure")) == "Why publish was skipped")
        #expect(RunGraph.panelTitle(job: "preview", skip(.notInRun)) == "preview is not in this run")
        #expect(RunGraph.panelSentence(skip(.conditionFalse)) == "Its condition is false for this run.")
        #expect(RunGraph.panelSentence(skip(.notKnown)) == "Its condition reads something only the run knew, so Runnir cannot tell.")
        #expect(RunGraph.panelSentence(skip(.notKnown, note: "Runnir reads its condition as true.")) == "Runnir reads its condition as true.")
        #expect(RunGraph.sourceLine(path: ".github/workflows/ios-release.yml", sha: "a3f9c21dd", note: "")
                == "Read from ios-release.yml at a3f9c21, the file this run used.")
        #expect(RunGraph.sourceLine(path: ".github/workflows/ci.yml", sha: "a3f9c21dd", note: "GitHub ran this file merged with the base, which may differ.")
                == "Read from ci.yml at a3f9c21; GitHub ran this file merged with the base, which may differ.")
    }

    @Test func thePanelStaysUnderItsNodeAndInsideTheColumns() {
        #expect(RunGraph.panelLeading(nodeMinX: 0, columnsWidth: 596, panelWidth: 360) == 0)
        #expect(RunGraph.panelLeading(nodeMinX: 210, columnsWidth: 596, panelWidth: 360) == 210)
        #expect(RunGraph.panelLeading(nodeMinX: 420, columnsWidth: 596, panelWidth: 360) == 236, "the last column's panel ends with it")
        #expect(RunGraph.panelLeading(nodeMinX: 0, columnsWidth: 176, panelWidth: 360) == 0)
    }

    @Test func oneWhyPanelIsOpenAtATime() async {
        let model = RunLayerModel(hub: CoreHub(provider: FakeProvider()), workspaceID: UUID())
        model.show(run: 1)
        model.toggleSkip("docs")
        #expect(model.skipJobID == "docs")
        model.toggleSkip("publish")
        #expect(model.skipJobID == "publish", "another skipped node moves the panel there")
        model.toggleSkip("publish")
        #expect(model.skipJobID == nil, "the same node closes it")
        model.toggleSkip("docs")
        model.open(runJob(5, "build"))
        #expect(model.skipJobID == nil, "a job's log closes the panel")
        model.toggleSkip("docs")
        model.show(run: 2)
        #expect(model.skipJobID == nil)
    }

    private func workflowRun(status: String, attempt: Int64 = 1) -> CoreWorkflowRun {
        CoreWorkflowRun(id: 21, workflowID: 1, name: "CI", displayTitle: "Fix build", runNumber: 1482, event: "push",
                        status: status, conclusion: status == "completed" ? "failure" : nil, branch: "main", headSHA: "a3f9c21ffff",
                        actor: "eugene", htmlURL: nil, createdAt: nil, updatedAt: nil, runAttempt: attempt)
    }

    @Test func theReasonsAreAskedForAgainWhenTheRunSkipsAJob() {
        let going = workflowRun(status: "in_progress")
        let lint = runJob(1, "lint", node: "lint")
        let docs = runJob(2, "docs", node: "docs", conclusion: "skipped")
        let first = RunGraph.workflowRequest(run: going, jobs: [lint])
        #expect(RunGraph.workflowRequest(run: going, jobs: [lint, runJob(3, "build", status: "in_progress", conclusion: nil)]) == first,
                "a job that starts asks nothing")
        #expect(RunGraph.workflowRequest(run: going, jobs: [lint, docs]) != first, "a job the run skipped asks again")
        let done = RunGraph.workflowRequest(run: workflowRun(status: "completed"), jobs: [lint, docs])
        #expect(done != RunGraph.workflowRequest(run: going, jobs: [lint, docs]), "the run finishing asks again")
        #expect(RunGraph.workflowRequest(run: workflowRun(status: "completed"), jobs: nil) == done, "a finished run's jobs reloading asks nothing")
        #expect(RunGraph.workflowRequest(run: workflowRun(status: "completed", attempt: 2), jobs: nil) != done, "a re-run asks again")
    }

    @Test func aFailedReadKeepsTheGraphShown() {
        let model = RunLayerModel(hub: CoreHub(provider: FakeProvider()), workspaceID: UUID())
        model.show(run: 1)
        model.apply(workflow: .failed(.unavailable))
        #expect(model.workflow?.access == .unavailable, "a first read that fails is shown")
        let read = CoreRunWorkflow(access: .ok, path: ".github/workflows/ci.yml", jobs: [job("lint")], problem: "",
                                   skips: [skip(.notInRun)])
        model.apply(workflow: read)
        model.apply(workflow: .failed(.unavailable))
        #expect(model.workflow == read)
        let again = CoreRunWorkflow(access: .ok, path: ".github/workflows/ci.yml", jobs: [job("lint")], problem: "")
        model.apply(workflow: again)
        #expect(model.workflow == again, "a read that works replaces it")
    }

    @Test func escapeClosesThePanelOnlyInItsOwnWindowAndNotOverAField() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        #expect(SkippedJobPanel.escapeCloses(in: window, host: window))
        #expect(!SkippedJobPanel.escapeCloses(in: other, host: window), "another window or a sheet keeps its Escape")
        #expect(!SkippedJobPanel.escapeCloses(in: window, host: nil))
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        #expect(!SkippedJobPanel.escapeCloses(in: window, host: window), "a field being edited keeps its Escape")
        field.isEditable = false
        #expect(SkippedJobPanel.escapeCloses(in: window, host: window), "text that can only be selected does not")
    }
}
