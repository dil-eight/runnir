import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ManualJobsTests {
    private let deploy = CoreJob(id: "deploy-production", name: "Deploy to production", needs: ["build"],
                                 manual: true, manualInputs: ["environment": "production"])
    private let workflow = CoreGitHubWorkflow(id: 77, name: "API", path: ".github/workflows/api.yml", state: "active", htmlURL: nil)

    private func run(status: String, conclusion: String? = "success", branch: String = "main", event: String = "push",
                     id: Int64 = 438) -> CoreWorkflowRun {
        CoreWorkflowRun(id: id, workflowID: 77, name: "API", displayTitle: "Bump", runNumber: id, event: event, status: status,
                        conclusion: conclusion, branch: branch, headSHA: "09e2502", actor: nil, htmlURL: nil, createdAt: Date(), updatedAt: nil)
    }

    private func job(_ status: String, conclusion: String? = nil) -> CoreRunJob {
        CoreRunJob(id: 1, name: "Deploy to production", status: status, conclusion: conclusion, startedAt: nil, completedAt: nil, htmlURL: nil, steps: [])
    }

    private func start(_ job: CoreJob, matched: [CoreRunJob] = [], latest: CoreWorkflowRun?, workflow: CoreGitHubWorkflow?,
                       defaultBranch: String? = "main") -> ManualJobStart? {
        ManualJobStart.of(job, matched: matched, run: latest, workflowRuns: latest.map { [$0] } ?? [], workflow: workflow,
                          defaultBranch: defaultBranch)
    }

    @Test func aJobStartedByHandStartsOnTheDefaultBranchWithTheInputsOfItsCondition() {
        let production = ManualJobStart.dispatch(workflowID: 77, ref: "main", inputs: ["environment": "production"])
        #expect(start(deploy, matched: [job("completed", conclusion: "skipped")], latest: run(status: "completed"), workflow: workflow) == production)
        // The latest run on a pull request's branch, still going, or none:
        // the deployment still starts on the default branch.
        #expect(start(deploy, latest: run(status: "completed", branch: "feature", event: "pull_request"), workflow: workflow) == production)
        #expect(start(deploy, latest: run(status: "in_progress", conclusion: nil, event: "pull_request"), workflow: workflow) == production)
        #expect(start(deploy, latest: nil, workflow: workflow) == production)
        // Not for other jobs, not without the workflow on GitHub or a known default branch.
        #expect(start(CoreJob(id: "build", name: "build", needs: []), latest: run(status: "completed"), workflow: workflow) == nil)
        #expect(start(deploy, latest: run(status: "completed"), workflow: nil) == nil)
        #expect(start(deploy, latest: run(status: "completed"), workflow: workflow, defaultBranch: nil) == nil)
        #expect(start(deploy, latest: run(status: "completed"), workflow: workflow, defaultBranch: "") == nil)
    }

    @Test func noStartWhileARunStartedByHandIsGoing() {
        let going = run(status: "queued", conclusion: nil, event: "workflow_dispatch", id: 440)
        let latest = run(status: "completed", event: "pull_request", id: 441)
        #expect(ManualJobStart.of(deploy, matched: [], run: latest, workflowRuns: [latest, going], workflow: workflow, defaultBranch: "main") == nil)
        let done = run(status: "completed", event: "workflow_dispatch", id: 440)
        #expect(ManualJobStart.of(deploy, matched: [], run: latest, workflowRuns: [latest, done], workflow: workflow, defaultBranch: "main") != nil)
    }

    @Test func aJobWaitingForApprovalOffersTheApproval() {
        let plain = CoreJob(id: "deploy", name: "deploy", needs: [])
        #expect(start(plain, matched: [job("waiting")], latest: run(status: "waiting", conclusion: nil), workflow: workflow)
                == .approve(runID: 438, runNumber: 438))
        #expect(start(plain, matched: [job("queued")], latest: run(status: "waiting", conclusion: nil), workflow: workflow) == nil)
    }

    @Test func theHintSaysHowTheJobStarts() {
        let skipped = [job("completed", conclusion: "skipped")]
        let offered = PipelineLayout.hint(for: deploy, matched: skipped, readFailed: false, now: Date(),
                                          start: .dispatch(workflowID: 77, ref: "main", inputs: ["environment": "production"]))
        #expect(offered.hasPrefix("Runs only when started by hand with environment: production · ▶ starts it on main\nSkipped"))
        // Without a ▶ (a run started by hand is going) the hint still says it.
        let notOffered = PipelineLayout.hint(for: deploy, matched: skipped, readFailed: false, now: Date())
        #expect(notOffered.hasPrefix("Runs only when started by hand with environment: production\nSkipped"))
        #expect(!PipelineLayout.hint(for: CoreJob(id: "build", name: "build", needs: []), matched: [], readFailed: false, now: Date())
            .contains("by hand"))
    }

    private func hub(_ configure: (FakeCore) -> Void = { _ in }) async -> (CoreHub, UUID, FakeCore) {
        let provider = FakeProvider()
        configure(provider.core)
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        _ = await eventually { hub.status == .ready(version: "fake") }
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/a")
        _ = await eventually { hub.session(for: workspace)?.phase == .ready }
        return (hub, workspace, provider.core)
    }

    @Test func playStartsTheWorkflowWithTheConditionsInputsAndWaitsForTheRun() async {
        let (hub, workspace, fake) = await hub { $0.dispatchedRunID = 450 }
        // The run the dispatch starts shows up at the next read.
        fake.setRuns(CoreGitHubResult(access: .ok, items: [run(status: "queued", conclusion: nil, event: "workflow_dispatch", id: 450)]),
                     for: "/repo/a")
        var asked: [String] = []
        let message = await ManualJobRunner.start(.dispatch(workflowID: 77, ref: "main", inputs: ["environment": "production"]),
                                                  jobName: "Deploy to production", workflowName: "API", workspaceID: workspace, hub: hub,
                                                  ask: { title, _, _ in asked.append(title); return true },
                                                  confirmOwner: { _ in .confirmed })
        #expect(asked == ["Run API on main?"])
        #expect(fake.dispatchRequests.map(\.ref) == ["main"])
        #expect(fake.dispatchRequests.first?.inputs == ["environment": "production"])
        #expect(fake.confirmed == ["dispatch_1"])
        #expect(message == "Started API on main with environment: production: run #450.")
    }

    @Test func aRunThatDoesNotShowUpIsSaid() async {
        let (hub, workspace, _) = await hub()
        hub.runLookupTimeout = .milliseconds(20)
        hub.runLookupInterval = .milliseconds(5)
        let message = await ManualJobRunner.start(.dispatch(workflowID: 77, ref: "main", inputs: [:]), jobName: "Deploy", workflowName: "API",
                                                  workspaceID: workspace, hub: hub, ask: { _, _, _ in true }, confirmOwner: { _ in .confirmed })
        #expect(message == "Started API on main. The run has not shown up yet; check Runs before starting it again.")
    }

    @Test func declinedConfirmationsSendNothing() async {
        let (hub, workspace, fake) = await hub()
        let start = ManualJobStart.dispatch(workflowID: 77, ref: "main", inputs: [:])
        let declined = await ManualJobRunner.start(start, jobName: "Deploy", workflowName: "API", workspaceID: workspace, hub: hub,
                                                   ask: { _, _, _ in false }, confirmOwner: { _ in .confirmed })
        let noTouchID = await ManualJobRunner.start(start, jobName: "Deploy", workflowName: "API", workspaceID: workspace, hub: hub,
                                                    ask: { _, _, _ in true }, confirmOwner: { _ in .declined })
        #expect(declined == nil && noTouchID == nil)
        #expect(fake.dispatchRequests.isEmpty)
        #expect(fake.confirmed.isEmpty)
    }

    @Test func playApprovesTheDeploymentsTheRunWaitsFor() async {
        let (hub, workspace, fake) = await hub { $0.runActionEnvironments = ["production"] }
        var asked: [String] = []
        let message = await ManualJobRunner.start(.approve(runID: 438, runNumber: 438), jobName: "Deploy to production", workflowName: "API",
                                                  workspaceID: workspace, hub: hub,
                                                  ask: { title, _, _ in asked.append(title); return true }, confirmOwner: { _ in .confirmed })
        #expect(fake.runActions == [.approveDeployments])
        #expect(asked == ["Approve the deployment to production?"])
        #expect(fake.confirmedActions == ["action_1"])
        #expect(message == "Approved the deployment to production; run #438 goes on.")
    }
}
