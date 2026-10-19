import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DispatchFormModelTests {
    private let workflow = CoreGitHubWorkflow(id: 1, name: "Deploy", path: ".github/workflows/deploy.yml", state: "active", htmlURL: nil)

    private func dispatchRun(_ id: Int64, workflowID: Int64 = 1, event: String = "workflow_dispatch", branch: String = "feature",
                             created: Date = Date()) -> CoreWorkflowRun {
        CoreWorkflowRun(id: id, workflowID: workflowID, name: "Deploy", displayTitle: "Deploy", runNumber: id, event: event,
                        status: "queued", conclusion: nil, branch: branch, headSHA: "abc", actor: "me", htmlURL: nil,
                        createdAt: created, updatedAt: created)
    }

    /// A ready hub with one linked workspace on branch "feature".
    private func rig() async -> (CoreHub, FakeProvider, UUID) {
        let provider = FakeProvider()
        let hub = CoreHub(provider: provider)
        hub.startMonitoring()
        provider.ready()
        hub.runLookupInterval = .milliseconds(10)
        hub.runLookupTimeout = .milliseconds(300)
        provider.core.setBranch("feature", for: "/repo/linked")
        let workspace = UUID()
        hub.attach(windowID: UUID(), workspaceID: workspace, path: "/repo/linked")
        _ = await eventually { hub.session(for: workspace)?.githubAccess == .ok }
        return (hub, provider, workspace)
    }

    private func model(_ hub: CoreHub, _ workspace: UUID) -> DispatchFormModel {
        DispatchFormModel(workspaceID: workspace, hub: hub, workflows: [workflow], workflowID: nil, currentBranch: "feature")
    }

    @Test
    func defaultsFollowGitHub() {
        let values = DispatchFormModel.initialValues(for: [
            CoreDispatchInput(name: "flag", description: "", kind: .boolean, required: false, defaultValue: "", options: []),
            CoreDispatchInput(name: "on", description: "", kind: .boolean, required: false, defaultValue: "true", options: []),
            CoreDispatchInput(name: "env", description: "", kind: .choice, required: true, defaultValue: "", options: ["staging", "prod"]),
            CoreDispatchInput(name: "note", description: "", kind: .string, required: false, defaultValue: "hi", options: []),
        ])
        #expect(values == ["flag": "false", "on": "true", "env": "staging", "note": "hi"])
    }

    @Test
    func loadPicksTheCurrentBranchAndReadsTheDefinition() async {
        let (hub, provider, workspace) = await rig()
        provider.core.dispatchDefinition = CoreDispatchDefinition(access: .ok, dispatchable: true, inputs: [
            CoreDispatchInput(name: "target", description: "", kind: .string, required: true, defaultValue: "", options: []),
        ], parseError: nil)
        let form = model(hub, workspace)
        await form.load()
        #expect(form.ref == "feature")
        #expect(form.definition?.dispatchable == true)
        #expect(form.missingRequired == ["target"])
        #expect(!form.canReview)
        form.values["target"] = "eu"
        #expect(form.canReview)
        #expect(form.inputsToSend == ["target": "eu"])
    }

    @Test
    func problemsFromTheCoreKeepTheFormOpen() async {
        let (hub, provider, workspace) = await rig()
        provider.core.preparedProblems = ["\"target\" must be one of: eu, us."]
        let form = model(hub, workspace)
        await form.load()
        await form.review()
        #expect(form.step == .editing)
        #expect(form.problems == ["\"target\" must be one of: eu, us."])
    }

    @Test
    func aReviewedDispatchIsSentOnceAndItsRunIsFound() async {
        let (hub, provider, workspace) = await rig()
        let old = dispatchRun(5, created: Date().addingTimeInterval(-600))
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [old]), for: "/repo/linked")
        await hub.loadGitHubActivity(workspaceID: workspace)
        let form = model(hub, workspace)
        await form.load()
        await form.review()
        guard case .review = form.step else { Issue.record("expected review, got \(form.step)"); return }
        #expect(provider.core.confirmed.isEmpty) // nothing sent before confirming

        // The new run appears after the dispatch; older and unrelated runs are ignored.
        let started = dispatchRun(6)
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [
            dispatchRun(7, event: "push"), dispatchRun(8, workflowID: 2), started, old,
        ]), for: "/repo/linked")
        await form.confirm()
        #expect(form.step == .found(started))
        #expect(provider.core.confirmed == ["dispatch_1"])

        await form.confirm() // no second send from the found state
        #expect(provider.core.confirmed == ["dispatch_1"])
    }

    @Test
    func aRunThatDoesNotAppearIsReportedHonestly() async {
        let (hub, _, workspace) = await rig()
        let form = model(hub, workspace)
        await form.load()
        await form.review()
        await form.confirm()
        #expect(form.step == .notFoundYet)
    }

    @Test
    func anUsedConfirmationSendsNothing() async {
        let (hub, provider, workspace) = await rig()
        // Spend the confirmation outside the form, as an expired or reused one would be.
        _ = try? await provider.core.confirmWorkflowDispatch(dispatchID: "dispatch_1")
        let form = model(hub, workspace)
        await form.load()
        await form.review()
        await form.confirm()
        if case .failed(let message) = form.step {
            #expect(message.contains("nothing was sent"))
        } else {
            Issue.record("expected failed, got \(form.step)")
        }
        #expect(provider.core.confirmed == ["dispatch_1"])
    }
}
