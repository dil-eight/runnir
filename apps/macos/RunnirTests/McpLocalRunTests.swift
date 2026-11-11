import Foundation
import Testing
@testable import Runnir

/// Local runs an MCP client starts (docs/superpowers/specs/2026-11-09-mcp-full-control-design.md).
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct McpLocalRunTests {
    static let ci = ".github/workflows/ci.yml"

    private static func plan(blockers: [String] = [], host: Bool = false, unsandboxed: Bool = false) -> CoreLocalRunPlan {
        var jobs = [CoreLocalRunJob(id: "test", support: .supported, selected: true)]
        if host { jobs.append(CoreLocalRunJob(id: "mac", support: .host, selected: true)) }
        var plan = CoreLocalRunPlan.oneLane(ci, name: "CI", jobs: jobs)
        plan.secrets = ["API_KEY"]
        plan.variables = ["REGION"]
        plan.blockers = blockers
        if host { plan.hostJobs = ["CI › mac"] }
        plan.hostUnsandboxed = unsandboxed
        return plan
    }

    /// A ready hub with a workspace whose Core plans `plan`, and a desktop
    /// that starts runs through it.
    private func rig(_ plan: CoreLocalRunPlan, store: InMemoryLocalRunValueStore = InMemoryLocalRunValueStore())
        async -> (FakeMcpDesktop, WorkspaceRecord, FakeCore, CoreHub) {
        let (hub, id, fake) = await makeWorkspaceHub {
            $0.preparedLocalRun = CorePreparedLocalRun(readiness: FakeCore.readyTools, plan: plan, confirmationID: "local_1", expiresAt: Date())
        }
        let record = WorkspaceRecord(id: id, path: "/repo/a", name: "a", bookmark: Data(), lastOpenedAt: Date())
        let desktop = FakeMcpDesktop(workspaces: [record], workflows: [], store: store)
        desktop.mcpHub = hub
        return (desktop, record, fake, hub)
    }

    private func start(_ start: CoreMcpLocalRunStart) -> CoreMcpRequest {
        CoreMcpRequest(id: "m", client: "claude-code", tool: .startLocalRun, repository: "/repo/a", set: "", secrets: [], variables: [],
                       action: true, start: start)
    }

    @Test func missingValuesAreRefusedUnlessAllowed() async throws {
        let (desktop, record, fake, hub) = await rig(Self.plan())
        let handler = McpRequestHandler(desktop: desktop)
        guard case .refusal(let reason) = await handler.answer(start(CoreMcpLocalRunStart())) else {
            Issue.record("started without values")
            return
        }
        #expect(reason.contains("secrets.API_KEY") && reason.contains("vars.REGION") && reason.contains("runnir_set_values"))
        #expect(fake.confirmedLocalRuns.isEmpty)

        let answer = await handler.answer(start(CoreMcpLocalRunStart(allowMissingValues: true)))
        #expect(answer == .started(CoreMcpLocalRunStarted(workspace: "a", executionID: "exec_1", passed: [],
                                                          empty: ["secrets.API_KEY", "vars.REGION"], environment: nil)))
        #expect(fake.startedBy == ["claude-code"])
        #expect(desktop.shownRuns == [desktop.windowID])
        #expect(hub.session(for: record.id)?.localRun?.startedBy == "claude-code")
    }

    @Test func savedValuesArePassed() async throws {
        let store = InMemoryLocalRunValueStore()
        let (desktop, record, fake, _) = await rig(Self.plan(), store: store)
        try await store.save(workspaceID: record.id, key: LocalRunValueKey(kind: .secret, name: "API_KEY"), value: "s3cr3t")
        try await store.save(workspaceID: record.id, key: LocalRunValueKey(kind: .variable, name: "REGION"), value: "eu")
        let answer = await McpRequestHandler(desktop: desktop).answer(start(CoreMcpLocalRunStart()))
        guard case .started(let started) = answer else {
            Issue.record("\(answer)")
            return
        }
        #expect(started.passed == ["secrets.API_KEY", "vars.REGION"] && started.empty.isEmpty)
        #expect(fake.confirmedValues.first?.secrets == ["API_KEY": "s3cr3t"])
    }

    @Test func aRunStillGoingOrBlockedIsRefused() async throws {
        let (desktop, _, _, _) = await rig(Self.plan(blockers: ["Docker is not running."]))
        guard case .refusal(let blocked) = await McpRequestHandler(desktop: desktop).answer(start(CoreMcpLocalRunStart(allowMissingValues: true))) else {
            Issue.record("a blocked run started")
            return
        }
        #expect(blocked.contains("Docker is not running."))

        let (going, _, fake, _) = await rig(Self.plan())
        fake.localOutputs = [CoreLocalRunOutput(executionID: "exec_1", repositoryID: "repo", state: .running, phase: .running, lines: [],
                                                discarded: false, lastSequence: 0, jobs: [], plan: Self.plan(), startedAt: Date(), finishedAt: nil,
                                                exitCode: nil, message: nil, cleanupProblem: nil)]
        let handler = McpRequestHandler(desktop: going)
        guard case .started = await handler.answer(start(CoreMcpLocalRunStart(allowMissingValues: true))) else {
            Issue.record("the first run did not start")
            return
        }
        guard case .refusal(let reason) = await handler.answer(start(CoreMcpLocalRunStart(allowMissingValues: true))) else {
            Issue.record("a second run started")
            return
        }
        #expect(reason.contains("still going") && reason.contains("exec_1"))
    }

    @Test func withoutTheSandboxTheUserDecides() async throws {
        let (desktop, _, fake, _) = await rig(Self.plan(host: true, unsandboxed: true))
        let handler = McpRequestHandler(desktop: desktop)
        let request = start(CoreMcpLocalRunStart(workflows: [(Self.ci, ["test", "mac"])], allowMissingValues: true, macosWithoutSandbox: true))

        let cancelled = Task { await handler.answer(request) }
        let prompt = try #require(await waitForRunPrompt(desktop))
        #expect(prompt.client == "Claude Code" && prompt.jobs == ["CI › mac"] && prompt.windowID == desktop.windowID)
        prompt.cancel()
        #expect(await cancelled.value == .refusal("Cancelled in Runnir; nothing ran."))
        #expect(fake.confirmedLocalRuns.isEmpty && desktop.mcpRunPrompt == nil)
        #expect(fake.localRunRequests.last?.unsandboxed == true)
        #expect(desktop.opened.last?.1 == true, "the window comes to the front")

        let ran = Task { await handler.answer(request) }
        let asked = try #require(await waitForRunPrompt(desktop))
        let planned = fake.localRunRequests.count
        asked.run()
        guard case .started = await ran.value else {
            Issue.record("the run did not start")
            return
        }
        #expect(fake.confirmedLocalRuns == ["local_1"])
        #expect(fake.localRunRequests.count == planned + 1, "planned again after the yes, for a fresh confirmation")
    }

    /// The prompt waits longer than the Core keeps a confirmation, so the run
    /// is planned again after the yes; one that changed meanwhile does not start.
    @Test func aRunThatChangedWhileAskingDoesNotStart() async throws {
        let (desktop, _, fake, _) = await rig(Self.plan(host: true, unsandboxed: true))
        let handler = McpRequestHandler(desktop: desktop)
        let request = start(CoreMcpLocalRunStart(workflows: [(Self.ci, ["test", "mac"])], allowMissingValues: true, macosWithoutSandbox: true))

        let ran = Task { await handler.answer(request) }
        let asked = try #require(await waitForRunPrompt(desktop))
        var changed = Self.plan(host: true, unsandboxed: true)
        changed.hostJobs = ["CI › mac", "CI › other-mac"]
        fake.preparedLocalRun = CorePreparedLocalRun(readiness: FakeCore.readyTools, plan: changed, confirmationID: "local_2", expiresAt: Date())
        asked.run()
        #expect(await ran.value == .refusal("The run changed while Runnir asked about it, so nothing ran. Ask again."))
        #expect(fake.confirmedLocalRuns.isEmpty)
    }

    @Test func withoutAMacOSJobThereIsNothingToUnsandbox() async {
        let (desktop, _, _, _) = await rig(Self.plan())
        guard case .refusal(let reason) = await McpRequestHandler(desktop: desktop).answer(start(CoreMcpLocalRunStart(macosWithoutSandbox: true))) else {
            Issue.record("started")
            return
        }
        #expect(reason.contains("No macOS job"))
    }

    @Test func workflowsAndJobsAreChosenByName() throws {
        let lanes = [
            CoreLocalRunLane(workflowID: Self.ci, workflowName: "CI", jobs: [
                CoreLocalRunJob(id: "lint", support: .supported),
                CoreLocalRunJob(id: "test", support: .supported, needs: ["lint"]),
                CoreLocalRunJob(id: "mac", support: .host),
                CoreLocalRunJob(id: "win", support: .unsupported, reason: "Not supported locally: Windows runner"),
            ]),
            CoreLocalRunLane(workflowID: ".github/workflows/release.yml", workflowName: "Release", jobs: [CoreLocalRunJob(id: "build", support: .supported)]),
        ]
        let all = try McpLocalRunStarter.selection([("ci", [])], in: lanes).get()
        #expect(all.jobs[Self.ci] == ["lint", "test"], "macOS jobs only when named")
        #expect(all.jobs[".github/workflows/release.yml"] == [])
        let named = try McpLocalRunStarter.selection([("ci.yml", ["test", "mac"]), ("Release", [])], in: lanes).get()
        #expect(named.jobs[Self.ci] == ["lint", "test", "mac"], "a job brings what it needs")
        #expect(named.jobs[".github/workflows/release.yml"] == ["build"])

        func refusal(_ asked: [(workflow: String, jobs: [String])]) -> String {
            guard case .failure(let refusal) = McpLocalRunStarter.selection(asked, in: lanes) else { return "" }
            return refusal.reason
        }
        #expect(refusal([("deploy", [])]).contains(".github/workflows/release.yml"))
        #expect(refusal([("CI", ["nope"])]).contains("lint, test, mac, win"))
        #expect(refusal([("CI", ["win"])]).contains("Windows runner"))
    }

    @Test func theRequestCarriesTheStartOverGRPC() {
        let request = GRPCCoreService.map(Runnir_Core_V1_McpRequest.with {
            $0.id = "mcp_1"
            $0.tool = .startLocalRun
            $0.action = true
            $0.start = .with {
                $0.scenario = .with { $0.kind = .pullRequest; $0.target = "main" }
                $0.workflows = [.with { $0.workflow = "ci.yml"; $0.jobs = ["test"] }]
                $0.allowMissingValues = true
            }
        })
        #expect(request.tool == .startLocalRun && request.action)
        #expect(request.start?.scenario?.kind == .pullRequest && request.start?.scenario?.target == "main")
        #expect(request.start?.workflows.first?.workflow == "ci.yml" && request.start?.workflows.first?.jobs == ["test"])
        #expect(request.start?.allowMissingValues == true && request.start?.macosWithoutSandbox == false && request.start?.environment == nil)
    }

    private func waitForRunPrompt(_ desktop: FakeMcpDesktop) async -> McpUnsandboxedPrompt? {
        for _ in 0..<200 {
            if let prompt = desktop.mcpRunPrompt { return prompt }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }
}

@Suite struct McpClientNameTests {
    @Test func knownClientsHaveTheirNames() {
        #expect(McpClientName.display("claude-code") == "Claude Code")
        #expect(McpClientName.display("codex-mcp-client") == "Codex")
        #expect(McpClientName.display("") == "An MCP client")
        #expect(McpClientName.display("zed") == "zed")
    }
}
