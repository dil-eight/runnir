import Foundation
import Testing
@testable import Runnir

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DispatchHistoryTests {
    private let path = ".github/workflows/deploy.yml"
    private let sent = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ id: Int64, ref: String = "main", inputs: [String: String] = [:], omitted: [String] = [], run: Int64 = 0,
                        sent: Date? = nil) -> CoreDispatchRecord {
        CoreDispatchRecord(id: id, workflowPath: path, ref: ref, inputs: inputs, omittedInputs: omitted, sentAt: sent ?? self.sent, runID: run)
    }

    @Test
    func theSummaryListsTheValuesSentInANameOrder() {
        #expect(DispatchHistory.summary(record(1, inputs: ["environment": "staging", "dry_run": "false"])) == "dry_run=false, environment=staging")
        #expect(DispatchHistory.summary(record(1)) == "no inputs")
        let many = record(1, inputs: ["a": "1", "b": "2", "c": "3", "d": "4", "e": "5"])
        #expect(DispatchHistory.summary(many) == "a=1, b=2, c=3 +2 more")
        // A long value is cut so the menu stays readable.
        let long = record(1, inputs: ["note": String(repeating: "x", count: 80)])
        #expect(DispatchHistory.summary(long).count <= 40)
    }

    @Test
    func leftOutInputsAreSaidSoAndNeverValued() {
        #expect(DispatchHistory.leftOut(record(1)) == nil)
        #expect(DispatchHistory.leftOut(record(1, omitted: ["deploy_token"])) == "Left out because it looks secret: deploy_token")
        #expect(DispatchHistory.leftOut(record(1, omitted: ["deploy_token", "pin"])) == "Left out because they look secret: deploy_token, pin")
    }

    @Test
    func twoEntriesAreComparedByBranchAndEveryInput() {
        let a = record(1, ref: "main", inputs: ["environment": "staging", "dry_run": "true"])
        let b = record(2, ref: "release/1.4", inputs: ["environment": "production", "dry_run": "true", "note": "hotfix"])
        let rows = DispatchHistory.compare(a, b)
        #expect(rows.map(\.name) == ["Branch or tag", "dry_run", "environment", "note"])
        #expect(rows.map(\.changed) == [true, false, true, true])
        #expect(rows[0].first == "main" && rows[0].second == "release/1.4")
        #expect(rows[3].first == nil && rows[3].second == "hotfix")
        #expect(DispatchHistory.changedCount(rows) == 3)
        #expect(DispatchHistory.compare(a, a).allSatisfy { !$0.changed })
    }

    @Test
    func anEntryBecomesAPresetToApplyForItsWorkflowAndWorkspace() {
        let workspace = UUID()
        let preset = DispatchHistory.preset(from: record(4, ref: "release/1.4", inputs: ["environment": "production"]), workspaceID: workspace)
        #expect(preset.workspaceID == workspace)
        #expect(preset.workflowPath == path)
        #expect(preset.ref == "release/1.4")
        #expect(preset.inputs == ["environment": "production"])
        #expect(preset.name.hasPrefix("Sent "))
    }

    @Test
    func theMenuNamesTheTimeTheBranchAndTheValues() {
        let now = sent.addingTimeInterval(3 * 3600)
        let entry = record(1, ref: "main", inputs: ["environment": "staging"])
        let title = DispatchHistory.menuTitle(entry, now: now)
        #expect(title.hasPrefix(DispatchHistory.age(of: entry, now: now) + " · main · "))
        #expect(title.hasSuffix("environment=staging"))
        // Sent three hours before now, whatever the language: later "now" gives another age.
        #expect(DispatchHistory.age(of: entry, now: now) != DispatchHistory.age(of: entry, now: sent.addingTimeInterval(60)))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DispatchHistoryFormTests {
    private let workflow = CoreGitHubWorkflow(id: 1, name: "Deploy", path: ".github/workflows/deploy.yml", state: "active", htmlURL: nil)

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

    private func form(_ hub: CoreHub, _ workspace: UUID) -> DispatchFormModel {
        DispatchFormModel(workspaceID: workspace, hub: hub, workflows: [workflow], workflowID: nil, currentBranch: "feature")
    }

    private func record(_ id: Int64, ref: String = "feature", inputs: [String: String]) -> CoreDispatchRecord {
        CoreDispatchRecord(id: id, workflowPath: workflow.path, ref: ref, inputs: inputs, omittedInputs: [], sentAt: Date(), runID: 0)
    }

    @Test
    func theHistoryOfTheSelectedWorkflowIsLoadedNewestFirstFromTheCore() async {
        let (hub, provider, workspace) = await rig()
        provider.core.history = [record(2, inputs: ["target": "us"]), record(1, inputs: ["target": "eu"])]
        let model = form(hub, workspace)
        await model.load()
        await model.loadHistory()
        #expect(model.history.map(\.id) == [2, 1])
        #expect(provider.core.historyRequests.last == workflow.path)
    }

    @Test
    func anEntryFillsTheFormLikeAPresetAndKeepsNothingSecret() async {
        let (hub, provider, workspace) = await rig()
        provider.core.dispatchDefinition = CoreDispatchDefinition(access: .ok, dispatchable: true, inputs: [
            CoreDispatchInput(name: "target", description: "", kind: .string, required: true, defaultValue: "", options: []),
            CoreDispatchInput(name: "note", description: "", kind: .string, required: false, defaultValue: "", options: []),
        ], parseError: nil)
        let model = form(hub, workspace)
        await model.load()
        model.applyHistory(CoreDispatchRecord(id: 3, workflowPath: workflow.path, ref: "feature", inputs: ["target": "eu", "gone": "x"],
                                              omittedInputs: ["deploy_token"], sentAt: Date(), runID: 0))
        #expect(model.values["target"] == "eu")
        #expect(model.ref == "feature")
        // An input the workflow no longer has is said, not silently dropped.
        #expect(model.presetNotes.contains { $0.contains("gone") })
        #expect(model.historyNote?.contains("deploy_token") == true)
    }

    @Test
    func aRunFoundAfterTheDispatchIsLinkedToItsEntry() async {
        let (hub, provider, workspace) = await rig()
        provider.core.dispatchHistoryID = 7
        let model = form(hub, workspace)
        await model.load()
        await model.review()
        let started = CoreWorkflowRun(id: 9, workflowID: 1, name: "Deploy", displayTitle: "Deploy", runNumber: 9, event: "workflow_dispatch",
                                      status: "queued", conclusion: nil, branch: "feature", headSHA: "abc", actor: "me", htmlURL: nil,
                                      createdAt: Date(), updatedAt: Date())
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [started]), for: "/repo/linked")
        await model.confirm()
        #expect(model.step == .found(started))
        #expect(provider.core.linkedDispatchRuns.map(\.id) == [7])
        #expect(provider.core.linkedDispatchRuns.map(\.runID) == [9])
    }

    @Test
    func aRunGitHubNamedNeedsNoLinking() async {
        let (hub, provider, workspace) = await rig()
        provider.core.dispatchHistoryID = 7
        provider.core.dispatchedRunID = 9
        let model = form(hub, workspace)
        await model.load()
        await model.review()
        let started = CoreWorkflowRun(id: 9, workflowID: 1, name: "Deploy", displayTitle: "Deploy", runNumber: 9, event: "workflow_dispatch",
                                      status: "queued", conclusion: nil, branch: "feature", headSHA: "abc", actor: "me", htmlURL: nil,
                                      createdAt: Date(), updatedAt: Date())
        provider.core.setRuns(CoreGitHubResult(access: .ok, items: [started]), for: "/repo/linked")
        await model.confirm()
        #expect(model.step == .found(started))
        #expect(provider.core.linkedDispatchRuns.isEmpty, "the Core already recorded the run it was told about")
    }
}
