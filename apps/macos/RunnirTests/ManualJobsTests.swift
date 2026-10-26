import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ManualJobsTests {
    private let deploy = CoreJob(id: "deploy-production", name: "Deploy to production", needs: ["build"],
                                 manual: true, manualInputs: ["environment": "production"])
    private let workflow = CoreGitHubWorkflow(id: 77, name: "API", path: ".github/workflows/api.yml", state: "active", htmlURL: nil)

    private func run(status: String, conclusion: String? = "success", branch: String = "main") -> CoreWorkflowRun {
        CoreWorkflowRun(id: 438, workflowID: 77, name: "API", displayTitle: "Bump", runNumber: 438, event: "push", status: status,
                        conclusion: conclusion, branch: branch, headSHA: "09e2502", actor: nil, htmlURL: nil, createdAt: nil, updatedAt: nil)
    }

    private func job(_ status: String, conclusion: String? = nil) -> CoreRunJob {
        CoreRunJob(id: 1, name: "Deploy to production", status: status, conclusion: conclusion, startedAt: nil, completedAt: nil, htmlURL: nil, steps: [])
    }

    @Test func aJobStartedByHandOffersANewRunWithTheInputsOfItsCondition() {
        let skipped = [job("completed", conclusion: "skipped")]
        #expect(ManualJobStart.of(deploy, matched: skipped, run: run(status: "completed"), workflow: workflow, defaultBranch: "main")
                == .dispatch(workflowID: 77, ref: "main", inputs: ["environment": "production"]))
        // Not while the run is going, not for other jobs, not without the workflow on GitHub.
        #expect(ManualJobStart.of(deploy, matched: [], run: run(status: "in_progress", conclusion: nil), workflow: workflow, defaultBranch: "main") == nil)
        #expect(ManualJobStart.of(CoreJob(id: "build", name: "build", needs: []), matched: [], run: run(status: "completed"), workflow: workflow, defaultBranch: "main") == nil)
        #expect(ManualJobStart.of(deploy, matched: skipped, run: run(status: "completed"), workflow: nil, defaultBranch: "main") == nil)
        #expect(ManualJobStart.of(deploy, matched: skipped, run: nil, workflow: workflow, defaultBranch: "main") == nil)
        // A pull request's branch never starts a deployment, nor an unknown default branch.
        #expect(ManualJobStart.of(deploy, matched: skipped, run: run(status: "completed", branch: "feature"), workflow: workflow, defaultBranch: "main") == nil)
        #expect(ManualJobStart.of(deploy, matched: skipped, run: run(status: "completed"), workflow: workflow, defaultBranch: nil) == nil)
    }

    @Test func aJobWaitingForApprovalOffersTheApproval() {
        let plain = CoreJob(id: "deploy", name: "deploy", needs: [])
        #expect(ManualJobStart.of(plain, matched: [job("waiting")], run: run(status: "waiting", conclusion: nil), workflow: workflow, defaultBranch: "main")
                == .approve(runID: 438, runNumber: 438))
        #expect(ManualJobStart.of(plain, matched: [job("queued")], run: run(status: "waiting", conclusion: nil), workflow: workflow, defaultBranch: "main") == nil)
    }

    @Test func theHintSaysHowTheJobStarts() {
        let hint = PipelineLayout.hint(for: deploy, matched: [job("completed", conclusion: "skipped")], readFailed: false, now: Date(),
                                       start: .dispatch(workflowID: 77, ref: "main", inputs: ["environment": "production"]))
        #expect(hint.hasPrefix("Runs only when started by hand with environment: production · ▶ starts it\nSkipped"))
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

    @Test func playStartsTheWorkflowOnTheRunsBranchWithTheConditionsInputs() async {
        let (hub, workspace, fake) = await hub()
        var asked: [String] = []
        let message = await ManualJobRunner.start(.dispatch(workflowID: 77, ref: "main", inputs: ["environment": "production"]),
                                                  jobName: "Deploy to production", workflowName: "API", workspaceID: workspace, hub: hub,
                                                  ask: { title, _, _ in asked.append(title); return true },
                                                  confirmOwner: { _ in .confirmed })
        #expect(asked == ["Run API on main?"])
        #expect(fake.dispatchRequests.map(\.ref) == ["main"])
        #expect(fake.dispatchRequests.first?.inputs == ["environment": "production"])
        #expect(fake.confirmed == ["dispatch_1"])
        #expect(message == "Started API on main with environment: production.")
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
